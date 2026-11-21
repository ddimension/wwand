// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI Wireless Messaging Service (WMS) message schema (service 0x05).
// List/read/write/delete and send (RAW_SEND, below). TLV layouts + message ids +
// enum values verified against libqmi 1.38 data/qmi-service-wms.json and
// qmi-enums-wms.h:
//   Raw Write 0x0021, Raw Read 0x0022, Modify Tag 0x0023, Delete 0x0024,
//   List Messages 0x0031.

'use strict';

// QmiWmsStorageType — SIM card vs modem-internal store.
export const STORAGE_UIM = 0x00;   // SIM
export const STORAGE_NV  = 0x01;   // ME (modem non-volatile)

// QmiWmsMessageMode — GSM/WCDMA vs CDMA framing of the raw PDU.
export const MODE_CDMA      = 0x00;
export const MODE_GSM_WCDMA = 0x01;

// QmiWmsMessageFormat (RAW_SEND Format field; Event Report Transfer Route)
export const FORMAT_GSM_WCDMA_PP = 0x06;
export const FORMAT_GSM_WCDMA_BROADCAST = 0x07;

// QmiWmsAckIndicator: whether the host must Send Ack a transferred message
export const ACK_SEND = 0x00;

// QmiWmsMessageProtocol (Send Ack)
export const PROTOCOL_WCDMA = 0x01;

// QmiWmsMessageTagType
export const TAG_MT_READ     = 0x00;
export const TAG_MT_NOT_READ = 0x01;
export const TAG_MO_SENT     = 0x02;
export const TAG_MO_NOT_SENT = 0x03;

// Event reporting and broadcast, verified against libqmi 1.38
// qmi-service-wms.json (2026-11-19): Set Event Report 0x0001 (:30-43) and the
// Event Report indication 0x0001 (:45-116); Send Ack 0x0037 (:506-564); Set
// Broadcast Activation 0x003C (:567-586), Set/Get Broadcast Config
// 0x003D/0x003E (:589-650). The activation's second field carries its own
// "id" in the JSON but sits inside the sequence: one 2-octet TLV 0x01.
export default {
	service: 0x05,
	messages: {
		SET_EVENT_REPORT: {
			id: 0x0001,
			req:  { new_mt: { t: 0x10, f: 'u8' } },
			resp: {},
		},

		// a message stored (0x10) or handed over unstored (0x11 — a cell
		// broadcast page is Format 0x07 there, ModemManager 1.25.95
		// mm-broadband-modem-qmi.c:10970-10988)
		EVENT_REPORT_IND: {
			id: 0x0001,
			ind: {
				mt_message:     { t: 0x10, f: { storage_type: 'u8', memory_index: 'u32' } },
				transfer_route: { t: 0x11, f: { ack_indicator: 'u8', transaction_id: 'u32',
				                                format: 'u8', data: { n: 'u16', of: 'u8' } } },
				message_mode:   { t: 0x12, f: 'u8' },
			},
		},

		SEND_ACK: {
			id: 0x0037,
			req:  { info: { t: 0x01, f: { transaction_id: 'u32', protocol: 'u8', success: 'u8' } } },
			resp: {},
		},

		SET_BROADCAST_ACTIVATION: {
			id: 0x003C,
			req:  { activation: { t: 0x01, f: { mode: 'u8', activate: 'u8' } } },
			resp: {},
		},

		SET_BROADCAST_CONFIG: {
			id: 0x003D,
			req:  {
				mode:     { t: 0x01, f: 'u8' },
				channels: { t: 0x10, f: { n: 'u16', of: { start: 'u16', end: 'u16', selected: 'u8' } } },
			},
			resp: {},
		},

		GET_BROADCAST_CONFIG: {
			id: 0x003E,
			req:  { mode: { t: 0x01, f: 'u8' } },
			resp: {
				config: { t: 0x10, f: { activated: 'u8',
				                        channels: { n: 'u16', of: { start: 'u16', end: 'u16', selected: 'u8' } } } },
			},
		},

		// Send a raw PDU (SMS-SUBMIT). Verified vs libqmi wms "Raw Send" 0x0020:
		// input Raw Message Data 0x01 { Format u8, Raw Data u16-array }, GSM WCDMA
		// Link Timer 0x12 (u8) optional; output Message ID 0x01 (u16 reference).
		RAW_SEND: {
			id: 0x0020,
			req: {
				raw: { t: 0x01, f: { format: 'u8', data: { n: 'u16', of: 'u8' } } },
			},
			resp: {
				message_id: { t: 0x01, f: 'u16' },
			},
		},

		// Store a raw PDU (an SMS-DELIVER that came another way: SMS over IMS).
		// libqmi 1.38 qmi-service-wms.json "Raw Write" 0x0021: input Raw Message
		// Data 0x01 { Storage Type u8, Format u8, Raw Data u16-array }; output
		// Memory Index 0x01 (u32). It carries no tag: the RG502Q stores a
		// DELIVER as MT read (HW 2026-11-21), MODIFY_TAG makes it unread.
		RAW_WRITE: {
			id: 0x0021,
			req: {
				raw: { t: 0x01, f: { storage_type: 'u8', format: 'u8', data: { n: 'u16', of: 'u8' } } },
			},
			resp: {
				memory_index: { t: 0x01, f: 'u32' },
			},
		},

		// libqmi 1.38 "Modify Tag" 0x0023: input Message Tag 0x01 { Storage Type
		// u8, Memory Index u32, Message Tag u8 }, Message Mode 0x10 (u8)
		MODIFY_TAG: {
			id: 0x0023,
			req: {
				tag:          { t: 0x01, f: { storage_type: 'u8', memory_index: 'u32', tag: 'u8' } },
				message_mode: { t: 0x10, f: 'u8' },
			},
			resp: {},
		},

		// Read one stored message as a raw PDU. Message Mode (0x10) is mandatory
		// for GSM. Response TLV 0x01 = { tag, format, raw_data } with the PDU as a
		// u16-prefixed byte array (like uim SEND_APDU).
		RAW_READ: {
			id: 0x0022,
			req: {
				storage:      { t: 0x01, f: { storage_type: 'u8', memory_index: 'u32' } },
				message_mode: { t: 0x10, f: 'u8' },
			},
			resp: {
				raw: { t: 0x01, f: { tag: 'u8', format: 'u8', data: { n: 'u16', of: 'u8' } } },
			},
		},

		// Delete one message by index, or (index omitted) all messages of a tag.
		DELETE: {
			id: 0x0024,
			req: {
				storage:      { t: 0x01, f: 'u8' },
				memory_index: { t: 0x10, f: 'u32' },   // optional: omit to delete all of the tag
				message_tag:  { t: 0x11, f: 'u8' },     // optional
				message_mode: { t: 0x12, f: 'u8' },
			},
			resp: {},
		},

		// List stored messages. Message Tag (0x11) optional — omit to list all.
		// Response TLV 0x01 = u32-counted array of { memory_index, tag }.
		LIST_MESSAGES: {
			id: 0x0031,
			req: {
				storage_type: { t: 0x01, f: 'u8' },
				message_tag:  { t: 0x11, f: 'u8' },     // optional
				message_mode: { t: 0x12, f: 'u8' },
			},
			resp: {
				list: { t: 0x01, f: { n: 'u32', of: { memory_index: 'u32', tag: 'u8' } } },
			},
		},
	},
};
