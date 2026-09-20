// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — MBIM session client. Owns the transaction id space on a cdc-wdm
// control channel, correlates COMMAND/COMMAND_DONE by transaction id and
// dispatches INDICATE_STATUS by (service, cid).
//
// Unlike QMI there is one control endpoint per device (no per-service client
// ids); the client must be OPENed once before commands and CLOSEd on
// shutdown. It attaches to the same transport hub used by the QMI stack —
// the hub simply hands every decoded frame to on_message().
//
//   let c = mbim_client.create(hub, { on_error, on_success });
//   c.open((err) => { ... });
//   c.command(schema, 'CONNECT', 'set', args, (err, data) => { ... });
//   c.on(schema, 'REGISTER_STATE', (data) => { ... });   // indications
//   c.close();
//
// on_error(client, kind, what, status) — `kind` is 'send' | 'timeout' | 'mbim',
// `what` names the command ('basic_connect/CONNECT', or 'qmi_passthrough/cid 1'
// where there is no schema, or 'OPEN'/'CLOSE'), and `status` is the
// MBIM_STATUS_ERROR for kind 'mbim'. The QMI client reports the same shape
// (client.uc -> modem.uc: "qmi error (kind) svc N NAME"); before this, an MBIM
// failure was anonymous, which is how a v1-shaped CONNECT to a v3 modem showed
// up as a bare "status 21" and cost a day to place (HW, RM520N-GL, 2026-09-19).

'use strict';

import * as uloop from 'uloop';
import * as mbim from 'wwand.codec.mbim';
import * as struct from 'struct';

const DEFAULT_TIMEOUT = 15000;
const OPEN_TIMEOUT = 10000;

// MS Basic Connect Extensions service + CID 15, and the versions we advertise,
// as libmbim builds them (mbim-device.c:1710-1714, 1.32.0): 0x0100 = MBIM 1.0,
// 0x0300 = MBIMEx 3.0. libmbim refuses to ask for v2 and v3 at once and so do
// we — v3 is what the schemas in codec/mbim_schema/ are written against.
const EXT_SERVICE_UUID   = '3d01dcc5-fef5-4d05-0d3a-bef7058e9aaf';
const EXT_CID_VERSION    = 15;
const MBIM_VERSION_1_0   = 0x0100;
const MBIMEX_VERSION_3_0 = 0x0300;

// WHICH MBIMEx VERSION TO ASK FOR, or 0 to ask for none. 0 is the shipped
// value: see the comment in open(). Set to MBIMEX_VERSION_3_0 only together
// with v3 encoders/decoders for Connect, Subscriber Ready Status, Packet
// Service and IP Packet Filters.
const MBIMEX_REQUEST = MBIMEX_VERSION_3_0;

// MBIM_STATUS_ERROR success code
const STATUS_SUCCESS = 0;

