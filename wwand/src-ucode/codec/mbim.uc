// wwand — MBIM message framing and InformationBuffer codec.
//
// MBIM messages share a 12-byte header (MessageType, MessageLength,
// TransactionId, all u32 LE). COMMAND/COMMAND_DONE/INDICATE carry a fragment
// header, a 16-byte service UUID, a CID and an InformationBuffer.
//
// The InformationBuffer uses the MBIM "fixed part + data buffer" layout:
// scalar fields (u32/u64/uuid/ipv4/ipv6) are inline in declaration order;
// variable fields (string, arrays) appear in the fixed part as
// offset+length (or count) referencing bytes appended after the fixed part.
// Strings are UTF-16LE. Everything is padded to 4-byte boundaries.
//
// Field format vocabulary (schema): u32 u64 uuid ipv4 ipv6 (scalar),
// string, ipv4-array, ipv6-array, and struct arrays declared as
// { array: <count-field-name>, of: { field: fmt, ... } }.

'use strict';

import * as struct from 'struct';

export const MSG_OPEN = 0x00000001;
export const MSG_CLOSE = 0x00000002;
export const MSG_COMMAND = 0x00000003;
export const MSG_HOST_ERROR = 0x00000004;
export const MSG_OPEN_DONE = 0x80000001;
export const MSG_CLOSE_DONE = 0x80000002;
export const MSG_COMMAND_DONE = 0x80000003;
export const MSG_FUNCTION_ERROR = 0x80000004;
export const MSG_INDICATE_STATUS = 0x80000007;

export const CMD_QUERY = 0;
export const CMD_SET = 1;

function padding(n)
{
	let p = (4 - (n % 4)) % 4;
	let s = '';

	for (let i = 0; i < p; i++)
		s += "\x00";

	return s;
}

// "a289cc33-bcbb-8b4f-b6b0-133ec2aae6df" -> 16 bytes (MBIM UUID byte order is
// big-endian for all fields, i.e. the string written out verbatim)
export function uuid_bytes(str)
{
	// MBIM UUIDs are stored as the string written out verbatim (16 bytes)
	return hexdec(replace(str, /-/g, ''));
}

function uuid_str(bytes)
{
	let h = '';

	for (let i = 0; i < 16; i++)
		h += sprintf('%02x', ord(bytes, i));

	return sprintf('%s-%s-%s-%s-%s',
		substr(h, 0, 8), substr(h, 8, 4), substr(h, 12, 4),
		substr(h, 16, 4), substr(h, 20, 12));
}

function utf16le_encode(s)
{
	let out = '';

	for (let i = 0; i < length(s); i++)
		out += struct.pack('<H', ord(s, i));   // ASCII/latin subset is enough

	return out;
}

function utf16le_decode(bytes)
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

function ipv4_bytes(v)
{
	let o = split(v ?? '0.0.0.0', '.');

	return chr(+o[0] & 0xff, +o[1] & 0xff, +o[2] & 0xff, +o[3] & 0xff);
}

function ipv4_str(bytes, pos)
{
	return sprintf('%d.%d.%d.%d', ord(bytes, pos), ord(bytes, pos + 1),
		ord(bytes, pos + 2), ord(bytes, pos + 3));
}

function ipv6_str(bytes, pos)
{
	let g = [];

	for (let i = 0; i < 8; i++)
		push(g, sprintf('%x', struct.unpack('>H', substr(bytes, pos + i * 2, 2))[0]));

	return join(':', g);
}

// --- InformationBuffer encode -----------------------------------------------

function field_size(fmt)
{
	switch (fmt) {
	case 'u32': case 'ipv4': return 4;
	case 'u64': return 8;
	case 'uuid': case 'ipv6': return 16;
	default: return 4;
	}
}

function encode_scalar(fmt, v)
{
	switch (fmt) {
	case 'u32': return struct.pack('<I', v ?? 0);
	case 'u64': return struct.pack('<Q', v ?? 0);
	case 'uuid': return uuid_bytes(v ?? '00000000-0000-0000-0000-000000000000');
	case 'ipv4': return ipv4_bytes(v);
	default: return struct.pack('<I', v ?? 0);
	}
}

