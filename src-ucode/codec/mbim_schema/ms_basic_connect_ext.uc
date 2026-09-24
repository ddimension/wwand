// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — MBIM "MS Basic Connect Extensions" service schema (MBIMEx).
//
// Service UUID and CIDs verified against libmbim 1.32.0:
//   UUID  src/libmbim-glib/mbim-uuid.c uuid_ms_basic_connect_extensions =
//         { 3d 01 dc c5 } { fe f5 } { 4d 05 } { 0d 3a } { be f7 05 8e 9a af }
//         -> "3d01dcc5-fef5-4d05-0d3a-bef7058e9aaf"
//   CIDs  src/libmbim-glib/mbim-cid.h (enum MbimCidMsBasicConnectExtensions):
//         LTE_ATTACH_CONFIGURATION=3, LTE_ATTACH_INFO=4, SYS_CAPS=5,
//         DEVICE_CAPS=6, DEVICE_SLOT_MAPPINGS=7, SLOT_INFO_STATUS=8,
//         BASE_STATIONS_INFO=11, VERSION=15, REGISTRATION_PARAMETERS=17.
//
// Field layouts verified against data/mbim-service-ms-basic-connect-extensions*
// .json.  A handful of MBIMEx layouts (ms-struct / ms-struct-array, guint16
// pairs, tlv-list tails) fall outside the InformationBuffer codec vocabulary in
// codec/mbim.uc; those messages carry a custom `decode(info)` that walks the raw
// buffer here (see the header of each such command) rather than extending the
// codec.

'use strict';

import * as struct from 'struct';
import * as mbimcodec from 'wwand.codec.mbim';
import { utf16le_encode, utf16le_decode, mbimex_v3 } from 'wwand.codec.mbim';

export const SERVICE_UUID = '3d01dcc5-fef5-4d05-0d3a-bef7058e9aaf';
export const service = SERVICE_UUID;

// MbimDataClass bits (mbim-enums.h MbimDataClass) — carried in the register
// state / base-stations SystemType and the v2 signal SystemType.
export const DATA_CLASS_LTE    = 1 << 5;
export const DATA_CLASS_5G_NSA = 1 << 6;
export const DATA_CLASS_5G_SA  = 1 << 7;
// ...and the one that means "I am not going to tell you": CUSTOM is libmbim's
// spelling for a class that is proprietary or simply not in the enum, and a
// modem that reports it ALONE has said nothing about its RAT. Field-seen on a
// Quectel RM520F-GL carrying NR5G-SA traffic while reporting exactly
// 0x80000000 (ddimension/wwand#30).
export const DATA_CLASS_CUSTOM = 1 << 31;

// MbimDataSubclass bits (mbim-enums.h MbimDataSubclass) — 5G connectivity detail
export const DATA_SUBCLASS_5G_ENDC = 1 << 0;   // NR anchored on LTE (NSA)
export const DATA_SUBCLASS_5G_NR   = 1 << 1;   // NR standalone (SA)

// MbimLteAttachState
// MbimLteAttachState has TWO values, not three (libmbim 1.32.0, mbim-enums.h
// :1424-1425). An ATTACHING=1 / ATTACHED=2 triple sat here from b2d8176 — the
// same commit that carried the wrong LTE_ATTACH_INFO layout, and the same kind
// of mistake: written from what the states ought to be rather than read off the
// spec. Nothing used it, so nothing broke; a modem reporting the real ATTACHED
// (1) would have read as "attaching" and never as attached.
export const LTE_ATTACH_STATE_DETACHED = 0;
export const LTE_ATTACH_STATE_ATTACHED = 1;

export const LTE_ATTACH_STATE = {
	'0': 'detached',
	'1': 'attached',
};
export const LTE_ATTACH_STATE_DETACHING = 3;

