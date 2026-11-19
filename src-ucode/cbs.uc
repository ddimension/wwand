// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — Cell Broadcast (TS 23.041): decode a page, join a message's pages,
// recognise the repeats, keep the last messages, and name the public warning
// channels (ETWS, CMAS / EU-Alert).
//
// A network repeats a broadcast every few minutes for as long as it is in
// force, and an emergency alert for hours. A message is therefore identified
// by its Message Identifier and Serial Number (geographic scope, message code
// AND update number — §9.4.1.2.1): the same pair again is a repeat, an
// incremented update number is a new version that is shown again.
//
// The page arrives in one of two formats: the 88-octet GSM page (§9.4.1.2),
// which QMI and +CBM hand over in the common case, or the UMTS message
// (§9.4.2.2, also what LTE SIB12 and NR carry) with every page in it. Which
// one is told by the length, as ModemManager does (mm-cbm-part.c:147-241,
// 1.25.95) — except that ModemManager reads only the GSM one.
//
//   page(octets)          -> { id, serial, gs, code, update, dcs, page, pages, text, language } | null
//   receive(store, octets, at) -> a COMPLETE new message, or null (a part, a repeat, junk)
//   pws(id)               -> { kind, name } for a public-warning channel, null otherwise

'use strict';

import * as sms_pdu from 'wwand.sms_pdu';

// how many messages a modem keeps (the newest first), and how long a repeat
// is recognised after the message was last seen. A day covers how long an
// alert stays in force; after that the same serial is a broadcast reissued.
const KEEP = 20;
const REPEAT_S = 86400;

// a page part that never completes is forgotten after this
const PARTIAL_S = 600;

function be16(a, i)
{
	return ((a[i] ?? 0) << 8) | (a[i + 1] ?? 0);
}

// text of one page's content: the padding (CR in GSM7 and UCS2 alike, §9.4.1.2.3)
// and a trailing LF go
function page_text(dcs, content)
{
	let t = sms_pdu.cbs_text(dcs, content);

	if (t.text != null)
		t.text = replace(t.text, /[\r\n]+$/, '');

	return t;
}

// the serial number fields (§9.4.1.2.1): geographic scope 2 bits, message
// code 10 bits, update number 4 bits
function serial_fields(serial)
{
	return { gs: (serial >> 14) & 3, code: (serial >> 4) & 0x3ff, update: serial & 0xf };
}

export function page(octets)
{
	let n = length(octets ?? []);

	// UMTS: message type 1, id, serial, DCS, page count, then per page 82
	// octets of content and its used length
	if (n != 88 && n >= 7 && octets[0] == 1) {
		let pages = octets[6], dcs = octets[5], text = '', lang = null;

		if (pages < 1 || pages > 15 || n < 7 + pages * 83)
			return null;

		for (let p = 0; p < pages; p++) {
			let off = 7 + p * 83;
			let used = min(octets[off + 82], 82);
			let t = page_text(dcs, slice(octets, off, off + used));

			text += t.text ?? '';
			lang = lang ?? t.language;
		}

		return { id: be16(octets, 1), serial: be16(octets, 3), ...serial_fields(be16(octets, 3)),
		         dcs: dcs, page: 1, pages: 1, text: text, language: lang, format: 'umts' };
	}

	if (n != 88)
		return null;

	let serial = be16(octets, 0);
	let pp = octets[5];
	let pages = pp & 0x0f, pg = (pp >> 4) & 0x0f;

	// 0x00 is a single page (§9.4.1.2.4: "0000" reserved, read as 1/1)
	if (pages == 0 || pg == 0)
		pages = pg = 1;

	let t = page_text(octets[4], slice(octets, 6, 88));

	return { id: be16(octets, 2), serial: serial, ...serial_fields(serial),
	         dcs: octets[4], page: pg, pages: pages, text: t.text, language: t.language,
	         raw: t.raw, format: 'gsm' };
};

