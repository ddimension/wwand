// wwand tests — NCM modem + context integration against a scripted AT port.
//
// The NCM backend has no message transport: it drives the modem entirely over
// AT. So instead of the MBIM/QMI mock hub we mock the AT *tty* (like
// test_atport / test_atcmd do) with a fake transport that auto-answers scripted
// commands. We drive modem_ncm through open-AT -> identify -> SIM -> attach
// (CGDCONT/QICSGP) -> registration (CEREG) to READY, then exercise the context:
//   s1  connect (CGDCONT + QICSGP carrying user/pass -> QNETDEVCTL -> CGCONTRDP)
//       yields the neutral static settings shape (v4 + v6); down disconnects.
//   s2  empty APN -> blank CGDCONT (network default).
//   s3  zero-rx watchdog: stalled QGDCNT rx bytes -> 'zero_rx'.
//   s4  bearer loss: QNETDEVCTL? state 0 -> context down/disconnected.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as fakefx from './lib/fakefx.uc';
import * as modem_ncm from 'wwand/modem_ncm.uc';
import * as context_ncm from 'wwand/context_ncm.uc';
import * as ncm_vendors from 'wwand/ncm_vendors.uc';
import * as modem_common from 'wwand/modem_common.uc';

uloop.init();

// --- scripted AT transport ---------------------------------------------------
//
// handlers: [ { re, lines?, term? } ]  (first match wins). term defaults to
// 'OK'; replies are delivered asynchronously (uloop.timer(0)) like real serial.
function at_mock(handlers)
{
	let self = { written: [], data_cb: null, closed: false };

	self.write = (data) => {
		let cmd = trim(data);
		push(self.written, cmd);

		let h = null;

		for (let e in handlers)
			if (match(cmd, e.re)) { h = e; break; }

		let lines = h?.lines ?? [];
		let urcs = h?.urcs ?? [];
		let term = h?.term ?? 'OK';

		uloop.timer(0, () => {
			if (self.closed || !self.data_cb)
				return;

			let out = '';

			// URCs interleaved INTO the response (before the finalizer): the
			// engine folds them into the command's lines, exactly like a real
			// modem reset does during the identify chain
			for (let u in urcs)
				out += u + "\r\n";

			for (let l in lines)
				out += l + "\r\n";

			self.data_cb(out + term + "\r\n");
		});

		return length(data);
	};

	self.on_data = (cb) => { self.data_cb = cb; };
	self.drain = () => null;
	self.close = () => { self.closed = true; };
	self.saw = (re) => {
		for (let c in self.written)
			if (match(c, re))
				return c;
		return null;
	};
	// how often a command was written — distinguishes a re-run bring-up from
	// the first one (the written history survives a close/re-open)
	self.count = (re) => length(filter(self.written, (c) => match(c, re)));

	return self;
}

// base Quectel bring-up + connect script; `over` prepends scenario overrides
function script(over)
{
	return [
		...(over ?? []),
		{ re: /^AT\+CGMI$/,   lines: [ 'Quectel' ] },
		{ re: /^AT\+CGMM$/,   lines: [ 'RG650E-EU' ] },
		{ re: /^AT\+CGMR$/,   lines: [ 'RG650EM4G_01.001' ] },
		{ re: /^AT\+CGSN$/,   lines: [ '359072060000000' ] },
		{ re: /^AT\+CIMI$/,   lines: [ '262011234567890' ] },
		{ re: /^AT\+QCCID$/,  lines: [ '+QCCID: 89490200001022832490' ] },
		{ re: /^AT\+CPIN\?$/, lines: [ '+CPIN: READY' ] },
		{ re: /^AT\+CEREG\?$/, lines: [ '+CEREG: 2,1' ] },   // registered, home
		// CGCONTRDP: one IPv4 line + one IPv6 line (16 dotted bytes)
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,5,internet,10.20.30.40.255.255.255.0,10.20.30.1,8.8.8.8,8.8.4.4',
			'+CGCONTRDP: 1,5,internet,32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136,32.1.72.96.0.0.0.0.0.0.0.0.0.0.0.1,32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136',
		] },
		{ re: /^AT\+QNETDEVCTL=\?$/, lines: [] },   // supported (probe OK)
		{ re: /^AT\+QNETDEVCTL=1,/, lines: [ '+QNETDEVSTATUS: 1,1,"IPV4V6",0' ] },
		{ re: /^AT\+CSQ$/,    lines: [ '+CSQ: 20,99' ] },
		{ re: /^AT\+QENG=/,   lines: [] },   // no serving cell in the test
	];
}

// --- scenario runner ---------------------------------------------------------

let scenarios = [];
let current = 0;

function run_next()
{
	if (current >= length(scenarios)) {
		uloop.end();
		return;
	}

	let s = scenarios[current++];
	let tr = at_mock(s.script);
	let cevents = [], mevents = [];
	let ctx = null, modem = null, guard = null, finished = false;

	let finish = () => {
		if (finished)
			return;

		finished = true;
		if (guard) guard.cancel();
		modem.stop();
		uloop.timer(1, run_next);
	};

	modem = modem_ncm.create({
		id: s.name, device: '/dev/cdc-wdm0',
		config: { tty: '/dev/ttyUSB2', stats_interval: 1, zero_rx_timeout: 0, ...(s.mconfig ?? {}) },
		timing: { settle: 1, reg_timeout: 500, reg_poll: 5, backoff_min: 1, backoff_max: 5, at_drain: 1,
		          ...(s.mtiming ?? {}) },
		datapath: s.datapath,
		// inject the scripted tty; a re-opened tty is not closed (a scenario
		// that restarts the modem re-opens the same mock and keeps its history)
		at: { open_transport: () => { tr.closed = false; return tr; } },
		deps: {
			log: () => null,
			on_event: (m, event, data) => {
				push(mevents, { event: event, data: data });

				if (event == 'registered' && !ctx && !s.run_at_start) {
					ctx = context_ncm.create({
						name: 'wan', modem: m, config: s.cconfig,
						timing: s.ctx_timing,
						deps: {
							log: () => null,
							on_event: (c, ev, d) => push(cevents, { event: ev, data: d }),
						},
					});

					s.run({ ctx: ctx, modem: m, tr: tr,
					        cevents: cevents, mevents: mevents, finish: finish });
				}
			},
		},
	});

	guard = uloop.timer(3000, () => { ok(false, s.name + ': timed out'); finish(); });
	modem.start();

	// a scenario that never reaches 'registered' on its own (the slot switch
	// stops the modem before the SIM step) drives itself from start()
	if (s.run_at_start)
		s.run({ ctx: null, modem: modem, tr: tr,
		        cevents: cevents, mevents: mevents, finish: finish });
}

// poll `cond` until it holds, then run `then` (bounded — the scenario guard
// timer reports a real hang; the assertions after `then` report the failure)
let wait_for;
wait_for = (cond, then, n) => {
	if (cond() || (n ?? 0) > 400)
		return then();

	uloop.timer(5, () => wait_for(cond, then, (n ?? 0) + 1));
};

function last_event(arr, name)
{
	let r = null;
	for (let e in arr)
		if (e.event == name) r = e;
	return r;
}

function any_event(arr, name)
{
	for (let e in arr)
		if (e.event == name) return true;
	return false;
}

// --- s_c5greg: an unsupported AT+C5GREG? is asked once, then dropped ---------
//
// The 5GS registration probe sits between CEREG and the legacy CREG fallback.
// A modem without 5G refuses it for good (MeiG SLM770A, LTE Cat4: bare ERROR),
// but the registration poll repeats every couple of seconds for as long as the
// modem is searching — so an unlatched probe costs a round-trip and a warning
// line per poll, precisely while the log is worth reading. Ask once.
//
// The CEREG handler object is kept mutable so the scenario can let the modem
// register at the end (first match wins; the mock reads .lines per write).
let c5_cereg = { re: /^AT\+CEREG\?$/, lines: [ '+CEREG: 2,0' ] };

push(scenarios, {
	name: 's_c5greg_latch',
	script: script([
		c5_cereg,
		{ re: /^AT\+C5GREG\?$/, term: 'ERROR', lines: [] },
		{ re: /^AT\+CREG\?$/, lines: [ '+CREG: 2,0' ] },
	]),
	cconfig: { apn: 'internet' },
	run_at_start: true,
	run: (env) => {
		// wait on the LAST command of the poll chain, not the first: CREG is
		// sent after CEREG, so waiting for four CEREGs can observe only three
		// CREGs and the assertion below races the fourth
		wait_for(() => env.tr.count(/^AT\+CREG\?$/) >= 4, () => {
			eq(env.tr.count(/^AT\+C5GREG\?$/), 1,
				'c5greg: the refused probe is sent exactly once, not once per poll');
			ok(env.tr.count(/^AT\+CREG\?$/) >= 4,
				'c5greg: the CREG fallback still runs on every poll');

			// the latch must not cost registration: let CEREG succeed
			c5_cereg.lines = [ '+CEREG: 2,1' ];

			wait_for(() => any_event(env.mevents, 'registered'), () => {
				ok(any_event(env.mevents, 'registered'),
					'c5greg: registration still completes with the probe latched off');
				eq(env.tr.count(/^AT\+C5GREG\?$/), 1,
					'c5greg: still not re-probed after registering');
				env.finish();
			});
		});
	},
});

// --- s1: lifecycle + settings shape + auth reaches QICSGP -------------------

push(scenarios, {
	name: 's1_flow',
	script: script(),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6', auth: 'chap',
	           username: 'joe', password: 'secret', mux_id: 0 },
	run: (env) => {
		let m = env.modem;

		ok(true, 'modem reached READY (openAT->identify->sim->attach->register)');
		eq(m.info.model, 'RG650E-EU', 'model from CGMM');
		eq(m.info.imei, '359072060000000', 'imei from CGSN');
		eq(m.info.imsi, '262011234567890', 'imsi from CIMI');
		eq(m.info.iccid, '89490200001022832490', 'iccid from QCCID');
		eq(m.dial.name, 'qnetdevctl', 'dial resolves to QNETDEVCTL when probe answers OK');
		ok(m.dial.connect(1) == 'AT+QNETDEVCTL=1,1,1', 'quectel QNETDEVCTL dial selected');

		env.ctx.up((err, settings) => {
			eq(err, null, 'context up succeeds');
			eq(env.ctx.state, 'CONNECTED', 'context CONNECTED');

			// neutral settings shape (static, from CGCONTRDP)
			eq(settings?.ipv4?.addr, '10.20.30.40', 'ipv4 addr from CGCONTRDP');
			eq(settings?.ipv4?.prefix, 32, 'ipv4 forced /32 p2p');
			eq(settings?.ipv4?.gateway, '10.20.30.1', 'ipv4 gateway from CGCONTRDP');
			eq(settings?.ipv4?.dns, [ '8.8.8.8', '8.8.4.4' ], 'ipv4 dns from CGCONTRDP');
			eq(settings?.ipv6?.addr, '2001:4860:4860:0:0:0:0:8888', 'ipv6 addr decoded from 16 dotted bytes');
			ok(settings?.ipv6?.gateway == '2001:4860:0:0:0:0:0:1', 'ipv6 gateway decoded');

			// auth username/password MUST reach the QICSGP profile command
			// (the connect-time one for this context, apn 'internet')
			let q = env.tr.saw(/^AT\+QICSGP=1,3,"internet",/);
			ok(q != null, 'QICSGP issued for the context');
			ok(q && index(q, '"joe"') >= 0 && index(q, '"secret"') >= 0, 'QICSGP carries username + password');
			ok(q && match(q, /,2$/), 'QICSGP auth = CHAP (2)');

			// the vendor dial bound the netdev
			ok(env.tr.saw(/^AT\+QNETDEVCTL=1,1,1$/) != null, 'QNETDEVCTL connect issued');

			// down disconnects the netdev
			env.ctx.down(() => {
				eq(env.ctx.state, 'IDLE', 'context down -> IDLE');
				ok(env.tr.saw(/^AT\+QNETDEVCTL=0,1,0$/) != null, 'QNETDEVCTL disconnect issued');
				ok(last_event(env.cevents, 'down') != null, 'context emitted down');
				env.finish();
			});
		});
	},
});

// --- s2: empty APN -> blank CGDCONT (network default) -----------------------

push(scenarios, {
	name: 's2_empty_apn',
	script: script(),
	cconfig: { apn: null, pdp_type: 'ipv4v6', mux_id: 0 },
	run: (env) => {
		env.ctx.up((err) => {
			eq(err, null, 'empty-apn context up succeeds');
			ok(env.tr.saw(/^AT\+CGDCONT=1,"IPV4V6",""$/) != null,
				'blank APN -> AT+CGDCONT=1,"IPV4V6","" (network default)');
			env.finish();
		});
	},
});

// --- s3: zero-rx watchdog ---------------------------------------------------