// --- raw-buffer readers (for the ms-struct / ms-struct-array layouts) --------
// MBIMEx variable structs pack a fixed part followed by any string data, with
// string offsets taken RELATIVE TO THE STRUCT START.  ms-struct is an
// [offset,size] pointer to one such struct; ms-struct-array is an [offset,size]
// pointer to a [count][elem0..elemN] region where each element is self-sized.
// Verified against the generated readers in
// openwrt-build/src/libmbim-glib/generated/mbim-ms-basic-connect-extensions.c
// (_mbim_message_read_*_ms_struct / _ms_struct_array).

function _u32(buf, p) { return (p + 4 <= length(buf)) ? struct.unpack('<I', substr(buf, p, 4))[0] : 0; }
function _i32(buf, p) { return (p + 4 <= length(buf)) ? struct.unpack('<i', substr(buf, p, 4))[0] : 0; }
function _u64(buf, p) { return (p + 8 <= length(buf)) ? struct.unpack('<Q', substr(buf, p, 8))[0] : 0; }

// UTF-16LE decode shared with the codec (codec/mbim.uc)
const _utf16 = utf16le_decode;

// Read one MBIMEx variable struct at absolute offset `base`, driven by an
// ordered field list of [name, fmt] where fmt is 'u32' | 'i32' | 'u64' | 'str'.
// Returns [ obj, consumed ] — consumed is the struct's total size (fixed part
// plus any appended, 4-byte-padded string data) so callers can walk arrays.
function _read_struct(buf, base, fields)
{
	let res = {};
	let o = base;
	let data_end = 0;

	for (let fd in fields) {
		let name = fd[0], fmt = fd[1];

		if (fmt == 'str') {
			let soff = _u32(buf, o), slen = _u32(buf, o + 4);
			o += 8;

			if (slen > 0 && base + soff + slen <= length(buf)) {
				res[name] = _utf16(substr(buf, base + soff, slen));

				let end = soff + slen;
				end += (4 - (end % 4)) % 4;

				if (end > data_end)
					data_end = end;
			}
			else {
				res[name] = '';
			}
		}
		else if (fmt == 'u64') { res[name] = _u64(buf, o); o += 8; }
		else if (fmt == 'i32') { res[name] = _i32(buf, o); o += 4; }
		else                   { res[name] = _u32(buf, o); o += 4; }
	}

	let fixed = o - base;
	let total = (data_end > fixed) ? data_end : fixed;
	total += (4 - (total % 4)) % 4;

	return [ res, total ];
}

// ms-struct pointer at `pos` -> single struct (or null)
function _read_ms_struct(buf, pos, fields)
{
	let off = _u32(buf, pos);

	if (off == 0 || off >= length(buf))
		return null;

	return _read_struct(buf, off, fields)[0];
}

// ms-struct-array pointer at `pos` -> [ elem, ... ]
function _read_ms_struct_array(buf, pos, fields)
{
	let off = _u32(buf, pos);

	if (off == 0 || off + 4 > length(buf))
		return [];

	let count = _u32(buf, off);
	let len = length(buf);
	let o = off + 4;
	let out = [];

	// hard bound: `count` is read straight off the modem buffer; a malformed
	// BASE_STATIONS_INFO/cell payload can carry a garbage count that would loop
	// building null-structs until OOM. Each struct advances `o` by its fixed
	// span, so stopping once `o` leaves the buffer caps iterations to the real
	// element capacity. (This decodes serving/neighbour cells on the native-MBIM
	// path — first-choice telemetry on HW we cannot host-validate.)
	for (let i = 0; i < count && o < len; i++) {
		let r = _read_struct(buf, o, fields);
		push(out, r[0]);
		o += r[1];
	}

	return out;
}

