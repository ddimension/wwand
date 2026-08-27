// wwand tests — AT over MBIM (atcmd_mbim.uc).
//
// A PCIe/MHI modem often has no AT tty at all, but its MBIM channel is a
// separate node on the same wwan device and Quectel carries an AT pipe there
// (QDU service, CID 8). This suite pins the wire format and the adaptation
// from the engine's byte-stream view to that request/response pipe.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as struct from 'struct';
import * as atmbim from 'wwand/atcmd_mbim.uc';

// a fake MBIM client: records what was sent, answers from a canned table
function fake(answers, opts) {
	let self = { sent: [], opened: false, closed: false };

	self.client = {
		open: (cb) => {
			self.opened = true;
			cb(opts?.open_err ?? null);
		},
		command_raw: (uuid, cid, info, cb) => {
			let ctype = struct.unpack('<I', substr(info, 0, 4))[0];
			let cmd = substr(info, 4);

			push(self.sent, { uuid: uuid, cid: cid, ctype: ctype, cmd: cmd });

			if (opts?.cmd_err)
				return cb(opts.cmd_err, null);

			let a = answers[trim(cmd)];

			cb(null, struct.pack('<I', a != null ? 0 : 1) +
				(a ?? "\r\nERROR\r\n"));
		},
		close: (cb) => { self.closed = true; if (cb) cb(); },
	};

	self.hub = { close: () => { self.hub_closed = true; } };

	return self;
}

function open_with(f, cb, o) {
	atmbim.open('/dev/wwan0mbim0', {
		log: (l, m) => null,
		open_hub: (path, cbs) => { f.cbs = cbs; return o?.no_hub ? null : f.hub; },
		make_client: () => f.client,
	}, cb);
}

// --- the wire format ---------------------------------------------------------

let f = fake({ 'ATI': "ATI\r\r\nQuectel\r\nRM520N-GL\r\n\r\nOK\r\n" });
let got = null;

open_with(f, (tr) => {
	ok(tr != null, 'open: transport built once MBIM_OPEN succeeds');
	eq(f.opened, true, 'open: MBIM_OPEN was actually issued');

	tr.on_data((d) => got = d);
	tr.write("ATI\r");

	eq(length(f.sent), 1, 'wire: one command sent');
	eq(f.sent[0].uuid, '6427015f-579d-48f5-8c54-f43ed1e76f83', 'wire: QDU service uuid');
	eq(f.sent[0].cid, 8, 'wire: CID 8');
	eq(f.sent[0].ctype, 0, 'wire: CommandType 0 = AT');
	eq(f.sent[0].cmd, 'ATI', 'wire: the bare command, no CR (the pipe frames it)');

	// the modem echoes the command back as the first line; the engine above
	// must not see it, or every response starts with its own request
	// exactly the echo and its CR come off — the CRLF that opens the response
	// stays, so the engine sees the same framing a tty would give it
	eq(got, "\r\nQuectel\r\nRM520N-GL\r\n\r\nOK\r\n", 'wire: echo stripped, framing kept');

	// a modem that echoes something else still gets cut at the first newline
	eq(atmbim.open != null, true, 'wire: module exports open');

	tr.close();
	eq(f.closed, true, 'close: MBIM_CLOSE issued');
});

// --- framing: the engine writes cmd + CR, one transaction per line -----------

f = fake({ 'AT+CPIN?': "AT+CPIN?\r\r\n+CPIN: READY\r\n\r\nOK\r\n",
           'AT+COPS?': "AT+COPS?\r\r\n+COPS: 0,0,\"X\",7\r\n\r\nOK\r\n" });
let seen = [];

open_with(f, (tr) => {
	tr.on_data((d) => push(seen, d));

	// two commands in one write, and a partial line that must NOT be sent yet
	tr.write("AT+CPIN?\rAT+COPS?\rAT+CGD");

	eq(map(f.sent, (s) => s.cmd), [ 'AT+CPIN?', 'AT+COPS?' ],
		'framing: complete lines dispatched, the partial one held back');
	eq(length(seen), 2, 'framing: one response per command');

	// completing the held line dispatches it
	f.sent = [];
	tr.write("CONT?\r");
	eq(map(f.sent, (s) => s.cmd), [ 'AT+CGDCONT?' ],
		'framing: a command split across writes is reassembled');
});

// an SMS body is terminated by ^Z, not CR — that is a unit of work too
f = fake({ 'hello': "hello\r\n\r\nOK\r\n" });
open_with(f, (tr) => {
	tr.write("hello\x1a");
	eq(map(f.sent, (s) => s.cmd), [ 'hello' ], 'framing: ^Z terminates a payload write');
});

// blank lines are not commands
f = fake({});
open_with(f, (tr) => {
	tr.write("\r\n\r\n");
	eq(length(f.sent), 0, 'framing: empty lines are not sent');
});

// --- failure paths -----------------------------------------------------------

f = fake({}, { open_err: { error: 'open_failed', status: 3 } });
let res = 'unset';
open_with(f, (tr) => res = tr);
eq(res, null, 'open: a refused MBIM_OPEN yields no transport');
eq(f.hub_closed, true, 'open: the hub is closed again on a refused open');

f = fake({});
res = 'unset';
open_with(f, (tr) => res = tr, { no_hub: true });
eq(res, null, 'open: an unopenable device yields no transport');

