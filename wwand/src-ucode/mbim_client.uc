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
import * as mbim from './codec/mbim.uc';

const DEFAULT_TIMEOUT = 15000;
const OPEN_TIMEOUT = 10000;

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

			if (cb)
				cb(null);
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
		let info = mbim.encode_info(cmd[kind] ?? {}, args);
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

			// responses use the 'response' field layout
			let data = mbim.decode_info(cmd.response ?? {}, msg.info);

			if (cb)
				cb(null, data);
		}, opts?.timeout);
	};

	// command_raw: send a COMMAND whose InformationBuffer is opaque bytes (not a
	// schema-encoded struct) and return the raw response InformationBuffer. Used
	// by the QMI-over-MBIM passthrough, where `info` is a whole QMUX frame.
	self.command_raw = function(service_uuid, cid, info, cb, opts) {
		let txn = self.next_txn++;
		let frame = mbim.encode_command(txn, service_uuid, cid, mbim.CMD_SET, info ?? '');

		return self.raw_send(frame, txn, (err, msg) => {
			if (err)
				return cb ? cb(err, null) : null;

			if (msg.status != STATUS_SUCCESS) {
				if (hooks?.on_error)
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
	self.on_message = function(msg) {
		if (msg.type == mbim.MSG_OPEN_DONE || msg.type == mbim.MSG_CLOSE_DONE ||
		    msg.type == mbim.MSG_COMMAND_DONE) {
			let key = sprintf('%d', msg.txn);
			let p = self.pending[key];

			if (!p)
				return;

			delete self.pending[key];
			p.timer.cancel();

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
}
