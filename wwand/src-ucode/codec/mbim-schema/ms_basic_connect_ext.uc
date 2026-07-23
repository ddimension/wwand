// wwand — MBIM "MS Basic Connect Extensions" service schema (MBIMEx).
//
// Service UUID and CIDs verified against libmbim 1.32.0:
//   UUID  src/libmbim-glib/mbim-uuid.c uuid_ms_basic_connect_extensions =
//         { 3d 01 dc c5 } { fe f5 } { 4d 05 } { 0d 3a } { be f7 05 8e 9a af }
//         -> "3d01dcc5-fef5-4d05-0d3a-bef7058e9aaf"
//   CIDs  src/libmbim-glib/mbim-cid.h (enum MbimCidMsBasicConnectExtensions):
//         LTE_ATTACH_INFO=4, DEVICE_CAPS=6, BASE_STATIONS_INFO=11, VERSION=15,
//         REGISTRATION_PARAMETERS=17.
//
// Field layouts verified against data/mbim-service-ms-basic-connect-extensions*
// .json.  A handful of MBIMEx layouts (ms-struct / ms-struct-array, guint16
// pairs, tlv-list tails) fall outside the InformationBuffer codec vocabulary in
// codec/mbim.uc; those messages carry a custom `decode(info)` that walks the raw
// buffer here (see the header of each such command) rather than extending the
// codec.

'use strict';

import * as struct from 'struct';

export const SERVICE_UUID = '3d01dcc5-fef5-4d05-0d3a-bef7058e9aaf';
export const service = SERVICE_UUID;

// MbimDataClass bits (mbim-enums.h MbimDataClass) — carried in the register
// state / base-stations SystemType and the v2 signal SystemType.
export const DATA_CLASS_LTE    = 1 << 5;
export const DATA_CLASS_5G_NSA = 1 << 6;
export const DATA_CLASS_5G_SA  = 1 << 7;

// MbimDataSubclass bits (mbim-enums.h MbimDataSubclass) — 5G connectivity detail
export const DATA_SUBCLASS_5G_ENDC = 1 << 0;   // NR anchored on LTE (NSA)
export const DATA_SUBCLASS_5G_NR   = 1 << 1;   // NR standalone (SA)

// MbimLteAttachState
export const LTE_ATTACH_STATE_DETACHED  = 0;
export const LTE_ATTACH_STATE_ATTACHING = 1;
export const LTE_ATTACH_STATE_ATTACHED  = 2;
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

function _utf16(bytes)
{
	let out = '';

	for (let i = 0; i + 1 < length(bytes); i += 2) {
		let c = struct.unpack('<H', substr(bytes, i, 2))[0];

		if (c == 0)
			break;

		out += chr(c & 0xff);
	}

	return out;
}

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
	let o = off + 4;
	let out = [];

	for (let i = 0; i < count; i++) {
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
const F_SERVING_NR = [
	[ 'provider_id', 'str' ], [ 'nci', 'u64' ], [ 'pci', 'u32' ],
	[ 'nrarfcn', 'u32' ], [ 'tac', 'u32' ], [ 'rsrp', 'i32' ], [ 'rsrq', 'i32' ],
	[ 'sinr', 'i32' ], [ 'timing_advance', 'u64' ],
];
const F_NEIGH_NR = [
	[ 'system_sub_type', 'u32' ], [ 'provider_id', 'str' ], [ 'cell_id', 'str' ],
	[ 'pci', 'u32' ], [ 'tac', 'u32' ], [ 'rsrp', 'i32' ], [ 'rsrq', 'i32' ],
	[ 'sinr', 'i32' ],
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
export function decode_base_stations_info(info)
{
	return {
		system_type:     _u32(info, 0),
		system_sub_type: _u32(info, 4),
		lte_serving:     _read_ms_struct(info, 32, F_SERVING_LTE),
		lte_neighbors:   _read_ms_struct_array(info, 64, F_NEIGH_LTE),
		nr_serving:      _read_ms_struct_array(info, 80, F_SERVING_NR),
		nr_neighbors:    _read_ms_struct_array(info, 88, F_NEIGH_NR),
	};
}

// VERSION query/report is two guint16 (MbimVersion, MbimExtendedVersion); the
// codec has no u16 scalar, so decode the 4-byte buffer directly.
export function decode_version(info)
{
	return {
		mbim_version:          (length(info) >= 2) ? struct.unpack('<H', substr(info, 0, 2))[0] : null,
		mbim_extended_version: (length(info) >= 4) ? struct.unpack('<H', substr(info, 2, 2))[0] : null,
	};
}

export const commands = {
	// Protocol version handshake (MBIMEx v2.0+). CID 15.
	VERSION: {
		cid: 15,
		query: {},
		decode: decode_version,
	},

	// LTE attach status (CID 4). v3 response inserts NwError after LteAttachState;
	// all fields are codec-expressible (u32 + strings). Verified vs v3 JSON.
	LTE_ATTACH_INFO: {
		cid: 4,
		query: {},
		response: {
			lte_attach_state: 'u32', nw_error: 'u32', ip_type: 'u32',
			access_string: 'string', user_name: 'string', password: 'string',
			compression: 'u32', auth_protocol: 'u32',
		},
		notification: {
			lte_attach_state: 'u32', nw_error: 'u32', ip_type: 'u32',
			access_string: 'string', user_name: 'string', password: 'string',
			compression: 'u32', auth_protocol: 'u32',
		},
	},

	// Device capabilities, extensions variant (CID 6). Modeled on the v1/v2
	// layout, which is codec-expressible; the v3 layout replaces the trailing
	// fields with a guint64 DataSubclass and tlv strings (not decoded here).
	DEVICE_CAPS: {
		cid: 6,
		query: {},
		response: {
			device_type: 'u32', cellular_class: 'u32', voice_class: 'u32',
			sim_class: 'u32', data_class: 'u32', sms_caps: 'u32',
			control_caps: 'u32', max_sessions: 'u32',
			custom_data_class: 'string', device_id: 'string',
			firmware_info: 'string', hardware_info: 'string',
			executor_index: 'u32',
		},
	},

	// Base stations serving + neighbour cell info (CID 11). Query caps the count
	// per RAT; response uses ms-struct/ms-struct-array (custom decode). Verified
	// vs v3 JSON (MaxNrCount + Nr serving/neighbour arrays).
	BASE_STATIONS_INFO: {
		cid: 11,
		query: {
			max_gsm_count: 'u32', max_umts_count: 'u32', max_tdscdma_count: 'u32',
			max_lte_count: 'u32', max_cdma_count: 'u32', max_nr_count: 'u32',
		},
		decode: decode_base_stations_info,
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
