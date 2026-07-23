// wwand — per-model / per-vendor quirk + expectation table.
//
// A small, extensible data table of what a given modem SHOULD look like once
// wwand has configured it, plus known-bad firmware defaults worth flagging.
// It drives the runtime "does the live modem match our config + spec" check in
// modem.validate_config (config_warnings), and can also feed the init-time AT
// quirks (init_commands) as those tables consolidate here.
//
// Each entry:
//   { match: /model-regex/,
//     expect?:        { ... },   // spec the validator compares live state to
//     warn?:          [ ... ],   // static "heads-up" notes for this firmware
//     init_commands?: [ ... ] }  // AT quirks (advisory; atcmd stays the source
//                                //   of truth for what is actually issued today)
//
// for_model(model) merges every matching entry into a single resolved object
// { expect, warn, init_commands } (later matches extend earlier ones), so a
// model can pick up both a shared vendor rule and its own specific note.

'use strict';

const QUIRKS = [
	// Quectel LTE/5G family (EG06/EM06, RG50x, RG65x). Telekom (and other
	// networks) reject an IPv4-only autonomous LTE attach with EMM cause #33 —
	// the attach profile (CID1) must allow IPv6, so expect ipv4v6 there. The
	// QMBNCFG auto-select is the carrier-config (MBN) quirk mirrored from
	// atcmd.MODEL_QUIRKS.
	{
		match: /^EG06|^EM06|^RG50[0-9]|^RG65[0-9]/,
		expect: {
			attach_pdp_type: 'ipv4v6',
		},
		init_commands: [ 'AT+QMBNCFG="AutoSel",1' ],
	},

	// Zyxel-bundled RG502Q firmware self-activates PDP profile 2 on boot,
	// fighting wwand's own context; wwand reclaims it (AT+CGACT). Flagged so the
	// operator understands why an extra internal PDP context appears.
	{
		match: /^RG502Q/,
		warn: [ 'firmware self-activates PDP profile 2 on boot; wwand reclaims it via AT+CGACT' ],
	},
];

// resolve every matching entry for a model into one merged descriptor.
// Always returns the full shape so callers can index without guards.
export function for_model(model)
{
	let out = { expect: {}, warn: [], init_commands: [] };

	for (let q in QUIRKS) {
		if (!match(model ?? '', q.match))
			continue;

		for (let k, v in (q.expect ?? {}))
			out.expect[k] = v;

		for (let w in (q.warn ?? []))
			push(out.warn, w);

		for (let c in (q.init_commands ?? []))
			push(out.init_commands, c);
	}

	return out;
}
