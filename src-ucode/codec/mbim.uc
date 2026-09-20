// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
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
};

function uuid_str(bytes)
{
	let h = '';

	for (let i = 0; i < 16; i++)
		h += sprintf('%02x', ord(bytes, i));

	return sprintf('%s-%s-%s-%s-%s',
		substr(h, 0, 8), substr(h, 8, 4), substr(h, 12, 4),
		substr(h, 16, 4), substr(h, 20, 12));
}

// MBIM strings are UTF-16LE; ucode strings are UTF-8 byte strings. Both
// directions have to convert by hand, because ucode's chr() is BYTE-oriented:
// chr(0x4E2D) yields 0xff, not a three-byte UTF-8 sequence. The first version
// of the decoder did `chr(c & 0xff)`, which discards the high byte of every
// code unit — fine for ASCII, garbage for anything else. A Chinese operator
// name came back as "-\xef\xbf\xbd5" (ddimension/wwand#8, RM520F-GL on a 460
// IMSI); the encoder had the mirror defect, packing a UTF-8 *byte* as if it
// were a code unit.
export function utf16le_encode(s)
{
	let out = '';

	for (let i = 0; i < length(s); ) {
		let b = ord(s, i);
		let cp, n;

		// decode one UTF-8 sequence; an invalid lead byte is passed through as
		// U+00FF-and-below rather than dropped, so a malformed input still
		// round-trips to something of the same length instead of vanishing
		if (b < 0x80)                  { cp = b; n = 1; }
		else if ((b & 0xe0) == 0xc0)   { cp = b & 0x1f; n = 2; }
		else if ((b & 0xf0) == 0xe0)   { cp = b & 0x0f; n = 3; }
		else if ((b & 0xf8) == 0xf0)   { cp = b & 0x07; n = 4; }
		else                           { cp = b;        n = 1; }

		if (i + n > length(s))
			n = 1;

		for (let k = 1; k < n; k++)
			cp = (cp << 6) | (ord(s, i + k) & 0x3f);

		i += n;

		if (cp < 0x10000) {
			out += struct.pack('<H', cp);
		}
		else {
			// above the BMP: one surrogate pair
			cp -= 0x10000;
			out += struct.pack('<H', 0xd800 + (cp >> 10));
			out += struct.pack('<H', 0xdc00 + (cp & 0x3ff));
		}
	}

	return out;
};

export function utf16le_decode(bytes)
{
	let out = '';

	for (let i = 0; i + 1 < length(bytes); i += 2) {
		let c = struct.unpack('<H', substr(bytes, i, 2))[0];

		if (c == 0)
			break;

		// a high surrogate followed by a low one is ONE code point
		if (c >= 0xd800 && c <= 0xdbff && i + 3 < length(bytes)) {
			let lo = struct.unpack('<H', substr(bytes, i + 2, 2))[0];

			if (lo >= 0xdc00 && lo <= 0xdfff) {
				c = 0x10000 + ((c - 0xd800) << 10) + (lo - 0xdc00);
				i += 2;
			}
		}

		if (c < 0x80)
			out += chr(c);
		else if (c < 0x800)
			out += chr(0xc0 | (c >> 6)) + chr(0x80 | (c & 0x3f));
		else if (c < 0x10000)
			out += chr(0xe0 | (c >> 12)) + chr(0x80 | ((c >> 6) & 0x3f)) +
			       chr(0x80 | (c & 0x3f));
		else
			out += chr(0xf0 | (c >> 18)) + chr(0x80 | ((c >> 12) & 0x3f)) +
			       chr(0x80 | ((c >> 6) & 0x3f)) + chr(0x80 | (c & 0x3f));
	}

	return out;
};

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
	case 'u16': return 2;
	case 'u32': case 'ipv4': return 4;
	case 'u64': return 8;
	case 'uuid': case 'ipv6': return 16;
	default: return 4;
	}
}