// MbimCellInfo* struct field layouts (order + type), from the v3 JSON.
const F_SERVING_LTE = [
	[ 'provider_id', 'str' ], [ 'cell_id', 'u32' ], [ 'earfcn', 'u32' ],
	[ 'pci', 'u32' ], [ 'tac', 'u32' ], [ 'rsrp', 'i32' ], [ 'rsrq', 'i32' ],
	[ 'timing_advance', 'u32' ],
];
const F_NEIGH_LTE = [
	[ 'provider_id', 'str' ], [ 'cell_id', 'u32' ], [ 'earfcn', 'u32' ],
	[ 'pci', 'u32' ], [ 'tac', 'u32' ], [ 'rsrp', 'i32' ], [ 'rsrq', 'i32' ],
];
// NR metrics are UNSIGNED here, and that is not a detail: they are coded
// indices, not dB (see nr_metric in mbim_backend.uc). Reading them signed also
// destroys the unknown marker, which is 0xFFFFFFFF (libmbim 1.32.0,
// mbimcli-ms-basic-connect-extensions.c:1214-1219,1410-1412). LTE's stay signed
// — those really are dBm/dB, with the marker cast to -1 (:1207-1212,1346-1347).
const F_SERVING_NR = [
	[ 'provider_id', 'str' ], [ 'nci', 'u64' ], [ 'pci', 'u32' ],
	[ 'nrarfcn', 'u32' ], [ 'tac', 'u32' ], [ 'rsrp', 'u32' ], [ 'rsrq', 'u32' ],
	[ 'sinr', 'u32' ], [ 'timing_advance', 'u64' ],
];
const F_NEIGH_NR = [
	[ 'system_sub_type', 'u32' ], [ 'provider_id', 'str' ], [ 'cell_id', 'str' ],
	[ 'pci', 'u32' ], [ 'tac', 'u32' ], [ 'rsrp', 'u32' ], [ 'rsrq', 'u32' ],
	[ 'sinr', 'u32' ],
];

// Base Stations Info (v3) response fixed part — 2 scalars then a run of 8-byte
// ms-struct / ms-struct-array pointers, in this order (verified against the
// generated v3 parser):
//   0  SystemType(u32) 4 SystemSubType(u32)
//   8  GsmServingCell 16 UmtsServingCell 24 TdscdmaServingCell 32 LteServingCell
//  40  Gsm/48 Umts/56 Tdscdma/64 Lte neighboring arrays 72 CdmaCells
//  80  NrServingCells 88 NrNeighborCells
// Only the LTE + NR cells are decoded (the metrics wwand surfaces); the other
// RATs are skipped by advancing past their pointers.
// v1 HAS NO SystemSubType, so every pointer after it sits 4 bytes earlier and
// there are no NR arrays at all (libmbim 1.32.0, mbim-service-ms-basic-connect-
// extensions.json: SystemType, 4 serving ms-structs, 5 array pointers; the v3
// file adds SystemSubType and the two NR arrays). Decoding a v1 answer with the
// v3 offsets does not fail — the bounds checks absorb it — it publishes
// FABRICATED serving-cell PCI/TAC/RSRP. Which layout applies is settled by the
// version handshake at mbim_client.uc open(); a modem that refused it is v1.
export function decode_base_stations_info(info, mc)
{
	if (!mbimex_v3(mc))
		return {
			system_type:     _u32(info, 0),
			system_sub_type: null,
			lte_serving:     _read_ms_struct(info, 28, F_SERVING_LTE),
			lte_neighbors:   _read_ms_struct_array(info, 60, F_NEIGH_LTE),
			nr_serving:      [],
			nr_neighbors:    [],
		};

	return {
		system_type:     _u32(info, 0),
		system_sub_type: _u32(info, 4),
		lte_serving:     _read_ms_struct(info, 32, F_SERVING_LTE),
		lte_neighbors:   _read_ms_struct_array(info, 64, F_NEIGH_LTE),
		nr_serving:      _read_ms_struct_array(info, 80, F_SERVING_NR),
		nr_neighbors:    _read_ms_struct_array(info, 88, F_NEIGH_NR),
	};
};

