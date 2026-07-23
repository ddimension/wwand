// wwand tests — shared modem helpers (modem_common.uc).
// Focus: watch_driver, the adaptive fast-telemetry cadence used identically by
// the QMI (modem.uc) and MBIM (modem_mbim.uc) state machines. The per-backend
// modem suites exercise it through a real modem; this pins the cadence unit's
// own behaviour (guards, immediate kick, reschedule, non-overlap, decay, stop).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as mc from 'wwand/modem_common.uc';

uloop.init();

// --- guards: watch() does nothing unless ready AND alive ----------------------

let calls = 0;
let d = mc.watch_driver({
	alive: () => false, ready: () => true,
	refresh: (fin) => { calls++; fin(); },
	min_interval: 10, decay: 10000,
});
d.watch();
eq(calls, 0, 'guard: not alive -> no refresh');
d.stop();

calls = 0;
d = mc.watch_driver({
	alive: () => true, ready: () => false,
	refresh: (fin) => { calls++; fin(); },
	min_interval: 10, decay: 10000,
});
d.watch();
eq(calls, 0, 'guard: not ready -> no refresh');
d.stop();

// --- immediate kick + no double-start while a cycle is running ---------------

calls = 0;
let hold = null;                 // capture fin to defer completion
d = mc.watch_driver({
	alive: () => true, ready: () => true,
	refresh: (fin) => { calls++; hold = fin; },   // do NOT finish yet
	min_interval: 10, decay: 10000,
});
d.watch();
eq(calls, 1, 'kick: watch() refreshes immediately');
d.watch();
eq(calls, 1, 'non-overlap: a second watch() does not start a parallel cycle');
hold();                          // finish the in-flight cycle -> reschedules
d.stop();

// --- reschedule while watched, then stop() halts it --------------------------
// forward-declare the phase chain (ucode captures only already-declared names)
let phase2, phase3, phase4, phase5;

let rescheduled = 0;
phase2 = () => {
	rescheduled = 0;
	d = mc.watch_driver({
		alive: () => true, ready: () => true,
		refresh: (fin) => { rescheduled++; fin(); },   // synchronous cycles
		min_interval: 15, decay: 10000,
	});
	d.watch();                   // immediate cycle = 1

	uloop.timer(80, () => {
		ok(rescheduled >= 3, sprintf('reschedule: kept ticking while watched (%d cycles)', rescheduled));
		d.stop();
		let frozen = rescheduled;

		uloop.timer(60, () => {
			eq(rescheduled, frozen, 'stop(): no cycles after stop()');
			phase3();
		});
	});
};

// --- decay: the loop idles out `decay` ms after the last watch() -------------

phase3 = () => {
	let n = 0;
	let dd = mc.watch_driver({
		alive: () => true, ready: () => true,
		refresh: (fin) => { n++; fin(); },
		min_interval: 10, decay: 30,
	});
	dd.watch();                  // one poll, then decay ~30ms later

	uloop.timer(120, () => {
		let after_decay = n;
		uloop.timer(80, () => {
			eq(n, after_decay, sprintf('decay: loop stopped itself after the decay window (%d cycles)', n));
			ok(n < 20, 'decay: bounded number of cycles, not a runaway loop');
			dd.stop();
			phase4();
		});
	});
};

// --- bail: refresh finishing while !alive does not reschedule ----------------

phase4 = () => {
	let n = 0;
	let live = true;
	let db = mc.watch_driver({
		alive: () => live, ready: () => true,
		refresh: (fin) => { n++; live = false; fin(); },   // channel vanished mid-cycle
		min_interval: 10, decay: 10000,
	});
	db.watch();
	eq(n, 1, 'bail: the one kicked cycle ran');

	uloop.timer(60, () => {
		eq(n, 1, 'bail: a cycle that finished !alive did not reschedule');
		db.stop();
		phase5();
	});
};

// --- non-overlap under a slow refresh: never two cycles in flight ------------

phase5 = () => {
	let in_flight = 0, max_in_flight = 0, cycles = 0;
	let ds = mc.watch_driver({
		alive: () => true, ready: () => true,
		refresh: (fin) => {
			cycles++;
			in_flight++;
			if (in_flight > max_in_flight) max_in_flight = in_flight;
			uloop.timer(12, () => { in_flight--; fin(); });   // slow async cycle
		},
		min_interval: 3, decay: 10000,
	});
	ds.watch();

	uloop.timer(120, () => {
		eq(max_in_flight, 1, 'non-overlap: at most one refresh in flight at any time');
		ok(cycles >= 3, sprintf('non-overlap: still made progress (%d cycles)', cycles));
		ds.stop();
		uloop.end();
	});
};

phase2();
uloop.run();

done('test_modem_common');
