// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — SMS PDU decoder (GSM 03.40 SMS-DELIVER), backend-neutral.
//
// All three backends deliver stored messages as raw PDUs — QMI WMS RAW_READ,
// MBIM SMS_READ, and AT+CMGF=0 CMGL/CMGR — so this ONE decoder serves them all.
// encode_submit() is the send counterpart (SMS-SUBMIT, GSM7/UCS2, concatenated).
// Everything here is pure (no I/O) and host-testable with known TPDU hex vectors
// (tests/test_sms_pdu.uc).
//
// decode_deliver(pdu_hex) -> {
//   smsc, sender, sender_type, timestamp, encoding ('gsm7'|'8bit'|'ucs2'),
//   text, udh: { ref, total, part } | null, index?, status?
// } or null on a malformed / non-DELIVER PDU.

'use strict';

// GSM 03.38 default alphabet: septet value -> Unicode code point (0x00..0x7f).
const GSM7 = [
	0x40,0xA3,0x24,0xA5,0xE8,0xE9,0xF9,0xEC,0xF2,0xC7,0x0A,0xD8,0xF8,0x0D,0xC5,0xE5,
	0x0394,0x5F,0x03A6,0x0393,0x039B,0x03A9,0x03A0,0x03A8,0x03A3,0x0398,0x039E,0x1B,0xC6,0xE6,0xDF,0xC9,
	0x20,0x21,0x22,0x23,0xA4,0x25,0x26,0x27,0x28,0x29,0x2A,0x2B,0x2C,0x2D,0x2E,0x2F,
	0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38,0x39,0x3A,0x3B,0x3C,0x3D,0x3E,0x3F,
	0xA1,0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4A,0x4B,0x4C,0x4D,0x4E,0x4F,
	0x50,0x51,0x52,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5A,0xC4,0xD6,0xD1,0xDC,0xA7,
	0xBF,0x61,0x62,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6A,0x6B,0x6C,0x6D,0x6E,0x6F,
	0x70,0x71,0x72,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7A,0xE4,0xF6,0xF1,0xFC,0xE0
];

// default-alphabet extension table (septet after a 0x1B escape).
const GSM7_EXT = {
	'10': 0x0C, '20': 0x5E, '40': 0x7B, '41': 0x7D, '47': 0x5C,
	'60': 0x5B, '61': 0x7E, '62': 0x5D, '65': 0x7C, '101': 0x20AC   // €
};

// --- byte helpers ------------------------------------------------------------

// hex string -> byte array (ignores odd trailing nibble); null-safe.
function hex_bytes(s)
{
	let raw = hexdec(s ?? '');
	let out = [];

	for (let i = 0; i < length(raw ?? ''); i++)
		push(out, ord(raw, i));

	return out;
}

function b(a, i)
{
	return (i >= 0 && i < length(a)) ? a[i] : 0;
}

// one Unicode code point -> UTF-8 bytes appended to the string `s`.
function utf8(cp)
{
	if (cp < 0x80)
		return chr(cp);
	if (cp < 0x800)
		return chr(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F));
	if (cp < 0x10000)
		return chr(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));

	return chr(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
	           0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
}

// --- field decoders ----------------------------------------------------------

// continuous 7-bit unpack: `n` septets from `octets` starting at octet `off`,
// dropping the first `skip` septets (used to step over a UDH). LSB-first packing.
function unpack7(octets, off, n, skip)
{
	let res = [], carry = 0, bits = 0, oi = off;

	for (let i = 0; i < n; i++) {
		while (bits < 7) {
			carry |= b(octets, oi++) << bits;
			bits += 8;
		}

		let sept = carry & 0x7f;
		carry >>= 7;
		bits -= 7;

		if (i >= skip)
			push(res, sept);
	}

	return res;
}

// septet array -> UTF-8 text via the default alphabet (+ escape extension).
function gsm7_text(septets)
{
	let out = '';

	for (let i = 0; i < length(septets); i++) {
		let s = septets[i];

		if (s == 0x1b) {
			let ext = GSM7_EXT[sprintf('%d', septets[++i])];
			out += utf8(ext ?? 0x20);
			continue;
		}

		out += utf8(GSM7[s] ?? 0x20);
	}

	return out;
}

