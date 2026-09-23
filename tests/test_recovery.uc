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

// THE REBOOT WINDOW STARTS AT THE HARDWARE RESET, NOT AT ZERO.
//
// The tests above arm the channel FIRST, so the count begins climbing with
// proto_ok already set and the absolute `n > limit*2` gate happened to be
// right. The field case is the opposite: a control channel that never answers
// produces nothing but protocol errors, the ladder refuses the hardware rung
// while unarmed (it looks like the wrong protocol, not broken hardware), and n
// runs far past 2x limit sitting at 'retry'. The first decoded reply — an
// error reply counts — arms proto_ok; the next error fires the repower; and
// the error after THAT satisfied `n > limit*2` on the strength of counting
// that happened before the reset was even attempted. The router rebooted while
// the modem was still inside its reset hold, which is the reboot-loop this
// rung was added to prevent (NR7101). Found by a full review, 2026-09-19.
r = recovery.create({ id: 'unarmed', failreboot: 100, proto_error_limit: 3,
	fx: fx, state_dir: '/state', log: silent });

let uacts = [];

/* 20 errors with the channel never having answered: far past 2x3 */
for (let i = 1; i <= 20; i++)
	push(uacts, r.on_proto_error());

let physical = filter(uacts, (a) => a != 'retry');
eq(length(physical), 0, 'window: nothing physical while the channel has never answered');

r.note_answer();   /* the modem finally decodes something — an error reply */

eq(r.on_proto_error(), 'usb_repower', 'window: the first error after arming takes the hardware rung');
eq(r.counters.proto_hw_base, 21, 'window: ...and the window is anchored at that count');

/* the modem is inside its reset hold: the next errors must NOT reboot */
let after = [];
for (let i = 1; i <= 3; i++)
	push(after, r.on_proto_error());

eq(after, [ 'retry', 'retry', 'reboot' ],
	'window: a further full window (3) of errors is required before the reboot');

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

// --- the one exception: a named RESET line on an unarmed modem ---------------
// The gate above is right about power: the 2026-08-30 report was repeated
// power-cycling of a healthy misdetected modem, and the box in that case has no
// reset line at all (see `unarmed pulse: power-cycle box` below, which is the
// same construction WITHOUT reset_line and must stay fully blocked).
//
// It is wrong about one board: an NR7101 whose profile exports the modem's own
// RESET line for exactly the wedge it suffers (ddimension/wwand#40, reported
// 2026-09-23). The arming evidence lives in tmpfs, so every reboot turns a
// modem that has worked for months into one that never answered, and the rung
// written for that hardware can never fire. One pulse of that named line, once
// per outage, is what the modem-reset BUTTON already does on the same modem
// unguarded (hwops.repower_modem) — this just stops waking the operator up.
let pulses = [];
fx = fakefx.create();
let ru = recovery.create({ id: 'unarmed_reset', failreboot: 30, fx: fx,
	state_dir: '/state', log: silent,
	repower: () => { push(pulses, 'board'); return true; },
	reset_line: () => 'gpio515' });

let ua = [];
for (let i = 1; i <= 23; i++) push(ua, ru.on_attempt());

eq(length(filter(ua, (a) => a != 'retry')), 0,
	'unarmed pulse: the cheaper rungs stay blocked — no opmode cycle at 8, no modem reset at 16');

eq(ru.on_attempt(), 'usb_repower', 'unarmed pulse: fires at the repower threshold (24)');
eq(ru.usb_repower(), true, 'unarmed pulse: the primitive lets THIS one through');
eq(pulses, [ 'board' ], 'unarmed pulse: the board action actually ran');

// ...and never again this outage: the token was consumed, the flag is set
eq(ru.usb_repower(), false,
	'unarmed pulse: a second call is refused — the grant was for one call, so the zero-rx watchdog cannot inherit it');

let ua_rest = [];
for (let i = 25; i <= 40; i++) push(ua_rest, ru.on_attempt());
eq(length(filter(ua_rest, (a) => a != 'retry')), 0,
	'unarmed pulse: once per outage, and the reboot past failreboot 30 stays refused');
eq(length(pulses), 1, 'unarmed pulse: exactly one pulse');
eq(ru.counters.rung, 0,
	'unarmed pulse: the armed ladder index is untouched — sharing it would mark opmode and modem-reset fired');

