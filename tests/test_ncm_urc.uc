// wwand tests — modem_ncm at_on_urc wiring (register fast path, the _esim_op
// quiet mode, NITZ) on a DIRECT modem instance with a slow register poll, so
// a URC-triggered immediate re-poll is distinguishable from the timer's.
//
// The scenario runner in test_ncm.uc drives the same state machine but with a
// 5 ms reg_poll (URCs and timer fire back-to-back, the fast path is invisible
// there) — hence this standalone suite.

'use strict';

import * as uloop from 'uloop';
import { eq, ok, done } from './lib/check.uc';
import * as modem_ncm from 'wwand.modem_ncm';

// --- scripted AT transport (same shape as test_ncm's at_mock) -----------------

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
	self.count = (re) => length(filter(self.written, (c) => match(c, re)));
	return self;
}

// fibocom identity + attach/register handlers. The register handlers answer
// not-registered until the URC fast-path test flips them (the lines array is
// re-read per write, so mutating it works) — the reg_poll is 60 s, so any poll
// beyond the first must come from a URC
let creg_h  = { re: /^AT\+CEREG\?$/,  lines: [ '+CEREG: 2,0' ] };
let c5g_h   = { re: /^AT\+C5GREG\?$/, lines: [ '+C5GREG: 2,0' ] };
let cg_h    = { re: /^AT\+CREG\?$/,   lines: [ '+CREG: 2,0' ] };

function register_handlers()
{
	return [
		{ re: /^AT\+CGMI$/, lines: [ 'Fibocom Wireless Inc.' ] },
		{ re: /^AT\+CGMM$/, lines: [ 'FM350-GL' ] },
		{ re: /^AT\+CGMR$/, lines: [ 'FM350GL_04.02.10' ] },
		{ re: /^AT\+CGSN$/, lines: [ '350000000000000' ] },
		{ re: /^AT\+GTFCCEFFSTATUS\?$/, lines: [ '+GTFCCEFFSTATUS: 0' ] },
		{ re: /^AT\+SIMTYPE\?$/, lines: [ '+SIMTYPE: 0' ] },
		{ re: /^AT\+ESLOTSINFO/, lines: [ '+ESLOTSINFO: 1, "+CPIN: READY", "1", "0", "3B00000000000000", "", "89000000000000000000"' ] },
		{ re: /^AT\+EID$/, lines: [ '+EID: 89000000000000000000000000000000' ] },
		{ re: /^AT\+CIMI$/, lines: [ '001010123456789' ] },
		{ re: /^AT\+QCCID$/, term: 'ERROR', lines: [] },
		{ re: /^AT\+ICCID$/, lines: [ '+ICCID: 89000000000000000000' ] },
		{ re: /^AT\+CPIN\?$/, lines: [ '+CPIN: READY' ] },
		creg_h, c5g_h, cg_h,
		{ re: /^AT\+GTDUALSIM\?$/, lines: [ '+GTDUALSIM : 0, "SUB1", "NR"' ] },
		{ re: /^AT\+GTRNDIS=\?$/, term: 'ERROR', lines: [] },
		{ re: /^AT\+CGDCONT\?$/, lines: [] },
		{ re: /^AT\+CSQ$/, lines: [ '+CSQ: 20,99' ] },
	];
}

function make_modem(tr, deps)
{
	return modem_ncm.create({
		id: 'urc', device: '/dev/cdc-wdm0',
		config: { tty: '/dev/ttyUSB2', zero_rx_timeout: 0 },
		timing: { settle: 1, reg_timeout: 2000, reg_poll: 60000, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { open_transport: () => tr },
		deps: { log: () => null, on_event: deps.on_event, set_clock: deps.set_clock },
	});
}

// --- 1: URC fast path + quiet mode + NITZ -------------------------------------

let events = [];
let clocks = [];
let tr = at_mock(register_handlers());
let m = make_modem(tr, {
	on_event: (mm, ev) => push(events, ev),
	set_clock: (e, t) => push(clocks, e),
});

m.start();

uloop.timer(50, () => {
	eq(m.state, 'REGISTERING', 'urc: REGISTERING before any URC');
	let n0 = tr.count(/^AT\+CEREG\?$/);
	eq(n0, 1, 'urc: exactly one poll so far (60 s timer has not fired)');

	// quiet mode: with _esim_op set the same URC must not trigger a re-poll
	m._esim_op = true;
	tr.data_cb('+CEREG: 2,1\r\n');
	uloop.timer(50, () => {
		eq(tr.count(/^AT\+CEREG\?$/), n0, 'urc: no re-poll while _esim_op (quiet mode)');
		eq(m.state, 'REGISTERING', 'urc: still REGISTERING (URC suppressed)');

		// lift the quiet flag: the URC fast path must re-poll immediately and
		// reach READY off the 60 s timer long before it would fire
		m._esim_op = false;
		creg_h.lines = [ '+CEREG: 2,1' ];
		c5g_h.lines  = [ '+C5GREG: 2,1' ];
		cg_h.lines   = [ '+CREG: 2,1' ];
		tr.data_cb('+CEREG: 2,1\r\n');
		uloop.timer(50, () => {
			ok(tr.count(/^AT\+CEREG\?$/) > n0, 'urc: URC triggered an immediate re-poll (fast path)');
			eq(m.state, 'READY', 'urc: registered via the URC fast path');

			// NITZ: the +CTZV frame feeds network_time + the shared clock path
			tr.data_cb('+CTZV: "26/08/19,14:00:00+32"\r\n');
			uloop.timer(20, () => {
				eq(m.network_time?.tz_offset_min, 480, 'urc: NITZ frame -> network_time tz');
				eq(length(clocks), 1, 'urc: set_clock dep invoked once');
				m.stop();
				uloop.timer(10, () => done('test_ncm_urc'));
			});
		});
	});
});

uloop.run();
