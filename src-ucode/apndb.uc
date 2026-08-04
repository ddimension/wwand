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
// Entry: '<prefix>': { apn, pdp_type, auth, username?, password?, note }

'use strict';

const APNDB = {
	// Deutsche Telekom (DE, 262/01): dual-stack default APN
	'894902': { apn: 'internet.v6.telekom', pdp_type: 'ipv4v6', auth: 'none',
	            note: 'Deutsche Telekom DE' },

	// Vodafone (DE, 262/02)
	'894920': { apn: 'web.vodafone.de', pdp_type: 'ipv4v6', auth: 'none',
	            note: 'Vodafone DE' },

	// 1NCE IoT (global, rides Telekom)
	'8988280': { apn: 'iot.1nce.net', pdp_type: 'ipv4', auth: 'none',
	             note: '1NCE IoT' },

	// Vodafone GDSP / global M2M (IMSI 901 28 00...) — HW-verified on the
	// Cudy LT300 deployment SIM
	'9012800': { apn: 'apn.global-m2m.net', pdp_type: 'ipv4v6', auth: 'both',
	             username: 'gdsp', password: 'gdsp',
	             note: 'Vodafone GDSP global M2M' },
};

// longest-prefix lookup across ICCID and IMSI; returns the entry (a copy,
// never the table object) or null
export function lookup(iccid, imsi)
{
	let best = null, best_len = 0;

	for (let prefix, entry in APNDB) {
		if (length(prefix) <= best_len)
			continue;

		for (let ident in [ iccid, imsi ]) {
			if (length(ident ?? '') && substr(ident, 0, length(prefix)) == prefix) {
				best = entry;
				best_len = length(prefix);
				break;
			}
		}
	}

	return best ? { ...best } : null;
};
