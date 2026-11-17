// wwand tests — cell locks (cell_lock.uc): the dialect table, sync's
// read-before-write in both directions, and the NAS cell-lock wire layout.
//
// The wire buffers are the bytes measured on hardware (RG502Q-EA and
// RG650E-EU, 2026-11-17), so a wrong TLV id or width in codec/schema/nas.uc
// fails here, not on a modem.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as tlv from 'wwand/codec/tlv.uc';
import * as nas from 'wwand/codec/schema/nas.uc';
import * as cell_lock from 'wwand/cell_lock.uc';

let M = nas.default.messages;
let silent = (level, msg) => null;

function unhex(h) { let o = ''; for (let i = 0; i < length(h); i += 2) o += chr(hex(substr(h, i, 2))); return o; }
function tohex(s) { let o = ''; for (let i = 0; i < length(s); i++) o += sprintf('%02x', ord(s, i)); return o; }

// --- wire layout (HW-measured) ----------------------------------------------

eq(M.SET_CELL_LOCK_CONFIG.id, 0x00AF, 'nas: Set Cell Lock Config 0x00AF');
eq(M.GET_CELL_LOCK_CONFIG.id, 0x00D7, 'nas: Get Cell Lock Config 0x00D7');
eq(M.SET_CELL_CONFIG.id, 0x00D8, 'nas: Set Cell Config 0x00D8');
eq(M.GET_CELL_CONFIG.id, 0x015A, 'nas: Get Cell Config 0x015A');
eq(M.SET_NR5G_CELL_CONFIG.id, 0x010E, 'nas: Set NR5G Cell Config 0x010E');
eq(M.GET_NR5G_CELL_CONFIG.id, 0x010F, 'nas: Get NR5G Cell Config 0x010F');

// the request that locked the RG502Q-EA to EARFCN 6300 / PCI 409
eq(tohex(tlv.pack(M.SET_CELL_LOCK_CONFIG.req, { cell_list: [ { pci: 409, freq: 6300 } ], enforce: 1 })),
	'0105000199019c1810010001', 'wire: 0x00AF lock, u16 frequency');
// ...and the RG650E-EU to 6300 / 334, u32 frequency
eq(tohex(tlv.pack(M.SET_CELL_CONFIG.req, { cell_list: [ { pci: 334, freq: 6300 } ], enforce: 1 })),
	'010700014e019c18000010010001', 'wire: 0x00D8 lock, u32 frequency');
// the unlock: an empty list
eq(tohex(tlv.pack(M.SET_CELL_LOCK_CONFIG.req, { cell_list: [], enforce: 1 })),
	'0101000010010001', 'wire: unlock = empty list');

let r = tlv.unpack(M.GET_CELL_LOCK_CONFIG.resp, unhex('020400000000001005000199019c18'));
eq(r.cell_list, [ { pci: 409, freq: 6300 } ], 'wire: 0x00D7 read of a lock');
r = tlv.unpack(M.GET_CELL_CONFIG.resp, unhex('02040000000000100700014e019c180000'));
eq(r.cell_list, [ { pci: 334, freq: 6300 } ], 'wire: 0x015A read of a lock');
r = tlv.unpack(M.GET_CELL_CONFIG.resp, unhex('0204000000000010010000'));
eq(r.cell_list, [], 'wire: read of an unlocked modem = empty list');

// the NR lock the RG502Q-EA read back as "common/5g",100,636666,30,78
const NR_LOCK = '01040000000000104a00640001000000fab6090000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000';
let nr_args = { type: 0, cell_identity: { pci: 100, scs: 1, arfcn: 636666,
	band1: 0, band2: 1 << 13, band3: 0, band4: 0, band5: 0, band6: 0, band7: 0, band8: 0 } };
eq(tohex(tlv.pack(M.SET_NR5G_CELL_CONFIG.req, nr_args)), NR_LOCK, 'wire: 0x010E NR lock, 74-byte identity');
eq(tohex(tlv.pack(M.SET_NR5G_CELL_CONFIG.req, { type: 2 })), '01040002000000', 'wire: 0x010E unlock');
r = tlv.unpack(M.GET_NR5G_CELL_CONFIG.resp, unhex('0204000000000010040000000000114a00640001000000fab6090000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'));
eq([ r.type, r.cell_identity?.pci, r.cell_identity?.arfcn, r.cell_identity?.scs, r.cell_identity?.band2 ],
	[ 0, 100, 636666, 1, 1 << 13 ], 'wire: 0x010F read of an NR lock');