function encode_scalar(fmt, v)
{
	switch (fmt) {
	case 'u16': return struct.pack('<H', v ?? 0);
	case 'u32': return struct.pack('<I', v ?? 0);
	case 'u64': return struct.pack('<Q', v ?? 0);
	case 'uuid': return uuid_bytes(v ?? '00000000-0000-0000-0000-000000000000');
	case 'ipv4': return ipv4_bytes(v);
	default: return struct.pack('<I', v ?? 0);
	}
}

// MBIMEx v3 CONNECT (set). A DIFFERENT STRUCTURE, not a variant of the v1 one:
// v3 reorders the fixed fields, inserts MediaPreference, and carries the three
// strings as TLVs instead of v1's offset/length pairs (libmbim 1.32.0,
// mbim-service-ms-basic-connect-v3.json; ModemManager chooses between the two
// on mbim_device_check_ms_mbimex_version, mm-bearer-mbim.c:1340). A modem
// serving v3 answers the v1 form with INVALID_PARAMETERS (21) — HW-observed on
// an RM520N-GL whose SUBSCRIBER_READY_STATUS also came back in the v3 layout,
// 2026-09-19.
//
// TLV header: type u16, reserved u8, padding u8, data_length u32, then the data
// padded to a 4-byte boundary (libmbim mbim-tlv-private.h, struct tlv).
// The types live HERE, above their first user, because module-level `const`
// is not hoisted in ucode (libmbim 1.32.0, src/libmbim-glib/mbim-tlv.h).
export const TLV_WCHAR_STR = 10;
export const TLV_TAI = 9;
export const TLV_UINT16_TBL = 11;

// A WCHAR_STR TLV: UTF-16LE payload, zero-padded to a 4-byte boundary, with the
// pad count in the header and data_length the UNPADDED byte count (libmbim
// 1.32.0, src/libmbim-glib/mbim-tlv.c). The encoding goes through
// utf16le_encode, not a byte-wise widen: ucode strings are UTF-8 byte strings,
// so widening each byte turns 'ä' (c3 a4) into U+00C3 U+00A4 instead of U+00E4.
// ASCII is identical either way, which is why an APN never shows it and a
// non-ASCII user name or password would have gone out corrupted.
function tlv_wchar(str)
{
	let data = utf16le_encode(str ?? '');
	let pad = (4 - (length(data) % 4)) % 4;
	let head = struct.pack('<HBBI', TLV_WCHAR_STR, 0, pad, length(data));

	for (let i = 0; i < pad; i++)
		data += chr(0);

	return head + data;
}

// Which MBIMEx generation the modem agreed to speak, settled by the version
// handshake in mbim_client.open(); a modem that refused it, or that never got
// the question, is v1 (`mbimex_version` 0). This lives here rather than in a
// schema file because MORE THAN ONE schema layout depends on it — Basic Connect
// (SUBSCRIBER_READY_STATUS, CONNECT) and the MS extensions (BASE_STATIONS_INFO)
// — and a second copy of the predicate is a second thing to forget.
export function mbimex_v3(mc)
{
	return (mc?.mbimex_version ?? 0) >= 0x0300;
};

