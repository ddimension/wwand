// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand-apntest — the test plan. parse(raw) is pure (raw = uci get_all()
// section objects) so it stays host-testable; UCI access lives in the runner.
//
// A plan is a list of APN tests, each bound to a SIM, plus the order in which
// they will actually run. The order is not the configuration order: tests are
// GROUPED BY SIM, because getting to a SIM is the expensive part of a sweep —
// a physical slot switch ends in a modem reset and usually a USB
// re-enumeration, an eUICC profile enable in a REFRESH and re-registration.
// Grouping turns "five APNs on card A, two on card B" into two switches
// instead of seven.
//
// UNKNOWN KEYS ARE AN ERROR HERE, and that is the whole reason this file
// validates at all. The tool this replaces read `ip_regex` while its own
// shipped example wrote `ip_regext`; eleven of twelve boxes in the field
// inherited the typo, so the check "did the APN hand out an address from the
// right pool" never ran on any of them — for years, without a single symptom.
// A silently ignored option is worse than a rejected one.

'use strict';

const GLOBAL_KEYS = {
	modem: true, schedule: true, run_budget: true, restore_sim: true,
	monitor: true, nsca_cfg: true, nsca_host: true, keep_records: true,
};

const SIM_KEYS = { slot: true, profile: true, pincode: true };

// An operator's counter API is an ACCOUNT, not a provider. The field proves it:
// four endpoints in two protocols are in use, and `m-ccp-be1.ioteasyconnect.de`
// speaks the m-ccp protocol under the IEC operator's domain while
// `api.ioteasyconnect.de` speaks OAuth2 — so "which provider" answers nothing.
// The .cz instance of IEC is a third account of the second protocol.
const ACCOUNT_KEYS = {
	type: true, base_url: true,
	client_id: true, client_secret: true, username: true, password: true,
};

const ACCOUNT_TYPES = {
	// basic auth in the URL, /<sim_type>/<sim_id>/status, statusList counters
	mccp: true,
	// OAuth2 password grant, /api/v1/simcard/<sim_id>/status -> traffic_used
	iec: true,
};

const SIM_TYPES = { simcard: true, globalsim: true };

const TEST_KEYS = {
	sim: true, apn: true, auth: true, username: true, password: true,
	account: true, sim_id: true, sim_type: true,
	pdp_type: true, modes: true, mcc: true, mnc: true,
	ip_regex: true, dns_regex: true, detach_after: true,
	service: true, nsca_port: true, budget: true, check: true,
	disabled: true,
};

// uci carries these on every section; they are not options.
const META = { '.type': true, '.name': true, '.anonymous': true, '.index': true };

// Typos we have actually seen in the field, mapped to what was meant. Naming
// them turns "unknown option" into an answer instead of a puzzle — `ip_regext`
// is in the shipped example of the old package, so it is not a one-off.
const KNOWN_TYPOS = {
	ip_regext: 'ip_regex', dns_regext: 'dns_regex',
	imsi_reettach: 'detach_after', imsi_detach: 'detach_after',
	pinghost: 'check ping:<host>', pinghost2: 'check ping:<host>',
	servicename: 'service', servicename2: 'service',
	monitorhost: 'monitor (in the globals section)',
	monitorport: 'nsca_port', send_nsca_cfg: 'nsca_cfg (in the globals section)',
	hostname: 'nsca_host (in the globals section)',
	network: 'modem (in the globals section)',
};

function num_opt(value, dflt, what, errors)
{
	if (value == null || value === '')
		return dflt;

	let n = +value;

	// NaN fails every comparison, so a typo'd number slips past guards that do
	// exist and reaches a timer as a delay. Reject it here instead.
	if (n != n) {
		push(errors, sprintf('%s: %J is not a number', what, value));
		return dflt;
	}

	return n;
};

function bool_opt(value, dflt)
{
	if (value == null || value === '')
		return dflt;

	return (value == '1' || value == 'true' || value == 'yes' || value === true);
};

// Reject anything we do not know, and say what was probably meant. `errors`
// rather than `warnings`: a test whose pool check silently does not run is a
// test that reports OK for an APN nobody has verified.
function check_keys(section, allowed, where, errors)
{
	for (let k in section) {
		if (META[k] || allowed[k])
			continue;

		let hint = KNOWN_TYPOS[k];

		push(errors, hint
			? sprintf('%s: unknown option %J — did you mean %s?', where, k, hint)
			: sprintf('%s: unknown option %J', where, k));
	}
};

