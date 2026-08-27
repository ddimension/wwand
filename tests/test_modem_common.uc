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

// --- telemetry channel selection (at2) ---------------------------------------
// telemetry_at() is a pure selector: open_at() opens BOTH ports up front (at2 is
// a URC source first and a poll channel second), so this only has to return the
// dedicated engine when there is one and the control channel otherwise.

// (1) direct telemetry_at semantics on a hand-built modem
let at2_engine = { tag: 'at2' };
let s = { at: { tag: 'ctrl' }, at_telemetry: at2_engine };

eq(mc.telemetry_at(s), at2_engine, 'at2: telemetry_at returns the dedicated engine');
eq(mc.telemetry_at(s), at2_engine, 'at2: selection is stable across calls');

// no second port -> the control channel (open_at aliased at_telemetry to at)
let s2 = { at: { tag: 'ctrl' } };
s2.at_telemetry = s2.at;
eq(mc.telemetry_at(s2), s2.at, 'at2: no second port -> control channel');

// a torn-down modem (close_at ran: at/at_telemetry nulled) must NOT yield null —
// stale in-flight callbacks call telemetry_at(self).send(...) unguarded; they
// get a stub engine that errors immediately instead of crashing the daemon
// (the Cudy LT300 autosetup-reload crash: reload inside the 'registered' emit)
let s4 = { at: null, at_telemetry: null };
let stub = mc.telemetry_at(s4);
ok(stub != null, 'teardown: telemetry_at never returns null');
let stub_err = 'unset';
stub.send('AT+CSQ', (err, res) => { stub_err = err; eq(res, null, 'teardown: stub send has no result'); });
eq(stub_err, 'closed', 'teardown: stub send errors with closed');
let seq_done = false;
stub.run_sequence([ 'AT' ], () => { seq_done = true; });
ok(seq_done, 'teardown: stub run_sequence completes via callback');
stub.close();   // must not throw

// --- collect_temperature (per-manufacturer AT dispatch) ----------------------
function temp_modem(mfr, resp) {
	let m;
	m = {
		info: { manufacturer: mfr },
		at_telemetry: { send: (cmd, cb) => { m._sent = cmd; cb(null, { lines: resp }); } },
	};
	return m;
}

let tq = temp_modem('Quectel', [ '+QTEMP: "cpu0-0-usr","41"', 'OK' ]);
mc.collect_temperature(tq, () => null);
eq(tq._sent, 'AT+QTEMP', 'temp: quectel sends AT+QTEMP');
eq(tq.temperature.celsius, 41, 'temp: quectel parsed 41 C');
eq(tq.temperature.source, 'at', 'temp: source tagged at');

let tm = temp_modem('MeiG SMART', [ '+TEMP: "soc-thmzone","38500"', 'OK' ]);
mc.collect_temperature(tm, () => null);
eq(tm._sent, 'AT+TEMP', 'temp: meig sends AT+TEMP');
eq(tm.temperature.celsius, 38, 'temp: meig milli /1000');

let ts = temp_modem('SIMCOM INCORPORATED', [ '+CPMUTEMP: 47' ]);
mc.collect_temperature(ts, () => null);
eq(ts._sent, 'AT+CPMUTEMP', 'temp: simcom sends AT+CPMUTEMP');
eq(ts.temperature.celsius, 47, 'temp: simcom parsed 47 C');

// unreadable value -> temperature cleared to null (not left stale-as-object)
let tn = temp_modem('Quectel', [ '+QTEMP: "x","5"', 'OK' ]);
mc.collect_temperature(tn, () => null);
eq(tn.temperature, null, 'temp: below-floor reading -> null');

// unknown vendor: no command sent, temperature untouched, and latched off
let tu = temp_modem('AcmeModem', [ '+FOO: 1' ]);
mc.collect_temperature(tu, () => null);
eq(tu._sent, null, 'temp: unknown vendor sends nothing');
eq(tu.temperature, null, 'temp: unknown vendor leaves temperature unset');
ok(tu._temp_unavail === true, 'temp: unknown vendor latches off');