// MbimAccessMediaType: ModemManager sends UNKNOWN (0) and lets the modem pick.
// --- TLV decode --------------------------------------------------------------
// The counterpart to tlv_wchar above. MBIMEx v3 puts variable-length data in
// TLVs rather than the v1 offset/length pairs, and three messages hand back a
// TLV area the fixed part does not describe: Modem Configuration (a name plus
// unnamed IEs), Wake Reason (one TLV whose meaning depends on the wake type),
// and the v3 Connect response.
//
// Header: type u16, reserved u8, padding_length u8, data_length u32; the
// payload is padded to a 4-byte boundary and data_length is the UNPADDED count
// (libmbim 1.32.0, src/libmbim-glib/mbim-tlv.c).
// Walk a TLV area into [ { type, data }, ... ]. A header that claims more bytes
// than the buffer holds ends the walk rather than throwing — a truncated area
// is a protocol error, and the caller sees the TLVs that were whole.
export function decode_tlvs(buf, pos)
{
	let out = [];
	let len = length(buf ?? '');

	pos = pos ?? 0;

	while (pos + 8 <= len) {
		let hdr = struct.unpack('<HBBI', substr(buf, pos, 8));
		let dlen = hdr[3];
		let pad = hdr[2];

		// THE PADDING COUNTS TOWARD THE RECORD. libmbim computes
		// `sizeof(header) + data_length + padding_length` and refuses to read a
		// TLV the buffer cannot hold in full (mbim-tlv.c:150-160, 1.32.0) — so
		// a header claiming padding that is not there is a truncated record,
		// not a complete one. Checking only data_length accepted
		// `0a0000ff00000000` as a whole zero-length TLV while it claims 255
		// bytes of absent padding. Raised by review, 2026-09-20.
		if (pos + 8 + dlen + pad > len)
			break;

		push(out, { type: hdr[0], data: substr(buf, pos + 8, dlen) });

		// the padding is not part of data_length but IS on the wire
		pos += 8 + dlen + pad;
	}

	return out;
};

// The first TLV of a given type, decoded as a string. WCHAR_STR is UTF-16LE;
// anything else is handed back as raw bytes, because guessing is how a codec
// invents data.
export function tlv_string(tlvs, type)
{
	for (let t in tlvs ?? []) {
		if (t.type != (type ?? TLV_WCHAR_STR))
			continue;

		return (t.type == TLV_WCHAR_STR) ? utf16le_decode(t.data) : t.data;
	}

	return null;
};

export const ACCESS_MEDIA_UNKNOWN = 0;

export function encode_connect_v3(a)
{
	return struct.pack('<IIIII', a.session_id ?? 0, a.activation_command ?? 0,
			a.compression ?? 0, a.auth_protocol ?? 0, a.ip_type ?? 0) +
		uuid_bytes(a.context_type ?? '7e5e2a7e-4e6f-7272-736b-656e7e5e2a7e') +
		struct.pack('<I', a.media_preference ?? ACCESS_MEDIA_UNKNOWN) +
		tlv_wchar(a.access_string ?? '') +
		tlv_wchar(a.user_name ?? '') +
		tlv_wchar(a.password ?? '');
};

// MBIM_CID_DEVICE_SERVICE_SUBSCRIBE_LIST (basic_connect cid 19) — the one
// command whose payload is an array of variable-length structs, so it gets a
// hand-built encoder rather than a field spec.
//
// Layout (libmbim 1.32.0, mbim-service-basic-connect.json:699-724, checked
// 2026-09-20): EventsCount u32, then a ref-struct-array — one (offset, size)
// pair per entry, offsets relative to the START OF THE INFORMATION BUFFER —
// then the entries. Each entry is MbimEventEntry: DeviceServiceId (16-byte
// uuid), CidsCount u32, Cids u32[CidsCount].
//
// `events` is [ { service: '<uuid string>', cids: [ n, ... ] }, ... ].
export function encode_subscribe_list(events)
{
	let list = events ?? [];
	let n = length(list);

	// count + the pair table; the entries start after both
	let head = 4 + n * 8;
	let pairs = '';
	let blobs = '';

	for (let e in list) {
		let body = uuid_bytes(e.service) + struct.pack('<I', length(e.cids ?? []));

		for (let cid in (e.cids ?? []))
			body += struct.pack('<I', cid);

		pairs += struct.pack('<II', head + length(blobs), length(body));
		blobs += body;
	}

	return struct.pack('<I', n) + pairs + blobs;
};

