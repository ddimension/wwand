// wwand tests — service client correlation logic against a mock hub.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as client from 'wwand/client.uc';
import * as tlv from 'wwand/codec/tlv.uc';
import * as qmux from 'wwand/codec/qmux.uc';
import dms from 'wwand/codec/schema/dms.uc';

uloop.init();

let sent = [];
let errors = [];

let hub = {
	send: (frame) => { push(sent, frame); return true; },
	register: (c) => null,
	unregister: (c) => null,
};

let answers = 0;

let hooks = {
	on_error: (c, kind) => push(errors, kind),
	on_answer: (c) => answers++,
};

let c = client.create(hub, dms, 5, hooks);

// --- request encoding -------------------------------------------------------

let got_err = 'unset', got_data = null;

c.request('GET_MODEL', {}, (err, data) => { got_err = err; got_data = data; });

eq(length(sent), 1, 'one frame sent');
let d = qmux.decode(sent[0]);
eq(d.service, 2, 'frame service dms');
eq(d.cid, 5, 'frame cid');
eq(d.msg_id, 0x0022, 'frame msg id');
eq(d.txn, 1, 'first txn');

// --- response dispatch ------------------------------------------------------

// synthesize success response: result TLV + model TLV
let resp_tlvs = hexdec('02040000000000') + tlv.pack(dms.messages.GET_MODEL.resp, { model: 'RG502Q-EA' });
c.dispatch({ kind: 'response', txn: 1, msg_id: 0x0022, tlvs: resp_tlvs });

eq(got_err, null, 'success: err is null');
eq(got_data.model, 'RG502Q-EA', 'success: model decoded');

// unknown txn must be ignored silently
c.dispatch({ kind: 'response', txn: 99, msg_id: 0x0022, tlvs: resp_tlvs });
ok(true, 'unknown txn ignored');

// --- a send the hub failed vs one it held back (ddimension/wwand#61) ---------
// A failed send is a protocol error; a request the hub did not even try (its
// destination known to be stuck, the attempt that found out already counted)
// fails the same way but is not counted again.

{
	let answer = false;
	let fhub = { send: (f) => answer, register: () => null, unregister: () => null };
	let ferrs = [];
	let fc = client.create(fhub, dms, 7, { on_error: (c, kind) => push(ferrs, kind) });
	let e1, e2;

	fc.request('GET_MODEL', {}, (err) => { e1 = err; });
	answer = 'held';
	fc.request('GET_MODEL', {}, (err) => { e2 = err; });

	eq([ e1?.error, e2?.error ], [ 'send', 'send' ], 'send: failed and held both fail the request as a send error');
	eq(ferrs, [ 'send' ], 'send: ...but only the failed one counts toward recovery');
}

// --- QMI error result -------------------------------------------------------

c.request('GET_REVISION', {}, (err, data) => { got_err = err; });
d = qmux.decode(sent[1]);
eq(d.txn, 2, 'txn increments');

// result=1, error=0x0010 (not provisioned)
c.dispatch({ kind: 'response', txn: 2, msg_id: d.msg_id, tlvs: hexdec('02040001001000') });
eq(got_err.error, 'qmi', 'qmi error kind');
eq(got_err.code, 16, 'qmi error code');
eq(errors, [ 'qmi' ], 'error hook fired');

// --- timeout ----------------------------------------------------------------

let timed_out = false;

c.request('GET_IDS', {}, (err, data) => { timed_out = (err?.error == 'timeout'); },
	{ timeout: 20 });

uloop.timer(100, () => uloop.end());
uloop.run();

ok(timed_out, 'timeout fired');
eq(errors, [ 'qmi', 'timeout' ], 'timeout counted as error');

// --- indications ------------------------------------------------------------

let ctl_like = {
	service: 0,
	messages: {
		SYNC: { id: 0x0027, req: {}, resp: {}, ind: {} },
	},
};

let synced = 0;
let cc = client.create(hub, ctl_like, 0, null);

cc.on('SYNC', (data, dec) => synced++);
cc.dispatch({ kind: 'indication', txn: 0, msg_id: 0x0027, tlvs: '' });
eq(synced, 1, 'indication handler fired');

// CTL txn wraps at 0xff
cc.next_txn = 0xff;
cc.request('SYNC', {}, null);
eq(cc.next_txn, 1, 'ctl txn wraps to 1');

// --- on_answer: a matched response is the modem speaking QMI -----------------
// A different question from on_success, and a strictly weaker one: the hardware
// recovery gate asks "is this the right protocol", which a SERVICE ERROR
// answers just as well as a result-0 response. Arming on success alone would
// strand a modem that talks to us fluently but refuses everything we ask.
ok(answers >= 2, 'on_answer: fired for the success AND for the QMI error response');