// One check is a string: `<plugin>` or `<plugin>:<argument>`. The argument is
// opaque here — the plugin parses it, this file only carries it.
function parse_checks(raw, where, errors)
{
	let list = [];

	for (let c in (type(raw) == 'array' ? raw : (raw != null ? [ raw ] : []))) {
		let s = trim('' + c);

		if (s == '')
			continue;

		// `plugin:argument#label`. The label names the Centreon service this
		// check reports to and defaults to the plugin name; the argument is
		// opaque here, the plugin parses it.
		let hash = index(s, '#');
		let label = (hash >= 0) ? substr(s, hash + 1) : null;
		let head = (hash >= 0) ? substr(s, 0, hash) : s;
		let colon = index(head, ':');
		let name = (colon >= 0) ? substr(head, 0, colon) : head;
		let arg = (colon >= 0) ? substr(head, colon + 1) : null;

		if (!match(name, /^[a-z][a-z0-9_]*$/)) {
			push(errors, sprintf('%s: check %J has no usable plugin name', where, s));
			continue;
		}

		push(list, { name: name, arg: arg, raw: s, label: label });
	}

	return list;
};

// The SIM a test runs on is part of its identity. The old model inherited
// whichever card the box happened to have booted with, which is fine while a
// box tests one APN on one SIM and becomes unattributable the moment it
// sweeps.
function parse_sim(name, s, errors)
{
	check_keys(s, SIM_KEYS, sprintf('sim %s', name), errors);

	let slot = num_opt(s.slot, null, sprintf('sim %s: slot', name), errors);
	let profile = (s.profile != null && s.profile !== '') ? trim('' + s.profile) : null;

	if (slot == null && profile == null)
		push(errors, sprintf('sim %s: neither slot nor profile — nothing to select', name));

	return {
		name: name,
		slot: slot,
		profile: profile,
		pincode: (s.pincode != null && s.pincode !== '') ? '' + s.pincode : null,
	};
};

function parse_account(name, s, errors)
{
	check_keys(s, ACCOUNT_KEYS, sprintf('account %s', name), errors);

	let t = (s.type != null && s.type !== '') ? trim('' + s.type) : null;

	if (t == null)
		push(errors, sprintf('account %s: no type (mccp or iec)', name));
	else if (!ACCOUNT_TYPES[t])
		push(errors, sprintf('account %s: type %J is neither mccp nor iec', name, t));

	if (s.base_url == null || s.base_url === '')
		push(errors, sprintf('account %s: no base_url', name));

	// An `iec` account without an OAuth client cannot obtain a token, and the
	// failure would only show at the first accounting run — in the middle of a
	// sweep, minutes in. Catch it while reading the plan.
	if (t == 'iec')
		for (let k in [ 'client_id', 'client_secret', 'username', 'password' ])
			if (s[k] == null || s[k] === '')
				push(errors, sprintf('account %s: type iec needs %s', name, k));

	return {
		name: name,
		type: t,
		base_url: (s.base_url != null) ? trim('' + s.base_url) : null,
		client_id: (s.client_id != null && s.client_id !== '') ? '' + s.client_id : null,
		client_secret: (s.client_secret != null && s.client_secret !== '') ? '' + s.client_secret : null,
		username: (s.username != null && s.username !== '') ? '' + s.username : null,
		password: (s.password != null && s.password !== '') ? '' + s.password : null,
	};
};

function parse_test(name, s, sims, accounts, errors)
{
	check_keys(s, TEST_KEYS, sprintf('test %s', name), errors);

	let sim = (s.sim != null && s.sim !== '') ? trim('' + s.sim) : null;

	if (sim == null)
		push(errors, sprintf('test %s: no sim', name));
	else if (!sims[sim])
		push(errors, sprintf('test %s: sim %J is not configured', name, sim));

	if (s.apn == null || s.apn === '')
		push(errors, sprintf('test %s: no apn', name));

	let checks = parse_checks(s.check, sprintf('test %s', name), errors);
	let service = (s.service != null && s.service !== '') ? '' + s.service : name;

	// THE FIRST CHECK IS THE TEST, the rest are named after themselves. That is
	// the convention the field already uses: the main ping reports as
	// `apn-vf_cda` while the extras report `apn-vf_cda_routing` and
	// `apn-vf_cda_accounting` (01-vf_routing / 99-accounting on .16). Making it
	// a rule rather than a habit means a second check can never silently
	// overwrite the first one's service.
	for (let i = 0; i < length(checks); i++)
		checks[i].service = (i == 0 && checks[i].label == null)
			? service
			: sprintf('%s_%s', service, checks[i].label ?? checks[i].name);

	if (!length(checks))
		push(errors, sprintf('test %s: no check — it would dial and conclude nothing', name));

	let account = (s.account != null && s.account !== '') ? trim('' + s.account) : null;
	let sim_id = (s.sim_id != null && s.sim_id !== '') ? trim('' + s.sim_id) : null;
	let sim_type = (s.sim_type != null && s.sim_type !== '') ? trim('' + s.sim_type) : null;

	if (account != null && !accounts[account])
		push(errors, sprintf('test %s: account %J is not configured', name, account));

	if (sim_type != null && !SIM_TYPES[sim_type])
		push(errors, sprintf('test %s: sim_type %J is neither simcard nor globalsim', name, sim_type));

	// A CHECK THAT CANNOT RUN MUST NOT LOOK LIKE ONE THAT PASSED. The tool this
	// replaces returns success when the SIM id is unset, and three field boxes
	// have it unset — so their accounting has never run and has never said so.
	// Here the plan refuses to load instead.
	if (length(filter(checks, (c) => c.name == 'accounting'))) {
		if (account == null)
			push(errors, sprintf('test %s: an accounting check needs an account', name));

		if (sim_id == null)
			push(errors, sprintf('test %s: an accounting check needs a sim_id', name));
	}

	return {
		name: name,
		sim: sim,
		apn: (s.apn != null) ? '' + s.apn : null,
		auth: (s.auth != null && s.auth !== '') ? '' + s.auth : null,
		username: (s.username != null && s.username !== '') ? '' + s.username : null,
		password: (s.password != null && s.password !== '') ? '' + s.password : null,
		pdp_type: (s.pdp_type != null && s.pdp_type !== '') ? '' + s.pdp_type : 'ipv4',
		modes: (s.modes != null && s.modes !== '') ? '' + s.modes : null,
		mcc: (s.mcc != null && s.mcc !== '') ? '' + s.mcc : null,
		mnc: (s.mnc != null && s.mnc !== '') ? '' + s.mnc : null,
		ip_regex: (s.ip_regex != null && s.ip_regex !== '') ? '' + s.ip_regex : null,
		dns_regex: (s.dns_regex != null && s.dns_regex !== '') ? '' + s.dns_regex : null,
		detach_after: bool_opt(s.detach_after, false),
		account: account,
		sim_id: sim_id,
		sim_type: sim_type ?? 'simcard',
		service: service,
		nsca_port: num_opt(s.nsca_port, null, sprintf('test %s: nsca_port', name), errors),
		budget: num_opt(s.budget, 240, sprintf('test %s: budget', name), errors),
		disabled: bool_opt(s.disabled, false),
		checks: checks,
	};
};

