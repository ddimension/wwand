// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI WDA service message schema (service 0x1A).
// TLV layouts verified against libqmi data/qmi-service-wda.json.

'use strict';

// QmiWdaLinkLayerProtocol
export const LLP_802_3 = 1;
export const LLP_RAW_IP = 2;

// QmiWdaDataAggregationProtocol — the full ladder, because taking the two we
// use out of context is how the v5 value came to be wrong: it was 8, which is
// QMAPv4. libqmi 1.38 (src/libqmi-glib/qmi-enums-wda.h) has QMAPV4 = 0x08 and
// QMAPV5 = 0x09, and quectel-cm agrees from the other side — it sends 0x05 or
// 0x09 and nothing in between (`if (qmap_version != 0x09) qmap_version = 0x05`).
//
// The old value has a field symptom on record: the RG650E "declining DAP 8
// aggregation edge cases" and renegotiating plain QMAP was not a firmware
// quirk. We were asking for QMAPv4.
export const DAP_DISABLED = 0;
export const DAP_TLP      = 1;
export const DAP_QC_NCM   = 2;
export const DAP_MBIM     = 3;
export const DAP_RNDIS    = 4;
export const DAP_QMAP     = 5;   // QMAP v1 — what libqmi simply calls QMAP
export const DAP_QMAPV1   = 5;   // the same value, spelled so the ladder reads
                                 // v1..v5 and 5-means-v1 cannot be misread again
export const DAP_QMAPV2   = 6;
export const DAP_QMAPV3   = 7;
export const DAP_QMAPV4   = 8;
export const DAP_QMAPV5   = 9;

// QmiDataEndpointType
export const ENDPOINT_TYPE_HSUSB = 2;
export const ENDPOINT_TYPE_PCIE = 3;
export const ENDPOINT_TYPE_EMBEDDED = 4;

const FORMAT_FIELDS_RESP = {
	qos:              { t: 0x10, f: 'u8' },
	llp:              { t: 0x11, f: 'u32' },
	ul_protocol:      { t: 0x12, f: 'u32' },
	dl_protocol:      { t: 0x13, f: 'u32' },
	ndp_signature:    { t: 0x14, f: 'u32' },
	dl_max_datagrams: { t: 0x15, f: 'u32' },
	dl_max_size:      { t: 0x16, f: 'u32' },
	ul_max_datagrams: { t: 0x17, f: 'u32' },
	ul_max_size:      { t: 0x18, f: 'u32' },
};

export default {
	service: 0x1A,
	messages: {
		SET_DATA_FORMAT: {
			id: 0x0020,
			req: {
				qos:              { t: 0x10, f: 'u8' },
				llp:              { t: 0x11, f: 'u32' },
				ul_protocol:      { t: 0x12, f: 'u32' },
				dl_protocol:      { t: 0x13, f: 'u32' },
				dl_max_datagrams: { t: 0x15, f: 'u32' },
				dl_max_size:      { t: 0x16, f: 'u32' },
				endpoint:         { t: 0x17, f: { type: 'u32', iface: 'u32' } },
				// Three request TLVs libqmi 1.38 does not model — its input set
				// is 0x10-0x17, 0x1B, 0x1C. They are no longer inferred from the
				// WDA spec alone: 0x18/0x19/0x1A appear in two independent vendor
				// IDL trees and in the message table of the RG650E in front of
				// us, agreeing on ids and widths.
				//
				// `dl_min_padding` is the interesting one — it decides whether
				// the modem pads downlink QMAP frames, which lands directly on
				// the rmnet aggregation the datapath layer tunes. It sits next to
				// the uplink block below by tag order alone, which once read as
				// if it were one of them; it is DOWNLINK.
				//
				// Declared, deliberately not sent. What a given modem does with
				// them is unmeasured here, and the invariant in this tree is that
				// a schema entry is cheap while a wrong request is not. Sending
				// any of them should follow a GET_SUPPORTED_FIELDS (0x001F) probe
				// on the target, not a schema line.
				qos_header_format: { t: 0x18, f: 'u8' },
				dl_min_padding:    { t: 0x19, f: 'u32' },
				flow_control:      { t: 0x1A, f: 'u8' },
				// uplink QMAP aggregation: tell the modem to expect host-batched
				// UL frames. Optional — only emitted when the caller sets them.
				ul_max_datagrams: { t: 0x1B, f: 'u32' },
				ul_max_size:      { t: 0x1C, f: 'u32' },
			},
			resp: FORMAT_FIELDS_RESP,
		},
	},
};
