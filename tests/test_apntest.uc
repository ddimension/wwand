// wwand tests — apntest plan: parsing, validation and SIM grouping.
//
// The grouping is the point of the sweep: getting to a SIM costs a modem reset
// (slot) or a REFRESH and re-registration (eUICC profile), so a plan that
// visits a card twice pays twice. The validation is the point of everything
// else: the tool this replaces read `ip_regex` while its own example wrote
// `ip_regext`, and eleven of twelve field boxes inherited the typo — the pool
// check never ran on any of them, silently, for years.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as plan from 'wwand/apntest/plan.uc';

// --- a plan that is fine -----------------------------------------------------

let r = plan.parse({
	globals: { '.type': 'apntest', modem: 'wwmodem0', schedule: '*/10 * * * *',
	           monitor: 'monitor1.marcant.net', nsca_host: 'MarcanT_mccp-apn' },
	cda: { '.type': 'apntest_sim', slot: '1' },
	m2m: { '.type': 'apntest_sim', profile: '8949020000184496711' },
	iec_de: { '.type': 'apntest_account', type: 'iec',
	          base_url: 'https://api.ioteasyconnect.de', client_id: 'c',
	          client_secret: 's', username: 'u', password: 'p' },
	tcom_cda: { '.type': 'apntest', sim: 'cda', apn: 'marcant.ic.t-mobile',
	            username: 'mccp', ip_regex: '^172\\.', service: 'apn-tcom_cda',
	            nsca_port: '5668', check: [ 'ping:8.8.8.8' ] },
	tcom_internet: { '.type': 'apntest', sim: 'cda', apn: 'internet.t-mobile',
	                 check: [ 'ping:dns' ] },
	vf_m2m: { '.type': 'apntest', sim: 'm2m', apn: 'm2m.cda.vodafone.de',
	          account: 'iec_de', sim_id: '262021608171418', sim_type: 'globalsim',
	          service: 'apn-vf_m2m',
	          check: [ 'ping:172.30.0.1', 'accounting' ] },
});

eq(length(r.errors), 0, 'plan: a well-formed plan has no errors');
eq(length(r.tests), 3, 'plan: three tests parsed');
eq(r.globals.modem, 'wwmodem0', 'plan: globals carried');
eq(r.globals.run_budget, 1800, 'plan: run_budget defaults to 1800');
eq(r.globals.restore_sim, true, 'plan: the box is put back as it was by default');

// GROUPING IS THE SWEEP. Two SIMs, three tests -> two selections, not three.
eq(r.switches, 2, 'plan: one SIM selection per card, not one per test');
eq(length(r.groups), 2, 'plan: two groups');
eq(r.groups[0].sim.name, 'cda', 'plan: first group is the first SIM named');
eq(length(r.groups[0].tests), 2, 'plan: both cda tests are in one group');
eq(r.groups[0].tests[0].name, 'tcom_cda', 'plan: config order kept inside a group');
eq(r.groups[1].sim.profile, '8949020000184496711', 'plan: an eUICC group carries its profile');

// defaults worth pinning: a test that names no service is its own service, and
// pdp_type is v4 because that is what these tests dial
eq(r.tests[1].service, 'tcom_internet', 'plan: service defaults to the test name');
eq(r.tests[0].pdp_type, 'ipv4', 'plan: pdp_type defaults to ipv4');
eq(r.tests[0].checks[0].name, 'ping', 'plan: check plugin name split off');
eq(r.tests[0].checks[0].arg, '8.8.8.8', 'plan: check argument kept opaque');
eq(r.tests[2].checks[1].arg, null, 'plan: a check without an argument has none');

// --- accounts: two protocols, N endpoints ------------------------------------

// `m-ccp-be1.ioteasyconnect.de` speaks the m-ccp protocol under the IEC
// operator's domain, and there is a .cz instance of IEC with its own
// credentials — so the endpoint is data, and "which provider" answers nothing.
eq(r.accounts.iec_de.type, 'iec', 'plan: an account carries its protocol');
eq(r.accounts.iec_de.base_url, 'https://api.ioteasyconnect.de',
	'plan: and its endpoint, because there is more than one per protocol');