// Group by SIM, first-appearance order. Configuration order still decides which
// SIM comes first and how the tests inside a group are ordered — it is only the
// SIM switches that are collapsed. Deliberately stable: a sweep whose order
// changes between runs is a sweep whose timings cannot be compared.
function group_by_sim(tests, sims)
{
	let order = [], groups = {};

	for (let t in tests) {
		if (t.disabled || t.sim == null || !sims[t.sim])
			continue;

		if (!groups[t.sim]) {
			groups[t.sim] = { sim: sims[t.sim], tests: [] };
			push(order, t.sim);
		}

		push(groups[t.sim].tests, t);
	}

	return map(order, (name) => groups[name]);
};

// parse(raw): raw is the `apntest` package as uci get_all() returns it —
// { <section name>: { '.type': ..., <options> } }. Returns the plan and
// everything wrong with it; the caller decides whether to run.
export function parse(raw)
{
	let errors = [];
	let globals = {}, sims = {}, accounts = {}, tests = [];

	for (let name in (raw ?? {})) {
		let s = raw[name];
		let t = s?.['.type'];

		if (t == 'apntest_sim') {
			sims[name] = parse_sim(name, s, errors);
			continue;
		}

		if (t == 'apntest_account') {
			accounts[name] = parse_account(name, s, errors);
			continue;
		}

		if (t != 'apntest')
			continue;

		// the globals section is an `apntest` section by name, as in the tool
		// this replaces — keeping that spelling makes the migration mechanical
		if (name == 'globals') {
			check_keys(s, GLOBAL_KEYS, 'globals', errors);
			globals = {
				modem: (s.modem != null && s.modem !== '') ? '' + s.modem : null,
				schedule: (s.schedule != null && s.schedule !== '') ? '' + s.schedule : null,
				run_budget: num_opt(s.run_budget, 1800, 'globals: run_budget', errors),
				restore_sim: bool_opt(s.restore_sim, true),
				monitor: (s.monitor != null && s.monitor !== '') ? '' + s.monitor : null,
				nsca_cfg: (s.nsca_cfg != null && s.nsca_cfg !== '') ? '' + s.nsca_cfg : '/etc/send_nsca.cfg',
				nsca_host: (s.nsca_host != null && s.nsca_host !== '') ? '' + s.nsca_host : null,
				keep_records: num_opt(s.keep_records, 20, 'globals: keep_records', errors),
			};
			continue;
		}

		push(tests, parse_test(name, s, sims, accounts, errors));
	}

	// A second pass would be needed if a test named a SIM declared after it;
	// uci section order is not something a plan should depend on, so re-check
	// the bindings once every section has been seen.
	for (let t in tests)
		if (t.sim != null && !sims[t.sim] &&
		    !length(filter(errors, (e) => index(e, sprintf('test %s: sim', t.name)) == 0)))
			push(errors, sprintf('test %s: sim %J is not configured', t.name, t.sim));

	let groups = group_by_sim(tests, sims);

	if (!length(groups) && !length(errors))
		push(errors, 'plan is empty — no enabled test names a configured sim');

	return {
		globals: globals,
		sims: sims,
		accounts: accounts,
		tests: tests,
		groups: groups,
		errors: errors,
		// how many SIM selections this plan costs, which is the number worth
		// looking at when a sweep does not fit into its schedule
		switches: length(groups),
	};
};
