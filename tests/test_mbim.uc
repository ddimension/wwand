// wwand tests — MBIM codec (framing + InformationBuffer).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as mbim from 'wwand/codec/mbim.uc';
import * as bc from 'wwand/codec/mbim-schema/basic_connect.uc';
import * as context_mbim from 'wwand/context_mbim.uc';

function p32(v) {
	return chr(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff);
}
function ord4(f, p) {
	return ord(f, p) | (ord(f, p+1) << 8) | (ord(f, p+2) << 16) | (ord(f, p+3) << 24);
}

function build_done(txn, uuid, cid, status, ibuf) {
	let body = "\x01\x00\x00\x00\x00\x00\x00\x00" +   // fragment total=1 cur=0
		mbim.uuid_bytes(uuid) + p32(cid) + p32(status) + p32(length(ibuf)) + ibuf;
	return p32(mbim.MSG_COMMAND_DONE) + p32(12 + length(body)) + p32(txn) + body;
}

function build_ipcfg() {
	// real MBIM_IP_CONFIGURATION_INFO: 15 u32 in the fixed part — each array is a
	// separate Count field plus a 4-byte Offset (NOT an inline offset+count
	// pair) — then the data buffer with the elements at those offsets.
	let fixedlen = 4 * 15;   // 60
	let v4addr_off = fixedlen;
	let v4addr = p32(30) + chr(10,11,12,13);   // OnLinkPrefixLength + IPv4
	let gw_off = v4addr_off + length(v4addr);
	let gw = chr(10,11,12,14);
	let dns_off = gw_off + length(gw);
	let dns = chr(8,8,8,8) + chr(8,8,4,4);     // 2 x IPv4 DNS

	let fixed =
		p32(0) +            // session_id
		p32(1) + p32(0) +   // v4 avail, v6 avail
		p32(1) +            // v4 count
		p32(v4addr_off) +   // v4 addr OFFSET (count is the field above)
		p32(0) +            // v6 count
		p32(0) +            // v6 addr offset
		p32(gw_off) +       // v4 gw ref
		p32(0) +            // v6 gw ref
		p32(2) +            // v4 dns count
		p32(dns_off) +      // v4 dns OFFSET (count is the field above)
		p32(0) +            // v6 dns count
		p32(0) +            // v6 dns offset
		p32(1500) + p32(0); // v4 mtu, v6 mtu

	return fixed + v4addr + gw + dns;
}

// --- uuid --------------------------------------------------------------------

let u = mbim.uuid_bytes(bc.service);
eq(length(u), 16, 'uuid: 16 bytes');
eq(hexenc(u), 'a289cc33bcbb8b4fb6b0133ec2aae6df', 'uuid: byte order verbatim');

// --- command framing ---------------------------------------------------------

let info = mbim.encode_info(bc.commands.CONNECT.set, {
	session_id: 0,
	activation_command: bc.ACTIVATION_CMD_ACTIVATE,
	access_string: 'internet',
	compression: 0,
	auth_protocol: bc.AUTH_NONE,
	ip_type: bc.IP_TYPE_IPV4V6,
	context_type: bc.CONTEXT_TYPE_INTERNET,
});

let frame = mbim.encode_command(7, bc.service, bc.commands.CONNECT.cid,
	mbim.CMD_SET, info);

eq(ord4(frame, 0), mbim.MSG_COMMAND, 'frame: command type');
eq(ord4(frame, 8), 7, 'frame: txn');
eq(ord4(frame, 4), length(frame), 'frame: length matches');

// --- info buffer round-trip (scalars + string) -------------------------------

let round = mbim.decode_info(bc.commands.CONNECT.set, info);
eq(round.session_id, 0, 'info: session id');
eq(round.access_string, 'internet', 'info: string decoded (utf16le)');
eq(round.ip_type, bc.IP_TYPE_IPV4V6, 'info: ip type');
eq(round.context_type, bc.CONTEXT_TYPE_INTERNET, 'info: uuid field');
eq(round.auth_protocol, 0, 'info: auth');

// empty string encodes as 0/0
let e = mbim.encode_info({ a: 'u32', s: 'string' }, { a: 5 });
let ed = mbim.decode_info({ a: 'u32', s: 'string' }, e);
eq(ed.a, 5, 'info: scalar before empty string');
eq(ed.s, null, 'info: empty string decodes null');

