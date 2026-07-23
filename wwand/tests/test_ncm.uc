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
import * as modem_ncm from 'wwand/modem_ncm.uc';
import * as context_ncm from 'wwand/context_ncm.uc';

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
		let term = h?.term ?? 'OK';

		uloop.timer(0, () => {
			if (self.closed || !self.data_cb)
				return;

			let out = '';

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
		timing: { settle: 1, reg_timeout: 500, reg_poll: 5, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { open_transport: () => tr },   // inject the scripted tty
		deps: {
			log: () => null,
			on_event: (m, event, data) => {
				push(mevents, { event: event, data: data });

				if (event == 'registered' && !ctx) {
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
}

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
		{ re: /^AT\+ECMDUP=1,1$/, lines: [ '^DCONN: 1,1,"IPV4"' ] },
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
		ok(m.dial.connect(1) == 'AT+ECMDUP=1,1', 'meig ECMDUP dial selected from CGMI');

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

			ok(env.tr.saw(/^AT\+ECMDUP=1,1$/) != null, 'ECMDUP connect issued');

			env.ctx.down(() => {
				ok(env.tr.saw(/^AT\+ECMDUP=1,0$/) != null, 'ECMDUP disconnect issued');
				env.finish();
			});
		});
	},
});

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
		// the verbatim RG650E dual-stack line (mixed comma/space, mixed widths)
		{ re: /^AT\+CGCONTRDP/, lines: [
			'+CGCONTRDP: 1,5,"web.vodafone.de","100.71.169.229","42.0.0.32.66.143.62.233.146.68.145.209.245.33.214.219", "254.128.0.0.0.0.0.0.0.0.0.0.0.0.0.1","139.7.30.125" "42.1.8.96.0.0.3.0.0.0.0.0.0.0.0.83","139.7.30.126" "42.1.8.96.0.0.3.0.0.0.0.0.0.0.1.83"',
		] },
		{ re: /^AT\+CGACT=1,/, lines: [] },
		{ re: /^AT\+CGACT=0,/, lines: [] },
		{ re: /^AT\+CGACT\?$/, lines: [ '+CGACT: 1,1' ] },
		{ re: /^AT\+CSQ$/,    lines: [ '+CSQ: 20,99' ] },
		{ re: /^AT\+QENG=/,   lines: [] },
	],
	cconfig: { apn: 'web.vodafone.de', pdp_type: 'ipv4v6', mux_id: 0 },
	run: (env) => {
		let m = env.modem;

		eq(m.dial.name, 'cgact', 'RG650E: QNETDEVCTL probe ERROR -> CGACT dial resolved');

		env.ctx.up((err, settings) => {
			eq(err, null, 'RG650E context up succeeds via CGACT');
			ok(env.tr.saw(/^AT\+CGACT=1,1$/) != null, 'CGACT connect issued');

			// dual-stack decode from the real RG650E CGCONTRDP line
			eq(settings?.ipv4?.addr, '100.71.169.229', 'RG650E ipv4 addr (bare 4-octet local)');
			eq(settings?.ipv4?.prefix, 32, 'RG650E ipv4 forced /32');
			eq(settings?.ipv4?.dns, [ '139.7.30.125', '139.7.30.126' ], 'RG650E both v4 DNS');
			eq(settings?.ipv6?.addr, '2a00:20:428f:3ee9:9244:91d1:f521:d6db', 'RG650E ipv6 addr (16-octet field)');
			eq(settings?.ipv6?.dns, [ '2a01:860:0:300:0:0:0:53', '2a01:860:0:300:0:0:0:153' ], 'RG650E both v6 DNS');

			env.ctx.down(() => {
				ok(env.tr.saw(/^AT\+CGACT=0,1$/) != null, 'CGACT disconnect issued');
				env.finish();
			});
		});
	},
});

// --- direct unit test: parse_cgcontrdp on the exact RG650E-EU line ----------

let rdp = modem_ncm.parse_cgcontrdp([
	'+CGCONTRDP: 1,5,"web.vodafone.de","100.71.169.229","42.0.0.32.66.143.62.233.146.68.145.209.245.33.214.219", "254.128.0.0.0.0.0.0.0.0.0.0.0.0.0.1","139.7.30.125" "42.1.8.96.0.0.3.0.0.0.0.0.0.0.0.83","139.7.30.126" "42.1.8.96.0.0.3.0.0.0.0.0.0.0.1.83"',
]);
eq(rdp.ipv4?.addr, '100.71.169.229', 'parse_cgcontrdp: v4 addr');
eq(rdp.ipv4?.gateway, null, 'parse_cgcontrdp: no v4 gateway (unmasked local)');
eq(rdp.ipv4?.dns, [ '139.7.30.125', '139.7.30.126' ], 'parse_cgcontrdp: both v4 DNS');
eq(rdp.ipv6?.addr, '2a00:20:428f:3ee9:9244:91d1:f521:d6db', 'parse_cgcontrdp: v6 addr from 16-octet field');
eq(rdp.ipv6?.gateway, 'fe80:0:0:0:0:0:0:1', 'parse_cgcontrdp: v6 gateway (link-local)');
eq(rdp.ipv6?.dns, [ '2a01:860:0:300:0:0:0:53', '2a01:860:0:300:0:0:0:153' ], 'parse_cgcontrdp: both v6 DNS');

// standard single-stack-per-line style still parses (masked v4 -> gateway present)
let rdp2 = modem_ncm.parse_cgcontrdp([
	'+CGCONTRDP: 1,5,internet,10.20.30.40.255.255.255.0,10.20.30.1,8.8.8.8,8.8.4.4',
]);
eq(rdp2.ipv4?.addr, '10.20.30.40', 'parse_cgcontrdp: standard v4 addr');
eq(rdp2.ipv4?.gateway, '10.20.30.1', 'parse_cgcontrdp: standard v4 gateway (masked local)');
eq(rdp2.ipv4?.dns, [ '8.8.8.8', '8.8.4.4' ], 'parse_cgcontrdp: standard v4 DNS');

run_next();
uloop.run();

done('test_ncm');
