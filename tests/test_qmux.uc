// wwand tests — QMUX framing.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as wda from 'wwand/codec/schema/wda.uc';
import * as qmux from 'wwand/codec/qmux.uc';
import * as tlv from 'wwand/codec/tlv.uc';
import ctl from 'wwand/codec/schema/ctl.uc';
import nas from 'wwand/codec/schema/nas.uc';
import uim from 'wwand/codec/schema/uim.uc';

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

// --- NAS Network Scan schema (0x0021) ---------------------------------------

// decode the REAL libqmi 1.38 test-generated.c "NAS Network Scan" Network
// Information TLV (type 0x10) — proves the schema (guint16-count array of
// { mcc:u16, mnc:u16, network_status:u8, description:lstring }) matches the wire
let scan_tlvs = hexdec(
	'02040000000000' +                             // result TLV (ok)
	'1060000800' +                                 // netinfo TLV, 8 elements
	'd6000100aa07' + '766f6461204553' +            // 214/1  0xAA "voda ES"
	'd6000300aa06' + '4f72616e6765' +              // 214/3  0xAA "Orange"
	'd6000400aa05' + '594f49474f' +                // 214/4  0xAA "YOIGO"
	'd6000100aa07' + '766f6461204553' +
	'd6000400aa05' + '594f49474f' +
	'd6000700aa08' + '4d6f766973746172' +          // 214/7  0xAA "Movistar"
	'd6000700aa08' + '4d6f766973746172' +
	'd6000300a900');                               // 214/3  0xA9 "" (current serving)

let scan = tlv.unpack(nas.messages.NETWORK_SCAN.resp, scan_tlvs);
eq(length(scan.network_information), 8, 'network scan: 8 operators decoded');
eq(scan.network_information[0],
	{ mcc: 214, mnc: 1, network_status: 0xAA, description: 'voda ES' },
	'network scan: first operator (libqmi wire bytes)');
eq(scan.network_information[7].network_status, 0xA9, 'network scan: current-serving status bits');
eq(scan.network_information[7].description, '', 'network scan: empty operator name');

// round-trip through pack (the shape the mock hub encodes for the daemon test)
let rt = tlv.unpack(nas.messages.NETWORK_SCAN.resp,
	tlv.pack(nas.messages.NETWORK_SCAN.resp, {
		network_information: [
			{ mcc: 262, mnc: 1, network_status: 0x01, description: 'Op1' },
			{ mcc: 262, mnc: 3, network_status: 0x12, description: 'Op3' },
		],
	}));
eq(length(rt.network_information), 2, 'network scan: round-trip element count');
eq(rt.network_information[1],
	{ mcc: 262, mnc: 3, network_status: 0x12, description: 'Op3' },
	'network scan: round-trip second element');

// --- NAS Set/Get Preferred Networks (0x0027 / 0x0026) -----------------------
// TLV 0x10 = guint16-count array of { mcc:u16, mnc:u16, rat:u16 }; the rat is
// the EF-6F60 AcT bitmask (0x8000 UTRAN, 0x4000 E-UTRAN, 0x0800 NG-RAN,
// 0x0080 GSM). The array wire form is the same {n:'u16',of} convention proven
// against real libqmi bytes by the NETWORK_SCAN test above; round-trip here.
let setrt = tlv.unpack(nas.messages.SET_PREFERRED_NETWORKS.req,
	tlv.pack(nas.messages.SET_PREFERRED_NETWORKS.req, {
		preferred_networks: [
			{ mcc: 262, mnc: 1, rat: 0x8000 | 0x4000 },   // UTRAN + E-UTRAN
			{ mcc: 262, mnc: 3, rat: 0x4000 | 0x0800 },   // E-UTRAN + NG-RAN
		],
		clear_previous: 1,
	}));
eq(length(setrt.preferred_networks), 2, 'nas set-pref: two records round-trip');
eq(setrt.preferred_networks[0], { mcc: 262, mnc: 1, rat: 0xC000 }, 'nas set-pref: element 0 (mcc/mnc/rat)');
eq(setrt.preferred_networks[1].rat, 0x4800, 'nas set-pref: element 1 rat bitmask (E-UTRAN|NG-RAN)');
eq(setrt.clear_previous, 1, 'nas set-pref: clear-previous flag');

let getrt = tlv.unpack(nas.messages.GET_PREFERRED_NETWORKS.resp,
	tlv.pack(nas.messages.GET_PREFERRED_NETWORKS.resp, {
		preferred_networks: [ { mcc: 310, mnc: 260, rat: 0x4000 } ],
	}));
