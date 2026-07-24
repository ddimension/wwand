// wwand tests — QMI WMS schema (codec/schema/wms.uc) wire layout.
//
// Drives the real TLV codec against the WMS message specs with hand-built bytes
// in the on-the-wire layout, so a wrong TLV id / format (the libqmi invariant)
// fails the assertion. No re-encode of a decoded object.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as struct from 'struct';
import * as tlv from 'wwand/codec/tlv.uc';
import * as wms from 'wwand/codec/schema/wms.uc';

function u8(v)  { return chr(v & 0xff); }
function u16(v) { return struct.pack('<H', v); }
function u32(v) { return struct.pack('<I', v); }
function tb(t, v) { return chr(t) + struct.pack('<H', length(v)) + v; }
function tohex(s) { let o = ''; for (let i = 0; i < length(s); i++) o += sprintf('%02x', ord(s, i)); return o; }

let M = wms.default.messages;

// --- constants sanity (verified vs qmi-enums-wms.h) -------------------------
eq(wms.default.service, 0x05, 'wms service id 0x05');
eq(M.RAW_READ.id, 0x0022, 'RAW_READ id 0x0022');
eq(M.DELETE.id, 0x0024, 'DELETE id 0x0024');
eq(M.LIST_MESSAGES.id, 0x0031, 'LIST_MESSAGES id 0x0031');
eq(wms.STORAGE_UIM, 0, 'STORAGE_UIM=0 (SIM)');
eq(wms.STORAGE_NV, 1, 'STORAGE_NV=1 (ME)');
eq(wms.MODE_GSM_WCDMA, 1, 'MODE_GSM_WCDMA=1');

// --- RAW_READ request pack: TLV 0x01 {u8 storage,u32 index} + TLV 0x10 mode --
let rr = tlv.pack(M.RAW_READ.req, {
	storage: { storage_type: wms.STORAGE_UIM, memory_index: 5 },
	message_mode: wms.MODE_GSM_WCDMA,
});
eq(tohex(rr),
	tohex(tb(0x01, u8(0) + u32(5)) + tb(0x10, u8(1))),
	'RAW_READ req: storage seq (0x01) + mode (0x10)');

// --- RAW_READ response unpack: 0x01 = {tag, format, u16-len raw pdu} ---------
let pdu = u8(0x07) + u8(0x91) + u8(0xAB);     // 3 arbitrary PDU bytes
let rresp = tlv.unpack(M.RAW_READ.resp, tb(0x01, u8(0) + u8(6) + u16(3) + pdu));
eq(rresp.raw.tag, 0, 'RAW_READ resp: tag');
eq(rresp.raw.format, 6, 'RAW_READ resp: format (GSM/WCDMA P2P)');
eq(rresp.raw.data, [ 0x07, 0x91, 0xAB ], 'RAW_READ resp: raw PDU byte array (u16-prefixed)');

// --- LIST_MESSAGES response unpack: 0x01 = u32 count + {u32 idx, u8 tag}[] ---
let lresp = tlv.unpack(M.LIST_MESSAGES.resp,
	tb(0x01, u32(2) + u32(3) + u8(wms.TAG_MT_READ) + u32(7) + u8(wms.TAG_MT_NOT_READ)));
eq(length(lresp.list), 2, 'LIST resp: two entries (u32 count)');
eq(lresp.list[0].memory_index, 3, 'LIST resp: entry0 index');
eq(lresp.list[0].tag, 0, 'LIST resp: entry0 tag read');
eq(lresp.list[1].memory_index, 7, 'LIST resp: entry1 index');
eq(lresp.list[1].tag, 1, 'LIST resp: entry1 tag unread');

// --- LIST_MESSAGES request: tag optional (omitted -> lists all) --------------
let lreq_all = tlv.pack(M.LIST_MESSAGES.req, { storage_type: wms.STORAGE_UIM, message_mode: 1 });
eq(tohex(lreq_all), tohex(tb(0x01, u8(0)) + tb(0x12, u8(1))),
	'LIST req: omitting message_tag drops TLV 0x11 (list all)');

// --- DELETE request: by index (tag omitted) ---------------------------------
let del = tlv.pack(M.DELETE.req, {
	storage: wms.STORAGE_UIM, memory_index: 5, message_mode: wms.MODE_GSM_WCDMA,
});
eq(tohex(del), tohex(tb(0x01, u8(0)) + tb(0x10, u32(5)) + tb(0x12, u8(1))),
	'DELETE req: storage(0x01)+index(0x10)+mode(0x12), tag omitted');

done('test_wms');
