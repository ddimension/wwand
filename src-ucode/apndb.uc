// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — internal ICCID-prefix -> APN defaults table (AUTOSETUP ONLY).
//
// Used exclusively by the zero-config autosetup: when wwand creates the
// initial configuration itself (no wwand_modem / proto-wwand interface
// existed), the active SIM's ICCID is matched here and the values are COPIED
// into /etc/config/network once. This is NOT a runtime override layer — after
// autosetup the uci config is the single source of truth and the operator
// edits it like any hand-written config. No match -> the interface keeps an
// empty APN, which attaches with the SIM/modem-provisioned APN.
//
// Prefixes match against BOTH identities of the active SIM: the ICCID
// (starts with 89 <country calling code> <issuer>) and the IMSI (starts with
// <MCC><MNC>) — the LONGEST match across both wins. Keep entries
// conservative: only add prefixes whose mapping is certain, and prefer the
// carrier's dual-stack default APN.
//
// Entry: '<prefix>': { match?, apn, pdp_type, auth, username?, password?, note }
//   match: 'iccid' | 'imsi' — which identity the prefix may bind to. As the
//   table grows, an IMSI digit run could collide with an ICCID issuer prefix;
//   tagging prevents that. Absent = both (legacy).

'use strict';

const APNDB = {
	// Deutsche Telekom (DE, 262/01): dual-stack default APN
	'894902': { match: 'iccid', apn: 'internet.v6.telekom', pdp_type: 'ipv4v6', auth: 'none',
	            note: 'Deutsche Telekom DE' },

	// Vodafone (DE, 262/02)
	'894920': { match: 'iccid', apn: 'web.vodafone.de', pdp_type: 'ipv4v6', auth: 'none',
	            note: 'Vodafone DE' },

	// 1NCE IoT (global, rides Telekom)
	'8988280': { match: 'iccid', apn: 'iot.1nce.net', pdp_type: 'ipv4', auth: 'none',
	             note: '1NCE IoT' },

	// Vodafone GDSP / global M2M (IMSI 901 28 00..., ICCID 8988239...) —
	// HW-verified on the Cudy LT300 + Huawei E392 deployment SIMs
	'9012800': { match: 'imsi', apn: 'apn.global-m2m.net', pdp_type: 'ipv4v6', auth: 'both',
	             username: 'gdsp', password: 'gdsp',
	             note: 'Vodafone GDSP global M2M' },
	'8988239': { match: 'iccid', apn: 'apn.global-m2m.net', pdp_type: 'ipv4v6', auth: 'both',
	             username: 'gdsp', password: 'gdsp',
	             note: 'Vodafone GDSP global M2M (ICCID)' },
};

// longest-prefix lookup across ICCID and IMSI; returns the entry (a copy,
// never the table object) or null
export function lookup(iccid, imsi)
{
	let best = null, best_len = 0;

	for (let prefix, entry in APNDB) {
		if (length(prefix) <= best_len)
			continue;

		// entries may pin the identity class they match (see header).
		// NOTE deliberately written as a kind-loop: a nested-ternary building
		// per-iteration array literals here crashed the host ucode build with
		// heap corruption (malloc_consolidate abort in test_daemon) — do not
		// "simplify" this back.
		for (let kind in [ 'iccid', 'imsi' ]) {
			if (entry.match != null && entry.match != kind)
				continue;

			let ident = (kind == 'iccid') ? iccid : imsi;

			if (length(ident ?? '') && substr(ident, 0, length(prefix)) == prefix) {
				best = entry;
				best_len = length(prefix);
				break;
			}
		}
	}

	return best ? { ...best } : null;
};