// The same layout coming back, so a test can read what was written and a caller
// can see what the modem actually agreed to subscribe. Returns null rather than
// guessing on a buffer that does not hold what it claims.
export function decode_subscribe_list(buf)
{
	if (length(buf ?? '') < 4)
		return null;

	let n = struct.unpack('<I', substr(buf, 0, 4))[0];

	if (length(buf) < 4 + n * 8)
		return null;

	let out = [];

	for (let i = 0; i < n; i++) {
		let off = struct.unpack('<I', substr(buf, 4 + i * 8, 4))[0];
		let len = struct.unpack('<I', substr(buf, 8 + i * 8, 4))[0];

		// ...and it must point PAST the count and the pair table. Without that
		// a malformed answer can have an entry decode the header bytes as a
		// service uuid — a wrong answer where the contract promises null.
		if (off < 4 + n * 8 || off + len > length(buf) || len < 20)
			return null;

		let body = substr(buf, off, len);
		let cids = [];
		let cn = struct.unpack('<I', substr(body, 16, 4))[0];

		if (20 + cn * 4 > len)
			return null;

		for (let c = 0; c < cn; c++)
			push(cids, struct.unpack('<I', substr(body, 20 + c * 4, 4))[0]);

		push(out, { service: uuid_str(substr(body, 0, 16)), cids: cids });
	}

	return out;
};

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
		else if (fmt == 'ipv4-array' || fmt == 'ipv6-array' || type(fmt) == 'object') {
			// count+offset arrays are DECODE-only in wwand: they appear solely in
			// MBIM responses/notifications, never in the SET/QUERY requests this
			// function builds. The old array-encode paths were never exercised and
			// are asymmetric with decode_info anyway (obj-array wrote an inline
			// offset+count where decode expects a 4-byte offset + a separate count
			// field; ipv4/ipv6-array had no branch at all and fell to a 4-byte
			// scalar despite fixed_len reserving 8, corrupting every later offset).
			// Fail loudly if a future request schema adds one, rather than silently
			// emitting a corrupt InformationBuffer.
			die(sprintf('encode_info: array field %s unsupported (arrays are decode-only)', name));
		}
		else {
			fixed += encode_scalar(fmt, v);
		}
	}

	return fixed + data;
};

// --- InformationBuffer decode -----------------------------------------------

function decode_scalar(fmt, buf, pos)
{
	switch (fmt) {
	case 'u16': return [ (pos + 2 <= length(buf)) ? struct.unpack('<H', substr(buf, pos, 2))[0] : null, pos + 2 ];
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
};


// --- message framing --------------------------------------------------------

export function encode_command(txn, service_uuid, cid, cmd_type, info)
{
	info = info ?? '';

	let body = struct.pack('<II', 1, 0) +       // fragment: total=1, current=0
		uuid_bytes(service_uuid) +
		struct.pack('<III', cid, cmd_type, length(info)) + info;

	let total = 12 + length(body);

	return struct.pack('<III', MSG_COMMAND, total, txn) + body;
};

export function encode_open(txn, max_control_transfer)
{
	return struct.pack('<IIII', MSG_OPEN, 16, txn, max_control_transfer ?? 4096);
};

export function encode_close(txn)
{
	return struct.pack('<III', MSG_CLOSE, 12, txn);
};

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

		// THE FRAGMENT HEADER IS NOT PADDING. It was skipped unread, so a
		// response larger than the negotiated MaxControlTransfer (4096) was
		// silently TRUNCATED to its first fragment, and every continuation
		// fragment — which carries only this header plus more InformationBuffer,
		// no uuid/cid/status — was then parsed as though those 24 bytes were a
		// service uuid and a cid, yielding a bogus message. Nothing reported an
		// error; the data was simply short. It bites SMS read-all once a SIM
		// holds enough PDUs. Reassembly is the client's job (it owns the
		// pending-by-transaction map); the codec's job is to stop hiding this.
		// Found by a full review, 2026-09-19.
		if (length(buf) >= 12 + 8) {
			msg.frag_total = struct.unpack('<I', substr(buf, 12, 4))[0];
			msg.frag_index = struct.unpack('<I', substr(buf, 16, 4))[0];
		}

		// a continuation fragment is header + body, nothing else
		if ((msg.frag_index ?? 0) > 0) {
			msg.info = substr(buf, p) ?? '';
			break;
		}
		// A truncated frame must be REJECTED, not thrown on: struct.unpack of a
		// short substr returns null and the [0] below would throw out of the
		// read handler, taking the whole message loop with it — for one bad
		// frame from the modem. The sibling branches above already length-check;
		// this one did not.
		let need = p + 16 + 4 + ((h[0] == MSG_COMMAND_DONE) ? 4 : 0) + 4;

		if (length(buf) < need)
			return null;

		msg.service = uuid_str(substr(buf, p, 16)); p += 16;
		msg.cid = struct.unpack('<I', substr(buf, p, 4))[0]; p += 4;

		if (h[0] == MSG_COMMAND_DONE) {
			msg.status = struct.unpack('<I', substr(buf, p, 4))[0]; p += 4;
		}

		let ilen = struct.unpack('<I', substr(buf, p, 4))[0]; p += 4;

		// and the declared information length is the modem's claim, not a fact:
		// clamp it to what actually arrived rather than handing decode_info a
		// short buffer it would read past (it bounds-checks, but silently).
		if (p + ilen > length(buf))
			ilen = length(buf) - p;

		msg.info = substr(buf, p, ilen);
		break;
	}
	}

	return msg;
};

