// wwand tests — backend-neutral SMS dispatch (sms.uc), QMI path.
// Drives the list -> per-entry raw-read -> reassemble flow and delete against a
// fake modem.wms client (the schema + PDU decode are covered by test_wms /
// test_sms_pdu; here we pin the dispatch, storage mapping and index plumbing).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as sms from 'wwand/sms.uc';

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
