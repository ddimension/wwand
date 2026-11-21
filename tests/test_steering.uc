// wwand tests — anchor steering (steering.uc): candidate choice, the lock's
// deadlines and every path that clears it. A scripted fake modem stands in for
// the radio; time and timers are driven by hand, so each rule is checked at its
// boundary rather than by sleeping.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as steering from 'wwand/steering.uc';

// the cells AT+QSCAN reported on the NR7101 (2026-11-21), trimmed
const SCAN = [
	{ plmn: '262/02', earfcn: 6300, pci: 409, rsrp: -62, band: 20 },
	{ plmn: '262/01', earfcn: 6400, pci: 381, rsrp: -79, band: 20 },
	{ plmn: '262/01', earfcn: 3749, pci: 116, rsrp: -82, band: 8 },
	{ plmn: '262/01', earfcn: 1300, pci: 342, rsrp: -95, band: 3 },
	{ plmn: '262/01', earfcn: 1444, pci: 482, rsrp: -110, band: 3 },
	{ plmn: '262/03', earfcn: 6200, pci: 397, rsrp: -78, band: 20 },
];

// a fake modem: `radio` is what observe() reports; lock() records and, when
// `follows` is set, moves the serving cell onto the locked one
function mkfx(o) {
	let t = { now: 1000, timers: [], locks: [], scans: 0, log: [] };
	let radio = {
		serving: { earfcn: 6300, pci: 334, rsrp: -62 },
		registered: true, anchor: false, stalled: false,
	};
	t.radio = radio;
	t.fx = {
		now: () => t.now,
		timer: (ms, cb) => {
			let e = { at: t.now + ms / 1000, cb: cb, live: true };
			push(t.timers, e);
			return { cancel: () => { e.live = false; } };
		},
		observe: () => radio,
		reg_plmn: () => '262/01',
		busy: () => o?.busy ?? null,
		scan: (cb) => {
			t.scans++;
			let fin = () => cb(o?.scan_err ?? null, map(o?.scan ?? SCAN, (c) => ({ ...c })), 'qscan');
			if (o?.async) return t.fx.timer(20000, fin);   // a QSCAN takes ~26 s
			fin();
		},
		lock: (cells, cb) => {
			// async: the write reaches the modem only when the timer fires,
			// as a probe/write/read chain does — what `modem_lock` ends at is
			// what the modem really holds
			if (o?.async) {
				push(t.locks, length(cells) ? join(',', cells) : 'release');
				return t.fx.timer(2000, () => {
					t.modem_lock = length(cells) ? cells[0] : null;
					if (length(cells) && (o?.follows ?? true)) {
						let m = match(cells[0], /^([0-9]+):([0-9]+)$/);
						radio.serving = { earfcn: +m[1], pci: +m[2], rsrp: o?.locked_rsrp ?? -79 };
					}
					cb(null);
				});
			}
			push(t.locks, length(cells) ? join(',', cells) : 'release');
			if (length(cells) && (o?.follows ?? true)) {
				let m = match(cells[0], /^([0-9]+):([0-9]+)$/);
				radio.serving = { earfcn: +m[1], pci: +m[2], rsrp: o?.locked_rsrp ?? -79 };
			}
			if (!length(cells) && o?.release_to)
				radio.serving = { ...o.release_to };
			cb(o?.lock_err && length(cells) ? o.lock_err : null);
		},
	};
	// advance the clock to `s` seconds later, firing due timers in order
	t.run = (s) => {
		let end = t.now + s;
		for (;;) {
			let due = filter(t.timers, (e) => e.live && e.at <= end);
			if (!length(due))
				break;
			due = sort(due, (a, b) => a.at - b.at);
			let e = due[0];
			e.live = false;
			t.now = e.at;
			e.cb();
		}
		t.now = end;
	};
	return t;
}

let mk = (t, cfg) => steering.create({ fx: t.fx, config: cfg ?? {},
	log: (lvl, msg) => push(t.log, msg) });

