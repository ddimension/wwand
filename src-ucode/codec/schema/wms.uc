// wwand — QMI Wireless Messaging Service (WMS) message schema (service 0x05).
// Receive/list/read/delete only (no send). TLV layouts + message ids + enum
// values verified against libqmi 1.38 data/qmi-service-wms.json and
// qmi-enums-wms.h:
//   Raw Read 0x0022, Delete 0x0024, List Messages 0x0031.

'use strict';

// QmiWmsStorageType — SIM card vs modem-internal store.
export const STORAGE_UIM = 0x00;   // SIM
export const STORAGE_NV  = 0x01;   // ME (modem non-volatile)

// QmiWmsMessageMode — GSM/WCDMA vs CDMA framing of the raw PDU.
export const MODE_CDMA      = 0x00;
export const MODE_GSM_WCDMA = 0x01;

// QmiWmsMessageTagType
export const TAG_MT_READ     = 0x00;
export const TAG_MT_NOT_READ = 0x01;
export const TAG_MO_SENT     = 0x02;
export const TAG_MO_NOT_SENT = 0x03;

export default {
	service: 0x05,
	messages: {
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
