// wwand tests — plugins.uc, the optional-plugin registry, and the simops
// helpers it hands to plugins (connection token, eSIM lock).

'use strict';

import * as fs from 'fs';
import * as plugins from 'wwand/plugins.uc';
import * as simops from 'wwand/simops.uc';
import { eq, ok, done } from './lib/check.uc';

// --- discovery -------------------------------------------------------------------

let tmp = sprintf('%s/wwand-test-plugins-%d', getenv('TMPDIR') ?? '/tmp', time());
fs.mkdir(tmp);
for (let f in [ 'alpha.uc', 'broken.uc', 'Bad-Name.uc', 'notes.txt' ])
	fs.writefile(sprintf('%s/%s', tmp, f), '');

let calls = [];
let inst = null;   // declared before the stub that returns it (ucode scoping)
let stubs = {
	alpha: { name: 'alpha', options: [ 'alpha', 'alpha_interval' ], create: (d) => { push(calls, 'create'); return inst; } },
	broken: null,
};
let notes = [];
let found = plugins.list(tmp, (n) => {
	if (n == 'broken')
		die('syntax error');
	return stubs[n];
}, notes);

eq(map(found, (p) => p.name), [ 'alpha' ], 'discover: a well-formed plugin is found, the rest is not');
eq(length(notes), 1, 'discover: a plugin that fails to load is noted, not fatal');
eq(plugins.option_names(found), [ 'alpha', 'alpha_interval' ], 'discover: its options are known');

// --- hooks --------------------------------------------------------------------------

let ticks = [];
inst = {
	tick: (ref, ext) => push(ticks, [ ref, ext ]),
	esim_guard: (ref, op, ext) => (ext.alpha == '1') ? { reason: 'alpha has it' } : null,
	ops: {
		status: (ref, ext, args, cb) => cb(null, { ok: true, ref: ref }),
		poll:   (ref, ext, args, cb) => cb(null, { started: true }),
	},
	read_ops: [ 'status' ],
};

let self = {
	modems: { m0: { modem: {}, ext: { alpha: '1' } }, m1: { modem: {}, ext: {} } },
	contexts: {},
};
plugins.install(self, { log: () => null, plugins: found, deps: {} });

self.plugins_tick();
eq(ticks, [ [ 'm0', { alpha: '1' } ], [ 'm1', {} ] ], 'tick: every modem, with its own options');
eq(calls, [ 'create' ], 'tick: the plugin is created once');

eq(self.esim_guard('m0', 'enable'), { by: 'alpha', reason: 'alpha has it' }, 'guard: the plugin that manages the card says so');
eq(self.esim_guard('m1', 'enable'), null, 'guard: a card it does not manage is free');

let res = null;
self.modem_plugin('m0', 'alpha', 'status', {}, (e, r) => { res = [ e, r ]; }, true);
eq(res, [ null, { ok: true, ref: 'm0' } ], 'ubus: the read-only twin reaches a read op');
self.modem_plugin('m0', 'alpha', 'poll', {}, (e, r) => { res = [ e, r ]; }, true);
eq(res[0]?.error, 'permission_denied', 'ubus: ...and not an op that is not declared read-only');
self.modem_plugin('m0', 'alpha', 'poll', {}, (e, r) => { res = [ e, r ]; }, false);
eq(res, [ null, { started: true } ], 'ubus: the write method reaches it');
self.modem_plugin('m0', 'nosuch', 'status', {}, (e, r) => { res = [ e, r ]; }, false);
eq(res[0]?.error, 'no_such_plugin', 'ubus: an unknown plugin is named as such');

// --- simops: the lock and the connection token -------------------------------------

self.contexts = {
	wan_b: { cfg: { modem: 'm0' }, ctx: { state: 'CONNECTED' }, _conn_seq: 4 },
	wan_a: { cfg: { modem: 'm0' }, ctx: { state: 'CONNECTING' }, _conn_seq: 9 },
};
simops.install(self, {
	log: () => null,
	check_modem: (ref, cb) => self.modems[ref] ?? (cb({ error: 'no_such_modem' }), null),
	load_esim: () => ({}),
});

let got = null;
self.modem_esim('m0', 'enable', { iccid: '8949' }, (e, r) => { got = e; });
eq([ got?.error, got?.by ], [ 'esim_managed', 'alpha' ], 'lock: a profile change on a managed card is refused, naming the plugin');
self.modem_esim('m0', 'notify', {}, (e, r) => { got = e; });
eq(got?.error, 'esim_managed', 'lock: so is sending its notifications');
got = null;
self.modem_esim('m0', 'enable', { force: true }, (e, r) => { got = e; });
ok(got?.error != 'esim_managed', 'lock: force goes past it');
self.modem_esim('m1', 'enable', {}, (e, r) => { got = e; });
ok(got?.error != 'esim_managed', 'lock: a card no plugin manages is not locked');

eq(self.connection_token('m0'), 'wan_b:4', 'token: the connected context and its generation');
eq(self.connection_token('m1'), null, 'token: null for a modem with nothing connected');

for (let f in fs.lsdir(tmp) ?? [])
	fs.unlink(sprintf('%s/%s', tmp, f));
fs.rmdir(tmp);

done('test_plugins');
