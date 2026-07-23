// wwand tests — QMI-over-MBIM passthrough transport shim (qmi_over_mbim.uc).
//
// Proves the core: a real QMI client, handed the passthrough shim in place of
// the transport hub, has its QMUX request wrapped into an MBIM COMMAND to the
// QMI passthrough CID, and the unwrapped QMUX reply decoded back through the
// normal client/tlv path — no changes to client.uc / qmux / tlv / the schema.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as struct from 'struct';
import * as qmux from 'wwand/codec/qmux.uc';
import * as tlv from 'wwand/codec/tlv.uc';
import * as dmsmod from 'wwand/codec/schema/dms.uc';
import * as client_mod from 'wwand/client.uc';
import * as qom from 'wwand/qmi_over_mbim.uc';
import * as qmi_pt from 'wwand/codec/mbim-schema/qmi_passthrough.uc';

uloop.init();

let dms = dmsmod.default;
let seen = {};

// fake mbim_client: records the wrap, unwraps the QMUX request, and answers with
// a canned GET_MODEL QMUX response (result TLV + model) delivered async — as the
// real transport would, so client.request has registered its pending by then.
let fake_mc = {
	command_raw: function(service_uuid, cid, info, cb) {
		seen.service = service_uuid;
		seen.cid = cid;
		let req = qmux.decode(info);
		seen.req = req;

		uloop.timer(0, () => {
			let msg = dms.messages.GET_MODEL;
			let result = struct.pack('<BHHH', 0x02, 4, 0, 0);   // QMI result TLV, success
			let tlvs = result + tlv.pack(msg.resp, { model: 'RG650E-EU' });
			let frame = qmux.encode(req.service, req.cid, req.txn, msg.id, tlvs, 'response');
			cb(null, frame);
		});
	},
	on: function(schema, name, cb) { seen.ind_registered = name; },
};

let shim = qom.create(fake_mc);
let c = client_mod.create(shim, dms, 3, {});

let got = null;
c.request('GET_MODEL', {}, (err, data) => { got = { err: err, data: data }; uloop.end(); });

uloop.run();

eq(seen.service, qmi_pt.service, 'passthrough: wrapped to the QMI service uuid');
eq(seen.cid, qmi_pt.CID_QMI_MSG, 'passthrough: QMI_MSG cid');
eq(seen.req.service, dms.service, 'passthrough: inner QMUX carries the DMS service');
eq(seen.req.cid, 3, 'passthrough: inner QMUX carries the client cid');
eq(got?.err, null, 'passthrough: request succeeds through the shim');
eq(got?.data?.model, 'RG650E-EU', 'passthrough: response decoded end-to-end');
eq(seen.ind_registered, 'QMI_MSG', 'passthrough: registered for unsolicited QMI indications');

// --- never-SYNC structural rail ---------------------------------------------
// A CTL SYNC (service 0, msg 0x0027) must NEVER reach the wire over the
// passthrough: it resets the modem's embedded QMI state and kills the live MBIM
// data session. The shim drops it and fails the request fast instead.
let wire_calls = 0;
let rail_mc = {
	command_raw: function(su, cid, info, cb) { wire_calls++; },
	on: function() {},
};
let rail = qom.create(rail_mc);
let sync_frame = qmux.encode(0, 0, 7, 0x0027, '', 'request');
let sent = rail.send(sync_frame);

eq(wire_calls, 0, 'never-SYNC: CTL SYNC is not forwarded to the MBIM wire');
ok(sent, 'never-SYNC: send() still returns true (request handled, not queued)');

// a non-SYNC CTL frame (ALLOCATE_CID, 0x0022) does go through
rail.send(qmux.encode(0, 0, 8, 0x0022, '', 'request'));
eq(wire_calls, 1, 'never-SYNC: other CTL frames still reach the wire');

done('test_passthrough');
