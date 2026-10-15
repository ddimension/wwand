// wwand tests — qmi_over_qrtr.uc, the QMI-over-QRTR hub (ddimension/wwand#46),
// over a fake wwand_io: every "socket" is a real pipe so the uloop handles are
// real, its datagrams a queue. Covers the CTL emulation, one socket per
// client (the reason it exists: wwand runs several WDS clients at once), the
// header strip/re-add, stray datagrams, the name server's NEW/DEL_SERVER
// reports, and the node choice / presence probe in discovery.uc.
'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as fs from 'fs';
import * as struct from 'struct';
import * as qrtr from 'wwand/qmi_over_qrtr.uc';
import * as discovery from 'wwand/discovery.uc';
import * as qmux from 'wwand/codec/qmux.uc';
import * as tlv from 'wwand/codec/tlv.uc';
import * as ctlmod from 'wwand/codec/schema/ctl.uc';

uloop.init();

const CTRL_PORT = 0xfffffffe;
const M = ctlmod.default.messages;

// node 5 is the SoC's own (it serves a low-numbered service too, and is listed
// first); node 1 is the modem: it serves DMS. 1071 is a vendor service id.
let servers = [
	{ service: 1, instance: 0, node: 5, port: 99 },
	{ service: 2, instance: 0, node: 1, port: 10 },
	{ service: 1, instance: 0, node: 1, port: 11 },
	{ service: 3, instance: 0, node: 1, port: 12 },
	{ service: 1071, instance: 0, node: 1, port: 13 },
];

let socks = [], fail_open = false;

let fake_io = {
	last_error: () => 'fake failure',
	qrtr_open: () => {
		if (fail_open)
			return null;

		let pp = fs.pipe();
		let s = { r: pp[0], w: pp[1], q: [], sent: [], closed: false };

		s.fileno = () => s.r.fileno();
		s.qsend = (n, p, d) => (push(s.sent, [ n, p, d ]), true);
		s.qread = () => {
			if (!length(s.q))
				return null;

			s.r.read(1);

			return shift(s.q);
		};
		s.qdiscover = (ms) => servers;
		s.close = () => { s.closed = true; };
		push(socks, s);

		return s;
	},
};

let inject = (s, msg) => { push(s.q, msg); s.w.write('x'); s.w.flush(); };
let spin = (ms) => { uloop.timer(ms ?? 20, () => uloop.end()); uloop.run(); };

let got = {};
let client = (service, cid) => {
	let c = { service: service, cid: cid, dispatch: (d) => push(got[sprintf('%d:%d', service, cid)] ??= [], d) };
	return c;
};
let inbox = (service, cid) => got[sprintf('%d:%d', service, cid)] ?? [];

// --- node choice / presence (discovery.uc) ------------------------------------

eq(discovery.qrtr_pick_node(servers), 1, 'pick: the node serving DMS, not the first one listed');
eq(discovery.qrtr_pick_node(servers, 1), 1, 'pick: a wanted node that serves DMS');
eq(discovery.qrtr_pick_node(servers, 5), null, 'pick: a wanted node without DMS is no modem');
eq(discovery.qrtr_pick_node([ servers[0] ]), null, 'pick: no DMS anywhere -> null, not "any node"');
eq(discovery.qrtr_probe(null, { qrtr_servers: (ms) => servers }), 1, 'probe: present once DMS is on the bus');
eq(discovery.qrtr_probe(null, { qrtr_servers: (ms) => [] }), null, 'probe: a modem still booting reads as absent');
eq(discovery.qrtr_probe(null, { qrtr_servers: (ms) => null }), null, 'probe: no qrtr in the kernel reads as absent');

// --- create -------------------------------------------------------------------

eq(qrtr.create({ io: fake_io, node: 5 }), null, 'create: refuses a node without DMS');

let gone = 0;
let hub = qrtr.create({ io: fake_io, on_gone: () => gone++ });
let lookup = socks[length(socks) - 1];

ok(hub != null && hub.node == 1, 'create: on the modem node');

let ctl = client(0, 0);
hub.register(ctl);

let ctl_req = (txn, msg, req) =>
	hub.send(qmux.encode(0, 0, txn, M[msg].id, req ? tlv.pack(M[msg].req, req) : '', 'request'));
let ctl_last = (msg) => {
	let d = inbox(0, 0)[length(inbox(0, 0)) - 1];
	return { msg_id: d?.msg_id, r: tlv.unpack(M[msg].resp, d?.tlvs ?? '') };
};

// --- CTL emulation ------------------------------------------------------------

ctl_req(1, 'GET_VERSION_INFO');
spin();
let vi = ctl_last('GET_VERSION_INFO');
eq(sort(map(vi.r.services ?? [], (s) => s.service)), [ 1, 2, 3 ],
	'ctl: version list = the modem node\'s services, without the vendor id > 255');

let opened = length(socks);
ctl_req(2, 'ALLOCATE_CID', { service: 1 });
spin();
let a1 = ctl_last('ALLOCATE_CID').r.allocation;
ctl_req(3, 'ALLOCATE_CID', { service: 1 });
spin();
let a2 = ctl_last('ALLOCATE_CID').r.allocation;

eq([ a1?.cid, a2?.cid ], [ 1, 2 ], 'ctl: two WDS clients get two cids');
eq(length(socks), opened + 2, 'ctl: ...and a socket each — on the modem they are two clients');

let s1 = socks[opened], s2 = socks[opened + 1];
let w1 = client(1, 1), w2 = client(1, 2);
hub.register(w1);
hub.register(w2);