eq(r.tests[2].account, 'iec_de', 'plan: a test names the account it counts through');
eq(r.tests[2].sim_type, 'globalsim', 'plan: sim_type carried');
eq(r.tests[0].sim_type, 'simcard', 'plan: sim_type defaults to simcard');

// THE CHECK THAT COULD NOT RUN. The old test returns SUCCESS when the sim id is
// unset — three field boxes have it unset, so their accounting has never run
// and has never said so. Here the plan refuses instead.
let na = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0' },
	s1: { '.type': 'apntest_sim', slot: '1' },
	t: { '.type': 'apntest', sim: 's1', apn: 'a', check: [ 'accounting' ] },
});

ok(length(filter(na.errors, (e) => index(e, 'needs an account') >= 0)) == 1,
	'plan: accounting without an account is refused, not silently skipped');
ok(length(filter(na.errors, (e) => index(e, 'needs a sim_id') >= 0)) == 1,
	'plan: accounting without a sim_id likewise');

// an iec account with no OAuth client cannot get a token; say so while reading
// the plan, not minutes into a sweep
na = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0' },
	broken: { '.type': 'apntest_account', type: 'iec', base_url: 'https://x' },
});

eq(length(filter(na.errors, (e) => index(e, 'type iec needs') >= 0)), 4,
	'plan: every missing oauth credential is named');

na = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0' },
	weird: { '.type': 'apntest_account', type: 'carrier-pigeon', base_url: 'https://x' },
});

ok(length(filter(na.errors, (e) => index(e, 'neither mccp nor iec') >= 0)) == 1,
	'plan: an unknown account protocol is refused');

// --- one service per check ---------------------------------------------------

// The field convention: the main ping reports as the test's service, extras add
// a suffix (01-vf_routing -> apn-vf_cda_routing, 99-accounting -> _accounting).
let sv = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0' },
	s1: { '.type': 'apntest_sim', slot: '1' },
	acc: { '.type': 'apntest_account', type: 'mccp', base_url: 'https://api-ng.m-ccp.de' },
	vf: { '.type': 'apntest', sim: 's1', apn: 'cda.vodafone.de',
	      service: 'apn-vf_cda', account: 'acc', sim_id: '4915112345678',
	      check: [ 'ping:172.30.0.1', 'ping:192.168.192.1#routing', 'accounting' ] },
});

eq(length(sv.errors), 0, 'plan: the vodafone shape parses');
eq(sv.tests[0].checks[0].service, 'apn-vf_cda',
	'plan: the first check is the test itself');
eq(sv.tests[0].checks[1].service, 'apn-vf_cda_routing',
	'plan: a labelled check gets its own service');
eq(sv.tests[0].checks[2].service, 'apn-vf_cda_accounting',
	'plan: an unlabelled later check is named after its plugin');
eq(sv.tests[0].checks[1].arg, '192.168.192.1',
	'plan: the label does not leak into the argument');

// --- the typo that cost eleven boxes their pool check ------------------------

r = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0' },
	cda: { '.type': 'apntest_sim', slot: '1' },
	t: { '.type': 'apntest', sim: 'cda', apn: 'a', check: [ 'ping:1.1.1.1' ],
	     ip_regext: '^172\\.' },
});

ok(length(filter(r.errors, (e) => index(e, 'ip_regext') >= 0)) == 1,
	'plan: an unknown option is an error, not a shrug');
ok(length(filter(r.errors, (e) => index(e, 'did you mean ip_regex') >= 0)) == 1,
	'plan: and it names what was probably meant');

// the other field spellings get the same treatment
r = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0' },
	cda: { '.type': 'apntest_sim', slot: '1' },
	t: { '.type': 'apntest', sim: 'cda', apn: 'a', check: [ 'ping:1.1.1.1' ],
	     pinghost: '8.8.8.8', servicename: 'x', monitorport: '5668' },
});