// --- fakes -------------------------------------------------------------------

// AT: answers = { cmd: [ lines ] | 'ERROR' }; everything else OK
function fake_at(answers)
{
	let self = { sent: [] };

	self.send = (cmd, cb, opts) => {
		push(self.sent, cmd);
		let a = answers[cmd];

		if (a == 'ERROR')
			return cb({ error: 'error' });

		if (type(a) == 'function')
			a = a();

		cb(null, { lines: a ?? [] });
	};

	return self;
}

// NAS: state kept like a modem keeps it, per generation
function fake_nas(opts)
{
	let self = { sent: [], lte: opts.lte ?? [], nr: opts.nr ?? null };
	let qerr = (code) => ({ error: 'qmi', result: 1, code: code });

	self.request = (name, args, cb) => {
		push(self.sent, { name: name, args: args });

		switch (name) {
		case 'GET_CELL_CONFIG':
			return opts.u32 ? cb(null, { cell_list: self.lte }) : cb(qerr(71));
		case 'GET_CELL_LOCK_CONFIG':
			return opts.u16 ? cb(null, { cell_list: self.lte }) : cb(qerr(71));
		case 'SET_CELL_CONFIG':
		case 'SET_CELL_LOCK_CONFIG':
			self.lte = args.cell_list;
			return cb(null, {});
		case 'GET_NR5G_CELL_CONFIG':
			if (!opts.nr5g)
				return cb(qerr(94));
			return cb(null, self.nr ? { type: 0, cell_identity: self.nr } : {});
		case 'SET_NR5G_CELL_CONFIG':
			if (args.type == 2 && !self.nr)
				return cb(qerr(3));   // the RG502Q-EA: unlock with nothing locked
			self.nr = (args.type == 2) ? null : args.cell_identity;
			return cb(null, {});
		}

		cb(qerr(71));
	};

	return self;
}

function run(m)
{
	let warns = [];
	let add = (check, severity, message, expected, actual) =>
		push(warns, { check: check, severity: severity, message: message, actual: actual });
	let called = 0;

	cell_lock.sync(m, silent, add, () => called++);
	eq(called, 1, 'sync: cb exactly once');

	return warns;
}

let at_cmds = (at) => filter(at.sent, (c) => index(c, ',') >= 0);

// --- Quectel -----------------------------------------------------------------

// a lock the config does not ask for is released, and the release persisted
{
	let locked = true;
	let at = fake_at({
		'AT+QNWLOCK="common/4g"': () => locked ? [ '+QNWLOCK: "common/4g",1,1300,246' ] : [ '+QNWLOCK: "common/4g",0' ],
		'AT+QNWLOCK="common/4g",0': () => { locked = false; return []; },
		'AT+QNWLOCK="common/5g"': [ '+QNWLOCK: "common/5g",0' ],
	});
	let m = { at: at, config: {} };
	let w = run(m);

	eq(m.cell_lock_dialect, 'quectel', 'quectel: chosen by its read');
	eq(at_cmds(at), [ 'AT+QNWLOCK="common/4g",0', 'AT+QNWLOCK="save_ctrl",1,1' ],
		'quectel: stale lock released, then saved — the old lock may sit in NV');
	eq(w, [], 'quectel: a release that took leaves no warning');
}

// a configured lock already in place: nothing written
{
	let at = fake_at({
		'AT+QNWLOCK="common/4g"': [ '+QNWLOCK: "common/4g",2,1300,246,6300,409' ],
		'AT+QNWLOCK="common/5g"': [ '+QNWLOCK: "common/5g",100,636666,30,78' ],
	});
	let w = run({ at: at, config: { lock_4g: [ '6300:409', '1300:246' ], lock_5g: '100:636666:30:78' } });

	eq(at_cmds(at), [], 'quectel: lock as configured (any order) — no write');
	eq(w, [], 'quectel: and no warning');
}

