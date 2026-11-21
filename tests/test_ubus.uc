// wwand tests — the deferred-reply watchdog helper (ubus.uc defer()).
// Every deferred ubus method routes through defer(); this pins its contract:
// exactly one reply, req.defer() always called, and a watchdog that completes a
// wedged request (dropped backend callback) instead of leaking it open forever.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import { defer, publish } from 'wwand/ubus.uc';

uloop.init();

function fake_req() {
	let r = { replies: [], deferred: 0 };
	r.reply = (obj) => push(r.replies, obj);
	r.defer = () => { r.deferred++; };
	return r;
}

// --- happy path: the backend replies once ------------------------------------

let r1 = fake_req();
defer(r1, (reply) => reply({ ok: true, v: 1 }), 50);
eq(r1.deferred, 1, 'defer: req.defer() called');
eq(length(r1.replies), 1, 'happy: exactly one reply');
eq(r1.replies[0], { ok: true, v: 1 }, 'happy: the backend object is passed through verbatim');

// --- double reply: a second callback after completion is ignored -------------

let r2 = fake_req();
defer(r2, (reply) => { reply({ ok: true, n: 1 }); reply({ ok: true, n: 2 }); }, 50);
eq(length(r2.replies), 1, 'double: only the first reply is delivered');
eq(r2.replies[0].n, 1, 'double: the first reply wins');

// --- watchdog: a dropped backend callback is completed with a timeout --------

let steps = [], si = 0, run_next;
run_next = () => { if (si >= length(steps)) return uloop.end(); steps[si++](run_next); };

push(steps, (next) => {
	let r = fake_req();
	defer(r, (reply) => { /* backend never calls reply */ }, 30);
	eq(length(r.replies), 0, 'watchdog: no reply before the timeout');

	uloop.timer(70, () => {
		eq(length(r.replies), 1, 'watchdog: fired a reply after the timeout');
		eq(r.replies[0].ok, false, 'watchdog: reply is an error');
		eq(r.replies[0].error, 'timeout', 'watchdog: timeout error');
		next();
	});
});

// a backend that replies before the watchdog cancels it (watchdog never fires)
push(steps, (next) => {
	let r = fake_req();
	defer(r, (reply) => uloop.timer(10, () => reply({ ok: true, late: true })), 60);

	uloop.timer(120, () => {
		eq(length(r.replies), 1, 'cancel: exactly one reply (watchdog cancelled)');
		eq(r.replies[0].late, true, 'cancel: the real reply, not a timeout');
		next();
	});
});

// a late backend callback AFTER the watchdog already fired is ignored
push(steps, (next) => {
	let r = fake_req();
	let stash;
	defer(r, (reply) => { stash = reply; }, 20);   // capture, reply later

	uloop.timer(60, () => {
		eq(r.replies[0].error, 'timeout', 'late: watchdog fired first');
		stash({ ok: true, v: 9 });                 // backend finally replies
		eq(length(r.replies), 1, 'late: post-timeout reply is ignored');
		next();
	});
});

run_next();
uloop.run();

// Every method must declare ubus_rpc_session, and as a string. LuCI's calls
// reach the object through uhttpd-mod-ubus, which adds the session id to the
// arguments as a STRING (uhttpd ubus.c:564-579, 2026.06.16~7b1bec45), and
// ucode's ubus module refuses any argument its policy does not name, or names
// with another type (lib/ubus.c:2377-2385, ucode 2026.07.09~b885dd0f). A
// method that lost the declaration answers INVALID_ARGUMENT, which LuCI's
// legacy call format turns into an empty result — a silent `{}`, not an error.
{
	let table = null;
	let fake_conn = { publish: (name, methods) => { table = methods; return {}; } };

	publish(fake_conn, {}, null);

	ok(table != null && length(keys(table)) > 0, 'publish: the method table was handed over');

	let missing = [];

	for (let name, m in (table ?? {}))
		if (type(m?.args?.ubus_rpc_session) != 'string')
			push(missing, name);

	eq(missing, [], 'publish: every method accepts ubus_rpc_session as a string');

	// the same refusal for an op's own argument: `wwandctl esim discovery
	// <smds>` and a single `notify` by seq go through modem_esim, and an
	// undeclared one is refused before the daemon sees it
	let me = table?.modem_esim?.args ?? {};

	eq([ type(me.smds), type(me.seq) ], [ 'string', 'int' ], 'publish: modem_esim declares smds (string) and seq (int)');
}

done('test_ubus');