eq(length(r.errors), 3, 'plan: every legacy key is reported, not just the first');
ok(length(filter(r.errors, (e) => index(e, 'check ping:') >= 0)) == 1,
	'plan: pinghost is pointed at the check list');

// --- things that would make a run meaningless --------------------------------

r = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0' },
	cda: { '.type': 'apntest_sim', slot: '1' },
	nocheck: { '.type': 'apntest', sim: 'cda', apn: 'a' },
});

ok(length(filter(r.errors, (e) => index(e, 'no check') >= 0)) == 1,
	'plan: a test with no check would dial and conclude nothing');

r = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0' },
	t: { '.type': 'apntest', sim: 'ghost', apn: 'a', check: [ 'ping:1.1.1.1' ] },
});

ok(length(filter(r.errors, (e) => index(e, 'is not configured') >= 0)) >= 1,
	'plan: a test naming an unknown sim is an error');

// a sim section that selects nothing selects nothing
r = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0' },
	empty: { '.type': 'apntest_sim' },
	t: { '.type': 'apntest', sim: 'empty', apn: 'a', check: [ 'ping:1.1.1.1' ] },
});

ok(length(filter(r.errors, (e) => index(e, 'neither slot nor profile') >= 0)) == 1,
	'plan: a sim with neither slot nor profile is an error');

// A NUMBER THAT IS NOT ONE must not reach a timer: NaN fails every comparison,
// so a guard like `budget <= 0` lets it through and uloop fires immediately.
r = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0', run_budget: 'soon' },
	cda: { '.type': 'apntest_sim', slot: '1' },
	t: { '.type': 'apntest', sim: 'cda', apn: 'a', check: [ 'ping:1.1.1.1' ],
	     budget: 'later' },
});

ok(length(filter(r.errors, (e) => index(e, 'is not a number') >= 0)) == 2,
	'plan: both non-numbers are reported');
eq(r.globals.run_budget, 1800, 'plan: and the default is used, never NaN');
eq(r.tests[0].budget, 240, 'plan: per-test budget falls back too');

// --- disabled tests leave the plan, and an empty plan says so ----------------

r = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0' },
	cda: { '.type': 'apntest_sim', slot: '1' },
	t: { '.type': 'apntest', sim: 'cda', apn: 'a', check: [ 'ping:1.1.1.1' ],
	     disabled: '1' },
});

eq(length(r.groups), 0, 'plan: a disabled test is not scheduled');
ok(length(filter(r.errors, (e) => index(e, 'plan is empty') >= 0)) == 1,
	'plan: a plan with nothing to run says so rather than running nothing');

// --- order is stable ---------------------------------------------------------

// The same sections in a different declaration order must produce the same
// execution order for the same SIM grouping, or two runs of one box cannot be
// compared against each other.
let a = plan.parse({
	globals: { '.type': 'apntest', modem: 'm0' },
	s1: { '.type': 'apntest_sim', slot: '1' },
	s2: { '.type': 'apntest_sim', slot: '2' },
	t1: { '.type': 'apntest', sim: 's1', apn: 'a', check: [ 'ping:1.1.1.1' ] },
	t2: { '.type': 'apntest', sim: 's2', apn: 'b', check: [ 'ping:1.1.1.1' ] },
	t3: { '.type': 'apntest', sim: 's1', apn: 'c', check: [ 'ping:1.1.1.1' ] },
});

eq(length(a.groups), 2, 'plan: interleaved sims still make two groups');
eq(a.groups[0].sim.name, 's1', 'plan: group order follows first appearance');
eq(length(a.groups[0].tests), 2, 'plan: t1 and t3 share the s1 group');
eq(a.groups[0].tests[1].apn, 'c', 'plan: t3 keeps its place behind t1');

done('test_apntest');