// MbimUiccSlotState (mbim-enums.h, since 1.26) — carried by SLOT_INFO_STATUS.
export const UICC_SLOT_STATE_UNKNOWN                 = 0;
export const UICC_SLOT_STATE_OFF_EMPTY               = 1;
export const UICC_SLOT_STATE_OFF                     = 2;
export const UICC_SLOT_STATE_EMPTY                   = 3;
export const UICC_SLOT_STATE_NOT_READY               = 4;
export const UICC_SLOT_STATE_ACTIVE                  = 5;
export const UICC_SLOT_STATE_ERROR                   = 6;
export const UICC_SLOT_STATE_ACTIVE_ESIM             = 7;
export const UICC_SLOT_STATE_ACTIVE_ESIM_NO_PROFILES = 8;

// ...and their names, for the log. A slot indication that reads "state 3" makes
// the reader look the number up; "empty" does not. Numeric keys are quoted
// because a bare one is a ucode parse error, and looked up with sprintf('%d').
export const UICC_SLOT_STATE_NAMES = {
	'0': 'unknown', '1': 'off, empty', '2': 'off', '3': 'empty',
	'4': 'not ready', '5': 'active', '6': 'error',
	'7': 'active eSIM', '8': 'active eSIM, no profiles',
};

// Device Slot Mappings response: MapCount, then a ref-struct-array of MbimSlot —
// MapCount × [offset(u32), size(u32)] pairs (offsets relative to the
// InformationBuffer start) with each 4-byte struct in the data region. Returns
// { slots: [ slot_index_of_executor_0, ... ] }. Verified against the generated
// _mbim_message_read_mbim_slot_ref_struct_array in libmbim 1.32.
export function decode_device_slot_mappings(info)
{
	let count = _u32(info, 0);
	let out = [];

	for (let i = 0; i < count && 4 + 8 * i + 8 <= length(info); i++) {
		let off = _u32(info, 4 + 8 * i);
		let len = _u32(info, 4 + 8 * i + 4);

		push(out, (len >= 4 && off + 4 <= length(info)) ? _u32(info, off) : null);
	}

	return { slots: out };
};

// VERSION query/report is two guint16 (MbimVersion, MbimExtendedVersion); the
// codec has no u16 scalar, so decode the 4-byte buffer directly.
export function decode_version(info)
{
	return {
		mbim_version:          (length(info) >= 2) ? struct.unpack('<H', substr(info, 0, 2))[0] : null,
		mbim_extended_version: (length(info) >= 4) ? struct.unpack('<H', substr(info, 2, 2))[0] : null,
	};
};

// MbimMsLteAttachContextRoamingControl — one attach context per roaming
// condition; a Set must carry exactly these three.
export const ROAMING_HOME        = 0;
export const ROAMING_PARTNER     = 1;
export const ROAMING_NON_PARTNER = 2;

// MbimMsContextSource — creation source; the OS/admin-configured attach APN is
// tagged Admin (modem-preconfigured defaults come back tagged ModemProvisioned).
export const CONTEXT_SOURCE_ADMIN             = 0;
export const CONTEXT_SOURCE_MODEM_PROVISIONED = 3;

// MbimMsLteAttachContextOperation for the Set.
export const ATTACH_OP_DEFAULT         = 0;   // overwrite all three roaming contexts
export const ATTACH_OP_RESTORE_FACTORY = 1;

// --- LTE attach context (CID 3) encode/decode --------------------------------
// MBIM_MS_LTE_ATTACH_CONTEXT: 44-byte fixed head then 4-byte-padded UTF-16LE
// strings, string offsets relative to the struct start (matches _read_struct's
// base-relative 'str' handling). Field order verified vs MS-Learn
// "MB LTE Attach Operations" and libmbim mbim-service-ms-basic-connect-ext JSON:
//   IPType, Roaming, Source, Access[off,size], User[off,size], Pass[off,size],
//   Compression, AuthProtocol.
const F_LTE_ATTACH_CTX = [
	[ 'ip_type', 'u32' ], [ 'roaming', 'u32' ], [ 'source', 'u32' ],
	[ 'access_string', 'str' ], [ 'user_name', 'str' ], [ 'password', 'str' ],
	[ 'compression', 'u32' ], [ 'auth_protocol', 'u32' ],
];