// --- diagnostic vocabulary ---------------------------------------------------
// Names for the two numbers that appear in every MBIM failure. They exist so a
// failed command can say what it was and what the modem answered, instead of a
// bare integer: an anonymous "status 21" cost a day of hardware bisection on an
// RM520N-GL before it turned out to be InvalidParameters, returned because a
// v1-shaped CONNECT had been sent to a modem serving MBIMEx v3 layouts
// (HW-observed, 2026-09-19 — see encode_connect_v3 above).
//
// Values transcribed mechanically from libmbim 1.32.0
// src/libmbim-glib/mbim-errors.h (MbimStatusError, nick= annotations); the
// large ones are the vendor ranges (0x8743…, 0x9100…). ucode object literals
// reject numeric keys, so the keys are quoted and looked up via sprintf.
const STATUS_NAMES = {
	'0': 'None',
	'1': 'Busy',
	'2': 'Failure',
	'3': 'SimNotInserted',
	'4': 'BadSim',
	'5': 'PinRequired',
	'6': 'PinDisabled',
	'7': 'NotRegistered',
	'8': 'ProvidersNotFound',
	'9': 'NoDeviceSupport',
	'10': 'ProviderNotVisible',
	'11': 'DataClassNotAvailable',
	'12': 'PacketServiceDetached',
	'13': 'MaxActivatedContexts',
	'14': 'NotInitialized',
	'15': 'VoiceCallInProgress',
	'16': 'ContextNotActivated',
	'17': 'ServiceNotActivated',
	'18': 'InvalidAccessString',
	'19': 'InvalidUserNamePwd',
	'20': 'RadioPowerOff',
	'21': 'InvalidParameters',
	'22': 'ReadFailure',
	'23': 'WriteFailure',
	'25': 'NoPhonebook',
	'26': 'ParameterTooLong',
	'27': 'StkBusy',
	'28': 'OperationNotAllowed',
	'29': 'MemoryFailure',
	'30': 'InvalidMemoryIndex',
	'31': 'MemoryFull',
	'32': 'FilterNotSupported',
	'33': 'DssInstanceLimit',
	'34': 'InvalidDeviceServiceOperation',
	'35': 'AuthIncorrectAuth',
	'36': 'AuthSyncFailure',
	'37': 'AuthAmfNotSet',
	'38': 'ContextNotSupported',
	'100': 'SmsUnknownSmscAddress',
	'101': 'SmsNetworkTimeout',
	'102': 'SmsLangNotSupported',
	'103': 'SmsEncodingNotSupported',
	'104': 'SmsFormatNotSupported',
	'2269315073': 'NoLogicalChannels',
	'2269315074': 'SelectFailed',
	'2269315075': 'InvalidLogicalChannel',
	'2432696321': 'InvalidSignature',
	'2432696322': 'InvalidImei',
	'2432696323': 'InvalidTimeStamp',
	'2432696324': 'NetworkListTooLarge',
	'2432696325': 'SignatureAlgorithmNotSupported',
	'2432696326': 'FeatureNotSupported',
	'2432696327': 'DecodeOrParsingError',
};

