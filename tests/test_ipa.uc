// wwand tests — ipa.uc, the eIM poll scheduler (wwand-ipa), and the simops
// side of it: the eSIM lock on an eIM-managed card and the connection token.
//
// The assistant itself is a C program (feed: wwand-ipad) with its own tests;
// here the bridge is a fake that records the command line and plays the
// assistant's side of the stdio protocol.

'use strict';

import * as uloop from 'uloop';
import * as simops from 'wwand/simops.uc';
import { eq, ok, done } from './lib/check.uc';

let ipa = require('wwand.ipa');

// --- pure helpers -------------------------------------------------------------

eq(ipa.tac_of('351234567890123'), '35123456', 'tac: first 8 digits of the IMEI');
eq(ipa.tac_of('35123'), null, 'tac: a short IMEI gives no TAC');
eq(ipa.tac_of(null), null, 'tac: no IMEI, no TAC');

eq(ipa.interval_of({}), 3600, 'interval: default 3600 s');
eq(ipa.interval_of({ ipa_interval: 60 }), 300, 'interval: floored at 300 s');
eq(ipa.interval_of({ ipa_interval: 7200 }), 7200, 'interval: taken as set');

let T = { settle: 60, retry: 600 };

eq(ipa.due({}, {}, T), null, 'due: never while offline');
eq(ipa.due({ online_since: 1000 }, {}, T), 1060, 'due: first run after the settle time');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: true }, {}, T), 5600,
	'due: after a good run, the interval');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: false }, {}, T), 2600,
	'due: after a failed run, the shorter retry');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: false }, { ipa_interval: 300 }, T), 2300,
	'due: the retry never exceeds the interval');

// the fleet spread: fixed per device, different between devices
let sa = ipa.spread_of('351234567890123'), sb = ipa.spread_of('351234567890124');
ok(sa >= 0 && sa < 1 && sb >= 0 && sb < 1, 'spread: a fraction in [0, 1)');
eq(ipa.spread_of('351234567890123'), sa, 'spread: the same device always gets the same one');
ok(sa != sb, 'spread: neighbouring IMEIs do not');
eq(ipa.spread_of(null), 0, 'spread: none without an IMEI');

let T2 = { settle: 60, settle_spread: 300, retry: 600 };
eq(ipa.due({ online_since: 1000, spread: 0.5 }, {}, T2), 1210,
	'due: the first run waits the settle time plus its share of the spread');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: true, spread: 0.5 }, {}, T2), 5780,
	'due: a good run adds up to a tenth of the interval, per device');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: false, fails: 2 }, {}, T2), 3200,
	'due: the retry doubles with each consecutive failure');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: false, fails: 3 }, {}, T2), 4400,
	'due: and again');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: false, fails: 9 }, {}, T2), 5600,
	'due: but never beyond the interval');

eq(ipa.build_cmd({ ipad: '/x/ipad', nvstate: '/s/E.nvstate' }),
	"/x/ipad -E -H -n '/s/E.nvstate' 2>&1",
	'cmd: always emulation (-E) and host-driven (-H), its log into the pipe (syslog)');
eq(ipa.build_cmd({ ipad: '/x/ipad', nvstate: '/s/E.nvstate', tac: '35123456',
                   eim_id: 'eim.example', insecure: true, init_cfg: '/etc/e.ber' }),
	"/x/ipad -E -H -n '/s/E.nvstate' -t 35123456 -e 'eim.example' -I -f '/etc/e.ber' 2>&1",
	'cmd: TAC, eIM id, insecure and the provisioning file');

// its log lines, as libipa/log.c writes them ("%8s %8s " subsystem, level)
eq(ipa.log_level('    HTTP    ERROR HTTP request failed'), 'warn', 'log: ERROR is a warning');
eq(ipa.log_level('     IPA     INFO Generic eUICC Package Download'), 'info', 'log: INFO is info');
eq(ipa.log_level('   SCARD    DEBUG stdio TX: 81E2910003BF2200'), 'debug', 'log: DEBUG (the APDU traffic) is debug');
eq(ipa.log_level(' nvstate path: /etc/wwand/ipa/x'), 'debug', 'log: main.c parameter chatter is debug');