// UTF-16LE encoder shared with the codec (codec/mbim.uc); null-tolerant wrap
const _utf16le = (s) => utf16le_encode(s ?? '');

function _pad4enc(s)
{
	for (let need = (4 - length(s) % 4) % 4; need > 0; need--)
		s += '\x00';

	return s;
}

// one MBIM_MS_LTE_ATTACH_CONTEXT (self-sized): 11×u32 head + padded strings.
function _encode_attach_context(c)
{
	let astr = _utf16le(c.access_string ?? '');
	let ustr = _utf16le(c.user_name ?? '');
	let pstr = _utf16le(c.password ?? '');

	let HEAD = 44;
	let ao = length(astr) ? HEAD : 0;
	let uo = length(ustr) ? (HEAD + length(_pad4enc(astr))) : 0;
	let po = length(pstr) ? (HEAD + length(_pad4enc(astr)) + length(_pad4enc(ustr))) : 0;

	let head = struct.pack('<IIIIIIIIIII',
		c.ip_type ?? 0, c.roaming ?? 0, c.source ?? 0,
		ao, length(astr), uo, length(ustr), po, length(pstr),
		c.compression ?? 0, c.auth_protocol ?? 0);

	return head + _pad4enc(astr) + _pad4enc(ustr) + _pad4enc(pstr);
}

// MBIM_MS_SET_LTE_ATTACH_CONFIG: Operation(u32), ElementCount(u32), then EC
// [offset,size] ref pairs (offsets from the information-buffer start), then the context
// structs. Built raw because the codec has no ms-struct-array encode path.
export function encode_set_lte_attach_config(contexts, operation)
{
	let ec = length(contexts);
	let cur = 8 + 8 * ec;          // header: op + ec + EC ref pairs
	let pairs = '';
	let data = '';

	for (let c in contexts) {
		let enc = _encode_attach_context(c);
		pairs += struct.pack('<II', cur, length(enc));
		data += enc;
		cur += length(enc);
	}

	return struct.pack('<II', operation ?? ATTACH_OP_DEFAULT, ec) + pairs + data;
};

// MBIM_MS_LTE_ATTACH_CONFIG_INFO (Query + Set response): ElementCount(u32) then
// EC [offset,size] ref pairs (offsets from buffer start) into the context array.
export function decode_lte_attach_config(info)
{
	let ec = _u32(info, 0);
	let out = [];

	for (let i = 0; i < ec && 4 + 8 * i + 8 <= length(info); i++) {
		let off = _u32(info, 4 + 8 * i);

		if (off > 0 && off + 44 <= length(info))
			push(out, _read_struct(info, off, F_LTE_ATTACH_CTX)[0]);
	}

	return { contexts: out };
};

// Vocabulary for the two v3 diagnostics (libmbim 1.32.0, mbim-enums.h:
// MbimModemConfigurationStatus, MbimWakeType). Numeric object keys are a parse
// error in ucode, hence the quoted decimal strings.
export const MODEM_CONFIG_STATUS = {
	'0': 'unknown',
	'1': 'started',
	'2': 'completed',
};

export const WAKE_TYPE = {
	'0': 'cid response',
	'1': 'cid indication',
	'2': 'packet',
};

// Extended DEVICE_CAPS comes in two shapes; see the note at the command.
const CAPS_V1 = {
	device_type: 'u32', cellular_class: 'u32', voice_class: 'u32',
	sim_class: 'u32', data_class: 'u32', sms_caps: 'u32',
	control_caps: 'u32', max_sessions: 'u32',
	custom_data_class: 'string', device_id: 'string',
	firmware_info: 'string', hardware_info: 'string',
	executor_index: 'u32',
};

