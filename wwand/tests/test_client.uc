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

let hooks = {
	on_error: (c, kind) => push(errors, kind),
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

// --- destroy cancels pending ------------------------------------------------

let cancelled = false;

c.request('GET_MODEL', {}, (err) => { cancelled = (err?.error == 'cancelled'); });
c.destroy();
ok(cancelled, 'destroy cancels pending requests');

done('test_client');