// --- candidate choice ---------------------------------------------------------
{
	let c = steering.candidates(SCAN, { earfcn: 6300, pci: 334, rsrp: -62 }, '262/01', {}, steering.DEFAULTS);
	eq(map(c, (x) => sprintf('%d:%d', x.earfcn, x.pci)), [ '6400:381', '3749:116' ],
		'candidates: own PLMN only, by RSRP; B3 at -95 is more than max_drop below -62, -110 below the floor');
	c = steering.candidates(SCAN, { earfcn: 6300, pci: 334, rsrp: -80 }, '262/01', {}, steering.DEFAULTS);
	eq(map(c, (x) => x.pci), [ 381, 116, 342 ], 'candidates: from a weaker cell the B3 one qualifies');

	c = steering.candidates(SCAN, { earfcn: 6300, pci: 334, rsrp: -62 }, '262/01', {}, { ...steering.DEFAULTS, max_drop: 18 });
	eq(map(c, (x) => x.pci), [ 381 ], 'candidates: never more than max_drop below the current cell');

	c = steering.candidates(SCAN, null, '262/01', { '6400:381': { until: 1 } }, steering.DEFAULTS);
	eq(c[0].pci, 116, 'candidates: a blocked cell is skipped');

	let withanchor = map(SCAN, (x) => ({ ...x, anchor: x.pci == 342 }));
	c = steering.candidates(withanchor, null, '262/01', {}, steering.DEFAULTS);
	eq(c[0].pci, 342, 'candidates: a cell seen with an anchor ranks first, whatever its RSRP');
}

// --- enabled(): a configured lock wins ---------------------------------------
eq(steering.enabled({ anchor_steering: 'auto' }), true, 'enabled: auto');
eq(steering.enabled({}), false, 'enabled: off by default');
eq(steering.enabled({ anchor_steering: 'auto', lock_4g: [ '6300:334' ] }), false,
	'enabled: off while the config sets a 4G lock');

// --- the good path: lock, acquire, anchor, keep -------------------------------
{
	let t = mkfx();
	let s = mk(t);

	t.run(60);
	eq(t.scans, 0, 'good: no scan before first_scan');
	t.run(70);
	eq(t.scans, 1, 'good: the first scan after first_scan');
	eq(t.locks, [ '6400:381' ], 'good: the best own cell is locked');
	t.run(4);
	eq(s.state, 'locked', 'good: serving and registered -> locked');
	t.radio.anchor = true;
	t.run(4);
	eq(s.state, 'verified', 'good: EN-DC seen -> verified, the lock kept');
	t.run(3600);
	eq(t.locks, [ '6400:381' ], 'good: a verified lock is left alone');
	eq(s.status().target, '6400:381', 'good: status names the target');
}

// --- the cell is not there: cleared within acquire_s --------------------------
{
	let t = mkfx({ follows: false });
	let s = mk(t);

	t.run(125);
	eq(t.locks[0], '6400:381', 'absent: locked');
	t.radio.serving = null;           // SEARCH: no serving cell
	t.radio.registered = false;
	t.run(8);
	eq(length(t.locks), 1, 'absent: still waiting inside acquire_s');
	t.run(5);
	eq(t.locks[1], 'release', 'absent: released once acquire_s has passed');
	ok(s.status().blocked[0]?.cell == '6400:381', 'absent: the cell is blocked');
	eq(t.locks[2], '3749:116', 'absent: the next candidate is tried');
}

// --- no anchor within anchor_s: cleared, next tried ---------------------------
{
	let t = mkfx();
	let s = mk(t);

	t.run(125);
	t.run(4);
	eq(s.state, 'locked', 'no-anchor: locked');
	t.run(50);
	eq(length(t.locks), 1, 'no-anchor: still waiting inside anchor_s');
	t.run(8);
	eq(t.locks[1], 'release', 'no-anchor: released after anchor_s');
	eq(t.locks[2], '3749:116', 'no-anchor: the next candidate is tried');
}

