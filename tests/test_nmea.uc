// wwand tests — NMEA 0183 parsing (nmea.uc).
//
// The sentences below are RECORDED, not invented: twelve seconds off the GPS
// port of two routers standing a few metres apart, 2026-09-21.
//
//   192.168.203.242  Zyxel NR7101, Quectel RG502Q-EA — a real 3D fix
//   192.168.203.245  MikroTik Chateau, RG650E        — no GNSS antenna, so
//                                                       every field is empty
//
// The second one is the more useful of the two. A parser that only ever sees
// good data treats "" as a number, and `+""` is 0 in ucode — an unset HDOP
// would render as a perfect one.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as nmea from 'wwand.nmea';

// --- framing ----------------------------------------------------------------

let s = nmea.parse_sentence('$GPGSA,A,3,03,04,06,07,09,11,19,31,,,,,0.8,0.5,0.6,1*21');

eq(s.talker, 'GP', 'sentence: talker split off the type');
eq(s.type, 'GSA', 'sentence: ...and the type with it');
eq(length(s.f), 18, 'sentence: the type is not one of the fields');

// A truncated line is what a half-read buffer produces, and the checksum is
// the only thing that tells it from a short one. One flipped digit:
eq(nmea.parse_sentence('$GPGSA,A,3,03,04,06,07,09,11,19,31,,,,,0.8,0.5,0.6,1*22'), null,
   'sentence: a wrong checksum is refused, not parsed');
eq(nmea.parse_sentence('$GPGSA,A,3,03,04'), null,
   'sentence: no checksum at all is refused too');
eq(nmea.parse_sentence('garbage'), null, 'sentence: not NMEA at all');
eq(nmea.parse_sentence(''), null, 'sentence: empty line');
// proprietary sentences carry no 2+3 talker/type and must not be forced into one
eq(nmea.parse_sentence('$PQXFI,1,2*3C'), null, 'sentence: a proprietary sentence is skipped');

// --- a real fix (192.168.203.242) -------------------------------------------

let p = nmea.create();

p.feed('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60', 100);
p.feed('$GPGSA,A,3,03,04,06,07,09,11,19,31,,,,,0.8,0.5,0.6,1*21', 100);
p.feed('$GPRMC,082112.00,A,5208.613543,N,00857.854813,E,0.021,,210926,,,A,V*0F', 100);

let f = p.snapshot(100);

// ddmm.mmmmmm -> degrees: 52 + 08.613543/60, not 52.08...
ok(f.latitude > 52.14355 && f.latitude < 52.14356, 'fix: latitude is degrees, not degrees-and-minutes');
ok(f.longitude > 8.96424 && f.longitude < 8.96425, 'fix: longitude likewise');
eq(f.elevation, 102.9, 'fix: altitude above the geoid');
eq(f.geoid_separation, 47.0, 'fix: ...and the separation, which is a different number');
eq(f.fix, '3d', 'fix: GSA mode 3 is a 3D fix');
eq(f.valid, true, 'fix: RMC status A');
eq(f.quality, 1, 'fix: GGA quality');
eq(f.satellites_used, 8, 'fix: satellites in use, from GGA');
eq(f.hdop, 0.5, 'fix: HDOP');
eq(f.pdop, 0.8, 'fix: PDOP — which ugps does not report at all');
eq(f.vdop, 0.6, 'fix: VDOP likewise');
eq(f.epoch, 1789978872, 'fix: epoch from the RMC date and time (2026-09-21 08:21:12 UTC)');
eq(f.age, 0, 'fix: age is zero at the moment the position landed');
eq(p.snapshot(137).age, 37, 'fix: ...and counts from the POSITION, not from the last sentence');

// --- GSV keyed by SIGNAL, not by talker -------------------------------------
//
// The RG502Q sends two GSV cycles under the SAME `$GP` talker, told apart only
// by the NMEA 4.10 signal id in the last field: eleven satellites on signal 1
// and seven of the same ones on signal 8. Keyed by talker the second cycle
// replaced the first, and the snapshot then claimed EIGHT satellites in use
// and SEVEN in view — which cannot happen, and is how this was found.

