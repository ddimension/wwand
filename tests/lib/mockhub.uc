// wwand tests — mock transport hub simulating a QMI modem.
//
// let mock = mockhub.create({ handlers: { ... } });
// let modem = modem_mod.create({ deps: { transport_open: mock.transport_open }, ... });
//
// Handlers are keyed by message name (e.g. 'GET_MODEL') or 'service:NAME'.
// A handler is either a plain response object or fn(args, meta) -> object;
// meta = { service, cid, name, count }. Return { __error: code } to fail the
// request with QMI error <code> (other keys are still packed as TLVs).
//
// CTL SYNC / ALLOCATE_CID / RELEASE_CID have built-in default handlers.
// All responses/indications go through the real qmux/tlv codec.

'use strict';

import * as uloop from 'uloop';
import * as struct from 'struct';
import * as qmux from '../wwand/codec/qmux.uc';
import * as tlv from '../wwand/codec/tlv.uc';
import * as ctlmod from '../wwand/codec/schema/ctl.uc';
import * as dmsmod from '../wwand/codec/schema/dms.uc';
import * as nasmod from '../wwand/codec/schema/nas.uc';
import * as uimmod from '../wwand/codec/schema/uim.uc';
import * as wdsmod from '../wwand/codec/schema/wds.uc';
import * as wdamod from '../wwand/codec/schema/wda.uc';
import * as locmod from '../wwand/codec/schema/loc.uc';

const SCHEMAS = [ ctlmod.default, dmsmod.default, nasmod.default,
                  uimmod.default, wdsmod.default, wdamod.default,
                  locmod.default ];

// per-service indexes: request messages by id, indications by name
let req_index = {}, ind_index = {};

for (let schema in SCHEMAS) {
	let svc = sprintf('%d', schema.service);

	req_index[svc] = req_index[svc] ?? {};
	ind_index[svc] = ind_index[svc] ?? {};

	for (let name, msg in schema.messages) {
		if (msg.req != null || msg.resp != null)
			req_index[svc][sprintf('%d', msg.id)] = { name: name, msg: msg };

		if (msg.ind != null)
			ind_index[svc][name] = msg;
	}
}

export function create(opts)
{
	let self = {
		device: null,
		clients: {},
		calls: [],
		counts: {},
		closed: false,
		handlers: opts?.handlers ?? {},
		next_cid: 5,
		cbs: null,
	};

	self.register = function(client) {
		self.clients[sprintf('%d:%d', client.service, client.cid)] = client;
	};

	self.unregister = function(client) {
		delete self.clients[sprintf('%d:%d', client.service, client.cid)];
	};

	self.route = function(dec) {
		let client = self.clients[sprintf('%d:%d', dec.service, dec.cid)];

		if (!client && dec.kind == 'indication' && dec.cid == 0xff) {
			for (let key, c in self.clients)
				if (c.service == dec.service)
					c.dispatch(dec);

			return;
		}

		if (client)
			client.dispatch(dec);
	};

	let respond = (dec, msg, obj) => {
		let result = struct.pack('<BHHH', 0x02, 4, obj?.__error ? 1 : 0, obj?.__error ?? 0);
		let rest = {};

		for (let k, v in (obj ?? {}))
			if (k != '__error')
				rest[k] = v;

		let tlvs = result + tlv.pack(msg.resp ?? {}, rest);
		let frame = qmux.encode(dec.service, dec.cid, dec.txn, msg.id, tlvs, 'response');

		uloop.timer(0, () => self.route(qmux.decode(frame)));
	};

	self.send = function(frame) {
		if (self.closed)
			return false;

		let dec = qmux.decode(frame);

		if (!dec || dec.kind != 'request')
			die('mockhub: received non-request frame');

		let entry = req_index[sprintf('%d', dec.service)]?.[sprintf('%d', dec.msg_id)];

		if (!entry)
			die(sprintf('mockhub: unknown message svc %d id 0x%04x', dec.service, dec.msg_id));

		let args = tlv.unpack(entry.msg.req ?? {}, dec.tlvs);

		push(self.calls, { service: dec.service, cid: dec.cid, name: entry.name, args: args });
		self.counts[entry.name] = (self.counts[entry.name] ?? 0) + 1;

		let meta = {
			service: dec.service,
			cid: dec.cid,
			name: entry.name,
			count: self.counts[entry.name],
		};

		let handler = self.handlers[sprintf('%d:%s', dec.service, entry.name)]
			?? self.handlers[entry.name];

		// built-in CTL defaults
		if (handler == null && dec.service == 0) {
			switch (entry.name) {
			case 'SYNC':
				handler = {};
				break;

			case 'ALLOCATE_CID':
				handler = (a) => {
					if (self.next_cid > 254)
						self.next_cid = 5;

					return { allocation: { service: a.service, cid: self.next_cid++ } };
				};
				break;

			case 'RELEASE_CID':
				handler = (a) => ({ release: a.release });
				break;
			}
		}

		if (handler == null)
			die(sprintf('mockhub: no handler for %s', entry.name));

		let obj = (type(handler) == 'function') ? handler(args, meta) : handler;

		// handler may return null to swallow the request (timeout testing)
		if (obj != null)
			respond(dec, entry.msg, obj);

		return true;
	};

	self.close = function() {
		self.closed = true;
	};

	// synthesize an indication towards a client
	self.indicate = function(service, cid, name, args) {
		let msg = ind_index[sprintf('%d', service)]?.[name];

		if (!msg)
			die(sprintf('mockhub: unknown indication %s', name));

		let frame = qmux.encode(service, cid, 0, msg.id, tlv.pack(msg.ind, args ?? {}), 'indication');

		uloop.timer(0, () => self.route(qmux.decode(frame)));
	};

	// factory usable as deps.transport_open
	self.transport_open = function(device, cbs) {
		self.device = device;
		self.cbs = cbs;
		self.closed = false;

		return self;
	};

	self.trigger_gone = function() {
		self.close();

		if (self.cbs?.on_gone)
			self.cbs.on_gone(self);
	};

	// calls made for one message name
	self.calls_for = function(name) {
		return filter(self.calls, (c) => c.name == name);
	};

	return self;
}