// --- lost while locked: the serving cell changes ------------------------------
{
	let t = mkfx();
	let s = mk(t);

	t.run(125); t.run(4);
	t.radio.anchor = true; t.run(4);
	eq(s.state, 'verified', 'lost: verified');
	t.radio.serving = { earfcn: 6300, pci: 334, rsrp: -62 };
	t.radio.anchor = false;
	t.run(4);
	eq(t.locks[1], 'release', 'lost: a different serving cell releases at once');
	eq(s.state, 'backoff', 'lost: backoff');
	ok(s.status().blocked[0]?.why == 'serving cell is 6300:334', 'lost: the reason is kept');
	let n = t.scans;
	t.run(600);
	eq(t.scans, n, 'lost: no new scan right after the release');
	ok(s.status().next_scan_s > 20000, 'lost: the next round waits scan_interval');
}

// --- lost while locked: registration, data stall, weak signal -----------------
for (let what in [ 'registration', 'stall' ]) {
	let t = mkfx();
	let s = mk(t);

	t.run(125); t.run(4);
	if (what == 'registration') t.radio.registered = false;
	else t.radio.stalled = true;
	t.run(4);
	eq(t.locks[1], 'release', sprintf('lost (%s): released at once', what));
}
{
	let t = mkfx({ locked_rsrp: -100 });
	let s = mk(t);

	t.run(125); t.run(4);
	t.radio.anchor = true; t.run(4);
	t.radio.serving.rsrp = -110;
	t.run(27);
	eq(length(t.locks), 1, 'weak: inside weak_s the lock stays');
	t.run(6);
	eq(t.locks[1], 'release', 'weak: released after weak_s below the floor');
}

// --- a recovery step and stop() clear the lock first --------------------------
{
	let t = mkfx();
	let s = mk(t);

	t.run(125); t.run(4);
	let called = false;
	s.before_recovery(() => { called = true; });
	eq(t.locks[1], 'release', 'recovery: the lock is released before the rung');
	ok(called, 'recovery: ...and the rung then runs');
	ok(s.status().blocked[0]?.why == 'recovery', 'recovery: that cell is not tried again soon');

	let t2 = mkfx();
	let s2 = mk(t2);
	t2.run(125);
	s2.stop();
	eq(t2.locks, [ '6400:381', 'release' ], 'stop: releases the lock it holds');
	eq(s2.state, 'off', 'stop: off');
	t2.run(100000);
	eq(t2.scans, 1, 'stop: nothing runs afterwards');

	let t3 = mkfx();
	let s3 = mk(t3);
	let c3 = false;
	s3.before_recovery(() => { c3 = true; });
	ok(c3 && !length(t3.locks), 'recovery without a lock: no write, the rung runs');
}

// --- nothing to do -------------------------------------------------------------
{
	let t = mkfx();
	t.radio.anchor = true;
	let s = mk(t);
	t.run(200);
	eq(t.scans, 0, 'anchored: no scan while the serving cell advertises EN-DC');

	let t2 = mkfx({ busy: 'a voice call is up' });
	let s2 = mk(t2);
	t2.run(200);
	eq(t2.scans + length(t2.locks), 0, 'busy: no scan and no lock during a call');
	eq(s2.status().reason, 'a voice call is up', 'busy: the reason is shown');

	let t3 = mkfx({ scan: [ SCAN[0], SCAN[5] ] });
	let s3 = mk(t3);
	t3.run(200);
	eq(s3.state, 'idle', 'no candidate: idle');
	eq(length(t3.locks), 0, 'no candidate: nothing locked');
	ok(s3.status().next_scan_s > 21000, 'no candidate: the next scan waits scan_interval');

	let t4 = mkfx({ lock_err: 'InvalidArgument' });
	let s4 = mk(t4);
	t4.run(125);
	eq(slice(t4.locks, 0, 2), [ '6400:381', 'release' ], 'lock refused: released anyway (a half-taken write)');
}