// ...and the bound survives a daemon restart, because an outage does. The state
// file is the only thing that carries it: without the restore, a procd respawn
// loop on a modem already past the threshold would pulse the reset line once
// per start — the exact repetition the guard exists to prevent.
let ru2 = recovery.create({ id: 'unarmed_reset', failreboot: 30, fx: fx,
	state_dir: '/state', log: silent,
	repower: () => { push(pulses, 'restarted'); return true; },
	reset_line: () => 'gpio515' });
ru2.load();

eq(ru2.counters.unarmed_reset, 1,
	'unarmed pulse: a restart mid-outage remembers the pulse already spent');
eq(ru2.on_attempt(), 'retry',
	'unarmed pulse: and does not fire a second one');
eq(length(pulses), 1, 'unarmed pulse: still exactly one');

// the armed ladder is therefore still complete for this modem
ru.on_proto_success();
eq(ru.on_attempt(), 'opmode_cycle',
	'unarmed pulse: after arming, the ladder starts at its first rung as if nothing had fired');

// the exception is per outage, exactly like `rung`
ru.on_connect_success();
eq(ru.counters.unarmed_reset, 0, 'unarmed pulse: a successful connection clears the allowance');

// a state file written before this key existed simply has not fired it
fx.files['/state/legacy_ur.json'] =
	'{ "attempts": 30, "proto_errors": 0, "rung": 0, "proto_hw": 0, "proto_ok": 0, "proto_name": "qmi" }';
let rlg = recovery.create({ id: 'legacy_ur', failreboot: 30, fx: fx,
	state_dir: '/state', log: silent,
	repower: () => { push(pulses, 'legacy'); return true; },
	reset_line: () => 'gpio515' });
rlg.load();
eq(rlg.counters.unarmed_reset, 0, 'unarmed pulse: a pre-upgrade state file has not spent it');
eq(rlg.on_attempt(), 'usb_repower', 'unarmed pulse: so it is still available after an upgrade');

// --- ...and the three ways it must NOT fire ---------------------------------
// 1. a box whose hardware action is a power cycle: the 2026-08-30 case itself
fx = fakefx.create();
let rpc = recovery.create({ id: 'unarmed_pc', failreboot: 30, fx: fx,
	state_dir: '/state', log: silent,
	repower: () => { push(pulses, 'power'); return true; },
	reset_line: () => null });

let pc = [];
for (let i = 1; i <= 40; i++) push(pc, rpc.on_attempt());
eq(length(filter(pc, (a) => a != 'retry')), 0,
	'unarmed pulse: power-cycle box — nothing physical, the original rule intact');
eq(rpc.usb_repower(), false, 'unarmed pulse: power-cycle box — the primitive refuses too');

// 2. no board profile at all (most boxes): no reset_line callback is passed
fx = fakefx.create();
let rnb = recovery.create({ id: 'unarmed_nb', failreboot: 30, fx: fx,
	state_dir: '/state', log: silent });

let nb = [];
for (let i = 1; i <= 40; i++) push(nb, rnb.on_attempt());
eq(length(filter(nb, (a) => a != 'retry')), 0,
	'unarmed pulse: no board profile — nothing physical');

// 2b. a reset_gpio option that is PRESENT BUT EMPTY. uci keeps `option
// reset_gpio ''` as an empty string; `??` passes it through while every consumer
// that acts on it tests truthiness, so the ladder would have authorised a reset
// and the board would have cut power instead — the one action the guard exists
// to prevent, on an unarmed modem. Raised by Codex review, 2026-09-23.
fx = fakefx.create();
let rem = recovery.create({ id: 'unarmed_empty', failreboot: 30, fx: fx,
	state_dir: '/state', log: silent,
	repower: () => { push(pulses, 'empty'); return true; },
	reset_line: () => '' });

let em = [];
for (let i = 1; i <= 40; i++) push(em, rem.on_attempt());
eq(length(filter(em, (a) => a != 'retry')), 0,
	'unarmed pulse: an empty reset_gpio is not a reset line');
eq(rem.usb_repower(), false, 'unarmed pulse: and the primitive refuses it too');

// 3. the pin is KNOWN wrong: arm_blocked is the active form of a misdetection,
// and no pulse of any line fixes a language mismatch
fx = fakefx.create();
let rab = recovery.create({ id: 'unarmed_blocked', failreboot: 30, fx: fx,
	state_dir: '/state', log: silent,
	repower: () => { push(pulses, 'blocked'); return true; },
	reset_line: () => 'gpio515' });
rab.revoke_arming('driver contradicts the configured protocol');

