// wwand — schema-driven QMI TLV codec.
//
// Field spec:      { argname: { t: <tlv type>, f: FORMAT }, ... }
// FORMAT is either a primitive name:
//   u8 i8 u16 i16 u32 i32 u64 i64   (little-endian, as everywhere in QMI)
//   string   raw bytes filling the rest of the enclosing TLV/struct tail
//   bytes    like string, but semantically opaque binary
//   lstring  u8 length-prefixed string (e.g. DMS PIN values)
//   ipv4     u32 whose MSB is the first octet (libqmi convention), "a.b.c.d"
//   ipv6     16 bytes in network order, "xxxx:xxxx:...:xxxx" (no :: compression)
// or an ordered struct: { member: FORMAT, ... }
// or an array:          { n: 'u8'|'u16', of: FORMAT }
//
// unpack() never throws on malformed input: unknown TLVs land in _raw,
// overrunning TLVs set _truncated, the mandatory result TLV (0x02) is always
// decoded into _result = { result, error }.

'use strict';

import * as struct from 'struct';

const prim_fmt = {
	u8:  '<B', i8:  '<b',
	u16: '<H', i16: '<h',
	u32: '<I', i32: '<i',
	u64: '<Q', i64: '<q',
	f32: '<f', f64: '<d',
};

const prim_size = {
	u8: 1, i8: 1, u16: 2, i16: 2, u32: 4, i32: 4, u64: 8, i64: 8,
	f32: 4, f64: 8,
};

function pack_prim(fmt, v)
{
	return struct.pack(prim_fmt[fmt], v ?? 0);
}

function unpack_prim(fmt, buf, pos)
{
	let sz = prim_size[fmt];

	if (pos + sz > length(buf))
		return null;

	return [ struct.unpack(prim_fmt[fmt], substr(buf, pos, sz))[0], pos + sz ];
}

function pack_ipv4(v)
{
	let o = split(v ?? '0.0.0.0', '.');
	let n = ((+o[0] & 0xff) << 24) | ((+o[1] & 0xff) << 16) |
	        ((+o[2] & 0xff) << 8)  |  (+o[3] & 0xff);

	return struct.pack('<I', n);
}

