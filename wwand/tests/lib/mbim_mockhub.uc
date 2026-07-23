// wwand tests — MBIM control-channel mock hub.
//
// The MBIM analogue of mockhub.uc (which is QMUX-only). It speaks the real MBIM
// framing (codec/mbim.uc) so modem_mbim + context_mbim exercise the actual
// encode/decode path. Plugged in as deps.transport_open; the modem's on_raw
// handler decodes each delivered frame and feeds mbim_client.on_message.
//
//   let mock = mbim_mockhub.create({ schema: bc, handlers: { ... } });
//   modem = modem_mbim.create({ ..., deps: { transport_open: mock.transport_open } });
//   mock.indicate('CONNECT', { session_id: 0, activation_state: 0 });  // unsolicited
//
// A modem exercising more than one MBIM service (e.g. native cells over the
// MS Basic Connect Extensions service alongside signal over Basic Connect —
// both happen to use CID 11) passes { schemas: [ bc, ext ] } instead of a single
// schema; routing is then keyed by (service uuid, cid). A COMMAND for a service/
// cid no schema knows (e.g. the QMI-passthrough probe) is rejected with a
// non-zero MBIM status rather than aborting the test, so an unsupported
// passthrough candidate simply loses in backend.choose.
//
// Handlers are keyed by command name (e.g. 'CONNECT'). A handler is a static
// response object or fn(args, meta) -> response. Special return values:
//   { __error: <status> }  answer with a non-zero MBIM status (no info buffer)
//   { __raw: <bytes> }     use the bytes verbatim as the InformationBuffer
//                          (needed for array responses like IP_CONFIGURATION,
//                          which encode_info cannot produce — it only ever
//                          encodes request buffers in production)
//   null                   swallow the command (timeout testing)
// OPEN/CLOSE get built-in success answers.

'use strict';

import * as uloop from 'uloop';
import * as struct from 'struct';
import * as mbim from '../wwand/codec/mbim.uc';

// COMMAND_DONE frame: header(12) + fragment(8) + uuid(16) + cid(4) + status(4) +
// infolen(4) + info — mirrors what a real cdc-wdm device sends back.
function done_frame(txn, service, cid, status, ibuf)
{
	ibuf = ibuf ?? '';
	let body = struct.pack('<II', 1, 0) +
		mbim.uuid_bytes(service) +
		struct.pack('<III', cid, status, length(ibuf)) + ibuf;

	return struct.pack('<III', mbim.MSG_COMMAND_DONE, 12 + length(body), txn) + body;
}

// INDICATE_STATUS frame: like COMMAND_DONE but without the status word.
function indicate_frame(service, cid, ibuf)
{
	ibuf = ibuf ?? '';
	let body = struct.pack('<II', 1, 0) +
		mbim.uuid_bytes(service) +
		struct.pack('<II', cid, length(ibuf)) + ibuf;

	return struct.pack('<III', mbim.MSG_INDICATE_STATUS, 12 + length(body), 0) + body;
}