// --- races (Codex review): a stop or a recovery while a write or scan is out ---
{
	// stop() while the set is still on its way: the release queues behind it
	let t = mkfx({ async: true, follows: false });
	let s = mk(t);
	t.run(121);                 // scan started at 120 s, ends at 140 s
	t.run(20);                  // scan done, set write issued, lands at 142 s
	eq(t.locks, [ '6400:381' ], 'race stop: the set is in flight');
	let stopped = false;
	s.stop(() => { stopped = true; });
	t.run(10);
	eq(t.locks, [ '6400:381', 'release' ], 'race stop: the release went out after the set');
	eq(t.modem_lock, null, 'race stop: the modem holds no lock at the end');
	ok(stopped, 'race stop: stop() called back once the release landed');

	// a recovery step while the scan runs: its result is not acted on
	let t2 = mkfx({ async: true });
	let s2 = mk(t2);
	t2.run(125);                // scanning
	let ran = false;
	s2.before_recovery(() => { ran = true; });
	ok(ran, 'race recovery: the rung runs at once (no lock to release)');
	t2.run(30);                 // the scan ends now
	eq(t2.locks, [], 'race recovery: the scan result locks nothing');
	ok(s2.status().next_scan_s > 20000, 'race recovery: the next round waits an interval');

	// a recovery step while the set is in flight: released behind it
	let t3 = mkfx({ async: true, follows: false });
	let s3 = mk(t3);
	t3.run(141);
	let ran3 = false;
	s3.before_recovery(() => { ran3 = true; });
	t3.run(10);
	eq([ t3.modem_lock, ran3 ], [ null, true ], 'race recovery: the set is undone before the rung');
}

// --- roaming (GDSP and other global cards): no EN-DC for this SIM anywhere ---
{
	let t = mkfx();
	let plmn = '262/01';
	t.fx.reg_plmn = () => plmn;
	let s = mk(t);

	t.run(125);
	t.run(200);      // every candidate locked and released for "no anchor"
	eq(s.status().failed_rounds, 1, 'roaming: a round where every candidate failed counts');
	let w1 = s.status().next_scan_s;
	ok(w1 > 40000, 'roaming: the next round waits twice the interval');
	t.run(w1 + 1);
	t.run(200);
	eq(s.status().failed_rounds, 2, 'roaming: a second failed round');
	ok(s.status().next_scan_s > 80000, 'roaming: ...and the wait doubles again');

	// the visited network changes: learned state is dropped, a fresh start
	plmn = '262/02';
	t.run(11);       // the idle cadence (SLOW_MS)
	eq([ s.status().failed_rounds, length(s.status().blocked), s.status().plmn ], [ 0, 0, '262/02' ],
		'roaming: a new registered network starts over');
	ok(s.status().next_scan_s <= 120, 'roaming: ...with a scan soon');
}

// --- second Codex pass: overlapping releases, network change, stale rounds ---
{
	// stop() while a release is on its way waits for it
	let t = mkfx({ async: true });
	let s = mk(t);
	t.run(150);                       // scan 120..140, set lands 142, locked
	t.radio.serving = { earfcn: 6300, pci: 334, rsrp: -62 };   // left the cell
	t.run(1);                         // the supervision tick (every 3 s) issues the release; it lands 2 s later
	eq(s.state, 'releasing', 'overlap: a release is on its way');
	let stopped = false;
	s.stop(() => { stopped = true; });
	ok(!stopped, 'overlap: stop() does not return before that release landed');
	t.run(5);
	ok(stopped && t.modem_lock == null, 'overlap: ...and returns once it did, the modem unlocked');

	// the registered network changes under a verified lock: released, rescanned
	let t2 = mkfx();
	let plmn = '262/01';
	t2.fx.reg_plmn = () => plmn;
	let s2 = mk(t2);
	t2.run(125); t2.run(4);
	t2.radio.anchor = true; t2.run(4);
	eq(s2.state, 'verified', 'network change: verified on the old network');
	plmn = '262/03';
	t2.run(4);
	eq(t2.locks[length(t2.locks) - 1], 'release', 'network change: the old network\'s lock is released');
	ok(s2.status().next_scan_s <= 120, 'network change: a scan for the new network soon');

	// a recovery step while the last candidate's release is out: no failed round
	let t3 = mkfx({ async: true, follows: false, scan: [ SCAN[1] ] });
	let s3 = mk(t3);
	t3.run(141);                      // set lands at 142, never serving
	t3.run(17);                       // acquire_s passes: release out
	eq(s3.state, 'releasing', 'stale round: the last candidate is being released');
	s3.before_recovery(() => null);
	t3.run(10);
	eq(s3.status().failed_rounds, 0, 'stale round: a round a recovery ended is not counted as failed');
}

