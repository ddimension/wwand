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
r.on_proto_success();   /* the control channel answered: hardware rungs armed */

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
r.on_proto_success();   /* the control channel answered: hardware rungs armed */

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
r.on_proto_success();   /* the control channel answered: hardware rungs armed */
for (let i = 1; i <= 8; i++) r.on_attempt();        // fires opmode at 8 -> rung=1
eq(r.counters.rung, 1, 'restart: opmode fired before restart');

// a fresh daemon restores the persisted state (attempts=8, rung=1)
let rr = recovery.create({ id: 'restart', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
rr.load();
rr.on_proto_success();   /* the control channel answered: hardware rungs armed */
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
rl.on_proto_success();   /* the control channel answered: hardware rungs armed */
eq(rl.counters.rung, 2, 'legacy: rung index defaulted from attempts (23 -> opmode+reset done)');
eq(rl.on_attempt(), 'usb_repower', 'legacy: next rung (24) still reachable after default');

// failreboot = 0 disables ONLY the final reboot rung: the cheaper hardware
// recovery rungs still fire (headless GPIO-reset / keep-router-up use case),
// and the ladder then retries forever instead of ever rebooting.
r = recovery.create({ id: 'm1', failreboot: 0, fx: fx, state_dir: '/state', log: silent });
r.on_proto_success();   /* control channel answered */

let acts0 = [];
for (let i = 1; i <= 200; i++)
	push(acts0, r.on_attempt());

eq(acts0[7], 'opmode_cycle', 'failreboot=0: opmode rung still fires at 8');
eq(acts0[15], 'modem_reset', 'failreboot=0: modem_reset rung still fires at 16');
eq(acts0[23], 'usb_repower', 'failreboot=0: repower rung still fires at 24');

let no_reboot0 = true;
for (let a in acts0)
	if (a == 'reboot')
		no_reboot0 = false;

ok(no_reboot0, 'failreboot=0: never reboots, keeps retrying');

// --- qmi error ceiling -------------------------------------------------------

// A SYNC-wedged modem only climbs the proto-error counter (never a full
// attempt), so this path escalates itself: ONE hardware reset (usb_repower) when
// the count first crosses the limit, and reboot only if errors persist a further
// full window (> 2x limit). A reboot doesn't power-cycle a self-powered modem, so
// the cheaper reset must be tried first (fixes the NR7101 reboot-loop).
r = recovery.create({ id: 'm2', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
r.on_proto_success();   /* control channel answered */

let acts = [];
for (let i = 1; i <= 51; i++)
	push(acts, r.on_proto_error());

eq(acts[25], 'usb_repower', 'errors: 26th error (crosses limit 25) -> hardware reset first');
let repowers = 0;
for (let a in acts) if (a == 'usb_repower') repowers++;
eq(repowers, 1, 'errors: hardware reset fires exactly once, not per error');
eq(acts[50], 'reboot', 'errors: 51st error (> 2x limit) -> reboot after the reset did not clear it');

r.on_proto_success();
eq(r.counters.proto_errors, 0, 'errors: success resets counter');
eq(r.counters.proto_hw, 0, 'errors: success clears the hardware-reset flag');

// the proto-error thresholds scale with the configurable proto_error_limit
r = recovery.create({ id: 'plim', failreboot: 100, proto_error_limit: 3, fx: fx, state_dir: '/state', log: silent });
r.on_proto_success();   /* control channel answered */
let pacts = [];
for (let i = 1; i <= 7; i++)
	push(pacts, r.on_proto_error());
eq(pacts[3], 'usb_repower', 'errors: limit 3 -> hardware reset at the 4th error');
eq(pacts[6], 'reboot', 'errors: limit 3 -> reboot at the 7th error (> 2x3)');

// the proto-error reboot is gated by failreboot too: <=0 never reboots, but the
// hardware reset still fires (cheaper recovery runs even with reboots disabled)
r = recovery.create({ id: 'pgate', failreboot: 0, proto_error_limit: 3, fx: fx, state_dir: '/state', log: silent });
r.on_proto_success();   /* control channel answered: hardware rungs armed */
let pg_reboot = false, pg_repower = false;
for (let i = 1; i <= 30; i++) {
	let a = r.on_proto_error();
	if (a == 'reboot') pg_reboot = true;
	if (a == 'usb_repower') pg_repower = true;
}
ok(!pg_reboot, 'errors: failreboot=0 never reboots on a proto-error storm');
ok(pg_repower, 'errors: failreboot=0 still fires the hardware reset');

// --- persistence -------------------------------------------------------------

fx = fakefx.create();
r = recovery.create({ id: 'wan', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
r.on_proto_success();   /* control channel answered */

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

// --- the gate: a control channel that never answered ------------------------
// A misdetected control device fails exactly like a wedged one. Until 1.6.x the
// ladder escalated through opmode cycle, modem reset and board power-cycle
// against hardware that was never broken — reported from the field on
// 2026-08-30, where a huawei_cdc_ncm modem classified as QMI was power-cycled
// for it. With no successful request on record the errors say something about
// our own detection, so nothing physical may happen.
fx = fakefx.create();
let rg = recovery.create({ id: 'gate', failreboot: 0, proto_error_limit: 3,
	fx: fx, state_dir: '/state', log: silent });

let gate_acts = [];
for (let i = 1; i <= 40; i++) push(gate_acts, rg.on_proto_error());
eq(length(filter(gate_acts, (a) => a != 'retry')), 0,
	'gate: proto errors alone never reach hardware when nothing ever answered');

for (let i = 1; i <= 30; i++) push(gate_acts, rg.on_attempt());
eq(length(filter(gate_acts, (a) => a != 'retry')), 0,
	'gate: the attempt rungs are blocked too, not just the repower');

// ...and one successful request lifts it: the attempts are long past every
// threshold by now, so the very next one fires the first not-yet-fired rung
rg.on_proto_success();
eq(rg.on_attempt(), 'opmode_cycle', 'gate: an answer arms the ladder again');

// a protocol change withdraws the permission — what "it answered once" proved
// says nothing about the new choice
rg.note_protocol('mbim');
eq(rg.counters.proto_ok, 0, 'gate: switching protocol withdraws the arming');

// --- the two ways an unarmed modem could still reach the reboot -------------
// The gate above used to wrap only the RUNG branch, so it stopped applying the
// moment the ladder ran out of rungs — and execution fell straight through to
// the reboot. Both routes there are the migration case the gate exists for, so
// both get a test. Note failreboot > 0 here: the block above runs with 0, which
// is exactly why neither showed up.

// (a) a legacy state file whose attempt count puts the rung index at the end of
// the ladder. Nothing ever answered; the router must not reboot for it.
fx = fakefx.create();
fx.files['/state/oldstate.json'] = '{ "attempts": 30, "proto_errors": 0 }';
let ro = recovery.create({ id: 'oldstate', failreboot: 40, fx: fx, state_dir: '/state', log: silent });
ro.load();
eq(ro.counters.rung, 3, 'unarmed reboot: legacy state restored with the ladder exhausted');
eq(ro.counters.proto_ok, 0, 'unarmed reboot: a state file without the key is not armed');

let old_acts = [];
for (let i = 1; i <= 30; i++) push(old_acts, ro.on_attempt());
eq(length(filter(old_acts, (a) => a != 'retry')), 0,
	'unarmed reboot: an exhausted ladder does not fall through to the reboot');

// ...and the arming still works from there: the count is far past failreboot
ro.note_answer();
eq(ro.on_attempt(), 'reboot', 'unarmed reboot: once it answers, the reboot rung is reachable');

// ...and the unarmed warning reaches EVERY threshold. Keying it on the current
// rung index reported 8 forever and never 16 or 24, because `rung` cannot
// advance while the guard returns early.
fx = fakefx.create();
let glogs = [];
let rw = recovery.create({ id: 'warnings', failreboot: 40, fx: fx, state_dir: '/state',
	log: (level, msg) => push(glogs, msg) });

for (let i = 1; i <= 45; i++) rw.on_attempt();

let warned = filter(glogs, (m) => match(m, /never answered/) != null);
eq(length(warned), 4, 'unarmed log: one line per threshold — 8, 16, 24 and the reboot');
ok(match(warned[1], /^16 failed/) != null, 'unarmed log: the second rung is reported');
ok(match(warned[2], /^24 failed/) != null, 'unarmed log: and the third');

// (b) a protocol change on a modem that had already climbed every rung
fx = fakefx.create();
let rp = recovery.create({ id: 'protoswitch', failreboot: 40, fx: fx, state_dir: '/state', log: silent });
rp.note_protocol('qmi');
rp.note_answer();
for (let i = 1; i <= 45; i++) rp.on_attempt();
eq(rp.counters.rung, 3, 'proto switch: every rung fired while armed');

rp.note_protocol('ncm');   // detection corrected: the old proof is void
eq(rp.counters.proto_ok, 0, 'proto switch: arming withdrawn');
eq(rp.on_attempt(), 'retry',
	'proto switch: past failreboot with an exhausted ladder still does not reboot');

// A pin the driver contradicts must revoke a permission ALREADY on file.
// note_protocol only withdraws on a name change, and here the name does not
// change — the state file says 'ncm' and the pin says 'ncm'; what is wrong is
// the evidence behind it. Refusing to arm again leaves the old grant standing,
// and the next failed attempt walks into the hardware ladder.
fx = fakefx.create();
fx.files['/state/pinned.json'] =
	'{ "attempts": 7, "proto_errors": 0, "rung": 0, "proto_hw": 0, "proto_ok": 1, "proto_name": "ncm" }';
let rv = recovery.create({ id: 'pinned', failreboot: 40, fx: fx, state_dir: '/state', log: silent });
rv.load();
rv.note_protocol('ncm');
eq(rv.counters.proto_ok, 1, 'revoke: an unchanged protocol name keeps the grant (note_protocol alone)');

rv.revoke_arming('the driver says qmi');
eq(rv.counters.proto_ok, 0, 'revoke: withdrawn explicitly');
eq(rv.on_attempt(), 'retry', 'revoke: attempt 8 no longer reaches the opmode cycle');

// and it does not come back across a restart
let rv2 = recovery.create({ id: 'pinned', failreboot: 40, fx: fx, state_dir: '/state', log: silent });
rv2.load();
eq(rv2.counters.proto_ok, 0, 'revoke: the withdrawal is persisted, not just in memory');

// revoking what was never granted is a no-op, not a rewrite
fx = fakefx.create();
let rv3 = recovery.create({ id: 'never', failreboot: 40, fx: fx, state_dir: '/state', log: silent });
rv3.revoke_arming('nothing to take');
eq(rv3.counters.proto_ok, 0, 'revoke: harmless when nothing was armed');

// The gate lives at the PRIMITIVE, because the ladder is not its only caller.
// The zero-rx watchdog repowers directly (modem_common.trip_zero_rx), which is
// reachable on a modem that never proved its protocol: a contradicted NCM pin
// still lets AT replies drive the state machine far enough to bring a context
// up, and a stall on that context would then power-cycle healthy hardware.
fx = fakefx.create();
let rz = recovery.create({ id: 'zerorx', failreboot: 40, fx: fx, state_dir: '/state',
	log: silent, reboot_delay: 10 });

eq(rz.usb_repower(), false, 'primitive: no repower while the channel has never answered');
eq(length(fx.matching('run usb-repower')), 0, 'primitive: ...and nothing was run');

rz.reboot('attempt limit');
uloop.timer(30, () => uloop.end());
uloop.run();
eq(length(fx.matching('run reboot')), 0, 'primitive: no reboot either, for the same reason');

// ...and once the modem does answer, both are available again
rz.note_answer();
eq(rz.usb_repower(), true, 'primitive: an answer restores the repower');

// the full path your reviewer asked for: persisted arming, revoked by a
// contradicted pin, zero-rx must then do nothing
fx = fakefx.create();
fx.files['/state/ztrip.json'] =
	'{ "attempts": 3, "proto_errors": 0, "rung": 0, "proto_hw": 0, "proto_ok": 1, "proto_name": "ncm" }';
let rt = recovery.create({ id: 'ztrip', failreboot: 40, fx: fx, state_dir: '/state', log: silent });
rt.load();
rt.note_protocol('ncm');
eq(rt.counters.proto_ok, 1, 'zero-rx: the inherited grant is there to lose');

rt.revoke_arming('the driver says qmi');
eq(rt.usb_repower(), false, 'zero-rx: a revoked modem is not repowered by the watchdog');
eq(length(fx.matching('run usb-repower')), 0, 'zero-rx: nothing physical happened');

// remove the contradiction, get legitimate evidence, and it works again
rt.note_answer();
eq(rt.usb_repower(), true, 'zero-rx: legitimate evidence restores it');

// note_answer arms WITHOUT touching the error counters — that is what separates
// it from on_proto_success, and conflating the two would silently disable the
// proto-error ladder (every service error would reset its own counter).
fx = fakefx.create();
let rn = recovery.create({ id: 'answer', failreboot: 100, proto_error_limit: 3,
	fx: fx, state_dir: '/state', log: silent });
for (let i = 1; i <= 3; i++) rn.on_proto_error();
rn.note_answer();
eq(rn.counters.proto_ok, 1, 'note_answer: arms');
eq(rn.counters.proto_errors, 3, 'note_answer: leaves the error counter alone');
rn.on_proto_success();
eq(rn.counters.proto_errors, 0, 'on_proto_success: still clears it');

// corrupted state file is ignored
fx.files['/state/bad.json'] = 'not json{';
let r3 = recovery.create({ id: 'bad', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
r3.on_proto_success();   /* control channel answered */
r3.load();
eq(r3.counters.attempts, 0, 'persist: corrupt state ignored');

// --- usb repower / reboot ----------------------------------------------------

fx = fakefx.create();
r = recovery.create({ id: 'm3', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
r.on_proto_success();   /* control channel answered */

eq(r.usb_repower(), true, 'repower: runs external tool');
eq(fx.matching('run usb-repower'), [ 'run usb-repower' ], 'repower: command invoked');

// missing tool: non-zero rc reported, no crash
fx = fakefx.create({ rc: { 'usb-repower': 127 } });
r = recovery.create({ id: 'm4', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
r.on_proto_success();   /* control channel answered */
eq(r.usb_repower(), false, 'repower: missing tool tolerated');

// reboot is deferred and deduplicated
fx = fakefx.create();
r = recovery.create({ id: 'm5', failreboot: 100, fx: fx, state_dir: '/state', log: silent, reboot_delay: 10 });
r.on_proto_success();   /* control channel answered */

r.reboot('test');
r.reboot('test again');

eq(length(fx.matching('run reboot')), 0, 'reboot: not immediate');

uloop.timer(50, () => uloop.end());
uloop.run();

eq(length(fx.matching('run reboot')), 1, 'reboot: fired once after delay');

done('test_recovery');