eq(getrt.preferred_networks[0], { mcc: 310, mnc: 260, rat: 0x4000 }, 'nas get-pref: 3-digit mnc + E-UTRAN round-trip');

// --- UIM Write Transparent (0x0022) — EF_FPLMN update ------------------------
// libqmi 1.38 has no binding for this message; the schema is spec-derived and
// mirrors READ_TRANSPARENT with the read_info replaced by write data. Pin the
// request wire form: session(0x01), file(0x02 {file_id u16, path}), write_data
// (0x03 {offset u16, data as u16-counted u8 array}).
let wt_bytes = tlv.pack(uim.messages.WRITE_TRANSPARENT.req, {
	session:    { session_type: 0, aid: '' },
	file:       { file_id: 0x6F7B, path: '\x00\x3F\x20\x7F' },   // 3F00/7F20
	write_data: { offset: 0, data: [ 0x62, 0xF2, 0x20, 0xFF, 0xFF, 0xFF ] },
});
let wt = tlv.unpack(uim.messages.WRITE_TRANSPARENT.req, wt_bytes);
eq(wt.file.file_id, 0x6F7B, 'uim write: EF_FPLMN file id round-trips');
eq(wt.write_data.offset, 0, 'uim write: offset');
eq(wt.write_data.data, [ 0x62, 0xF2, 0x20, 0xFF, 0xFF, 0xFF ], 'uim write: 6-byte data array round-trips');
// the write_data TLV (type 0x03) on the wire: offset u16-le (0000) + u16-le
// count (0006) + the 6 data bytes = 10 payload bytes
ok(index(wt_bytes, chr(0x03) + '\x0a\x00' + '\x00\x00' + '\x06\x00' + '\x62\xf2\x20\xff\xff\xff') >= 0,
	'uim write: write_data TLV wire layout (offset + u16 count + bytes)');

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

// The WDA data-aggregation ladder, pinned against libqmi 1.38
// (src/libqmi-glib/qmi-enums-wda.h) because getting one wrong is invisible:
// DAP_QMAPV5 was 8 — which is QMAPv4 — and the modem simply renegotiated, so
// it looked like a firmware quirk ("RG650E declines DAP 8") for months.
// quectel-cm confirms the pair from the other side: it sends 0x05 or 0x09.
eq([ wda.DAP_DISABLED, wda.DAP_TLP, wda.DAP_QC_NCM, wda.DAP_MBIM, wda.DAP_RNDIS,
     wda.DAP_QMAP, wda.DAP_QMAPV2, wda.DAP_QMAPV3, wda.DAP_QMAPV4, wda.DAP_QMAPV5 ],
   [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 ], 'wda: the aggregation enum matches libqmi 1.38');
eq(wda.DAP_QMAPV1, wda.DAP_QMAP, 'wda: QMAP and QMAPV1 are the same value (5)');


// --- WDA SET_DATA_FORMAT: the three request TLVs libqmi does not model --------
// 0x18/0x19/0x1A are declared but deliberately never sent. This pins their wire
// ids and widths so a later change that starts sending one cannot quietly move
// them — a wrong tag decodes garbage rather than failing.
let sdf_req = wda.default.messages.SET_DATA_FORMAT.req;
eq(sdf_req.qos_header_format.t, 0x18, 'wda: qos_header_format is request TLV 0x18');
eq(sdf_req.dl_min_padding.t,    0x19, 'wda: dl_min_padding is request TLV 0x19');
eq(sdf_req.flow_control.t,      0x1A, 'wda: flow_control is request TLV 0x1A');
eq(sdf_req.dl_min_padding.f,   'u32', 'wda: dl_min_padding is 32 bit');

// the RESPONSE has its own TLV space — 0x18 there is ul_max_size. Conflating the
// two namespaces is exactly how a decoder ends up reading the wrong field.
eq(wda.default.messages.SET_DATA_FORMAT.resp.ul_max_size.t, 0x18,
	'wda: response 0x18 is ul_max_size, a different namespace');

// none of the three is emitted unless the caller sets it — tlv.pack() writes
// only the fields present in the args, so declaring them costs nothing on the
// wire until something deliberately sets one
let sdf_packed = tlv.pack(sdf_req, { llp: 2 });
eq(index(sdf_packed, chr(0x18)), -1, 'wda: qos_header_format not sent unless set');
eq(index(sdf_packed, chr(0x1A)), -1, 'wda: flow_control not sent unless set');

done('test_qmux');