push(scenarios, {
	name: 's3_zero_rx',
	// constant rx bytes -> a stall the watchdog must catch
	script: script([ { re: /^AT\+QGDCNT\?$/, lines: [ '+QGDCNT: 500,1000' ] } ]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4', mux_id: 0 },
	ctx_timing: { stats_interval: 5, zero_rx_ms: 8 },
	run: (env) => {
		env.ctx.up((err) => {
			eq(err, null, 'zero-rx: context connected');

			uloop.timer(80, () => {
				ok(any_event(env.cevents, 'zero_rx'), 'stalled rx bytes -> zero_rx tripped');
				env.finish();
			});
		});
	},
});

// --- s4: bearer loss via QNETDEVCTL? state 0 --------------------------------

push(scenarios, {
	name: 's4_bearer_loss',
	script: script([
		{ re: /^AT\+QNETDEVCTL\?$/, lines: [ '+QNETDEVCTL: 1,1,1,0' ] },   // state 0 = unbound
		{ re: /^AT\+QGDCNT\?$/, lines: [ '+QGDCNT: 500,1000' ] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4', mux_id: 0 },
	ctx_timing: { stats_interval: 5, zero_rx_ms: 0 },
	run: (env) => {
		env.ctx.up((err) => {
			eq(err, null, 'bearer-loss: context connected');

			uloop.timer(40, () => {
				eq(env.ctx.state, 'IDLE', 'QNETDEVCTL? state 0 -> context IDLE');
				let d = last_event(env.cevents, 'down');
				ok(d && d.data?.reason == 'disconnected', 'context emitted down/disconnected');
				env.finish();
			});
		});
	},
});

// --- s5: MeiG modem (ASR platform: ECMDUP dial + AUTHDATA auth) -------------

// MeiG bring-up/connect script: shared identify/SIM/register/CGCONTRDP but a
// MeiG CGMI and the MeiG-specific dial/auth/status/stats commands.
function meig_script()
{
	return [
		{ re: /^AT\+CGMI$/,   lines: [ 'MEIGSMART' ] },
		{ re: /^AT\+CGMM$/,   lines: [ 'SLM770A' ] },
		{ re: /^AT\+CGMR$/,   lines: [ 'SLM770A_V1.0' ] },
		{ re: /^AT\+CGSN$/,   lines: [ '860000000000001' ] },
		{ re: /^AT\+CIMI$/,   lines: [ '262011234567890' ] },
		{ re: /^AT\+QCCID$/,  lines: [], term: 'ERROR' },   // not a Quectel command
		{ re: /^AT\+CPIN\?$/, lines: [ '+CPIN: READY' ] },
		{ re: /^AT\+CEREG\?$/, lines: [ '+CEREG: 2,1' ] },
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,5,internet,100.64.0.5.255.255.255.252,100.64.0.6,1.1.1.1,1.0.0.1',
		] },
		{ re: /^AT\+ECMDUP=1,1,[0-2]$/, lines: [ '^DCONN: 1,1,"IPV4"' ] },
		{ re: /^AT\+ECMDUP=1,0$/, lines: [ '^DEND: 1,0,"IPV4"' ] },
		{ re: /^AT\+ECMDUP\?$/, lines: [ '+ECMDUP: 1,1,"IPV4",0,"IPV6"' ] },
		{ re: /^AT\^DSFLOWQRY$/, lines: [ '^DSFLOWQRY: 100,0,0,592,645c,3c0f' ] },
		{ re: /^AT\^AUTHDATA=/, lines: [] },
		{ re: /^AT\+CSQ$/,    lines: [ '+CSQ: 18,99' ] },
		{ re: /^AT\+QENG=/,   lines: [], term: 'ERROR' },
	];
}

push(scenarios, {
	name: 's5_meig',
	script: meig_script(),
	cconfig: { apn: 'internet', pdp_type: 'ipv4', auth: 'chap',
	           username: 'joe', password: 'secret', mux_id: 0 },
	run: (env) => {
		let m = env.modem;

		eq(m.info.model, 'SLM770A', 'meig model from CGMM');
		ok(m.dial.connect(1) == 'AT+ECMDUP=1,1,2', 'meig ECMDUP dial selected from CGMI (default ipv4v6)');

		// the service/RAT indications reach the live modem object and are
		// remembered, so a modem that looks registered but carries nothing is
		// distinguishable from a healthy one
		m.at_on_urc('^SRVST: 1', 'at');
		eq(m.service_state, 1, 'urc: ^SRVST restricted service recorded on the modem');
		m.at_on_urc('^SRVST: 2', 'at');
		eq(m.service_state, 2, 'urc: ^SRVST effective service recorded');

		m.at_on_urc('^MODE: 9,71', 'at');
		eq(m.rat_mode, 71, 'urc: ^MODE RAT recorded (71 = FDD LTE)');

		// a repeat of the SAME value must not re-trigger anything (the modem
		// mirrors its URCs onto both AT ports, so every event arrives twice)
		let before_meng = env.tr.count(/^AT\+MENG=/);
		m.at_on_urc('^MODE: 9,71', 'at2');
		eq(env.tr.count(/^AT\+MENG=/), before_meng,
			'urc: the mirrored duplicate of a ^MODE does not refresh telemetry again');
		ok(m.dial.connect(1, { pdp_type: 'ipv4' }) == 'AT+ECMDUP=1,1,0', 'ECMDUP carries pdp_type (ipv4)');

		env.ctx.up((err, settings) => {
			eq(err, null, 'meig context up succeeds');
			eq(env.ctx.state, 'CONNECTED', 'meig context CONNECTED');
			eq(settings?.ipv4?.addr, '100.64.0.5', 'meig ipv4 addr from CGCONTRDP');
			eq(settings?.ipv4?.gateway, '100.64.0.6', 'meig ipv4 gateway from CGCONTRDP');

			// auth reaches AT^AUTHDATA (order: cid,auth,PLMN,password,username)
			let a = env.tr.saw(/^AT\^AUTHDATA=1,/);
			ok(a != null, 'AUTHDATA issued');
			ok(a && index(a, 'secret') >= 0 && index(a, 'joe') >= 0, 'AUTHDATA carries password + username');
			ok(a && match(a, /^AT\^AUTHDATA=1,2,/), 'AUTHDATA auth = CHAP (2)');

			ok(env.tr.saw(/^AT\+ECMDUP=1,1,0$/) != null, 'ECMDUP connect issued with pdp_type ipv4');

			env.ctx.down(() => {
				ok(env.tr.saw(/^AT\+ECMDUP=1,0$/) != null, 'ECMDUP disconnect issued');
				env.finish();
			});
		});
	},
});

// --- vendor service / RAT indications (^SRVST, ^MODE) -----------------------
//
// Values from the SLM770A manual (8.13 table 145, 8.7 table 133). ^SRVST: 1
// "restricted service" is the vendor's own word for the state that shows up as
// registration <stat> 11 — both appeared in the same second on every
// registration cycle observed on a Cudy LT300 (2026-08-23), which is what
// settled the reading of that stat.
let meig_v = ncm_vendors.vendor_for('MEIG INCORPORATED', 'SLM770A-R');

eq(meig_v.service_urc('^SRVST: 2')?.service, 2, 'service_urc: ^SRVST effective service');
eq(meig_v.service_urc('^SRVST: 1')?.kind, 'service', 'service_urc: ^SRVST classified as a service change');
eq(meig_v.service_urc('^SRVST: 0')?.service, 0, 'service_urc: ^SRVST no service');
// the firmware emits an undocumented 3 in passing — it must parse, not throw
eq(meig_v.service_urc('^SRVST: 3')?.service, 3, 'service_urc: an undocumented ^SRVST value still parses');

eq(meig_v.service_urc('^MODE: 9,71')?.kind, 'mode', 'service_urc: ^MODE classified as a RAT change');
eq(meig_v.service_urc('^MODE: 9,71')?.sys_mode, 9, 'service_urc: ^MODE sys_mode 9 = LTE');
eq(meig_v.service_urc('^MODE: 9,71')?.cell_service, 71, 'service_urc: ^MODE cell_service 71 = FDD LTE');
eq(meig_v.service_urc('^MODE: 0,0')?.cell_service, 0, 'service_urc: ^MODE 0,0 = no service');

// must not swallow anything else — ^DCONN/^DEND belong to session_urc, and the
// registration codes are the poll's business
eq(meig_v.service_urc('^DCONN: 1,1,"IPV4"'), null, 'service_urc: leaves the bearer URCs alone');
eq(meig_v.service_urc('+CEREG: 5,"88ce"'), null, 'service_urc: leaves registration URCs alone');
eq(meig_v.service_urc('^CELLLOCK: 1'), null, 'service_urc: leaves the cell-lock read-back alone');

// the two parsers stay disjoint in the other direction too
eq(meig_v.session_urc('^SRVST: 2'), null, 'session_urc: ignores a service change');

// the push (one field) and the answer to AT^SRVST? (<enable>,<status>) share a
// name. The URC parser must not read that answer's ENABLE flag as the state,
// and the query parser must take the SECOND field.
eq(meig_v.service_urc('^SRVST: 1,2'), null,
	'service_urc: the two-field query answer is not mistaken for a push');
eq(meig_v.parse_service([ '^SRVST: 1,2' ]), 2,
	'parse_service: reads <service_status>, not the <enable> flag');
eq(meig_v.parse_service([ '^SRVST: 1,0' ]), 0, 'parse_service: no service');
eq(meig_v.parse_service([ 'OK' ]), null, 'parse_service: no answer line -> null');
eq(meig_v.service_query, 'AT^SRVST?', 'service_query: the documented read command');

// --- the registered operator -------------------------------------------------
//
// The QMI backend gets this from the serving-system indication; on the AT path
// nobody asked, so every NCM modem showed an empty operator — and LuCI's status
// page, which reads reg.plmn, rendered a dash. ^EONS answers instantly with the
// names; AT+COPS? also works but takes over 8 s on this firmware and carries no
// name at all, which is why the vendor command is tried first.
eq(meig_v.operator_query, 'AT^EONS=1', 'operator_query: the vendor command, not COPS');

let op = meig_v.parse_operator([ '^EONS: 1,26202,"Vodafone.de","Vodafone",0,"DATA ONLY"' ]);
eq(op?.mcc, 262, 'parse_operator: mcc split off the PLMN id');
eq(op?.mnc, 2, 'parse_operator: 5-digit id -> 2-digit mnc');
eq(op?.description, 'Vodafone.de', 'parse_operator: the long name');

// 6-digit ids carry a 3-digit MNC — the split is positional, there is no
// separator, so the length IS the information
let op6 = meig_v.parse_operator([ '^EONS: 1,310260,"T-Mobile","TMO"' ]);
eq(op6?.mcc, 310, 'parse_operator: 6-digit id -> mcc 310');
eq(op6?.mnc, 260, 'parse_operator: 6-digit id -> 3-digit mnc');

// an empty long name falls back to the short one rather than reporting ''
eq(meig_v.parse_operator([ '^EONS: 1,26202,"","Vodafone"' ])?.description, 'Vodafone',
	'parse_operator: empty long name falls back to the short name');

eq(meig_v.parse_operator([ 'OK' ]), null, 'parse_operator: no answer line -> null');

// --- s5d/s5e: the modem's own bearer notification (^DEND / ^DCONN) ----------
//
// Field-seen on a Cudy LT300 (2026-08-23): ^DEND at 21:05:54, ^DCONN at
// 21:05:59 — the SLM770A dropped and re-established the session by itself in
// five seconds. So ^DEND must NOT tear the context down on its own; it arms a
// verification that only acts if a real status probe agrees, and a ^DCONN
// arriving first cancels it. Without any of this the drop is invisible until
// the next stats tick (up to 60 s).

// the status handler is kept MUTABLE so a scenario can flip the bearer from
// up to down mid-run: handing it back "down" from the start would let the
// ordinary liveness poll tear the context down before the URC is ever tested
function meig_session_script(status_handler)
{
	let s = meig_script();

	unshift(s, status_handler);

	return s;
}

let s5d_status = { re: /^AT\+ECMDUP\?$/, lines: [ '+ECMDUP: 1,1,"IPV4",0,"IPV6"' ] };
let s5e_status = { re: /^AT\+ECMDUP\?$/, lines: [ '+ECMDUP: 1,1,"IPV4",0,"IPV6"' ] };

// s5d: ^DEND followed by ^DCONN — the session heals, nothing happens
push(scenarios, {
	name: 's5d_meig_dend_then_dconn',
	script: meig_session_script(s5d_status),
	ctx_timing: { stats_interval: 5000, zero_rx_ms: 0, session_confirm_ms: 30 },
	cconfig: { apn: 'internet', pdp_type: 'ipv4' },
	run: (env) => {
		env.ctx.up((err) => {
			eq(err, null, 'dend/dconn: context up');

			env.ctx.modem_event('session_urc', { cid: 1, up: false });
			env.ctx.modem_event('session_urc', { cid: 1, up: true });

			// well past session_confirm_ms
			uloop.timer(80, () => {
				eq(env.ctx.state, 'CONNECTED',
					'dend/dconn: a ^DCONN before the grace period expires keeps the session');
				env.finish();
			});
		});
	},
});

// s5e: ^DEND alone, and the status probe confirms the bearer is gone
push(scenarios, {
	name: 's5e_meig_dend_confirmed',
	script: meig_session_script(s5e_status),
	ctx_timing: { stats_interval: 5000, zero_rx_ms: 0, session_confirm_ms: 30 },
	cconfig: { apn: 'internet', pdp_type: 'ipv4' },
	run: (env) => {
		env.ctx.up((err) => {
			eq(err, null, 'dend: context up');

			// a foreign cid must be ignored outright
			env.ctx.modem_event('session_urc', { cid: 7, up: false });

			uloop.timer(80, () => {
				eq(env.ctx.state, 'CONNECTED',
					'dend: a ^DEND for another cid is not ours to act on');

				// now the bearer really is gone, and OUR cid is announced
				s5e_status.lines = [ '+ECMDUP: 1,0,"IPV4",0,"IPV6"' ];
				env.ctx.modem_event('session_urc', { cid: 1, up: false });

				uloop.timer(80, () => {
					ok(env.ctx.state != 'CONNECTED',
						'dend: verified by the status probe, the context goes down');
					ok(any_event(env.cevents, 'down'),
						'dend: the drop is reported to the daemon');
					env.finish();
				});
			});
		});
	},
});

// s5f: ^DEND verified by an EMPTY status answer. Field-seen 2026-08-23 when the
// network dropped the modem: AT+ECMDUP? came back with no rows at all, because
// "no contexts" is exactly how the MeiG answers once the bearer is gone. An
// "=== 0" test did nothing and the drop went unnoticed for 53 s.
let s5f_status = { re: /^AT\+ECMDUP\?$/, lines: [ '+ECMDUP: 1,1,"IPV4",0,"IPV6"' ] };

push(scenarios, {
	name: 's5f_meig_dend_empty_status',
	script: meig_session_script(s5f_status),
	ctx_timing: { stats_interval: 5000, zero_rx_ms: 0, session_confirm_ms: 30 },
	cconfig: { apn: 'internet', pdp_type: 'ipv4' },
	run: (env) => {
		env.ctx.up((err) => {
			eq(err, null, 'dend-empty: context up');

			// the bearer is gone: the modem now lists no context at all
			s5f_status.lines = [];
			env.ctx.modem_event('session_urc', { cid: 1, up: false });

			uloop.timer(80, () => {
				ok(env.ctx.state != 'CONNECTED',
					'dend-empty: an empty context list confirms the drop too');
				env.finish();
			});
		});
	},
});

// --- s5c: a vendor byte-counter command the firmware refuses ----------------
//
// HW-found on the Cudy LT300 / SLM770A-R: AT^DSFLOWQRY answers +CME ERROR on
// every stats tick, forever. The poll already fell back to the netdev counter,
// but it re-sent the doomed command (and logged a warning) once per interval
// for the life of the connection. Retire it — but only after a RUN of
// refusals, because a CME error can also be a passing condition, unlike the
// bare ERROR that retires the C5GREG probe on the first try.

function meig_nostats_script()
{
	let s = meig_script();

	// first match wins, so prepend the refusal over the working handler
	unshift(s, { re: /^AT\^DSFLOWQRY$/, term: '+CME ERROR: 100', lines: [] });

	return s;
}

push(scenarios, {
	name: 's5c_meig_stats_refused',
	script: meig_nostats_script(),
	ctx_timing: { stats_interval: 5, zero_rx_ms: 0 },
	cconfig: { apn: 'internet', pdp_type: 'ipv4' },
	run: (env) => {
		env.ctx.up((err) => {
			eq(err, null, 'stats-refused: context still comes up');

			// let the stats poll run well past the give-up threshold
			wait_for(() => env.tr.count(/^AT\^DSFLOWQRY$/) >= 3, () => {
				// a few more intervals must add nothing
				uloop.timer(60, () => {
					eq(env.tr.count(/^AT\^DSFLOWQRY$/), 3,
						'stats-refused: asked exactly 3 times, then retired');
					eq(env.ctx.state, 'CONNECTED',
						'stats-refused: the context stays up on the netdev counter');
					env.finish();
				});
			});
		});
	},
});

// --- s5b: MeiG auto-dialed bearer — ECMDUP connect rejected while up, the
//          status probe sees the live session and the context adopts it
//          (HW-found on SLM770A-R: the modem auto-dials after attach and
//          answers a second ECMDUP with bare ERROR) ------------------------

function meig_adopt_script()
{
	let s = meig_script();

	for (let e in s) {
		if (match('AT+ECMDUP=1,1,0', e.re)) {
			e.lines = [];
			e.term = 'ERROR';
		}
	}

	return s;
}

push(scenarios, {
	name: 's5b_meig_adopt',
	script: meig_adopt_script(),
	cconfig: { apn: 'internet', pdp_type: 'ipv4', auth: 'none', mux_id: 0 },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 'meig adopt: context up succeeds despite ECMDUP ERROR');
			eq(env.ctx.state, 'CONNECTED', 'meig adopt: context CONNECTED');
			eq(settings?.ipv4?.addr, '100.64.0.5', 'meig adopt: ipv4 addr from CGCONTRDP');
			ok(env.tr.saw(/^AT\+ECMDUP\?$/) != null, 'meig adopt: dial status probed after ERROR');
			env.finish();
		});
	},
});