// UCS2 (UTF-16BE) octets -> UTF-8 text, with surrogate-pair handling.
function ucs2_text(octets, off, len)
{
	let out = '';

	for (let i = off; i + 1 < off + len; i += 2) {
		let cp = (b(octets, i) << 8) | b(octets, i + 1);

		// high surrogate -> combine with the following low surrogate
		if (cp >= 0xD800 && cp <= 0xDBFF && i + 3 < off + len) {
			let lo = (b(octets, i + 2) << 8) | b(octets, i + 3);
			cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
			i += 2;
		}

		out += utf8(cp);
	}

	return out;
}

// address field at `pos`: returns { value, type, next } (next = octet after it).
function decode_address(a, pos)
{
	let ndigits = b(a, pos++);
	let toa = b(a, pos++);
	let octets = int((ndigits + 1) / 2);
	let ton = (toa >> 4) & 0x07;
	let value;

	if (ton == 5) {
		// alphanumeric: the digit count is in semi-octets -> septets = n*4/7
		value = gsm7_text(unpack7(a, pos, int((ndigits * 4) / 7), 0));
	}
	else {
		value = '';
		for (let i = 0; i < octets; i++) {
			let o = b(a, pos + i);
			value += sprintf('%d', o & 0x0f);
			if ((o >> 4) != 0x0f)
				value += sprintf('%d', o >> 4);
		}
		if (ton == 1)          // international
			value = '+' + value;
	}

	return { value: value, type: ton, next: pos + octets };
}

// TP-SCTS (7 octets, swapped-BCD + timezone) -> "YY-MM-DD HH:MM:SS ±TZ".
function decode_scts(a, pos)
{
	let d = (i) => { let o = b(a, pos + i); return (o & 0x0f) * 10 + (o >> 4); };
	let tzo = b(a, pos + 6);
	// tz in quarter-hours; top nibble bit 3 (of the swapped low nibble) = sign
	let tzq = (tzo & 0x07) * 10 + (tzo >> 4);
	let neg = (tzo & 0x08) != 0;

	return sprintf('20%02d-%02d-%02d %02d:%02d:%02d %s%02d:%02d',
		d(0), d(1), d(2), d(3), d(4), d(5),
		neg ? '-' : '+', int(tzq / 4), (tzq % 4) * 15);
}

// parse a UDH (concatenation IEIs 0x00 / 0x08) -> { ref, total, part } | null.
function parse_udh(a, off, udhl)
{
	let p = off, end = off + udhl;

	while (p + 1 < end) {
		let iei = b(a, p++), ielen = b(a, p++);

		if (iei == 0x00 && ielen == 3)
			return { ref: b(a, p), total: b(a, p + 1), part: b(a, p + 2) };
		if (iei == 0x08 && ielen == 4)
			return { ref: (b(a, p) << 8) | b(a, p + 1), total: b(a, p + 2), part: b(a, p + 3) };

		p += ielen;
	}

	return null;
}

// --- public API --------------------------------------------------------------

// Decode one SMS-DELIVER PDU (hex string, SMSC-prefixed as AT/QMI deliver it).
export function decode_deliver(pdu_hex)
{
	let a = hex_bytes(pdu_hex);

	if (length(a) < 2)
		return null;

	let pos = 0;

	// SMSC: length octet counts the type byte + BCD digits
	let smsc_len = b(a, pos++);
	let smsc = null;

	if (smsc_len > 0) {
		// SMSC address length is in OCTETS (incl. the type byte), unlike a TP
		// address (semi-octets), so decode it inline rather than decode_address().
		let toa = b(a, pos);
		let digits = '';
		for (let i = 1; i < smsc_len; i++) {
			let o = b(a, pos + i);
			digits += sprintf('%d', o & 0x0f);
			if ((o >> 4) != 0x0f)
				digits += sprintf('%d', o >> 4);
		}
		smsc = (((toa >> 4) & 0x07) == 1 ? '+' : '') + digits;
	}

	pos += smsc_len;

	let first = b(a, pos++);

	if ((first & 0x03) != 0x00)     // TP-MTI must be 00 (SMS-DELIVER)
		return null;

	let udhi = (first & 0x40) != 0;

	let oa = decode_address(a, pos);
	pos = oa.next;

	let pid = b(a, pos++);
	let dcs = b(a, pos++);
	let ts = decode_scts(a, pos);
	pos += 7;
	let udl = b(a, pos++);

	// data coding: bits 3-2 select the alphabet (00 GSM7, 01 8-bit, 10 UCS2)
	let alpha = (dcs & 0x0c) >> 2;
	let encoding = (alpha == 2) ? 'ucs2' : (alpha == 1) ? '8bit' : 'gsm7';

	let udh = null, ud_off = pos, skip_septets = 0, skip_octets = 0;

	if (udhi) {
		let udhl = b(a, pos);
		udh = parse_udh(a, pos + 1, udhl);
		skip_octets = udhl + 1;
		// septets the UDH occupies, rounded up so text starts on a boundary
		skip_septets = int(((udhl + 1) * 8 + 6) / 7);
	}

	let text;

	if (encoding == 'gsm7')
		text = gsm7_text(unpack7(a, ud_off, udl, skip_septets));
	else if (encoding == 'ucs2')
		text = ucs2_text(a, ud_off + skip_octets, length(a) - (ud_off + skip_octets));
	else {
		// 8-bit: emit raw bytes as-is (after any UDH)
		text = '';
		for (let i = ud_off + skip_octets; i < length(a); i++)
			text += chr(b(a, i));
	}

	return {
		smsc: smsc,
		sender: oa.value,
		sender_type: oa.type,
		timestamp: ts,
		pid: pid,
		dcs: dcs,
		encoding: encoding,
		udh: udh,
		text: text,
	};
};

