// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — transport hub: wraps the native wwand_io handle, registers the
// fd with uloop and routes decoded QMUX messages to attached service clients.
//
// let hub = transport.open('/dev/cdc-wdm0', {
//     on_gone:      (hub) => { ... },        // device disappeared
//     on_unhandled: (hub, dec) => { ... },   // no client matched
// });
// hub.register(client);   // client provides .service, .cid, .dispatch(dec)
// hub.send(frame);
// hub.close();
//
// Note: QMI control messages are tiny, but cdc-wdm accepts only one
// outstanding write — bursts (the once-a-minute stats/telemetry tick) hit
// EAGAIN on the non-blocking fd. Failed writes are therefore queued and
// retried shortly instead of failing the request; only a persistently
// congested queue reports an error upstream.

'use strict';

import * as qmit from 'wwand_io';
import * as uloop from 'uloop';
import * as qmux from 'wwand.codec.qmux';

// tx congestion: frames queued past this depth report an error upstream
const TXQ_MAX = 64;
// retry cadence for a congested cdc-wdm write (message-oriented, so a failed
// write is retried whole)
const TX_RETRY_MS = 5;
// how many retries close() spends draining what is still queued. cdc-wdm takes
// ONE message at a time, so a burst drains at roughly one frame per round trip:
// the eleven clients modem.uc releases need eleven, and 20 x 5 ms bounds the
// teardown at ~100 ms. The ordinary reconnect is 5 s away (modem_common.uc:380),
// so nothing normally overlaps.
//
// RESIDUAL, named rather than hidden: a hotplug add for the same device inside
// that window opens a SECOND fd (cdc-wdm refcounts opens, desc->count++ —
// cdc-wdm.c wdm_open, 6.18.41) and the responses to the old session's releases
// are then read by the new one. The old hub reads nothing any more (its uloop
// registration is deleted on the first hop below), so it cannot mis-dispatch;
// the new CTL client drops a response whose transaction id it has no request
// for. A collision needs the same id within 100 ms of a teardown. Raised by
// Codex review, 2026-09-19.
const CLOSE_DRAIN_TRIES = 20;

