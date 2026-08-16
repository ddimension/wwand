// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — field-level gap-fill/merge for canonical telemetry objects.
//
// The generalisation of codec/schema/rat.uc's merge(): copies fields from a
// secondary-transport object `src` into a canonical target `dst` per a small
// policy spec, so a canonical object (signal / cells / serving / …) can be
// progressively completed from whatever backends a modem exposes — without
// discarding data that only a secondary transport carries (e.g. AT `band` on top
// of QMI/MBIM cell-location metrics).
//
// PURE by design: no imports, no I/O, no backend knowledge. Every
// transport/order/availability decision belongs to the duck-typed caller
// (modem_common). fill() only shuffles plain object fields.
//
// DELIBERATELY SHALLOW / scalar-and-reference: fill() never walks into nested
// arrays (per-cell metric lists) — it copies a field's value/reference as a
// whole. So you cannot accidentally splice one transport's serving-cell identity
// with another's per-cell metrics; the snapshot rule is structural.
//
//   fill(dst, src, {
//     src:    'at',                  // provenance tag for taken fields
//     gap:    [ 'band', … ] | true,  // copy only when dst[f]==null && src[f]!=null
//                                    //   (true / '*' = every field present in src)
//     prefer: [ 'x', … ],            // src[f] overwrites whenever src[f]!=null
//     score:  { f: (cur,inc)=>win }, // per-field resolver (e.g. rat.merge)
//     guard:  (dst,src)=>bool,       // false => copy nothing at all
//     prov:   true,                  // record dst._prov[f]=src for taken fields
//   }) -> dst   (mutated in place; a null dst is seeded to {})

'use strict';

export function fill(dst, src, spec)
{
	if (src == null)
		return dst;

	dst = dst ?? {};
	spec = spec ?? {};

	// snapshot-consistency gate: bail entirely if the two samples disagree
	// (e.g. a handover changed the serving cell between the two reads)
	if (type(spec.guard) == 'function' && !spec.guard(dst, src))
		return dst;

	let took = spec.prov ? [] : null;
	let take = (f) => { dst[f] = src[f]; if (took) push(took, f); };

	// gap: fill only fields the primary left null/absent (the progressive fill)
	let gap = spec.gap;
	if (gap === true || gap == '*')
		gap = keys(src);
	for (let f in (gap ?? []))
		if (dst[f] == null && src[f] != null)
			take(f);

	// prefer: the finer source overwrites whenever it has a value
	for (let f in (spec.prefer ?? []))
		if (src[f] != null)
			take(f);

	// score: delegate the winner decision to a per-field resolver (rat.merge et al.)
	for (let f, resolve in (spec.score ?? {})) {
		let win = resolve(dst[f], src[f]);
		if (win !== dst[f]) {
			dst[f] = win;
			if (took && win === src[f])
				push(took, f);
		}
	}

	if (took && length(took)) {
		dst._prov = dst._prov ?? {};
		for (let f in took)
			dst._prov[f] = spec.src ?? true;
	}

	return dst;
};
