// wwand tests — fcc_fibocom.uc: the Fibocom FM350 (MediaTek T7xx) GTFCCLOCK
// FCC-unlock challenge/response. sha256 is injected; here it is backed by the
// host's sha256sum so the exact algorithm (not just the byte assembly) is
// checked against the HW-verified vector.
'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as fs from 'fs';
import * as fcc from 'wwand/fcc_fibocom.uc';

// real sha256 over a (possibly binary, NUL-bearing) ucode byte string, via
// sha256sum — stands in for ucode-mod-digest, which the host ucode lacks.
let sha = (s) => {
	let tmp = '/tmp/wwand_fcc_fibocom_test.bin';
	let f = fs.open(tmp, 'w');
	f.write(s);
	f.close();
	let p = fs.popen('sha256sum < ' + tmp, 'r');
	let out = p.read('all');
	p.close();
	return substr(out, 0, 64);
};

// sha256sum sanity: "abc" -> ba7816bf...
eq(sha('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
	'sha helper: sha256("abc")');

// --- key_of: the known OEM model-id constants (ModemManager 14c3 / twh) -------
eq(fcc.key_of('DW5931EFCCLOCK', sha), '4909b5a4', 'key_of: Dell DW5931e');
eq(fcc.key_of('KHOIHGIUCCHHII', sha), '3df8c719', 'key_of: Lenovo');

// --- response: the HW-verified vector -----------------------------------------
// Dell DW5931e, 2026-10-30: challenge 0x40799ebd -> GTFCCLOCKVER=3436456810 ->
// +GTFCCLOCKVER: 1 (radio unlocked).
eq(fcc.response('0x40799ebd', fcc.key_of('DW5931EFCCLOCK', sha), sha), 3436456810,
	'response: HW vector (Dell, 0x40799ebd)');
// the 0x prefix is optional, and an integer challenge is accepted too
eq(fcc.response('40799ebd', fcc.key_of('DW5931EFCCLOCK', sha), sha), 3436456810,
	'response: challenge without 0x prefix');
eq(fcc.response(0x40799ebd, fcc.key_of('DW5931EFCCLOCK', sha), sha), 3436456810,
	'response: integer challenge');
// a challenge that needs the leading zero kept (big-endian 8 hex digits)
eq(fcc.response('0x00000001', fcc.key_of('DW5931EFCCLOCK', sha), sha),
	fcc.response('1', fcc.key_of('DW5931EFCCLOCK', sha), sha),
	'response: small challenge zero-padded consistently');

// --- model_ids: selection order ----------------------------------------------
// auto (no SMBIOS type 133 on the test host): the known ids, Dell first.
eq(fcc.model_ids('fibocom'), [ 'DW5931EFCCLOCK', 'KHOIHGIUCCHHII' ],
	'model_ids: auto -> known ids (Dell, Lenovo)');
eq(fcc.model_ids(null), [ 'DW5931EFCCLOCK', 'KHOIHGIUCCHHII' ],
	'model_ids: unset behaves as auto');
// an explicit id pins exactly that one
eq(fcc.model_ids('fibocom:MYOWNMODELID'), [ 'MYOWNMODELID' ],
	'model_ids: fibocom:<id> pins one');

// --- unlock: drives GTFCCLOCKGEN/VER over a fake AT engine ---------------------
// A fake AT engine: GEN hands out the HW challenge; VER answers 1 only for the
// Dell response, 0 otherwise — so unlock must skip a wrong id and take Dell.
let gen_count = 0, ver_seen = [];
let fake_at = {
	send: (cmd, cb) => {
		if (cmd == 'AT+GTFCCLOCKGEN') {
			gen_count++;
			return cb(null, { lines: [ '+GTFCCLOCKGEN: 0x40799ebd', 'OK' ] });
		}
		let m = match(cmd, /AT\+GTFCCLOCKVER=([0-9]+)/);
		push(ver_seen, m ? +m[1] : null);
		let good = (m && +m[1] == 3436456810);
		return cb(null, { lines: [ sprintf('+GTFCCLOCKVER: %d', good ? 1 : 0), 'OK' ] });
	},
};

// model_ids order is [Dell, Lenovo]; Dell is the first and should win at once.
let got;
fcc.unlock(fake_at, (lvl, msg) => null, 'fibocom', sha, (ok_) => { got = ok_; });
ok(got === true, 'unlock: succeeds on the Dell id');
eq(ver_seen[0], 3436456810, 'unlock: sent the Dell response first');

// A modem with NO GTFCCLOCKGEN (plain ERROR) is not an FM350 FCC lock: unlock
// stops on the first try and reports false, sending no VER.
let sent = [];
let no_gtf = {
	send: (cmd, cb) => {
		push(sent, cmd);
		return cb('ERROR', null);
	},
};
let got2;
fcc.unlock(no_gtf, (lvl, msg) => null, 'fibocom', sha, (ok_) => { got2 = ok_; });
ok(got2 === false, 'unlock: false when the modem has no GTFCCLOCKGEN');
eq(sent, [ 'AT+GTFCCLOCKGEN' ], 'unlock: no VER sent without a challenge');

// A modem that rejects every id (VER always 0) -> false, after trying each id.
let ver0 = {
	send: (cmd, cb) => (cmd == 'AT+GTFCCLOCKGEN')
		? cb(null, { lines: [ '+GTFCCLOCKGEN: 0x11111111' ] })
		: cb(null, { lines: [ '+GTFCCLOCKVER: 0' ] }),
};
let got3, gen3 = 0;
let ver0_counting = {
	send: (cmd, cb) => {
		if (cmd == 'AT+GTFCCLOCKGEN') gen3++;
		return ver0.send(cmd, cb);
	},
};
fcc.unlock(ver0_counting, (lvl, msg) => null, 'fibocom', sha, (ok_) => { got3 = ok_; });
ok(got3 === false, 'unlock: false when every id is rejected');
eq(gen3, 2, 'unlock: tried both known ids (a fresh challenge each)');

done('test_fcc_fibocom');
