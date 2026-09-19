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

	self.raw_send = function(frame, txn, cb, timeout) {
		if (!hub.send_raw(frame)) {
			if (hooks?.on_error)
				hooks.on_error(self, 'send');

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
				hooks.on_error(self, 'timeout');

			if (cb)
				cb({ error: 'timeout' }, null);
		});

		self.pending[sprintf('%d', txn)] = p;

		return true;
	};

	self.open = function(cb) {
		let txn = self.next_txn++;

		self.raw_send(mbim.encode_open(txn, 4096), txn, (err, msg) => {
			if (err)
				return cb ? cb(err) : null;

			if (msg.status != STATUS_SUCCESS)
				return cb ? cb({ error: 'open_failed', status: msg.status }) : null;

			self.opened = true;

			// MBIMEx VERSION HANDSHAKE — without it every MBIMEx layout is a guess.
			//
			// A device not told the host speaks MBIMEx MUST answer the v1 layouts
			// (MBIM 1.0), and v1 BASE_STATIONS_INFO has no SystemSubType — so every
			// ms-struct pointer after it sits 4 bytes EARLIER than the v3 layout
			// wwand decodes (LteServingCell at 28, not 32; LteNeighboringCells at
			// 60, not 64 — libmbim 1.32.0, mbim-service-ms-basic-connect-
			// extensions.json vs -v3.json). The bounds checks hide it: nothing
			// fails, wwand just publishes fabricated PCI/TAC/RSRP into telemetry
			// and LuCI. The query was wrong too, 6 counts where v1 expects 5.
			//
			// Sent exactly as libmbim does (mbim-device.c:1710-1718, 1.32.0): a
			// QUERY on MS Basic Connect Extensions CID 15 carrying our MBIM 1.0 and
			// the ONE extended version we ask for. A modem that refuses it is a v1
			// modem — the correct conclusion, not an error. Found by a full review,
			// 2026-09-19.
			//
			// NOT HW-VALIDATED. Host-tested against libmbim 1.32.0's own field
			// definitions only. The assumption worth confirming on an EG06 is the
			// converse case: a modem that answers MBIMEx layouts but does not
			// implement CID 15 would now be read as v1 and decoded with the v1
			// offsets. That is what the spec says such a device is, and it is the
			// safe direction (v1 is the documented default), but it is a behaviour
			// change for any firmware that was previously decoded correctly by
			// accident. `mbimex_version` on the client says which way it went.
			self.mbimex_version = 0;

			self.command_raw(EXT_SERVICE_UUID, EXT_CID_VERSION,
				struct.pack('<HH', MBIM_VERSION_1_0, MBIMEX_VERSION_3_0),
				(verr, info) => {
					if (!verr && length(info ?? '') >= 4)
						self.mbimex_version = struct.unpack('<H', substr(info, 2, 2))[0];

					if (cb)
						cb(null);
				},
				{ cmd_type: mbim.CMD_QUERY, timeout: OPEN_TIMEOUT });
		}, OPEN_TIMEOUT);
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

		return self.raw_send(frame, txn, (err, msg) => {
			if (err) {
				if (cb)
					cb(err, null);

				return;
			}

			if (msg.status != STATUS_SUCCESS) {
				if (hooks?.on_error)
					hooks.on_error(self, 'mbim');

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
		}, opts?.timeout);
	};

	// command_raw: send a COMMAND whose InformationBuffer is opaque bytes (not a
	// schema-encoded struct) and return the raw response InformationBuffer. Used
	// by the QMI-over-MBIM passthrough (info = a whole QMUX frame) and the AT-over-
	// MBIM vendor tunnel. Defaults to a SET; opts.cmd_type overrides it (the Compal
	// AT CID is a QUERY).
	self.command_raw = function(service_uuid, cid, info, cb, opts) {
		let txn = self.next_txn++;
		let frame = mbim.encode_command(txn, service_uuid, cid, opts?.cmd_type ?? mbim.CMD_SET, info ?? '');

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
					hooks.on_error(self, 'mbim');

				return cb ? cb({ error: 'mbim', status: msg.status }, null) : null;
			}

			if (hooks?.on_success)
				hooks.on_success(self);

			if (cb)
				cb(null, msg.info);
		}, opts?.timeout);
	};

	self.on = function(schema, name, cb) {
		let cmd = schema.commands[name];

		if (!cmd)
			return;

		let key = sprintf('%s:%d', schema.service, cmd.cid);

		self.handlers[key] = self.handlers[key] ?? [];
		push(self.handlers[key], { cb: cb, fields: cmd.notification ?? cmd.response ?? {} });
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

	// keyed by TYPE and transaction id, not the id alone: unsolicited
	// indications commonly carry transaction 0, so a COMMAND_DONE set and an
	// indication set would otherwise share one slot. Raised by Codex review,
	// 2026-09-19.
	let frag_key = (msg) => sprintf('%d:%d', msg.type, msg.txn);

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
			self.frags[key] = { msg: msg, next: 1, total: total, info: msg.info ?? '' };

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
				h.cb(mbim.decode_info(h.fields, msg.info), msg);

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
		}, OPEN_TIMEOUT);
	};

	self.destroy = function() {
		for (let key, p in self.pending) {
			p.timer.cancel();

			if (p.cb)
				p.cb({ error: 'cancelled' }, null);
		}

		self.pending = {};
	};

	return self;
};