// ...and v3 is not merely reordered, it changes KIND partway through. Only the
// first eleven fields are inline; everything from LteBandClass on is a TLV, and
// the four strings are tlv-string rather than the v1 offset/length pairs
// (libmbim 1.32.0, extensions-v3.json: `tlv-guint16-array`, `tlv-string`).
// DataSubclass is a guint64 here — note it is a guint32 in Packet Service, the
// same name at two widths in two messages, which is exactly the kind of detail
// a from-memory schema gets wrong.
const CAPS_V3_FIXED = {
	device_type: 'u32', cellular_class: 'u32', voice_class: 'u32',
	sim_class: 'u32', data_class: 'u32', sms_caps: 'u32',
	control_caps: 'u32', data_subclass: 'u64', max_sessions: 'u32',
	executor_index: 'u32', wcdma_band_class: 'u32',
};

// 7 * u32 + u64 + 3 * u32
const CAPS_V3_FIXED_LEN = 48;

// a UINT16_TBL payload is a bare sequence of guint16
function u16_table(data)
{
	if (data == null)
		return null;

	let out = [];

	for (let i = 0; i + 2 <= length(data); i += 2)
		push(out, struct.unpack('<H', substr(data, i, 2))[0]);

	return out;
}

function decode_caps_v3(info)
{
	let out = mbimcodec.decode_info(CAPS_V3_FIXED, info) ?? {};
	let tlvs = mbimcodec.decode_tlvs(info, CAPS_V3_FIXED_LEN);

	// POSITIONAL, with the type checked at each position — which is what
	// libmbim does: `_mbim_message_read_tlv_string` reads the TLV AT the given
	// offset and advances by its size, and the type check lives in
	// `mbim_tlv_string_get` (mbim-message.c:1109-1133, 1.32.0). None of these
	// fields is optional there; an empty value is still carried as a TLV.
	//
	// The tempting alternative — collect by type and take them in order — fails
	// quietly on a firmware that omits one: every later field shifts up by one
	// and `device_id` comes back holding the firmware string. A decode that
	// lies is worse than one that stops, so a position whose type does not
	// match ends the walk and leaves the rest null.
	const ORDER = [
		[ 'lte_band_class',    mbimcodec.TLV_UINT16_TBL ],
		[ 'nr_band_class',     mbimcodec.TLV_UINT16_TBL ],
		[ 'custom_data_class', mbimcodec.TLV_WCHAR_STR ],
		[ 'device_id',         mbimcodec.TLV_WCHAR_STR ],
		[ 'firmware_info',     mbimcodec.TLV_WCHAR_STR ],
		[ 'hardware_info',     mbimcodec.TLV_WCHAR_STR ],
	];

	for (let i = 0; i < length(ORDER); i++) {
		let t = tlvs[i];

		if (t == null || t.type != ORDER[i][1])
			break;

		out[ORDER[i][0]] = (ORDER[i][1] == mbimcodec.TLV_UINT16_TBL)
			? u16_table(t.data) : utf16le_decode(t.data);
	}

	return out;
}

// LTE Attach Info comes in two shapes; see the note at the command.
const ATTACH_V1 = {
	lte_attach_state: 'u32', ip_type: 'u32',
	access_string: 'string', user_name: 'string', password: 'string',
	compression: 'u32', auth_protocol: 'u32',
};

const ATTACH_V3 = {
	lte_attach_state: 'u32', nw_error: 'u32', ip_type: 'u32',
	access_string: 'string', user_name: 'string', password: 'string',
	compression: 'u32', auth_protocol: 'u32',
};

function attach_fields(mc)
{
	return mbimex_v3(mc) ? ATTACH_V3 : ATTACH_V1;
}

