// wwand tests — SMS PDU decoder (sms_pdu.uc), GSM 03.40 SMS-DELIVER.
//
// Strategy: a local pack7() encoder (independent inverse of the decoder's
// unpack7) lets us build PDUs from known fields and round-trip them, while the
// canonical "hello" -> E8329BFD06 packing anchors the 7-bit codec against an
// external reference so a shared encode/decode bug can't hide.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as sms from 'wwand/sms_pdu.uc';

// --- local encoder helpers (test-only) --------------------------------------

// LSB-first 7-bit pack (inverse of sms_pdu unpack7)
function pack7(septets) {
	let out = [], carry = 0, bits = 0;
	for (let s in septets) {
		carry |= (s & 0x7f) << bits; bits += 7;
		while (bits >= 8) { push(out, carry & 0xff); carry >>= 8; bits -= 8; }
	}
	if (bits > 0) push(out, carry & 0xff);
	return out;
}

function hex(bytes) {
	let s = '';
	for (let x in bytes) s += sprintf('%02x', x & 0xff);
	return s;
}

// ascii text -> gsm7 septets (letters/digits/space map 1:1 in the basic table)
function septets(s) {
	let out = [];
	for (let i = 0; i < length(s); i++) push(out, ord(s, i));
	return out;
}

// build an intl TP-address (semi-octet BCD, type 0x91)
function addr_intl(digits) {
	let out = [ length(digits), 0x91 ];
	for (let i = 0; i < length(digits); i += 2) {
		let lo = +substr(digits, i, 1);
		let hi = (i + 1 < length(digits)) ? +substr(digits, i + 1, 1) : 0x0f;
		push(out, (hi << 4) | lo);
	}
	return out;
}

// swapped-BCD SCTS octet for a 2-digit value
function bcd2(v) { return ((v % 10) << 4) | int(v / 10); }

// --- anchor: canonical "hello" packing --------------------------------------
eq(hex(pack7(septets('hello'))), 'e8329bfd06', 'pack7: canonical hello -> e8329bfd06');

// --- 1. GSM7, no UDH, international sender -----------------------------------
(function () {
	let text = 'hello';
	let sp = septets(text);
	let ud = pack7(sp);
	let scts = [ bcd2(2), bcd2(8), bcd2(26), bcd2(19), bcd2(37), bcd2(41), 0x80 ]; // +02:00
	let pdu = [ 0x00,                  // no SMSC
		0x04,                          // first octet: SMS-DELIVER, no UDH
		...addr_intl('491701234567'),  // sender
		0x00, 0x00,                    // PID, DCS=GSM7
		...scts,
		length(sp),                    // UDL (septets)
		...ud ];
	let m = sms.decode_deliver(hex(pdu));
	eq(m.encoding, 'gsm7', '1: encoding gsm7');
	eq(m.sender, '+491701234567', '1: intl sender decoded');
	eq(m.text, 'hello', '1: 7-bit text');
	eq(m.timestamp, '2002-08-26 19:37:41 +02:00', '1: SCTS timestamp');
	eq(m.udh, null, '1: no UDH');
})();

// --- 2. GSM7 special chars (basic table + escape extension) -----------------
(function () {
	// septet 0x7b -> ä ; 0x1b 0x65 -> € ; 0x00 -> @
	let sp = [ 0x7b, 0x1b, 0x65, 0x00 ];
	let ud = pack7(sp);
	let pdu = [ 0x00, 0x04, ...addr_intl('49123'), 0x00, 0x00,
		bcd2(2), bcd2(1), bcd2(1), 0, 0, 0, 0x80, length(sp), ...ud ];
	let m = sms.decode_deliver(hex(pdu));
	eq(m.text, 'ä€@', '2: gsm7 basic + escape extension');
})();

// --- 3. UCS2 with a surrogate-pair emoji ------------------------------------
(function () {
	// "ä€" + U+1F600 (😀 -> surrogates D83D DE00)
	let ud = [ 0x00,0xE4, 0x20,0xAC, 0xD8,0x3D, 0xDE,0x00 ];
	let pdu = [ 0x00, 0x04, ...addr_intl('49123'), 0x00, 0x08,   // DCS=UCS2
		bcd2(2), bcd2(1), bcd2(1), 0, 0, 0, 0x80, length(ud), ...ud ];
	let m = sms.decode_deliver(hex(pdu));
	eq(m.encoding, 'ucs2', '3: encoding ucs2');
	eq(m.text, 'ä€😀', '3: UCS2 incl. surrogate-pair emoji');
})();