// --- ensure_serial_bind: runtime usb-serial new_id registration -------------
// (MeiG SLM770A ECM 2dee:4d58 — the kernel option driver only knows the RNDIS
// PID, so wwand registers the ECM id itself before AT port discovery)

function bind_fx(over)
{
	return fakefx.create({
		files: {
			'/sys/class/net/usb0/device/../idVendor': '2dee\n',
			'/sys/class/net/usb0/device/../idProduct': '4d58\n',
			...(over?.files ?? {}),
		},
		present: { '/sys/bus/usb-serial/drivers/option1/new_id': true, ...(over?.present ?? {}) },
		globs: over?.globs ?? {},
	});
}

let bfx = bind_fx();
ok(modem_ncm.ensure_serial_bind(bfx, 'usb0') === true, 'new_id: known ECM pid is registered');
ok(bfx.actions[0] == 'write /sys/bus/usb-serial/drivers/option1/new_id 2dee 4d58',
	'new_id: correct vid/pid written to the option driver');

// ttys already bound -> no write
let bfx2 = bind_fx({ globs: { '/sys/class/net/usb0/device/../*/tty*':
	[ '/sys/class/net/usb0/device/../1-1:1.4/ttyUSB2' ] } });
ok(modem_ncm.ensure_serial_bind(bfx2, 'usb0') === false, 'new_id: skipped when ttys exist');
eq(length(bfx2.actions), 0, 'new_id: no write when ttys exist');

// unknown pid -> no write
let bfx3 = bind_fx({ files: { '/sys/class/net/usb0/device/../idProduct': '4d57\n' } });
ok(modem_ncm.ensure_serial_bind(bfx3, 'usb0') === false, 'new_id: unknown pid untouched');

// option module not loaded -> no write, caller retries via hotplug
let bfx4 = bind_fx({ present: { '/sys/bus/usb-serial/drivers/option1/new_id': false } });
ok(modem_ncm.ensure_serial_bind(bfx4, 'usb0') === false, 'new_id: driver absent -> no-op');

// --- s6: RG650E-EU HW reality — QNETDEVCTL unsupported -> CGACT dial + the
//         real dual-stack CGCONTRDP line -----------------------------------

push(scenarios, {
	name: 's6_rg650e_cgact',
	script: [
		{ re: /^AT\+CGMI$/,   lines: [ 'Quectel' ] },
		{ re: /^AT\+CGMM$/,   lines: [ 'RG650E-EU' ] },
		{ re: /^AT\+CGMR$/,   lines: [ 'RG650EM4G_01.001' ] },
		{ re: /^AT\+CGSN$/,   lines: [ '359072060000000' ] },
		{ re: /^AT\+CIMI$/,   lines: [ '262021234567890' ] },
		{ re: /^AT\+QCCID$/,  lines: [ '+QCCID: 89490200001022832490' ] },
		{ re: /^AT\+CPIN\?$/, lines: [ '+CPIN: READY' ] },
		{ re: /^AT\+CEREG\?$/, lines: [ '+CEREG: 2,1' ] },
		{ re: /^AT\+QNETDEVCTL=\?$/, lines: [], term: 'ERROR' },   // HW: unsupported
		// the RG650E dual-stack line shape (mixed comma/space, mixed widths; values anonymized)
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,5,"internet","192.0.2.229","32.1.13.184.0.0.0.0.0.0.0.0.0.0.0.1", "254.128.0.0.0.0.0.0.0.0.0.0.0.0.0.1","192.0.2.53" "32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136","192.0.2.54" "32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.68"',
		] },
		{ re: /^AT\+CGACT=1,/, lines: [] },
		{ re: /^AT\+CGACT=0,/, lines: [] },
		{ re: /^AT\+CGACT\?$/, lines: [ '+CGACT: 1,1' ] },
		{ re: /^AT\+CSQ$/,    lines: [ '+CSQ: 20,99' ] },
		{ re: /^AT\+QENG=/,   lines: [] },
	],
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6', mux_id: 0 },
	run: (env) => {
		let m = env.modem;

		eq(m.dial.name, 'cgact', 'RG650E: QNETDEVCTL probe ERROR -> CGACT dial resolved');

		env.ctx.up((err, settings) => {
			eq(err, null, 'RG650E context up succeeds via CGACT');
			ok(env.tr.saw(/^AT\+CGACT=1,1$/) != null, 'CGACT connect issued');

			// dual-stack decode from the RG650E CGCONTRDP line
			eq(settings?.ipv4?.addr, '192.0.2.229', 'RG650E ipv4 addr (bare 4-octet local)');
			eq(settings?.ipv4?.prefix, 32, 'RG650E ipv4 forced /32');
			eq(settings?.ipv4?.dns, [ '192.0.2.53', '192.0.2.54' ], 'RG650E both v4 DNS');
			eq(settings?.ipv6?.addr, '2001:db8:0:0:0:0:0:1', 'RG650E ipv6 addr (16-octet field)');
			eq(settings?.ipv6?.dns, [ '2001:4860:4860:0:0:0:0:8888', '2001:4860:4860:0:0:0:0:8844' ], 'RG650E both v6 DNS');

			env.ctx.down(() => {
				ok(env.tr.saw(/^AT\+CGACT=0,1$/) != null, 'CGACT disconnect issued');
				env.finish();
			});
		});
	},
});

// --- s7: Quectel telemetry -> QMI self.cells / self.signal / reg_detail ------
//
// Drives the vendor telemetry block (QENG servingcell+neighbourcell, per-antenna
// QRSRP/QRSRQ/QSINR, QCAINFO, CEER, QNWLOCK) and asserts it decodes into the same
// shapes the QMI backend produces, so the LuCI status page renders identically.