// --- the scheduler against a fake bridge ---------------------------------------

const EID = '89049032123451234512345678901235';

let clock = 1000;
let files = {};
let online = null;           // the connection token the fake daemon reports
let runs = [];               // command lines ipa_run was given
let resets = 0;
let reset_res = {};          // what apply_sim_reset answers
let modem_resets = [];
let logs = [];
let script = null;           // what the fake assistant does in a run
let refreshes = [];          // profile-list re-reads the scheduler asked for
let card_after = null;       // the profile list a re-read finds

let bridge = {
	ipa_run: (ref, slot, cmd, log_level, on_ipa, on_done) => {
		push(runs, cmd);
		return script ? script(on_ipa, on_done) : (on_done(null, ''), null);
	},
	apply_sim_reset: (ref, slot, cb) => { resets++; cb(null, reset_res); },
};

let modem = { info: { imei: '351234567890123' } };

let mk = (over) => ipa.create({
	bridge: bridge,
	esim: { get_eid: (m, slot, cb) => cb(null, { eid: EID }) },
	log: (lvl, msg) => push(logs, msg),
	modem_of: (ref) => (ref == 'm1') ? { modem: modem } : null,
	online: () => online,
	ipad_path: '/x/ipad', state_dir: '/s',
	// no first-run spread here, and the clock below steps 4000 s at a time,
	// past the interval plus its largest per-device stretch (3600 + 360)
	timing: { settle: 60, settle_spread: 0, retry: 600, online_timeout: 1, online_poll: 0.01 },
	now: () => clock,
	exists: (p) => p == '/x/ipad' || !!files[p],
	modem_reset: (ref, cb) => { push(modem_resets, ref); cb(null, {}); },
	refresh: (ref, eid, slot, cb) => {
		push(refreshes, [ ref, eid, slot ]);

		if (card_after != null)
			cb(map(card_after, (i) => ({ iccid: i })));
	},
	...(over ?? {}),
});

let s = mk();
let on = { ipa: true };

s.tick('m1', { ipa: false });
eq(length(runs), 0, 'tick: nothing without option ipa');

s.tick('m1', on);
eq(length(runs), 0, 'tick: nothing while offline');

online = 'wan:1';
s.tick('m1', on);
eq(length(runs), 0, 'tick: online, but not settled yet');

clock += 60;
s.tick('m1', on);
eq(s.status('m1', on).last_error, 'no_eim_config',
	'first run: a card without nvstate and no eIM configuration is refused, not guessed');
eq(length(runs), 0, 'first run: the assistant is not started without an eIM');

// provisioning: the configured eIM file exists, the card has no nvstate yet
files['/etc/wwand/eim.ber'] = true;
let cfg = { ipa: true, ipa_eim_config: '/etc/wwand/eim.ber' };
clock += 600;
s.tick('m1', cfg);
eq(length(runs), 2, 'provision: one run stores the eIM, a second polls it');
ok(index(runs[0], "-f '/etc/wwand/eim.ber'") >= 0, 'provision: first run carries -f');
ok(index(runs[1], '-f') < 0, 'provision: the poll does not');
ok(index(runs[0], sprintf("-n '/s/%s.nvstate'", EID)) >= 0, 'provision: nvstate keyed by the card\'s EID');
ok(index(runs[0], '-t 35123456') >= 0, 'provision: TAC from the modem\'s IMEI');
eq(s.status('m1', cfg).last_ok, true, 'provision: the run counts as good');

eq(refreshes, [ [ 'm1', EID, 1 ] ], 'refresh: the profile list is read again after a run that reached the card');

// the nvstate exists now: a later run only polls
files[sprintf('/s/%s.nvstate', EID)] = true;
runs = [];
clock += 4000;
s.tick('m1', cfg);
eq(length(runs), 1, 'poll: a known card is polled directly');

// an eIM id that could break out of the command line is refused
runs = [];
clock += 4000;
s.tick('m1', { ipa: true, ipa_eim_id: "x'; reboot; '" });
eq(length(runs), 0, 'safety: an eIM id with shell characters never reaches the shell');
eq(s.status('m1', cfg).state, 'idle', 'safety: and the scheduler is not left busy');