// failure latch: an AT error (unsupported command / dead AT port) stops retries
let tf;
tf = {
	info: { manufacturer: 'Quectel' },
	at_telemetry: { send: (cmd, cb) => { tf._n = (tf._n ?? 0) + 1; cb('closed', null); } },
};
mc.collect_temperature(tf, () => null);
eq(tf._n, 1, 'temp latch: first attempt sends');
ok(tf._temp_unavail === true, 'temp latch: AT error sets the unavailable latch');
mc.collect_temperature(tf, () => null);
eq(tf._n, 1, 'temp latch: no re-send on later ticks after a failure');

// format_telemetry surfaces the temperature
ok(index(mc.format_telemetry({ reg: { radio_ifs: [] }, temperature: { celsius: 44 } }), 'temp=44C') >= 0,
	'format_telemetry: temperature in the log line');

// (2) open_at must open BOTH ttys up front: at2 is a URC source, and a port
// nobody holds open drops what the modem pushes there. Drive the real open_at
// with a mock fx (RG650E-style 2c7c:0122 -> ttyUSB2 at + ttyUSB3 at2) and a
// transport opener that records which ttys it opens.
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
let opened_tr = [];
let fake_transport = () => {
	// A real port answers a bare AT, and open_at now checks that before
	// committing to a channel — a port that opens but stays silent is dropped
	// in favour of the MBIM pipe. The fake has to behave like a modem for that
	// much, or every AT bring-up in these tests looks like a dead channel.
	let t = { close: () => null, drain: () => null };

	t.write = (d) => {
		if (t.data_cb && match(d ?? '', /^AT\r?$/))
			t.data_cb("\r\nOK\r\n");

		return true;
	};

	t.on_data = (cb) => { t.data_cb = cb; };
	return t;
};
let open_transport = (tty) => {
	let t = fake_transport();
	push(opened_ttys, tty);
	push(opened_tr, t);
	return t;
};

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
eq(opened_ttys, [ '/dev/ttyUSB2', '/dev/ttyUSB3' ], 'open_at: both control and at2 ttys are opened up front');
ok(modem.at != null, 'open_at: control engine created');
ok(modem.at_telemetry != modem.at, 'open_at: at2 gets its own engine');
eq(modem.at_telemetry_tty, '/dev/ttyUSB3', 'open_at: at2 engine bound to the second tty');
eq(mc.telemetry_at(modem), modem.at_telemetry, 'open_at: telemetry_at selects the at2 engine');

// the at2 engine must dispatch URCs, not just carry polls: a code arriving there
// while no command runs reaches the modem's handler (the whole point of opening
// it before the first poll — on NCM that poll only happens at state READY)
let at2_urcs = [];
modem.at_on_urc = (line, ch) => push(at2_urcs, sprintf('%s/%s', ch, line));
opened_tr[1].data_cb("\r\n^SIMST: 1\r\n");
eq(at2_urcs, [ 'at2/^SIMST: 1' ], 'open_at: at2 dispatches URCs, tagged with its channel');

// and the control channel tags itself distinctly — a modem that mirrors its
// URCs onto both ports is otherwise indistinguishable from one sending twice
opened_tr[0].data_cb("\r\n^SRVST: 2\r\n");
eq(at2_urcs, [ 'at2/^SIMST: 1', 'at/^SRVST: 2' ], 'open_at: control-channel URCs are tagged at');

// a vendor merge on the control engine must NOT leak into at2 (each engine owns
// its list); the backend merges into both explicitly
modem.at.add_urc_prefixes([ '^NDISSTAT' ]);
ok(!length(filter(modem.at_telemetry.urc_prefixes, (p) => p == 'NDISSTAT')),
	'open_at: control-engine prefixes are not aliased into at2');

// at2_external keeps wwand off the second port entirely
opened_ttys = [];
opened_tr = [];
let modem_x = { device: '/dev/cdc-wdm0', config: { at2_external: '1' }, info: {} };
mc.open_at(modem_x, {
	at_opts: {
		fx: fake_fx('2c7c:0122', [ { ifn: 2, tty: 'ttyUSB2' }, { ifn: 3, tty: 'ttyUSB3' } ]),
		open_transport: open_transport,
	},
	log: (level, msg) => null,
	set_drain_timer: () => null,
	next: () => null,
});
eq(opened_ttys, [ '/dev/ttyUSB2' ], 'at2_external: the second tty is left alone');
eq(modem_x.at_telemetry, modem_x.at, 'at2_external: telemetry falls back to control');
eq(modem_x.at2_released, '/dev/ttyUSB3', 'at2_external: the released port is reported');