push(scenarios, {
	name: 's7_quectel_telemetry',
	script: script([
		{ re: /^AT\+QENG="servingcell"$/, lines: [
			'+QENG: "servingcell","CONNECT"',
			'+QENG: "LTE","FDD",262,01,1C36403,246,1300,3,5,5,BFF,-93,-11,-61,21,15,100,-',
			'+QENG: "NR5G-NSA",262,01,242,-102,19,-11,431070,1,3,0',
		] },
		{ re: /^AT\+QENG="neighbourcell"$/, lines: [
			'+QENG: "neighbourcell intra","LTE",1300,155,-13,-99,-70,8,-4,7,0,0,0',
			'+QENG: "neighbourcell inter","LTE",100,88,-15,-105,-75,4,-8,5,0,0',
		] },
		{ re: /^AT\+QRSRP\?$/, lines: [ '+QRSRP: -95,-98,-140,-140,LTE' ] },
		{ re: /^AT\+QRSRQ\?$/, lines: [ '+QRSRQ: -11,-12,-20,-20,LTE' ] },
		{ re: /^AT\+QSINR\?$/, lines: [ '+QSINR: 21,19,0,0,LTE' ] },
		{ re: /^AT\+QCAINFO$/, lines: [
			'+QCAINFO: "PCC",1300,100,"LTE BAND 3",1,246',
			'+QCAINFO: "SCC",1450,75,"LTE BAND 7",2,300',
		] },
		{ re: /^AT\+CEER$/, lines: [ '+CEER: EMM cause 33, requested service option not subscribed' ] },
		{ re: /^AT\+QNWLOCK="common\/4g"$/, lines: [ '+QNWLOCK: "common/4g",1,1300,246' ] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6', mux_id: 0 },
	run: (env) => {
		let m = env.modem;

		// wait for the first slow telemetry tick (interval=stats_interval=1s) to
		// populate signal + cells + reg_detail, then assert the QMI shapes
		uloop.timer(1500, () => {
			// per-antenna QRSRP/QRSRQ/QSINR merged into self.signal.lte (best branch;
			// snr in 0.1 dB), NR5G filled from the serving cell
			eq(m.signal?.lte?.rsrp, -95, 'signal.lte.rsrp = best QRSRP branch');
			eq(m.signal?.lte?.rsrq, -11, 'signal.lte.rsrq = best QRSRQ branch');
			eq(m.signal?.lte?.snr, 210, 'signal.lte.snr = best QSINR ×10 (0.1 dB)');
			eq(m.signal?.nr5g?.rsrp, -102, 'signal.nr5g.rsrp from QENG serving NR line');

			// self.cells.lte_intra: serving identifiers + serving-as-cell + neighbour
			let li = m.cells?.lte_intra;
			eq(li?.serving_cell_id, 246, 'lte_intra.serving_cell_id = serving PCI');
			eq(li?.earfcn, 1300, 'lte_intra.earfcn');
			eq(li?.tac, 3071, 'lte_intra.tac (hex BFF decoded)');
			eq(li?.global_cell_id, 29582339, 'lte_intra.global_cell_id (hex cid decoded)');
			eq(li?.plmn, '262/01', 'lte_intra.plmn = mcc/mnc');
			eq(length(li?.cells), 2, 'lte_intra.cells = serving + 1 neighbour');
			// serving entry (pci == serving_cell_id) carries metrics in 0.1 dB units
			let srv = filter(li.cells, (c) => c.pci == li.serving_cell_id)[0];
			eq(srv?.rsrp, -930, 'serving cell rsrp ×10 (0.1 dB units, QMI scale)');
			let nb = filter(li.cells, (c) => c.pci == 155)[0];
			eq(nb?.rsrp, -990, 'neighbour cell rsrp ×10 from QENG neighbourcell');
			eq(nb?.rsrq, -130, 'neighbour cell rsrq ×10');

			// inter-frequency neighbours grouped by earfcn
			eq(m.cells?.lte_inter?.freqs[0]?.earfcn, 100, 'lte_inter freq earfcn');
			eq(m.cells?.lte_inter?.freqs[0]?.cells[0]?.pci, 88, 'lte_inter neighbour pci');

			// NR5G serving cell (nr5g_cell) + arfcn, metrics ×10
			eq(m.cells?.nr5g_arfcn, 431070, 'nr5g_arfcn');
			eq(m.cells?.nr5g_cell?.pci, 242, 'nr5g_cell.pci');
			eq(m.cells?.nr5g_cell?.rsrp, -1020, 'nr5g_cell.rsrp ×10');
			eq(m.cells?.nr5g_cell?.snr, 190, 'nr5g_cell.snr ×10');

			// QCAINFO -> ca
			eq(length(m.cells?.ca), 2, 'QCAINFO -> two carriers');
			eq(m.cells?.ca[0]?.role, 'PCC', 'ca[0] role PCC');
			eq(m.cells?.ca[0]?.band, 3, 'ca[0] band 3');

			// data-system mode from the QENG NR line
			eq(m.dsd_status?.mode, 'NSA', 'dsd_status mode = NSA');

			// CEER -> reg_detail (mapped through the QMI REJECT_CAUSE table)
			eq(m.reg_detail?.reject_cause, 33, 'CEER -> reg_detail.reject_cause 33');
			eq(m.reg_detail?.reject_text, 'requested service option not subscribed',
				'reject_cause 33 mapped to text via REJECT_CAUSE');

			// cell-lock read-back surfaced on self.locks
			eq(m.locks?.lte?.enabled, true, 'QNWLOCK read -> self.locks.lte.enabled');
			eq(m.locks?.lte?.values, [ 1300, 246 ], 'self.locks.lte.values (earfcn/pci)');

			env.finish();
		});
	},
});

// --- s7b: Huawei telemetry (HCSQ / MONSC / MONNC / CHIPTEMP) ------------------
//
// The Huawei vendor block shipped with zero coverage: a regex slip silently
// nulls telemetry on Huawei sticks. Asserts the HCSQ index->dBm conversion, the
// MONSC/MONNC cell assembly into the QMI shapes, CEER and the temperature read.

push(scenarios, {
	name: 's7b_huawei_telemetry',
	script: script([
		{ re: /^AT\+CGMI$/, lines: [ 'Huawei' ] },
		{ re: /^AT\+CGMM$/, lines: [ 'E3372h-320' ] },
		{ re: /^AT\+CSQ$/,  lines: [ '+CSQ: 18,99' ] },
		// index->dBm: rssi 46-121=-75, rsrp 55-141=-86, sinr 146*0.2-20=9.2,
		// rsrq 26*0.5-19.5=-6.5
		{ re: /^AT\^HCSQ\?$/, lines: [ '^HCSQ: "LTE",46,55,146,26' ] },
		{ re: /^AT\^MONSC$/, lines: [ '^MONSC: LTE,262,01,1300,1C36403,246,BFF,-93,-11,-61' ] },
		{ re: /^AT\^MONNC$/, lines: [ '^MONNC: LTE,1300,155,-99,-13,0,8' ] },
		{ re: /^AT\+CEER$/, lines: [ '+CEER: EMM cause 33, requested service option not subscribed' ] },
		{ re: /^AT\^CHIPTEMP/, lines: [ '^CHIPTEMP: 42' ] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6', mux_id: 0 },
	run: (env) => {
		let m = env.modem;

		uloop.timer(1500, () => {
			// HCSQ wins over the CSQ floor for the per-RAT block
			eq(m.signal?.lte?.rssi, -75, 'huawei: HCSQ rssi index 46 -> -75 dBm');
			eq(m.signal?.lte?.rsrp, -86, 'huawei: HCSQ rsrp index 55 -> -86 dBm');
			eq(m.signal?.lte?.rsrq, -6.5, 'huawei: HCSQ rsrq index 26 -> -6.5 dB');
			ok(m.signal?.lte?.snr >= 91.9 && m.signal?.lte?.snr <= 92.1,
				'huawei: HCSQ sinr index 146 -> ~9.2 dB (snr in 0.1 dB)');

			// MONSC serving identifiers -> lte_intra (QMI shape)
			let li = m.cells?.lte_intra;
			eq(li?.plmn, '262/01', 'huawei: MONSC plmn');
			eq(li?.earfcn, 1300, 'huawei: MONSC earfcn');
			eq(li?.tac, 3071, 'huawei: MONSC tac (hex BFF)');
			eq(li?.global_cell_id, 29582339, 'huawei: MONSC cid (hex 1C36403)');
			eq(li?.serving_cell_id, 246, 'huawei: MONSC pci = serving_cell_id');
			eq(length(li?.cells), 2, 'huawei: serving + MONNC neighbour');
			let srv = filter(li.cells, (c) => c.pci == 246)[0];
			eq(srv?.rsrp, -930, 'huawei: serving rsrp x10 (0.1 dB)');
			let nb = filter(li.cells, (c) => c.pci == 155)[0];
			eq(nb?.rsrp, -990, 'huawei: MONNC neighbour rsrp x10');
			eq(nb?.rsrq, -130, 'huawei: MONNC neighbour rsrq x10');

			eq(m.reg_detail?.reject_cause, 33, 'huawei: CEER cause via REJECT_CAUSE');
			eq(m.temperature?.celsius, 42, 'huawei: CHIPTEMP -> temperature');
			eq(m.dsd_status?.mode, 'LTE', 'huawei: dsd mode LTE from cell source');

			env.finish();
		});
	},
});

// --- s7c: MeiG telemetry (MENG serving/neighbour, CELLLOCK, TEMP) -------------
//
// The MeiG (SLM770A / Cudy LT300) vendor block likewise had zero checks. Also
// exercises the fractional-RSRQ firmware trap (-10.5) and the CESQ-error path
// (signal must survive a failing AT+CESQ, keeping the CSQ floor + MENG fill).

push(scenarios, {
	name: 's7c_meig_telemetry',
	script: script([
		{ re: /^AT\+CGMI$/, lines: [ 'MEIG' ] },
		{ re: /^AT\+CGMM$/, lines: [ 'SLM770A-R' ] },
		{ re: /^AT\+CSQ$/,  lines: [ '+CSQ: 20,99' ] },          // floor rssi -73
		{ re: /^AT\+CESQ$/, lines: [], term: 'ERROR' },          // must not break signal
		{ re: /^AT\+MENG="servingcell"$/, lines: [
			'+MENG: "servingcell","NOCONN","LTE",0,262,01,1C36403,246,1300,3,5,5,BFF,-93,-10.5,-61,21,15',
		] },
		{ re: /^AT\+MENG="neighbourcell"$/, lines: [
			'+MENG: "neighbourcell intra","LTE",1300,155,-99,-13.5,-,-,8',
			'+MENG: "neighbourcell inter","LTE",100,88,-105,-15,-,-,4',
		] },
		{ re: /^AT\^CELLLOCK\?$/, lines: [ '^CELLLOCK: 1,"LTE",1,1300,246' ] },
		{ re: /^AT\+TEMP/, lines: [ '+TEMP: "soc-thmzone","42000"' ] },   // milli-C
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4', mux_id: 0 },
	run: (env) => {
		let m = env.modem;

		uloop.timer(1500, () => {
			// MENG serving fills the per-RAT signal; CSQ floor supplies rssi
			eq(m.signal?.lte?.rsrp, -93, 'meig: MENG rsrp -> signal.lte (dBm)');
			eq(m.signal?.lte?.rsrq, -10.5, 'meig: fractional MENG rsrq survives');
			eq(m.signal?.lte?.snr, 210, 'meig: MENG sinr 21 dB -> snr 210 (0.1 dB)');
			eq(m.signal?.lte?.rssi, -73, 'meig: CSQ floor rssi (CESQ ERROR tolerated)');

			let li = m.cells?.lte_intra;
			eq(li?.plmn, '262/01', 'meig: MENG plmn');
			eq(li?.tac, 3071, 'meig: MENG tac (hex BFF)');
			eq(li?.global_cell_id, 29582339, 'meig: MENG cid');
			eq(li?.serving_cell_id, 246, 'meig: MENG pci');
			let srv = filter(li.cells, (c) => c.pci == 246)[0];
			eq(srv?.rsrp, -930, 'meig: serving rsrp x10');
			let nb = filter(li.cells, (c) => c.pci == 155)[0];
			eq(nb?.rsrp, -990, 'meig: neighbour rsrp x10');
			eq(nb?.rsrq, -135, 'meig: fractional neighbour rsrq x10 (-13.5 -> -135)');

			// inter-frequency neighbours grouped by earfcn
			eq(m.cells?.lte_inter?.freqs[0]?.earfcn, 100, 'meig: inter freq earfcn');
			eq(m.cells?.lte_inter?.freqs[0]?.cells[0]?.pci, 88, 'meig: inter neighbour pci');

			// CELLLOCK read-back -> self.locks
			eq(m.locks?.lte?.enabled, true, 'meig: CELLLOCK enabled');
			eq(m.locks?.lte?.values, [ 1300, 246 ], 'meig: CELLLOCK arfcn/pci values');

			// milli-Celsius TEMP normalized
			eq(m.temperature?.celsius, 42, 'meig: TEMP 42000 milli-C -> 42 C');

			env.finish();
		});
	},
});

// --- s8: synchronous teardown INSIDE the 'registered' emit ------------------
// The autosetup phase-2 reload (uci write + apply_config) runs synchronously
// under emit('registered') and tears the emitting modem instance down
// (close_at nulls the AT engines). on_registered must notice and NOT start the
// READY telemetry hooks on the corpse — this crashed the daemon on the Cudy
// LT300 (tel_meig_locks over telemetry_at(null).send). The runner calls run()
// synchronously from the 'registered' event, i.e. exactly inside that emit.

push(scenarios, {
	name: 's8_teardown_in_registered_emit',
	script: script(),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6', mux_id: 0 },
	run: (env) => {
		let m = env.modem;

		// simulate the reload: stop this instance while emit('registered') is
		// still on the stack (surviving this line at all is the core check —
		// pre-fix the daemon crashed right here)
		m.stop();
		eq(m.state, 'ABSENT', 'teardown-in-emit: modem stopped to ABSENT');

		// give any (wrongly) started telemetry a tick, then verify the READY
		// hooks never ran: no lock read-back, no telemetry poll on the tty
		uloop.timer(50, () => {
			eq(env.tr.saw(/QNWLOCK/), null, 'teardown-in-emit: no lock read-back after stop');
			eq(env.tr.saw(/^AT\+CSQ/), null, 'teardown-in-emit: no telemetry poll after stop');
			env.finish();
		});
	},
});

// --- s9: Fibocom FM350-GL static-IP path (empty-local CGCONTRDP + CGPADDR) ---

// base Fibocom FM350-GL bring-up + connect script. CGCONTRDP answers in the
// T700 empty-local form (gateway + dns only — the exact live capture), plus an
// IPv6 line for the parity check. `over` prepends scenario overrides.
function fscript(over)
{
	return [
		...(over ?? []),
		{ re: /^AT\+CGMI$/, lines: [ 'Fibocom Wireless Inc.' ] },
		{ re: /^AT\+CGMM$/, lines: [ 'FM350-GL' ] },
		{ re: /^AT\+CGMR$/, lines: [ 'FM350GL_04.02.10' ] },
		{ re: /^AT\+CGSN$/, lines: [ '350000000000000' ] },
		// the FM350 has no vendor operator command -> the generic AT+COPS? path,
		// answering at the 3GPP default format 0 (a NAME, no mcc/mnc)
		{ re: /^AT\+COPS\?$/, lines: [ '+COPS: 0,0,"Telekom.de",7' ] },
		{ re: /^AT\+GTFCCEFFSTATUS\?$/, lines: [ '+GTFCCEFFSTATUS: 0' ] },
		{ re: /^AT\+SIMTYPE\?$/, lines: [ '+SIMTYPE: 0' ] },
		{ re: /^AT\+ESLOTSINFO/, lines: [ '+ESLOTSINFO: 2, "+CPIN: READY", "1", "0", "3B00000000000000", "", "89000000000000000000", "+CPIN: EMPTY_EUICC", "1", "1", "3B9F00000000000000000000", "89000000000000000000000000000000", ""' ] },
		{ re: /^AT\+EID$/, lines: [ '+EID: 89000000000000000000000000000000' ] },
		{ re: /^AT\+CIMI$/, lines: [ '001010123456789' ] },
		{ re: /^AT\+QCCID$/, term: 'ERROR', lines: [] },      // quectel-only probe
		{ re: /^AT\+ICCID$/, lines: [ '+ICCID: 89000000000000000000' ] },
		{ re: /^AT\+CPIN\?$/, lines: [ '+CPIN: READY' ] },
		{ re: /^AT\+CEREG\?$/, lines: [ '+CEREG: 2,1' ] },
		{ re: /^AT\+C5GREG\?$/, lines: [ '+C5GREG: 2,1' ] },
		{ re: /^AT\+GTDUALSIM\?$/, lines: [ '+GTDUALSIM : 0, "SUB1", "NR"' ] },
		{ re: /^AT\+GTRNDIS=\?$/, term: 'ERROR', lines: [] }, // no GTRNDIS on T700
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,5,"internet","","","192.0.2.1","192.0.2.22"',
			'+CGCONTRDP: 1,5,"internet",32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136,32.1.72.96.0.0.0.0.0.0.0.0.0.0.0.1,32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136',
		] },
		{ re: /^AT\+CGPADDR=1$/, lines: [ '+CGPADDR: 1,"192.0.2.190",""' ] },
		{ re: /^AT\+CGDCONT\?$/, lines: [] },                  // no existing profile
		{ re: /^AT\+CGACT=1,/, lines: [ 'OK' ] },
		{ re: /^AT\+GTCAINFO/, lines: [ '+GTCAINFO:', 'LTE PCC: 103,120,1279,75,2,1,1,1,71' ] },
		{ re: /^AT\+CSQ$/, lines: [ '+CSQ: 20,99' ] },
	];
}

let s9a_fx = fakefx.create({
	files: {
		'/sys/class/net/wwand0/mtu': '1500',
		'/proc/sys/net/ipv6/conf/wwand0/disable_ipv6': '1',
		'/proc/sys/net/ipv6/conf/wwand0/accept_ra': '0',
	},
	present: {
		'/proc/sys/net/ipv6/conf/wwand0/disable_ipv6': true,
		'/proc/sys/net/ipv6/conf/wwand0/accept_ra': true,
	},
	links: { '/sys/class/net/wwand0/device/driver': 'drivers/rndis_host' },
});

push(scenarios, {
	name: 's9a_fibocom_static_ip',
	script: fscript(),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	mconfig: { apn: 'internet' },   // concrete attach APN -> the CFUN cycle runs
	datapath: { netdev: 'wwand0', fx: s9a_fx },
	run: (env) => {
		let m = env.modem;

		ok(true, 'fibocom modem reached READY');
		eq(m.info.model, 'FM350-GL', 'fibocom model from CGMM');
		eq(m.dial.name, 'cgact', 'fibocom dial resolves to CGACT (GTRNDIS probe errors)');
		eq(s9a_fx.action_index('link_set wwand0 up noarp'), 0,
			's9a: rndis_host datapath comes up with NOARP');
		eq(m.datapath?.backend, 'rndis_host', 's9a: datapath label reads the real driver');
		ok(type(env.ctx.liveness_poke) == 'function' && type(env.ctx.settings_poke) == 'function',
			's9a: URC poke entry points exposed');
		eq(m.fcc_lock, 0, 's9a: FCC-lock probe read (unlocked)');

		eq(m.esim_state, '89000000000000000000000000000000', 's9a: eSIM surface probes run (EID last)');
		ok(any_event(env.mevents, 'esim_ready'), 's9a: esim_ready emitted after the probes');
		eq(s9a_fx.files['/proc/sys/net/ipv6/conf/wwand0/accept_ra'], '2',
			's9a: RA acceptance enabled on the netdev (accept_ra 2)');

		env.ctx.up((err, settings) => {
			eq(err, null, 'fibocom context up succeeds');
			eq(env.ctx.state, 'CONNECTED', 'fibocom context CONNECTED');

			// static /32 p2p: address from CGPADDR, gateway stays null — the
			// shim applies a gateway-less default device route (NOARP on rndis)
			eq(settings?.ipv4?.addr, '192.0.2.190', 'fibocom ipv4 addr from CGPADDR');
			eq(settings?.ipv4?.prefix, 32, 'fibocom ipv4 stays /32 (host-route model)');
			eq(settings?.ipv4?.gateway, null, 'fibocom gateway stays null (device route + NOARP on rndis)');
			// BOTH resolvers survive: the local/gateway slots are empty, so the
			// first DNS is no longer promoted to the address and then discarded
			eq(settings?.ipv4?.dns, [ '192.0.2.1', '192.0.2.22' ],
				'fibocom: both CGCONTRDP resolvers kept (none eaten as the address)');
			eq(settings?.mtu, 1500, 'fibocom mtu falls back to the netdev mtu (1500)');

			// IPv6 parity: the CGCONTRDP v6 line survives the static v4 path
			eq(settings?.ipv6?.addr, '2001:4860:4860:0:0:0:0:8888', 'fibocom ipv6 addr from CGCONTRDP (parity)');
			ok(settings?.ipv6?.gateway == '2001:4860:0:0:0:0:0:1', 'fibocom ipv6 gateway decoded');

			ok(env.tr.saw(/^AT\+CGPADDR=1$/) != null, 'fibocom static path queried CGPADDR');
			ok(env.tr.saw(/^AT\+CREG=3;\+CGREG=3;\+CEREG=3;\+C5GREG=3;\+CGEREP=2,1$/) != null,
				's9a: URC enables issued');
			ok(env.tr.saw(/^AT\+CTZR=1$/) != null, 's9a: NITZ URC enabled');
			// the empty CGDCONT? answer means the attach profile changes on every
			// connect — the CFUN 0/1 radio cycle must run each time
			ok(env.tr.saw(/^AT\+CFUN=0$/) != null, 's9a: attach-change radio cycle ran (CFUN 0 leg)');

			// the RS nudge toggles disable_ipv6 (1 then 0, 1s apart) after connect
			uloop.timer(1500, () => {
				eq(s9a_fx.files['/proc/sys/net/ipv6/conf/wwand0/disable_ipv6'], '0',
					's9a: RS nudge restores IPv6 on the netdev');
				ok(length(s9a_fx.matching('/proc/sys/net/ipv6/conf/wwand0/disable_ipv6')) >= 3,
					's9a: RS nudge toggled disable_ipv6 (datapath + 1/0 pair)');

				// the operator on the GENERIC path: the FM350 documents no
				// vendor operator command (^EONS is MeiG/Huawei dialect), so it
				// goes through AT+COPS? — and at the 3GPP default format that
				// answer is a NAME with no mcc/mnc. Accepting only the numeric
				// form would leave every Fibocom reporting no operator at all.
				// (Asserted here, not at 'registered': the read is async.)
				eq(env.modem.reg?.plmn?.description, 'Telekom.de',
					's9a: operator name taken from a format-0 COPS answer');
				eq(env.modem.reg?.plmn?.mcc, null,
					's9a: a name-format answer carries no mcc');

				env.finish();
			});
		});
	},
});

push(scenarios, {
	name: 's9c_fibocom_filled_cgcontrdp',
	script: fscript([
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,5,internet,10.20.30.40.255.255.255.0,10.20.30.1,8.8.8.8,8.8.4.4',
			'+CGCONTRDP: 1,5,internet,32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136,32.1.72.96.0.0.0.0.0.0.0.0.0.0.0.1,32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136',
		] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 'fibocom-filled context up succeeds');

			// Qualcomm-style regression: a filled CGCONTRDP takes the generic
			// path and CGPADDR is NEVER sent
			eq(settings?.ipv4?.addr, '10.20.30.40', 'fibocom-filled addr from CGCONTRDP');
			eq(settings?.ipv4?.gateway, '10.20.30.1', 'fibocom-filled gateway from CGCONTRDP');
			ok(env.tr.saw(/^AT\+CGPADDR=/) == null, 'fibocom-filled: no CGPADDR sent');

			env.finish();
		});
	},
});

push(scenarios, {
	name: 's9e_fibocom_v6_dns_pair',
	script: fscript([
		// v6-only PDP (field-analyzed): CGCONTRDP carries the ISP DNS PAIR in
		// the v6 slots — no host address, no link-local gateway. The hook must
		// demote them to DNS and NEVER surface a v6 address. And per the atc/
		// 3GPP model an ipv6-only PDP carries NO host v4: the embedded
		// <0×8, 0,1, 0,0><v4> CGPADDR form (the modem-CLAT artifact) must not
		// be assigned either — host v4 comes from the 464xlat package.
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,6,"internet","","","32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136","32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.68","","",0,,0',
		] },
		{ re: /^AT\+CGPADDR=1$/, lines: [ '+CGPADDR: 1,"0.0.0.0.0.0.0.0.0.1.0.0.192.0.2.48",""' ] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv6' },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 's9e context up succeeds');
			eq(settings?.ipv6?.addr, null, 's9e: no v6 address surfaced (DNS pair demoted)');
			eq(settings?.ipv6?.gateway, null, 's9e: no v6 gateway from the pair');
			eq(settings?.ipv6?.dns, [ '2001:4860:4860:0:0:0:0:8888', '2001:4860:4860:0:0:0:0:8844' ],
				's9e: the pair rides in dns (the DNS-only bucket)');
			eq(settings?.ipv6?.unmanaged, true, 's9e: the DNS-only v6 bucket is marked unmanaged (status rendering)');
			eq(settings?.ipv4, null, 's9e: no v4 on the ipv6-only PDP (embedded form not applied)');
			env.finish();
		});
	},
});

push(scenarios, {
	name: 's9v_fibocom_bogus_v6_addr',
	script: fscript([
		// ByteSIM field case: CGPADDR reports a NAT64-embedded junk address
		// (::<v4-hex>) as the PDP address — the real host v6 arrives via RA.
		// The validity filter must drop it (never push ::…/128 to netifd) and
		// fall back to the DNS-only/unmanaged bucket.
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,6,"internet","","","32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136","32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.68","","",0,,0',
		] },
		{ re: /^AT\+CGPADDR=1$/, lines: [ '+CGPADDR: 1,"::beef:beef:beef:beef",""' ] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv6' },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 's9v context up succeeds');
			eq(settings?.ipv6?.addr, null, 's9v: the NAT64-embedded junk address is dropped');
			eq(settings?.ipv6?.unmanaged, true, 's9v: falls back to the unmanaged (DNS-only) bucket');
			eq(settings?.ipv6?.dns, [ '2001:4860:4860:0:0:0:0:8888', '2001:4860:4860:0:0:0:0:8844' ],
				's9v: the real DNS pair survives');
			env.finish();
		});
	},
});