// --- COMMAND_DONE decode with synthesized response ---------------------------

// build a Subscriber Ready Status response info buffer and wrap it in a DONE
let ready_info = mbim.encode_info(bc.commands.SUBSCRIBER_READY_STATUS.response, {
	ready_state: bc.READY_STATE_INITIALIZED,
	subscriber_id: '262011234567890',
	sim_iccid: '89490200001022832490',
	ready_info: 0,
	telephone_numbers_count: 0,
});

let done_frame = build_done(9, bc.service, bc.commands.SUBSCRIBER_READY_STATUS.cid, 0, ready_info);
let dec = mbim.decode(done_frame);
eq(dec.type, mbim.MSG_COMMAND_DONE, 'done: type');
eq(dec.txn, 9, 'done: txn');
eq(dec.service, bc.service, 'done: service uuid');
eq(dec.cid, 2, 'done: cid');
eq(dec.status, 0, 'done: status success');

let ready = mbim.decode_info(bc.commands.SUBSCRIBER_READY_STATUS.response, dec.info);
eq(ready.ready_state, 1, 'ready: state initialized');
eq(ready.subscriber_id, '262011234567890', 'ready: imsi');
eq(ready.sim_iccid, '89490200001022832490', 'ready: iccid');


// --- IP configuration decode (struct arrays + ref + arrays) ------------------

// hand-build an IP_CONFIGURATION response: 1 IPv4 addr /30, gateway, 2 DNS
let ipcfg = build_ipcfg();
let cfg = mbim.decode_info(bc.commands.IP_CONFIGURATION.response, ipcfg);
eq(cfg.ipv4_available, 1, 'ipcfg: v4 available');
eq(cfg.ipv4_count, 1, 'ipcfg: one v4 address');
eq(cfg.ipv4_addresses[0].address, '10.11.12.13', 'ipcfg: v4 addr');
eq(cfg.ipv4_addresses[0].prefix, 30, 'ipcfg: v4 prefix');
eq(cfg.ipv4_gateway, '10.11.12.14', 'ipcfg: v4 gateway (ref)');
eq(cfg.ipv4_dns, [ '8.8.8.8', '8.8.4.4' ], 'ipcfg: v4 dns array');
eq(cfg.ipv4_mtu, 1500, 'ipcfg: mtu');


// --- lazy-load path ----------------------------------------------------------
// daemon.uc pulls MBIM in via require(), which compiles plain scripts where
// `export` is a syntax error — it must go through the exportless mbim_lazy
// wrapper. Regression: require()ing the ES modules directly crashed the
// daemon the moment a real MBIM modem enumerated (RG502Q on cdc_mbim).
let lazy = require('wwand.mbim_lazy');
ok(type(lazy?.modem?.create) == 'function', 'lazy: modem_mbim loadable via require');
ok(type(lazy?.context?.create) == 'function', 'lazy: context_mbim loadable via require');


// --- unsolicited CONNECT indication: network-side session loss --------------
// The MBIM analogue of QMI's PACKET_SERVICE_STATUS_IND. On cdc_mbim the netdev
// carrier does not follow the session, so this indication is the only signal
// that a live data session dropped — it must tear the context down.

function stub_mbim_modem() {
	let m;
	m = {
		state: 'READY',
		mbim: {},
		contexts: [],
		attach_context: function(c) { push(m.contexts, c); },
		command: function(name, kind, args, cb) {
			if (name == 'CONNECT' && args.activation_command == bc.ACTIVATION_CMD_ACTIVATE)
				return cb(null, { session_id: args.session_id,
				                  activation_state: bc.ACTIVATION_ACTIVATED });
			if (name == 'CONNECT')
				return cb(null, {});   // deactivate
			if (name == 'IP_CONFIGURATION')
				return cb(null, {
					ipv4_available: 1, ipv4_count: 1,
					ipv4_addresses: [ { address: '10.0.0.5', prefix: 30 } ],
					ipv4_gateway: '10.0.0.6', ipv4_dns: [ '1.1.1.1' ], ipv4_mtu: 1500,
					ipv6_available: 0, ipv6_addresses: [],
				});
			return cb(null, {});
		},
	};
	return m;
}

