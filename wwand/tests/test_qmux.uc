// wwand tests — QMUX framing.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as qmux from 'wwand/codec/qmux.uc';
import * as tlv from 'wwand/codec/tlv.uc';
import ctl from 'wwand/codec/schema/ctl.uc';

// --- CTL request (1-byte txn), hand-computed reference frame ----------------

// CTL ALLOCATE_CID(service=wds/0x01), txn 1:
let frame = qmux.encode(0x00, 0x00, 1, ctl.messages.ALLOCATE_CID.id,
	tlv.pack(ctl.messages.ALLOCATE_CID.req, { service: 0x01 }));

eq(hexenc(frame), '010f0000000000012200040001010001', 'CTL allocate-cid request frame');

// --- WDS request (2-byte txn), hand-computed reference frame ----------------

// WDS GET_PACKET_SERVICE_STATUS (0x0022), svc 1, cid 5, txn 0x0203, no TLVs:
frame = qmux.encode(0x01, 0x05, 0x0203, 0x0022, '');
eq(hexenc(frame), '010c0000010500030222000000', 'WDS request frame');

// --- decode of own frames ---------------------------------------------------

let d = qmux.decode(qmux.encode(0x01, 0x05, 0x0203, 0x0022, ''));
eq(d.service, 1, 'decode service');
eq(d.cid, 5, 'decode cid');
eq(d.txn, 0x0203, 'decode txn');
eq(d.msg_id, 0x0022, 'decode msg id');
eq(d.kind, 'request', 'decode kind request');
eq(d.tlvs, '', 'decode empty tlvs');

// --- decode synthetic response & indication ---------------------------------

// CTL ALLOCATE_CID response: flags 0x80 (service->cp), sdu flags 0x01 (resp),
// txn 1, result TLV + allocation TLV (svc 1, cid 5)
let hexresp = '011700800000' + '010122000c00' + '02040000000000' + '0102000105';
d = qmux.decode(hexdec(hexresp));
eq(d.kind, 'response', 'CTL response kind');
eq(d.txn, 1, 'CTL response txn');
let un = tlv.unpack(ctl.messages.ALLOCATE_CID.resp, d.tlvs);
eq(un._result, { result: 0, error: 0 }, 'CTL response result ok');
eq(un.allocation, { service: 1, cid: 5 }, 'CTL response allocation');

// WDS indication: svc 1, cid 5, sdu flags 0x04, txn 0
// msg 0x0022 with TLV 0x01 = {state u8=1, reconf u8=0}
let hexind = '011100800105' + '040000' + '22000500' + '0102000100';
d = qmux.decode(hexdec(hexind));
eq(d.kind, 'indication', 'WDS indication kind');
eq(d.msg_id, 0x0022, 'WDS indication msg id');

// --- robustness -------------------------------------------------------------

eq(qmux.decode(null), null, 'null input');
eq(qmux.decode(''), null, 'empty input');
eq(qmux.decode('\x02garbagegarbage'), null, 'wrong marker');
eq(qmux.decode(hexdec('010f00')), null, 'short frame');

// truncated TLV payload is tolerated (mlen clamped)
let good = qmux.encode(0x01, 0x05, 7, 0x0022, tlv.pack({ x: { t: 1, f: 'u32' } }, { x: 1 }));
for (let cut = 12; cut < length(good); cut++)
	qmux.decode(substr(good, 0, cut));
ok(true, 'progressive truncation survived');

done('test_qmux');