function unpack_ipv4(buf, pos)
{
	let r = unpack_prim('u32', buf, pos);

	if (!r)
		return null;

	let n = r[0];

	return [
		sprintf('%d.%d.%d.%d',
			(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff),
		r[1]
	];
}

function pack_ipv6(v)
{
	let groups = split(v ?? '0:0:0:0:0:0:0:0', ':');
	let out = '';

	for (let g in groups)
		out += struct.pack('>H', hex('0x' + g) & 0xffff);

	return out;
}

function unpack_ipv6(buf, pos)
{
	if (pos + 16 > length(buf))
		return null;

	let groups = [];

	for (let i = 0; i < 8; i++)
		push(groups, sprintf('%x', struct.unpack('>H', substr(buf, pos + i * 2, 2))[0]));

	return [ join(':', groups), pos + 16 ];
}

// 3-byte BCD PLMN <-> "mcc/mnc" (3GPP TS 24.008 encoding)
function pack_plmn(v)
{
	let m = match(v ?? '', /^([0-9]{3})\/([0-9]{2,3})$/);

	if (!m)
		return "\xff\xff\xff";

	let mcc = m[1], mnc = m[2];
	let d = (s, i) => +substr(s, i, 1);
	let mnc3 = (length(mnc) == 3) ? d(mnc, 2) : 0xf;

	return chr(d(mcc, 0) | (d(mcc, 1) << 4),
	           d(mcc, 2) | (mnc3 << 4),
	           d(mnc, 0) | (d(mnc, 1) << 4));
}

function unpack_plmn(buf, pos)
{
	if (pos + 3 > length(buf))
		return null;

	let b0 = ord(buf, pos), b1 = ord(buf, pos + 1), b2 = ord(buf, pos + 2);
	let mcc = sprintf('%d%d%d', b0 & 0xf, b0 >> 4, b1 & 0xf);
	let mnc3 = b1 >> 4;
	let mnc = sprintf('%d%d', b2 & 0xf, b2 >> 4);

	if (mnc3 != 0xf)
		mnc += sprintf('%d', mnc3);

	return [ sprintf('%s/%s', mcc, mnc), pos + 3 ];
}

function pack_value(fmt, v)
{
	if (type(fmt) == 'string') {
		switch (fmt) {
		case 'plmn':
			return pack_plmn(v);

		case 'u24be': {
			let n = +(v ?? 0);
			return chr((n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff);
		}

		case 'string':
			return sprintf('%s', v ?? '');

		case 'bytes':
			return v ?? '';

		case 'lstring': {
			let s = sprintf('%s', v ?? '');
			return struct.pack('<B', length(s)) + s;
		}

		case 'ipv4':
			return pack_ipv4(v);

		case 'ipv6':
			return pack_ipv6(v);

		default:
			return pack_prim(fmt, v);
		}
	}

	// array
	if (exists(fmt, 'of')) {
		let items = v ?? [];
		let out = pack_prim(fmt.n ?? 'u8', length(items));

		for (let item in items)
			out += pack_value(fmt.of, item);

		return out;
	}

	// struct
	let out = '';

	for (let name in fmt)
		out += pack_value(fmt[name], v?.[name]);

	return out;
}

function unpack_value(fmt, buf, pos)
{
	if (type(fmt) == 'string') {
		switch (fmt) {
		case 'plmn':
			return unpack_plmn(buf, pos);

		case 'u24be': {
			if (pos + 3 > length(buf))
				return null;

			return [ (ord(buf, pos) << 16) | (ord(buf, pos + 1) << 8) | ord(buf, pos + 2),
			         pos + 3 ];
		}

		case 'string':
		case 'bytes':
			return [ substr(buf, pos), length(buf) ];

		case 'lstring': {
			let l = unpack_prim('u8', buf, pos);

			if (!l || l[1] + l[0] > length(buf))
				return null;

			return [ substr(buf, l[1], l[0]), l[1] + l[0] ];
		}

		case 'ipv4':
			return unpack_ipv4(buf, pos);

		case 'ipv6':
			return unpack_ipv6(buf, pos);

		default:
			return unpack_prim(fmt, buf, pos);
		}
	}

	// array
	if (exists(fmt, 'of')) {
		let c = unpack_prim(fmt.n ?? 'u8', buf, pos);

		if (!c)
			return null;

		let items = [];
		pos = c[1];

		for (let i = 0; i < c[0]; i++) {
			let r = unpack_value(fmt.of, buf, pos);

			if (!r)
				return null;

			push(items, r[0]);
			pos = r[1];
		}

		return [ items, pos ];
	}

	// struct
	let res = {};

	for (let name in fmt) {
		let r = unpack_value(fmt[name], buf, pos);

		if (!r)
			return null;

		res[name] = r[0];
		pos = r[1];
	}

	return [ res, pos ];
}

// Pack argument object into concatenated TLV bytes according to field spec.
// Null/absent args are skipped (optional TLVs).
export function pack(fields, args)
{
	let out = '';

	for (let name in fields ?? {}) {
		if ((args?.[name] ?? null) == null)
			continue;

		let v = pack_value(fields[name].f, args[name]);

		out += struct.pack('<BH', fields[name].t, length(v)) + v;
	}

	return out;
}

// Unpack concatenated TLV bytes into an object according to field spec.
export function unpack(fields, buf)
{
	let res = {};

	// TLV types are u8 (0-255), so index the reverse map by the integer
	// directly — avoids an sprintf('%d', t) per field here and per TLV below,
	// which ran on every decoded message
	let by_type = [];

	for (let name in fields ?? {})
		by_type[fields[name].t] = name;

	let pos = 0;
	let len = length(buf ?? '');

	while (pos + 3 <= len) {
		let t = ord(buf, pos);
		let l = struct.unpack('<H', substr(buf, pos + 1, 2))[0];

		pos += 3;

		if (pos + l > len) {
			res._truncated = true;
			break;
		}

		let v = substr(buf, pos, l);

		pos += l;

		let name = by_type[t];

		// type 0x02 is the result TLV — unless the schema claims it as a
		// regular field (UIM requests use 0x02 for File/Info TLVs)
		if (name == null && t == 0x02 && l >= 4) {
			let r = struct.unpack('<HH', v);
			res._result = { result: r[0], error: r[1] };
			continue;
		}

		if (name != null) {
			let d = unpack_value(fields[name].f, v, 0);
			res[name] = d ? d[0] : null;
		}
		else {
			res._raw = res._raw ?? {};
			res._raw[sprintf('%d', t)] = v;
		}
	}

	return res;
}

// --- response validity -------------------------------------------------------
// A decoded response carries meta keys (_result, _raw, _truncated) alongside the
// schema fields. These helpers let pollers/consumers recognise the recurring
// class of "structurally valid but not actually usable" answers instead of
// caching or displaying them as real data.

// meta keys unpack() may add that are not schema payload
const META_KEYS = { _result: true, _raw: true, _truncated: true };

// true when the modem actually returned at least one of the data TLVs the
// schema asked for. A response with only _result (or _truncated) decoded no
// payload — e.g. GET_SIGNAL_INFO right after registration, or a modem that
// answers a poll with an empty body — and must not overwrite last-known data.
export function has_payload(data)
{
	for (let k in (data ?? {}))
		if (!META_KEYS[k])
			return true;

	return false;
}

// Per-type "value not available" markers QMI fills in for absent fields: signal
// metrics report i16 -32768, counters u32 0xFFFFFFFF, TAC u16 0xFFFF, cell id
// u32 0xFFFFFFFF, etc. Centralised so detectors reference one table instead of
// sprinkling magic numbers.
export const SENTINEL = {
	i8:  -128,
	i16: -32768,
	i32: -2147483648,
	u16: 0xFFFF,
	u32: 0xFFFFFFFF,
};

// true when v is null or the type's not-available sentinel (opt-in per field —
// 0xFFFF/0xFFFFFFFF are valid for some fields, so this is never applied blindly)
export function is_unavailable(v, type)
{
	return v == null || (SENTINEL[type] != null && v == SENTINEL[type]);
}