function encode_struct(fields, obj)
{
	let out = '';

	for (let name, fmt in fields)
		out += encode_scalar(fmt, obj?.[name]);

	return out;
}

export function encode_info(fields, args)
{
	let fixed = '';
	let data = '';

	// data offsets are relative to the start of the InformationBuffer
	let fixed_len = 0;

	for (let name, fmt in fields)
		fixed_len += (fmt == 'string' || fmt == 'ipv4-array' ||
		              fmt == 'ipv6-array' || type(fmt) == 'object') ? 8 : field_size(fmt);

	for (let name, fmt in fields) {
		let v = args?.[name];

		if (fmt == 'string') {
			let s = utf16le_encode(v ?? '');

			if (length(s)) {
				fixed += struct.pack('<II', fixed_len + length(data), length(s));
				data += s + padding(length(s));
			}
			else {
				fixed += struct.pack('<II', 0, 0);
			}
		}
		else if (type(fmt) == 'string') {
			fixed += encode_scalar(fmt, v);
		}
		else {
			// struct array: { array: countfield, of: {...} } — encoded as
			// count in the referenced field + offset/length here
			let items = v ?? [];
			let blob = '';

			for (let item in items)
				blob += encode_struct(fmt.of, item);

			if (length(blob)) {
				fixed += struct.pack('<II', fixed_len + length(data), length(items));
				data += blob;
			}
			else {
				fixed += struct.pack('<II', 0, 0);
			}
		}
	}

	return fixed + data;
}

// --- InformationBuffer decode -----------------------------------------------

function decode_scalar(fmt, buf, pos)
{
	switch (fmt) {
	case 'u32': return [ (pos + 4 <= length(buf)) ? struct.unpack('<I', substr(buf, pos, 4))[0] : null, pos + 4 ];
	case 'u64': return [ (pos + 8 <= length(buf)) ? struct.unpack('<Q', substr(buf, pos, 8))[0] : null, pos + 8 ];
	case 'uuid': return [ (pos + 16 <= length(buf)) ? uuid_str(substr(buf, pos, 16)) : null, pos + 16 ];
	case 'ipv4': return [ (pos + 4 <= length(buf)) ? ipv4_str(buf, pos) : null, pos + 4 ];
	case 'ipv6': return [ (pos + 16 <= length(buf)) ? ipv6_str(buf, pos) : null, pos + 16 ];
	// ref-ipv4/ipv6: u32 offset into the buffer, then the address
	case 'ref-ipv4': {
		if (pos + 4 > length(buf)) return [ null, pos + 4 ];
		let o = struct.unpack('<I', substr(buf, pos, 4))[0];
		return [ (o > 0 && o + 4 <= length(buf)) ? ipv4_str(buf, o) : null, pos + 4 ];
	}
	case 'ref-ipv6': {
		if (pos + 4 > length(buf)) return [ null, pos + 4 ];
		let o = struct.unpack('<I', substr(buf, pos, 4))[0];
		return [ (o > 0 && o + 16 <= length(buf)) ? ipv6_str(buf, o) : null, pos + 4 ];
	}
	default: return [ null, pos + 4 ];
	}
}

function decode_struct(fields, buf, pos)
{
	let res = {};

	for (let name, fmt in fields) {
		let d = decode_scalar(fmt, buf, pos);
		res[name] = d[0];
		pos = d[1];
	}

	return [ res, pos ];
}