// the locked 5G read has no enable field: the first number is the PCI
{
	let at = fake_at({
		'AT+QNWLOCK="common/4g"': [ '+QNWLOCK: "common/4g",0' ],
		'AT+QNWLOCK="common/5g"': [ '+QNWLOCK: "common/5g",100,636666,30,78' ],
	});
	run({ at: at, config: { lock_5g: '100:636666:30:78' } });
	eq(at_cmds(at), [], 'quectel: 5G read <pci>,<arfcn>,<scs>,<band> equals the config');
}

// leading zeros in the config: the modem reads numbers back, so no rewrite
{
	let at = fake_at({
		'AT+QNWLOCK="common/4g"': [ '+QNWLOCK: "common/4g",1,6300,409' ],
		'AT+QNWLOCK="common/5g"': [ '+QNWLOCK: "common/5g",0,636666,30,78' ],
	});
	let w = run({ at: at, config: { lock_4g: '06300:0409', lock_5g: '000:636666:030:78' } });

	eq(at_cmds(at), [], 'quectel: 06300:0409 equals the modem\'s 6300,409 — no write');
	eq(w, [], 'quectel: and no "not applied" warning; PCI 0 is a 5G lock');
}

// a configured lock is set; lock_persist saves it; the read-back confirms
{
	let cur = '+QNWLOCK: "common/4g",0';
	let at = fake_at({
		'AT+QNWLOCK="common/4g"': () => [ cur ],
		'AT+QNWLOCK="common/4g",1,1300,246': () => { cur = '+QNWLOCK: "common/4g",1,1300,246'; return []; },
		'AT+QNWLOCK="common/5g"': 'ERROR',   // an EG25-G: no 5G
	});
	let w = run({ at: at, config: { lock_4g: '1300:246', lock_persist: true } });

	eq(at_cmds(at), [ 'AT+QNWLOCK="common/4g",1,1300,246', 'AT+QNWLOCK="save_ctrl",1,1' ],
		'quectel: lock set, then saved because lock_persist asks');
	eq(w, [], 'quectel: applied lock, no warning');
}

// a lock the modem ignores is reported, with the state it shows
{
	let at = fake_at({
		'AT+QNWLOCK="common/4g"': [ '+QNWLOCK: "common/4g",0' ],
		'AT+QNWLOCK="common/5g"': 'ERROR',
	});
	let w = run({ at: at, config: { lock_4g: [ '1300:246' ], lock_5g: '1:2:30:78' } });

	eq(map(w, (x) => [ x.check, x.actual ]), [ [ 'lock_5g', null ], [ 'lock_4g', 'off' ] ],
		'quectel: 5G unsupported and 4G not taking are both reported');
}

// --- QMI ---------------------------------------------------------------------

// another vendor's AT answers ERROR: the search moves on to NAS (u32 generation)
{
	let at = fake_at({ 'AT+QNWLOCK="common/4g"': 'ERROR' });
	let n = fake_nas({ u32: true, u16: true });
	let m = { at: at, with_nas: (cb) => cb(n), config: { lock_4g: '6300:334' } };
	let w = run(m);

	eq(m.cell_lock_dialect, 'qmi', 'qmi: chosen when the Quectel read is refused');
	let sets = filter(n.sent, (s) => index(s.name, 'SET_') == 0);
	eq(sets, [ { name: 'SET_CELL_CONFIG', args: { cell_list: [ { pci: 334, freq: 6300 } ], enforce: 1 } } ],
		'qmi: the u32 generation is written, enforced at once');
	eq(w, [], 'qmi: lock read back, no warning');
	eq(length(filter(at.sent, (c) => index(c, ',') >= 0)), 0, 'qmi: no Quectel write on the other vendor');
}

// only the deprecated u16 pair (RG502Q-EA): written there; an EARFCN above
// 65535 is refused instead of wrapping onto another frequency
{
	let n = fake_nas({ u16: true, lte: [ { pci: 409, freq: 6300 } ] });
	let m = { with_nas: (cb) => cb(n), config: {} };
	run(m);
	eq(filter(n.sent, (s) => index(s.name, 'SET_') == 0),
		[ { name: 'SET_CELL_LOCK_CONFIG', args: { cell_list: [], enforce: 1 } } ],
		'qmi u16: the stale lock is released with an empty list');

	n = fake_nas({ u16: true });
	let w = run({ with_nas: (cb) => cb(n), config: { lock_4g: '66786:12' } });
	eq(length(filter(n.sent, (s) => index(s.name, 'SET_') == 0)), 0, 'qmi u16: EARFCN 66786 not sent');
	eq(map(w, (x) => x.check), [ 'lock_4g' ], 'qmi u16: and reported as not applied');
}

