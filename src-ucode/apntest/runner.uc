// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand-apntest — the runner: one sweep over a parsed plan (apntest/plan.uc).
//
// Synchronous by design. A sweep is a strict sequence — select a SIM, dial,
// check, hang up, next — run from cron on a box that does nothing else, so an
// event loop would add states without adding concurrency. Every side effect
// goes through `ops`, which is what makes the whole sweep testable on a host:
//
//   ops.ubus(object, method, args)   -> reply object or null
//   ops.uci_get_all(config)          -> { section: { ... } }
//   ops.uci_set(config, section, option, value)   (value null = delete)
//   ops.uci_revert(config, section)  -> drop the uncommitted changes
//   ops.exec(argv)                   -> { code, out }
//   ops.pipe(argv, input)            -> exit code (input on stdin)
//   ops.mark_dirty(iface), ops.clear_dirty()  -> a test's uci changes are
//                                    pending (the CLI's crash recovery)
//   ops.read(path)                   -> file contents or null (netdev counters)
//   ops.secret_file(content) -> path, ops.unlink(path)
//                                    a mode-0600 file for credentials, so
//                                    they never appear in a command line
//   ops.sleep(ms), ops.now() (seconds), ops.log(level, msg)
//
// HOW A TEST DIALS. The test's APN and credentials are written to the test
// interface as UNCOMMITTED uci changes, the interface is brought up through
// netifd, and the changes are reverted afterwards. The daemon re-reads an
// interface's connection options on every up, through a uci cursor that sees
// uncommitted changes (ctx_settings.uc refresh_context_cfg, main.uc
// load_config), and netifd does the addressing as in production — so a test
// exercises the same path a customer's box does, without one flash write per
// run. A `wwand_sim` entry for the card under test overrides the interface's
// APN (context_common conn_cfg: per-SIM wins); the runner refuses such a test
// rather than report on an APN it did not dial.

'use strict';

// Icinga/NSCA states
export const OK = 0, WARNING = 1, CRITICAL = 2, UNKNOWN = 3;
const STATE_NAMES = [ 'OK', 'WARNING', 'CRITICAL', 'UNKNOWN' ];

// The thresholds of the tool this replaces (/usr/sbin/apntester): 5 priming
// pings, then 10; more than 50 % loss is critical, more than 20 % a warning.
const PING_PRIME = 5, PING_COUNT = 10;
const LOSS_CRITICAL = 50, LOSS_WARNING = 20;

// registration wait: the old tool's 120 s
const REG_WAIT_S = 120;
// a slot switch ends in a modem reset and a re-enumeration
const SLOT_WAIT_S = 180;
// the ping check at most: -w 5 priming, then -w 20
const PING_MAX_S = 30;
// netifd tears down asynchronously; the next test must not dial into it
const DOWN_WAIT_S = 30;

