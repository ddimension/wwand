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

		txq = [];

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

		uloop.timer(0, () => {
			if (uh)
				uh.delete();

			handle.close();
		});
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