// --- scaffolding: shared modem plumbing --------------------------------------
// The state-transition / context / recovery-passthrough plumbing that was
// byte-identical in all three modem state machines.

let events = [];
let repowered = 0, success = 0;
let self_m = { state: 'ABSENT', contexts: [] };
let sc = mc.scaffolding(self_m, {
	deps: { on_event: (m, ev, d) => push(events, { m: m, ev: ev, d: d }) },
	log: (l, msg) => null,
	rec: { on_connect_success: () => success++, usb_repower: () => repowered++ },
});

// set_state emits 'state' with the merged data, and no-ops on an unchanged state
self_m.set_state('READY', { foo: 1 });
eq(self_m.state, 'READY', 'scaffolding: set_state updates self.state');
eq(length(events), 1, 'scaffolding: set_state emitted one event');
eq(events[0].ev, 'state', 'scaffolding: emits a state event');
eq(events[0].d, { state: 'READY', foo: 1 }, 'scaffolding: state event merges data');
eq(events[0].m, self_m, 'scaffolding: emit passes the modem as subject');

self_m.set_state('READY');
eq(length(events), 1, 'scaffolding: set_state to the same state is a no-op');

// emit / notify_contexts helpers
sc.emit('custom', { x: 1 });
eq(events[1], { m: self_m, ev: 'custom', d: { x: 1 } }, 'scaffolding: emit fans out via deps.on_event');

let ctx_events = [];
let ctx = { modem_event: (ev, d) => push(ctx_events, ev) };
self_m.attach_context(ctx);
eq(self_m.contexts, [ ctx ], 'scaffolding: attach_context registers the context');
eq(ctx_events, [ 'ready' ], 'scaffolding: attach_context replays ready when already READY');

sc.notify_contexts('lost');
eq(ctx_events, [ 'ready', 'lost' ], 'scaffolding: notify_contexts fans out to attached contexts');

// a context attached while NOT ready gets no immediate ready replay
self_m.state = 'REGISTERING';
let ctx2_events = [];
self_m.attach_context({ modem_event: (ev) => push(ctx2_events, ev) });
eq(ctx2_events, [], 'scaffolding: attach_context does not replay ready when not READY');

// recovery passthroughs
self_m.note_connect_success();
eq(success, 1, 'scaffolding: note_connect_success -> rec.on_connect_success');
self_m.trip_zero_rx();
eq(repowered, 1, 'scaffolding: trip_zero_rx -> rec.usb_repower');

// stop(): teardown + ABSENT
let torn_m = 0;
self_m.teardown = () => { torn_m++; };
self_m.state = 'READY';
self_m.stop();
eq(torn_m, 1, 'scaffolding: stop() tears down');
eq(self_m.state, 'ABSENT', 'scaffolding: stop() -> ABSENT');

// _device_gone(): notify contexts lost, teardown, ABSENT, emit removed
ctx_events = []; events = []; torn_m = 0;
self_m.state = 'READY';
self_m._device_gone();
eq(ctx_events, [ 'lost' ], 'scaffolding: _device_gone notifies contexts lost');
eq(torn_m, 1, 'scaffolding: _device_gone tears down');
eq(self_m.state, 'ABSENT', 'scaffolding: _device_gone -> ABSENT');
eq(events[length(events) - 1].ev, 'removed', 'scaffolding: _device_gone emits removed');

// --- note_connect_failure_light: MBIM/NCM recovery passthrough ---------------

let ncf_rc = { action: 'retry', reboots: 0, repowers: 0 };
let ncf_self = {};
mc.note_connect_failure_light(ncf_self, {
	on_attempt: () => ncf_rc.action,
	reboot: () => { ncf_rc.reboots++; },
	usb_repower: () => { ncf_rc.repowers++; },
});

let got_action = null;
ncf_self.note_connect_failure((a) => { got_action = a; });
eq(got_action, 'retry', 'ncf-light: passes the ladder action to done');
eq(ncf_rc.reboots, 0, 'ncf-light: retry does not reboot');
eq(ncf_rc.repowers, 0, 'ncf-light: retry does not repower');

