// wwand tests — EARFCN / NR-ARFCN -> 3GPP band derivation (codec/arfcn_bands.uc).
//
// Mirrors the LuCI bands.js table; these anchors are the same 3GPP TS 36.101 /
// 38.104 reference points so a drift between the two tables shows up here.
// mhz is checked within a tolerance (it is a float built from 0.1/0.015 steps).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as bands from 'wwand/codec/arfcn_bands.uc';

// lte(earfcn) -> assert band label + centre freq (MHz, within 0.05)
function lte(earfcn, band, mhz, msg)
{
	let d = bands.lte_band(earfcn);
	eq(d?.band, band, msg + ' (band)');
	if (band != null)
		ok(d != null && d.mhz > mhz - 0.05 && d.mhz < mhz + 0.05, msg + ' (mhz)');
}

// --- lte_band(): band edges (36.101 Table 5.7.3-1) + mid-band freq ----------

lte(0,     'B1',  2110,   'lte earfcn 0 -> B1 low edge');
lte(300,   'B1',  2140,   'lte earfcn 300 -> B1 2140 MHz');
lte(1575,  'B3',  1842.5, 'lte earfcn 1575 -> B3 (DE 1800)');
lte(2850,  'B7',  2630,   'lte earfcn 2850 -> B7');
lte(3450,  'B8',  925,    'lte earfcn 3450 -> B8 low edge (900)');
lte(6300,  'B20', 806,    'lte earfcn 6300 -> B20 (800 DD)');
lte(38750, 'B40', 2310,   'lte earfcn 38750 -> B40 TDD');
lte(40620, 'B41', 2593,   'lte earfcn 40620 -> B41 TDD');
lte(66486, 'B66', 2115,   'lte earfcn 66486 -> B66');
lte(600,   'B2',  1930,   'lte earfcn 600 -> B2 low edge (disjoint)');

// gaps / out-of-range -> null
eq(bands.lte_band(5000), null, 'lte earfcn 5000 -> gap between B11/B12 -> null');
eq(bands.lte_band(99999),null, 'lte earfcn 99999 -> out of range -> null');
eq(bands.lte_band(null), null, 'lte null earfcn -> null');

// --- nr_arfcn_to_mhz() (38.104 Table 5.4.2.1-1) ------------------------------

ok(bands.nr_arfcn_to_mhz(400000) == 2000, 'nr freq: FR1-low 400000 -> 2000 MHz');
ok(bands.nr_arfcn_to_mhz(700000) == 4500, 'nr freq: FR1-mid 700000 -> 4500 MHz');
ok(bands.nr_arfcn_to_mhz(2016667) == 24250.08, 'nr freq: FR2 boundary 2016667 -> 24250.08 MHz');

// --- nr_band() ---------------------------------------------------------------

// n78 3.5 GHz (ARFCN 636666 -> ~3550 MHz; n48 3550-3700 comes AFTER n78 in the
// table so the overlap resolves to n78 first)
let n78 = bands.nr_band(636666);
eq(n78.band, 'n78', 'nr arfcn 636666 -> n78');
ok(n78.mhz > 3549 && n78.mhz < 3551, 'nr n78 centre ~3550 MHz');

// n1 2.1 GHz (ARFCN 428000 -> 2140 MHz, n1 2110-2170 before n65/n66 overlap)
eq(bands.nr_band(428000).band, 'n1', 'nr arfcn 428000 -> n1 (before n65/n66)');

// n28 700 MHz (ARFCN 154600 -> 773 MHz)
eq(bands.nr_band(154600).band, 'n28', 'nr arfcn 154600 -> n28 (700 DD)');

// FR2 mmWave (~28 GHz -> n257 26500-29500, before n261)
eq(bands.nr_band(2079167).band, 'n257', 'nr arfcn 2079167 -> n257 (~28 GHz)');
let mm = bands.nr_band(2100000);
ok(mm.mhz > 24250 && mm.band != null, 'nr FR2 arfcn -> mmWave band + freq');

// valid centre freq (1200 MHz, between n8 960 and n76 1427) -> band null, mhz kept
let gap = bands.nr_band(240000);
ok(gap != null && gap.mhz == 1200 && gap.band == null,
	'nr arfcn in no NR band -> {band:null, mhz kept}');
eq(bands.nr_band(null), null, 'nr null arfcn -> null');

done('test_arfcn_bands');
