// wwand — generic QMI service client with request/response correlation.
//
// let c = client.create(hub, schema, cid);
// c.request('GET_MODEL', {}, (err, data) => { ... }, { timeout: 10000 });
// c.on('PACKET_SERVICE_STATUS_IND', (data, dec) => { ... });
// c.destroy();
//
// The callback receives (err, data):
//   err  null on success, else { error: 'timeout'|'send'|'qmi'|'proto',
//        result?, code? } — code is the QMI error number for 'qmi' errors.
//   data unpacked response TLVs (also passed on qmi errors, some responses
//        carry TLVs like verify-retry counts alongside a failure result).
//
// Timeouts replace the old shell `timeout -s KILL N uqmi ...` wrapper; the
// per-request on_error hook feeds the recovery ladder's error counter.

'use strict';

import * as uloop from 'uloop';
import * as tlv from './codec/tlv.uc';
import * as qmux from './codec/qmux.uc';

const DEFAULT_TIMEOUT = 10000;

export function create(hub, schema, cid, hooks)
{
	let self = {
		service: schema.service,
		cid: cid,
		schema: schema,
		pending: {},
		handlers: {},
		next_txn: 1,
		ind_by_id: {},
	};

	// index indication messages by id for dispatch
	for (let name, msg in schema.messages)
		if (msg.ind)
			self.ind_by_id[sprintf('%d', msg.id)] = name;

	// allocate a transaction id that is not already in flight. The id space wraps
	// (CTL 1..0xff — a single byte — else 1..0xffff). Skipping live txns prevents
	// a wrapped id from overwriting a still-pending request, which would leak that
	// request's timeout timer and let its later firing delete the NEW pending slot
	// (corrupting response correlation). Returns null only when every id is in
	// flight — unreachable in practice (the modem answers or times out long before
	// tens of thousands of requests stack up).
	let alloc_txn = () => {
		let txn_max = (schema.service == 0) ? 0xff : 0xffff;

		for (let tries = 0; tries < txn_max; tries++) {
			let txn = self.next_txn;
			self.next_txn = (txn >= txn_max) ? 1 : txn + 1;

			if (self.pending[sprintf('%d', txn)] == null)
				return txn;
		}

		return null;
	};

	self.request = function(name, args, cb, opts) {
		let msg = schema.messages[name];

		if (!msg) {
			if (cb)
				cb({ error: 'proto', detail: sprintf('no such message %s', name) }, null);

			return false;
		}

		let txn = alloc_txn();

		if (txn == null) {
			if (cb)
				cb({ error: 'busy', detail: 'no free transaction id' }, null);

			return false;
		}

		let frame = qmux.encode(schema.service, cid, txn, msg.id,
		                        tlv.pack(msg.req, args));

		// opts.no_recovery: don't feed the recovery error counter for this
		// request (optional reads / user ops that legitimately fail on some
		// modems must not climb the reboot ladder)
		let no_rec = opts?.no_recovery;

		if (!hub.send(frame)) {
			if (hooks?.on_error && !no_rec)
				hooks.on_error(self, 'send', name);

			if (cb)
				cb({ error: 'send' }, null);

			return false;
		}

		let p = { name: name, msg: msg, cb: cb, no_recovery: no_rec };

		p.timer = uloop.timer(opts?.timeout ?? DEFAULT_TIMEOUT, () => {
			delete self.pending[sprintf('%d', txn)];

			if (hooks?.on_error && !no_rec)
				hooks.on_error(self, 'timeout', name);

			if (cb)
				cb({ error: 'timeout' }, null);
		});

		self.pending[sprintf('%d', txn)] = p;

		return true;
	};

	self.on = function(ind_name, cb) {
		self.handlers[ind_name] = self.handlers[ind_name] ?? [];
		push(self.handlers[ind_name], cb);
	};

	self.dispatch = function(dec) {
		if (dec.kind == 'response') {
			let key = sprintf('%d', dec.txn);
			let p = self.pending[key];

			if (!p)
				return;

			delete self.pending[key];
			p.timer.cancel();

			let data = tlv.unpack(p.msg.resp, dec.tlvs);
			let err = null;

			// a TLV claimed more bytes than the frame carried: the decode is
			// corrupt, so the payload can't be trusted even if a result TLV
			// happened to parse. Treat as a protocol error, never as data.
			if (data._truncated)
				err = { error: 'proto', detail: 'truncated response' };
			else if (data._result == null)
				err = { error: 'proto', detail: 'missing result tlv' };
			else if (data._result.result != 0)
				err = { error: 'qmi', result: data._result.result, code: data._result.error };

			if (err && hooks?.on_error && !p.no_recovery)
				hooks.on_error(self, err.error, p.name);
			else if (!err && hooks?.on_success)
				hooks.on_success(self);

			if (p.cb)
				p.cb(err, data);

			return;
		}

		if (dec.kind == 'indication') {
			let name = self.ind_by_id[sprintf('%d', dec.msg_id)];

			if (!name)
				return;

			let data = tlv.unpack(schema.messages[name].ind, dec.tlvs);

			for (let cb in (self.handlers[name] ?? []))
				cb(data, dec);
		}
	};

	// cancel all pending requests, detach from hub (does not release the CID
	// on the modem — that is the owner's job via CTL RELEASE_CID)
	self.destroy = function() {
		for (let key, p in self.pending) {
			p.timer.cancel();

			if (p.cb)
				p.cb({ error: 'cancelled' }, null);
		}

		self.pending = {};
		hub.unregister(self);
	};

	hub.register(self);

	return self;
}
