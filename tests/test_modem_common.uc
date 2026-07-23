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

// --- lazy telemetry channel (at2) --------------------------------------------
// telemetry_at() must open the dedicated 'at2' engine only on first use, reuse
// it afterwards, and fall back to the control channel when there is none.

// (1) direct telemetry_at semantics on a hand-built modem
let opens = 0;
let at2_engine = { tag: 'at2' };
let s = { at: { tag: 'ctrl' } };
s.at_telemetry = s.at;
s._at2_open = () => { opens++; s.at_telemetry = at2_engine; };

eq(opens, 0, 'lazy: at2 not opened before first telemetry poll');
eq(mc.telemetry_at(s), at2_engine, 'lazy: first telemetry_at opens + returns at2');
eq(opens, 1, 'lazy: opened exactly once');
eq(mc.telemetry_at(s), at2_engine, 'lazy: second call reuses the open engine');
eq(opens, 1, 'lazy: not reopened on reuse');

// no second port -> always the control channel, never an open attempt
let s2 = { at: { tag: 'ctrl' } };
s2.at_telemetry = s2.at;
s2._at2_open = null;
eq(mc.telemetry_at(s2), s2.at, 'lazy: no at2 port -> control channel');

// a failing opener (leaves at_telemetry untouched) -> control channel, once
let tried = 0;
let s3 = { at: { tag: 'ctrl' } };
s3.at_telemetry = s3.at;
s3._at2_open = () => { tried++; /* open failed: do not set at_telemetry */ };
eq(mc.telemetry_at(s3), s3.at, 'lazy: failed open falls back to control');
eq(mc.telemetry_at(s3), s3.at, 'lazy: failed open not retried every poll');
eq(tried, 1, 'lazy: open attempted once, then given up');

// (2) open_at must NOT open the at2 tty eagerly (the #5 fix). Drive the real
// open_at with a mock fx (RG650E-style 2c7c:0122 -> ttyUSB2 at + ttyUSB3 at2)
// and a transport opener that records which ttys it opens.
function fake_fx(vidpid, ttys) {
	return {
		read: (p) => {
			if (index(p, 'board_name') >= 0) return '';
			if (index(p, 'idVendor') >= 0) return substr(vidpid, 0, 4);
			if (index(p, 'idProduct') >= 0) return substr(vidpid, 5);
			if (index(p, 'bInterfaceNumber') >= 0) {
				for (let t in ttys)
					if (index(p, sprintf(':1.%d/', t.ifn)) >= 0)
						return sprintf('%02x', t.ifn);
				return null;
			}
			return null;
		},
		glob: (pat) => map(ttys, (t) => sprintf('/sys/dev/2-1:1.%d/%s', t.ifn, t.tty)),
	};
}

let opened_ttys = [];
let fake_transport = () => ({ write: () => true, on_data: () => null, close: () => null, drain: () => null });
let open_transport = (tty) => { push(opened_ttys, tty); return fake_transport(); };

let modem = { device: '/dev/cdc-wdm0', config: {}, info: {} };
let reached_next = false;

mc.open_at(modem, {
	at_opts: {
		fx: fake_fx('2c7c:0122', [ { ifn: 2, tty: 'ttyUSB2' }, { ifn: 3, tty: 'ttyUSB3' } ]),
		open_transport: open_transport,
	},
	log: (level, msg) => null,
	set_drain_timer: () => null,
	next: () => { reached_next = true; },
});

ok(reached_next, 'open_at: completed init');
eq(opened_ttys, [ '/dev/ttyUSB2' ], 'open_at: only the control tty is opened eagerly (at2 stays lazy)');
ok(modem.at != null, 'open_at: control engine created');
eq(modem.at_telemetry, modem.at, 'open_at: telemetry aliases control until at2 is needed');
ok(modem._at2_open != null, 'open_at: a lazy at2 opener was stashed');

// first telemetry_at opens ttyUSB3
mc.telemetry_at(modem);
eq(opened_ttys, [ '/dev/ttyUSB2', '/dev/ttyUSB3' ], 'open_at: at2 tty opened on first telemetry_at');
ok(modem.at_telemetry != modem.at, 'open_at: telemetry now on the dedicated at2 engine');

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