ncf_rc.action = 'usb_repower';
ncf_self.note_connect_failure((a) => { got_action = a; });
eq(ncf_rc.repowers, 1, 'ncf-light: usb_repower action triggers rec.usb_repower');

ncf_rc.action = 'reboot';
ncf_self.note_connect_failure((a) => { got_action = a; });
eq(ncf_rc.reboots, 1, 'ncf-light: reboot action triggers rec.reboot');

// done is optional
ncf_rc.action = 'retry';
ncf_self.note_connect_failure();
ok(true, 'ncf-light: tolerates a missing done callback');

// --- make_fail: shared bring-up failure handler ------------------------------

let mf_events = [];
let mf_action = 'retry';
let torn = 0, started = 0, mf_retry = null;
let fm = {
	state: 'READY',
	counters: { attempts: 3 },
	timing: { backoff_min: 10, backoff_max: 100 },
	note_connect_failure: (done) => done(mf_action),   // yield the ladder action
	teardown: () => { torn++; },
	start: () => { started++; },
};
fm.set_state = (s, d) => { fm.state = s; fm.last_state_data = d; };

let fail = mc.make_fail(fm, {
	log: (l, m) => null,
	timing: fm.timing,
	emit: (ev, d) => push(mf_events, { ev: ev, d: d }),
	set_retry_timer: (t) => { mf_retry = t; },
});

// a 'retry' action: emits error, tears down, schedules a capped-backoff retry
mf_action = 'retry';
fail('register', { error: 'x' });
eq(mf_events[0].ev, 'error', 'make_fail: emits an error event');
eq(mf_events[0].d.action, 'retry', 'make_fail: error carries the ladder action');
eq(mf_events[0].d.attempts, 3, 'make_fail: error carries the attempt count');
eq(mf_events[0].d.stage, 'register', 'make_fail: error carries the failing stage');
eq(torn, 1, 'make_fail: teardown called');
eq(fm.state, 'ABSENT', 'make_fail: state driven to ABSENT');
eq(fm.last_state_data.retry_in, 30, 'make_fail: backoff = backoff_min * attempts (10*3)');
ok(mf_retry != null, 'make_fail: retry timer scheduled for a retry action');
mf_retry.cancel();

// a 'reboot' action: tears down but schedules NO retry (reboot pending)
mf_events = []; torn = 0; mf_retry = null;
mf_action = 'reboot';
fail('sync', {});
eq(torn, 1, 'make_fail: teardown on reboot too');
eq(mf_retry, null, 'make_fail: no retry scheduled when a reboot is pending');
eq(fm.state, 'ABSENT', 'make_fail: ABSENT after a reboot action');

// backoff is capped at backoff_max
mf_events = []; mf_retry = null; mf_action = 'retry';
fm.counters.attempts = 50;                 // 10*50 = 500 -> capped to 100
fail('register', {});
eq(fm.last_state_data.retry_in, 100, 'make_fail: backoff capped at backoff_max');
if (mf_retry) mf_retry.cancel();

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

// --- format_telemetry: one rich line across the three backend shapes ---------
let qmi = {
	reg: { radio_ifs: [ 8 ], roaming: false, plmn: { mcc: 262, mnc: 2, description: 'vodafone' } },
	cells: { lte_intra: { plmn: '26202', tac: 45195, global_cell_id: 13102082,
	         earfcn: 6300, serving_cell_id: 334, cells: [ { pci: 334, rsrp: -710, rsrq: -110 } ] } },
	signal: { lte: { rssi: -42, rsrp: -71, snr: 72 } }, config: {},
};
let l = mc.format_telemetry(qmi);
ok(index(l, 'tech=LTE') >= 0, 'ft-qmi: tech LTE from numeric radio_ifs');
ok(index(l, 'plmn=262/02 (vodafone)') >= 0, 'ft-qmi: plmn mcc/mnc');
ok(index(l, 'lte=[plmn 26202 tac 45195') >= 0, 'ft-qmi: cell block');
ok(index(l, 'sig_lte=[rssi -42 rsrp -71 snr 7.2]') >= 0, 'ft-qmi: per-tech signal');

