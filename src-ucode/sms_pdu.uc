// wwand — SMS PDU decoder (GSM 03.40 SMS-DELIVER), backend-neutral.
//
// All three backends deliver stored messages as raw PDUs — QMI WMS RAW_READ,
// MBIM SMS_READ, and AT+CMGF=0 CMGL/CMGR — so this ONE decoder serves them all.
// Decode-only (receive); there is no SMS-SUBMIT encoder because sending is out
// of scope. Everything here is pure (no I/O) and host-testable with known TPDU
// hex vectors (tests/test_sms_pdu.uc).
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
}

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
}
