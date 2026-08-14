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

// --- broadcast (0xff) indication fan-out ------------------------------------
// NAS broadcast indications arrive on cid 0xff and must be fanned out to every
// client of that service, exactly like the native transport hub. Regression
// guard: the passthrough deliver() diverged and dropped them before this fix.
import * as nasmod from 'wwand/codec/schema/nas.uc';

let nas = nasmod.default;
let ind_cb = null;
let bcast_mc = {
	command_raw: function() {},
	on: function(schema, name, cb) { ind_cb = cb; },
};
let bshim = qom.create(bcast_mc);

// two NAS clients on distinct cids, each with a serving-system handler
let hits = {};
let n5 = client_mod.create(bshim, nas, 5, {});
let n6 = client_mod.create(bshim, nas, 6, {});
n5.on('SERVING_SYSTEM_IND', () => hits['5'] = (hits['5'] ?? 0) + 1);
n6.on('SERVING_SYSTEM_IND', () => hits['6'] = (hits['6'] ?? 0) + 1);

// a DMS client of a different service must NOT receive the NAS broadcast
let dms_hit = 0;
let d7 = client_mod.create(bshim, dms, 7, {});
d7.on('EVENT_REPORT', () => dms_hit++);

// simulate the modem pushing a broadcast SERVING_SYSTEM_IND on cid 0xff
let ss_tlv = tlv.pack(nas.messages.SERVING_SYSTEM_IND.ind, {
	serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
	                  selected_network: 1, radio_ifs: [8] },
});
let bcast = qmux.encode(nas.service, 0xff, 0, 0x0024, ss_tlv, 'indication');
ind_cb(null, { info: bcast });

eq(hits['5'], 1, 'broadcast 0xff: fanned out to NAS client cid 5');
eq(hits['6'], 1, 'broadcast 0xff: fanned out to NAS client cid 6');
eq(dms_hit, 0, 'broadcast 0xff: not delivered to a different service');

// a targeted (non-0xff) indication still goes only to its own client
delete hits['5']; delete hits['6'];
let direct = qmux.encode(nas.service, 6, 0, 0x0024, ss_tlv, 'indication');
ind_cb(null, { info: direct });
eq(hits['6'], 1, 'targeted indication: delivered to the addressed client');
eq(hits['5'], null, 'targeted indication: not fanned out to other clients');

done('test_passthrough');