let ab = [];
for (let i = 1; i <= 40; i++) push(ab, rab.on_attempt());
eq(length(filter(ab, (a) => a != 'retry')), 0,
	'unarmed pulse: a contradicted protocol pin gets no pulse');
eq(length(pulses), 1, 'unarmed pulse: still exactly the one from the NR7101 case');

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

// A PROTOCOL CHANGE VOIDS THE WHOLE PROTO-ERROR LADDER, not just the arming.
//
// note_protocol cleared proto_ok alone, so the next protocol inherited the
// error count, the fired-once hardware flag and its window base: it skipped
// its own hardware reset (proto_hw was already 1) and then rebooted the router
// on a window measured partly under the protocol it had just stopped speaking.
// Raised by Codex review, 2026-09-19.
fx = fakefx.create();
let rs = recovery.create({ id: 'ladderswitch', failreboot: 100, proto_error_limit: 3,
	fx: fx, state_dir: '/state', log: silent });

rs.note_protocol('qmi');
rs.note_answer();

let sacts = [];
for (let i = 1; i <= 4; i++)
	push(sacts, rs.on_proto_error());

eq(sacts[3], 'usb_repower', 'switch: qmi took its hardware rung');
eq(rs.counters.proto_hw, 1, 'switch: ...and recorded it');
eq(rs.counters.proto_hw_base, 4, 'switch: ...with its window base');

rs.note_protocol('mbim');
eq([ rs.counters.proto_ok, rs.counters.proto_errors,
     rs.counters.proto_hw, rs.counters.proto_hw_base ], [ 0, 0, 0, 0 ],
	'switch: the new protocol inherits nothing from the old one');

/* and it gets its OWN hardware reset before any reboot */
rs.note_answer();

let sacts2 = [];
for (let i = 1; i <= 4; i++)
	push(sacts2, rs.on_proto_error());

eq(sacts2, [ 'retry', 'retry', 'retry', 'usb_repower' ],
	'switch: mbim reaches its own reset, not a reboot');

// REVOCATION TAKES THE HARDWARE RUNG TOO, even when the arming was already
// gone. The early return left proto_hw and the window base standing, and
// arm_blocked is deliberately not persisted — so after a restart with a
// corrected configuration the modem could arm afresh while still carrying a
// rung it never fired in this incarnation. Raised by Codex review, 2026-09-19.
fx = fakefx.create();
fx.files['/state/stale.json'] =
	'{ "attempts": 0, "proto_errors": 9, "rung": 0, "proto_hw": 1, "proto_hw_base": 4, "proto_ok": 0, "proto_name": "ncm" }';
let rstale = recovery.create({ id: 'stale', failreboot: 40, proto_error_limit: 3,
	fx: fx, state_dir: '/state', log: silent });
rstale.load();
eq(rstale.counters.proto_hw, 1, 'revoke: the stale rung is on file');

rstale.revoke_arming('the driver says qmi');
eq([ rstale.counters.proto_hw, rstale.counters.proto_hw_base, rstale.counters.proto_errors ],
	[ 0, 0, 0 ],
	'revoke: ...and revocation takes it, not only the arming flag');

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

// A withdrawal blocks EVERY later arming path, not just the grant it cleared.
// Three of them can set the permission — note_answer, on_proto_success and
// on_connect_success — and leaving them free to set it again made the
// withdrawal last only until the next one fired. That is how a modem pinned to
// a protocol its driver contradicts re-armed through a connection coming "up",
// which on NCM means the dial and the IP read finished and says nothing about
// packets moving.
rt.note_answer();
eq(rt.counters.proto_ok, 0, 'zero-rx: an answer does not lift a withdrawal');
rt.on_proto_success();
eq(rt.counters.proto_ok, 0, 'zero-rx: nor a successful request');
rt.on_connect_success();
eq(rt.counters.proto_ok, 0, 'zero-rx: nor a connection coming up');
eq(rt.usb_repower(), false, 'zero-rx: so the watchdog still cannot repower it');

// ...and the block is NOT persisted: it is derived from the configuration on
// every build, so correcting the pin lifts it by simply not setting it again.
let rt2 = recovery.create({ id: 'ztrip', failreboot: 40, fx: fx, state_dir: '/state', log: silent });
rt2.load();
rt2.note_protocol('ncm');
rt2.note_answer();
eq(rt2.counters.proto_ok, 1, 'zero-rx: a rebuild without the contradiction arms normally');

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