// a failed run: the assistant exits non-zero
script = (on_ipa, on_done) => { on_done({ error: 'lpac', code: 234 }, ''); return null; };
runs = [];
clock += 4000;
s.tick('m1', cfg);
eq(s.status('m1', cfg).last_error, 'exit 234', 'failure: the exit status is reported');
eq(s.status('m1', cfg).next_due, clock + 600, 'failure: retried after the retry time');

// busy: the bridge refuses (an lpac operation holds the card)
script = (on_ipa, on_done) => ({ error: 'busy' });
clock += 600;
s.tick('m1', cfg);
eq(s.status('m1', cfg).last_error, 'busy', 'busy: a refused start is a failed run, not a stuck one');
eq(s.status('m1', cfg).state, 'idle', 'busy: the scheduler is free again');
refreshes = [];
clock += 4000;
s.tick('m1', cfg);
eq(refreshes, [], 'refresh: not after a run that never reached the card');

// --- a profile change: reset the SIM, wait for a NEW connection ---------------

let answers = [];

script = (on_ipa, on_done) => {
	on_ipa({ kind: 'ipa', event: 'profile_changed' }, (obj) => {
		push(answers, obj);
		on_done(null, '');
	});
	return null;
};

online = 'wan:1';
resets = 0;
clock += 4000;
s.tick('m1', cfg);
eq(resets, 1, 'profile change: the SIM is reset so the modem takes the new profile');
eq(s.status('m1', cfg).state, 'waiting_online', 'profile change: waiting for the connection');

// the old session is still CONNECTED: that must not count as "back"
uloop.init();
uloop.timer(50, () => {
	eq(length(answers), 0, 'profile change: the still-connected old session is not the answer');
	online = 'wan:2';   // the daemon brought up a new session
});
uloop.timer(150, () => uloop.end());
uloop.run();

eq(answers, [ { online: true } ], 'profile change: a new connection generation is');
eq(s.status('m1', cfg).profile_changes, 1, 'profile change: counted');
eq(s.status('m1', cfg).state, 'idle', 'profile change: the run completed');

// the connection never comes back: the assistant is told so (it rolls back)
answers = [];
online = 'wan:2';
clock += 4000;
s.tick('m1', cfg);
online = null;
let t0 = clock;
uloop.init();
uloop.timer(30, () => { clock = t0 + 2; });   // past online_timeout
uloop.timer(150, () => uloop.end());
uloop.run();
eq(answers, [ { online: false } ], 'profile change: no connection by the deadline is reported as such');

// still the OLD session at the deadline: not back either
answers = [];
online = 'wan:2';
clock += 4000;
s.tick('m1', cfg);
t0 = clock;
uloop.init();
uloop.timer(30, () => { clock = t0 + 2; });
uloop.timer(150, () => uloop.end());
uloop.run();
eq(answers, [ { online: false } ], 'profile change: the pre-reset session at the deadline is not "back"');

// the assistant dies while we wait: the pending check must not revive the run
let died = null;
script = (on_ipa, on_done) => {
	on_ipa({ kind: 'ipa', event: 'profile_changed' }, (obj) => push(answers, obj));
	died = on_done;
	return null;
};
answers = [];
clock += 4000;
s.tick('m1', cfg);
died({ error: 'timeout', code: -1 }, '');
eq(s.status('m1', cfg).state, 'idle', 'dead run: idle at once');
online = 'wan:3';   // a new session arrives after the run is already over
uloop.init();
uloop.timer(150, () => uloop.end());
uloop.run();
eq(s.status('m1', cfg).state, 'idle', 'dead run: a late check does not put it back to running');
eq(answers, [], 'dead run: and nothing is answered to a process that is gone');

// --- what a run did to the card ------------------------------------------------