let mev = [];
let mctx = context_mbim.create({
	name: 'wan', modem: stub_mbim_modem(),
	config: { apn: 'internet', mux_id: 0 },
	deps: { on_event: (c, e, d) => push(mev, { e: e, d: d }), log: () => null },
});

let up_err;
mctx.up((e) => { up_err = e; });
eq(up_err, null, 'connect-ind: up succeeds');
eq(mctx.state, 'CONNECTED', 'connect-ind: reaches CONNECTED');
eq(mctx.session_id, 0, 'connect-ind: session 0');

// an ACTIVATED indication while connected is a no-op (still up)
mctx.connect_indication({ session_id: 0, activation_state: bc.ACTIVATION_ACTIVATED });
eq(mctx.state, 'CONNECTED', 'connect-ind: activated ind keeps CONNECTED');

// a DEACTIVATED indication tears the session down and reports it as a transient
// disconnect (same reason QMI uses -> same daemon reconnect-in-place path)
mctx.connect_indication({ session_id: 0, activation_state: bc.ACTIVATION_DEACTIVATED, nw_error: 0 });
eq(mctx.state, 'IDLE', 'connect-ind: deactivate ind -> IDLE');
let last = mev[length(mev) - 1];
eq(last.e, 'down', 'connect-ind: emits down');
eq(last.d.reason, 'disconnected', 'connect-ind: reason disconnected');

// a stray indication while already IDLE must not re-emit
let n = length(mev);
mctx.connect_indication({ session_id: 0, activation_state: bc.ACTIVATION_DEACTIVATED });
eq(length(mev), n, 'connect-ind: ignored when not CONNECTED');


// --- deactivate-before-retry ------------------------------------------------
// A failure *after* CONNECT activated the session must DEACTIVATE before the
// context reports failure — otherwise the daemon's retry issues a fresh CONNECT
// and the modem answers MBIM status 13 (max activated contexts).

function stub_fail_modem(rec) {
	let m;
	m = {
		state: 'READY',
		mbim: {},
		contexts: [],
		attach_context: function(c) { push(m.contexts, c); },
		command: function(name, kind, args, cb) {
			if (name == 'CONNECT')
				push(rec, args.activation_command);
			if (name == 'CONNECT' && args.activation_command == bc.ACTIVATION_CMD_ACTIVATE)
				return cb(null, { session_id: args.session_id,
				                  activation_state: bc.ACTIVATION_ACTIVATED });
			if (name == 'CONNECT')
				return cb(null, {});   // deactivate ack
			if (name == 'IP_CONFIGURATION')
				return cb({ error: 'mbim', status: 99 });   // fail after activation
			return cb(null, {});
		},
	};
	return m;
}

let recmds = [];
let fctx = context_mbim.create({
	name: 'wan', modem: stub_fail_modem(recmds),
	config: { apn: 'internet', mux_id: 0 },
	deps: { on_event: () => null, log: () => null },
});

let ferr;
fctx.up((e) => { ferr = e; });
ok(ferr != null, 'deactivate-retry: up fails at ip_config');
eq(fctx.state, 'IDLE', 'deactivate-retry: back to IDLE');
eq(recmds[0], bc.ACTIVATION_CMD_ACTIVATE, 'deactivate-retry: activated first');
eq(recmds[length(recmds) - 1], bc.ACTIVATION_CMD_DEACTIVATE,
	'deactivate-retry: deactivated after failure');

// a failure *before* activation (CONNECT itself errors) must NOT deactivate
function stub_connect_err(rec) {
	let m;
	m = {
		state: 'READY', mbim: {}, contexts: [],
		attach_context: function(c) { push(m.contexts, c); },
		command: function(name, kind, args, cb) {
			if (name == 'CONNECT')
				push(rec, args.activation_command);
			if (name == 'CONNECT')
				return cb({ error: 'mbim', status: 12 });   // CONNECT fails outright
			return cb(null, {});
		},
	};
	return m;
}

let recmds2 = [];
let fctx2 = context_mbim.create({
	name: 'wan', modem: stub_connect_err(recmds2),
	config: { apn: 'internet', mux_id: 0 },
	deps: { on_event: () => null, log: () => null },
});
fctx2.up(() => null);
eq(length(recmds2), 1, 'deactivate-retry: no deactivate when CONNECT never activated');

done('test_mbim');