// s9n: 5G drops away and the NR signal block must go with it.
//
// Reported on an FM350-GL riding out heavy rain (openwrt/luci#8917): the modem
// fell back from 5G to LTE, the serving cell correctly read LTE/B3, and the two
// 5G bars underneath kept showing the last NR reading forever.
//
// fill_signal_from_serving() starts from a COPY of the previous signal block,
// so a branch that simply is not written on a tick survived untouched. The
// values are the ones from that report: rsrp -83 dBm (raw 76), sinr 10 dB
// (raw 20).
let s9n_cells = { re: /^AT\+GTCCINFO\?$/, lines: [
	'+GTCCINFO:',
	'1,4,001,01,0001,001DBE47B,38927,272,140,100,13,54,54,12',
	'2,9,,,FFFFFFF,00FFFFFFF,646272,500,5078,100,20,0,76,67',
] };

push(scenarios, {
	name: 's9n_fibocom_nr_dropout',
	script: fscript([
		{ re: /^AT\+GTCAINFO/, lines: [ '+GTCAINFO:' ] },
		s9n_cells,
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	run: (env) => {
		env.ctx.up((err) => {
			eq(err, null, 's9n context up succeeds');

			env.modem.watch();

			wait_for(() => env.modem.signal?.nr5g?.rsrp != null, () => {
				// NR scales divide by 2.0, so these are doubles — eq() compares
				// the JSON form, where -83.0 and -83 are not the same text
				eq(env.modem.signal?.nr5g?.rsrp, -83.0, 's9n: NR rsrp while 5G is serving');
				eq(env.modem.signal?.nr5g?.snr, 100.0, 's9n: NR sinr while 5G is serving (0.1 dB)');
				eq(env.modem.signal?.lte?.rsrp, -87, 's9n: LTE rsrp alongside it');

				// heavy rain: the NR row is gone, LTE alone remains
				s9n_cells.lines = [
					'+GTCCINFO:',
					'1,4,001,01,0001,001DBE47B,38927,272,140,100,13,54,54,12',
				];
				env.modem.watch();

				wait_for(() => env.modem.cells?.serving?.nr == null, () => {
					eq(env.modem.signal?.nr5g, null,
						's9n: the NR signal block disappears with the NR serving cell');
					eq(env.modem.signal?.lte?.rsrp, -87,
						's9n: the LTE branch is untouched by the NR dropout');
					env.finish();
				});
			});
		});
	},
});

push(scenarios, {
	name: 's9d_fibocom_gtccinfo_fallback',
	script: fscript([
		// T700 firmware: GTCAINFO? answers with an empty body, the serving
		// cell row comes from GTCCINFO? (verbatim live capture)
		{ re: /^AT\+GTCAINFO/, lines: [ '+GTCAINFO:' ] },
		{ re: /^AT\+GTCCINFO\?$/, lines: [
			'+GTCCINFO:',
			'1,4,001,01,0001,001DBE47B,38927,272,140,100,13,54,54,12',
		] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	run: (env) => {
		env.ctx.up((err) => {
			eq(err, null, 's9d context up succeeds');
			// first telemetry tick fires stats_interval (1000 ms) after READY
			uloop.timer(1300, () => {
				eq(env.modem.cells?.serving?.lte?.band, 40, 's9d: GTCCINFO fallback fills band 40');
				eq(env.modem.cells?.serving?.lte?.rsrp, -87, 's9d: rsrp from GTCCINFO');
				eq(env.modem.cells?.serving?.lte?.pci, 272, 's9d: pci from GTCCINFO');
				eq(env.modem.signal?.lte?.rsrp, -87, 's9d: signal rsrp filled from serving');
				ok(env.modem.dsd_status != null, 's9d: dsd/tech set from the serving cell');
				ok(env.tr.saw(/^AT\+GTCCINFO\?$/) != null, 's9d: GTCCINFO was queried');
				env.finish();
			});
		});
	},
});

let s9s_fx = fakefx.create({
	files: {
		'/sys/class/net/wwand0/mtu': '1500',
		'/sys/class/net/wwand0/statistics/rx_bytes': '1234567890',
		'/sys/class/net/wwand0/statistics/tx_bytes': '987654321',
		'/sys/class/net/wwand0/statistics/rx_packets': '1000',
		'/sys/class/net/wwand0/statistics/tx_packets': '900',
		'/proc/sys/net/ipv6/conf/wwand0/disable_ipv6': '1',
		'/proc/sys/net/ipv6/conf/wwand0/accept_ra': '0',
	},
	present: {
		'/proc/sys/net/ipv6/conf/wwand0/disable_ipv6': true,
		'/proc/sys/net/ipv6/conf/wwand0/accept_ra': true,
	},
	links: { '/sys/class/net/wwand0/device/driver': 'drivers/rndis_host' },
});

push(scenarios, {
	name: 's9s_fibocom_endc_merge',
	script: fscript([
		// EN-DC rows (verbatim live shape): GTCAINFO carries the two PCC rows
		// (NR first), GTCCINFO the matching serving rows + the temp read
		{ re: /^AT\+GTCAINFO/, lines: [
			'+GTCAINFO:',
			'PCC:5041,770,532002,300,300,3,1,3,1,-87',
			'PCC:103,272,1775,75,75,1,1,1,3,-85',
		] },
		{ re: /^AT\+GTCCINFO\?$/, lines: [
			'+GTCCINFO:',
			'1,4,001,01,0001,001DBE47B,1775,272,103,75,17,55,55,21',
			'1,9,,,FFFFFFF,00FFFFFFF,532002,770,5041,300,28,69,69,65',
		] },
		{ re: /^AT\+ETHERMAL\?$/, lines: [ '+ETHERMAL: 47' ] },
	]),
	datapath: { netdev: 'wwand0', fx: s9s_fx },
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	ctx_timing: { stats_interval: 5, zero_rx_ms: 0 },
	run: (env) => {
		env.ctx.up((err) => {
			eq(err, null, 's9s context up succeeds');
			uloop.timer(1300, () => {
				let sl = env.modem.cells?.serving?.lte;
				let sn = env.modem.cells?.serving?.nr;
				let ca = env.modem.cells?.ca;

				// the matching GTCCINFO LTE row enriches identity + rsrq/sinr/bw
				eq(sl?.pci, 272, 's9s: lte pci stays GTCAINFO-authoritative');
				eq(sl?.rsrp, -85, 's9s: lte rsrp stays the signed GTCAINFO value');
				eq(sl?.rsrq, -9.5, 's9s: lte rsrq enriched from GTCCINFO');
				eq(sl?.sinr, 8.5, 's9s: lte sinr enriched from GTCCINFO');
				eq(sl?.cid, 31188091, 's9s: lte identity (cid) enriched from GTCCINFO');
				eq(sl?.tac, 1, 's9s: lte identity (tac) enriched from GTCCINFO');

				// the matching GTCCINFO NR row fills the gaps the NR PCC row
				// leaves: rsrq/sinr/bw (NR scales) — the 5G status SNR follows
				eq(sn?.pci, 770, 's9s: nr pci');
				eq(sn?.rsrp, -87, 's9s: nr rsrp stays the signed GTCAINFO value');
				eq(sn?.rsrq, -11.0, 's9s: nr rsrq from the GTCCINFO NR row');
				eq(sn?.sinr, 14.0, 's9s: nr sinr from the GTCCINFO NR row');

				eq(length(ca ?? []), 2, 's9s: both PCC carriers in the CA table');
				eq(ca?.[0]?.bandwidth_mhz, 15.0, 's9s: ca lte bandwidth_mhz');
				eq(ca?.[1]?.bandwidth_mhz, 60.0, 's9s: ca nr bandwidth_mhz (60 MHz n41)');
				eq(ca?.[1]?.rsrq, -110.0, 's9s: ca nr rsrq x10');
				eq(env.modem.signal?.nr5g?.snr, 140.0, 's9s: 5G status snr filled (sinr x10)');
				eq(env.modem.cells?.nr5g_cell?.snr, 140.0, 's9s: nr5g_cell snr filled');

				// the fibocom signal block follows the serving cells (refresh):
				// no independent NR/LTE source exists on this backend
				eq(env.modem.signal?.nr5g?.rsrp, -87, 's9s: signal.nr5g.rsrp == serving.nr.rsrp');
				eq(env.modem.signal?.lte?.rsrp, -85, 's9s: signal.lte.rsrp == serving.lte.rsrp');
				eq(env.modem.signal?.lte?.rsrq, -9.5, 's9s: signal.lte.rsrq == serving.lte.rsrq');

				// the fibocom/MediaTek temperature command (the 3ginfo-lite source)
				eq(env.modem.temperature?.celsius, 47.0, 's9s: ETHERMAL temperature read');
				ok(env.tr.saw(/^AT\+ETHERMAL\?$/) != null, 's9s: AT+ETHERMAL? was sent');

				// the netdev byte counters (no vendor stats AT on fibocom):
				// sampled from the datapath netdev statistics — the status
				// page / wwandctl byte counters + the zero-rx feed
				eq(env.ctx.stats?.rx_bytes, 1234567890, 's9s: netdev rx byte counter surfaced');
				eq(env.ctx.stats?.tx_bytes, 987654321, 's9s: netdev tx byte counter surfaced');

				env.finish();
			});
		});
	},
});

push(scenarios, {
	name: 's9t_fibocom_gtccinfo_mismatch',
	script: fscript([
		// a handover between the two sequential reads: GTCCINFO reports
		// DIFFERENT cells (lte pci 99/band 30, nr pci 777/band 78) — the
		// enrichment must drop them whole (no blending of two cells, and
		// no stale identity glued onto the new serving cell)
		{ re: /^AT\+GTCAINFO/, lines: [
			'+GTCAINFO:',
			'PCC:5041,770,532002,300,300,3,1,3,1,-87',
			'PCC:103,272,1775,75,75,1,1,1,3,-85',
		] },
		{ re: /^AT\+GTCCINFO\?$/, lines: [
			'+GTCCINFO:',
			'1,4,001,01,0002,00000ABC,1800,99,130,100,13,50,50,15',
			'1,9,,,FFFFFFF,00FFFFFFF,631334,777,5078,100,20,66,66,60',
		] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	run: (env) => {
		env.ctx.up((err) => {
			eq(err, null, 's9t context up succeeds');
			uloop.timer(1300, () => {
				let sl = env.modem.cells?.serving?.lte;
				let sn = env.modem.cells?.serving?.nr;
				let ca = env.modem.cells?.ca;

				eq(sl?.pci, 272, 's9t: lte pci keeps the GTCAINFO cell (mismatched row dropped)');
				eq(sl?.cid, null, 's9t: no stale cid glued onto the new cell');
				eq(sl?.tac, null, 's9t: no stale tac glued onto the new cell');
				eq(sl?.rsrq, null, 's9t: lte rsrq not enriched from the other cell');
				eq(sl?.sinr, null, 's9t: lte sinr not enriched from the other cell');
				eq(sn?.pci, 770, 's9t: nr pci keeps the GTCAINFO cell');
				eq(sn?.rsrq, null, 's9t: nr rsrq not enriched from the other cell');
				eq(sn?.sinr, null, 's9t: nr sinr not enriched from the other cell');
				eq(ca?.[0]?.rsrq, null, 's9t: ca lte rsrq stays empty');
				eq(ca?.[1]?.rsrq, null, 's9t: ca nr rsrq stays empty');

				env.finish();
			});
		});
	},
});

// --- s9 units: dual-slot surface ---------------------------------------------

let fb_slots = ncm_vendors.VENDORS.fibocom.slots;

eq(fb_slots.switch(2), 'AT+GTDUALSIM=1', 'fibocom slot switch maps slot 2 -> GTDUALSIM=1');
eq(fb_slots.switch(1), 'AT+GTDUALSIM=0', 'fibocom slot switch maps slot 1 -> GTDUALSIM=0');
eq(fb_slots.parse([ '+GTDUALSIM : 0, "SUB1", "NR"' ])?.sub, 1, 'fibocom gtdualsim parse: SUB1 active');
eq(fb_slots.parse([ '+GTDUALSIM : 1, "SUB2", "NO SERVICE"' ])?.sub, 2, 'fibocom gtdualsim parse: SUB2 active');
eq(fb_slots.parse([]), null, 'fibocom gtdualsim parse: empty -> null');

// vendor resolution: the fibocom match must win over mediatek when a T700
// unit's CGMI carries both tokens ("MediaTek Fibocom Wireless Inc.")
eq(ncm_vendors.vendor_for('MediaTek Fibocom Wireless Inc.'), ncm_vendors.VENDORS.fibocom,
	'vendor_for: fibocom wins over the mediatek match');

// The MODEL is the fallback key. AT+CGMI is the one identify answer a modem may
// withhold — the T700 returns nothing at all for it while a PDN teardown runs —
// and a null manufacturer used to drop the modem to `generic` for the whole
// session, taking ip_config/dials/telemetry with it. AT+CGMM answered correctly
// in the very same chain.
eq(ncm_vendors.vendor_for(null, 'FM350-GL'), ncm_vendors.VENDORS.fibocom,
	'vendor_for: empty CGMI falls back to the model (FM350-GL -> fibocom)');
eq(ncm_vendors.vendor_for('', 'RG650E-EU'), ncm_vendors.VENDORS.quectel,
	'vendor_for: model fallback resolves quectel');
eq(ncm_vendors.vendor_for('', 'SLM770A'), ncm_vendors.VENDORS.meig,
	'vendor_for: model fallback resolves meig');
eq(ncm_vendors.vendor_for('Quectel', 'FM350-GL'), ncm_vendors.VENDORS.quectel,
	'vendor_for: a known manufacturer still wins over the model');
eq(ncm_vendors.vendor_for(null, 'WEIRD-9000'), ncm_vendors.VENDORS.generic,
	'vendor_for: unknown on both keys -> generic');
eq(ncm_vendors.vendor_name(ncm_vendors.VENDORS.fibocom), 'fibocom',
	'vendor_name: recipe maps back to its key (for the log line)');

// vendor URC sets: only codes the vendor documentation actually attests, since
// a prefix here is filtered OUT of that modem's command responses
ok(index(ncm_vendors.VENDORS.meig.urcs, '^DSFLOWRPT') >= 0,
	'meig urcs: the traffic REPORT is listed');
eq(index(ncm_vendors.VENDORS.meig.urcs, '^DSFLOWQRY'), -1,
	'meig urcs: the QUERY answer is NOT — it is this recipe\'s own stats command');
eq(index(ncm_vendors.VENDORS.huawei.urcs, '^NDISSTATQRY'), -1,
	'huawei urcs: likewise the NDISSTATQRY answer is not treated as a URC');
ok(index(ncm_vendors.VENDORS.huawei.urcs, '^DSFLOWRPT') >= 0,
	'huawei urcs: the traffic-report push is filtered (field-seen every ~2 s on the E3372H)');
eq(length(ncm_vendors.VENDORS.generic.urcs ?? []), 0,
	'generic: no vendor codes guessed for an unidentified modem');

// huawei ip_config: the E3372H on stick firmware 21.200 (HW-observed on the
// WH3000 Pro, 2026-08-30) does NOT implement CGCONTRDP or GTDNS — both answer
// bare ERROR. The PDP address comes from CGPADDR; the /32 p2p model needs no
// gateway and there is no DNS-over-AT at all (operator config covers it).
let hw_sent = [];
let hw_at = {
	send: (cmd, cb) => {
		push(hw_sent, cmd);

		if (match(cmd, /CGCONTRDP/))
			return cb({ error: 'ERROR' }, null);

		if (match(cmd, /CGPADDR/))
			return cb(null, { lines: [ '+CGPADDR: 1,"100.67.207.142"' ] });

		return cb({ error: 'unexpected command' }, null);
	},
};
let hw_res = null;

ncm_vendors.VENDORS.huawei.ip_config({ at: hw_at }, 1, { pdp_type: 'ipv4v6' },
	(e, rdp) => { hw_res = { e: e, rdp: rdp }; });
eq(hw_sent, [ 'AT+CGCONTRDP=1', 'AT+CGPADDR=1' ],
	'huawei ip_config: CGCONTRDP tried first, CGPADDR on ERROR');
eq(hw_res.e, null, 'huawei ip_config: no error');
eq(hw_res.rdp.ipv4.addr, '100.67.207.142', 'huawei ip_config: v4 addr from CGPADDR');
eq(hw_res.rdp.ipv4.gateway, null, 'huawei ip_config: gateway-less /32 p2p model');
eq(hw_res.rdp.ipv4.prefix, null, 'huawei ip_config: prefix left to the shim (/32)');
eq(length(hw_res.rdp.ipv4.dns ?? []), 0, 'huawei ip_config: no DNS over AT on this firmware');
eq(hw_res.rdp.ipv6, null, 'huawei ip_config: no v6 claim (RA/dhcpv6 subinterface covers it)');

// firmware that FILLS CGCONTRDP takes the generic path — CGPADDR never sent
let hw_sent2 = [];
let hw_res2 = null;

ncm_vendors.VENDORS.huawei.ip_config({ at: {
	send: (cmd, cb) => {
		push(hw_sent2, cmd);

		if (match(cmd, /CGCONTRDP/))
			return cb(null, { lines: [
				'+CGCONTRDP: 1,5,internet,100.64.0.5.255.255.255.252,100.64.0.6,1.1.1.1,1.0.0.1',
			] });

		return cb({ error: 'unexpected command' }, null);
	},
} }, 1, { pdp_type: 'ipv4v6' }, (e, rdp) => { hw_res2 = { e: e, rdp: rdp }; });
eq(hw_sent2, [ 'AT+CGCONTRDP=1' ], 'huawei ip_config: a filled CGCONTRDP ends the probe');
eq(hw_res2.rdp.ipv4.addr, '100.64.0.5', 'huawei ip_config: generic parse result kept');
eq(hw_res2.rdp.ipv4.gateway, '100.64.0.6', 'huawei ip_config: gateway from CGCONTRDP');

// huawei session_urc: ^NDISSTAT is the bearer push (field-seen on the E3372H
// 21.200, 2026-08-30). One line per family on this firmware, one folded line
// on newer — both must parse; the ^NDISSTATQRY ANSWER is a different name and
// must never read as a push.
let hw_surc = ncm_vendors.VENDORS.huawei.session_urc;

eq(hw_surc('^NDISSTAT:1,,,"IPV4"'), { up: true }, 'huawei surc: v4 up');
eq(hw_surc('^NDISSTAT:0,36,,"IPV4"'), { up: false }, 'huawei surc: v4 down (reason 36 = regular deactivation)');
eq(hw_surc('^NDISSTAT:1,,,"IPV6"'), { up: true }, 'huawei surc: v6 up');
eq(hw_surc('^NDISSTAT:0,,,"IPV4",0,33,,"IPV6"'), { up: false }, 'huawei surc: folded dual line, both down');
eq(hw_surc('^NDISSTAT:0,36,,"IPV4",1,,,"IPV6"'), { up: true }, 'huawei surc: folded line with v6 still up');
eq(hw_surc('^NDISSTATQRY: 1,,,"IPV4",1,,,"IPV6"'), null, 'huawei surc: the query ANSWER is not a push');
eq(hw_surc('^HCSQ:"LTE",36,28,126,22'), null, 'huawei surc: unrelated URC ignored');


push(scenarios, {
	name: 's9f_fibocom_dual_slot',
	script: fscript(),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	run: (env) => {
		let m = env.modem;

		m.slot_status((err, slots) => {
			eq(err, null, 's9f slot_status succeeds');
			eq(length(slots ?? []), 2, 's9f two slots reported');
			eq(slots?.[0]?.active, true, 's9f SUB1 (physical) active');
			eq(slots?.[0]?.service, 'NR', 's9f GTDUALSIM service surfaced on the active slot');
			eq(slots?.[0]?.iccid, '89000000000000000000', 's9f active slot carries the modem iccid');
			eq(slots?.[0]?.cpin, '+CPIN: READY', 's9f USIM slot CPIN from ESLOTSINFO');
			eq(slots?.[1]?.is_euicc, true, 's9f SUB2 flagged eUICC');
			eq(slots?.[1]?.eid, '89000000000000000000000000000000', 's9f eUICC EID from ESLOTSINFO');
			eq(slots?.[1]?.cpin, '+CPIN: EMPTY_EUICC', 's9f eUICC CPIN state surfaced');
			eq(slots?.[1]?.iccid, null, 's9f inactive slot identity unknown until switched');

			m.switch_slot(2, (e2) => {
				eq(e2, null, 's9f switch_slot succeeds');
				ok(env.tr.saw(/^AT\+GTDUALSIM=1$/) != null, 's9f GTDUALSIM=1 issued');
				ok(env.tr.saw(/^AT\+CFUN=1,1$/) != null, 's9f CFUN reset after the switch');

				m.switch_slot(1, (e3, res) => {
					eq(e3, null, 's9f back-switch succeeds');
					eq(res?.unchanged, true, 's9f back-switch short-circuits (mock still on SUB1)');
					env.finish();
				});
			});
		});
	},
});

// s9h: slot-switch re-enumeration watchdog + the one-attempt latch.
// `option sim_slot 2` with the mock permanently reporting SUB1: step_simslot
// fires the switch (GTDUALSIM=1 + CFUN reset) and stops the modem for the
// expected re-enumeration — which never comes here (no hotplug on a mocked
// tty, exactly like a firmware that keeps the USB device across the reset).
// The watchdog must resume the bring-up in place instead of leaving the modem
// parked ABSENT forever, and the latch must not fire a SECOND switch (that
// would reset-loop on a firmware that never takes the switch).
push(scenarios, {
	name: 's9h_fibocom_slot_switch_watchdog',
	script: fscript(),
	mconfig: { sim_slot: 2 },
	mtiming: { reenum: 20 },
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	run_at_start: true,
	run: (env) => {
		// phase 1: the switch fires and parks the modem for the re-enumeration
		wait_for(() => env.tr.saw(/^AT\+CFUN=1,1$/) != null, () => {
			ok(env.tr.saw(/^AT\+GTDUALSIM=1$/) != null, 's9h slot switch issued');

			// phase 2: nothing re-enumerates — the watchdog has to carry the
			// bring-up through to registration on its own
			wait_for(() => any_event(env.mevents, 'registered'), () => {
				ok(any_event(env.mevents, 'registered'),
					's9h watchdog resumed the bring-up in place (no hotplug came)');
				eq(env.tr.count(/^AT\+CGMI$/), 2,
					's9h exactly one restart of the identify chain');
				eq(env.tr.count(/^AT\+GTDUALSIM=1$/), 1,
					's9h one switch attempt per modem object (no CFUN reset loop)');
				env.finish();
			});
		});
	},
});

// s9g: v6-DNS-pair pin — the v6-only PDP's empty-local CGCONTRDP line carries
// the ISP DNS PAIR as bare 16-octet tokens. The v6_real heuristic must NOT
// surface them as a v6 address (that would apply a DNS as a /128) — with no
// real 32-octet assignment on its own line, the settings stay v6-free.
push(scenarios, {
	name: 's9g_fibocom_v6_dns_pair_only',
	script: fscript([
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,5,"internet","","",32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136,32.1.72.96.0.0.0.0.0.0.0.0.0.0.0.1',
		] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	datapath: { netdev: 'wwand0', fx: s9a_fx },
	run: (env) => {
		let m = env.modem;

		env.ctx.up((err, settings) => {
			eq(err, null, 's9g: context up succeeds');
			eq(settings?.ipv4?.addr, '192.0.2.190', 's9g: v4 from CGPADDR unaffected');
			eq(settings?.ipv6?.addr, null, 's9g: DNS tokens never applied as a v6 address');
			ok(settings?.ipv6?.unmanaged, 's9g: v6 stays unmanaged (host v6 = RA/SLAAC)');
			// the resolvers are IPv6, so they belong in the IPv6 bucket — they
			// used to be dumped into ipv4.dns regardless of family
			eq(settings?.ipv6?.dns,
				[ '2001:4860:4860:0:0:0:0:8888', '2001:4860:0:0:0:0:0:1' ],
				's9g: the v6 resolvers land in the v6 bucket');
			eq(settings?.ipv4?.dns, [], 's9g: no v4 resolver on this line — none invented');
			env.finish();
		});
	},
});

// s9h: GTDNS is the T700's canonical resolver query — its answer wins over
// the CGCONTRDP pair fallback
push(scenarios, {
	name: 's9h_fibocom_gt_dns',
	script: fscript([
		{ re: /^AT\+GTDNS/, lines: [ '+GTDNS: 1,"2001:4860:4860::8888","2001:4860:4860::8844"' ] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	datapath: { netdev: 'wwand0', fx: s9a_fx },
	run: (env) => {
		let m = env.modem;

		env.ctx.up((err, settings) => {
			eq(err, null, 's9h: context up succeeds');
			ok(env.tr.saw(/^AT\+GTDNS=1$/) != null, 's9h: GTDNS queried');
			eq(settings?.ipv6?.dns,
				[ '2001:4860:4860::8888', '2001:4860:4860::8844' ],
				's9h: GTDNS v6 resolvers win — in the v6 bucket');
			eq(settings?.ipv4?.dns, [ '192.0.2.1', '192.0.2.22' ],
				's9h: v4 keeps its own CGCONTRDP resolvers (no cross-family mixing)');
			env.finish();
		});
	},
});

// s9i: bare-empty CGCONTRDP (no quotes — field-seen right after a CFUN
// cycle): the positional gate must still detect the empty local/subnet and
// take the CGPADDR path (the gateway token must never become the address)
push(scenarios, {
	name: 's9i_fibocom_bare_empty_local',
	script: fscript([
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,5,internet,,,192.0.2.1,192.0.2.22,0,,0',
		] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4' },
	datapath: { netdev: 'wwand0', fx: s9a_fx },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 's9i: context up succeeds');
			eq(settings?.ipv4?.addr, '192.0.2.190', 's9i: CGPADDR address wins (gateway token never the addr)');
			eq(settings?.ipv4?.dns, [ '192.0.2.1', '192.0.2.22' ], 's9i: both v4 resolvers intact');
			env.finish();
		});
	},
});

// s9j: a wrapped continuation line (no +CGCONTRDP:<cid> prefix, empty fields
// 3/4) after a FILLED response must not hijack the static CGPADDR path —
// the positional prefix gate's whole reason to exist
push(scenarios, {
	name: 's9j_fibocom_wrapped_continuation',
	script: fscript([
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,5,internet,10.20.30.40.255.255.255.0,10.20.30.1,8.8.8.8,8.8.4.4,',
			'"","","",',
		] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 's9j: context up succeeds');
			eq(settings?.ipv4?.addr, '10.20.30.40', 's9j: addr from the filled CGCONTRDP line');
			eq(settings?.ipv4?.gateway, '10.20.30.1', 's9j: gateway intact (never CGPADDR)');
			ok(env.tr.saw(/^AT\+CGPADDR=/) == null,
				's9j: continuation line must NOT trigger the static path');
			env.finish();
		});
	},
});

// s9k: ipv4v6 PDP whose CGCONTRDP carries an empty v6 pair — the fallback_dns
// null-when-empty must let the CGCONTRDP v4 DNS survive the ?? chain (an empty
// ARRAY would be truthy and drop the DNS entirely)
push(scenarios, {
	name: 's9k_fibocom_empty_pair_dns',
	script: fscript([
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,5,"internet","","","192.0.2.1","192.0.2.22"',
		] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	datapath: { netdev: 'wwand0', fx: s9a_fx },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 's9k: context up succeeds');
			eq(settings?.ipv4?.addr, '192.0.2.190', 's9k: v4 from CGPADDR');
			eq(settings?.ipv4?.dns, [ '192.0.2.1', '192.0.2.22' ],
				's9k: the CGCONTRDP v4 resolvers survive in full');
			eq(settings?.ipv6, null, 's9k: no v6 surfaced');
			env.finish();
		});
	},
});

// s9l: GTDNS answering ERROR must not leave the settings without DNS — the
// chain falls back to the CGCONTRDP tail (s9g/s9h pin the win + empty cases)
push(scenarios, {
	name: 's9l_fibocom_gt_dns_error',
	script: fscript([
		{ re: /^AT\+GTDNS/, lines: [], term: 'ERROR' },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	datapath: { netdev: 'wwand0', fx: s9a_fx },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 's9l: context up succeeds');
			eq(settings?.ipv4?.dns, [ '192.0.2.1', '192.0.2.22' ],
				's9l: GTDNS ERROR -> both CGCONTRDP v4 resolvers');
			env.finish();
		});
	},
});

// s9m: an embedded-v4 token inside the GTDNS reply is never a resolver —
// it must be skipped, not decoded into a garbage v6
push(scenarios, {
	name: 's9m_fibocom_gt_dns_ev4_skip',
	script: fscript([
		{ re: /^AT\+GTDNS/, lines: [
			'+GTDNS: 1,"0.0.0.0.0.0.0.0.0.1.0.0.192.0.2.1","2001:4860:4860::8888"',
		] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	datapath: { netdev: 'wwand0', fx: s9a_fx },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 's9m: context up succeeds');
			eq(settings?.ipv6?.dns, [ '2001:4860:4860::8888' ],
				's9m: embedded-v4 GTDNS token skipped, real v6 resolver kept');
			eq(settings?.ipv4?.dns, [ '192.0.2.1', '192.0.2.22' ],
				's9m: GTDNS carried no v4 resolver -> the CGCONTRDP v4 pair stands');
			env.finish();
		});
	},
});