// a QMI scan with a three-digit MNC (pcs) keeps it
{
	let m = { reg: { registration: 1, plmn: { mcc: 310, mnc: 1, mnc_digits: 3 } } };
	eq(steering.reg_plmn(m), '310/001', 'plmn: three-digit MNC from the registration');

	let sent = [];
	m.with_nas = (cb) => cb({ request: (name, args, cb2) => {
		push(sent, [ name, args ]);
		cb2(null, { pci_info: { cells: [ { freq: 1300, pci: 342, global_cell_id: 1,
			plmn: [ { mcc: 310, mnc: 1, pcs: 1 } ] } ], rsrp: -950 } });
	} });
	let got;
	steering.modem_fx(m, null, { now: () => 0, timer: () => null }).scan((e, cells, src) => { got = [ e, cells, src ]; });
	eq(sent[0], [ 'NETWORK_SCAN', { network_type: 4, scan_type: 3 } ], 'qmi scan: LTE, PCI scan type, no band restriction');
	eq([ got[0], got[2], got[1][0].plmn, got[1][0].band, got[1][0].rsrp ], [ null, 'qmi', '310/001', 3, -95 ],
		'qmi scan: the pcs flag keeps the three-digit MNC; band from the EARFCN, RSRP in dBm');

	// refused (70): remembered, and AT+QSCAN takes over on a Quectel
	let m2 = { cell_lock_dialect: 'quectel',
		with_nas: (cb) => cb({ request: (n, a, cb2) => cb2({ error: 'qmi', code: 70 }) }),
		at: { send: (cmd, cb2) => cb2(null, { lines: [ '+QSCAN: "LTE",262,01,6400,381,-79,-7,50,121,1C36400,BFF,50,20' ] }) } };
	let fx2 = steering.modem_fx(m2, null, { now: () => 0, timer: () => null });
	fx2.scan((e, cells, src) => { got = [ e, length(cells), src ]; });
	eq([ got[0], got[1], got[2], m2._steer_no_qmi_scan ], [ null, 1, 'qscan', true ],
		'scan: a refused QMI scan falls back to AT+QSCAN and is not asked again');
}

// --- modem_fx.observe: an NR leg counts as the anchor --------------------------
{
	let m = {
		reg: { registration: 1, plmn: { mcc: 262, mnc: 1, mnc_digits: 2 } },
		cells: { lte_intra: { earfcn: 6400, serving_cell_id: 381, cells: [ { pci: 381, rsrp: -790 } ] } },
		nr5g_state: { nsa_available: false },
	};
	let fx = steering.modem_fx(m, null, { now: () => 0, timer: () => null });
	eq(fx.observe().serving, { earfcn: 6400, pci: 381, rsrp: -79 }, 'observe: serving cell from lte_intra, RSRP in dBm');
	eq(fx.observe().anchor, false, 'observe: no NR leg, the System Info flag');
	m.cells.serving = { nr: { mode: 'NSA', arfcn: 431070 } };
	eq(fx.observe().anchor, true, 'observe: an NR leg is the anchor, whatever the lagging flag says');
	let fx2 = steering.modem_fx({ ...m, reg: { state: 'registered' } }, null,
		{ now: () => 0, timer: () => null, registered: () => true });
	eq(fx2.observe().registered, true, 'observe: the daemon decides registration for any backend');
	delete m.cells.serving;
	m.dsd_status = { nr: true };
	eq(fx.observe().anchor, true, 'observe: ...and so is the DSD reporting NR');
	eq(fx.reg_plmn(), '262/01', 'observe: the registered PLMN keeps the MNC leading zero');
}

done('test_steering');
