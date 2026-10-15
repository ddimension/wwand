#!/usr/bin/env ucode
// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand-apntest — scheduled end-to-end APN tests on a dedicated test box.
// The plan is /etc/config/apntest (apntest/plan.uc), the sweep apntest/runner.uc;
// this file is the command line and the real side effects behind `ops`.

'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as ubus from 'ubus';
import * as plan_mod from 'wwand.apntest.plan';
import * as runner from 'wwand.apntest.runner';

const STATE_DIR = '/tmp/wwand-apntest';
const LAST_FILE = STATE_DIR + '/last.json';
const LOCK_FILE = STATE_DIR + '/run.lock';
// names the interface whose test parameters are pending in the uci delta
// directory: written before they are set, removed after they are reverted
const DIRTY_FILE = STATE_DIR + '/dirty';
const SEND_NSCA = '/usr/bin/send_nsca';
const CRONTAB = '/etc/crontabs/root';
const CRON_BEGIN = '# wwand-apntest begin — managed, edit /etc/config/apntest';
const CRON_END = '# wwand-apntest end';

const HELP = `wwand-apntest — end-to-end APN tests through wwand

  wwand-apntest check          validate /etc/config/apntest (exit 1 on errors)
  wwand-apntest list           the plan, grouped by SIM as it will run
  wwand-apntest run [test]     run the sweep (or one test) and report it
  wwand-apntest last           the last verdict per service
  wwand-apntest cron-sync [off]  write (or remove) the cron line of globals.schedule
  wwand-apntest recover        undo what a killed run left behind
`;