// MBIM: no radio_ifs, plmn id, tech from dsd_status, flat signal
let mbim = {
	reg: { roaming: true, plmn: { id: '26201', description: 'Telekom' } },
	dsd_status: { mode: 'NSA' }, signal: { rssi: -65, rsrp: -95 }, config: {},
};
l = mc.format_telemetry(mbim);
ok(index(l, 'tech=NSA') >= 0, 'ft-mbim: tech from dsd_status');
ok(index(l, 'plmn=262/01 (Telekom)') >= 0, 'ft-mbim: numeric provider id split to mcc/mnc');
ok(index(l, 'roaming=yes') >= 0, 'ft-mbim: roaming');
ok(index(l, 'sig=[rssi -65 rsrp -95]') >= 0, 'ft-mbim: flat signal');

// NCM: tech from dsd_status, sig.lte, config lock shown
let ncm = {
	reg: { roaming: false }, dsd_status: { mode: 'LTE' },
	signal: { lte: { rssi: -60, rsrp: -80 } }, config: { lock_4g: [ '1300:246' ] },
};
l = mc.format_telemetry(ncm);
ok(index(l, 'tech=LTE') >= 0, 'ft-ncm: tech from dsd_status');
ok(index(l, 'sig_lte=[rssi -60 rsrp -80]') >= 0, 'ft-ncm: signal');
ok(index(l, 'lock_4g=1300:246') >= 0, 'ft-ncm: cell lock shown');

// the -32768 "no measurement" sentinel drops just that field
l = mc.format_telemetry({ reg: {}, signal: { lte: { rssi: -50, rsrp: -32768, snr: -32768 } }, config: {} });
ok(index(l, 'sig_lte=[rssi -50]') >= 0, 'ft: sentinel fields dropped');

// a fine IoT RAT (from AT QNWINFO) overrides the coarse radio-interface tech:
// the QMI radio_ifs say LTE, but the modem is actually on NB-IoT
l = mc.format_telemetry({
	reg: { radio_ifs: [ 8 ] },
	rat_fine: { rat: 'nb-iot', mode: null, ntn: false, src: 'qnwinfo' }, config: {},
});
ok(index(l, 'tech=NB-IoT') >= 0, 'ft: IoT rat_fine overrides coarse LTE');
ok(index(l, 'tech=LTE') < 0, 'ft: coarse LTE suppressed when IoT identified');

// a non-IoT rat_fine (e.g. plain LTE) does NOT override — coarse path stands
l = mc.format_telemetry({
	reg: { radio_ifs: [ 8 ] },
	rat_fine: { rat: 'lte', mode: null, ntn: false, src: 'qnwinfo' }, config: {},
});
ok(index(l, 'tech=LTE') >= 0, 'ft: non-IoT rat_fine leaves coarse tech intact');

// --- rat_from_radio_ifs: coarse rat_label fallback (E392-class, no DSD/QNWINFO)
eq(mc.rat_from_radio_ifs([ 8 ])?.rat, 'lte', 'radio_ifs: [8] -> lte');
eq(mc.rat_from_radio_ifs([ 5 ])?.rat, 'umts', 'radio_ifs: [5] -> umts');
eq(mc.rat_from_radio_ifs([ 4 ])?.rat, 'gsm', 'radio_ifs: [4] -> gsm');
eq(mc.rat_from_radio_ifs([ 12 ])?.rat, 'nr5g', 'radio_ifs: [12] -> nr5g');
// highest-tech wins when several are present (order-independent)
eq(mc.rat_from_radio_ifs([ 4, 8, 5 ])?.rat, 'lte', 'radio_ifs: mixed -> highest (lte)');
eq(mc.rat_from_radio_ifs([ 8, 12 ])?.rat, 'nr5g', 'radio_ifs: lte+nr -> nr5g');
// empty / absent / unknown -> null (no coarse rat)
ok(mc.rat_from_radio_ifs([]) == null, 'radio_ifs: empty -> null');
ok(mc.rat_from_radio_ifs(null) == null, 'radio_ifs: null -> null');
ok(mc.rat_from_radio_ifs([ 99 ]) == null, 'radio_ifs: unknown value -> null');