// a switch A -> B, reported with the ICCIDs the modem read before and after
// the SIM reset; the list comparison finds C installed and D deleted
modem.info.iccid = 'A';
modem.esim_info = { profiles: [ { iccid: 'A' }, { iccid: 'B' }, { iccid: 'D' } ] };
card_after = [ 'A', 'B', 'C' ];
script = (on_ipa, on_done) => {
	on_ipa({ kind: 'ipa', event: 'profile_changed' }, (obj) => on_done(null, ''));
	return null;
};
online = 'wan:5';
clock += 4000;
s.tick('m1', cfg);
modem.info.iccid = 'B';   // the re-read after the SIM reset
uloop.init();
uloop.timer(20, () => { online = 'wan:6'; });
uloop.timer(150, () => uloop.end());
uloop.run();
eq(s.status('m1', cfg).last_changes,
	{ switched: [ { from: 'A', to: 'B', rollback: false } ], installed: [ 'C' ], deleted: [ 'D' ] },
	'changes: the switch, and what the list comparison found installed and deleted');

// the eIM stays unreachable on B: the assistant rolls back to A in the same run
modem.esim_info = { profiles: [ { iccid: 'A' }, { iccid: 'B' } ] };
card_after = [ 'A', 'B' ];
let step_no = 0;
script = (on_ipa, on_done) => {
	let next;
	next = () => on_ipa({ kind: 'ipa', event: 'profile_changed' }, () => {
		if (++step_no < 2) {
			next();
			modem.info.iccid = 'A';   // the rollback's SIM reset re-reads A
			uloop.timer(20, () => { online = 'wan:11'; });
			return;
		}
		on_done(null, '');
	});
	next();
	return null;
};
modem.info.iccid = 'A';
online = 'wan:9';
clock += 4000;
s.tick('m1', cfg);
modem.info.iccid = 'B';
uloop.init();
uloop.timer(20, () => { online = 'wan:10'; });
uloop.timer(300, () => uloop.end());
uloop.run();
eq(s.status('m1', cfg).last_changes?.switched,
	[ { from: 'A', to: 'B', rollback: false }, { from: 'B', to: 'A', rollback: true } ],
	'changes: a switch back to where the run started is the rollback');
eq(s.status('m1', cfg).last_changes?.installed, [], 'changes: nothing installed');

// no list from before: no installed/deleted claims
modem.esim_info = null;
card_after = [ 'A', 'B' ];
script = null;
clock += 4000;
s.tick('m1', cfg);
eq(s.status('m1', cfg).last_changes, { switched: [], installed: null, deleted: null },
	'changes: without a list from before, nothing is claimed installed');

// the SIM power cycle fails: the modem is reset instead, and the new ICCID is
// read from the modem object the reset creates, not the one from the event
reset_res = { apply: 'modem_reset' };
modem_resets = [];
modem.info.iccid = 'A';
script = (on_ipa, on_done) => {
	on_ipa({ kind: 'ipa', event: 'profile_changed' }, (obj) => on_done(null, ''));
	return null;
};
online = 'wan:20';
clock += 4000;
s.tick('m1', cfg);
eq(modem_resets, [ 'm1' ], 'reset fallback: no SIM power cycle, so the modem is reset — nobody else would');
modem = { info: { imei: '351234567890123', iccid: 'B' } };   // the object after the reset
uloop.init();
uloop.timer(20, () => { online = 'wan:21'; });
uloop.timer(150, () => uloop.end());
uloop.run();
eq(s.status('m1', cfg).last_changes?.switched, [ { from: 'A', to: 'B', rollback: false } ],
	'reset fallback: the new ICCID comes from the modem that exists now');
reset_res = {};

// a dual-SIM module whose eUICC is the active card in physical slot 2: that
// is the card managed, whatever sim_slot says
modem.slot_status = (cb) => cb(null, [ { physical: 1, is_euicc: false, active: false },
                                       { physical: 2, is_euicc: true, active: true } ]);
script = null;
refreshes = [];
clock += 4000;
s.tick('m1', cfg);
eq(refreshes[0]?.[2], 2, 'slot: the active eUICC\'s physical slot, not the configured one');
delete modem.slot_status;

// --- the real bridge: the assistant's log reaches the syslog, not a file ------

import * as fs from 'fs';