let g = nmea.create();

for (let line in [
	'$GPGSV,3,1,11,03,36,099,29,04,73,077,37,06,57,281,32,07,14,172,21,1*64',
	'$GPGSV,3,2,11,09,64,226,34,11,26,309,37,17,06,219,32,19,19,246,42,1*68',
	'$GPGSV,3,3,11,21,02,284,37,26,08,061,25,31,17,037,36,1*56',
	'$GPGSV,2,1,07,03,36,099,34,04,73,077,38,06,57,281,27,09,64,226,34,8*63',
	'$GPGSV,2,2,07,11,26,309,35,21,02,284,33,26,08,061,28,8*5C',
])
	g.feed(line, 200);

g.feed('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60', 200);

let gs = g.snapshot(200);

eq(gs.satellites_in_view, 11, 'gsv: eleven distinct satellites, not the seven of the last cycle');
ok(gs.satellites_in_view >= gs.satellites_used,
   'gsv: ...and never fewer in view than in use, which is what the defect produced');
eq(length(gs.satellites), 18, 'gsv: every heard signal is kept — 11 on one, 7 on the other');

// the signal id is carried, so 18 entries for 11 satellites is legible
let sig1 = 0, sig8 = 0;

for (let sat in gs.satellites) {
	if (sat.signal == '1') sig1++;
	if (sat.signal == '8') sig8++;
}

eq([ sig1, sig8 ], [ 11, 7 ], 'gsv: each entry says which signal it was heard on');

// a cycle joined in the middle is not half-published
let mid = nmea.create();

mid.feed('$GPGSV,3,2,11,09,64,226,34,11,26,309,37,17,06,219,32,19,19,246,42,1*68', 300);
eq(mid.snapshot(300).satellites_in_view, null, 'gsv: joining mid-cycle publishes nothing');

// --- any talker, which is the other half of what ugps drops ------------------
//
// ugps takes `$GP` and `$GN` only (nmea.c nmea_process, 9a351d41): Galileo,
// GLONASS and BeiDou sentences are discarded before they are looked at.

let multi = nmea.create();

multi.feed('$GAGSV,1,1,03,05,45,120,40,09,30,210,38,12,10,300,,7*40', 400);
multi.feed('$GLGSV,1,1,02,65,55,045,41,66,20,180,35,1*70', 400);

let ms = multi.snapshot(400);

eq(ms.satellites_in_view, 5, 'talker: Galileo and GLONASS are counted, not dropped');
eq(multi.feed('$GNRMC,082112.00,A,5208.613543,N,00857.854813,E,0.021,,210926,,,A,V*11', 400),
   'RMC', 'talker: a GN sentence is handled like any other');

// a satellite with no SNR reported is in view but unheard — null, not 0
let unheard = 0;

for (let sat in ms.satellites)
	if (sat.snr == null)
		unheard++;

eq(unheard, 1, 'talker: an empty SNR field is absent, not a signal of zero');

// --- no antenna (192.168.203.245) -------------------------------------------
//
// Every field empty. This is the case that makes `+""` == 0 dangerous.

let dead = nmea.create();

for (let line in [
	'$GPGGA,,,,,,0,,,,,,,,*66',
	'$GPRMC,,V,,,,,,,,,,N,V*29',
	'$GPVTG,,T,,M,,N,,K,N*2C',
	'$GPGSA,A,1,,,,,,,,,,,,,,,,*32',
])
	dead.feed(line, 500);

let d = dead.snapshot(500);

eq(d.valid, false, 'no antenna: RMC status V is not a fix');
eq(d.fix, 'none', 'no antenna: GSA mode 1 says so too');
eq(d.quality, 0, 'no antenna: GGA quality 0');
eq(d.latitude, null, 'no antenna: no position');
eq(d.hdop, null, 'no antenna: an EMPTY hdop is absent — +"" would have made it a perfect 0');
eq(d.elevation, null, 'no antenna: ...and so is the altitude');
eq(d.satellites_used, null, 'no antenna: no count either');
eq(d.satellites_in_view, null, 'no antenna: nothing in view');
eq(d.age, null, 'no antenna: nothing has ever been positioned, so there is no age');
eq(d.speed_kmh, null, 'no antenna: an empty VTG is not a standstill');