export function decode_info(fields, buf)
{
	let res = {};
	let pos = 0;
	let len = length(buf ?? '');

	for (let name, fmt in fields) {
		if (fmt == 'string') {
			if (pos + 8 > len) { res[name] = null; pos += 8; continue; }

			let oh = struct.unpack('<II', substr(buf, pos, 8));
			pos += 8;
			res[name] = (oh[1] > 0 && oh[0] + oh[1] <= len)
				? utf16le_decode(substr(buf, oh[0], oh[1])) : null;
		}
		else if (fmt == 'ipv4-array' || fmt == 'ipv6-array') {
			// paired with a preceding count field; offset+size here
			if (pos + 8 > len) { res[name] = []; pos += 8; continue; }

			let oh = struct.unpack('<II', substr(buf, pos, 8));
			pos += 8;
			let out = [];
			let esz = (fmt == 'ipv4-array') ? 4 : 16;

			for (let o = oh[0]; o + esz <= oh[0] + oh[1] && o + esz <= len; o += esz)
				push(out, (esz == 4) ? ipv4_str(buf, o) : ipv6_str(buf, o));

			res[name] = out;
		}
		else if (type(fmt) == 'object') {
			// MBIM count+offset array: the element count lives in a separate,
			// already-decoded field named by fmt.array; only a 4-byte OFFSET
			// into the info buffer sits here. Elements (a struct via `of: {...}`
			// or a scalar via `of: 'ipv4'`/'ipv6') are read from that offset.
			if (pos + 4 > len) { res[name] = []; pos += 4; continue; }

			let o = struct.unpack('<I', substr(buf, pos, 4))[0];
			pos += 4;

			let count = +(res[fmt.array] ?? 0);
			let out = [];

			// hard bound: `count` comes straight off the modem wire; a
			// malformed/misaligned buffer can carry a garbage count (up to
			// ~4e9) which would loop building null-structs until OOM. Stop
			// as soon as the read offset leaves the buffer — each element
			// advances `o` by >=4, so this caps iterations at len/4.
			for (let i = 0; i < count && o < len; i++) {
				let d = (type(fmt.of) == 'object')
					? decode_struct(fmt.of, buf, o)
					: decode_scalar(fmt.of, buf, o);

				push(out, d[0]);
				o = d[1];
			}

			res[name] = out;
		}
		else {
			let d = decode_scalar(fmt, buf, pos);
			res[name] = d[0];
			pos = d[1];
		}
	}

	return res;
}


// --- message framing --------------------------------------------------------

export function encode_command(txn, service_uuid, cid, cmd_type, info)
{
	info = info ?? '';

	let body = struct.pack('<II', 1, 0) +       // fragment: total=1, current=0
		uuid_bytes(service_uuid) +
		struct.pack('<III', cid, cmd_type, length(info)) + info;

	let total = 12 + length(body);

	return struct.pack('<III', MSG_COMMAND, total, txn) + body;
}

export function encode_open(txn, max_control_transfer)
{
	return struct.pack('<IIII', MSG_OPEN, 16, txn, max_control_transfer ?? 4096);
}

export function encode_close(txn)
{
	return struct.pack('<III', MSG_CLOSE, 12, txn);
}

export function decode(buf)
{
	if (length(buf ?? '') < 12)
		return null;

	let h = struct.unpack('<III', substr(buf, 0, 12));
	let msg = { type: h[0], length: h[1], txn: h[2] };

	switch (h[0]) {
	case MSG_OPEN_DONE:
	case MSG_CLOSE_DONE:
		msg.status = (length(buf) >= 16) ? struct.unpack('<I', substr(buf, 12, 4))[0] : null;
		break;

	case MSG_FUNCTION_ERROR:
		msg.error = (length(buf) >= 16) ? struct.unpack('<I', substr(buf, 12, 4))[0] : null;
		break;

	case MSG_COMMAND_DONE:
	case MSG_INDICATE_STATUS: {
		// fragment(8) + uuid(16) + cid(4) [+ status(4) for DONE] + infolen(4)
		let p = 12 + 8;
		msg.service = uuid_str(substr(buf, p, 16)); p += 16;
		msg.cid = struct.unpack('<I', substr(buf, p, 4))[0]; p += 4;

		if (h[0] == MSG_COMMAND_DONE) {
			msg.status = struct.unpack('<I', substr(buf, p, 4))[0]; p += 4;
		}

		let ilen = struct.unpack('<I', substr(buf, p, 4))[0]; p += 4;
		msg.info = substr(buf, p, ilen);
		break;
	}
	}

	return msg;
}