// s9n: option sim_slot on a modem whose vendor HAS an AT slots recipe
// (Fibocom AT+GTDUALSIM) is now SUPPORTED — no config warning, and the
// already-active configured slot short-circuits without a switch
push(scenarios, {
	name: 's9n_fibocom_sim_slot',
	script: fscript([
		{ re: /^AT\+GTDUALSIM\?$/, lines: [ '+GTDUALSIM : 1, "SUB2", "NR"' ] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	mconfig: { apn: 'internet', sim_slot: 2 },
	run: (env) => {
		let m = env.modem;

		ok(m.state == 'READY', 's9n: modem READY with the configured slot active');
		ok(env.tr.saw(/^AT\+GTDUALSIM=/) == null, 's9n: no switch sent (slot already active)');
		ok(!filter(m.config_warnings ?? [], (w) => w.check == 'sim_slot')[0],
			's9n: no sim_slot warning (the vendor AT slots recipe supports it)');
		env.finish();
	},
});

// s9o: the same option on a modem with NO vendor slots recipe keeps the
// warning (the identify-time gate) — the active slot stays untouched
push(scenarios, {
	name: 's9o_generic_sim_slot_warning',
	script: script([
		{ re: /^AT\+CGMI$/, lines: [ 'Unknown Vendor Inc.' ] },
	]),
	mconfig: { sim_slot: 2 },
	run: (env) => {
		let w = filter(env.modem.config_warnings ?? [], (x) => x.check == 'sim_slot')[0];

		ok(w != null, 's9o: sim_slot warning raised without a vendor slot recipe');
		eq(w?.expected, 'slot 2', 's9o: warning carries the configured slot');
		ok(env.tr.saw(/^AT\+GTDUALSIM/) == null, 's9o: no slot command attempted');
		env.finish();
	},
});

// s9p: ipv6-only PDP whose CGCONTRDP carries the DNS64 pair in the ADDR+SUBNET
// slots (field-seen right after a PDP-type change — the modem's other form
// beside the empty-local one). The pair must NEVER become a v6 assignment:
// host v6 arrives via the modem's RA/SLAAC — the pair rides in dns instead
// (the DNS-only ipv6 bucket), which the shim pushes without an address.
push(scenarios, {
	name: 's9p_fibocom_ipv6_pair_in_addr_slots',
	script: fscript([
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,6,"internet","36.4.216.0.0.240.0.0.0.0.0.0.0.83.0.16","36.4.216.0.0.240.0.0.0.0.0.0.0.83.0.34","","",0,,0',
		] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv6' },
	datapath: { netdev: 'wwand0', fx: s9a_fx },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 's9p: context up succeeds');
			eq(settings?.ipv4, null, 's9p: no host v4 on the ipv6-only PDP');
			eq(settings?.ipv6?.addr, null, 's9p: the pair never becomes a v6 address (host v6 = RA)');
			eq(settings?.ipv6?.gateway, null, 's9p: no v6 gateway from the pair');
			eq(settings?.ipv6?.dns, [ '2404:d800:f0:0:0:0:53:10', '2404:d800:f0:0:0:0:53:22' ],
				's9p: the DNS64 pair rides in dns (the DNS-only bucket)');
			env.finish();
		});
	},
});

