// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — the SIM inventory: every card wwand has seen, by ICCID, and where
// it is — which modem, which slot, which eUICC and profile, or which reader
// on the router (wwand-rsim). One table for the status page and `wwandctl
// sims` now, and the lookup an ICCID-bound interface will need later.
//
// Each SOURCE reports its complete current view (`observe(key, cards)`):
// the active card of a modem, its slot list, the profile list of its eUICC,
// a reader. A card a source no longer reports is not deleted but marked
// absent — "known, not here" is what an ICCID binding has to be able to
// tell from "never seen".
//
// Traps this is shaped around (each has bitten or would):
// - An eUICC has no ICCID of its own: EF_ICCID reads the ENABLED profile's.
//   So the active card of an eSIM modem and that profile are one entry, not
//   a physical card plus a profile. Profiles are grouped under the EID.
// - A modem using a REMOTE card (wwand-rsim) reports that card as its own
//   active one. Its place is the reader, not the modem's slot: the source
//   says so with `reader`.
// - The same ICCID arrives in different spellings: QMI decodes the BCD with
//   a trailing F for 19-digit ICCIDs, AT+CCID answers with or without it,
//   some firmware in lower case. Normalised before anything is compared.
// - A card change clears the modem's identity before the new card is read
//   (simops card_changed). A source that has no reading yet reports
//   NOTHING rather than an empty list: `observe(key, null)` changes nothing,
//   `observe(key, [])` says the source is empty now.

'use strict';

// '8949 0200 0018 4496 711F' / lower case / spaces -> '89490200001844967110'-style digits
export function norm_iccid(v)
{
	if (type(v) != 'string')
		return null;

	let s = uc(replace(v, /[ \t-]/g, ''));

	s = replace(s, /F+$/, '');

	return match(s, /^[0-9]{18,20}$/) ? s : null;
};

// create({ now }): `now` in seconds, injectable for the tests
export function create(o)
{
	let now = o?.now ?? (() => time());
	let cards = {};      // iccid -> entry
	let sources = {};    // key -> [ iccid ... ] the source reported last

	let self = {};

	// One source's complete view. cards: [ { iccid, imsi?, modem?, slot?,
	// active?, reader?, eid?, profile? { state, name } } ], or null for "no
	// reading" (nothing changes).
	self.observe = function(key, list) {
		if (list == null)
			return;

		let t = now();
		let seen = [];

		for (let c in list) {
			let id = norm_iccid(c?.iccid);

			if (!id)
				continue;

			push(seen, id);

			let e = cards[id] ??= { iccid: id, first_seen: t, sources: {} };

			e.present = true;
			e.last_seen = t;
			e.sources[key] = true;

			// what this source knows; a later report of the same card from a
			// source that knows less does not erase what another one said
			for (let f in [ 'imsi', 'modem', 'slot', 'reader', 'eid' ])
				if (c[f] != null)
					e[f] = c[f];

			if (c.active != null)
				e.active = !!c.active;

			if (c.profile != null)
				e.profile = { state: c.profile.state ?? null, name: c.profile.name ?? null };
		}

		// what this source reported before and does not any more
		for (let id in (sources[key] ?? [])) {
			if (index(seen, id) >= 0 || !cards[id])
				continue;

			delete cards[id].sources[key];

			// gone only when NO source still has it
			if (!length(keys(cards[id].sources))) {
				cards[id].present = false;
				cards[id].active = false;
			}
		}

		sources[key] = seen;
	};

	// a source that went away altogether (a modem removed, a reader deleted)
	self.forget = function(key) {
		self.observe(key, []);
		delete sources[key];
	};

	// every source whose key starts with `prefix` and is not in `keep`
	self.forget_except = function(prefix, keep) {
		for (let k in keys(sources))
			if (substr(k, 0, length(prefix)) == prefix && index(keep, k) < 0)
				self.forget(k);
	};

	self.find = function(iccid) {
		let id = norm_iccid(iccid);

		return id ? cards[id] : null;
	};

	// present cards first, then by place, then by ICCID
	self.list = function() {
		let out = map(values(cards), (e) => ({ ...e, sources: sort(keys(e.sources)) }));

		return sort(out, (a, b) =>
			(a.present != b.present) ? (a.present ? -1 : 1)
			: ((a.reader ?? a.modem ?? '') != (b.reader ?? b.modem ?? ''))
				? (((a.reader ?? a.modem ?? '') < (b.reader ?? b.modem ?? '')) ? -1 : 1)
			: (a.iccid < b.iccid) ? -1 : (a.iccid > b.iccid) ? 1 : 0);
	};

	return self;
};

// The cards a modem's state tells about, as observe() lists, keyed by source.
// A modem object carries: info.{iccid,imsi} (the active card), active_slot,
// slots (the last slot_status read, if any), esim_info.{eid,profiles}.
// `remote` names the reader when the active card is remote (wwand-rsim).
// Null for a source with no reading.
export function from_modem(name, m, remote)
{
	let out = {};
	let active_id = norm_iccid(m?.info?.iccid);

	// the active card — unless it is an eUICC profile, which the profile
	// list below reports with more detail (same ICCID, same entry anyway)
	out[sprintf('modem:%s:active', name)] = (m?.info?.iccid == null) ? null : [ {
		iccid: m.info.iccid, imsi: m.info.imsi ?? null, active: true,
		modem: remote ? null : name, slot: remote ? null : (m.active_slot ?? null),
		reader: remote ?? null,
	} ];

	if (type(m?.slots) == 'array')
		out[sprintf('modem:%s:slots', name)] = map(filter(m.slots, (s) => !s.inferred && s.iccid != null), (s) => ({
			iccid: s.iccid, modem: name, slot: s.physical ?? null,
			active: !!s.active, eid: s.is_euicc ? (s.eid ?? null) : null,
		}));

	if (type(m?.esim_info?.profiles) == 'array')
		out[sprintf('modem:%s:esim', name)] = map(m.esim_info.profiles, (p) => ({
			iccid: p.iccid, modem: name, eid: m.esim_info.eid ?? null,
			slot: m.active_slot ?? null,
			active: (p.state == 'enabled' || p.state == 1) && (norm_iccid(p.iccid) == active_id),
			profile: { state: (p.state == 1) ? 'enabled' : (p.state == 0) ? 'disabled' : p.state,
			           name: p.nickname ?? p.name ?? null },
		}));

	return out;
};
