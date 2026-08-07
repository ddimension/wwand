// wwand tests — codec/hex.uc: the single home for byte/hex/BCD conversion
// (hex strings, binary strings, nibble-swapped BCD, ICCID/EID codecs).
'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as hex from 'wwand/codec/hex.uc';

// --- hex string <-> byte array ----------------------------------------------

eq(hex.hex_to_arr('00ff10'), [ 0, 255, 16 ], 'hex_to_arr: basic');
eq(hex.arr_to_hex([ 0, 255, 16 ]), '00ff10', 'arr_to_hex: basic');
eq(hex.hex_to_arr(hex.arr_to_hex([ 1, 2, 3, 254 ])), [ 1, 2, 3, 254 ], 'arr/hex roundtrip');
eq(hex.hex_to_arr(''), [], 'hex_to_arr: empty');
eq(hex.arr_to_hex([]), '', 'arr_to_hex: empty');
eq(hex.hex_to_arr('A0Fb'), [ 0xa0, 0xfb ], 'hex_to_arr: mixed case');

// --- hex string <-> binary string -------------------------------------------

let bin = hex.hex_to_bin('89abcdef');
eq(length(bin), 4, 'hex_to_bin: length');
eq(ord(bin, 0), 0x89, 'hex_to_bin: first byte');
eq(hex.bin_to_hex(bin), '89abcdef', 'bin/hex roundtrip');

// --- nibble-swapped BCD ------------------------------------------------------

// 0x21 0x43 -> "1234"
eq(hex.bcd_swapped_arr([ 0x21, 0x43 ]), '1234', 'bcd_swapped_arr: swaps nibbles');

// --- ICCID -------------------------------------------------------------------

// real-world GDSP ICCID (odd length -> F padding in the last byte)
let iccid = '89882390000587072730';
let bytes = hex.iccid_to_bytes(iccid);
eq(hex.bytes_to_iccid(bytes), iccid, 'iccid: bytes roundtrip (even length)');

let odd = '8949020000102283249';
eq(hex.bytes_to_iccid(hex.iccid_to_bytes(odd)), odd, 'iccid: roundtrip strips F padding');

// binary-string variant (UIM EF read shape)
let raw = '';
for (let b in hex.iccid_to_bytes(odd))
	raw += sprintf('%c', b);
eq(hex.decode_iccid(raw), odd, 'decode_iccid: binary-string variant matches');

// --- EID ---------------------------------------------------------------------

// the EID is plain (unswapped) BCD, 32 digits — its digit string doubles as
// its own hex encoding, so hex_to_bin builds the raw wire form directly
let eid = '89049032004008882600000009611596';
eq(hex.decode_eid(hex.hex_to_bin(eid)), eid, 'decode_eid: 32-digit EID decodes');

done('test_hex');