// s9w: THE live WH3000 Pro / FM350-GL capture on Singtel, verbatim. Both
// CGCONTRDP lines carry empty local+gateway slots and nothing but resolvers;
// CGPADDR's v6 slot is the network-assigned interface identifier with a zeroed
// prefix (host v6 = RA/SLAAC). Before the slot-aware parse this produced
// ipv4.addr = 165.21.83.88 — a Singtel DNS server installed as the WAN address
// (mwan3 "no usable default route", odhcpd ra_lifetime 0) — and on the v6 side
// 2400:d800::1 pushed as a /128 whose /64 then landed on br-lan via RFC 7278.
push(scenarios, {
	name: 's9w_fibocom_live_singtel_capture',
	script: fscript([
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,6,"internet.MNC001.MCC525.GPRS","","","165.21.100.88","165.21.83.88","","",0,,1280,,,,,,,,,,,,0',
			'+CGCONTRDP: 1,6,"internet.MNC001.MCC525.GPRS","","","36.0.216.0.0.0.0.0.0.0.0.0.0.0.0.1","36.0.216.0.0.0.0.0.0.0.0.0.0.0.0.2","","",0,,1280,,,,,,,,,,,,0',
		] },
		{ re: /^AT\+CGPADDR=1$/, lines: [
			'+CGPADDR: 1,"172.24.225.36","0.0.0.0.0.0.0.0.70.130.89.86.198.214.226.197"',
		] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4v6' },
	datapath: { netdev: 'wwand0', fx: s9a_fx },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 's9w: context up succeeds');

			eq(settings?.ipv4?.addr, '172.24.225.36', 's9w: v4 address from CGPADDR');
			ok(settings?.ipv4?.addr != '165.21.100.88' && settings?.ipv4?.addr != '165.21.83.88',
				's9w: no DNS server was promoted to the v4 address');
			eq(settings?.ipv4?.dns, [ '165.21.100.88', '165.21.83.88' ],
				's9w: both v4 resolvers, in the v4 bucket');

			// host v6 is RA/SLAAC only: no address, no gateway, resolvers kept
			eq(settings?.ipv6?.addr, null, 's9w: no v6 address invented from a resolver');
			eq(settings?.ipv6?.gateway, null, 's9w: no v6 gateway invented');
			ok(settings?.ipv6?.unmanaged, 's9w: v6 marked unmanaged (host v6 = RA/SLAAC)');
			eq(settings?.ipv6?.dns, [ '2400:d800:0:0:0:0:0:1', '2400:d800:0:0:0:0:0:2' ],
				's9w: v6 resolvers in the v6 bucket, not mixed into ipv4.dns');

			env.finish();
		});
	},
});