// quality 0 carries stale coordinates on some receivers; they are not a position
let stale = nmea.create();

stale.feed('$GPGGA,082112.00,5208.613543,N,00857.854813,E,0,00,,,M,,M,,*7B', 600);
eq(stale.snapshot(600).latitude, null, 'no antenna: coordinates under quality 0 are refused');

// --- time -------------------------------------------------------------------

let z = nmea.create();

z.feed('$GPZDA,082112.00,21,09,2026,00,00*62', 700);
eq(z.snapshot(700).epoch, 1789978872, 'time: ZDA carries a four-digit year, no century guess');

// losing validity must not blank the last position — a receiver that blinks
// has not moved, and the age is what says how much to trust it
let blink = nmea.create();

blink.feed('$GPRMC,082112.00,A,5208.613543,N,00857.854813,E,0.021,,210926,,,A,V*0F', 800);
blink.feed('$GPRMC,082113.00,V,,,,,,,210926,,,N,V*00', 801);

let b = blink.snapshot(802);

eq(b.valid, false, 'blink: validity is lost');
ok(b.latitude != null, 'blink: ...but the last position stands, with an age to judge it by');
eq(b.age, 2, 'blink: and the age keeps counting from the last real fix');

// --- losing the fix clears what DESCRIBED it --------------------------------
//
// Each sentence only ever updated its own fields, so "no fix" could stand
// beside "eight satellites, HDOP 0.5" — a state that never existed. The
// position stays, because a receiver that blinks has not moved and an age says
// how much to trust it. Raised by Codex review, 2026-09-21.
//
// WHO gets to say there is no fix matters: RMC, GLL and GGA speak for the
// SOLUTION, a GSA speaks only for its own constellation (see below).

(function() {
	let p = nmea.create();

	p.feed('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60', 100);
	p.feed('$GPGSA,A,3,03,04,06,07,09,11,19,31,,,,,0.8,0.5,0.6,1*21', 100);
	p.feed('$GPVTG,054.7,T,034.4,M,005.5,N,010.2,K,A*25', 100);

	let before = p.snapshot(100);

	eq(before.satellites_used, 8, 'lose: eight satellites while there is a fix');
	eq(before.speed_kmh, 10.2, 'lose: ...and a speed');

	// the RECEIVER says the solution is gone
	p.feed('$GPRMC,082113.00,V,,,,,,,210926,,,N,V*00', 110);

	let after = p.snapshot(110);

	eq(after.valid, false, 'lose: an RMC status of V is the solution going away');
	eq(after.fix, 'none', 'lose: the fix with it');
	eq(after.satellites_used, null, 'lose: the satellite count went too');
	eq(after.hdop, null, 'lose: ...and the HDOP that described it');
	eq(after.pdop, null, 'lose: ...and the PDOP');
	eq(after.elevation, null, 'lose: ...and the altitude');
	eq(after.speed_kmh, null, 'lose: ...and the speed, which was a speed over the ground');
	ok(after.latitude != null, 'lose: but the last POSITION stands');
	eq(after.age, 10, 'lose: ...with the age that says how old it is');

	// the same loss said by GGA instead
	let q = nmea.create();

	q.feed('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60', 200);
	q.feed('$GPGGA,082113.00,5208.613543,N,00857.854813,E,0,00,,,M,,M,,*7A', 201);

	eq(q.snapshot(201).satellites_used, null, 'lose: a GGA quality of 0 clears it too');
	eq(q.snapshot(201).hdop, null, 'lose: ...and its HDOP');
})();

// --- one GSA per constellation is NORMAL ------------------------------------
//
// A multi-GNSS receiver sends $GPGSA, $GLGSA, $GAGSA…, and one of them
// reporting mode 1 means THAT constellation is not contributing — not that
// there is no fix. Taken globally it tore a good combined solution down, and
// which way it went depended on the order the sentences arrived in. Raised by
// Codex review, 2026-09-21.