// --- 4. multipart (UDH concatenation) + reassembly --------------------------
(function () {
	// build one gsm7 part carrying a UDH concat header (ref, total, part)
	function build_part(ref, total, part, text) {
		let udh = [ 0x00, 0x03, ref, total, part ];    // IEI 0x00, len 3
		let udhl = length(udh);                          // 5
		let skip_oct = udhl + 1;                          // 6
		let skip_sept = int((skip_oct * 8 + 6) / 7);      // 7
		let sp = septets(text);
		let stream = [];
		for (let i = 0; i < skip_sept; i++) push(stream, 0);
		for (let s in sp) push(stream, s);
		let ud = pack7(stream);
		ud[0] = udhl;                                     // overwrite UDH region
		for (let i = 0; i < udhl; i++) ud[1 + i] = udh[i];
		return [ 0x00, 0x44,                              // first octet: DELIVER + UDHI(0x40)
			...addr_intl('49123'), 0x00, 0x00,
			bcd2(2), bcd2(1), bcd2(1), 0, 0, 0, 0x80,
			length(stream),                               // UDL = total septets
			...ud ];
	}

	let m1 = sms.decode_deliver(hex(build_part(0x42, 2, 1, 'AAAAAAAA')));
	let m2 = sms.decode_deliver(hex(build_part(0x42, 2, 2, 'BBBBBBBB')));
	eq(m1.text, 'AAAAAAAA', '4: part 1 text (UDH septet offset)');
	eq(m2.text, 'BBBBBBBB', '4: part 2 text');
	ok(m1.udh && m1.udh.ref == 0x42 && m1.udh.total == 2 && m1.udh.part == 1, '4: UDH parsed');

	m1.index = 3; m2.index = 4;
	let merged = sms.reassemble([ m1, m2 ]);
	eq(length(merged), 1, '4: reassembled into one message');
	eq(merged[0].text, 'AAAAAAAABBBBBBBB', '4: concatenated text in part order');
	eq(merged[0].incomplete, false, '4: complete concatenation');
	eq(merged[0].indexes, [ 3, 4 ], '4: keeps per-part storage indexes for delete');
})();

// --- 5. missing part -> best-effort, flagged incomplete ---------------------
(function () {
	let solo = { udh: { ref: 9, total: 2, part: 1 }, text: 'only', index: 7,
	             sender: 'x', smsc: null, sender_type: 0, timestamp: '', encoding: 'gsm7' };
	let merged = sms.reassemble([ solo ]);
	eq(merged[0].incomplete, true, '5: incomplete concatenation flagged');
	eq(merged[0].text, 'only', '5: partial text still returned');
})();

// --- 6. malformed / non-DELIVER -> null -------------------------------------
eq(sms.decode_deliver(''), null, '6: empty pdu -> null');
eq(sms.decode_deliver('0001'), null, '6: MTI!=DELIVER -> null (SUBMIT first octet 0x01)');

// --- 7. real-world vectors (read off an RG650E SIM, Vodafone DE) -------------
(function () {
	// multi-line mailbox notification
	let m = sms.decode_deliver('0791947122723033200C8130221290950841006230902143324065' +
		'D637396C7EBBCBA06638CD16BFF13AC58A969BC964B2182C57CBE1600A74980E5A97D3EE32C819' +
		'1EA3E5E9319A0E42A7DDF4B29C1D9ECFCB6E9D2206B296E5F3FA18AD08B741B09C0B3673C960321' +
		'B2826D3CD683AD94CA100');
	eq(m.encoding, 'gsm7', '7: real mailbox: gsm7');
	eq(m.sender, '032221095980', '7: real mailbox: sender');
	eq(m.timestamp, '2026-03-09 12:34:23 +01:00', '7: real mailbox: timestamp');
	ok(index(m.text, 'Vodafone Mailbox') == 0, '7: real mailbox: text start');
	ok(index(m.text, '\n') > 0, '7: real mailbox: multi-line (\\n)');

	// German umlaut + ß via the GSM7 basic table ("Freundliche Grüße")
	let d = sms.decode_deliver('07919471227230330405810808F800006270910091938096' +
		'C470DEC80ED34131D051A80311CB6E90303C4FCFE1F2727A0EB2BFDDA0182B970315EBF237081D1' +
		'697DDA07B5A0E0A8BCF65717D8CA6BB40C47419F484D3D36F37283DA783C4E939485F6F83643017' +
		'ECE692C16436100CA68BD940673F9B9E3EBB404679B9EE26B3D36374197494FB3D651688584EBB4' +
		'1D637396C7EBBCB2D6A39DC5600');
	ok(index(d.text, 'DayFlat') == 0, '7: real: text start');
	ok(index(d.text, 'Grüße') > 0, '7: real: German ü/ß decoded from GSM7');
})();

done('test_sms_pdu');