// Merge multipart parts (same UDH ref) into single messages. `msgs` is a list of
// decoded objects (each may carry `.udh` and an `.index`/`.storage` for delete).
// Returns a list where concatenated parts are joined in `part` order; incomplete
// concatenations are still returned (best-effort), flagged `.incomplete`.
export function reassemble(msgs)
{
	let groups = {}, order = [], out = [];

	for (let m in msgs) {
		if (!m.udh) {
			push(out, m);
			continue;
		}

		let key = sprintf('%d', m.udh.ref);

		if (!groups[key]) {
			groups[key] = { ref: m.udh.ref, total: m.udh.total, parts: {}, first: m };
			push(order, key);
		}

		groups[key].parts[sprintf('%d', m.udh.part)] = m;
	}

	for (let key in order) {
		let g = groups[key];
		let text = '', have = 0, indexes = [];

		for (let i = 1; i <= g.total; i++) {
			let p = g.parts[sprintf('%d', i)];
			if (p) {
				text += p.text;
				have++;
				push(indexes, p.index);
			}
		}

		push(out, {
			smsc: g.first.smsc,
			sender: g.first.sender,
			sender_type: g.first.sender_type,
			timestamp: g.first.timestamp,
			encoding: g.first.encoding,
			text: text,
			concat_ref: g.ref,
			parts: g.total,
			indexes: indexes,
			incomplete: have < g.total,
		});
	}

	return out;
};

// --- SMS-SUBMIT encoder (sending) --------------------------------------------
// Builds SMS-SUBMIT TPDUs for sms.uc's send path. GSM7 when the whole text maps
// to the default alphabet (incl. the extension table), else UCS2 (UTF-16BE).
// Long text is segmented with an 8-bit concatenation UDH. All pure; wire format
// verified vs GSM 03.40 and round-trips through decode_deliver in the tests.

// reverse GSM 03.38 map, built once (code point -> [septet] or [0x1b, ext]).
let GSM7_REV = null;

function gsm7_rev()
{
	if (GSM7_REV != null)
		return GSM7_REV;

	GSM7_REV = {};

	for (let i = 0; i < length(GSM7); i++)
		GSM7_REV[sprintf('%d', GSM7[i])] = [ i ];

	for (let k, v in GSM7_EXT)
		GSM7_REV[sprintf('%d', v)] = [ 0x1b, +k ];

	return GSM7_REV;
}

// decode a UTF-8 string to an array of Unicode code points.
function utf8_cps(s)
{
	let cps = [], i = 0, n = length(s ?? '');

	while (i < n) {
		let c = ord(s, i);

		if (c < 0x80) { push(cps, c); i += 1; }
		else if (c < 0xE0) { push(cps, ((c & 0x1f) << 6) | (ord(s, i+1) & 0x3f)); i += 2; }
		else if (c < 0xF0) { push(cps, ((c & 0x0f) << 12) | ((ord(s, i+1) & 0x3f) << 6) | (ord(s, i+2) & 0x3f)); i += 3; }
		else { push(cps, ((c & 0x07) << 18) | ((ord(s, i+1) & 0x3f) << 12) | ((ord(s, i+2) & 0x3f) << 6) | (ord(s, i+3) & 0x3f)); i += 4; }
	}

	return cps;
}

// map code points to GSM7 septets, or null if any char is outside the alphabet.
function to_septets(cps)
{
	let rev = gsm7_rev();
	let sep = [];

	for (let cp in cps) {
		let m = rev[sprintf('%d', cp)];

		if (!m)
			return null;

		for (let s in m)
			push(sep, s);
	}

	return sep;
}

