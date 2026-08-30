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
				// DOWNLINK minimum padding — grouped with the uplink block below
				// by tag order alone, which read as if it were one of them.
				// NOTE: libqmi 1.38 lists no 0x19 for Set Data Format (its input
				// set is 0x10-0x17, 0x1B, 0x1C), so this tag is from the QMI WDA
				// spec rather than verified against a binding. Nothing sets it
				// today; if something ever does, that is the moment to check it
				// on hardware.
				dl_min_padding:   { t: 0x19, f: 'u32' },
				// uplink QMAP aggregation: tell the modem to expect host-batched
				// UL frames. Optional — only emitted when the caller sets them.
				ul_max_datagrams: { t: 0x1B, f: 'u32' },
				ul_max_size:      { t: 0x1C, f: 'u32' },
			},
			resp: FORMAT_FIELDS_RESP,
		},
	},
};