// `ping` output (busybox or iputils) -> { loss, rta } (rta in ms, null if no
// reply came back). null when the output carries no statistics at all.
export function parse_ping(out)
{
	let loss = match(out ?? '', /([0-9.]+)% packet loss/);

	if (!loss)
		return null;

	let rta = match(out, /min\/avg\/max[^=]*= *[0-9.]+\/([0-9.]+)\//);

	return { loss: +loss[1], rta: rta ? +rta[1] : null };
};

// The schedule goes into ROOT'S crontab (apntest_cli.uc cron-sync), so it is
// checked first: five fields of cron characters and nothing else — a value
// carrying a newline would add a command of its own.
const CRON_FIELD = /^[0-9A-Za-z*\/,-]+$/;

export function cron_ok(sched)
{
	if (type(sched) != 'string' || match(sched, /[\r\n]/))
		return false;

	let f = split(trim(sched), /[ \t]+/);

	return length(f) == 5 && length(filter(f, (x) => match(x, CRON_FIELD))) == 5;
};

// --- accounting ---------------------------------------------------------------
//
// WHAT THE OPERATOR COUNTED FOR THIS SESSION. The m-ccp status answer for a
// globalsim card carries no running traffic counter — it lists the card's
// last sessions, each with bytesIn/bytesOut and a bytesTotal rounded up to
// the operator's block (roundingBytes) (application/vnd.mccp.api-v2+xml,
// api-ng.m-ccp.de, read 2026-10-03). The tool this replaces read
// `grep bytesTotal | tail -n1` before and after its download and subtracted:
// that is the total of the OLDEST listed session, so the difference measured
// nothing. Here the session itself is compared: the box counts the bytes on
// the interface from up to down, the session record (found by start time and
// APN once the session has ended and been accounted) says what the operator
// billed.

// the download that makes the session big enough to compare (the old test's)
const ACCT_URL = 'http://217.14.168.5/mccp-accounting';
// the operator writes the record after the session ends; the old test waited
// 180 s for the counters, then this many more polls a minute apart
const ACCT_SETTLE_S = 180, ACCT_RETRIES = 2, ACCT_RETRY_S = 60;
// a session record starting this much before the box's dial time is still
// this session (clock skew between the box and the operator)
const ACCT_SKEW_S = 300;
// the download's own limit, and what an accounting check needs left of the
// budget to be worth starting at all
const ACCT_DOWNLOAD_S = 60, ACCT_API_S = 30;
const CHECK_MIN_S = { ping: PING_MAX_S, accounting: ACCT_DOWNLOAD_S + ACCT_SETTLE_S + ACCT_API_S };

// ISO 8601 with offset ("2025-07-17T16:50:21+02:00", "…Z") -> epoch seconds,
// null when it is not one. ucode has no date parser; days_from_civil is
// H. Hinnant's algorithm.
export function iso_epoch(str)
{
	// POSIX ERE (ucode): no (?:…), so the fraction is group 7, the zone 8
	let m = match(str ?? '', /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$/);

	if (!m)
		return null;

	let y = +m[1], mo = +m[2], d = +m[3];

	y -= (mo <= 2) ? 1 : 0;

	let era = int(((y >= 0) ? y : y - 399) / 400);
	let yoe = y - era * 400;
	let doy = int((153 * (mo + ((mo > 2) ? -3 : 9)) + 2) / 5) + d - 1;
	let doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy;
	let days = era * 146097 + doe - 719468;
	let t = days * 86400 + (+m[4]) * 3600 + (+m[5]) * 60 + (+m[6]);

	if (m[8] != 'Z') {
		let o = match(m[8], /^([+-])([0-9]{2}):?([0-9]{2})$/);
		let off = (+o[2]) * 3600 + (+o[3]) * 60;

		t -= (o[1] == '+') ? off : -off;
	}

	return t;
};

// the <session> records of an m-ccp status answer
export function mccp_sessions(xml)
{
	let out = [];
	let tag = (blk, name) => {
		// POSIX bracket: `]` first after `^` is literal (`\]` is not an escape)
		let m = match(blk, regexp(sprintf('<%s>(<!\\[CDATA\\[)?([^]<]*)', name)));
		return m ? m[2] : null;
	};

	// a byte field that is not a plain number makes the record unusable —
	// coerced, it would be NaN, and every band comparison false: "OK"
	let uint = (blk, name) => {
		let v = tag(blk, name);
		return (v != null && match(v, /^[0-9]+$/)) ? +v : null;
	};

	// `<session` with or without attributes (the real answer carries
	// xmlns and id), and only up to its own end tag
	for (let blk in split(xml ?? '', '<session')) {
		if (!match(blk, /^[ \t\r\n>]/))
			continue;

		blk = split(blk, '</session>')[0];

		if (index(blk, '<startTime>') < 0)
			continue;

		push(out, {
			start: iso_epoch(tag(blk, 'startTime')),
			end: iso_epoch(tag(blk, 'endTime')),
			apn: tag(blk, 'apn'),
			ip: tag(blk, 'ipv4Address'),
			bytes_in: uint(blk, 'bytesIn'),
			bytes_out: uint(blk, 'bytesOut'),
			bytes_total: uint(blk, 'bytesTotal'),
		});
	}

	return out;
};

// the operator's raw count (in + out) against the box's: the old tool's
// bands — more than 2x critical, more than 10 % over a warning — and less
// than 90 % critical (the old test wanted at least 100 %, which a lost last
// packet already failed)
export function acct_state(iface_bytes, acct_bytes)
{
	if (acct_bytes > 2 * iface_bytes)
		return [ CRITICAL, 'too much traffic on the operator side, more than 2x' ];

	if (acct_bytes > iface_bytes * 1.1)
		return [ WARNING, 'too much traffic on the operator side, but less than 2x' ];

	if (acct_bytes < iface_bytes * 0.9)
		return [ CRITICAL, 'the operator counted less than the interface carried' ];

	return [ OK, 'Accounting correct' ];
};

// one NSCA line: host<TAB>service<TAB>code<TAB>message|perfdata
export function nsca_line(host, service, code, msg, perf)
{
	let text = replace(msg ?? '', /[\t\n]/g, ' ');

	if (length(perf ?? ''))
		text = sprintf('%s|%s', text, perf);

	return sprintf('%s\t%s\t%d\t%s\n', host, service, code, text);
};

// a configured regex against a value; a pattern that does not compile is a
// failed check with its reason, never an exception that ends the sweep
function rx_match(pattern, value)
{
	let re;

	try {
		re = regexp(pattern);
	}
	catch (e) {
		return { error: sprintf('invalid regex %J', pattern) };
	}

	return { hit: match(value ?? '', re) != null };
}

function perf_text(p)
{
	let parts = [];

	for (let k in sort(keys(p ?? {})))
		if (p[k] != null)
			push(parts, sprintf('%s=%s', k, '' + p[k]));

	return join(', ', parts);
}

// the interface a test dials: the configured one, else the only `proto wwand`
// interface bound to the plan's modem. cb-free, returns { name } or { error }.
export function resolve_interface(globals, network)
{
	if (globals?.interface)
		return network?.[globals.interface] ? { name: globals.interface }
			: { error: sprintf('interface %J is not in /etc/config/network', globals.interface) };

	let found = [];

	for (let name, s in (network ?? {}))
		if (s['.type'] == 'interface' && s.proto == 'wwand' && s.modem == globals?.modem)
			push(found, name);

	if (length(found) == 1)
		return { name: found[0] };

	return { error: length(found)
		? sprintf('modem %J has %d wwand interfaces (%s) — set `option interface` in globals',
			globals?.modem, length(found), join(', ', found))
		: sprintf('no `proto wwand` interface is bound to modem %J', globals?.modem) };
};

// a wwand_sim entry for this card that would override the test's connection
// options; null when there is none
function sim_override(network, iccid, imsi)
{
	for (let name, s in (network ?? {})) {
		if (s['.type'] != 'wwand_sim')
			continue;

		let hit = (iccid != null && s.iccid != null && index(iccid, s.iccid) == 0) ||
		          (imsi != null && s.imsi != null && s.imsi == imsi);

		// every field a wwand_sim may override on a connection
		// (context_common.uc SIM_OVERRIDABLE)
		if (hit && (s.apn != null || s.auth != null || s.username != null ||
		            s.password != null || s.pdp_type != null))
			return name;
	}

	return null;
}

export function create(plan, ops)
{
	let g = plan.globals ?? {};
	let log = ops.log;
	let verdicts = [];
	let started = ops.now();

	let modem_of = () => ops.ubus('wwand', 'status', {})?.modems?.[g.modem];
	let left = (deadline) => {
		let l = deadline - ops.now();
		return (l > 0) ? l : 0;
	};
	let at_most = (a, b) => (a < b) ? a : b;
	let netif = (iface) => sprintf('network.interface.%s', iface);

	// wait until the modem is registered (READY), at most `secs`
	let wait_ready = (secs) => {
		let until = ops.now() + secs;

		for (;;) {
			let m = modem_of();

			if (m?.state == 'READY')
				return m;

			if (ops.now() >= until)
				return null;

			ops.sleep(2000);
		}
	};

	let verdict = (test, service, state, msg, perf) => {
		let v = { test: test, service: service, state: state,
		          state_text: STATE_NAMES[state], message: msg,
		          perfdata: perf ?? null, time: ops.now() };

		push(verdicts, v);
		log(state == OK ? 'info' : 'warn', sprintf('%s: %s - %s', service, STATE_NAMES[state], msg));
		return v;
	};

	// the test failed before its checks: the first check reports the reason
	// under the test's service, the others say they did not run
	let fail_test = (t, state, msg, perf) => {
		verdict(t.name, t.service, state, sprintf('%s - %s', STATE_NAMES[state], msg), perf);

		for (let i = 1; i < length(t.checks); i++)
			verdict(t.name, t.checks[i].service, UNKNOWN,
				sprintf('UNKNOWN - not run: %s', msg), null);
	};

	let check_ping = (t, c, ctx) => {
		let host = c.arg;

		if (!length(host ?? ''))
			return [ UNKNOWN, 'UNKNOWN - ping needs a host (ping:<host>)', null ];

		ops.exec([ 'ping', '-c', '' + PING_PRIME, '-w', '' + PING_PRIME, '-I', ctx.dev, host ]);

		let r = ops.exec([ 'ping', '-c', '' + PING_COUNT, '-W', '10', '-w', '20', '-I', ctx.dev, host ]);
		let p = parse_ping(r?.out);

		if (!p)
			return [ CRITICAL, sprintf('CRITICAL - IP:%s, DNS:%s, Ping: %s, no statistics from ping',
				ctx.ip, ctx.dns, host), null ];

		let perf = { percent_packet_loss: p.loss, rta: p.rta, duration: ctx.duration, tries: 1 };
		let rta = (p.rta != null) ? sprintf('%s', '' + p.rta) : '-';

		if (p.loss > LOSS_CRITICAL)
			return [ CRITICAL, sprintf('CRITICAL - IP:%s, DNS:%s, Ping: %s, Packet loss too high: %s%%, RTA %sms',
				ctx.ip, ctx.dns, host, '' + p.loss, rta), perf ];

		if (p.loss > LOSS_WARNING)
			return [ WARNING, sprintf('WARNING - IP:%s, DNS:%s, Ping: %s, Packet loss high: %s%%, RTA %sms',
				ctx.ip, ctx.dns, host, '' + p.loss, rta), perf ];

		return [ OK, sprintf('OK - IP: %s, DNS: %s, Ping: %s, Loss: %s%%, RTA %sms',
			ctx.ip, ctx.dns, host, '' + p.loss, rta), perf ];
	};

	// the checks of this phase; anything else answers UNKNOWN — a check that
	// cannot run must never look like one that passed
	// rx + tx of the test interface's netdev, null when unreadable
	let netdev_bytes = (dev) => {
		let rx = ops.read(sprintf('/sys/class/net/%s/statistics/rx_bytes', dev));
		let tx = ops.read(sprintf('/sys/class/net/%s/statistics/tx_bytes', dev));

		return (rx == null || tx == null) ? null : (+trim(rx)) + (+trim(tx));
	};

	// DURING the session only the traffic: the verdict needs the session's
	// record, which exists once it has ended (acct_evaluate, after the down).
	// Returns null = no verdict now.
	let check_accounting = (t, c, ctx) => {
		let url = length(c.arg ?? '') ? c.arg : ACCT_URL;
		let r = ops.exec([ 'curl', '-sS', '-f', '-o', '/dev/null', '-m', '' + ACCT_DOWNLOAD_S,
			'--interface', ctx.dev, url ]);

		ctx.acct = { check: c, url: url, download: r?.code ?? -1 };
		return null;
	};

	let CHECKS = { ping: check_ping, accounting: check_accounting };

	let run_checks = (t, ctx, deadline) => {
		for (let c in t.checks) {
			let fn = CHECKS[c.name];

			// the sweep's budget bounds the checks too
			if (fn && left(deadline) < (CHECK_MIN_S[c.name] ?? PING_MAX_S)) {
				verdict(t.name, c.service, UNKNOWN, 'UNKNOWN - run budget exhausted before this check', null);
				continue;
			}

			if (!fn) {
				verdict(t.name, c.service, UNKNOWN,
					sprintf('UNKNOWN - check %s is not available in this version', c.name), null);
				continue;
			}

			let r = fn(t, c, ctx);

			if (r != null)
				verdict(t.name, c.service, r[0], r[1], r[2]);
		}
	};

	let apply_params = (iface, t) => {
		ops.uci_set('network', iface, 'apn', t.apn);
		ops.uci_set('network', iface, 'auth', t.auth);
		ops.uci_set('network', iface, 'username', t.username);
		ops.uci_set('network', iface, 'password', t.password);
		ops.uci_set('network', iface, 'pdp_type', t.pdp_type);
	};

	// the interface's IPv4 address, DNS and L3 device once up, or null
	let wait_up = (iface, secs) => {
		let until = ops.now() + secs;

		for (;;) {
			let st = ops.ubus(sprintf('network.interface.%s', iface), 'status', {});
			let a = st?.['ipv4-address']?.[0]?.address;

			let dev = st?.l3_device ?? st?.device;

			if (st?.up && a && dev)
				return { ip: a, dns: join(' ', st['dns-server'] ?? []), dev: dev, status: st };

			if (ops.now() >= until)
				return { error: st?.errors?.[0]?.code ?? (st?.up ? 'no IPv4 address' : 'interface did not come up') };

			ops.sleep(2000);
		}
	};

	// settled down: netifd reports neither up nor pending
	let wait_down = (iface, secs) => {
		let until = ops.now() + secs;

		for (;;) {
			let st = ops.ubus(netif(iface), 'status', {});

			if (st != null && !st.up && !st.pending)
				return true;

			if (ops.now() >= until)
				return false;

			ops.sleep(1000);
		}
	};

	// the dial and its checks, after the parameters are in place; anything
	// that throws in here is the test's UNKNOWN, never the sweep's end
	let dial_and_check = (t, iface, t0, deadline) => {
		ops.ubus(netif(iface), 'up', {});

		let budget = t.budget;

		if (deadline - ops.now() < budget)
			budget = deadline - ops.now();

		let up = wait_up(iface, (budget > 0) ? budget : 1);
		let ctx = null;

		let ipm = (!up.error && t.ip_regex != null) ? rx_match(t.ip_regex, up.ip) : { hit: true };
		let dnm = (!up.error && t.dns_regex != null) ? rx_match(t.dns_regex, up.dns) : { hit: true };
		let pf = () => perf_text({ duration: ops.now() - t0, tries: 1 });

		if (up.error)
			fail_test(t, CRITICAL, sprintf('Connection to APN %s failed with message: %s', t.apn, up.error), pf());
		else if (ipm.error || dnm.error)
			fail_test(t, UNKNOWN, sprintf('ip_regex/dns_regex: %s', ipm.error ?? dnm.error), pf());
		else if (!ipm.hit)
			fail_test(t, CRITICAL, sprintf('Received wrong IP: %s', up.ip), pf());
		else if (!length(up.dns))
			fail_test(t, CRITICAL, 'Could not get DNS Servers', pf());
		else if (!dnm.hit)
			fail_test(t, CRITICAL, sprintf('Received wrong DNS Servers: %s', up.dns), pf());
		else
			ctx = { ip: up.ip, dns: up.dns, dev: up.dev, duration: ops.now() - t0,
			        bytes0: netdev_bytes(up.dev) };

		if (ctx) {
			let before = length(verdicts);

			run_checks(t, ctx, deadline);

			for (let i = before; i < length(verdicts); i++)
				if (type(verdicts[i].perfdata) == 'object')
					verdicts[i].perfdata = perf_text(verdicts[i].perfdata);
		}

		return ctx;
	};

	// the operator's record of the session that just ended, against what the
	// interface carried
	let acct_evaluate = (t, ctx, t0, deadline) => {
		let a = ctx.acct, svc = a.check.service;
		let account = plan.accounts?.[t.account];
		let iface = (ctx.bytes0 != null && a.bytes1 != null) ? a.bytes1 - ctx.bytes0 : null;
		let say = (st, msg, perf) => verdict(t.name, svc, st, sprintf('%s - %s', STATE_NAMES[st], msg), perf);

		if (account?.type != 'mccp')
			return say(UNKNOWN, sprintf('accounting of type %s is not available in this version', account?.type ?? '?'));

		if (iface == null || iface <= 0)
			return say(UNKNOWN, sprintf('no byte counters for %s', ctx.dev));

		// without the stimulus the comparison would be of a few pings, and
		// could come out "correct" for a download that never happened
		if (a.download != 0)
			return say(UNKNOWN, sprintf('the accounting download %s failed (curl %d)', a.url, a.download),
				perf_text({ bytes_interface: iface }));

		if (left(deadline) < ACCT_SETTLE_S + ACCT_API_S)
			return say(UNKNOWN, 'run budget exhausted before the session could be accounted');

		ops.sleep(ACCT_SETTLE_S * 1000);

		let url = sprintf('%s/%s/%s/status', account.base_url, t.sim_type, t.sim_id);

		// the credentials in a 0600 curl config, not in argv, where any
		// process listing would show them
		let q = (v) => replace(replace('' + (v ?? ''), /\\/g, '\\\\'), /"/g, '\\"');
		let auth = ops.secret_file(sprintf('user = "%s:%s"\n', q(account.username), q(account.password)));

		if (auth == null)
			return say(UNKNOWN, 'cannot write the credentials file for the accounting API');

		let fetch = () => ops.exec([ 'curl', '-s', '-f', '-m', '' + ACCT_API_S, '-K', auth, url ]);
		let dist = (x) => (x - t0 < 0) ? t0 - x : x - t0;
		let r, mine, failed = null;

		// the file goes whatever happens in here
		try {
			for (let i = 0; ; i++) {
				r = fetch();

				if (r?.code != 0)
					break;

				// THIS session: it must have ended after the dial (a previous
				// test's session on the same APN ended before it), carry the
				// address the interface got when the operator names one, and of
				// several candidates the one that started nearest the dial wins
				mine = null;

				for (let ses in mccp_sessions(r.out)) {
					if (ses.start == null || ses.apn != t.apn || ses.start < t0 - ACCT_SKEW_S)
						continue;
					// no end yet is a session still open (or a broken record):
					// not one to judge
					if (ses.end == null || ses.end < t0 - 60)
						continue;
					if (ses.ip != null && ctx.ip != null && ses.ip != ctx.ip)
						continue;
					if (mine == null || dist(ses.start) < dist(mine.start))
						mine = ses;
				}

				if (mine || i >= ACCT_RETRIES || left(deadline) < ACCT_RETRY_S)
					break;

				ops.sleep(ACCT_RETRY_S * 1000);
			}
		}
		catch (e) {
			failed = e;
		}

		ops.unlink(auth);

		if (failed != null)
			die(failed);

		if (r?.code != 0)
			return say(UNKNOWN, sprintf('accounting API %s did not answer (curl %d)', account.base_url, r?.code ?? -1));

		if (mine && (mine.bytes_in == null || mine.bytes_out == null || mine.bytes_total == null))
			return say(UNKNOWN, 'the operator returned a malformed session record');

		if (!mine)
			return say(CRITICAL, sprintf('no accounting record for this session (apn %s, started after %d) on %s',
				t.apn, t0 - ACCT_SKEW_S, account.base_url),
				perf_text({ bytes_interface: iface }));

		let raw = mine.bytes_in + mine.bytes_out;
		let st = acct_state(iface, raw);
		let perf = perf_text({ bytes_interface: iface, bytes_mccp: raw, bytes_mccp_billed: mine.bytes_total });

		return say(st[0], sprintf('%s. Interface: %dB, operator: %dB (billed %dB)', st[1], iface, raw, mine.bytes_total), perf);
	};

	// returns false when the interface did not come down: the sweep stops
	// then, rather than dial the next APN into a teardown in progress
	let run_test = (t, iface, network, deadline) => {
		let t0 = ops.now();
		let m = wait_ready(at_most(REG_WAIT_S, left(deadline)));

		if (!m) {
			fail_test(t, WARNING, sprintf('Networkregistration took too long (%ds max)',
				at_most(REG_WAIT_S, ops.now() - t0)));
			return true;
		}

		let ov = sim_override(network, m.iccid, m.imsi);

		if (ov) {
			fail_test(t, UNKNOWN, sprintf('wwand_sim %s overrides the connection of this card — the test APN would not be dialled', ov));
			return true;
		}

		// THE TEST APN MUST NOT OUTLIVE THE TEST. It sits in the uci delta
		// directory, where the next ordinary ifup would dial it. So: mark the
		// interface before writing (a killed run is cleaned up by the next one
		// and by the init script — apntest_cli.uc recover), and clean up after whatever
		// happened in between.
		if (!ops.mark_dirty(iface)) {
			fail_test(t, UNKNOWN, 'cannot record the pending test parameters — not dialling');
			return true;
		}

		let ctx = null;

		try {
			apply_params(iface, t);
			ctx = dial_and_check(t, iface, t0, deadline);

			// the session's last count, while it still exists
			if (ctx?.acct)
				ctx.acct.bytes1 = netdev_bytes(ctx.dev);
		}
		catch (e) {
			let before = length(filter(verdicts, (v) => v.test == t.name));

			if (!before)
				fail_test(t, UNKNOWN, sprintf('runner error: %s', e));
			else
				log('err', sprintf('%s: runner error after its verdicts: %s', t.name, e));
		}

		// each cleanup step guarded on its own: a failed down must not keep
		// the revert from running, and the marker only goes once the revert
		// did (ucode has no `finally`)
		let down = false;

		try {
			ops.ubus(netif(iface), 'down', {});
			down = wait_down(iface, DOWN_WAIT_S);
		}
		catch (e) {
			log('err', sprintf('%s: teardown failed: %s', iface, e));
		}

		try {
			ops.uci_revert('network', iface);
			ops.clear_dirty();
		}
		catch (e) {
			log('err', sprintf('%s: reverting the test parameters failed: %s — left for `wwand-apntest recover`', iface, e));
			down = false;
		}

		if (!down)
			log('err', sprintf('%s did not come down cleanly — the sweep stops here', iface));

		// low power, then online: the IMSI leaves the network between tests
		// (old imsi_detach + imsi_reattach)
		if (t.detach_after)
			ops.ubus('wwand', 'modem_reattach', { modem: g.modem });

		// once the session has ended: the operator's record of it
		if (ctx?.acct) {
			try {
				acct_evaluate(t, ctx, t0, deadline);
			}
			catch (e) {
				verdict(t.name, ctx.acct.check.service, UNKNOWN, sprintf('UNKNOWN - accounting failed: %s', e), null);
			}
		}

		return down;
	};

	let select_sim = (sim, deadline) => {
		if (sim.profile != null)
			return 'eSIM profile selection is not available in this version';

		let slots = ops.ubus('wwand', 'modem_sim_slots', { modem: g.modem });
		let active = null;

		for (let s in (slots?.slots ?? []))
			if (s.active)
				active = s.physical;

		if (active == sim.slot || (active == null && sim.slot == 1))
			return null;

		log('notice', sprintf('switching %s to SIM slot %d', g.modem, sim.slot));

		let r = ops.ubus('wwand', 'modem_sim_switch_slot', { modem: g.modem, slot: sim.slot });

		if (r == null || r.error)
			return sprintf('switching to SIM slot %d failed: %s', sim.slot, r?.error ?? 'no answer');

		let w = at_most(SLOT_WAIT_S, left(deadline));

		return wait_ready(w) ? null
			: sprintf('no registration within %d s after switching to SIM slot %d', w, sim.slot);
	};

	let self = { verdicts: verdicts };

	// run the sweep, or one test (`only`); returns the verdicts
	self.run = function(only) {
		let network = ops.uci_get_all('network');
		let ifr = resolve_interface(g, network);
		let deadline = started + (g.run_budget ?? 1800);

		if (g.modem == null || ifr.error) {
			for (let grp in plan.groups)
				for (let t in grp.tests)
					if (!only || t.name == only)
						fail_test(t, UNKNOWN, g.modem == null ? 'no modem in globals' : ifr.error);
			return verdicts;
		}

		let slots0 = ops.ubus('wwand', 'modem_sim_slots', { modem: g.modem });
		let first_slot = null;

		for (let s in (slots0?.slots ?? []))
			if (s.active)
				first_slot = s.physical;

		let switched = false;
		let stuck = null;

		// the groups in a guard of their own: an exception must not keep the
		// box on a foreign card (restore_sim below)
		try {
			for (let grp in plan.groups) {
				let tests = filter(grp.tests, (t) => !only || t.name == only);

				if (!length(tests))
					continue;

				if (stuck || ops.now() >= deadline) {
					for (let t in tests)
						fail_test(t, UNKNOWN, stuck ?? 'run budget exhausted before this test');
					continue;
				}

				// set BEFORE the switch: one that succeeds and is followed by an
				// exception must still be undone below
				if (grp.sim.slot != null && grp.sim.slot != first_slot)
					switched = true;

				let err = select_sim(grp.sim, deadline);

				if (err) {
					for (let t in tests)
						fail_test(t, UNKNOWN, err);
					continue;
				}

				for (let t in tests) {
					if (stuck || ops.now() >= deadline) {
						fail_test(t, UNKNOWN, stuck ?? 'run budget exhausted before this test');
						continue;
					}

					if (!run_test(t, ifr.name, network, deadline))
						stuck = sprintf('not run: %s did not come down after the previous test', ifr.name);
				}
			}
		}
		catch (e) {
			log('err', sprintf('sweep aborted: %s', e));
		}

		// put the box back on the card it started with. Outside the budget on
		// purpose: leaving a test box on a foreign card costs more than the
		// minutes this takes.
		if (switched && g.restore_sim && first_slot != null)
			ops.ubus('wwand', 'modem_sim_switch_slot', { modem: g.modem, slot: first_slot });

		return verdicts;
	};

	// send every verdict to the NSCA monitor; returns the number not delivered
	self.report = function() {
		if (!g.monitor)
			return 0;

		let failed = 0;

		for (let v in verdicts) {
			let t = null;

			for (let grp in plan.groups)
				for (let x in grp.tests)
					if (x.name == v.test)
						t = x;

			let argv = [ 'send_nsca', '-H', g.monitor, '-c', g.nsca_cfg ?? '/etc/send_nsca.cfg' ];

			if (t?.nsca_port != null)
				push(argv, '-p', sprintf('%d', t.nsca_port));

			let code = ops.pipe(argv, nsca_line(g.nsca_host ?? 'localhost', v.service, v.state,
				v.message, v.perfdata));

			if (code != 0) {
				failed++;
				log('err', sprintf('send_nsca for %s failed (%d)', v.service, code));
			}
		}

		return failed;
	};

	return self;
};