let bridge_mod = require('wwand.esim_bridge');
let tmp = getenv('TMPDIR') ?? '/tmp';
let stub = sprintf('%s/wwand-test-ipad.sh', tmp);
let sf = fs.open(stub, 'w');
sf.write("#!/bin/sh\n" +
	"echo '    HTTP    ERROR eIM unreachable' >&2\n" +
	"echo '{\"type\":\"ipa\",\"payload\":{\"event\":\"profile_changed\"}}'\n" +
	"read line\n" +
	"echo \"   SCARD    DEBUG host said $line\" >&2\n" +
	"exit 3\n");
sf.close();

try { fs.mkdir('/tmp/wwand'); } catch (e) { }
fs.writefile('/tmp/wwand/esim-download.log', 'lpac run\n');

let seen = [];
let br = bridge_mod.create({ esim: {}, log: (lvl, msg) => push(seen, [ lvl, msg ]),
	modem_of: (r) => ({ modem: { id: r, _esim_op: 0 } }) });
let rres = null;

uloop.init();
let started = br.ipa_run('m0', 1, sprintf('sh %s 2>&1', stub), ipa.log_level,
	(rec, reply) => reply({ online: true }),
	(err, out) => { rres = { err, out }; uloop.end(); });
uloop.timer(5000, () => uloop.end());
uloop.run();

eq(started, null, 'bridge: the run starts');
eq(rres?.err?.code, 3, 'bridge: the exit status is the verdict');
eq(rres?.out, '', 'bridge: no log file to hand back');
let lvl_of = (needle) => {
	for (let e in seen)
		if (index(e[1], needle) >= 0)
			return e[0];
	return null;
};
eq(lvl_of('eIM unreachable'), 'warn', 'bridge: its ERROR line reaches the syslog as a warning');
eq(lvl_of('host said {"type":"ipa","payload":{ "online": true }}'), 'debug',
	'bridge: the answer to profile_changed arrived, and its DEBUG line is debug');
eq(fs.readfile('/tmp/wwand/esim-download.log'), 'lpac run\n', 'bridge: lpac\'s log file is left alone');
fs.unlink(stub);

// --- simops: the eSIM lock and the connection token ----------------------------

let self = {
	modems: { m1: { modem: {}, ipa: { ipa: true } }, m2: { modem: {}, ipa: { ipa: false } } },
	contexts: {
		wan_b: { cfg: { modem: 'm1' }, ctx: { state: 'CONNECTED' }, _conn_seq: 4 },
		wan_a: { cfg: { modem: 'm1' }, ctx: { state: 'CONNECTING' }, _conn_seq: 9 },
	},
};

simops.install(self, {
	log: () => null,
	check_modem: (ref, cb) => self.modems[ref] ?? (cb({ error: 'no_such_modem' }), null),
	load_esim: () => ({}),
});

let got = null;
self.modem_esim('m1', 'enable', { iccid: '8949' }, (e, r) => { got = e; });
eq(got?.error, 'ipa_managed', 'lock: a profile change on an eIM-managed card is refused');

self.modem_esim('m1', 'notify', {}, (e, r) => { got = e; });
eq(got?.error, 'ipa_managed', 'lock: so is sending its notifications past the eIM');

got = null;
self.modem_esim('m1', 'enable', { force: true }, (e, r) => { got = e; });
ok(got?.error != 'ipa_managed', 'lock: force goes past it');

self.modem_esim('m2', 'enable', {}, (e, r) => { got = e; });
ok(got?.error != 'ipa_managed', 'lock: a card without option ipa is not locked');

// option ipa set, but wwand-ipa is not installed: nothing manages the card
let self2 = { modems: { m1: { modem: {}, ipa: { ipa: true } } }, contexts: {} };
simops.install(self2, {
	log: () => null,
	check_modem: (ref, cb) => self2.modems[ref],
	load_esim: () => ({}),
	require_ipa: () => die('not installed'),
});
got = null;
self2.modem_esim('m1', 'enable', {}, (e, r) => { got = e; });
ok(got?.error != 'ipa_managed', 'lock: without wwand-ipa nothing manages the card, so nothing is locked');

eq(self._online_token('m1'), 'wan_b:4', 'token: the connected context and its generation');
eq(self._online_token('m2'), null, 'token: null for a modem with nothing connected');

done('test_ipa');