// a dead pipe must fail the command rather than stall the queue behind it
f = fake({}, { cmd_err: { error: 'timeout' } });
open_with(f, (tr) => {
	let out = null;
	tr.on_data((d) => out = d);
	tr.write("ATI\r");
	eq(out, "\r\nERROR\r\n", 'error: a transport error is handed up as ERROR');
});

// an unknown command answers status != 0 and still produces parseable output
f = fake({ 'AT+NOPE': null });
open_with(f, (tr) => {
	let out = null;
	tr.on_data((d) => out = d);
	tr.write("AT+NOPE\r");
	ok(index(out ?? '', 'ERROR') >= 0, 'error: a failed command yields ERROR');
});

// --- ordering: the pipe is one transaction at a time -------------------------

let pending = [];
f = fake({});
f.client.command_raw = (uuid, cid, info, cb) => {
	push(f.sent, { cmd: substr(info, 4) });
	push(pending, cb);
};

open_with(f, (tr) => {
	tr.write("AT1\rAT2\rAT3\r");
	eq(map(f.sent, (s) => s.cmd), [ 'AT1' ],
		'order: only one command is in flight');

	shift(pending)(null, struct.pack('<I', 0) + "AT1\r\r\nOK\r\n");
	eq(map(f.sent, (s) => s.cmd), [ 'AT1', 'AT2' ], 'order: the next goes out on completion');

	shift(pending)(null, struct.pack('<I', 0) + "AT2\r\r\nOK\r\n");
	eq(map(f.sent, (s) => s.cmd), [ 'AT1', 'AT2', 'AT3' ], 'order: and the one after that');
});

// --- attach(): riding a client someone else owns ----------------------------
//
// When MBIM DRIVES the modem, its control client is already open and a second
// MBIM_OPEN would reset the function and drop a live data session. attach()
// borrows the client instead — and must never close it.

// A borrowed client drives a live connection, so attach() asks
// DEVICE_SERVICES first instead of firing a speculative AT into it: a modem
// without the QDU service does not answer at all, and an unanswered command
// sits in flight for the full timeout (measured: 90 s on a connected RM520N).
const QDU_BYTES = "\x64\x27\x01\x5f\x57\x9d\x48\xf5\x8c\x54\xf4\x3e\xd1\xe7\x6f\x83";

function fake_svc(services, opts) {
	let f = fake(opts?.answers ?? { 'ATI': "ATI\r\r\nQuectel\r\n\r\nOK\r\n" });
	let inner = f.client.command_raw;

	f.client.command_raw = (uuid, cid, info, cb, o) => {
		if (cid == 16) {
			push(f.sent, { uuid: uuid, cid: cid, query: true });

			if (opts?.services_err)
				return cb(opts.services_err, null);

			return cb(null, "\x00\x00\x00\x00" + (services ?? ''));
		}

		return inner(uuid, cid, info, cb, o);
	};

	return f;
}

f = fake_svc(QDU_BYTES);
let tr = 'unset';
atmbim.attach(f.client, '/dev/cdc-wdm1', { log: (l, m) => null }, (t) => tr = t);

ok(tr != null, 'attach: transport built when the device offers QDU');
eq(f.opened, false, 'attach: no MBIM_OPEN issued on a client we do not own');
eq(f.sent[0].cid, 16, 'attach: DEVICE_SERVICES asked first');

let att = null;
tr.on_data((d) => att = d);
tr.write("ATI\r");
eq(f.sent[1].cid, 8, 'attach: same QDU wire format');
eq(att, "\r\nQuectel\r\n\r\nOK\r\n", 'attach: response delivered');

tr.close();
eq(f.closed, false, 'attach: closing the transport does NOT close the borrowed client');

// the probe must be short-lived on a borrowed client: an RM520N-GL that
// ADVERTISES QDU still never answered CID 8, and a 90 s in-flight command on
// the control channel of a modem carrying live traffic is not acceptable.
f = fake_svc(QDU_BYTES);
let touts = [];
let inner2 = f.client.command_raw;
f.client.command_raw = (uuid, cid, info, cb, o) => {
	if (cid == 8) push(touts, o?.timeout);
	return inner2(uuid, cid, info, cb, o);
};
tr = 'unset';
atmbim.attach(f.client, '/dev/cdc-wdm1', { log: (l, m) => null }, (t) => tr = t);
tr.on_data((d) => null);
tr.write("ATI\r");
tr.write("AT+COPS=?\r");
eq(touts[0], 8000, 'attach: the probe gets a short timeout');
ok(touts[1] > 8000, 'attach: once the modem has answered, long commands get the long timeout');

// a modem without the service: no transport, and NOTHING sent down the pipe
f = fake_svc("\x11\x22\x33\x44");
tr = 'unset';
atmbim.attach(f.client, '/dev/cdc-wdm1', { log: (l, m) => null }, (t) => tr = t);
eq(tr, null, 'attach: no QDU service, no transport');
eq(length(f.sent), 1, 'attach: nothing speculative sent to a modem that lacks it');

// device services unanswered -> decline, do not fall through to a blind probe
f = fake_svc(QDU_BYTES, { services_err: { error: 'timeout' } });
tr = 'unset';
atmbim.attach(f.client, '/dev/cdc-wdm1', { log: (l, m) => null }, (t) => tr = t);
eq(tr, null, 'attach: an unanswered DEVICE_SERVICES declines');

tr = 'unset';
atmbim.attach(null, '/dev/cdc-wdm1', {}, (t) => tr = t);
eq(tr, null, 'attach: no client, no transport');

done('test_atcmd_mbim');