(function() {
	let p = nmea.create();

	p.feed('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60', 100);
	// GLONASS has a 3D solution, GPS contributes nothing
	p.feed('$GLGSA,A,3,65,66,,,,,,,,,,,1.2,0.9,0.8,2*31', 100);
	p.feed('$GPGSA,A,1,,,,,,,,,,,,,,,,1*03', 100);

	let a = p.snapshot(100);

	eq(a.fix, '3d', 'gsa: the best constellation decides the fix, not the last sentence');
	eq(a.satellites_used, 8, 'gsa: ...and a quiet constellation tears nothing down');
	eq(a.pdop, 1.2, 'gsa: the DOPs come from the solution that IS the fix');
	ok(a.latitude != null, 'gsa: the position stands');

	// ORDER MUST NOT MATTER: the same two sentences the other way round
	let q = nmea.create();

	q.feed('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60', 100);
	q.feed('$GPGSA,A,1,,,,,,,,,,,,,,,,1*03', 100);
	q.feed('$GLGSA,A,3,65,66,,,,,,,,,,,1.2,0.9,0.8,2*31', 100);

	eq(q.snapshot(100).fix, '3d', 'gsa: ...whichever order they arrive in');
	eq(q.snapshot(100).satellites_used, 8, 'gsa: ...and nothing was cleared on the way');

	// 3D beats 2D, which is the case that actually decides something: one
	// constellation with a height solution is not downgraded because another
	// only has a horizontal one
	let d3 = nmea.create();

	d3.feed('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60', 100);
	d3.feed('$GLGSA,A,2,65,66,,,,,,,,,,,2.5,1.8,1.5,2*38', 100);
	d3.feed('$GPGSA,A,3,03,04,06,07,09,11,19,31,,,,,0.8,0.5,0.6,1*21', 100);

	eq(d3.snapshot(100).fix, '3d', 'gsa: 3D beats 2D');
	eq(d3.snapshot(100).pdop, 0.8, 'gsa: and the DOPs are the 3D solution\'s, not the 2D one\'s');

	// EVERY constellation reporting no fix is a different thing, and says so
	let r = nmea.create();

	r.feed('$GPGSA,A,1,,,,,,,,,,,,,,,,1*03', 100);
	r.feed('$GLGSA,A,1,,,,,,,,,,,,,,,,2*1C', 100);
	eq(r.snapshot(100).fix, 'none', 'gsa: with NOTHING contributing, there is no fix');

	// A GSA THAT STOPS ARRIVING STOPS COUNTING. Checking the age only when the
	// next GSA lands left a 3D verdict standing for ever on a receiver that
	// went quiet. Raised by Codex review, 2026-09-21.
	let stale = nmea.create();

	stale.feed('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60', 100);
	stale.feed('$GPGSA,A,3,03,04,06,07,09,11,19,31,,,,,0.8,0.5,0.6,1*21', 100);

	eq(stale.snapshot(100).fix, '3d', 'gsa ttl: a fresh GSA is a fix');
	eq(stale.snapshot(129).fix, '3d', 'gsa ttl: ...still, just inside the window');
	// null, not 'none': an expired GSA means the fix TYPE is unknown, and the
	// solution itself is still GGA's word — the two are different statements
	// and a GGA-only receiver, which never sends GSA at all, makes the same one
	eq(stale.snapshot(131).fix, null, 'gsa ttl: ...and once it is quiet, the fix TYPE is unknown');
	eq(stale.snapshot(131).valid, true, 'gsa ttl: ...while the solution is still GGA\'s word');
	eq(stale.snapshot(131).pdop, null, 'gsa ttl: its DOPs go with it');

	// AND A GSA CANNOT RESURRECT A SOLUTION THE RECEIVER SAID WAS GONE. This
	// reported { valid: false, fix: '3d' } — the exact opposite of the rule
	// this file states. Raised by Codex review, 2026-09-21.
	let zombie = nmea.create();

	zombie.feed('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60', 100);
	zombie.feed('$GPRMC,082113.00,V,,,,,,,210926,,,N,V*00', 101);
	zombie.feed('$GPGSA,A,3,03,04,06,07,09,11,19,31,,,,,0.8,0.5,0.6,1*21', 101);

	let z = zombie.snapshot(101);

	eq(z.valid, false, 'gsa zombie: the receiver said the solution was gone');
	eq(z.fix, 'none', 'gsa zombie: ...so a later GSA does not put it back');
})();