// NR: set as a 74-byte identity, released with type 2 — and only when the
// modem shows a lock (the RG502Q-EA answers an empty unlock with error 3)
{
	let n = fake_nas({ u16: true, nr5g: true });
	let m = { with_nas: (cb) => cb(n), config: { lock_5g: '100:636666:30:78' } };
	let w = run(m);
	let set = filter(n.sent, (s) => s.name == 'SET_NR5G_CELL_CONFIG')[0];

	eq(tohex(tlv.pack(M.SET_NR5G_CELL_CONFIG.req, set?.args)), NR_LOCK,
		'qmi nr: the identity sync builds is the measured wire');
	eq(w, [], 'qmi nr: lock read back, no warning');

	m.config = {};
	w = run(m);
	eq(filter(n.sent, (s) => s.name == 'SET_NR5G_CELL_CONFIG')[1]?.args, { type: 2 },
		'qmi nr: lock released when the config drops it');
	eq(w, [], 'qmi nr: release took');

	let before = length(n.sent);
	run(m);
	eq(length(filter(slice(n.sent, before), (s) => index(s.name, 'SET_') == 0)), 0,
		'qmi nr: nothing locked, nothing written (no error-3 unlock)');
}

// a value the u16/u32 field cannot hold is refused before the encoder,
// which would throw and leave sync without its callback (run() checks it)
{
	let n = fake_nas({ u32: true, nr5g: true });
	let w = run({ with_nas: (cb) => cb(n), config: { lock_4g: '6300:65536', lock_5g: '65536:636666:30:78' } });
	eq(length(filter(n.sent, (s) => index(s.name, 'SET_') == 0)), 0, 'qmi: PCI 65536 (LTE and NR) not sent');
	eq(map(w, (x) => x.check), [ 'lock_4g', 'lock_5g' ], 'qmi: both reported as not applied');

	n = fake_nas({ u32: true });
	w = run({ with_nas: (cb) => cb(n), config: { lock_4g: '4294967296:1' } });
	eq(length(filter(n.sent, (s) => index(s.name, 'SET_') == 0)), 0, 'qmi u32: EARFCN 2^32 not sent');
}

// lock_persist cannot be honoured over QMI: said, not silently dropped
{
	let n = fake_nas({ u32: true });
	let w = run({ with_nas: (cb) => cb(n), config: { lock_4g: '6300:334', lock_persist: true } });
	eq(map(w, (x) => [ x.check, x.severity ]), [ [ 'lock_persist', 'info' ] ], 'qmi: lock_persist noted as not controllable');
}

// --- no dialect --------------------------------------------------------------

{
	let at = fake_at({ 'AT+QNWLOCK="common/4g"': 'ERROR' });
	let n = fake_nas({});
	let m = { at: at, with_nas: (cb) => cb(n), config: { lock_4g: '1300:246', lock_5g: '1:2:30:78' } };
	let w = run(m);

	eq(m.cell_lock_dialect, null, 'none: no entry answered');
	eq(map(w, (x) => x.check), [ 'lock_4g', 'lock_5g' ], 'none: both configured locks reported, not guessed');
	eq(length(at_cmds(at)), 0, 'none: nothing written');

	w = run({ at: fake_at({ 'AT+QNWLOCK="common/4g"': 'ERROR' }), config: {} });
	eq(w, [], 'none: and silent when nothing is configured');

	// a bare OK with no +QNWLOCK line is not an answer in the Quectel dialect
	at = fake_at({});
	m = { at: at, config: { lock_4g: '1300:246' } };
	w = run(m);
	eq(m.cell_lock_dialect, null, 'none: a bare OK does not select quectel');
	eq(map(w, (x) => x.check), [ 'lock_4g' ], 'none: the configured lock is reported');
	eq(length(at_cmds(at)), 0, 'none: and no QNWLOCK write follows a bare OK');
}

done('test_cell_lock');
