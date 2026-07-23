// wwand tests — usbnet mode-switch engine (modeswitch.uc).
//
// Drives modeswitch.attempt() against a scripted AT tty (same fake-transport
// approach as test_ncm): identify (CGMI/CGMM) -> recipe -> optional idempotency
// query -> set + reset. Covers: a Quectel in ECM mode switched to QMI, a
// Quectel already in QMI mode (idempotent, no reset), and an unknown modem
// (generic no-op).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as modeswitch from 'wwand/modeswitch.uc';

uloop.init();

// scripted AT transport: handlers [ { re, lines?, term? } ], first match wins
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

let scenarios = [];
let current = 0;

function run_next()
{
	if (current >= length(scenarios))
		return uloop.end();

	let s = scenarios[current++];
	let tr = at_mock(s.script);

	modeswitch.attempt({
		tty: '/dev/ttyUSB2',
		log: () => null,
		open_transport: () => tr,
	}, (err, res) => {
		s.check(err, res, tr);
		uloop.timer(1, run_next);
	});
}

// --- Quectel in ECM mode (usbnet=1) -> switch to QMI (usbnet=0) --------------

push(scenarios, {
	name: 'quectel_ecm_to_qmi',
	script: [
		{ re: /^AT\+CGMI$/, lines: [ 'Quectel' ] },
		{ re: /^AT\+CGMM$/, lines: [ 'RG650E-EU' ] },
		{ re: /^AT\+QCFG="usbnet"$/, lines: [ '+QCFG: "usbnet",1' ] },   // ECM now
		{ re: /^AT\+QCFG="usbnet",0$/, lines: [] },
		{ re: /^AT\+CFUN=1,1$/, lines: [] },
	],
	check: (err, res, tr) => {
		eq(err, null, 'quectel: no error');
		eq(res?.switched, true, 'quectel ECM->QMI: switched');
		eq(res?.target, 'qmi', 'quectel: target qmi');
		ok(tr.saw(/^AT\+QCFG="usbnet",0$/) != null, 'quectel: usbnet set to 0');
		ok(tr.saw(/^AT\+CFUN=1,1$/) != null, 'quectel: reset issued');
	},
});

// --- Quectel already in QMI mode (usbnet=0) -> idempotent no-op --------------

push(scenarios, {
	name: 'quectel_already_qmi',
	script: [
		{ re: /^AT\+CGMI$/, lines: [ 'Quectel' ] },
		{ re: /^AT\+CGMM$/, lines: [ 'RG502Q-EA' ] },
		{ re: /^AT\+QCFG="usbnet"$/, lines: [ '+QCFG: "usbnet",0' ] },   // already QMI
	],
	check: (err, res, tr) => {
		eq(res?.switched, false, 'quectel already qmi: not switched');
		eq(tr.saw(/^AT\+CFUN=1,1$/), null, 'idempotent: no reset when already in wanted mode');
	},
});

// --- unknown modem -> generic no-op -----------------------------------------

push(scenarios, {
	name: 'unknown_noop',
	script: [
		{ re: /^AT\+CGMI$/, lines: [ 'Acme Networks' ] },
		{ re: /^AT\+CGMM$/, lines: [ 'ZZ9000' ] },
	],
	check: (err, res) => {
		eq(err, null, 'unknown: no error');
		eq(res?.switched, false, 'unknown modem: no recipe -> no-op');
	},
});

run_next();
uloop.run();

done('test_modeswitch');
