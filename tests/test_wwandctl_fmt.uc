// wwand tests — wwandctl's value formatters (wwandctl_fmt.uc).
//
// The CLI itself is unimportable by construction: it ends in a top-level
// command dispatch, so an `import` would RUN it. That is why not a line of
// wwandctl was ever under test. These three functions are the part users read,
// they are pure, and they have been wrong in the field — so they are the part
// worth pinning first.

'use strict';

import { eq, done } from './lib/check.uc';
import * as fmt from 'wwand/wwandctl_fmt.uc';

// --- fmt_plmn: two wire shapes for one operator ------------------------------
//
// QMI reports mcc/mnc separately; MBIM reports one concatenated ProviderId.
// A newer wwandctl against an older daemon sees only the second, and printing
// %d of a missing mcc produced "(0/00)" — reported as such in
// ddimension/wwand#8.
eq(fmt.fmt_plmn({ plmn: { mcc: 262, mnc: 1, description: 'Telekom.de' } }),
	'Telekom.de (262/01)', 'plmn: qmi shape, mnc padded to two digits');
eq(fmt.fmt_plmn({ plmn: { mcc: 460, mnc: 15, mnc_digits: 3, description: 'China Unicom' } }),
	'China Unicom (460/015)', 'plmn: three-digit mnc keeps its width');

// 460/15 and 460/015 are DIFFERENT networks, so the width is not cosmetic
eq(fmt.fmt_plmn({ plmn: { mcc: 460, mnc: 15, mnc_digits: 2 } }), '460/15',
	'plmn: two-digit width is preserved as such');

// MBIM: the pair has to be recovered from the concatenated id
eq(fmt.fmt_plmn({ plmn: { id: '46015', description: 'China Unicom' } }),
	'China Unicom (460/15)', 'plmn: mbim id split into mcc/mnc');
eq(fmt.fmt_plmn({ plmn: { id: '460150' } }), '460/150',
	'plmn: a six-digit id is a three-digit mnc');

// a firmware with no entry for the network emits junk for the name ("-5" for
// China Broadcasting Network); the NUMBER is then the only identification, so
// it must never be dropped
eq(fmt.fmt_plmn({ plmn: { mcc: 460, mnc: 15, description: '-5' } }), '-5 (460/15)',
	'plmn: a junk name never costs us the number');
eq(fmt.fmt_plmn({ plmn: { description: 'Some Net' } }), 'Some Net',
	'plmn: a name without a number is still worth printing');
eq(fmt.fmt_plmn({ plmn: {} }), '-', 'plmn: nothing at all');
eq(fmt.fmt_plmn({}), '-', 'plmn: no plmn block');
eq(fmt.fmt_plmn(null), '-', 'plmn: no registration at all');

// an out-of-range digit count arrives over ubus; 2 and 3 are the only widths
// 3GPP defines, and the padding loop below it must terminate
eq(fmt.fmt_plmn({ plmn: { mcc: 262, mnc: 1, mnc_digits: 9 } }), '262/01',
	'plmn: an implausible mnc_digits falls back to two');

// --- fmt_sig: sentinels are not measurements ---------------------------------
eq(fmt.fmt_sig({ lte: { rsrp: -95, rsrq: -10 } }), 'LTE rsrp -95 dBm rsrq -10 dB',
	'sig: lte rsrp/rsrq');
eq(fmt.fmt_sig({ nr5g: { rsrp: -80, snr: 135 } }), 'NR rsrp -80 dBm snr 13.5 dB',
	'sig: nr snr is tenths of a dB');
eq(fmt.fmt_sig({ lte: { rssi: -70 } }), 'LTE rssi -70 dBm',
	'sig: rssi carries the line when there is no rsrp');
eq(fmt.fmt_sig({ rssi: -101 }), 'rssi -101 dBm',
	'sig: the generic floor, which is all some modems report');
eq(fmt.fmt_sig({ lte: { rsrp: -32768 } }), '-',
	'sig: -32768 is the "not measured" sentinel, never a reading');
eq(fmt.fmt_sig({}), '-', 'sig: nothing');
eq(fmt.fmt_sig(null), '-', 'sig: no signal block');

// both RATs present: NR first, then LTE — an EN-DC modem shows both
eq(fmt.fmt_sig({ nr5g: { rsrp: -80, snr: 100 }, lte: { rsrp: -95, rsrq: -9 } }),
	'NR rsrp -80 dBm snr 10.0 dB, LTE rsrp -95 dBm rsrq -9 dB',
	'sig: en-dc shows both carriers');

// --- reg_text: what the status line says -------------------------------------
eq(fmt.reg_text({ state: 'READY', registration: { registration: 1,
		plmn: { mcc: 262, mnc: 1, description: 'Telekom.de' } }, rat: 'LTE' }),
	'Telekom.de (262/01), LTE', 'reg: registered with a rat');
eq(fmt.reg_text({ state: 'READY', registration: { registration: 1, roaming: true,
		plmn: { mcc: 262, mnc: 1 } } }),
	'262/01, roaming', 'reg: roaming is called out');

// a modem that reports no registration flag but names its radio interfaces is
// registered as far as the user is concerned
eq(fmt.reg_text({ state: 'READY', registration: { radio_ifs: [ 8 ],
		plmn: { mcc: 262, mnc: 1 } } }),
	'262/01', 'reg: radio_ifs alone counts as registered');

eq(fmt.reg_text({ state: 'READY', registration: { registration: 0 } }),
	'not registered', 'reg: plain refusal');
eq(fmt.reg_text({ state: 'READY', registration: { registration: 0 },
		registration_detail: { reject_text: 'PLMN not allowed' } }),
	'not registered: PLMN not allowed', 'reg: the network\'s own reason is shown');

// a blocked SIM outranks registration — it is the thing the user must act on
eq(fmt.reg_text({ state: 'SIM_BLOCKED', sim_block: { reason: 'PIN', retries: 2 } }),
	'SIM blocked: PIN (2 retries left)', 'reg: sim block with retries');
eq(fmt.reg_text({ state: 'SIM_BLOCKED', sim_block: { reason: 'PUK' } }),
	'SIM blocked: PUK', 'reg: sim block without a retry count');

done('test_wwandctl_fmt');
