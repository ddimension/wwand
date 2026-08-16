// wwand tests — field-level gap-fill/merge primitive (codec/schema/merge.uc).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as merge from 'wwand/codec/schema/merge.uc';

// --- gap: fill only null/absent, never clobber -------------------------------

let d = { a: 1, b: null };
merge.fill(d, { a: 9, b: 2, c: 3 }, { gap: [ 'a', 'b', 'c' ] });
eq(d, { a: 1, b: 2, c: 3 }, 'gap: fills null (b) + absent (c), keeps existing (a)');

// src field null/absent leaves dst untouched
d = { a: null };
merge.fill(d, { a: null, b: null }, { gap: [ 'a', 'b' ] });
eq(d, { a: null }, 'gap: null/absent src does not create or set a field');

// gap: true / '*' = every field present in src
d = { a: 1 };
merge.fill(d, { a: 9, b: 2, c: 3 }, { gap: true });
eq(d, { a: 1, b: 2, c: 3 }, 'gap:true = all src keys, still gap-only');
d = { a: 1 };
merge.fill(d, { b: 2 }, { gap: '*' });
eq(d, { a: 1, b: 2 }, "gap:'*' same as true");

// --- prefer: overwrite when src has a value ----------------------------------

d = { a: 1, b: 2 };
merge.fill(d, { a: 9, b: null }, { prefer: [ 'a', 'b' ] });
eq(d, { a: 9, b: 2 }, 'prefer: overwrites when src present (a), keeps when src null (b)');

// --- score: delegate to a per-field resolver ---------------------------------

let keepMax = (cur, inc) => (inc != null && inc > (cur ?? -2147483648)) ? inc : cur;
d = { x: 5, y: 5 };
merge.fill(d, { x: 9, y: 1 }, { score: { x: keepMax, y: keepMax } });
eq(d, { x: 9, y: 5 }, 'score: resolver picks winner per field');

// --- guard: false copies nothing ---------------------------------------------

d = { a: null };
merge.fill(d, { a: 7 }, { gap: [ 'a' ], guard: (dst, src) => false });
eq(d, { a: null }, 'guard:false = nothing copied');
d = { a: null };
merge.fill(d, { a: 7 }, { gap: [ 'a' ], guard: (dst, src) => true });
eq(d, { a: 7 }, 'guard:true = fill proceeds');
// realistic identity guard: earfcn must match
d = { earfcn: 100, band: null };
merge.fill(d, { earfcn: 200, band: 3 }, { gap: [ 'band' ],
	guard: (dst, src) => dst.earfcn == null || src.earfcn == null || dst.earfcn == src.earfcn });
eq(d, { earfcn: 100, band: null }, 'guard: earfcn mismatch leaves band null');
d = { earfcn: 100, band: null };
merge.fill(d, { earfcn: 100, band: 3 }, { gap: [ 'band' ],
	guard: (dst, src) => dst.earfcn == null || src.earfcn == null || dst.earfcn == src.earfcn });
eq(d, { earfcn: 100, band: 3 }, 'guard: earfcn match fills band');

// --- prov: record origin only for taken fields -------------------------------

d = { a: 1, b: null };
merge.fill(d, { a: 9, b: 2, c: 3 }, { gap: [ 'a', 'b', 'c' ], src: 'at', prov: true });
eq(d._prov, { b: 'at', c: 'at' }, 'prov: only taken fields (b,c) tagged, not kept a');
// no prov key when nothing was taken
d = { a: 1 };
merge.fill(d, { a: 9 }, { gap: [ 'a' ], src: 'at', prov: true });
ok(d._prov == null, 'prov: no _prov when nothing taken');

// --- shallow: array/object fields copied by reference, never walked ----------

let arr = [ { pci: 1 }, { pci: 2 } ];
d = { cells: null };
merge.fill(d, { cells: arr }, { gap: [ 'cells' ] });
ok(d.cells === arr, 'shallow: array field copied as-is (same reference, not walked)');

// --- null handling -----------------------------------------------------------

d = { a: 1 };
eq(merge.fill(d, null, { gap: [ 'a' ] }), { a: 1 }, 'null src returns dst unchanged');
let seeded = merge.fill(null, { a: 5 }, { gap: [ 'a' ] });
eq(seeded, { a: 5 }, 'null dst is seeded to {} then filled');

done('test_merge');
