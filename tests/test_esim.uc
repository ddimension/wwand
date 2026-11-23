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

let f2 = esim._qesim_fields('+QESIM: "eid",89000000000000000000000000000000');
eq(f2[0], '89000000000000000000000000000000', 'qesim: eid field');

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
				cb(null, { lines: [ '+CGLA: 14,"00A40004009000"' ] });
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
eq(at_cmds[1], 'AT+CGLA=2,10,"00A4000400"', 'apdu-at: CGLA quoted apdu (Quectel requirement)');
eq(ap_resp, '00a40004009000', 'apdu-at: CGLA quoted response parsed lowercase');

sim.apdu_close(fake, 2, ap_ch, (e) => { ap_closed = (e == null); });
eq(at_cmds[2], 'AT+CCHC=2', 'apdu-at: CCHC command');
eq(ap_closed, true, 'apdu-at: close ok');

// --- M2M / locked eUICC classification (ES10 refused with SW 6985) ----------
// The ISD-R opens fine (CCHO ok) but every ES10 STORE DATA is refused with a
// bare 6985: es10_request must classify this as es10_refused with the
// m2m_or_locked_euicc hint so the UI can explain (HW-hit: EMnify M2M eUICC —
// SGP.02 cards have no local ES10, they are managed OTA by the SM-SR).
let m2m = {
	_apdu_be: null,
	at: {
		send: (cmd, cb, o) => {
			if (match(cmd, /^AT\+CCHO=/))
				cb(null, { lines: [ '+CCHO: 1' ] });
			else if (match(cmd, /^AT\+CGLA=/))
				cb(null, { lines: [ '+CGLA: 4,"6985"' ] });
			else
				cb(null, { lines: [] });
		},
	},
};

let m2m_err = 'unset';
esim.profiles(m2m, 1, (e, r) => { m2m_err = e; });
eq(m2m_err?.error, 'es10_refused', 'm2m: bare 6985 on ES10 classified as es10_refused');
eq(m2m_err?.hint, 'm2m_or_locked_euicc', 'm2m: hint set for UI messaging');
eq(m2m_err?.sw, '6985', 'm2m: original status word preserved');