let hx = (a) => { let s = ''; for (let o in a) s += sprintf('%02X', o & 0xff); return s; };

// pack septets LSB-first into octets (optionally UDH-aligned by `skip` bits).
function pack7(sep, fill_bits)
{
	let out = [], carry = 0, bits = 0;

	// leading fill bits so the first septet starts on a 7-bit boundary after UDH
	if (fill_bits) { bits = fill_bits; }

	for (let s in sep) {
		carry |= (s << bits);
		bits += 7;

		while (bits >= 8) {
			push(out, carry & 0xff);
			carry >>= 8;
			bits -= 8;
		}
	}

	if (bits > 0)
		push(out, carry & 0xff);

	return out;
}

// encode a destination address into DA octets: [ ndigits, toa, ...semi-octets ].
function encode_address(number)
{
	let intl = (substr(number, 0, 1) == '+');
	let digits = replace(number, /[^0-9]/g, '');
	let toa = intl ? 0x91 : 0x81;   // 0x91 international/ISDN, 0x81 unknown/ISDN
	let out = [ length(digits), toa ];

	for (let i = 0; i < length(digits); i += 2) {
		let lo = ord(digits, i) - 48;
		let hi = (i + 1 < length(digits)) ? (ord(digits, i + 1) - 48) : 0x0f;
		push(out, (hi << 4) | lo);
	}

	return out;
}

// encode_submit(number, text, opts?) -> [ { pdu, tpdu_len }, ... ]
//   pdu: hex string with a 00 SMSC prefix (AT+CMGS wants tpdu_len = octet count
//        AFTER the SMSC byte; QMI/MBIM take the same PDU). One entry per segment.
//   opts.ref: 8-bit concatenation reference (default derived by the caller).
export function encode_submit(number, text, opts)
{
	let da = encode_address(number);
	let ref = (opts?.ref ?? 0) & 0xff;
	let cps = utf8_cps(text ?? '');
	let sep = to_septets(cps);
	let gsm7 = (sep != null);
	let dcs = gsm7 ? 0x00 : 0x08;

	// segment limits: single 160 GSM7 septets / 70 UCS2 chars; concatenated
	// 153 septets / 67 chars (6-byte UDH eats one septet-boundary block).
	let segs = [];

	if (gsm7) {
		if (length(sep) <= 160)
			segs = [ sep ];
		else
			for (let i = 0; i < length(sep); i += 153)
				push(segs, slice(sep, i, i + 153));
	}
	else {
		if (length(cps) <= 70)
			segs = [ cps ];
		else
			for (let i = 0; i < length(cps); i += 67)
				push(segs, slice(cps, i, i + 67));
	}

	let total = length(segs);
	let out = [];

	for (let n = 0; n < total; n++) {
		let concat = (total > 1);
		// first octet: SMS-SUBMIT (0x01) | VPF relative (0x10) | UDHI when concat
		let fo = 0x11 | (concat ? 0x40 : 0);
		let tp = [ fo, 0x00 ];   // + MR 00

		for (let o in da) push(tp, o);
		push(tp, 0x00);          // TP-PID
		push(tp, dcs);           // TP-DCS
		push(tp, 0xAA);          // TP-VP relative = 4 days

		let udh = concat ? [ 0x05, 0x00, 0x03, ref, total, n + 1 ] : [];

		if (gsm7) {
			let seg = segs[n];
			// UDL counts septets incl. the UDH's septet-equivalent padding
			let udhl_septets = concat ? int((length(udh) * 8 + 6) / 7) : 0;
			let fill = concat ? (7 - ((length(udh) * 8) % 7)) % 7 : 0;
			push(tp, length(seg) + udhl_septets);   // TP-UDL (septets)
			for (let o in udh) push(tp, o);
			for (let o in pack7(seg, fill)) push(tp, o);
		}
		else {
			let seg = segs[n];
			let body = [];
			for (let cp in seg) { push(body, (cp >> 8) & 0xff); push(body, cp & 0xff); }
			push(tp, length(udh) + length(body));    // TP-UDL (octets)
			for (let o in udh) push(tp, o);
			for (let o in body) push(tp, o);
		}

		out[n] = { pdu: '00' + hx(tp), tpdu_len: length(tp), encoding: gsm7 ? 'gsm7' : 'ucs2' };
	}

	return out;
};
