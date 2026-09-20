// wwand tests — MBIM codec (framing + InformationBuffer).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as struct from 'struct';
import * as mbim from 'wwand/codec/mbim.uc';
import * as bc from 'wwand/codec/mbim_schema/basic_connect.uc';
import * as ext from 'wwand/codec/mbim_schema/ms_basic_connect_ext.uc';
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

// encoding a count+offset array (decode-only in wwand) must fail loudly rather
// than silently emit a corrupt InformationBuffer — for the object-array and the
// ipv4/ipv6-array forms alike.
for (let af in [ { arr: { array: 'n', of: { x: 'u32' } } }, { arr: 'ipv4-array' } ]) {
	let threw = false;
	try { mbim.encode_info(af, { arr: [] }); } catch (ex) { threw = true; }
	ok(threw, sprintf('info: encoding an array field (%s) dies loudly', type(af.arr) == 'object' ? 'obj-array' : af.arr));
}

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

// a modem that accepts every command but never answers CONNECT: leaves an
// attempt in flight so the abort paths can be exercised
function stub_never_answers() {
	let m;
	m = {
		state: 'READY', mbim: {}, contexts: [],
		attach_context: function(c) { push(m.contexts, c); },
		command: function(name, kind, args, cb) {
			if (name == 'CONNECT')
				return;   // never calls back

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

// --- the wire session id follows the datapath, not the config -----------------
//
// A datapath that adopts a driver's own children inherits its numbering; on MBIM
// that number IS the session id. The chain is netlink.setup() -> r.map_ids ->
// modem.datapath.map_ids -> context wire_session() -> every on-wire command. It
// was broken end to end once, because modem_mbim dropped map_ids on the floor
// and nothing exercised it.
{
	let seen = [];
	let mstub;
	mstub = {
		state: 'READY', mbim: {}, contexts: [],
		// what a remapping datapath left behind (SDX7x: channel 1 -> session 113)
		datapath: { backend: 'rmnet_nss_mhi', map_ids: { '1': 113 } },
		attach_context: function(c) { push(mstub.contexts, c); },
		command: function(name, kind, args, cb) {
			if (name == 'CONNECT')
				push(seen, args.session_id);
			return cb({ error: 'mbim', status: 12 });
		},
	};

	let ctx = context_mbim.create({
		name: 'wan', modem: mstub,
		config: { apn: 'internet', mux_id: 1 },
		deps: { on_event: () => null, log: () => null },
	});

	eq(ctx.session_id, 1, 'wire: the CONFIGURED channel stays what the operator wrote');
	eq(ctx.wire_session(), 113, 'wire: ...while the wire id follows the datapath');

	ctx.up(() => null);
	eq(seen, [ 113 ], 'wire: CONNECT is sent with the remapped session id');
	eq(ctx.status().wire_session_id, 113, 'wire: status shows it when it differs');

	// and with no remapping datapath the two are the same, which is every
	// board that exists today
	let plain = context_mbim.create({
		name: 'wan', modem: stub_connect_err([]),
		config: { apn: 'internet', mux_id: 2 },
		deps: { on_event: () => null, log: () => null },
	});
	eq(plain.wire_session(), 2, 'wire: identity without a remap');
	eq(plain.status().wire_session_id, null, 'wire: ...and status does not clutter');
}

// --- an aborted attempt must not take a later one with it ---------------------
//
// `up_cb` is one slot and DEACTIVATE is asynchronous, so every path that ends an
// attempt has to move the generation, not just the state — a new attempt can be
// back in ACTIVATING before an old reply lands.
{
	let ctx = context_mbim.create({
		name: 'wan', modem: stub_connect_err([]),
		config: { apn: 'internet', mux_id: 0 },
		deps: { on_event: () => null, log: () => null },
	});

	// down() while nothing is in flight must still settle cleanly
	let downed = 0;
	ctx.down(() => downed++);
	eq(downed, 1, 'abort: down() on an idle context completes');

	// an up() whose callback is still pending when down() runs must be answered
	// rather than stranded and then overwritten by the next up()
	let first = null, second = null;
	let ctx2 = context_mbim.create({
		name: 'wan', modem: stub_never_answers(),
		config: { apn: 'internet', mux_id: 0 },
		deps: { on_event: () => null, log: () => null },
	});

	ctx2.up((e) => { first = e; });
	ctx2.down(() => null);
	ok(first != null, 'abort: down() completes a pending up() instead of stranding it');

	ctx2.up((e) => { second = e; });
	eq(second, null, 'abort: the next up() has its own callback');
}

// --- a malformed frame is rejected, never thrown on ---------------------------
//
// decode()'s COMMAND_DONE/INDICATE branch used to unpack at fixed offsets with
// no length check while its siblings checked: struct.unpack of a short substr
// returns null, and the [0] on it throws out of the read handler — one bad
// frame from the modem would stop the message loop.
{
	let full = struct.pack('<III', 0x80000003, 48, 7) +   // COMMAND_DONE
		struct.pack('<II', 1, 0) +                        // fragment
		'\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10' +
		struct.pack('<III', 5, 0, 0);                     // cid, status, infolen

	ok(mbim.decode(full) != null, 'decode: a complete COMMAND_DONE still decodes');

	let threw = 0;

	for (let n = 12; n < length(full); n++) {
		try { mbim.decode(substr(full, 0, n)); }
		catch (e) { threw++; }
	}

	eq(threw, 0, 'decode: no truncation of it throws');
	eq(mbim.decode(substr(full, 0, 30)), null, 'decode: a short COMMAND_DONE is rejected');

	// the declared information length is the modem's claim, not a fact
	let liar = substr(full, 0, length(full) - 4) + struct.pack('<I', 9999);
	eq(length(mbim.decode(liar).info), 0, 'decode: an over-long infolen is clamped to what arrived');
}


// --- UTF-16LE <-> UTF-8, both directions -------------------------------------
//
// The decoder used to do `chr(c & 0xff)`, throwing away the high byte of every
// code unit. ASCII survived that, which is why it went unnoticed until a
// non-Latin operator name came back as mojibake in a field report
// (ddimension/wwand#8: `registered: plmn "-\xef\xbf\xbd5"` on a China Mobile
// SIM). The encoder had the mirror defect. ucode's chr() is byte-oriented —
// chr(0x4E2D) is 0xff — so both conversions are hand-rolled and worth pinning.
(function() {
	// ASCII, the case that always worked
	eq(mbim.utf16le_decode(mbim.utf16le_encode('PLAY')), 'PLAY',
		'utf16: ASCII round-trips');

	// Latin-1: one code unit, TWO utf-8 bytes — the old decoder emitted one raw
	// byte here, which is not valid utf-8 and reached ubus as such
	eq(mbim.utf16le_decode(mbim.utf16le_encode('Télé')), 'Télé',
		'utf16: Latin-1 round-trips');

	// BMP beyond Latin-1: the case from the report
	eq(mbim.utf16le_decode(mbim.utf16le_encode('中国移动')), '中国移动',
		'utf16: CJK round-trips');

	// above the BMP: a surrogate PAIR must become one code point, not two
	eq(mbim.utf16le_decode(mbim.utf16le_encode('a😀b')), 'a😀b',
		'utf16: a surrogate pair round-trips as one code point');

	// decode from a hand-built buffer, so this does not merely test the encoder
	// against itself: 4E2D 56FD = 中国, little-endian
	eq(mbim.utf16le_decode(chr(0x2d, 0x4e, 0xfd, 0x56)), '中国',
		'utf16: decode of a hand-built LE buffer');

	// the encoder must produce exactly those bytes
	let enc = mbim.utf16le_encode('中国');
	eq(length(enc), 4, 'utf16: two BMP code points are four bytes');
	eq(ord(enc, 0), 0x2d, 'utf16: low byte first');
	eq(ord(enc, 1), 0x4e, 'utf16: ...then high byte');

	// a NUL terminates, as MBIM strings do
	eq(mbim.utf16le_decode(chr(0x41, 0x00, 0x00, 0x00, 0x42, 0x00)), 'A',
		'utf16: decoding stops at the NUL');
})();


// --- MBIMEx v3: a different structure, not a variant --------------------------
//
// v3 reorders CONNECT's fixed fields, inserts MediaPreference, and carries the
// three strings as TLVs instead of v1's offset/length pairs; SUBSCRIBER_READY_
// STATUS gains a `Flags` u32 after ReadyState, moving SubscriberId and SimIccId
// four bytes along. A modem serving v3 answers the v1 CONNECT with
// MBIM_STATUS_ERROR_INVALID_PARAMETERS (21) and its subscriber strings read as
// empty — both HW-observed on an RM520N-GL (GL-X3000), 2026-09-19, and both
// fixed by speaking v3. Layouts from libmbim 1.32.0
// (mbim-service-ms-basic-connect-v3.json); ModemManager picks between the two
// the same way (mm-bearer-mbim.c).

(function () {
	let b = mbim.encode_connect_v3({
		session_id: 1, activation_command: 1, compression: 0, auth_protocol: 0,
		ip_type: 3, access_string: 'internet.m2mportal.de',
	});
	let hx = '';
	for (let i = 0; i < length(b); i++) hx += sprintf('%02x', ord(b, i));

	// fixed part: SessionId, ActivationCommand, Compression, AuthProtocol,
	// IpType, ContextType(uuid), MediaPreference — then three WCHAR TLVs
	eq(substr(hx, 0, 40), '0100000001000000000000000000000003000000',
		'v3 connect: the five leading u32 in v3 order');
	eq(substr(hx, 40, 32), '7e5e2a7e4e6f7272736b656e7e5e2a7e',
		'v3 connect: the Internet context uuid');
	eq(substr(hx, 72, 8), '00000000', 'v3 connect: MediaPreference (UNKNOWN)');

	// TLV: type 10 (WCHAR_STR) u16, reserved 0, padding 2, data_length 42
	eq(substr(hx, 80, 16), '0a0000022a000000',
		'v3 connect: the access-string TLV header — type, reserved, padding, length');
	eq(length(b), 108, 'v3 connect: 40 fixed + 8+42+2 + two empty TLVs');

	// an empty string is still a TLV, with no data and no padding
	eq(substr(hx, length(hx) - 32), '0a000000000000000a00000000000000',
		'v3 connect: empty user name and password are present as empty TLVs');
})();

// The real SUBSCRIBER_READY_STATUS answer from that RM520N, byte for byte. Read
// with the v1 layout it takes `Flags` for the SubscriberId offset and yields
// nothing — which is exactly what the modem status showed for hours while
// AT+CIMI and the UICC slot query both read the card fine.
(function () {
	let raw = '0100000001000000200000001e0000004000000028000000' +
		'0000000000000000' +
		'390030003100340030003500300030003400340032003700380039003800' + '0000' +
		'38003900380038003200320038003000300030003000310039003200310035003500330030003300';
	let buf = '';
	for (let i = 0; i < length(raw); i += 2)
		buf += chr(hex(substr(raw, i, 2)));

	// through the schema's OWN version selection, not a hand-picked field spec:
	// that is the code path the client takes, and picking the layout here would
	// only prove that RDY_V3 decodes a v3 buffer — which was never in doubt.
	let d = bc.commands.SUBSCRIBER_READY_STATUS.decode(buf, { mbimex_version: 0x0300 });

	eq(d.ready_state, 1, 'v3 subscriber: ready state initialized');
	eq(d.flags, 1, 'v3 subscriber: the Flags field v1 does not have');
	eq(d.subscriber_id, '901405004427898', 'v3 subscriber: the imsi, not an empty string');
	eq(d.sim_iccid, '89882280000192155303', 'v3 subscriber: ...and the iccid');
})();


// --- diagnostic vocabulary ---------------------------------------------------
// The two numbers in every MBIM failure, made readable. Anchored to libmbim
// 1.32.0 src/libmbim-glib/mbim-errors.h; 21 is the one that matters here,
// because that is what an RM520N-GL answers to a v1 CONNECT while serving v3.
eq(mbim.status_name(21), 'InvalidParameters', 'status_name: 21 is InvalidParameters');
eq(mbim.status_name(0), 'None', 'status_name: success has a name too');
eq(mbim.status_name(2), 'Failure', 'status_name: the generic refusal');
eq(mbim.status_name(3), 'SimNotInserted', 'status_name: SIM states are in the table');
// the vendor ranges (0x8743…/0x9100…) are what the UICC low-level access and
// the MS extensions answer — they must survive the decimal-key lookup
eq(mbim.status_name(0x87430001), 'NoLogicalChannels', 'status_name: the MS UICC vendor range');
eq(mbim.status_name(0x91000007), 'DecodeOrParsingError', 'status_name: the MS extension range');
// a code libmbim 1.32.0 does not name must come back null, never a wrong name
eq(mbim.status_name(9999), null, 'status_name: an unnamed code stays unnamed');
eq(mbim.status_name(null), null, 'status_name: and so does no code at all');

eq(mbim.service_name('a289cc33-bcbb-8b4f-b6b0-133ec2aae6df'), 'basic_connect',
	'service_name: basic connect');
eq(mbim.service_name('d1a30bc2-f97a-6e43-bf65-c7e24fb0f0d3'), 'qmi_passthrough',
	'service_name: the QMI tunnel');
eq(mbim.service_name('c2f6588e-f037-4bc9-8665-f4d44bd09367'), 'ms_uicc_low_level',
	'service_name: the eSIM/APDU service');
// addressed by raw UUID from mbim_backend.uc, with no schema file — and the
// first service a real failure named, so the table must not stop at our own
eq(mbim.service_name('533fbeeb-14fe-4467-9f90-33a223e56c3f'), 'sms',
	'service_name: a service we have no schema for is still named');
// an unknown service is precisely where the raw UUID is the useful thing to
// print, so it is returned verbatim rather than swallowed into a '?'
eq(mbim.service_name('00000000-0000-0000-0000-0000000000ff'),
	'00000000-0000-0000-0000-0000000000ff', 'service_name: an unknown service prints its UUID');

// --- and the SAME command in its v1 shape -----------------------------------
//
// The buffer below is a genuine v1 SUBSCRIBER_READY_STATUS: seven u32 of fixed
// part, no Flags. It is hand-built rather than produced by this tree, because a
// buffer written with the same field spec it is then read with proves only that
// the spec is self-consistent.
//
// This is the regression the v3 work introduced and this test exists to hold
// shut: with the v3 field unconditional, the fixed part shifts by four bytes
// and the decode does not fail — it returns the imsi MISSING ITS FIRST DIGIT
// ('62011234567890') and a null iccid. A plausible-looking wrong answer is the
// worst kind, and it would have hit every modem that does not speak MBIMEx v3,
// the EG06 among them.
(function () {
	let raw = '010000001c0000001e0000003c000000280000000000000000000000' +
		'320036003200300031003100320033003400350036003700380039003000' + '0000' +
		'38003900340039003000320030003000300030003100300032003200380033003200340039003000';
	let buf = '';
	for (let i = 0; i < length(raw); i += 2)
		buf += chr(hex(substr(raw, i, 2)));

	// mbimex_version 0 = a modem that refused the handshake, or was never asked
	let d = bc.commands.SUBSCRIBER_READY_STATUS.decode(buf, { mbimex_version: 0 });

	eq(d.ready_state, 1, 'v1 subscriber: ready state initialized');
	eq(d.flags, null, 'v1 subscriber: no Flags field is invented');
	eq(d.subscriber_id, '262011234567890',
		'v1 subscriber: the WHOLE imsi, not one digit short');
	eq(d.sim_iccid, '89490200001022832490', 'v1 subscriber: and the iccid');
})();

// --- v3 strings are UTF-16, not widened bytes -------------------------------
//
// ucode strings are UTF-8 byte strings, so a byte-wise widen turns 'ä' (c3 a4)
// into U+00C3 U+00A4 — two wrong characters of the right length, which ASCII
// test data can never reveal. Credentials are the realistic case: an APN is
// ASCII in practice, a password is not.
(function () {
	let buf = mbim.encode_connect_v3({ access_string: 'ä' });
	let hx = '';
	for (let i = 0; i < length(buf); i++)
		hx += sprintf('%02x', ord(buf, i));

	// the access-string TLV follows the fixed part (5 u32 + uuid + u32 = 40)
	let tlv = substr(hx, 40 * 2, 12 * 2);

	eq(tlv, '0a00000202000000e4000000',
		'v3 strings: U+00E4 encodes as e4 00, padded to four bytes');
})();

// --- a v3 modem gets v3 for the WHOLE session -------------------------------
//
// The first cut branched only the activation. The deactivate kept sending the
// v1 CONNECT, which a v3 modem answers with INVALID_PARAMETERS — and because
// the teardown is best-effort, the context would have reported itself down
// while the modem still held the bearer. Both directions go through the same
// sender now, and both name themselves for the log (otherwise the one failure
// the named logging was built for would print as 'basic_connect/cid 12').
(function () {
	let raws = [], v1s = [];
	let m;

	m = {
		state: 'READY',
		mbim: {
			mbimex_version: 0x0300,
			command_raw: (svc, cid, info, cb, opts) => {
				push(raws, { cid: cid, info: info, name: opts?.name });
				// answer as the modem does: activated, session 0
				cb(null, mbim.encode_info(bc.commands.CONNECT.response,
					{ session_id: 0, activation_state: bc.ACTIVATION_ACTIVATED,
					  voice_call_state: 0, ip_type: 1,
					  context_type: '7e5e2a7e-4e6f-7272-736b-656e7e5e2a7e', nw_error: 0 }));
			},
		},
		contexts: [],
		attach_context: function(c) { push(m.contexts, c); },
		command: function(name, kind, args, cb) {
			if (name == 'CONNECT')
				push(v1s, args.activation_command);

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

	let c3 = context_mbim.create({
		name: 'wan', modem: m,
		config: { apn: 'internet', mux_id: 0 },
		deps: { on_event: () => null, log: () => null },
	});

	c3.up(() => null);
	eq(c3.state, 'CONNECTED', 'v3 session: comes up');
	eq(length(raws), 1, 'v3 session: the activation went out as a v3 buffer');
	eq(raws[0]?.name, 'CONNECT',
		'v3 session: ...and names itself, so a failure does not log "cid 12"');

	c3.down(() => null);

	eq(length(v1s), 0, 'v3 session: no CONNECT took the v1 path at all');
	eq(length(raws), 2, 'v3 session: the teardown is a v3 buffer too');
	// activation_command is the second u32 of the v3 fixed part
	eq(struct.unpack('<I', substr(raws[1]?.info ?? '', 4, 4))[0],
		bc.ACTIVATION_CMD_DEACTIVATE, 'v3 session: and it really is a DEACTIVATE');
})();

// --- the MBIMEx additions, off the wire -------------------------------------
//
// Hand-built buffers throughout: a buffer produced with the same spec it is
// then read with only proves the spec is self-consistent. Layouts checked
// against libmbim 1.32.0 (mbim-service-ms-basic-connect-v3.json and
// -extensions-v3.json), 2026-09-20.
(function () {
	let hex2buf = (raw) => {
		let b = '';
		for (let i = 0; i < length(raw); i += 2)
			b += chr(hex(substr(raw, i, 2)));
		return b;
	};

	// PACKET SERVICE. The three MBIMEx fields are APPENDED, so ONE layout has
	// to read both generations — that is the claim under test, and it is only
	// worth anything if both buffers go through the same spec.
	let ps3 = mbim.decode_info(bc.commands.PACKET_SERVICE.response, hex2buf(
		'00000000020000000080000080d1f0080000000000ca9a3b00000000' +
		'0100000002000000' + '060101002c1b0000'));

	eq(ps3.packet_service_state, 2, 'ps v3: the v1 fields still read');
	eq(ps3.downlink_speed, 1000000000, 'ps v3: ...including the u64s');
	eq(ps3.frequency_range, 1, 'ps v3: FR1');
	eq(ps3.data_subclass, 2, 'ps v3: data subclass 5G_NR — NSA vs SA, stated');
	eq(ps3.tai_mcc, 262, 'ps v3: the TAI plmn (u16, which the codec had to learn)');
	eq(ps3.tai_mnc, 1, 'ps v3: ...mnc');
	eq(ps3.tai_tac, 0x1b2c, 'ps v3: ...and the tracking area code');

	// the same spec against a v1 modem, which stops after DownlinkSpeed
	let ps1 = mbim.decode_info(bc.commands.PACKET_SERVICE.response, hex2buf(
		'00000000020000000080000080d1f0080000000000ca9a3b00000000'));

	eq(ps1.packet_service_state, 2, 'ps v1: reads with the same layout');
	eq(ps1.downlink_speed, 1000000000, 'ps v1: ...to the end of what it sent');
	eq(ps1.frequency_range, null, 'ps v1: absent means null, not zero');
	eq(ps1.data_subclass, null, 'ps v1: ...and not a fabricated subclass');
	eq(ps1.tai_mcc, null, 'ps v1: ...nor a fabricated TAI');

	// REGISTER STATE: PreferredDataClasses is the v2 append. Same argument.
	// fixed part is 52 bytes: 5 u32, three offset/length pairs, then
	// RegistrationFlag and the v2 PreferredDataClasses
	let rs = mbim.decode_info(bc.commands.REGISTER_STATE.response, hex2buf(
		'00000000' + '01000000' + '01000000' + '00800000' + '01000000' +
		'340000000a000000' + '3e00000014000000' + '0000000000000000' +
		'00000000' + '00800000' +
		'320036003200300031002e006400650000000000' +
		'540065006c0065006b006f006d002e0064006500'));

	eq(rs.register_state, 1, 'rs: the v1 fields read');
	eq(rs.provider_id, '26201', 'rs: ...and the strings still resolve');
	eq(rs.preferred_data_classes, 0x8000, 'rs: the v2 append is picked up');
})();

// --- the layouts that are SELECTED, not appended -----------------------------
//
// These are the dangerous ones: v3 INSERTS a field, so the fixed part shifts
// and every string offset after it moves. A wrong choice here does not fail, it
// returns a plausible APN or none at all — the same shape as the bug that made
// the RM520N-GL unreachable. Both directions are asserted, because getting one
// right and the other wrong is exactly what happened before.
(function () {
	let hex2buf = (raw) => {
		let b = '';
		for (let i = 0; i < length(raw); i += 2)
			b += chr(hex(substr(raw, i, 2)));
		return b;
	};

	// v1: LteAttachState, IpType, 3 strings, Compression, AuthProtocol.
	// Fixed part 40 bytes, so the APN sits at offset 0x28.
	let a1 = hex2buf('01000000' + '01000000' +
		'2800000010000000' + '0000000000000000' + '0000000000000000' +
		'00000000' + '00000000' +
		'69006e007400650072006e0065007400');

	// v3: NwError 33 (requested service option not subscribed) INSERTED after
	// the state, so the fixed part is 44 and the APN moves to 0x2c
	let a3 = hex2buf('01000000' + '21000000' + '01000000' +
		'2c00000010000000' + '0000000000000000' + '0000000000000000' +
		'00000000' + '00000000' +
		'69006e007400650072006e0065007400');

	let v1 = { mbimex_version: 0 }, v3 = { mbimex_version: 0x0300 };
	let dec = ext.commands.LTE_ATTACH_INFO.decode;

	eq(dec(a1, v1).access_string, 'internet', 'attach v1: the apn reads');
	eq(dec(a1, v1).nw_error, null, 'attach v1: no cause field is invented');
	eq(dec(a3, v3).access_string, 'internet', 'attach v3: the apn reads too');
	eq(dec(a3, v3).nw_error, 33, 'attach v3: ...and the cause comes with it');

	// THE COUNTERPROOF THE CODE EXISTS FOR: cross the buffers and the decode
	// does not fail, it lies. Reading a v1 answer as v3 takes IpType for the
	// cause and the APN offset for the ip type.
	let wrong = dec(a1, v3);

	eq(wrong.nw_error, 1, 'attach: a v1 buffer read as v3 reports IpType as a reject cause');
	ok(wrong.access_string != 'internet',
		'attach: ...and the apn is not the apn (this is why the layout is selected)');
})();

// --- the two v3-only diagnostics --------------------------------------------
(function () {
	let hex2buf = (raw) => {
		let b = '';
		for (let i = 0; i < length(raw); i += 2)
			b += chr(hex(substr(raw, i, 2)));
		return b;
	};

	// Modem Configuration: status u32, then the name as a WCHAR_STR TLV — not
	// an offset/length string, which is why this needs TLV DEcoding and the
	// codec only had TLV encoding.
	let mc = ext.commands.MODEM_CONFIGURATION.decode(hex2buf(
		'02000000' + '0a0000021e000000' +
		'52004f0057005f00470065006e0065007200690063005f0033005f004700' + '0000'));

	eq(mc.configuration_status, 2, 'modem config: status (2 = completed)');
	eq(ext.MODEM_CONFIG_STATUS['2'], 'completed', 'modem config: ...with a name');
	eq(mc.configuration_name, 'ROW_Generic_3_G', 'modem config: the carrier profile');

	// Wake Reason: WakeType, SessionId, one TLV whose meaning follows the type
	let wr = ext.commands.WAKE_REASON.decode(hex2buf(
		'01000000' + '00000000' + '0900000008000000' + '0601010005000000'));

	eq(wr.wake_type, 1, 'wake reason: type');
	eq(ext.WAKE_TYPE['1'], 'cid indication', 'wake reason: ...named');
	eq(wr.wake_tlv_type, 9, 'wake reason: the trailing TLV is identified (TAI)');
	eq(wr.wake_tlv_len, 8, 'wake reason: ...and its payload measured, not guessed at');

	// a TLV area that claims more than it carries must end the walk, not throw
	eq(length(mbim.decode_tlvs(hex2buf('0a000002ff000000' + '4100'), 0)), 0,
		'tlv: a truncated header yields nothing rather than reading past the end');

	// PADDING IS ON THE WIRE BUT NOT IN data_length, and only a SECOND TLV can
	// prove the walk skips it: with one TLV the pad sits at the end where
	// ignoring it costs nothing. Here the first payload is 6 bytes with 2 of
	// padding, so a decoder that adds only data_length starts the next header
	// two bytes early and reads rubbish.
	let two = mbim.decode_tlvs(hex2buf(
		'0a00000206000000' + '610062006300' + '0000' +
		'0a00000004000000' + '7a007a00'), 0);

	eq(length(two), 2, 'tlv: both TLVs are found across the padding');
	eq(mbim.tlv_string([ two[0] ]), 'abc', 'tlv: ...the first reads');
	eq(mbim.tlv_string([ two[1] ]), 'zz', 'tlv: ...and so does the one behind the pad');
})();

// --- extended Device Caps (CID 6): reordered AND part-TLV in v3 -------------
//
// The nastiest of the version splits. v3 inserts DataSubclass as a guint64
// (it is a guint32 in Packet Service — the same name at two widths), moves
// ExecutorIndex and the band classes ahead of the strings, and turns everything
// from LteBandClass on into TLVs. The v1 layout sat here unconditionally and
// was harmless only because nothing called it.
(function () {
	let hex2buf = (raw) => {
		let b = '';
		for (let i = 0; i < length(raw); i += 2)
			b += chr(hex(substr(raw, i, 2)));
		return b;
	};

	let fixed = '01000000' + '01000000' + '00000000' + '02000000' +
		'3f000080' + '03000000' + '01000000' +     /* … ControlCaps */
		'0100000000000000' +                        /* DataSubclass, u64 */
		'0f000000' + '00000000' + '00010000';       /* MaxSessions, Executor, Wcdma */
	let tlvs = '0b00000004000000' + '03001400' +    /* LteBandClass table */
		'0b00000004000000' + '4e000100' +           /* NrBandClass table */
		'0a0000000c000000' + '350047002f005400440053' + '00' +
		'0a0000021e000000' + '3300350039003000370032003000360030003000300030003000300030' + '000000' +
		'0a00000010000000' + '52004d003500320030004e0047004c00' +
		'0a00000212000000' + '52004d003500320030004e002d0047004c00' + '0000';

	let d = ext.commands.DEVICE_CAPS.decode(hex2buf(fixed + tlvs),
		{ mbimex_version: 0x0300 });

	eq(d.max_sessions, 15, 'caps v3: MaxSessions reads — it sits AFTER the u64');
	eq(d.data_subclass, 1, 'caps v3: DataSubclass is a u64 here, not a u32');
	eq(d.lte_band_class, [ 3, 20 ], 'caps v3: the band table is a uint16 TLV');
	eq(d.nr_band_class, [ 78, 1 ], 'caps v3: ...and so is the NR one');
	eq(d.device_id, '359072060000000', 'caps v3: the strings are TLVs, not offset/length');
	eq(d.hardware_info, 'RM520N-GL', 'caps v3: ...to the last of them');

	// THE DISCRIMINATOR: the same bytes read as v1 must not quietly produce a
	// plausible answer. v1 expects MaxSessions where v3 has the low half of
	// DataSubclass, and offset/length strings where v3 has TLVs.
	let v1 = ext.commands.DEVICE_CAPS.decode(hex2buf(fixed + tlvs),
		{ mbimex_version: 0 });

	ok(v1.max_sessions != 15, 'caps v3: read as v1 the session count is wrong');
	ok(v1.device_id != '359072060000000', 'caps v3: ...and the IMEI is not the IMEI');

	// A TRUNCATED TLV RUN STOPS, it does not shift. Drop the two band tables
	// and the strings land at positions the walk checks the type of.
	let short = ext.commands.DEVICE_CAPS.decode(hex2buf(fixed +
		'0a00000212000000' + '52004d003500320030004e002d0047004c00' + '0000'),
		{ mbimex_version: 0x0300 });

	eq(short.lte_band_class, null, 'caps v3: a wrong type at position 0 ends the walk');
	// the discriminator against the type-FILTERING version this replaced: it
	// would have found the lone WCHAR_STR and put it in custom_data_class
	eq(short.custom_data_class, null,
		'caps v3: ...and does not collect the string by type from a later slot');
	eq(short.device_id, null, 'caps v3: ...rather than shifting a string into the IMEI');
	eq(short.max_sessions, 15, 'caps v3: the fixed part still decodes');
})();

// --- a TLV that claims padding it does not carry is truncated ----------------
//
// libmbim sizes a record as header + data_length + padding_length and refuses
// to read one the buffer cannot hold in full (mbim-tlv.c:150-160, 1.32.0).
// Checking only data_length accepted this as a complete zero-length TLV.
eq(length(mbim.decode_tlvs('\x0a\x00\x00\xff\x00\x00\x00\x00', 0)), 0,
	'tlv: a header claiming absent padding is a truncated record');

done('test_mbim');