export function create(hub, hooks)
{
	let self = {
		next_txn: 1,
		pending: {},
		handlers: {},     // "service:cid" -> [cb]
		opened: false,
	};

	// `what` names the command for the log — see the on_error contract above.
	self.raw_send = function(frame, txn, cb, timeout, what) {
		if (!hub.send_raw(frame)) {
			if (hooks?.on_error)
				hooks.on_error(self, 'send', what);

			if (cb)
				cb({ error: 'send' }, null);

			return false;
		}

		let p = { cb: cb };

		p.timer = uloop.timer(timeout ?? DEFAULT_TIMEOUT, () => {
			delete self.pending[sprintf('%d', txn)];

			// and any half-collected fragment set for this transaction: its
			// continuations are not coming, and leaving it there both grows the
			// table forever and lets a reused transaction id append to stale
			// bytes. Raised by Codex review, 2026-09-19.
			delete self.frags[sprintf('%d:%d', mbim.MSG_COMMAND_DONE, txn)];

			if (hooks?.on_error)
				hooks.on_error(self, 'timeout', what);

			if (cb)
				cb({ error: 'timeout' }, null);
		});

		self.pending[sprintf('%d', txn)] = p;

		return true;
	};

	// OPEN, then agree an MBIMEx version — with ONE close/re-open retry if that
	// second step comes back a function error.
	//
	// `self.opened` is this CLIENT's belief, not the device's. A fresh client
	// over a device the previous host session left in-session has opened=false
	// and so never closes, and the function then answers the version query with
	// a function error. libmbim has a step for exactly this — an explicit CLOSE
	// before OPEN when the device may still be in session (mbim-device.c:2051-2058,
	// 1.32.0) — and the consequence of not having it is not cosmetic: with no
	// version agreed this client reads and writes the v1 layouts, and a v3 modem
	// answers the v1 CONNECT with status 21 (InvalidParameters), every attempt,
	// forever. HW-reproduced on the GL-X3000/RM520N (2026-09-20) after a config
	// reload bounced the modem: 30+ identical bring-up failures, cleared only by
	// restarting the daemon.
	//
	// Recovering here rather than closing pre-emptively on every start: the
	// failure is what tells us the function needs it, and a CLOSE sent to a
	// device that is not open is its own error to reason about.
	self.open = function(cb) {
		let attempt = 0;
		let do_open, do_version;

		do_version = () => {

			// WE DO NOT ASK FOR MBIMEx, AND THAT IS THE POINT.
			//
			// A host that sends no MBIM_CID_VERSION gets the v1 layouts, which is
			// what this client implements — so `mbimex_version` stays 0 and every
			// version-aware decoder reads v1. That is the whole of finding 24: the
			// bug was never "we fail to negotiate", it was "we decode v3 while
			// negotiating nothing". Decoding what we actually get fixes it.
			//
			// ASKING FOR A VERSION IS A COMMITMENT TO ENCODE THAT GENERATION,
			// not a flag. MBIMEx v3 REDEFINES Connect in Basic Connect — a
			// different field order plus MediaPreference and UnnamedIes — and
			// also Subscriber Ready Status, Packet Service and IP Packet
			// Filters; v2 redefines Register State, Packet Service and Signal
			// State (libmbim 1.32.0, mbim-service-ms-basic-connect-v2.json and
			// -v3.json). This client does not implement that generation
			// consistently — Connect and friends are encoded in their v1 form,
			// while the Signal State decode already reads the v2 tail — so
			// negotiating it would have us sending and expecting layouts the
			// agreed contract does not describe.
			//
			// The tested RM520N-GL agreed to 3.0 first try (GL-X3000,
			// 2026-09-19), so the request alone is enough to enter that
			// contract. (The CONNECT failure on that box is older than the
			// experiment — MBIM_STATUS_ERROR_INVALID_PARAMETERS against an M2M
			// APN, logged by the previous daemon before any of this was
			// deployed — so it is NOT evidence either way, and is not claimed
			// as such.)
			//
			// The handshake and the version-aware layouts stay in the tree because
			// they are what such a port would build on; setting MBIMEX_REQUEST to
			// 0x0300 turns it back on. Found by a full review, 2026-09-19; the
			// regression caught on hardware the same day.
			self.command_raw(EXT_SERVICE_UUID, EXT_CID_VERSION,
				struct.pack('<HH', MBIM_VERSION_1_0, MBIMEX_REQUEST),
				(verr, info) => {
					// VALIDATE BOTH HALVES before letting the answer pick a
					// layout: an unexpected value here would select a decode
					// this client does not implement, which is the very thing
					// the request is withheld to avoid. Raised by Codex review,
					// 2026-09-19.
					let why = null;

					if (verr)
						why = sprintf('query failed (%s%s)', verr.error ?? 'error',
							(verr.status != null) ? sprintf(' status %d', verr.status) : '');
					else if (length(info ?? '') < 4)
						why = sprintf('answer too short (%d bytes)', length(info ?? ''));
					else {
						let mv = struct.unpack('<H', substr(info, 0, 2))[0];
						let ev = struct.unpack('<H', substr(info, 2, 2))[0];

						if (mv == MBIM_VERSION_1_0 && ev && ev <= MBIMEX_REQUEST)
							self.mbimex_version = ev;
						else
							why = sprintf('answered mbim %d.%d / ext %d.%d, outside what this client implements',
								(mv >> 8) & 0xff, mv & 0xff, (ev >> 8) & 0xff, ev & 0xff);
					}

					// SAY WHY. "no MBIMEx version agreed" on its own is the
					// worst kind of log line: it reports a decision with real
					// consequences — a v3 modem answers the v1 CONNECT with
					// status 21 (InvalidParameters) and every bring-up then
					// fails identically — and gives nothing to act on. Seen on
					// the GL-X3000/RM520N (2026-09-20): the same modem agreed
					// 3.0 on one start and not on the next, and the log could
					// not tell the two apart.
					// ONE close/re-open, and only for an error from the
					// FUNCTION: that is the signature of a device still in a
					// session this client did not open. A short or unexpected
					// ANSWER is the modem telling us what it supports, and
					// asking again would get the same answer.
					if (!self.mbimex_version && verr?.error == 'function_error' && attempt < 2) {
						if (hooks?.log)
							hooks.log('info', 'MBIMEx version query hit a function error — closing and reopening the channel once');

						return self.close(() => do_open());
					}

					if (hooks?.log)
						hooks.log(self.mbimex_version ? 'info' : 'warn', self.mbimex_version
							? sprintf('MBIMEx %d.%d agreed%s', (self.mbimex_version >> 8) & 0xff,
								self.mbimex_version & 0xff,
								(attempt > 1) ? ' (after reopening the channel)' : '')
							: sprintf('no MBIMEx version agreed (%s) — reading the v1 layouts', why));

					if (cb)
						cb(null);
				},
				{ cmd_type: mbim.CMD_QUERY, timeout: OPEN_TIMEOUT });
		};

		do_open = () => {
			attempt++;

			let txn = self.next_txn++;

			self.raw_send(mbim.encode_open(txn, 4096), txn, (err, msg) => {
				if (err)
					return cb ? cb(err) : null;

				if (msg.status != STATUS_SUCCESS)
					return cb ? cb({ error: 'open_failed', status: msg.status }) : null;

				self.opened = true;
				self.mbimex_version = 0;

				if (!MBIMEX_REQUEST)
					return cb ? cb(null) : null;

				do_version();
			}, OPEN_TIMEOUT, 'OPEN');
		};

		do_open();
	};

	self.command = function(schema, name, kind, args, cb, opts) {
		let cmd = schema.commands[name];

		if (!cmd) {
			if (cb)
				cb({ error: 'proto', detail: sprintf('no command %s', name) }, null);

			return false;
		}

		let cmd_type = (kind == 'set') ? mbim.CMD_SET : mbim.CMD_QUERY;

		// encode_info die()s on schema fields it cannot encode (arrays are
		// decode-only) — surface that as a failed REQUEST, not a dead daemon
		let info;
		try {
			// a command whose LAYOUT depends on the negotiated MBIMEx version
		// gives its field spec as a function of the client (BASE_STATIONS_INFO)
		info = mbim.encode_info((type(cmd[kind]) == 'function')
			? cmd[kind](self) : (cmd[kind] ?? {}), args);
		}
		catch (e) {
			if (cb)
				cb({ error: 'proto', detail: sprintf('%s', e) }, null);

			return false;
		}

		let txn = self.next_txn++;

		let frame = mbim.encode_command(txn, schema.service, cmd.cid, cmd_type, info);
		let what = sprintf('%s/%s', mbim.service_name(schema.service), name);

		return self.raw_send(frame, txn, (err, msg) => {
			if (err) {
				if (cb)
					cb(err, null);

				return;
			}

			if (msg.status != STATUS_SUCCESS) {
				// `no_recovery` works here too, and it did not before: only
				// command_raw honoured it, so a schema'd command could not opt
				// out of voting on the channel. That gap matters for the
				// OPTIONAL ones — an MBIMEx v3 diagnostic a firmware simply
				// has not implemented answers a refusal per query, and counted
				// as protocol errors those drive the hardware recovery ladder
				// toward a repower for a command nothing depends on. Same
				// argument as the QMI-over-MBIM tunnel (ddimension/wwand#30);
				// mandatory commands keep reporting, so a wedged channel is
				// still caught. Found by review, 2026-09-20.
				if (hooks?.on_error && !opts?.no_recovery)
					hooks.on_error(self, 'mbim', what, msg.status);

				if (cb)
					cb({ error: 'mbim', status: msg.status }, null);

				return;
			}

			if (hooks?.on_success)
				hooks.on_success(self);

			// responses use the 'response' field layout, unless the command
			// supplies a custom `decode(info)` — needed for MBIMEx buffers whose
			// ms-struct/ms-struct-array layout the InformationBuffer codec can't
			// express (Base Stations Info, v2 Signal State). The raw info buffer
			// is passed as a third argument for callers that want it.
			let data = (type(cmd.decode) == 'function')
				? cmd.decode(msg.info, self)
				: mbim.decode_info(cmd.response ?? {}, msg.info);

			if (cb)
				cb(null, data, msg.info);
		}, opts?.timeout, what);
	};

	// command_raw: send a COMMAND whose InformationBuffer is opaque bytes (not a
	// schema-encoded struct) and return the raw response InformationBuffer. Used
	// by the QMI-over-MBIM passthrough (info = a whole QMUX frame) and the AT-over-
	// MBIM vendor tunnel. Defaults to a SET; opts.cmd_type overrides it (the Compal
	// AT CID is a QUERY).
	self.command_raw = function(service_uuid, cid, info, cb, opts) {
		let txn = self.next_txn++;
		let frame = mbim.encode_command(txn, service_uuid, cid, opts?.cmd_type ?? mbim.CMD_SET, info ?? '');
		// opts.name: a caller that KNOWS the command names it, so the log reads
		// 'basic_connect/CONNECT' rather than 'basic_connect/cid 12'. The v3
		// CONNECT goes out through here, and that is precisely the failure the
		// named logging exists for.
		let what = opts?.name
			? sprintf('%s/%s', mbim.service_name(service_uuid), opts.name)
			: sprintf('%s/cid %d', mbim.service_name(service_uuid), cid);

		return self.raw_send(frame, txn, (err, msg) => {
			if (err)
				return cb ? cb(err, null) : null;

			if (msg.status != STATUS_SUCCESS) {
				// `no_recovery`: a non-success status on a VENDOR CID is not evidence
				// about the control channel. The QMI-over-MBIM tunnel is the case that
				// matters — an RM520F-GL answers status 2 to every request through it,
				// once per telemetry tick, while its MBIM is working perfectly. Counted
				// as protocol errors those drove the hardware recovery ladder toward a
				// repower and a reboot (ddimension/wwand#30). Native MBIM commands keep
				// reporting, so a genuinely wedged channel is still caught by all of
				// them; only this one optional tunnel stops voting.
				if (hooks?.on_error && !opts?.no_recovery)
					hooks.on_error(self, 'mbim', what, msg.status);

				return cb ? cb({ error: 'mbim', status: msg.status }, null) : null;
			}

			if (hooks?.on_success)
				hooks.on_success(self);

			if (cb)
				cb(null, msg.info);
		}, opts?.timeout, what);
	};

	self.on = function(schema, name, cb) {
		let cmd = schema.commands[name];

		if (!cmd)
			return;

		let key = sprintf('%s:%d', schema.service, cmd.cid);

		self.handlers[key] = self.handlers[key] ?? [];
		// `decode` is kept, not resolved: a command whose LAYOUT depends on the
		// negotiated MBIMEx version must be decided when the indication ARRIVES,
		// not when the handler is registered — registration happens before
		// open(), so the version is not known yet. Freezing the field spec here
		// is what made SUBSCRIBER_READY_STATUS indications decode with the wrong
		// layout on a v3 modem while the query path had it right.
		push(self.handlers[key], { cb: cb, decode: cmd.decode,
			fields: cmd.notification ?? cmd.response ?? {} });
	};

	// called by the hub for every decoded MBIM frame on this device
	// REASSEMBLE A FRAGMENTED RESPONSE before anyone tries to decode it.
	//
	// A COMMAND_DONE or INDICATE_STATUS larger than the negotiated
	// MaxControlTransfer (4096, sent in OPEN) arrives split: fragment 0 carries
	// the full header, the rest carry only the message+fragment headers and more
	// InformationBuffer. The codec used to skip the fragment header entirely, so
	// fragment 0 was handed up as the whole answer and the continuations were
	// parsed as bogus standalone messages. Everything downstream saw a short but
	// well-formed buffer and decoded what it could — an SMS read-all on a SIM
	// with enough stored PDUs simply lost the tail. Keyed by transaction id,
	// which is what identifies a fragment set. Found by a full review,
	// 2026-09-19.
	self.frags = {};

	// BOUNDED, both ways. An incomplete set is only ever cleaned up by the
	// request timeout, and that only reaches the COMMAND_DONE key of a
	// transaction we are waiting on — an INDICATION set (transaction 0, or any
	// id the modem invents) whose last fragment never arrives just stays. A
	// firmware that starts fragmented messages it never finishes therefore
	// grows this table without limit, and a large frag_total lets one set grow
	// without limit too. Neither is a big number in practice; both are
	// unbounded, which is the part that matters in a daemon meant to run for
	// months. Found by review, 2026-09-20.
	//
	// 64 KiB is far above any MBIM message this tree decodes (the largest,
	// BASE_STATIONS_INFO with a full neighbour list, is a few KiB), and MBIM
	// does not interleave fragmented messages on the control channel — so more
	// than a couple of live sets is already abnormal.
	const FRAG_MAX_BYTES = 65536;
	const FRAG_MAX_SETS = 8;

	// keyed by TYPE and transaction id, not the id alone: unsolicited
	// indications commonly carry transaction 0, so a COMMAND_DONE set and an
	// indication set would otherwise share one slot. Raised by Codex review,
	// 2026-09-19.
	let frag_key = (msg) => sprintf('%d:%d', msg.type, msg.txn);

	let log_frag = (f, ...a) => {
		if (hooks?.log)
			hooks.log('debug', sprintf('mbim: ' + f, ...a));
	};

	let reassemble = (msg) => {
		let total = msg.frag_total ?? 1;
		let idx = msg.frag_index ?? 0;
		let key = frag_key(msg);

		if (total <= 1) {
			delete self.frags[key];

			return msg;
		}

		if (idx == 0) {
			// a fresh fragment 0 replaces whatever sat here: MBIM does not
			// interleave fragmented messages on the control channel, so an
			// unfinished set at this key is one that will never finish
			if (!exists(self.frags, key)) {
				// ...and sets at OTHER keys that will never finish are exactly
				// what accumulates. Drop the stalest rather than refuse the new
				// one: the message arriving now is the one with a reader.
				let n = 0, oldest = null, oldest_at = null;

				for (let k, a in self.frags) {
					n++;

					if (oldest_at == null || a.at < oldest_at) {
						oldest_at = a.at;
						oldest = k;
					}
				}

				if (n >= FRAG_MAX_SETS && oldest != null) {
					log_frag('dropping an unfinished fragment set (%s) — %d sets open', oldest, n);
					delete self.frags[oldest];
				}
			}

			// ...and fragment ZERO is itself a buffer. The ceiling below used
			// to be checked only when appending a continuation, so a first
			// fragment larger than the limit was stored whole and, if nothing
			// followed it, sat there. Found by review, 2026-09-20.
			if (length(msg.info ?? '') > FRAG_MAX_BYTES) {
				log_frag('fragment 0 of %s is over %d bytes — dropping', key, FRAG_MAX_BYTES);
				delete self.frags[key];

				return null;
			}

			self.frags[key] = { msg: msg, next: 1, total: total,
				info: msg.info ?? '', at: time() };

			return null;
		}

		let acc = self.frags[key];

		// STRICTLY SEQUENTIAL, and only within one declared set. A continuation
		// with no fragment 0 is not something to guess at — and neither is a
		// repeated or out-of-order index, which counted toward completion all
		// the same and yielded a buffer assembled in arrival order. Raised by
		// Codex review, 2026-09-19.
		if (!acc || idx != acc.next || idx >= total || total != acc.total) {
			delete self.frags[key];

			return null;
		}

		acc.info += (msg.info ?? '');
		acc.next++;

		if (length(acc.info) > FRAG_MAX_BYTES) {
			log_frag('fragment set %s exceeded %d bytes — dropping', key, FRAG_MAX_BYTES);
			delete self.frags[key];

			return null;
		}

		if (acc.next < total)
			return null;

		delete self.frags[key];
		acc.msg.info = acc.info;

		return acc.msg;
	};

	self.on_message = function(full) {
		let msg = reassemble(full);

		if (!msg)
			return;

		if (msg.type == mbim.MSG_OPEN_DONE || msg.type == mbim.MSG_CLOSE_DONE ||
		    msg.type == mbim.MSG_COMMAND_DONE) {
			let key = sprintf('%d', msg.txn);
			let p = self.pending[key];

			if (!p)
				return;

			delete self.pending[key];
			p.timer.cancel();

			// A done-frame carrying OUR transaction id is the modem answering
			// MBIM, whatever status it holds — a strictly weaker fact than a
			// successful command, and the only one the hardware-recovery gate
			// asks for (see recovery.note_answer). Deliberately also on
			// OPEN_DONE: a firmware that REFUSES MBIM_OPEN, as the RG650E does,
			// still refused it in MBIM.
			if (hooks?.on_answer)
				hooks.on_answer(self);

			if (p.cb)
				p.cb(null, msg);

			return;
		}

		if (msg.type == mbim.MSG_INDICATE_STATUS) {
			let key = sprintf('%s:%d', msg.service, msg.cid);

			for (let h in (self.handlers[key] ?? []))
				h.cb((type(h.decode) == 'function')
					? h.decode(msg.info, self)
					: mbim.decode_info(h.fields, msg.info), msg);

			return;
		}

		if (msg.type == mbim.MSG_FUNCTION_ERROR) {
			// abort the matching pending request if any
			let p = self.pending[sprintf('%d', msg.txn)];

			if (p) {
				delete self.pending[sprintf('%d', msg.txn)];
				p.timer.cancel();

				// a function error carrying our transaction id is as much an
				// MBIM answer as a done-frame is: the function parsed the frame
				// and rejected it. Leaving it out would let a modem that only
				// ever returns function errors stay unarmed for good.
				if (hooks?.on_answer)
					hooks.on_answer(self);

				if (p.cb)
					p.cb({ error: 'function_error', code: msg.error }, null);
			}
		}
	};

	self.close = function(cb) {
		if (!self.opened)
			return cb ? cb(null) : null;

		let txn = self.next_txn++;

		self.raw_send(mbim.encode_close(txn), txn, () => {
			self.opened = false;

			if (cb)
				cb(null);
		}, OPEN_TIMEOUT, 'CLOSE');
	};

	self.destroy = function() {
		// the half-assembled buffers belong to the channel that is going away
		self.frags = {};

		for (let key, p in self.pending) {
			p.timer.cancel();

			if (p.cb)
				p.cb({ error: 'cancelled' }, null);
		}

		self.pending = {};
	};

	return self;
};
