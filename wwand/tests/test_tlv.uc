// wwand tests — TLV codec.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as tlv from 'wwand/codec/tlv.uc';

// --- primitives -------------------------------------------------------------

let f = { val: { t: 0x01, f: 'u16' } };

eq(hexenc(tlv.pack(f, { val: 0x1234 })), '0102003412', 'u16 pack');
eq(tlv.unpack(f, hexdec('0102003412')).val, 0x1234, 'u16 unpack');

f = { val: { t: 0x10, f: 'u32' } };
eq(tlv.unpack(f, tlv.pack(f, { val: 4000000000 })).val, 4000000000, 'u32 roundtrip');

f = { val: { t: 0x11, f: 'i32' } };
eq(tlv.unpack(f, tlv.pack(f, { val: -5 })).val, -5, 'i32 roundtrip');

f = { val: { t: 0x11, f: 'u64' } };
eq(tlv.unpack(f, tlv.pack(f, { val: 123456789012345 })).val, 123456789012345, 'u64 roundtrip');

// --- floats (LOC service) ----------------------------------------------------

f = { lat: { t: 0x10, f: 'f64' } };
eq(tlv.unpack(f, tlv.pack(f, { lat: 52.5 })).lat, 52.5, 'f64 roundtrip');
eq(tlv.unpack(f, tlv.pack(f, { lat: -13.375 })).lat, -13.375, 'f64 negative');

f = { alt: { t: 0x1B, f: 'f32' } };
eq(tlv.unpack(f, tlv.pack(f, { alt: 34.5 })).alt, 34.5, 'f32 roundtrip');

// --- strings ----------------------------------------------------------------

f = { apn: { t: 0x14, f: 'string' } };
eq(hexenc(tlv.pack(f, { apn: 'web' })), '140300776562', 'string pack');
eq(tlv.unpack(f, hexdec('140300776562')).apn, 'web', 'string unpack');

f = { info: { t: 0x01, f: { pin_id: 'u8', pin: 'lstring' } } };
eq(hexenc(tlv.pack(f, { info: { pin_id: 1, pin: '1234' } })),
	'010600010431323334', 'lstring struct pack (DMS verify pin)');
eq(tlv.unpack(f, hexdec('010600010431323334')).info,
	{ pin_id: 1, pin: '1234' }, 'lstring struct unpack');

// --- addresses --------------------------------------------------------------

f = { ip: { t: 0x1e, f: 'ipv4' } };
// 10.20.30.40 -> u32 0x0a141e28 -> LE bytes 28 1e 14 0a
eq(hexenc(tlv.pack(f, { ip: '10.20.30.40' })), '1e0400281e140a', 'ipv4 pack');
eq(tlv.unpack(f, hexdec('1e0400281e140a')).ip, '10.20.30.40', 'ipv4 unpack');

f = { ip: { t: 0x25, f: { addr: 'ipv6', plen: 'u8' } } };
let v6 = tlv.pack(f, { ip: { addr: '2001:db8:0:0:0:0:0:1', plen: 64 } });
eq(tlv.unpack(f, v6).ip, { addr: '2001:db8:0:0:0:0:0:1', plen: 64 }, 'ipv6+plen roundtrip');

// --- plmn / u24be (cell telemetry) -------------------------------------------

f = { plmn: { t: 0x01, f: 'plmn' } };
// 262/01 -> BCD 62 f2 10
eq(tlv.unpack(f, hexdec('010300' + '62f210')).plmn, '262/01', 'plmn decode 2-digit mnc');
eq(hexenc(tlv.pack(f, { plmn: '262/01' })), '01030062f210', 'plmn encode roundtrip');
// 310/410 (3-digit mnc)
eq(tlv.unpack(f, tlv.pack(f, { plmn: '310/410' })).plmn, '310/410', 'plmn 3-digit mnc roundtrip');

f = { tac: { t: 0x02, f: 'u24be' } };
eq(tlv.unpack(f, tlv.pack(f, { tac: 0x0aff42 })).tac, 0x0aff42, 'u24be roundtrip');

// --- arrays -----------------------------------------------------------------

f = { services: { t: 0x01, f: { n: 'u8', of: { service: 'u8', major: 'u16', minor: 'u16' } } } };
let arr = { services: [ { service: 1, major: 1, minor: 15 }, { service: 3, major: 1, minor: 25 } ] };
eq(tlv.unpack(f, tlv.pack(f, arr)).services, arr.services, 'struct array roundtrip (CTL version info)');

// nested arrays: array whose elements each contain another array — the shape
// of the LTE inter-frequency cell set (freqs[] each with cells[]).
f = { inter: { t: 0x14, f: {
	ue_idle: 'u8',
	freqs: { n: 'u8', of: {
		earfcn: 'u16', thresh_low: 'u8', thresh_high: 'u8', resel_priority: 'u8',
		cells: { n: 'u8', of: { pci: 'u16', rsrq: 'i16', rsrp: 'i16', rssi: 'i16', srxlev: 'i16' } },
	} },
} } };
let inter = { inter: { ue_idle: 1, freqs: [
	{ earfcn: 100, thresh_low: 2, thresh_high: 20, resel_priority: 4,
	  cells: [ { pci: 111, rsrq: -120, rsrp: -1000, rssi: -800, srxlev: 30 },
	           { pci: 222, rsrq: -130, rsrp: -1050, rssi: -820, srxlev: 20 } ] },
	{ earfcn: 1300, thresh_low: 3, thresh_high: 21, resel_priority: 5,
	  cells: [ { pci: 246, rsrq: -110, rsrp: -980, rssi: -780, srxlev: 40 } ] },
] } };
eq(tlv.unpack(f, tlv.pack(f, inter)).inter, inter.inter, 'nested array roundtrip (LTE inter-frequency cells)');

// --- multiple TLVs, optional skipping ---------------------------------------

f = {
	a: { t: 0x10, f: 'u8' },
	b: { t: 0x11, f: 'u8' },
	c: { t: 0x12, f: 'string' },
};
let packed = tlv.pack(f, { a: 7, c: 'x' });
eq(hexenc(packed), '10010007120100' + '78', 'optional TLV skipped');
let un = tlv.unpack(f, packed);
eq(un.a, 7, 'multi unpack a');
ok(!exists(un, 'b'), 'absent optional stays absent');
eq(un.c, 'x', 'multi unpack c');

// --- result TLV -------------------------------------------------------------

// result TLV 0x02: result=1 (failure), error=0x0e (call failed)
let res = tlv.unpack({}, hexdec('0204000100' + '0e00'));
eq(res._result, { result: 1, error: 14 }, 'result TLV decoded');

// --- robustness -------------------------------------------------------------

// unknown TLV type collected in _raw
res = tlv.unpack({}, hexdec('7f0200abcd'));
eq(hexenc(res._raw['127']), 'abcd', 'unknown TLV lands in _raw');

// truncated TLV must not throw
res = tlv.unpack({}, hexdec('10ff00ab'));
ok(res._truncated, 'overrunning TLV flagged as truncated');

// garbage / short input must not throw
tlv.unpack(f, hexdec('10'));
tlv.unpack(f, '');
tlv.unpack(f, null);
ok(true, 'short/garbage input survived');

done('test_tlv');
