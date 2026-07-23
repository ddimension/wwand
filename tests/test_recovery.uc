// wwand tests — recovery ladder unit tests.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as fakefx from './lib/fakefx.uc';
import * as recovery from 'wwand/recovery.uc';

uloop.init();

const silent = (level, msg) => null;

// --- ladder thresholds -------------------------------------------------------

let fx = fakefx.create();
let r = recovery.create({ id: 'm0', failreboot: 30, fx: fx, state_dir: '/state', log: silent });

let actions = [];

for (let i = 1; i <= 31; i++)
	push(actions, r.on_attempt());

eq(actions[6], 'retry', 'ladder: attempt 7 retry');
eq(actions[7], 'opmode_cycle', 'ladder: attempt 8 opmode cycle');
eq(actions[8], 'retry', 'ladder: attempt 9 retry again');
eq(actions[15], 'modem_reset', 'ladder: attempt 16 modem reset');
eq(actions[23], 'usb_repower', 'ladder: attempt 24 usb repower');
eq(actions[29], 'retry', 'ladder: attempt 30 still retry');
eq(actions[30], 'reboot', 'ladder: attempt 31 > failreboot -> reboot');

r.on_connect_success();
eq(r.counters.attempts, 0, 'ladder: success resets attempts');
eq(r.counters.rung, 0, 'ladder: success resets the fired-rung index');

// --- rung crossing: a counter jump must NOT skip a rung ----------------------
// Two callers can increment the shared counter in one failed cycle, so the
// count can leap past a threshold. The rung is a crossing, fired once, in order.
fx = fakefx.create();
r = recovery.create({ id: 'jump', failreboot: 100, fx: fx, state_dir: '/state', log: silent });

for (let i = 1; i <= 7; i++) r.on_attempt();       // attempts=7, no rung yet
eq(r.counters.rung, 0, 'jump: no rung fired below threshold 8');

// simulate a double-count cycle: jump 7 -> 9, straight past 8
r.counters.attempts = 8;                            // (second caller's increment)
let jumped = r.on_attempt();                        // attempts becomes 9
eq(jumped, 'opmode_cycle', 'jump: opmode_cycle still fires when 8 is jumped (9 >= 8)');
eq(r.counters.rung, 1, 'jump: exactly one rung advanced');

// next attempt does not re-fire the same rung
eq(r.on_attempt(), 'retry', 'jump: rung does not re-fire on the next attempt');

// --- restart mid-outage: rung index persists, no skip and no re-run ----------
fx = fakefx.create();
r = recovery.create({ id: 'restart', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
for (let i = 1; i <= 8; i++) r.on_attempt();        // fires opmode at 8 -> rung=1
eq(r.counters.rung, 1, 'restart: opmode fired before restart');

// a fresh daemon restores the persisted state (attempts=8, rung=1)
let rr = recovery.create({ id: 'restart', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
rr.load();
eq(rr.counters.attempts, 8, 'restart: attempts restored');
eq(rr.counters.rung, 1, 'restart: fired-rung index restored (opmode not re-run)');
// climbing continues from the restored rung; modem_reset next at 16
let acts2 = [];
for (let i = 9; i <= 16; i++) push(acts2, rr.on_attempt());
eq(acts2[0], 'retry', 'restart: attempt 9 retry (opmode already done)');
eq(acts2[7], 'modem_reset', 'restart: attempt 16 modem_reset (next rung, not skipped)');

// legacy state file (no `rung` key) defaults the index from the attempt count
fx.files['/state/legacy.json'] = '{ "attempts": 23, "proto_errors": 0 }';
let rl = recovery.create({ id: 'legacy', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
rl.load();
eq(rl.counters.rung, 2, 'legacy: rung index defaulted from attempts (23 -> opmode+reset done)');
eq(rl.on_attempt(), 'usb_repower', 'legacy: next rung (24) still reachable after default');

// failreboot = 0 disables the ladder entirely (old gate)
r = recovery.create({ id: 'm1', failreboot: 0, fx: fx, state_dir: '/state', log: silent });

let all_retry = true;

for (let i = 1; i <= 200; i++)
	if (r.on_attempt() != 'retry')
		all_retry = false;

ok(all_retry, 'ladder: failreboot=0 never escalates');

// --- qmi error ceiling -------------------------------------------------------

r = recovery.create({ id: 'm2', failreboot: 100, fx: fx, state_dir: '/state', log: silent });

let hit = null;

for (let i = 1; i <= 26; i++)
	if (r.on_proto_error() == 'reboot' && hit == null)
		hit = i;

eq(hit, 26, 'errors: 26th error crosses ceiling of 25');

r.on_proto_success();
eq(r.counters.proto_errors, 0, 'errors: success resets counter');

// --- persistence -------------------------------------------------------------

fx = fakefx.create();
r = recovery.create({ id: 'wan', failreboot: 100, fx: fx, state_dir: '/state', log: silent });

r.on_attempt();
r.on_attempt();
// qmi errors persist at 5-count milestones (debounced to avoid a write storm
// during a sustained outage), so drive it to a milestone
for (let i = 0; i < 5; i++)
	r.on_proto_error();

let r2 = recovery.create({ id: 'wan', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
r2.load();

eq(r2.counters.attempts, 2, 'persist: attempts restored');
eq(r2.counters.proto_errors, 5, 'persist: proto errors restored at milestone');

// corrupted state file is ignored
fx.files['/state/bad.json'] = 'not json{';
let r3 = recovery.create({ id: 'bad', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
r3.load();
eq(r3.counters.attempts, 0, 'persist: corrupt state ignored');

// --- usb repower / reboot ----------------------------------------------------

fx = fakefx.create();
r = recovery.create({ id: 'm3', failreboot: 100, fx: fx, state_dir: '/state', log: silent });

eq(r.usb_repower(), true, 'repower: runs external tool');
eq(fx.matching('run usb-repower'), [ 'run usb-repower' ], 'repower: command invoked');

// missing tool: non-zero rc reported, no crash
fx = fakefx.create({ rc: { 'usb-repower': 127 } });
r = recovery.create({ id: 'm4', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
eq(r.usb_repower(), false, 'repower: missing tool tolerated');

// reboot is deferred and deduplicated
fx = fakefx.create();
r = recovery.create({ id: 'm5', failreboot: 100, fx: fx, state_dir: '/state', log: silent, reboot_delay: 10 });

r.reboot('test');
r.reboot('test again');

eq(length(fx.matching('run reboot')), 0, 'reboot: not immediate');

uloop.timer(50, () => uloop.end());
uloop.run();

eq(length(fx.matching('run reboot')), 1, 'reboot: fired once after delay');

done('test_recovery');