// s9q: ipv4 PDP with the pair-in-addr-slots form (field-seen right after a
// PDP-type change — the modem settles on the empty-local form a minute
// later): the CGCONTRDP v4 tokens are gateway+DNS, the ADDRESS comes over
// AT (CGPADDR). The gw token must never become the address.
push(scenarios, {
	name: 's9q_fibocom_ipv4_pair_in_addr_slots',
	script: fscript([
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,6,"internet","192.0.2.1","192.0.2.22","","",0,,0',
		] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4' },
	datapath: { netdev: 'wwand0', fx: s9a_fx },
	run: (env) => {
		env.ctx.up((err, settings) => {
			eq(err, null, 's9q: context up succeeds');
			eq(settings?.ipv4?.addr, '192.0.2.190',
				's9q: address from CGPADDR (the gw token never becomes the address)');
			eq(settings?.ipv4?.gateway, null, 's9q: gateway-less /32');
			eq(settings?.ipv4?.dns, [ '192.0.2.22' ], 's9q: the pair tail rides in dns');
			env.finish();
		});
	},
});

// s9r: URCs interleaved into the identify answers (the modem emits
// +CGEV/+ESIMS/+CIREPI/+CNEMIU/+CTZV bursts right after a reset — HW-seen):
// every identify value must still land on its own command, or the vendor
// resolves to generic (generic telemetry + generic ip_config, no cells)
push(scenarios, {
	name: 's9r_fibocom_noisy_identify',
	script: fscript([
		{ re: /^AT\+CGMI$/,  lines: [ 'Fibocom Wireless Inc.' ], urcs: [ '+CGEV: ME PDN DEACT 1' ] },
		{ re: /^AT\+CGMM$/,  lines: [ 'FM350-GL' ],               urcs: [ '+ESIMS: 0,0' ] },
		{ re: /^AT\+CGSN$/,  lines: [ '350000000000000' ],       urcs: [ '+CIREPI: 0' ] },
		{ re: /^AT\+CIMI$/,  lines: [ '001010123456789' ],       urcs: [ '+CNEMIU: 0' ] },
		{ re: /^AT\+ICCID$/, lines: [ '+ICCID: 89000000000000000000' ], urcs: [ '+CTZV: "+32,0"' ] },
	]),
	cconfig: { apn: 'internet', pdp_type: 'ipv4' },
	run: (env) => {
		let m = env.modem;

		eq(m.info.manufacturer, 'Fibocom Wireless Inc.', 's9r: manuf correct despite interleaved URCs');
		eq(m.info.model, 'FM350-GL', 's9r: model correct');
		eq(m.info.imsi, '001010123456789', 's9r: imsi correct');
		eq(m.info.iccid, '89000000000000000000', 's9r: iccid correct');
		eq(m.fcc_lock, 0, 's9r: fibocom vendor resolved (fcc probe ran)');
		ok(env.tr.saw(/^AT\+CESQ$/) == null,
			's9r: fibocom telemetry block (no generic CESQ)');
		env.finish();
	},
});

// --- s9 units: peer-gateway rule + CGPADDR/empty-local parsers ----------------

let cgp = ncm_vendors.parse_cgpaddr([ '+CGPADDR: 1,"192.0.2.190",""' ]);

eq(cgp?.addr, '192.0.2.190', 'parse_cgpaddr: v4 addr (quoted)');
eq(cgp?.v6, null, 'parse_cgpaddr: empty v6 -> null');

let cgp2 = ncm_vendors.parse_cgpaddr([ '+CGPADDR: 1,"192.0.2.190","2001:db8::1"' ]);

eq(cgp2?.addr, '192.0.2.190', 'parse_cgpaddr: v4 addr (with v6)');
eq(cgp2?.v6, '2001:db8::1', 'parse_cgpaddr: v6 addr');

let cgp3 = ncm_vendors.parse_cgpaddr([ '+CGPADDR: 1,192.0.2.190,' ]);

eq(cgp3?.addr, '192.0.2.190', 'parse_cgpaddr: bare (unquoted) form');

// single-slot CGPADDR (v4-only PDP, 3GPP 27.007): the second slot is optional
let cgp5 = ncm_vendors.parse_cgpaddr([ '+CGPADDR: 1,"192.0.2.190"' ]);

eq(cgp5?.addr, '192.0.2.190', 'parse_cgpaddr: single-slot v4');
eq(cgp5?.v6, null, 'parse_cgpaddr: single-slot has no v6');

// parse_eslotsinfo: every per-slot field, both slot kinds, absent forms
let es = ncm_vendors.parse_eslotsinfo([ '+ESLOTSINFO: 2, "+CPIN: READY", "1", "0", "3B00000000000000", "", "89000000000000000000", "+CPIN: EMPTY_EUICC", "1", "1", "3B9F00000000000000000000", "89000000000000000000000000000000", ""' ]);

eq(es[0].cpin, '+CPIN: READY', 'eslotsinfo: slot1 cpin');
eq(es[0].present, true, 'eslotsinfo: slot1 present');
eq(es[0].kind, 'usim', 'eslotsinfo: slot1 kind usim');
eq(es[0].atr, '3B00000000000000', 'eslotsinfo: slot1 atr');
eq(es[0].eid, null, 'eslotsinfo: usim slot has no eid');
eq(es[0].iccid, '89000000000000000000', 'eslotsinfo: slot1 iccid');
eq(es[1].kind, 'euicc', 'eslotsinfo: slot2 kind euicc');
eq(es[1].atr, '3B9F00000000000000000000', 'eslotsinfo: slot2 atr');
eq(es[1].iccid, null, 'eslotsinfo: empty iccid -> null');

let es2 = ncm_vendors.parse_eslotsinfo([ '+ESLOTSINFO: 1, "", "0", "1", "", "", ""' ]);

eq(es2[0].present, false, 'eslotsinfo: present 0');
eq(es2[0].cpin, null, 'eslotsinfo: empty cpin -> null');
eq(ncm_vendors.parse_eslotsinfo([ 'OK' ]), null, 'eslotsinfo: no line -> null');

// T700 pdp-ipv6 form: the v4 slot carries <0×8, 0,1, 0,0><embedded v4> — the
// network serves IPv4 even on the ipv6 PDP (field-verified: 13/14.x pool (anonymized), the
// extracted address pinged 3/3)
let cgp4 = ncm_vendors.parse_cgpaddr([ '+CGPADDR: 1,"0.0.0.0.0.0.0.0.0.1.0.0.192.0.2.48",""' ]);

eq(cgp4?.addr, '192.0.2.48', 'parse_cgpaddr: embedded v4 extracted from the dotted token');
eq(cgp4?.v6, null, 'parse_cgpaddr: no v6 in the embedded form');

// the empty-local form: fields 3 (<local_addr and subnet_mask>) and 4 (<gw_addr>)
// are EMPTY and the only tokens are the resolvers. The parser must return NO
// address — the misread it used to produce here (first DNS promoted to the
// address) put a carrier resolver on the WAN and, via RFC 7278, its /64 on the
// LAN. Field-seen on a WH3000 Pro / FM350-GL, on both families.
let empty_rdp = modem_ncm.parse_cgcontrdp([
	'+CGCONTRDP: 1,5,"internet","","","192.0.2.1","192.0.2.22"',
]);

eq(empty_rdp.ipv4?.addr, null, 'empty-local CGCONTRDP: empty address slot -> NO address');
eq(empty_rdp.ipv4?.gateway, null, 'empty-local CGCONTRDP: no gateway slot');
eq(empty_rdp.ipv4?.dns, [ '192.0.2.1', '192.0.2.22' ], 'empty-local CGCONTRDP: BOTH resolvers kept as dns');

// the same shape on the v6 line — the live WH3000 capture. 2400:d800::1/::2 are
// Singtel's resolvers; one of them was being pushed as the host address.
let empty_rdp6 = modem_ncm.parse_cgcontrdp([
	'+CGCONTRDP: 1,6,"internet","","","36.0.216.0.0.0.0.0.0.0.0.0.0.0.0.1","36.0.216.0.0.0.0.0.0.0.0.0.0.0.0.2"',
]);

eq(empty_rdp6.ipv6?.addr, null, 'empty-local CGCONTRDP v6: no address from a DNS slot');
eq(empty_rdp6.ipv6?.gateway, null, 'empty-local CGCONTRDP v6: no gateway invented');
eq(empty_rdp6.ipv6?.dns, [ '2400:d800:0:0:0:0:0:1', '2400:d800:0:0:0:0:0:2' ],
	'empty-local CGCONTRDP v6: both resolvers kept as dns');

// embedded-v4 on the CGCONTRDP path (the v6-only PDP): the 16-octet token
// must extract the real v4 — and never corrupt the v6 bucket even when its
// line precedes the real v6 tokens (first token wins there)
let ev4 = ncm_vendors.parse_cgcontrdp([
	'+CGCONTRDP: 1,5,"apn","0.0.0.0.0.0.0.0.0.1.0.0.192.0.2.190","32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136.255.255.255.255.255.255.255.255.0.0.0.0.0.0.0.0","32.1.72.96.0.0.0.0.0.0.0.0.0.0.0.1"',
]);

eq(ev4.ipv4?.addr, '192.0.2.190', 'CGCONTRDP: embedded-v4 extracted');
eq(ev4.ipv4?.prefix, null, 'CGCONTRDP: embedded-v4 /32 (no mask token)');
eq(ev4.ipv6?.addr, '2001:4860:4860:0:0:0:0:8888', 'CGCONTRDP: v6 untouched by the embedded token');
eq(ev4.ipv6?.gateway, '2001:4860:0:0:0:0:0:1', 'CGCONTRDP: v6 gateway intact');

// +CTZV NITZ frame (Fibocom T700 format): yy/MM/dd,hh:mm:ss±quarter-hours
let tzv = modem_common.nitz_ctzv('+CTZV: "26/08/19,14:00:00+32"');

eq(tzv?.tz_offset_min, 480, 'nitz_ctzv: +32 quarter-hours = +480 min');
eq(tzv?.epoch, timegm({ year: 2026, mon: 8, mday: 19, hour: 14, min: 0, sec: 0 }),
	'nitz_ctzv: epoch from the frame');
eq(modem_common.nitz_ctzv('+CTZV: "00/00/00,00:00:00+0"'), null, 'nitz_ctzv: zeroed frame -> null');
eq(modem_common.nitz_ctzv('garbage'), null, 'nitz_ctzv: junk -> null');

// --- direct unit test: parse_cgcontrdp on the exact RG650E-EU line ----------

let rdp = modem_ncm.parse_cgcontrdp([
	'+CGCONTRDP: 1,5,"internet","192.0.2.229","32.1.13.184.0.0.0.0.0.0.0.0.0.0.0.1", "254.128.0.0.0.0.0.0.0.0.0.0.0.0.0.1","192.0.2.53" "32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136","192.0.2.54" "32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.68"',
]);
eq(rdp.ipv4?.addr, '192.0.2.229', 'parse_cgcontrdp: v4 addr');
eq(rdp.ipv4?.gateway, null, 'parse_cgcontrdp: no v4 gateway (unmasked local)');
eq(rdp.ipv4?.dns, [ '192.0.2.53', '192.0.2.54' ], 'parse_cgcontrdp: both v4 DNS');
eq(rdp.ipv6?.addr, '2001:db8:0:0:0:0:0:1', 'parse_cgcontrdp: v6 addr from 16-octet field');
eq(rdp.ipv6?.gateway, 'fe80:0:0:0:0:0:0:1', 'parse_cgcontrdp: v6 gateway (link-local)');
eq(rdp.ipv6?.dns, [ '2001:4860:4860:0:0:0:0:8888', '2001:4860:4860:0:0:0:0:8844' ], 'parse_cgcontrdp: both v6 DNS');

// standard single-stack-per-line style still parses (masked v4 -> gateway present)
let rdp2 = modem_ncm.parse_cgcontrdp([
	'+CGCONTRDP: 1,5,internet,10.20.30.40.255.255.255.0,10.20.30.1,8.8.8.8,8.8.4.4',
]);
eq(rdp2.ipv4?.addr, '10.20.30.40', 'parse_cgcontrdp: standard v4 addr');
eq(rdp2.ipv4?.gateway, '10.20.30.1', 'parse_cgcontrdp: standard v4 gateway (masked local)');
eq(rdp2.ipv4?.dns, [ '8.8.8.8', '8.8.4.4' ], 'parse_cgcontrdp: standard v4 DNS');

// --- QModem-study additions: 5G-SA registration + vendor dial/auth verbs ----

// C5GREG registration (5G-SA modems read not-registered on CEREG)
eq(modem_ncm.parse_creg([ '+C5GREG: 2,1' ])?.registered, true, 'parse_creg: +C5GREG registered (home)');
eq(modem_ncm.parse_creg([ '+C5GREG: 2,5' ])?.roaming, true, 'parse_creg: +C5GREG roaming');
eq(modem_ncm.parse_creg([ '+C5GREG: 2,0' ])?.registered, false, 'parse_creg: +C5GREG not registered');
eq(modem_ncm.parse_creg([ '+CEREG: 2,1' ])?.registered, true, 'parse_creg: +CEREG still parses');
eq(modem_ncm.parse_creg([ '+CREG: 2,5' ])?.roaming, true, 'parse_creg: +CREG still parses');

// 27.007 <stat> beyond 0-5. Field-observed on a MeiG SLM770A (2026-08-23): every
// registration cycle passes through stat 11 — in the same second as its
// ^SRVST: 1 (limited service) — before settling on 5. Both +CREG and +CEREG
// report it simultaneously, which is what rules out a merged-line artefact.
eq(modem_ncm.parse_creg([ '+CEREG: 11,"88ce","00c52a16",7' ])?.stat, 11,
	'parse_creg: URC form with tac/ci reads stat 11, not the <n> of a query');
eq(modem_ncm.parse_creg([ '+CEREG: 11,"88ce","00c52a16",7' ])?.registered, false,
	'parse_creg: RLOS (11) is attached but NOT usable for data');
eq(modem_ncm.parse_creg([ '+CEREG: 11' ])?.restricted, true,
	'parse_creg: RLOS (11) is reported as a restricted attach');

// CSFB-not-preferred is a FULL data registration — the old stat==1||stat==5
// test left modems polling forever on networks that signal 9/10
eq(modem_ncm.parse_creg([ '+CEREG: 9' ])?.registered, true,
	'parse_creg: CSFB-not-preferred home (9) counts as registered');
eq(modem_ncm.parse_creg([ '+CEREG: 10' ])?.registered, true,
	'parse_creg: CSFB-not-preferred roaming (10) counts as registered');
eq(modem_ncm.parse_creg([ '+CEREG: 10' ])?.roaming, true,
	'parse_creg: stat 10 is a roaming registration');

// SMS-only and emergency-only are attachments no PDP context can live on
eq(modem_ncm.parse_creg([ '+CREG: 7,"88ce","00c52a16",7' ])?.registered, false,
	'parse_creg: SMS-only roaming (7) is not usable for data');
eq(modem_ncm.parse_creg([ '+CREG: 7' ])?.roaming, true,
	'parse_creg: stat 7 still reports roaming');
eq(modem_ncm.parse_creg([ '+CEREG: 8' ])?.registered, false,
	'parse_creg: emergency-only (8) is not usable for data');

// the query form keeps winning over the URC form: <n>,<stat>
eq(modem_ncm.parse_creg([ '+CEREG: 2,3' ])?.stat, 3,
	'parse_creg: query form still reads <stat>, not <n>');
ok(index(modem_ncm.parse_creg([ '+CEREG: 2,3' ])?.why ?? '', 'denied') >= 0,
	'parse_creg: a denial carries a human-readable reason for the log');

// Fibocom auth is a best-effort chain: +MGAUTH (the Qualcomm FM150/FM350
// form) first, +CGAUTH as the fallback for the MediaTek T700 (FM350-GL)
let fb_auth = modem_ncm.vendor_for('Fibocom Wireless').auth_cmds(1, 3, 'web',
	{ username: 'u', password: 'p' });

eq(length(fb_auth), 2, 'fibocom auth chain has two candidates');
ok(match(fb_auth[0], /^AT\+MGAUTH=1,[0-9]+,"u","p"$/) != null,
	'fibocom auth chain: +MGAUTH first');
ok(match(fb_auth[1], /^AT\+CGAUTH=1,[0-9]+,"u","p"$/) != null,
	'fibocom auth chain: +CGAUTH fallback');
eq(modem_ncm.vendor_for('Fibocom Wireless').auth_cmds(1, 3, 'web', {}), [],
	'fibocom auth chain: no credentials -> no auth commands');

let fb_setup = modem_ncm.build_pdp_setup(modem_ncm.vendor_for('Fibocom Wireless'), 1,
	{ apn: 'web', username: 'u', password: 'p' });

ok(index(fb_setup, 'AT+CGDCONT=1,"IPV4V6","web"') == 0, 'fibocom setup: CGDCONT first');
ok(length(filter(fb_setup, (c) => match(c, /^AT\+MGAUTH=/) != null)) == 1
	&& length(filter(fb_setup, (c) => match(c, /^AT\+CGAUTH=/) != null)) == 1,
	'fibocom setup: both auth candidates in the sequence');

// new vendor dial verbs
eq(modem_ncm.vendor_for('gosuncn').dials[0].connect(2), 'AT+ZECMCALL=1', 'gosuncn dial = +ZECMCALL');
eq(modem_ncm.vendor_for('neoway').dials[0].connect(2), 'AT$MYUSBNETACT=0,1', 'neoway dial = $MYUSBNETACT');
eq(modem_ncm.vendor_for('telit').dials[1].connect(3), 'AT#ICMAUTOCONN=1,3', 'telit fallback dial = #ICMAUTOCONN');
eq(modem_ncm.vendor_for('meig').dials[1].connect(4), 'AT$QCRMCALL=1,0,3,2,4', 'meig fallback dial = 5-arg $QCRMCALL');

// P2 correctness fixes: internal-dialer disable + Sierra AT! unlock at init
ok(index(modem_ncm.vendor_for('Huawei Technologies').modem_init, 'AT^SETAUTODIAL=0') >= 0,
	'huawei init disables the internal auto-dialer (SETAUTODIAL=0)');
ok(index(modem_ncm.vendor_for('Sierra Wireless, Incorporated').modem_init, 'AT!ENTERCND="A710"') >= 0,
	'sierra init unlocks AT! via ENTERCND before any AT! config');

// generic-variant audit: the standard 3GPP context (CGDCONT) is ALWAYS defined,
// even for vendors whose context define is proprietary (ZTE/MikroTik ZGDCONT),
// so the generic AT+CGACT dial fallback has a valid context to activate
let zte_setup = modem_ncm.build_pdp_setup(modem_ncm.vendor_for('ZTE Corporation'), 1,
	{ apn: 'web', pdp_type: 'ipv4v6' });
ok(index(zte_setup, 'AT+CGDCONT=1,"IPV4V6","web"') >= 0, 'zte: generic CGDCONT co-set (not only ZGDCONT)');
ok(length(filter(zte_setup, (c) => match(c, /^AT\+ZGDCONT=/) != null)) == 1, 'zte: vendor ZGDCONT still layered on top');
// a vendor without a custom define emits CGDCONT exactly once
let q_setup = modem_ncm.build_pdp_setup(modem_ncm.vendor_for('Quectel'), 1, { apn: 'web' });
eq(length(filter(q_setup, (c) => match(c, /^AT\+CGDCONT=/) != null)), 1, 'quectel: single generic CGDCONT');

run_next();
uloop.run();

done('test_ncm');