// MBIM_STATUS_ERROR nick for a status code, or null when the modem returned one
// libmbim 1.32.0 does not name (a vendor code outside the documented ranges).
export function status_name(status)
{
	return STATUS_NAMES[sprintf('%d', status ?? -1)] ?? null;
};

// A UUID in a log line is 36 characters nobody reads. The names are this tree's
// own where it has a schema for the service (they match the file under
// codec/mbim_schema/), and libmbim's otherwise.
//
// THE LIST IS NOT ONLY WHAT WE HAVE SCHEMAS FOR. The first real failure this
// logging caught came from the SMS service, which wwand addresses by raw UUID
// out of mbim_backend.uc and has no schema file for — it printed as
// '533fbeeb-.../cid 2 status 9 (NoDeviceSupport)' (HW, RM520N-GL, 2026-09-19).
// Standard-service UUIDs transcribed from libmbim 1.32.0
// src/libmbim-glib/mbim-uuid.c.
const SERVICE_NAMES = {
	'a289cc33-bcbb-8b4f-b6b0-133ec2aae6df': 'basic_connect',
	'3d01dcc5-fef5-4d05-0d3a-bef7058e9aaf': 'ms_basic_connect_ext',
	'c2f6588e-f037-4bc9-8665-f4d44bd09367': 'ms_uicc_low_level',
	'd1a30bc2-f97a-6e43-bf65-c7e24fb0f0d3': 'qmi_passthrough',
	'a2a32a97-cab1-4f57-9ae1-451c74dda957': 'compal_at',
	'ffffffff-abca-4b11-a4e2-f2fc87f94488': 'fibocom',
	'11223344-5566-7788-99aa-bbccddeeff11': 'quectel',
	'533fbeeb-14fe-4467-9f90-33a223e56c3f': 'sms',
	'e550a0c8-5e82-479e-82f7-10abf4c3351f': 'ussd',
	'4bf38476-1e6a-41db-b1d8-bed289c25bdb': 'phonebook',
	'd8f20131-fcb5-4e17-8602-d6ed3816164c': 'stk',
	'1d2b5ff7-0aa1-48b2-aa52-50f15767174e': 'auth',
	'c08a26dd-7718-4382-8482-6e0d583c4d0e': 'dss',
	'e9f7dea2-feaf-4009-93ce-90a3694103b6': 'ms_firmware_id',
	'883b7c26-985f-43fa-9804-27d7fb80959c': 'ms_host_shutdown',
	'68223d04-9f6c-4e0f-822d-28441fb72340': 'ms_sar',
	'838cf7fb-8d0d-4d7f-871e-d71dbefbb39b': 'proxy_control',
	'5967bdcc-7fd2-49a2-9f5c-b2e70e527db3': 'atds',
	'6427015f-579d-48f5-8c54-f43ed1e76f83': 'qdu',
	'8d8b9eba-37be-449b-8f1e-61cb034a702e': 'ms_voice_extensions',
	'3e1e92cf-c53d-4f14-85d0-a86ad9e12245': 'google',
};

// Short name for a service UUID, or the UUID itself when it is not one of ours
// — an unknown service is exactly the case where the raw UUID is the useful
// thing to print.
export function service_name(uuid)
{
	return SERVICE_NAMES[lc(uuid ?? '')] ?? (uuid ?? '?');
};