// --- check_identity: post-open stable-identity gate --------------------------
let ci_events;
let ci_emit = (ev, d) => push(ci_events, [ ev, d ]);
let ci_log = (lvl, msg) => null;
function mk_modem(imei, cfg_imei) {
	return { info: { imei: imei, model: 'RGx' }, config: { imei: cfg_imei, serial: 'S1' } };
}

// no pinned IMEI -> proceed, but still emits 'identity' (for learn-back)
ci_events = [];
let ci1 = mk_modem('351234567890123', null);
eq(mc.check_identity(ci1, { emit: ci_emit, log: ci_log }), true, 'identity: no pin -> proceed');
eq(ci_events[0][0], 'identity', 'identity: emits identity event');
eq(ci_events[0][1].imei, '351234567890123', 'identity: event carries the imei');
eq(ci_events[0][1].serial, 'S1', 'identity: event carries the serial for learn-back');

// exact match -> proceed
eq(mc.check_identity(mk_modem('351234567890123', '351234567890123'), { emit: ci_emit, log: ci_log }),
	true, 'identity: exact match -> proceed');

// IMEISV (16 digits) matches the pinned IMEI (first 14 TAC+serial compared)
eq(mc.check_identity(mk_modem('3512345678901288', '351234567890123'), { emit: ci_emit, log: ci_log }),
	true, 'identity: IMEISV matches IMEI (first 14)');

// punctuation/spaces ignored
eq(mc.check_identity(mk_modem('35-123456-789012-3', '351234567890123'), { emit: ci_emit, log: ci_log }),
	true, 'identity: punctuation ignored');

// mismatch -> halt (false), records self.identity_mismatch, emits identity_mismatch
ci_events = [];
let ci4 = mk_modem('359999999999999', '351234567890123');
eq(mc.check_identity(ci4, { emit: ci_emit, log: ci_log }), false, 'identity: mismatch -> halt');
ok(ci4.identity_mismatch != null, 'identity: mismatch recorded on self');
eq(ci4.identity_mismatch.found, '359999999999999', 'identity: records the found imei');
eq(length(filter(ci_events, (e) => e[0] == 'identity_mismatch')), 1, 'identity: emits identity_mismatch');

// pinned IMEI but the modem never reported one -> cannot validate, proceed
eq(mc.check_identity(mk_modem(null, '351234567890123'), { emit: ci_emit, log: ci_log }),
	true, 'identity: unknown modem imei -> proceed');

// --- nitz_epoch: NAS Network-Time "Universal Time" -> unix epoch --------------
// QMI month is 1-based (matches timegm). 2026-07-27 13:45:09 UTC.
eq(mc.nitz_epoch({ year: 2026, month: 7, day: 27, hour: 13, minute: 45, second: 9 }),
	timegm({ year: 2026, mon: 7, mday: 27, hour: 13, min: 45, sec: 9 }), 'nitz: full UTC -> epoch');
eq(mc.nitz_epoch({ year: 2000, month: 1, day: 1, hour: 0, minute: 0, second: 0 }),
	timegm({ year: 2000, mon: 1, mday: 1, hour: 0, min: 0, sec: 0 }), 'nitz: lower-bound year accepted');
// implausible / zeroed frames -> null (modem pushed NITZ before it had a time)
eq(mc.nitz_epoch({ year: 0, month: 0, day: 0 }), null, 'nitz: zeroed frame -> null');
eq(mc.nitz_epoch({ year: 1980, month: 6, day: 1 }), null, 'nitz: pre-2000 year -> null');
eq(mc.nitz_epoch({ year: 2026, month: 13, day: 1 }), null, 'nitz: month out of range -> null');
eq(mc.nitz_epoch(null), null, 'nitz: no struct -> null');
eq(mc.nitz_epoch({ year: 2026 }), null, 'nitz: missing month -> null');

// --- last_reg_detail: reject cause survives the failure re-init --------------
// make_fail stashes a fresh registration problem on the persistent recovery
// record; scaffolding re-seeds it (marked stale) onto the recreated modem.
let rec_p = {};
let frd = { reg_detail: { source: 'mbim', reject_cause: 15, limited: true },
	counters: { attempts: 1 },
	note_connect_failure: (cb) => cb('reboot'),   // 'reboot' path: no retry timer
	teardown: () => null, set_state: () => null, state: 'REGISTERING' };