// --- GetEUICCInfo2 (BF22): the card's own description -----------------------
// The two answers read on 2026-11-22 (ddimension/wwand#99), as the cards sent
// them: the RG650E's eUICC over AT CGLA, the T99W175's over MBIM UICC. Both
// say SGP.22 2.2.x, category [11] as 8B (lpac 2.3.0 looks for AB).
{
	let h2a = (h) => map(match(h, /../g), (x) => hex(x[0]));
	let rg650e = 'bf228187810302030182030202028303426300840f8101008204000391108304000016478505067f36f7c086030d01008703020300880203d8a916041481370f5125d0b1d408d4c3b232e6d25e795bebfbaa16041481370f5125d0b1d408d4c3b232e6d25e795bebfb8b01029902064004030100000c1454532d50412d55502d303432352d332020202020';
	let t99w175 = 'bf2281d3810302010082030202008303030100840f81010082040012e88083040000712a8504057f32e086030902008703020300880204d0a92c041481370f5125d0b1d408d4c3b232e6d25e795bebfb041477f0bd69d60bdc9e31da702b221c32808bb8e42aaa2c041481370f5125d0b1d408d4c3b232e6d25e795bebfb041477f0bd69d60bdc9e31da702b221c32808bb8e42a8b010204030000020c1454532d43412d55502d3038323120202020202020ac23801f4d756c746953696d5f43455f342e322e345f416476616e6365642076312e318100';
	let parse = (h) => esim._parse_euiccinfo2(esim._ber_parse(h2a(h)));
	let a = parse(rg650e), b = parse(t99w175);

	eq([ a.svn, a.profile_version, a.firmware, a.category ], [ '2.2.2', '2.3.1', '66.99.0', 'mediumEuicc' ],
		'euiccinfo2 rg650e: svn, profile package, firmware, category (8B)');
	eq(a.rsp_capability, [ 'additionalProfile', 'crlSupport', 'testProfileSupport', 'deviceInfoExtensibilitySupport' ],
		'euiccinfo2 rg650e: rspCapability bits by name');
	eq([ a.installed_applications, a.free_nvm, a.free_vm ], [ 0, 0x039110, 0x1647 ], 'euiccinfo2 rg650e: extCardResource');
	eq([ a.ci_pkid_verification, a.forbidden_ppr ], [ [ '81370f5125d0b1d408d4c3b232e6d25e795bebfb' ], [ 'ppr1' ] ],
		'euiccinfo2 rg650e: CI key ids, forbidden PPRs (99 02 06 40 = bit 1, PPR1)');
	eq([ a.pp_version, trim(a.sas_accreditation), a.globalplatform_version, a.ts102241_version ],
		[ '1.0.0', 'TS-PA-UP-0425-3', '2.3.0', '13.1.0' ], 'euiccinfo2 rg650e: PP, SAS, GP, TS 102 241');
	eq(index(a.uicc_capability, 'usimSupport') >= 0 && index(a.uicc_capability, 'isimSupport') >= 0, true,
		'euiccinfo2 rg650e: uiccCapability decoded');
	eq([ b.svn, b.category, b.platform_label, length(b.ci_pkid_signing) ],
		[ '2.2.0', 'mediumEuicc', 'MultiSim_CE_4.2.4_Advanced v1.1', 2 ], 'euiccinfo2 t99w175: svn, category, certification data, two CI keys');
	eq(b.rsp_capability, [ 'additionalProfile', 'crlSupport', 'testProfileSupport' ], 'euiccinfo2 t99w175: rspCapability');
	eq([ a.iot_specific_info, a.highest_svn ], [ null, null ], 'euiccinfo2: no SGP.32 / v3 fields on an SGP.22 2.2 card');

	// a set bit the table has no name for is reported by number, not dropped
	let c = parse('bf2207' + '8805' + '04' + '00001100');
	eq(c.rsp_capability, [ 'osUpdateSupport', 'bit 23' ], 'euiccinfo2: unknown bits by number, names past lpac\'s five');
	eq(parse('bf3e00'), null, 'euiccinfo2: no BF22 in the answer is null');

	// the op: EUICCInfo2, the EID, then the SGP.32 probe the card refuses
	let card = (eim_sw) => ({ _apdu_be: null, at: { send: (cmd, cb, o) => {
		let m = match(cmd, /^AT\+CGLA=1,[0-9]+,"(.*)"/);
		let r = !m ? null
			: (substr(m[1], 10) == 'BF2200') ? rg650e + '9000'
			: (substr(m[1], 10) == 'BF3E035C015A') ? 'bf3e125a10' + '89033023000000000000000000000001' + '9000'
			: (substr(m[1], 10) == 'BF5500') ? eim_sw : '6d00';

		if (match(cmd, /^AT\+CCHO=/))
			return cb(null, { lines: [ '+CCHO: 1' ] });
		cb(null, { lines: m ? [ sprintf('+CGLA: %d,"%s"', length(r), r) ] : [] });
	} } });
	let got;

	esim.info(card('6985'), 1, (e, r) => { got = e ?? r; });
	eq([ got.svn, got.eid, got.sgp32 ], [ '2.2.2', '89033023000000000000000000000001', false ],
		'info: EUICCInfo2 + EID, BF55 refused -> not SGP.32');
	esim.info(card('bf5505a003300180' + '9000'), 1, (e, r) => { got = e ?? r; });
	eq([ got.sgp32, got.eim_count ], [ true, 1 ], 'info: BF55 answered -> SGP.32, its eIM entries counted');
	esim.info(card('6f00'), 1, (e, r) => { got = e ?? r; });
	eq([ got.sgp32, got.sgp32_error ], [ null, 'sw' ], 'info: a probe that fails otherwise is unknown, not no');
}

// --- PIN safety: shared low-retry guard (all backends) ----------------------
// never auto-enter the PIN with <= 1 attempt left; distinct reason for 0 (PUK)
// vs 1 (releasable); a manual force overrides; unknown retries -> proceed.
eq(sim.pin_block_reason(null, false), null, 'pin: unknown retries -> proceed');
eq(sim.pin_block_reason(3, false), null, 'pin: 3 left -> proceed');
eq(sim.pin_block_reason(2, false), null, 'pin: 2 left -> proceed');
eq(sim.pin_block_reason(1, false), 'pin_retries_low', 'pin: 1 left -> block (releasable)');
eq(sim.pin_block_reason(0, false), 'retries_exhausted', 'pin: 0 left -> block (PUK)');
eq(sim.pin_block_reason(1, true), null, 'pin: manual force overrides the 1-left block');
eq(sim.pin_block_reason(0, true), null, 'pin: manual force overrides even at 0 (user accepts risk)');

// effective_pincode: manual override wins over active_sim / config
eq(sim.effective_pincode({ _pin_override: '4321', active_sim: { pincode: '1111' }, config: { pincode: '2222' } }), '4321', 'pin: manual override wins');
eq(sim.effective_pincode({ active_sim: { pincode: '1111' }, config: { pincode: '2222' } }), '1111', 'pin: active_sim override wins over config');
eq(sim.effective_pincode({ config: { pincode: '2222' } }), '2222', 'pin: falls back to config pincode');

done('test_esim');
