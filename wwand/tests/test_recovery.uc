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
	if (r.on_qmi_error() == 'reboot' && hit == null)
		hit = i;

eq(hit, 26, 'errors: 26th error crosses ceiling of 25');

r.on_qmi_success();
eq(r.counters.qmi_errors, 0, 'errors: success resets counter');

// --- persistence -------------------------------------------------------------

fx = fakefx.create();
r = recovery.create({ id: 'wan', failreboot: 100, fx: fx, state_dir: '/state', log: silent });

r.on_attempt();
r.on_attempt();
r.on_qmi_error();

let r2 = recovery.create({ id: 'wan', failreboot: 100, fx: fx, state_dir: '/state', log: silent });
r2.load();

eq(r2.counters.attempts, 2, 'persist: attempts restored');
eq(r2.counters.qmi_errors, 1, 'persist: qmi errors restored');

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