// PWS channels (TS 23.041 §9.4.1.2.2; EU-Alert, ETSI TS 102 900): what a
// message on `id` is. The language variants (id + 13, 4383-4395) carry the
// same alert in a second language.
const CMAS = [ 'presidential', 'extreme', 'extreme', 'extreme', 'extreme',
	'severe', 'severe', 'severe', 'severe', 'amber', 'test', 'exercise', 'operator' ];

export function pws(id)
{
	if (id >= 4352 && id <= 4359)
		return { kind: 'etws', name: [ 'earthquake', 'tsunami', 'earthquake_tsunami', 'test', 'other' ][id - 4352] ?? 'etws' };

	if (id >= 4370 && id <= 4382)
		return { kind: 'cmas', name: CMAS[id - 4370] };

	if (id >= 4383 && id <= 4395)
		return { kind: 'cmas', name: CMAS[id - 4383], second_language: true };

	if (id >= 4396 && id <= 4399)
		return { kind: 'cmas', name: (id <= 4397) ? 'public_safety' : 'state_local_test' };

	if (id >= 0x1100 && id <= 0x18ff)
		return { kind: 'pws', name: 'reserved' };

	return null;
};

export function create_store()
{
	return { messages: [], seen: {}, partial: {} };
};

// One page in; the message it completes, if it is new. `at` = time() now.
export function receive(store, octets, at)
{
	let p = page(octets);

	if (!p)
		return null;

	// forget old repeats and abandoned parts
	for (let k, t in store.seen)
		if (at - t > REPEAT_S)
			delete store.seen[k];

	for (let k, v in store.partial)
		if (at - v.at > PARTIAL_S)
			delete store.partial[k];

	let key = sprintf('%d:%d:%d', p.id, p.serial, p.dcs);

	if (store.seen[key] != null) {
		store.seen[key] = at;   // still in force: the clock starts again
		return null;
	}

	let text = p.text;

	if (p.pages > 1) {
		let part = store.partial[key] ?? { at: at, pages: {} };

		part.pages[sprintf('%d', p.page)] = p.text ?? '';
		store.partial[key] = part;

		if (length(keys(part.pages)) < p.pages)
			return null;

		text = '';

		for (let i = 1; i <= p.pages; i++)
			text += part.pages[sprintf('%d', i)] ?? '';

		delete store.partial[key];
	}

	store.seen[key] = at;

	let w = pws(p.id);
	let msg = { id: p.id, serial: p.serial, code: p.code, update: p.update, gs: p.gs,
	            language: p.language, text: text, raw: p.raw, at: at,
	            kind: w?.kind, name: w?.name };

	unshift(store.messages, msg);

	if (length(store.messages) > KEEP)
		splice(store.messages, KEEP);

	return msg;
};

// `list cb_channels` -> [ { start, end } ], ranges "4370-4399" or single ids.
// The default when the feature is on but names none: the public warning
// channels — ETWS (4352-4359) and CMAS/EU-Alert with their language variants
// (4370-4399).
export const DEFAULT_CHANNELS = [ { start: 4352, end: 4359 }, { start: 4370, end: 4399 } ];

export function parse_channels(list)
{
	let out = [];

	for (let e in ((type(list) == 'array') ? list : (list != null ? split(sprintf('%s', list), /[ ,]+/) : []))) {
		let m = match(trim(e), /^([0-9]+)(-([0-9]+))?$/);

		if (!m)
			continue;

		let a = +m[1], b = (m[3] != null) ? +m[3] : a;

		if (a > 0xffff || b > 0xffff || b < a)
			continue;

		push(out, { start: a, end: b });
	}

	return length(out) ? out : null;
};

// channels as the 27.005 +CSCB <mids> string: "4352-4359,4370-4399"
export function cscb_mids(channels)
{
	return join(',', map(channels, (c) => (c.start == c.end) ? sprintf('%d', c.start)
	                                                           : sprintf('%d-%d', c.start, c.end)));
};