function sh_quote(s)
{
	return "'" + replace('' + s, /'/g, "'\\''") + "'";
}

function syslog_log(level, msg)
{
	// stdout for a person at the shell, syslog for cron
	print(sprintf('%s: %s\n', level, msg));
	system(sprintf('logger -t wwand-apntest -p daemon.%s -- %s',
		(level == 'err' || level == 'warn' || level == 'notice' || level == 'debug') ? level : 'info',
		sh_quote(msg)));
}

function load_plan()
{
	let cur = uci.cursor();

	return plan_mod.parse(cur.get_all('apntest') ?? {});
}

function real_ops()
{
	let conn = ubus.connect();
	let cur = uci.cursor();

	if (!conn)
		die('wwand-apntest: cannot connect to ubus\n');

	return {
		ubus: (obj, method, args) => conn.call(obj, method, args ?? {}),
		uci_get_all: (config) => {
			cur.unload(config);
			return cur.get_all(config);
		},
		// UNCOMMITTED: saved to the uci delta directory, where the daemon's
		// own cursor sees it, and never written to flash
		uci_set: (config, section, option, value) => {
			if (value == null)
				cur.delete(config, section, option);
			else
				cur.set(config, section, option, '' + value);
			cur.save(config);
		},
		uci_revert: (config, section) => cur.revert(config, section),
		// true only once the marker is on disk: without it a killed run
		// could not be cleaned up, so the runner does not dial
		mark_dirty: (iface) => {
			fs.mkdir(STATE_DIR);
			return fs.writefile(DIRTY_FILE, iface + '\n') != null;
		},
		clear_dirty: () => fs.unlink(DIRTY_FILE),
		exec: (argv) => {
			let p = fs.popen(join(' ', map(argv, sh_quote)) + ' 2>&1', 'r');

			if (!p)
				return { code: -1, out: '' };

			let out = p.read('all');

			return { code: p.close(), out: out };
		},
		pipe: (argv, input) => {
			let p = fs.popen(join(' ', map(argv, sh_quote)) + ' >/dev/null 2>&1', 'w');

			if (!p)
				return -1;

			p.write(input);
			return p.close();
		},
		read: (path) => fs.readfile(path),
		// 0600 from the first byte: created with that mode, not chmod'ed after
		secret_file: (content) => {
			fs.mkdir(STATE_DIR);

			let path = sprintf('%s/curl-auth.%d', STATE_DIR, time());
			let f = fs.open(path, 'w', 384);   // 0600

			if (!f)
				return null;

			f.write(content);
			f.close();
			return path;
		},
		unlink: (path) => fs.unlink(path),
		sleep: (ms) => sleep(ms),
		now: () => time(),
		log: syslog_log,
	};
}

function print_errors(errs)
{
	for (let e in errs)
		warn(sprintf('plan: %s\n', e));
}

// what the plan needs from the box beyond its own validity
function runtime_errors(p)
{
	let errs = [];

	if (p.globals?.monitor && !fs.access(SEND_NSCA, 'x'))
		push(errs, sprintf('globals: monitor is set but %s is not installed (package nsca-ng) — no verdict would reach it', SEND_NSCA));

	// the accounting check downloads and asks the operator's API with curl
	let acct = filter(p.tests ?? [], (t) => length(filter(t.checks, (c) => c.name == 'accounting')));

	if (length(acct) && !fs.access('/usr/bin/curl', 'x'))
		push(errs, sprintf('test %s: the accounting check needs curl (/usr/bin/curl), which is not installed', acct[0].name));

	return errs;
}

// A RUN THAT WAS KILLED left its test parameters in the uci delta directory,
// where the next ordinary ifup would dial them. Only the interface the marker
// names is touched, and only its pending changes are dropped — the runner
// writes nothing else.
function cmd_recover(quiet)
{
	let iface = trim(fs.readfile(DIRTY_FILE) ?? '');

	if (!length(iface)) {
		if (!quiet)
			print('nothing to recover\n');
		return 0;
	}

	// the marker goes only once both steps did: dropped early, a stale test
	// APN would stay pending with nothing left to say so
	let conn = ubus.connect();

	if (!conn) {
		warn('recover: no ubus — left pending\n');
		return 1;
	}

	conn.call(sprintf('network.interface.%s', iface), 'down', {});

	let cur = uci.cursor();

	// revert() answers null when nothing was pending (a run killed between
	// its revert and dropping the marker), so the proof is what is left
	cur.revert('network', iface);

	// a FRESH cursor: the one that reverted does not report the delta
	// directory again; changes() answers { network: [ [op, section, …] ] }
	let left = filter(uci.cursor().changes('network')?.network ?? [], (c) => c[1] == iface);

	if (length(left)) {
		warn(sprintf('recover: network.%s still has %d pending change(s) — left pending\n', iface, length(left)));
		return 1;
	}

	if (!fs.unlink(DIRTY_FILE)) {
		warn(sprintf('recover: cannot remove %s\n', DIRTY_FILE));
		return 1;
	}

	syslog_log('notice', sprintf('recovered %s: test parameters of an interrupted run dropped, interface down', iface));
	return 0;
}

function cmd_check()
{
	let p = load_plan();

	p.errors = [ ...p.errors, ...runtime_errors(p) ];
	print_errors(p.errors);

	if (!length(p.errors))
		print(sprintf('plan ok: %d test(s) on %d SIM(s)\n',
			length(filter(p.tests, (t) => !t.disabled)), length(p.groups)));

	return length(p.errors) ? 1 : 0;
}

function cmd_list()
{
	let p = load_plan();

	print_errors(p.errors);

	for (let g in p.groups) {
		print(sprintf('SIM %s (%s)\n', g.sim.name,
			g.sim.profile ? sprintf('profile %s', g.sim.profile) : sprintf('slot %d', g.sim.slot)));

		for (let t in g.tests)
			print(sprintf('  %-20s apn %-28s %s\n', t.name, t.apn,
				join(', ', map(t.checks, (c) => sprintf('%s -> %s', c.raw, c.service)))));
	}

	return length(p.errors) ? 1 : 0;
}

function save_last(verdicts)
{
	fs.mkdir(STATE_DIR);

	let raw = fs.readfile(LAST_FILE);
	let last = {};

	try {
		last = raw ? json(raw) : {};
	}
	catch (e) {
		last = {};
	}

	if (type(last) != 'object')
		last = {};

	for (let v in verdicts)
		last[v.service] = v;

	return fs.writefile(LAST_FILE + '.tmp', sprintf('%J\n', last)) != null &&
	       fs.rename(LAST_FILE + '.tmp', LAST_FILE);
}

function cmd_run(only)
{
	let p = load_plan();

	p.errors = [ ...p.errors, ...runtime_errors(p) ];

	if (length(p.errors)) {
		print_errors(p.errors);
		syslog_log('err', sprintf('plan has %d error(s) — not running', length(p.errors)));
		return 3;
	}

	if (only && !length(filter(p.tests, (t) => t.name == only))) {
		warn(sprintf('no test %J in the plan\n', only));
		return 3;
	}

	// one sweep at a time: cron fires again while a long sweep still runs
	fs.mkdir(STATE_DIR);

	let lock = fs.open(LOCK_FILE, 'w');

	if (!lock || !lock.lock('xn')) {
		syslog_log('notice', 'a sweep is already running — not starting another');
		return 0;
	}

	// whatever a killed predecessor left pending goes first — and if that
	// cannot be cleaned up, no new test parameters go on top of it
	if (cmd_recover(true) != 0) {
		syslog_log('err', 'a previous run left test parameters pending and they could not be dropped — not running');
		return 3;
	}

	let r = runner.create(p, real_ops());
	let verdicts = r.run(only);
	let undelivered = r.report();

	if (!save_last(verdicts))
		syslog_log('err', sprintf('could not write %s', LAST_FILE));

	lock.lock('u');
	lock.close();

	let worst = 0;

	for (let v in verdicts)
		if (v.state > worst)
			worst = v.state;

	// a verdict that did not reach the monitor is a run nobody saw: cron's
	// exit status must not say all was well
	return undelivered ? 3 : worst;
}

function cmd_last()
{
	let raw = fs.readfile(LAST_FILE);

	if (!raw) {
		print('no run recorded since boot\n');
		return 0;
	}

	let last;

	try {
		last = json(raw);
	}
	catch (e) {
		last = null;
	}

	if (type(last) != 'object') {
		warn(sprintf('%s is not a verdict record\n', LAST_FILE));
		return 1;
	}

	for (let s in sort(keys(last)))
		print(sprintf('%-32s %-8s %s\n', s, last[s].state_text, last[s].message));

	return 0;
}

// the plan's schedule as a managed block in root's crontab; no schedule (or
// `off`, from the init script's stop) removes it. Restarting cron makes it
// re-read the file. A plan with errors leaves the existing line alone: the
// box keeps testing on the last good plan instead of silently stopping.
function cmd_cron_sync(mode)
{
	let p = load_plan();
	let sched = (mode == 'off') ? null : p.globals?.schedule;

	if (mode != 'off' && length(p.errors)) {
		print_errors(p.errors);
		warn('cron line left as it was\n');
		return 1;
	}

	if (sched != null && !runner.cron_ok(sched)) {
		warn(sprintf('globals: schedule %J is not five cron fields — cron line left as it was\n', sched));
		return 1;
	}

	let old = fs.readfile(CRONTAB) ?? '';
	let lines = [], skip = false;

	for (let l in split(old, '\n')) {
		if (l == CRON_BEGIN) { skip = true; continue; }
		if (l == CRON_END) { skip = false; continue; }
		if (!skip)
			push(lines, l);
	}

	while (length(lines) && lines[length(lines) - 1] == '')
		pop(lines);

	if (sched)
		push(lines, CRON_BEGIN, sprintf('%s /usr/sbin/wwand-apntest run >/dev/null 2>&1', trim(sched)), CRON_END);

	let text = join('\n', lines) + '\n';

	if (text == old)
		return 0;

	fs.mkdir('/etc/crontabs');

	if (fs.writefile(CRONTAB, text) == null) {
		warn(sprintf('cannot write %s\n', CRONTAB));
		return 1;
	}

	// busybox crond re-reads a crontab only on a signal or a restart
	if (system('/etc/init.d/cron restart >/dev/null 2>&1') != 0) {
		warn('cron restart failed — the new line takes effect at the next cron start\n');
		return 1;
	}

	return 0;
}

const COMMANDS = {
	check: () => cmd_check(),
	list: () => cmd_list(),
	run: () => cmd_run(ARGV[1]),
	last: () => cmd_last(),
	'cron-sync': () => cmd_cron_sync(ARGV[1]),
	recover: () => cmd_recover(false),
};

let cmd = ARGV[0];

if (cmd != null && COMMANDS[cmd])
	exit(COMMANDS[cmd]());

print(HELP);
exit((cmd == null || cmd == 'help') ? 0 : 1);