export const commands = {
	// Default LTE attach context of the inserted SIM's provider (CID 3, MBIMEx).
	// Query returns the three roaming contexts (home/partner/non-partner); the
	// Set (exactly three) is built raw in mbim_backend.set_lte_attach_config —
	// the codec encode has no ms-struct-array vocabulary. Both answer with
	// MBIM_MS_LTE_ATTACH_CONFIG_INFO -> decode_lte_attach_config.
	LTE_ATTACH_CONFIG: {
		cid: 3,
		query: {},
		decode: decode_lte_attach_config,
	},

	// Protocol version handshake (MBIMEx v2.0+). CID 15.
	VERSION: {
		cid: 15,
		query: {},
		decode: decode_version,
	},

	// LTE attach status (CID 4). v3 response inserts NwError after LteAttachState;
	// all fields are codec-expressible (u32 + strings). Verified vs v3 JSON.
	// LTE attach state and the profile the modem attached with (CID 4).
	//
	// v3 INSERTS NwError after LteAttachState — it does not append it (libmbim
	// 1.32.0, mbim-service-ms-basic-connect-extensions-v3.json vs the v1 file,
	// checked 2026-09-20). So the layouts differ from the second field on, and
	// everything after shifts by four bytes: read a v1 answer with the v3 spec
	// and `nw_error` takes IpType, `ip_type` takes the AccessString OFFSET, and
	// the APN comes back wrong or null. That is not hypothetical — this entry
	// carried the v3 layout unconditionally from b2d8176 until now, and was
	// only harmless because nothing called it.
	//
	// The addition is worth having: NwError is the 3GPP cause for a REFUSED
	// attach, in the attach message itself. wwand otherwise reconstructs that
	// from QMI system info plus AT+CEER (regdetail.uc).
	LTE_ATTACH_INFO: {
		cid: 4,
		query: {},
		response: ATTACH_V1,
		notification: ATTACH_V1,
		response_for: attach_fields,
		decode: (info, mc) => mbimcodec.decode_info(attach_fields(mc), info),
	},

	// System capabilities (CID 5): executor / SIM-slot counts. Verified vs the
	// 1.26 JSON (NumberOfExecutors, NumberOfSlots, Concurrency, ModemId).
	SYS_CAPS: {
		cid: 5,
		query: {},
		response: {
			number_of_executors: 'u32', number_of_slots: 'u32',
			concurrency: 'u32', modem_id: 'u64',
		},
	},

	// Executor→slot mapping (CID 7). Response needs the ref-struct-array decode
	// above; the SET (slot switch) is built raw in mbim_backend.slot_switch
	// (the codec's encode path has no array vocabulary).
	DEVICE_SLOT_MAPPINGS: {
		cid: 7,
		query: {},
		decode: decode_device_slot_mappings,
	},

	// Per-slot UICC state (CID 8). State is MbimUiccSlotState (consts above).
	SLOT_INFO_STATUS: {
		cid: 8,
		query: { slot_index: 'u32' },
		response: { slot_index: 'u32', state: 'u32' },
		notification: { slot_index: 'u32', state: 'u32' },
	},

	// Device capabilities, extensions variant (CID 6). Modeled on the v1/v2
	// layout, which is codec-expressible; the v3 layout replaces the trailing
	// fields with a guint64 DataSubclass and tlv strings (not decoded here).
	// Extended device caps (CID 6) — NOT the basic-connect DEVICE_CAPS (CID 1),
	// which v3 leaves alone and which is the one modem_mbim actually queries.
	//
	// v3 REORDERS this one: DataSubclass is inserted after ControlCaps, and
	// ExecutorIndex plus three band-class fields move AHEAD of the strings
	// (libmbim 1.32.0, extensions-v3.json vs the v1 file, checked 2026-09-20):
	//
	//   v1:  … ControlCaps, MaxSessions, [strings], ExecutorIndex
	//   v3:  … ControlCaps, DataSubclass, MaxSessions, ExecutorIndex,
	//           WcdmaBandClass, LteBandClass, NrBandClass, [strings]
	//
	// Same failure shape as SUBSCRIBER_READY_STATUS: a positional fixed part,
	// shifted offsets, and a decode that yields plausible nonsense rather than
	// an error. The v1 layout sat here unconditionally and was harmless only
	// because nothing called it — which is the worst way for a schema to be
	// right. The band classes are the reason somebody eventually will: they say
	// what the radio can do per RAT without asking AT.
	DEVICE_CAPS: {
		cid: 6,
		query: {},
		response: CAPS_V1,
		decode: (info, mc) => mbimex_v3(mc)
			? decode_caps_v3(info)
			: mbimcodec.decode_info(CAPS_V1, info),
	},

	// Base stations serving + neighbour cell info (CID 11). Query caps the count
	// per RAT; response uses ms-struct/ms-struct-array (custom decode). Verified
	// vs v3 JSON (MaxNrCount + Nr serving/neighbour arrays).
	BASE_STATIONS_INFO: {
		cid: 11,
		// v1 takes FIVE counts; MaxNrCount is a v3 addition. A field spec given
		// as a function is resolved against the client (mbim_client.uc), so the
		// negotiated version decides both halves of this command.
		query: (mc) => mbimex_v3(mc)
			? {
				max_gsm_count: 'u32', max_umts_count: 'u32', max_tdscdma_count: 'u32',
				max_lte_count: 'u32', max_cdma_count: 'u32', max_nr_count: 'u32',
			}
			: {
				max_gsm_count: 'u32', max_umts_count: 'u32', max_tdscdma_count: 'u32',
				max_lte_count: 'u32', max_cdma_count: 'u32',
			},
		decode: decode_base_stations_info,
	},

	// Carrier configuration status (CID 16, MBIMEx v3.0). The MBIM counterpart
	// of what hwops.uc reads over QMI PDC — and reachable on a modem with no
	// PDC service at all, which is the point. The notification is the half
	// worth having: a configuration switch announces itself instead of being
	// polled for.
	//
	// The name is a WCHAR_STR TLV, not an offset/length string, so the whole
	// response needs a custom decode.
	MODEM_CONFIGURATION: {
		cid: 16,
		query: {},
		decode: (info) => {
			let st = mbimcodec.decode_info({ configuration_status: 'u32' }, info);
			let tlvs = mbimcodec.decode_tlvs(info, 4);

			return {
				configuration_status: st?.configuration_status,
				configuration_name: mbimcodec.tlv_string(tlvs),
				ies: length(tlvs),
			};
		},
	},

	// Why the modem woke the host (CID 19, MBIMEx v3.0). WakeType says whether
	// it was a CID response, a CID indication or a data packet; SessionId names
	// the session for the packet case. The trailing TLV carries the detail and
	// its meaning depends on the type, so it is handed back as raw bytes rather
	// than guessed at.
	//
	// This is the missing half of the lowpower work: after a wake, the daemon
	// currently cannot tell data from paging from a vendor event.
	WAKE_REASON: {
		cid: 19,
		query: {},
		decode: (info) => {
			let fixed = mbimcodec.decode_info(
				{ wake_type: 'u32', session_id: 'u32' }, info);
			let tlvs = mbimcodec.decode_tlvs(info, 8);

			return {
				wake_type: fixed?.wake_type,
				session_id: fixed?.session_id,
				wake_tlv_type: tlvs[0]?.type,
				// the one type worth naming here: a wake carrying a TAI says
				// which tracking area the paging came from
				wake_tlv_tai: (tlvs[0]?.type == mbimcodec.TLV_TAI),
				wake_tlv_len: length(tlvs[0]?.data ?? ''),
			};
		},
	},

	// 5G registration parameters (CID 17, MBIMEx v3.0). Only the fixed leading
	// guint32 fields are decoded; the trailing UnnamedIes tlv-list is dropped
	// (not codec-expressible, not consumed). Verified vs v3 JSON.
	REGISTRATION_PARAMETERS: {
		cid: 17,
		query: {},
		response: {
			mico_mode: 'u32', drx_cycle: 'u32', ladn_info: 'u32',
			default_pdu_activation_hint: 'u32', re_register_if_needed: 'u32',
		},
	},
};

export default commands;
