// wwand tests — the SIM inventory (siminventory.uc): cards by ICCID and where
// they are, across the sources that report them, and the traps it is shaped
// around (eUICC profile = active card, remote cards, ICCID spellings, cards
// that leave, readings that are not there yet).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as siminv from 'wwand/siminventory.uc';

// --- ICCID spellings --------------------------------------------------------
eq(siminv.norm_iccid('8949020000184496711F'), '8949020000184496711', 'iccid: the trailing F of a 19-digit BCD goes');
eq(siminv.norm_iccid('8949 0200 0018 4496 7110'), '89490200001844967110', 'iccid: spaces go');
eq(siminv.norm_iccid('89882390000056293510'), '89882390000056293510', 'iccid: 20 digits stay');
eq(siminv.norm_iccid('8988abc'), null, 'iccid: not an ICCID is nothing');
eq(siminv.norm_iccid(null), null, 'iccid: null is nothing');

let t = 1000;
let inv = siminv.create({ now: () => t });

// --- a modem's active card, then its slots ------------------------------------
inv.observe('modem:m0:active', [ { iccid: '8949020000184496711F', imsi: '262014943410220', active: true, modem: 'm0', slot: 1 } ]);
inv.observe('modem:m0:slots', [
	{ iccid: '8949020000184496711', modem: 'm0', slot: 1, active: true },
	{ iccid: '89882280000192155295', modem: 'm0', slot: 2, active: false, eid: '89033023426300000000041811587764' },
]);

eq(length(inv.list()), 2, 'slots: the active card and the second slot, not the same card twice');

let c1 = inv.find('8949020000184496711');

eq([ c1?.modem, c1?.slot, c1?.imsi, c1?.active ], [ 'm0', 1, '262014943410220', true ],
   'slots: the active card keeps its IMSI from the other source');
eq(inv.find('89882280000192155295')?.eid, '89033023426300000000041811587764', 'slots: an eUICC slot has its EID');

// --- an eUICC: the enabled profile IS the active card ------------------------------
let inv2 = siminv.create({ now: () => t });
let m = {
	info: { iccid: '89882280000192155295', imsi: '901280001078482' }, active_slot: 2,
	esim_info: { eid: 'EID1', profiles: [
		{ iccid: '89882280000192155295', state: 'enabled', nickname: 'IoT' },
		{ iccid: '89490200001111111111', state: 'disabled', nickname: 'Telekom' },
	] },
};

for (let k, l in siminv.from_modem('m0', m, null))
	inv2.observe(k, l);

eq(length(inv2.list()), 2, 'eUICC: two profiles, two entries — not an extra one for the "card"');
eq([ inv2.find('89882280000192155295').active, inv2.find('89882280000192155295').profile.state ], [ true, 'enabled' ],
   'eUICC: the enabled profile is the active card');
eq([ inv2.find('89490200001111111111').active, inv2.find('89490200001111111111').present ], [ false, true ],
   'eUICC: a disabled profile is present but not active');
eq(inv2.find('89490200001111111111').eid, 'EID1', 'eUICC: the profiles are grouped under the EID');

// --- a remote card: its place is the reader ------------------------------------------
let inv3 = siminv.create({ now: () => t });

for (let k, l in siminv.from_modem('m0', { info: { iccid: '89882390000056293510', imsi: '901280001078482' }, active_slot: 1 }, 'smartmouse'))
	inv3.observe(k, l);

let r = inv3.find('89882390000056293510');

eq([ r.reader, r.modem, r.slot ], [ 'smartmouse', null, null ], 'remote card: in the reader, not in the modem\'s slot');

// --- cards that leave; readings that are not there yet -------------------------------
t = 2000;
inv.observe('modem:m0:active', null);
ok(inv.find('8949020000184496711').present, 'no reading (identity being re-read) changes nothing');

inv.observe('modem:m0:active', []);
ok(inv.find('8949020000184496711').present, 'a card another source still reports stays present (the slot list has it)');

inv.observe('modem:m0:slots', [ { iccid: '89882280000192155295', modem: 'm0', slot: 2, active: true } ]);

let gone = inv.find('8949020000184496711');

eq([ gone.present, gone.active, gone.last_seen ], [ false, false, 1000 ],
   'a card no source reports any more is kept, absent, with when it was last seen');
eq(inv.list()[0].iccid, '89882280000192155295', 'present cards are listed first');

// a modem that went away takes its sources along
inv.forget_except('modem:', []);
eq(inv.find('89882280000192155295').present, false, 'forget: a removed modem\'s cards are absent');

done('test_siminventory');