export function create(opts)
{
	let schemas = opts.schemas ?? [ opts.schema ];
	let schema = schemas[0];   // primary: default for indication + response uuid
	let self = {
		handlers: opts?.handlers ?? {},
		calls: [],
		counts: {},
		device: null,
		cbs: null,
		closed: true,
	};

	// (service uuid bytes, cid) -> { name, cmd, schema }. Keying on the service
	// as well as the cid lets two services that reuse a cid (bc SIGNAL_STATE_V2
	// and ext BASE_STATIONS_INFO both use 11) coexist in one mock.
	let by_key = {};
	let route_key = (uuid_bytes, cid) => uuid_bytes + sprintf(':%d', cid);

	for (let sch in schemas)
		for (let name, cmd in sch.commands)
			by_key[route_key(mbim.uuid_bytes(sch.service), cmd.cid)] =
				{ name: name, cmd: cmd, schema: sch };

	let deliver = (frame) => {
		uloop.timer(0, () => {
			if (!self.closed && self.cbs?.on_raw)
				self.cbs.on_raw(self, frame);
		});
	};

	// hub interface used by mbim_client.raw_send
	self.send_raw = function(frame)
	{
		if (self.closed)
			return false;

		let msg_type = struct.unpack('<I', substr(frame, 0, 4))[0];
		let txn = struct.unpack('<I', substr(frame, 8, 4))[0];

		if (msg_type == mbim.MSG_OPEN) {
			deliver(struct.pack('<IIII', mbim.MSG_OPEN_DONE, 16, txn, 0));
			return true;
		}

		if (msg_type == mbim.MSG_CLOSE) {
			deliver(struct.pack('<IIII', mbim.MSG_CLOSE_DONE, 16, txn, 0));
			return true;
		}

		if (msg_type != mbim.MSG_COMMAND)
			die(sprintf('mbim_mockhub: unexpected frame type 0x%08x', msg_type));

		// COMMAND: header(12) + fragment(8) + uuid(16) + cid + cmd_type + infolen
		let uuid = substr(frame, 12 + 8, 16);
		let p = 12 + 8 + 16;
		let cid = struct.unpack('<I', substr(frame, p, 4))[0]; p += 4;
		let cmd_type = struct.unpack('<I', substr(frame, p, 4))[0]; p += 4;
		let ilen = struct.unpack('<I', substr(frame, p, 4))[0]; p += 4;
		let info = substr(frame, p, ilen);

		let entry = by_key[route_key(uuid, cid)];

		// a service/cid no configured schema knows (e.g. the QMI-passthrough
		// probe): answer with a non-zero MBIM status so the caller sees a clean
		// failure instead of the test aborting.
		if (!entry) {
			let body = struct.pack('<II', 1, 0) + uuid +
				struct.pack('<III', cid, 1 /* MBIM_STATUS_FAILURE */, 0);
			deliver(struct.pack('<III', mbim.MSG_COMMAND_DONE, 12 + length(body), txn) + body);
			return true;
		}

		let kind = (cmd_type == mbim.CMD_SET) ? 'set' : 'query';
		let args = mbim.decode_info(entry.cmd[kind] ?? {}, info);

		push(self.calls, { name: entry.name, cid: cid, kind: kind, args: args });
		self.counts[entry.name] = (self.counts[entry.name] ?? 0) + 1;

		let meta = { name: entry.name, cid: cid, kind: kind, count: self.counts[entry.name] };
		let handler = self.handlers[entry.name];

		if (handler == null)
			die(sprintf('mbim_mockhub: no handler for %s', entry.name));

		let obj = (type(handler) == 'function') ? handler(args, meta) : handler;

		// null swallows the command (leaves the client waiting -> timeout)
		if (obj == null)
			return true;

		let status = 0, ibuf = '';

		if (obj.__error != null)
			status = obj.__error;
		else if (obj.__raw != null)
			ibuf = obj.__raw;
		else
			ibuf = mbim.encode_info(entry.cmd.response ?? {}, obj);

		deliver(done_frame(txn, entry.schema.service, cid, status, ibuf));
		return true;
	};

	self.close = function() {
		self.closed = true;
	};

	// synthesize an unsolicited INDICATE_STATUS towards the client
	self.indicate = function(name, args) {
		let sch = schema, cmd = null;

		for (let s in schemas)
			if (s.commands[name]) { sch = s; cmd = s.commands[name]; break; }

		if (!cmd)
			die(sprintf('mbim_mockhub: unknown indication %s', name));

		let ibuf = mbim.encode_info(cmd.notification ?? cmd.response ?? {}, args ?? {});
		deliver(indicate_frame(sch.service, cmd.cid, ibuf));
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

	self.calls_for = function(name) {
		return filter(self.calls, (c) => c.name == name);
	};

	return self;
}
