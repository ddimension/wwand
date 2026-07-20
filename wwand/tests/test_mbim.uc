// wwand tests — MBIM codec (framing + InformationBuffer).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as mbim from 'wwand/codec/mbim.uc';
import * as bc from 'wwand/codec/mbim-schema/basic_connect.uc';

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
	// fixed part layout of IP_CONFIGURATION.response, offsets relative to info
	// scalars: session_id, v4avail, v6avail, v4count, [v4addr off/count],
	//   v6count, [v6addr off/count], [v4gw ref], [v6gw ref],
	//   v4dnscount, [v4dns off/size], v6dnscount, [v6dns off/size], v4mtu, v6mtu
	// We place the data buffer after the fixed part and fill matching offsets.
	let fixedlen = 4*3 + 4 + 8 + 4 + 8 + 4 + 4 + 4 + 8 + 4 + 8 + 4 + 4; // = 76
	let db = fixedlen;
	// v4 address element: prefix(4) + ipv4(4)
	let v4addr_off = db;
	let v4addr = p32(30) + chr(10,11,12,13);
	// gateway
	let gw_off = v4addr_off + length(v4addr);
	let gw = chr(10,11,12,14);
	// dns array: 2 x ipv4
	let dns_off = gw_off + length(gw);
	let dns = chr(8,8,8,8) + chr(8,8,4,4);

	let fixed =
		p32(0) +            // session_id
		p32(1) + p32(0) +   // v4 avail, v6 avail
		p32(1) +            // v4 count
		p32(v4addr_off) + p32(1) +   // v4 addr off + count
		p32(0) +            // v6 count
		p32(0) + p32(0) +   // v6 addr off/count
		p32(gw_off) +       // v4 gw ref
		p32(0) +            // v6 gw ref
		p32(2) +            // v4 dns count
		p32(dns_off) + p32(8) +   // v4 dns off + size(bytes)
		p32(0) +            // v6 dns count
		p32(0) + p32(0) +   // v6 dns off/size
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


done('test_mbim');
