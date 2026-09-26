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
	let sources = {};    // key -> { iccid -> what that source reported }

	let self = {};

	// An entry is DERIVED from the sources that report it now, every time
	// one of them changes. Merging reports into the entry instead left a
	// source's contribution behind after the source stopped reporting: a card
	// back from the reader kept `reader` and was still shown there. A card no
	// source reports keeps its last place — "not present, last seen in X".
	let rebuild = (id) => {
		let e = cards[id];
		let from = [];

		for (let k in sort(keys(sources)))
			if (sources[k][id])
				push(from, [ k, sources[k][id] ]);

		let pick = (f) => {
			for (let kc in from)
				if (kc[1][f] != null)
					return kc[1][f];

			return null;
		};

		e.sources = {};
		for (let kc in from)
			e.sources[kc[0]] = true;

		e.present = length(from) > 0;
		e.active = e.present && length(filter(from, (kc) => kc[1].active)) > 0;

		if (!e.present)
			return;

		// one place: a remote card is in its reader, not in a modem slot
		e.reader = pick('reader');
		e.modem = e.reader ? null : pick('modem');
		e.slot = e.reader ? null : pick('slot');
		e.eid = pick('eid');

		let p = pick('profile');

		e.profile = p ? { state: p.state ?? null, name: p.name ?? null } : null;

		// the IMSI is only known while the card is read; keep the last one
		let imsi = pick('imsi');

		if (imsi != null)
			e.imsi = imsi;
	};

	// One source's complete view. list: [ { iccid, imsi?, modem?, slot?,
	// active?, reader?, eid?, profile? { state, name } } ], or null for "no
	// reading" (nothing changes).
	self.observe = function(key, list) {
		if (list == null)
			return;

		let t = now();
		let snap = {};

		for (let c in list) {
			let id = norm_iccid(c?.iccid);

			if (!id)
				continue;

			snap[id] = c;
			cards[id] ??= { iccid: id, first_seen: t, sources: {} };
			cards[id].last_seen = t;
		}

		let affected = { ...(sources[key] ?? {}), ...snap };

		sources[key] = snap;

		for (let id in keys(affected))
			rebuild(id);
	};

	// a source that went away altogether (a modem removed, a reader deleted)
	self.forget = function(key) {
		let had = sources[key] ?? {};

		delete sources[key];

		for (let id in keys(had))
			if (cards[id])
				rebuild(id);
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
	// every source key is always there, null when it has no reading: a
	// modem mid-restart must not look like one whose slots and profiles
	// were emptied (the caller forgets keys it no longer sees)
	let out = {
		[sprintf('modem:%s:active', name)]: null,
		[sprintf('modem:%s:slots', name)]: null,
		[sprintf('modem:%s:esim', name)]: null,
	};
	let active_id = norm_iccid(m?.info?.iccid);

	// A missing ICCID is normally a reading still to come (the identity is
	// re-read after a card change). Not when the modem stopped because it
	// FOUND no card: that is a reading, and it says the card is gone. QMI
	// names it no_sim (sim.uc), MBIM and NCM sim_absent.
	let nocard = (m?.state == 'SIM_BLOCKED' && index([ 'no_sim', 'sim_absent' ], m?.sim_block?.reason) >= 0);

	// the active card — unless it is an eUICC profile, which the profile
	// list below reports with more detail (same ICCID, same entry anyway)
	out[sprintf('modem:%s:active', name)] = nocard ? [] : (m?.info?.iccid == null) ? null : [ {
		iccid: m.info.iccid, imsi: m.info.imsi ?? null, active: true,
		modem: remote ? null : name, slot: remote ? null : (m.active_slot ?? null),
		reader: remote ?? null,
	} ];

	// "in use" is the card the modem runs on, matched by ICCID: the ACTIVE
	// slot's card is not in use while the modem works on a remote one, and
	// the slot list can be older than the last card change.
	// The slot list is read once per registration, so without a card the
	// active slot's entry is the card that left.
	if (type(m?.slots) == 'array')
		out[sprintf('modem:%s:slots', name)] = map(filter(m.slots, (s) => !s.inferred && s.iccid != null && !(nocard && s.active)), (s) => ({
			iccid: s.iccid, modem: name, slot: s.physical ?? null,
			active: !!s.active && active_id != null && norm_iccid(s.iccid) == active_id,
			eid: s.is_euicc ? (s.eid ?? null) : null,
		}));

	// the profiles sit in the eUICC's slot, which is not the active one when
	// the modem runs on another card (a second slot, a remote SIM)
	let euicc_slot = m?.active_slot ?? null;

	for (let s in ((type(m?.slots) == 'array') ? m.slots : []))
		if (s.is_euicc && s.eid != null && s.eid == m?.esim_info?.eid)
			euicc_slot = s.physical ?? euicc_slot;

	if (type(m?.esim_info?.profiles) == 'array')
		out[sprintf('modem:%s:esim', name)] = map(m.esim_info.profiles, (p) => ({
			iccid: p.iccid, modem: name, eid: m.esim_info.eid ?? null,
			slot: euicc_slot,
			active: (p.state == 'enabled' || p.state == 1) && (norm_iccid(p.iccid) == active_id),
			profile: { state: (p.state == 1) ? 'enabled' : (p.state == 0) ? 'disabled' : p.state,
			           name: p.nickname ?? p.name ?? null },
		}));

	return out;
};
