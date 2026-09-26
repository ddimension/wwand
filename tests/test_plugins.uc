// wwand tests — plugins.uc, the optional-plugin registry, and the simops
// helpers it hands to plugins (connection token, eSIM lock).

'use strict';

import * as fs from 'fs';
import * as plugins from 'wwand/plugins.uc';
import * as simops from 'wwand/simops.uc';
import * as daemon_mod from 'wwand/daemon.uc';
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

// --- the daemon's deps: sim_upsert re-reads the config after a write --------------

{
	let captured = null, upserts = [], reloads = 0;
	let answer = { written: true, section: 'wwsim_1' };
	let d = daemon_mod.create({ deps: {
		log: () => null,
		plugins: [ { name: 'cap', options: [], mod: { create: (dd) => { captured = dd; return {}; } } } ],
		sim_upsert: (iccid, fields, origin, opts) => { push(upserts, [ iccid, fields, origin, opts ]); return answer; },
	} });

	d.reload = () => reloads++;
	d.esim_guard('m0', 'enable');   // loads the plugins
	ok(type(captured?.sim_upsert) == 'function', 'deps: a plugin gets sim_upsert');

	let r = captured.sim_upsert('8949', { apn: 'a' }, 'cap', { create_only: true });
	eq(r, answer, 'deps: sim_upsert answers what the writer said');
	eq(upserts, [ [ '8949', { apn: 'a' }, 'cap', { create_only: true } ] ], 'deps: ...having passed everything on');
	eq(reloads, 1, 'deps: a write is re-read at once');

	answer = { written: false, reason: 'foreign' };
	captured.sim_upsert('8949', { apn: 'a' }, 'cap');
	eq(reloads, 1, 'deps: nothing written, nothing reloaded');
}

// --- qmi_client: a client on the modem's channel, or the reason there is none ---

{
	let captured = null;
	let d = daemon_mod.create({ deps: {
		log: () => null,
		plugins: [ { name: 'cap', options: [], mod: { create: (dd) => { captured = dd; return {}; } } } ],
	} });

	d.esim_guard('m0', 'enable');   // loads the plugins
	ok(type(captured?.qmi_client) == 'function', 'deps: a plugin gets qmi_client');

	let res = {};
	let schema = { service: 0x32, messages: {} };

	d.modems = { gone: { modem: null }, mbim: { modem: {} },
	             qmi: { modem: { extra_client: (s, cb) => cb(null, { service: s.service, cid: 7 }),
	                             extra_release: (c, cb) => { res.released = c.cid; cb?.(null); } } } };

	captured.qmi_client('nope', schema, (e) => { res.nope = e?.error; });
	captured.qmi_client('gone', schema, (e) => { res.gone = e?.error; });
	captured.qmi_client('mbim', schema, (e) => { res.mbim = e?.error; });
	captured.qmi_client('qmi', schema, (e, c) => { res.qmi = c?.cid; });
	captured.qmi_release('qmi', { cid: 7 });

	eq(res.nope, 'no_modem', 'qmi_client: an unknown modem says so');
	eq(res.gone, 'no_modem', 'qmi_client: ...as does a modem that is not running');
	eq(res.mbim, 'unsupported', 'qmi_client: a modem without a QMI channel of its own is unsupported, not a crash');
	eq(res.qmi, 7, 'qmi_client: a QMI modem hands out the client');
	eq(res.released, 7, 'qmi_release: and takes it back through the modem, which owns it');
}

// --- sim_changed: a plugin that swaps the card gets the slot switch's process ---

{
	let captured = null;
	let d = daemon_mod.create({ deps: {
		log: () => null,
		plugins: [ { name: 'cap', options: [], mod: { create: (dd) => { captured = dd; return {}; } } } ],
	} });

	d.esim_guard('m0', 'enable');   // loads the plugins
	ok(type(captured?.sim_changed) == 'function', 'deps: a plugin gets sim_changed');

	let m = { info: { iccid: '8949', imsi: '26201', msisdn: '49' }, sim_note: 'session closed: card removed',
	          active_sim: { pincode: '1234' }, _esim_be: 'at', _apdu_be: 'at', esim_info: {}, _gen: 1 };

	d.modems = { m0: { modem: m } };

	eq(captured.sim_changed('nope', 'x'), false, 'sim_changed: an unknown modem is a no-op');

	let at_got = null;

	m.at = { send: (cmd, cb) => cb(null, { lines: [ '+CSIM: 4,"9000"' ] }) };
	captured.modem_at('m0', 'AT+CSIM=10,"00B0000002"', (e, r) => { at_got = r?.lines; });
	eq(at_got, [ '+CSIM: 4,"9000"' ], 'modem_at: a plugin reaches the modem\'s AT channel');
	delete m.at;
	eq(captured.sim_changed('m0', 'remote SIM'), true, 'sim_changed: a running modem is told');
	eq([ m.info.iccid, m.info.imsi, m.info.msisdn ], [ null, null, null ],
	   'sim_changed: the old card\'s identity is forgotten, not shown for the new one');
	eq(m.active_sim, null, 'sim_changed: ...and its per-SIM override, whose PIN must not reach the new card');
	eq(m.sim_note, null, 'sim_changed: ...and its parting note');
	eq([ m._esim_be, m._apdu_be, m.esim_info ], [ null, null, null ], 'sim_changed: ...and the eSIM/APDU caches');
}

// --- status rows: what optional packages report about a modem ----------------

{
	let logs = [];
	let d = daemon_mod.create({ deps: {
		log: (l, m) => push(logs, m),
		plugins: [
			{ name: 'a', options: [ 'a_x' ], mod: { create: () => ({
				status: (ref, ext) => (ext.a_x ? { label: 'remote SIM', text: 'in use', level: 'ok' } : null) }) } },
			{ name: 'b', options: [], mod: { create: () => ({
				status: () => [ { label: 'x', text: 1, level: 'bogus' }, { label: 'no text' } ] }) } },
			{ name: 'c', options: [], mod: { create: () => ({ status: () => die('boom') }) } },
		],
	} });

	d.modems = { m0: { ext: { a_x: '1' } }, m1: { ext: {} } };

	eq(d.plugins_status('m0'), [
		{ plugin: 'a', label: 'remote SIM', text: 'in use', level: 'ok' },
		{ plugin: 'b', label: 'x', text: '1', level: 'ok' },
	], 'status rows: one per report, text made a string, an unknown level is ok, a row without text dropped');
	eq(length(d.plugins_status('m1')), 1, 'status rows: a plugin with nothing to say adds nothing');

	d.plugins_status('m0');
	eq(length(filter(logs, (l) => index(l, 'status failed') >= 0)), 1,
	   'status rows: a plugin that throws costs its row, logged once — not every second of LuCI polling');
}

for (let f in fs.lsdir(tmp) ?? [])
	fs.unlink(sprintf('%s/%s', tmp, f));
fs.rmdir(tmp);

done('test_plugins');