export function open(path, cbs)
{
	// cbs.io_open: injectable device opener (unit tests fake the native
	// handle). NOTE: kept as two statements — ucode does not parse
	// `(a ?? b)(args)` as a call on the parenthesized expression.
	let io_open = cbs?.io_open ?? qmit.open;
	let handle = io_open(path);

	if (!handle)
		return null;

	let hub = {
		path: path,
		clients: {},
		closed: false,
	};

	// service/cid are u8; combine into one integer key to avoid an sprintf on
	// the per-message dispatch path (below)
	hub.register = function(client) {
		hub.clients[client.service * 256 + client.cid] = client;
	};

	hub.unregister = function(client) {
		delete hub.clients[client.service * 256 + client.cid];
	};

	let txq = [];
	let tx_timer = null;
	let flush_txq;

	flush_txq = () => {
		tx_timer = null;

		while (length(txq)) {
			let w = handle.write(txq[0]);

			// hard write error (false; e.g. EIO on a wedged-not-gone device):
			// the device is unusable — take the same path as a read failure
			// instead of busy-retrying it as congestion forever
			if (w === false) {
				hub.close();

				if (cbs?.on_gone)
					cbs.on_gone(hub);

				return;
			}

			if (w !== length(txq[0])) {
				// congested (null / partial) — retry shortly (frames are
				// message-oriented, a short write does not happen on cdc-wdm)
				tx_timer = uloop.timer(TX_RETRY_MS, flush_txq);
				return;
			}

			shift(txq);
		}
	};

	hub.send = function(frame) {
		if (hub.closed)
			return false;

		if (length(txq) > TXQ_MAX)
			return false;   // persistently congested: report upstream

		if (length(txq)) {
			push(txq, frame);
			return true;
		}

		let w = handle.write(frame);

		if (w === length(frame))
			return true;

		push(txq, frame);

		if (!tx_timer)
			tx_timer = uloop.timer(TX_RETRY_MS, flush_txq);

		return true;
	};

	// raw frame writer — identical to send(), named for the MBIM client which
	// deals in whole messages already
	hub.send_raw = hub.send;

	hub.close = function() {
		if (hub.closed)
			return;

		hub.closed = true;

		if (tx_timer) {
			tx_timer.cancel();
			tx_timer = null;
		}

		// Release the fd registration one loop iteration later, never inline.
		// close() is reachable FROM the read handle's own callback (device
		// gone), and deleting a uloop handle while uloop is still holding it
		// for the duration of that call is a use-after-free. A 64-bit
		// allocator absorbs the read that follows it; MIPS32 does not, and it
		// surfaces as SIGSEGV inside libucode — field-reported on a ramips
		// RUTM11, where `/etc/init.d/wwand restart` crashed the interpreter.
		//
		// Everything that makes the hub inert (the closed flag, the timer, the
		// queue) has already happened above, so callers see a synchronous
		// close either way.
		let uh = hub._uhandle;

		hub._uhandle = null;

		// WHAT IS STILL QUEUED IS WRITTEN BEFORE THE FD GOES, not discarded.
		//
		// This used to be `txq = []` above, on the stated grounds that teardown
		// writes its frames synchronously. It does not. cdc-wdm serves ONE
		// control message at a time: with O_NONBLOCK a write issued while the
		// previous URB is still in flight returns -EAGAIN (cdc-wdm.c:419-424,
		// Linux 6.18.41), and WDM_IN_USE clears only in the completion callback
		// (:161, :1334). So the first frame goes out and the SECOND almost
		// always queues — and send() then queues every frame after it without
		// even trying (:99-102).
		//
		// modem.uc teardown issues RELEASE_CID for up to eleven clients back to
		// back and closes the hub in the same synchronous block, so ten of
		// eleven releases were dropped before the 5 ms retry could run. The CIDs
		// stayed allocated in the MODEM's table — exactly the leak that release
		// burst exists to prevent, and on an E182E-class stack with a tiny table
		// a few `/etc/init.d/wwand restart` cycles exhaust it. Found by a full
		// review, 2026-09-19.
		let drain_tries = 0;
		let drain;

		drain = () => {
			// THE READ REGISTRATION GOES ON THE FIRST HOP, not at the end.
			// The callback at :221 returns without reading once `closed` is set,
			// and the fd is level-triggered — so leaving it registered for the
			// length of the drain lets uloop re-dispatch a still-readable (or
			// HUP) fd in a hot loop for up to 100 ms. Deleting it here still
			// happens from a timer callback rather than inline, which is the
			// whole point of deferring it (see above); the native fd stays open
			// because the drain below still WRITES to it. Raised by Codex
			// review, 2026-09-19.
			if (uh) {
				uh.delete();
				uh = null;
			}

			while (length(txq)) {
				let w = handle.write(txq[0]);

				if (w === length(txq[0])) {
					shift(txq);
					continue;
				}

				// hard error: the device is gone, nothing left to save
				if (w === false)
					txq = [];

				break;
			}

			if (length(txq) && ++drain_tries < CLOSE_DRAIN_TRIES)
				return uloop.timer(TX_RETRY_MS, drain);

			txq = [];

			handle.close();
		};

		uloop.timer(0, drain);
	};

	hub._dispatch = function(dec) {
		let client = hub.clients[dec.service * 256 + dec.cid];

		// broadcast indications (e.g. NAS) arrive on cid 0xff
		if (!client && dec.kind == 'indication' && dec.cid == 0xff) {
			for (let key, c in hub.clients)
				if (c.service == dec.service)
					c.dispatch(dec);

			return;
		}

		if (client)
			client.dispatch(dec);
		else if (cbs?.on_unhandled)
			cbs.on_unhandled(hub, dec);
	};

	hub._uhandle = uloop.handle(handle.fileno(), (events) => {
		// a closed hub may still get one more readable event before the
		// deferred delete above lands
		if (hub.closed)
			return;

		while (true) {
			let msg = handle.read();

			if (msg === null)
				break;

			if (msg === false) {
				hub.close();

				if (cbs?.on_gone)
					cbs.on_gone(hub);

				return;
			}

			// MBIM devices hand whole messages to a single raw handler
			// (no per-service QMUX demux); QMI devices decode QMUX
			if (cbs?.on_raw) {
				cbs.on_raw(hub, msg);
				continue;
			}

			let dec = qmux.decode(msg);

			if (dec)
				hub._dispatch(dec);
			else if (cbs?.on_unhandled)
				cbs.on_unhandled(hub, { raw: msg });
		}
	}, uloop.ULOOP_READ);

	if (!hub._uhandle) {
		handle.close();

		return null;
	}

	return hub;
};
