// wwand tests — backend-neutral SMS dispatch (sms.uc), QMI path.
// Drives the list -> per-entry raw-read -> reassemble flow and delete against a
// fake modem.wms client (the schema + PDU decode are covered by test_wms /
// test_sms_pdu; here we pin the dispatch, storage mapping and index plumbing).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as sms from 'wwand/sms.uc';
import * as simops from 'wwand/simops.uc';

// a minimal SMS-DELIVER PDU for gsm7 "hi" (SMSC 00, sender +12, UD e834)
const PDU_HI = [ 0x00, 0x04, 0x02,0x91,0x21, 0x00,0x00,
                 0x20,0x10,0x10,0,0,0,0x00, 0x02, 0xe8,0x34 ];

let deleted = [];

// fake QMI WMS client: LIST returns two entries, RAW_READ returns the same PDU,
// DELETE records its args.
let modem = {
	wms: {
		request: function(name, args, cb) {
			if (name == 'LIST_MESSAGES')
				return cb(null, { list: [ { memory_index: 1, tag: 0 },
				                          { memory_index: 4, tag: 1 } ] });
			if (name == 'RAW_READ')
				return cb(null, { raw: { tag: 0, format: 6, data: PDU_HI } });
			if (name == 'DELETE') {
				push(deleted, args);
				return cb(null);
			}
			return cb({ error: 'unexpected', name: name });
		},
	},
};

// --- list: chooses qmi, reads both entries, reassembles -----------------------
sms.sms_list(modem, 'SM', (err, res) => {
	eq(err, null, 'list: no error');
	eq(length(res.messages), 2, 'list: two messages');
	eq(res.messages[0].text, 'hi', 'list: decoded text');
	eq(modem._sms_be, 'qmi', 'list: qmi backend cached');
});

// --- read one by index --------------------------------------------------------
sms.sms_read(modem, 'ME', 4, (err, res) => {
	eq(err, null, 'read: no error');
	eq(res.message.text, 'hi', 'read: decoded text');
	eq(res.message.index, 4, 'read: index echoed');
	eq(res.message.storage, 'ME', 'read: storage echoed');
});

// --- delete maps storage 'ME' -> NV(1) and passes the index -------------------
sms.sms_delete(modem, 'ME', 4, (err, res) => {
	eq(err, null, 'delete: no error');
	ok(res.ok, 'delete: ok');
});
eq(deleted[0].storage, 1, 'delete: storage ME -> NV(1)');
eq(deleted[0].memory_index, 4, 'delete: index passed');

// --- 'SM' maps to UIM(0) ------------------------------------------------------
sms.sms_delete(modem, 'SM', 2, () => {});
eq(deleted[1].storage, 0, 'delete: storage SM -> UIM(0)');

// --- deleting a SET, which is what the UI actually needs ----------------------
//
// NOT a protocol "delete all", although every backend offers one. A bulk
// primitive deletes what is in the store when the MODEM runs it, not what the
// operator was shown, so a message arriving between the list and the click goes
// with it (ddimension/luci-app-wwand#8). Deleting the listed indices cannot do
// that.
deleted = [];
sms.sms_delete(modem, 'SM', [ 2, 5, 9 ], (err, res) => {
	eq(err, null, 'multi: no error');
	ok(res.ok, 'multi: ok');
	eq(res.deleted, 3, 'multi: all three deleted');
	eq(res.requested, 3, 'multi: and all three were requested');
	eq(length(res.failed), 0, 'multi: nothing failed');
});
eq(map(deleted, (d) => d.memory_index), [ 9, 5, 2 ],
	'multi: DESCENDING — a firmware that compacted its store could not shift a pending index');

// duplicates and junk are dropped rather than sent twice
deleted = [];
sms.sms_delete(modem, 'SM', [ 3, 3, -1, 7 ], (err, res) => {
	eq(res.deleted, 2, 'multi: duplicate collapsed, negative dropped');
});
eq(map(deleted, (d) => d.memory_index), [ 7, 3 ], 'multi: each surviving index sent once');

// an empty set is an error, not a silent success — a UI bug must not read as
// "deleted nothing, fine"
sms.sms_delete(modem, 'SM', [], (err, res) => {
	eq(err?.error, 'no_index', 'multi: an empty set is refused');
	eq(res, null, 'multi: and returns no result');
});

// A SINGLE index keeps the reply shape it always had, because rpc callers and
// the per-row Delete button still use it.
deleted = [];
sms.sms_delete(modem, 'SM', 6, (err, res) => {
	eq(err, null, 'single: unchanged');
	ok(res.ok, 'single: plain ok');
	eq(res.deleted, null, 'single: no multi bookkeeping in the reply');
});