let a0 = answers;
c.dispatch({ kind: 'response', txn: 4242, msg_id: 0x0022, tlvs: resp_tlvs });
eq(answers, a0, 'on_answer: an unmatched txn is not our modem answering us');

// --- txn collision: a wrapped id must skip a still-pending request ----------

let hub2_sent = [];
let hub2 = { send: (f) => { push(hub2_sent, f); return true; }, register: () => null, unregister: () => null };
let tc = client.create(hub2, dms, 5, null);

// request A stays pending (never dispatched)
tc.request('GET_MODEL', {}, () => null);
let ta = qmux.decode(hub2_sent[0]).txn;

// force next_txn back onto A's id to simulate a wrap-around collision
tc.next_txn = ta;
tc.request('GET_REVISION', {}, () => null);
let tb = qmux.decode(hub2_sent[1]).txn;

ok(tb != ta, 'txn-collision: wrapped id skips the in-flight txn');
ok(tc.pending[sprintf('%d', ta)] != null, 'txn-collision: original pending preserved (not overwritten)');
eq(tc.pending[sprintf('%d', ta)].name, 'GET_MODEL', 'txn-collision: slot A still holds request A');
eq(tc.pending[sprintf('%d', tb)].name, 'GET_REVISION', 'txn-collision: request B got its own free slot');
tc.destroy();

// --- destroy cancels pending ------------------------------------------------

let cancelled = false;

c.request('GET_MODEL', {}, (err) => { cancelled = (err?.error == 'cancelled'); });
c.destroy();
ok(cancelled, 'destroy cancels pending requests');

// --- a callback that "carries on" during destroy must not reach the wire -----
// This is the cancellation family at its source. destroy() reports `cancelled`
// to every pending callback; a callback that treats an error as "carry on" then
// issued its next request from inside that loop, while the hub was still live.
// The frame went out and a timeout timer was armed — and the pending entry it
// created was wiped a moment later by the very loop that had called it. So the
// response could never arrive, while the timer still fired and reported a
// protocol timeout on a client that no longer exists, straight into the
// recovery error counter that drives the reboot ladder.
let c2 = client.create(hub, dms, 6, hooks);
let carried = 'unset';

c2.request('GET_MODEL', {}, () => {
	/* the "carry on" pattern, verbatim */
	c2.request('GET_REVISION', {}, (e2) => { carried = e2?.error ?? 'sent'; });
});

/* only what the teardown itself causes counts */
sent = [];
errors = [];

c2.destroy();

eq(length(sent), 0, 'destroy: a request issued from a cancellation callback never reaches the hub');
eq(carried, 'cancelled', 'destroy: ...it is refused synchronously, the shape callers already handle');
eq(length(errors), 0, 'destroy: ...and nothing is charged to the recovery error counter');

// a second destroy is a no-op rather than a second round of callbacks
let again = 0;
c2.request('GET_MODEL', {}, () => { again++; });
c2.destroy();
eq(again, 1, 'destroy: after teardown a request answers once, and destroy does not run again');

// --- request_raw: a message no schema describes (wwandctl qmi) --------------
// The payload goes out as given; the answer comes back undecoded as the third
// callback argument — also when the result says failure, because the TLVs of
// a refusal are what the operator is looking at.
{
	let rsent = [];
	let rhub = { send: (f) => { push(rsent, f); return true; }, register: () => null, unregister: () => null };
	let rerrs = [];
	let rc = client.create(rhub, { service: 0x2a, messages: {} }, 9, { on_error: (c, k) => push(rerrs, k) });
	let got = [];

	rc.request_raw(0x0024, hexdec('010100ff'), (e, data, raw) => push(got, [ e, data?._result, raw ]), { no_recovery: true });

	let fd = qmux.decode(rsent[0]);

	eq([ fd.service, fd.cid, fd.msg_id, hexenc(fd.tlvs) ], [ 0x2a, 9, 0x0024, '010100ff' ],
		'request_raw: service, cid, message id and the TLV bytes as given');

	rc.dispatch({ kind: 'response', txn: fd.txn, msg_id: 0x0024, tlvs: hexdec('020400010030001001007f') });
	eq(got[0][0], { error: 'qmi', result: 1, code: 0x30 }, 'request_raw: a failure result is the usual qmi error...');
	eq(hexenc(got[0][2]), '020400010030001001007f', '...and still carries the response TLVs, undecoded');
	eq(rerrs, [], 'request_raw: no_recovery keeps a refused experiment out of the recovery count');

	rc.destroy();
	let late = null;
	eq(rc.request_raw(1, '', (e) => { late = e?.error; }), false, 'request_raw: a destroyed client sends nothing');
	eq(late, 'cancelled', '...and says cancelled');
}

done('test_client');
