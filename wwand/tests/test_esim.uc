// wwand tests — ES10c building blocks of the optional eSIM module: BER-TLV
// parser/builder, ICCID coding and the ProfileInfoList decode (pure, no I/O).
'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as sim from 'wwand/sim.uc';

let esim = require('wwand.esim');

ok(type(esim) == 'object', 'esim: module loads via require()');

// --- BER build/parse roundtrip ----------------------------------------------

let req = esim._ber_build(0xbf31, [
	...esim._ber_build(0x5a, [ 0x98, 0x94, 0x20 ]),
	...esim._ber_build(0x01, [ 0xff ]),
]);

eq(req[0], 0xbf, 'ber: two-byte tag hi');
eq(req[1], 0x31, 'ber: two-byte tag lo');
eq(req[2], 8, 'ber: outer length');

let tlvs = esim._ber_parse(req);
eq(length(tlvs), 1, 'ber: one outer tlv');
eq(tlvs[0].tag, 0xbf31, 'ber: parsed tag');

let inner = esim._ber_parse(tlvs[0].val);
eq(inner[0].tag, 0x5a, 'ber: inner iccid tag');
eq(inner[1].tag, 0x01, 'ber: inner boolean tag');
eq(inner[1].val, [ 0xff ], 'ber: refresh flag value');

// long-form length (0x81)
let big = [];
for (let i = 0; i < 200; i++) push(big, 0x42);
big = esim._ber_build(0xe3, big);
eq(big[1], 0x81, 'ber: long form length marker');
eq(big[2], 200, 'ber: long form length');
eq(esim._ber_parse(big)[0].tag, 0xe3, 'ber: long form parses');
eq(length(esim._ber_parse(big)[0].val), 200, 'ber: long form value length');

// --- ICCID coding ------------------------------------------------------------

let er = esim._iccid_request(0xbf31, '8949020000102283249', true);
let ei = esim._ber_parse(esim._ber_parse(er)[0].val);
eq(ei[0].tag, 0x5a, 'iccid: choice tag');
eq(ei[0].val[0], 0x98, 'iccid: nibble-swapped first byte');
eq(esim._bytes_to_iccid(ei[0].val), '8949020000102283249', 'iccid: roundtrip');

// --- ProfileInfoList decode --------------------------------------------------

// BF2D { A0 { E3 { 5A iccid, 9F70 01, 91 "TestNet", 92 "prof" } } }
let profile = [
	...esim._ber_build(0x5a, [ 0x98, 0x94, 0x20 ]),
	...esim._ber_build(0x9f70, [ 0x01 ]),
	...esim._ber_build(0x91, [ 0x54, 0x65, 0x73, 0x74, 0x4e, 0x65, 0x74 ]),
	...esim._ber_build(0x92, [ 0x70, 0x72, 0x6f, 0x66 ]),
];
let list = esim._ber_build(0xbf2d, esim._ber_build(0xa0, esim._ber_build(0xe3, profile)));

let profs = esim._parse_profiles(esim._ber_parse(list));
eq(length(profs), 1, 'profiles: one entry');
eq(profs[0].iccid, '894902', 'profiles: iccid decoded');
eq(profs[0].state, 'enabled', 'profiles: state');
eq(profs[0].provider, 'TestNet', 'profiles: provider name');
eq(profs[0].name, 'prof', 'profiles: profile name');

// --- vendor AT+QESIM line parser --------------------------------------------

let f1 = esim._qesim_fields('+QESIM: "profile_detail",89358152000000075749,0,"","Telit","Telit",2');
eq(f1[0], '89358152000000075749', 'qesim: iccid field');
eq(f1[1], '0', 'qesim: state field');
eq(f1[2], '', 'qesim: empty quoted nickname');
eq(f1[3], 'Telit', 'qesim: provider field');
eq(f1[4], 'Telit', 'qesim: name field');
eq(f1[5], '2', 'qesim: class field');

let f2 = esim._qesim_fields('+QESIM: "eid",89033023426300000000041811587764');
eq(f2[0], '89033023426300000000041811587764', 'qesim: eid field');

// commas inside a quoted field must not split
let f3 = esim._qesim_fields('+QESIM: "profile_detail",111,1,"Home, Work","ACME","ACME Data",1');
eq(f3[2], 'Home, Work', 'qesim: comma inside quotes preserved');
eq(f3[3], 'ACME', 'qesim: field after quoted comma');

eq(esim._qesim_fields('OK'), null, 'qesim: non-qesim line ignored');

// download result line
let dl = esim._qesim_fields('+QESIM: "download",0');
eq(dl[0], '0', 'qesim: download ret ok');

// --- AT (CCHO/CGLA/CCHC) APDU transport -------------------------------------
// a modem with no UIM client falls back to the AT transport; verify the exact
// AT commands and response parsing of open/send/close.
let at_cmds = [];
let fake = {
	_apdu_be: null,
	at: {
		send: (cmd, cb, o) => {
			push(at_cmds, cmd);
			if (match(cmd, /^AT\+CCHO=/))
				cb(null, { lines: [ '+CCHO: 2' ] });
			else if (match(cmd, /^AT\+CGLA=/))
				cb(null, { lines: [ '+CGLA: 12,00A40004009000' ] });
			else
				cb(null, { lines: [] });
		},
	},
};

let ap_ch, ap_resp, ap_closed;
sim.apdu_open(fake, 2, 'a0000005591010ffffffff8900000100', (e, r) => { ap_ch = r?.channel; });
eq(ap_ch, 2, 'apdu-at: CCHO channel parsed');
eq(at_cmds[0], 'AT+CCHO="A0000005591010FFFFFFFF8900000100"', 'apdu-at: CCHO command + uppercase AID');
eq(fake._apdu_be, 'at', 'apdu-at: backend cached as at (no uim)');

sim.apdu_send(fake, 2, ap_ch, '00a4000400', (e, r) => { ap_resp = r; });
eq(at_cmds[1], 'AT+CGLA=2,10,00A4000400', 'apdu-at: CGLA channel,len(hexchars),apdu');
eq(ap_resp, '00a40004009000', 'apdu-at: CGLA response parsed lowercase');

sim.apdu_close(fake, 2, ap_ch, (e) => { ap_closed = (e == null); });
eq(at_cmds[2], 'AT+CCHC=2', 'apdu-at: CCHC command');
eq(ap_closed, true, 'apdu-at: close ok');

done('test_esim');