// AN EMPTY SELECTION MUST NOT DELETE ANYTHING, and the ubus layer is where that
// is decided. ubus fills a declared argument with its default when the caller
// omits it, so `index` arrives as 0 whether or not anyone asked for slot 0 —
// `indices: []` therefore used to fall through to "delete index 0" and issue a
// real delete. HW-confirmed on an NR7101: the modem answered +CMS ERROR 321,
// which it only does because the command was sent (2026-09-12).
(function() {
	let sent = [];
	let fake = { _sms_be: 'qmi', wms: { request: (n, a, cb) => { push(sent, a.memory_index); cb(null); } } };
	let ops = {};

	simops.install(ops, {
		log: (l, m) => null,
		check_modem: (ref, cb) => (ref == 'm0') ? { modem: fake } : cb({ error: 'no_such_modem' }, null),
	});

	let got;
	ops.modem_sms_delete('m0', 'SM', 0, [], (e, r) => { got = e; });
	eq(got?.error, 'no_index', 'ubus: an empty selection is refused');
	eq(length(sent), 0, 'ubus: and NOTHING was sent to the modem');

	ops.modem_sms_delete('m0', 'SM', 0, null, (e, r) => { got = e; });
	eq(got?.error, 'no_index', 'ubus: a bare index 0 is refused too — slots number from 1');
	eq(length(sent), 0, 'ubus: still nothing sent');

	// ...and a real request still goes through, both shapes
	ops.modem_sms_delete('m0', 'SM', 3, [], (e, r) => { got = e; });
	eq(sent, [ 3 ], 'ubus: a positive single index is deleted');

	sent = [];
	ops.modem_sms_delete('m0', 'SM', 0, [ 2, 5 ], (e, r) => { got = e; });
	eq(sent, [ 5, 2 ], 'ubus: a list is deleted, highest first');
})();

// --- one bad slot must not strand the rest -----------------------------------
// The case this exists for is a full SIM: index 30 failing is no reason for
// 31..47 to survive, and the caller needs to be told which one went wrong
// rather than just "error".
let flaky_deleted = [];
let flaky = {
	// backend pre-selected: this fixture exercises the LOOP, not the probe
	_sms_be: 'qmi',
	wms: {
		request: function(name, args, cb) {
			if (name != 'DELETE')
				return cb({ error: 'unexpected', name: name });
			if (args.memory_index == 5)
				return cb({ error: 'qmi', result: 1, code: 48 });
			push(flaky_deleted, args.memory_index);
			return cb(null);
		},
	},
};

sms.sms_delete(flaky, 'SM', [ 2, 5, 9 ], (err, res) => {
	eq(err, null, 'partial: not reported as a failed call');
	ok(!res.ok, 'partial: but not ok either');
	eq(res.deleted, 2, 'partial: the other two went');
	eq(length(res.failed), 1, 'partial: one failure recorded');
	eq(res.failed[0].index, 5, 'partial: named by index');
	eq(res.failed[0].error?.detail?.code, 48,
		'partial: with the backend error kept, in the shape it always had');
});
eq(flaky_deleted, [ 9, 2 ], 'partial: the failure did not stop the loop');

// ...and a SINGLE index that fails still reports the bare error it always did
sms.sms_delete(flaky, 'SM', 5, (err, res) => {
	eq(err?.detail?.code, 48, 'single: a failure is still the plain error');
	eq(res, null, 'single: and no result');
});

// --- no WMS -> unsupported_on_backend ----------------------------------------
sms.sms_list({}, 'SM', (err, res) => {
	eq(err.error, 'unsupported_on_backend', 'no wms -> unsupported_on_backend');
});

// A SEND can be the first SMS operation on a modem, and WMS is allocated
// lazily — the list/read/delete path reaches _ensure_wms through
// sms_backend(), the send path did not. On a QMI-only modem that meant
// send-first found modem.wms null and fell through to an AT path that may not
// exist at all.
{
	let ensured = 0, sent = [];
	// forward-declared: the closure refers to `m` (ucode has no hoisting)
	let m;
	m = {
		_ensure_wms: function(cb) {
			ensured++;
			// what the real one does: allocate, then hand control back
			m.wms = { request: (name, args, rcb) => {
				push(sent, name);
				rcb(null, { message_id: 1 });
			} };
			cb();
		},
	};

	sms.sms_send(m, '+491700000000', 'hi', (err, res) => {
		eq(err, null, 'send-first: succeeds without a prior list');
		eq(res.parts, 1, 'send-first: one part');
	});

	eq(ensured, 1, 'send-first: the WMS client is allocated on the send itself');
	eq(sent, [ 'RAW_SEND' ], 'send-first: and the message goes out over WMS, not AT');
}

done('test_sms');