// an invalid VTG must not repopulate what a lost fix cleared
(function() {
	let p = nmea.create();

	p.feed('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60', 100);
	p.feed('$GPRMC,082113.00,V,,,,,,,210926,,,N,V*00', 101);
	p.feed('$GPVTG,054.7,T,034.4,M,005.5,N,010.2,K,N*2A', 101);

	eq(p.snapshot(101).speed_kmh, null,
	   'vtg: an FAA mode of N is "not valid" — its numbers are not a speed');
})();

// --- a GSV cycle is not evidence forever ------------------------------------
//
// A constellation or a signal band that stops being reported would otherwise
// stay in the count and in the SNR list for the life of the daemon.

(function() {
	let p = nmea.create();

	p.feed('$GPGSV,1,1,02,01,10,100,40,02,20,110,41,1*66', 1000);
	p.feed('$GLGSV,1,1,02,65,55,045,41,66,20,180,35,1*70', 1000);

	eq(p.snapshot(1000).satellites_in_view, 4, 'gsv ttl: four satellites across two talkers');

	// GLONASS keeps reporting, GPS stops
	p.feed('$GLGSV,1,1,02,65,55,045,41,66,20,180,35,1*70', 1040);

	let late = p.snapshot(1040);

	eq(late.satellites_in_view, 2, 'gsv ttl: the band that went quiet leaves the count');
	eq(length(late.satellites), 2, 'gsv ttl: ...and its satellites leave the list');

	// ...and nothing expires while it is still being repeated
	eq(p.snapshot(1041).satellites_in_view, 2, 'gsv ttl: the one still reporting stays');
})();

// --- a checksum proves arrival, not meaning ---------------------------------
//
// A receiver in a strange state emits well-formed nonsense; every sentence
// below has a CORRECT checksum.

(function() {
	let p = nmea.create();

	// minutes that are not minutes
	p.feed('$GPGLL,5299.000000,N,00857.854813,E,082112.00,A,A*6F', 1);
	eq(p.snapshot(1).latitude, null, 'garbage: 99 minutes is not a coordinate');

	// a hemisphere that is not one
	let q = nmea.create();

	q.feed('$GPGLL,5208.613543,X,00857.854813,E,082112.00,A,A*77', 1);
	eq(q.snapshot(1).latitude, null, 'garbage: a hemisphere must be one of the four');

	// an hour that does not exist: timegm would roll it into the next day
	let r = nmea.create();

	r.feed('$GPZDA,472112.00,21,09,2026,00,00*69', 1);
	eq(r.snapshot(1).epoch, null, 'garbage: hour 47 is refused, not normalised into tomorrow');

	// a month that does not exist
	let t = nmea.create();

	t.feed('$GPZDA,082112.00,21,19,2026,00,00*63', 1);
	eq(t.snapshot(1).epoch, null, 'garbage: month 19 likewise');

	// ...and a DAY that does not exist in the month it names. `d <= 31` passes
	// this and timegm rolls it into March with a perfectly plausible epoch.
	let u = nmea.create();

	u.feed('$GPZDA,082112.00,31,02,2026,00,00*68', 1);
	eq(u.snapshot(1).epoch, null, 'garbage: 31 February is not a date');

	// 2026 is not a leap year; 2028 is, and that one must still work
	let v = nmea.create();

	v.feed('$GPZDA,082112.00,29,02,2026,00,00*61', 1);
	eq(v.snapshot(1).epoch, null, 'garbage: 29 February in a common year');

	let w = nmea.create();

	w.feed('$GPZDA,082112.00,29,02,2028,00,00*6F', 1);
	ok(w.snapshot(1).epoch != null, 'garbage: ...but a real leap day is a date');
})();

done('test_nmea');