let ffail = mc.make_fail(frd, { log: () => null, emit: () => null,
	timing: { backoff_min: 1, backoff_max: 1 }, set_retry_timer: () => null,
	rec: rec_p });
ffail('registration_timeout', { reg: {} });
eq(rec_p.last_reg_detail, { source: 'mbim', reject_cause: 15, limited: true },
	'last_reg_detail: make_fail stashes the fresh cause on the recovery record');

let seeded = { config: {}, reg_detail: null, state: 'ABSENT', contexts: [] };
mc.scaffolding(seeded, { deps: {}, log: () => null, rec: rec_p });
eq(seeded.reg_detail, { source: 'mbim', reject_cause: 15, limited: true, stale: true },
	'last_reg_detail: scaffolding re-seeds it marked stale');

// a stale detail is NOT re-stashed (would keep resurrecting forever)
let rec_p2 = {};
let frd2 = { ...frd, reg_detail: { source: 'mbim', reject_cause: 15, stale: true } };
mc.make_fail(frd2, { log: () => null, emit: () => null,
	timing: { backoff_min: 1, backoff_max: 1 }, set_retry_timer: () => null,
	rec: rec_p2 })('registration_timeout', { reg: {} });
eq(rec_p2.last_reg_detail, null, 'last_reg_detail: stale detail is not re-stashed');

// --- preserve_serving: carry AT band forward across a band-less cell refresh --

// same serving cell (EARFCN match) -> serving carried onto the new cells object
let oldc = { serving: { lte: { earfcn: 6300, band: 20, bandwidth_mhz: 10 } } };
let newc = { lte_intra: { earfcn: 6300, serving_cell_id: 334 } };
mc.preserve_serving(newc, oldc);
eq(newc.serving, { lte: { earfcn: 6300, band: 20, bandwidth_mhz: 10 } }, 'preserve_serving: carried when EARFCN matches');

// handover (EARFCN differs) -> stale serving dropped, not mislabelled
newc = { lte_intra: { earfcn: 1500, serving_cell_id: 12 } };
mc.preserve_serving(newc, oldc);
ok(newc.serving == null, 'preserve_serving: dropped on EARFCN mismatch (handover)');

// no comparable identity on the new cells -> conservatively keep
newc = { nr5g_arfcn: null };
mc.preserve_serving(newc, oldc);
ok(newc.serving != null, 'preserve_serving: kept when identity not comparable');

// NR path: ARFCN match carries serving.nr
let oldnr = { serving: { nr: { arfcn: 646272, band: 78, bandwidth_mhz: 100 } } };
newc = { nr5g_arfcn: 646272 };
mc.preserve_serving(newc, oldnr);
eq(newc.serving.nr.band, 78, 'preserve_serving: NR carried when ARFCN matches');

// never clobber a serving the new object already has (gap-only)
newc = { serving: { lte: { band: 3 } }, lte_intra: { earfcn: 6300 } };
mc.preserve_serving(newc, oldc);
eq(newc.serving.lte.band, 3, 'preserve_serving: existing serving not overwritten');

// null guards
ok(mc.preserve_serving(null, oldc) == null, 'preserve_serving: null new cells -> null');
newc = { lte_intra: { earfcn: 6300 } };
mc.preserve_serving(newc, { serving: null });
ok(newc.serving == null, 'preserve_serving: no old serving -> no-op');

// --- serving_from_ca: vendor-neutral BANDWIDTH from the CA-info PCC -----------
// (band is left to EARFCN derivation; the QMI CA band TLV is the ActiveBand enum)

// no serving yet -> seed serving.lte with bandwidth + earfcn/pci from the PCC
let sca = { cells: { ca: [
	{ role: 'PCC', earfcn: 6300, pci: 334, bandwidth_mhz: 10 },
	{ role: 'SCC', earfcn: 1500, bandwidth_mhz: 20 },
] } };
mc.serving_from_ca(sca);
eq(sca.cells.serving.lte, { bandwidth_mhz: 10, earfcn: 6300, pci: 334 },
	'serving_from_ca: PCC seeds serving.lte (bw+earfcn+pci, no band); SCC ignored');

