// wwand tests — ES10c building blocks of the optional eSIM module: BER-TLV
// parser/builder, ICCID coding and the ProfileInfoList decode (pure, no I/O).
'use strict';

import { eq, ok, done } from './lib/check.uc';

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

done('test_esim');