// --- send: header stripped, from the client's own socket ----------------------

let f1 = qmux.encode(1, 1, 7, 0x0020, '', 'request');
let f2 = qmux.encode(1, 2, 8, 0x0020, '', 'request');
ok(hub.send(f1) && hub.send(f2), 'send: accepted');
eq(s1.sent, [ [ 1, 11, substr(f1, 6) ] ], 'send: cid 1 from its socket, to WDS on the modem node, SDU only');
eq(s2.sent, [ [ 1, 11, substr(f2, 6) ] ], 'send: cid 2 from ITS socket — not the SoC\'s WDS on node 5');
eq(hub.send(qmux.encode(1, 9, 1, 0x0020, '', 'request')), false, 'send: a cid with no socket is refused');

// --- receive: what arrives on a socket belongs to that client -----------------

let sdu = substr(qmux.encode(1, 0, 8, 0x0020, struct.pack('<BHHH', 0x02, 4, 0, 0), 'response'), 6);
inject(s2, { node: 1, port: 11, data: sdu });
spin();
eq([ length(inbox(1, 1)), length(inbox(1, 2)) ], [ 0, 1 ], 'recv: the reply reaches the client whose socket it came in on');
eq([ inbox(1, 2)[0]?.service, inbox(1, 2)[0]?.cid, inbox(1, 2)[0]?.txn ], [ 1, 2, 8 ],
	'recv: re-framed with that client\'s service and cid');

inject(s1, { node: 5, port: 99, data: sdu });
spin();
eq(length(inbox(1, 1)), 0, 'recv: a datagram from another endpoint is dropped');

// --- release / reuse / exhaustion ---------------------------------------------

ctl_req(4, 'RELEASE_CID', { release: { service: 1, cid: 1 } });
spin();
ok(s1.closed && !s2.closed, 'release: only that client\'s socket is closed');

inject(s2, { node: 1, port: 11, data: sdu });
spin();
eq(length(inbox(1, 2)), 2, 'release: the other WDS client still gets its replies');

ctl_req(5, 'ALLOCATE_CID', { service: 1 });
spin();
eq(ctl_last('ALLOCATE_CID').r.allocation?.cid, 1, 'allocate: a released cid is reused, with a fresh socket');

fail_open = true;
ctl_req(6, 'ALLOCATE_CID', { service: 3 });
spin();
let last = inbox(0, 0)[length(inbox(0, 0)) - 1];
let res = tlv.unpack({ r: { t: 0x02, f: { result: 'u16', error: 'u16' } } }, last.tlvs).r;
eq([ res?.result, res?.error ], [ 1, 5 ], 'allocate: no socket -> ClientIdsExhausted, as a real CTL would');
fail_open = false;

ctl_req(7, 'SYNC');
hub.send(qmux.encode(0, 0, 9, 0x00ff, '', 'request'));
spin();
last = inbox(0, 0)[length(inbox(0, 0)) - 1];
res = tlv.unpack({ r: { t: 0x02, f: { result: 'u16', error: 'u16' } } }, last.tlvs).r;
eq([ last.msg_id, res?.error ], [ 0x00ff, 94 ], 'ctl: an unknown request is NotSupported, not a silent success');

// --- the name server's reports -------------------------------------------------

let ctrl = (cmd, svc, node, port) =>
	({ node: 1, port: CTRL_PORT, data: struct.pack('<IIIII', cmd, svc, 0, node, port) });

eq(qrtr.parse_ctrl('short'), null, 'ctrl: a short packet is not a report');

inject(lookup, ctrl(4, 1, 1, 21));
spin();
hub.send(f2);
eq(s2.sent[length(s2.sent) - 1], [ 1, 21, substr(f2, 6) ], 'ctrl: NEW_SERVER moves WDS to its new port');

inject(lookup, ctrl(5, 2, 5, 40));
spin();
eq(gone, 0, 'ctrl: DMS leaving ANOTHER node is not this modem going');

// a service re-registered on a new port before the old one's deletion
// arrives: that deletion is stale and must not drop the live mapping
inject(lookup, ctrl(4, 1, 1, 31));
inject(lookup, ctrl(5, 1, 1, 21));
spin();
hub.send(f2);
eq(s2.sent[length(s2.sent) - 1], [ 1, 31, substr(f2, 6) ], 'ctrl: a DEL_SERVER for an endpoint already superseded is ignored');

inject(lookup, ctrl(5, 2, 1, 10));
spin();
eq(gone, 1, 'ctrl: DMS leaving the modem node is "device gone"');
ok(s2.closed && lookup.closed, 'ctrl: ...and every socket of the hub is closed');
eq(hub.send(f2), false, 'ctrl: a gone hub refuses to send');

// DMS showing up on a NEW port is a restart too, even when that report
// comes before the old port's deletion
let gone2 = 0;
let hub2 = qrtr.create({ io: fake_io, on_gone: () => gone2++ });
let lookup2 = socks[length(socks) - 1];
inject(lookup2, ctrl(4, 2, 1, 50));
spin();
eq(gone2, 1, 'ctrl: DMS re-registered on another port is "device gone"');
inject(lookup2, ctrl(4, 2, 1, 50));
spin();
eq(gone2, 1, 'ctrl: ...reported once, the hub is closed after it');

// presence wants WDS beside DMS: a node caught mid-boot is not a modem yet
eq(discovery.qrtr_pick_node([ { service: 2, node: 1, port: 10 } ]), null,
	'pick: DMS without WDS yet -> not present (the init reads the service list once)');

done('test_qmi_over_qrtr');