// an AT-QENG serving already there wins (gap-fill only fills the missing bw)
sca = { cells: { serving: { lte: { earfcn: 6300, band: 20 } },
	ca: [ { role: 'PCC', earfcn: 6300, bandwidth_mhz: 15 } ] } };
mc.serving_from_ca(sca);
eq(sca.cells.serving.lte, { earfcn: 6300, band: 20, bandwidth_mhz: 15 },
	'serving_from_ca: existing serving (AT) kept, missing bandwidth filled from PCC');

// EARFCN mismatch -> guarded out (bandwidth not filled)
sca = { cells: { serving: { lte: { earfcn: 6300 } },
	ca: [ { role: 'PCC', earfcn: 1500, bandwidth_mhz: 20 } ] } };
mc.serving_from_ca(sca);
ok(sca.cells.serving.lte.bandwidth_mhz == null, 'serving_from_ca: EARFCN mismatch does not fill');

// no PCC (or PCC without bandwidth) -> no-op
sca = { cells: { ca: [ { role: 'SCC', earfcn: 1500, bandwidth_mhz: 20 } ] } };
mc.serving_from_ca(sca);
ok(sca.cells.serving == null, 'serving_from_ca: no PCC -> no serving created');

// --- qeng_ok: vendor gate for AT+QENG ----------------------------------------

ok(mc.qeng_ok({ info: { manufacturer: 'Quectel' } }), 'qeng_ok: Quectel');
ok(mc.qeng_ok({ info: { manufacturer: 'ASR' } }), 'qeng_ok: ASR');
ok(!mc.qeng_ok({ info: { manufacturer: 'Fibocom' } }), 'qeng_ok: Fibocom -> no');
ok(!mc.qeng_ok({ info: { manufacturer: 'Foxconn' } }), 'qeng_ok: Foxconn -> no');
ok(!mc.qeng_ok({ info: {} }), 'qeng_ok: unknown -> no');

// --- urc_common: NITZ + PDN events are backend-neutral -----------------------
//
// Until now only the NCM backend consumed URCs: open_at passed on_urc: null
// unless the backend defined a handler, and only modem_ncm did. A QMI or MBIM
// modem with an AT port emits the same codes and dropped every one of them.

let uc_clock = [], uc_liveness = 0, uc_settings = 0;
let uc_self = {
	contexts: [
		{ cid: 1, liveness_poke: () => uc_liveness++, settings_poke: () => uc_settings++ },
		{ cid: 2, liveness_poke: () => uc_liveness++, settings_poke: () => uc_settings++ },
	],
};
let uc_h = mc.urc_common(uc_self, {
	log: (lvl, msg) => null,
	deps: { set_clock: (e, tz) => push(uc_clock, [ e, tz ]) },
});

uc_h('+CTZV: "26/08/22,10:15:00+08"');
eq(length(uc_clock), 1, 'urc_common: NITZ reaches set_clock');
eq(uc_self.network_time?.tz_offset_min, 120, 'urc_common: NITZ tz offset decoded (8 quarters)');

uc_h('+CGEV: ME PDN DEACT 1');
eq(uc_liveness, 1, 'urc_common: PDN DEACT pokes only the matching cid');
eq(uc_settings, 0, 'urc_common: PDN DEACT does not poke settings');

uc_h('+CGEV: ME PDN ACT 2');
eq(uc_settings, 1, 'urc_common: PDN ACT pokes settings on the matching cid');

// no cid -> every context
uc_liveness = 0;
uc_h('+CGEV: ME PDN DEACT');
eq(uc_liveness, 2, 'urc_common: a cid-less PDN event reaches every context');

// an eSIM operation drives its own long AT sequence — PDN pokes are suppressed
uc_self._esim_op = true;
uc_liveness = 0;
uc_h('+CGEV: ME PDN DEACT 1');
eq(uc_liveness, 0, 'urc_common: PDN events suppressed during an eSIM op');
uc_self._esim_op = false;

// an unrelated line is simply ignored
uc_h('+CEREG: 5,"718B","01D8A467",13,0,0');
eq(length(uc_clock), 1, 'urc_common: unrelated URCs are left alone');

done('test_modem_common');
