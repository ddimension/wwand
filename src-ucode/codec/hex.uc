// wwand — shared byte/hex/BCD helpers.
//
// One home for the conversions that were re-implemented across sim/esim/sms/
// mbim_backend. Two data shapes exist in the tree and both are supported:
//   byte ARRAYS   ([0x89, 0x49, …])   — QMI TLV payloads (schema 'of u8')
//   binary STRING ("\x89\x49…")       — MBIM InformationBuffers, EF lstrings

'use strict';

const NIBBLES = '0123456789abcdef';

// byte array -> lowercase hex string
export function arr_to_hex(a)
{
	let s = '';

	for (let b in (a ?? []))
		s += sprintf('%02x', b);

	return s;
};

// hex string -> byte array (odd trailing nibble ignored)
export function hex_to_arr(s)
{
	let out = [];

	for (let i = 0; i + 1 < length(s ?? ''); i += 2)
		push(out, hex(substr(s, i, 2)));

	return out;
};

// binary string -> lowercase hex string
export function bin_to_hex(b)
{
	let s = '';

	for (let i = 0; i < length(b ?? ''); i++)
		s += sprintf('%02x', ord(b, i));

	return s;
};

// hex string -> binary string (odd trailing nibble ignored)
export function hex_to_bin(h)
{
	let o = '';

	for (let i = 0; i + 1 < length(h ?? ''); i += 2)
		o += chr(hex(substr(h, i, 2)));

	return o;
};

// --- BCD (SIM identity) ------------------------------------------------------

// nibble-swapped BCD byte ARRAY -> digit string (EF-IMSI/EF-ICCID raw bytes;
// the old proto_qmi_convert_from_uimbyte)
export function bcd_swapped_arr(bytes)
{
	let s = '';

	for (let b in (bytes ?? []))
		s += sprintf('%x%x', b & 0xf, b >> 4);

	return s;
};

// nibble-swapped BCD binary STRING (lstring) -> digit string with the trailing
// F padding stripped — the ICCID as humans write it
export function decode_iccid(raw)
{
	let s = '';

	for (let i = 0; i < length(raw ?? ''); i++) {
		let b = ord(raw, i);
		s += sprintf('%x%x', b & 0xf, b >> 4);
	}

	return replace(s, /f+$/, '');
};

// EID is plain BCD, high nibble first (SGP.02) — no nibble swap
export function decode_eid(raw)
{
	let s = '';

	for (let i = 0; i < length(raw ?? ''); i++) {
		let b = ord(raw, i);
		s += sprintf('%x%x', b >> 4, b & 0xf);
	}

	return s;
};

// ICCID digit string -> nibble-swapped BCD byte array (odd length F-padded),
// the wire form of the SGP.22 iccid TLV (0x5A)
export function iccid_to_bytes(iccid)
{
	let out = [];
	let s = lc(iccid ?? '');

	if (length(s) % 2)
		s += 'f';

	for (let i = 0; i < length(s); i += 2) {
		let lo = index(NIBBLES, substr(s, i, 1));
		let hi = index(NIBBLES, substr(s, i + 1, 1));

		push(out, ((hi < 0 ? 0xf : hi) << 4) | (lo < 0 ? 0xf : lo));
	}

	return out;
};

// nibble-swapped BCD byte array -> ICCID digit string (trailing F stripped)
export function bytes_to_iccid(b)
{
	let s = '';

	for (let x in (b ?? []))
		s += sprintf('%x%x', x & 0xf, x >> 4);

	return replace(s, /f+$/, '');
};
