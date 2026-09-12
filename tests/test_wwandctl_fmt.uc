// wwand tests — wwandctl's value formatters (wwandctl_fmt.uc).
//
// The CLI itself is unimportable by construction: it ends in a top-level
// command dispatch, so an `import` would RUN it. That is why not a line of
// wwandctl was ever under test. These three functions are the part users read,
// they are pure, and they have been wrong in the field — so they are the part
// worth pinning first.

'use strict';

import { eq, ok, done } from './lib/check.uc';
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


// --- collectd exec feed ------------------------------------------------------

// THE CADENCE FLOOR. `modem_signal` keeps wwand's adaptive fast-telemetry loop
// warm, and that loop decays only 6 s after the last request — so one sample
// costs ~6 s of 1 Hz modem traffic and the duty cycle is 6/interval. At 6 s or
// below the loop never decays at all and the modem is polled around the clock.
// collectd's global `Interval` must therefore be raised, not obeyed.
eq(fmt.collectd_interval('60'), 60, 'interval: a sane value is taken as given');
eq(fmt.collectd_interval('30'), 30, 'interval: the floor itself is allowed');
eq(fmt.collectd_interval('10'), 30, 'interval: below the floor it is RAISED, not obeyed');
eq(fmt.collectd_interval('1'), 30, 'interval: and the pathological case too');
eq(fmt.collectd_interval(null), 60, 'interval: absent -> collectd default 60');
eq(fmt.collectd_interval('kaputt'), 60, 'interval: unparsable -> 60, never 0');
eq(fmt.collectd_interval('0'), 60, 'interval: zero would busy-loop — refused');

// A SENTINEL MUST NEVER REACH RRD. -32768 is the i16 "not measured" value; as a
// data point it is a real reading that flattens every graph sharing its scale.
// HW-observed on an RG650E camped on LTE: it reports nr5g rsrp/snr as -32768
// alongside perfectly good LTE numbers (2026-09-11).
let sig_hw = {
	lte: { rssi: -64, rsrq: -13, rsrp: -100, snr: 154 },
	nr5g: { rsrp: -32768, snr: -32768 },
	nr5g_rsrq: -32768,
};
let lines = fmt.collectd_lines('h', 'wwmodem0', sig_hw,
	{ state: 'READY', temperature: { celsius: 41 }, attempts: 0, proto_errors: 0 }, 30);
let joined = join('\n', lines);

eq(index(joined, '-32768'), -1, 'collectd: no sentinel reaches the output');
eq(index(joined, 'nr5g'), -1, 'collectd: and no 5G series at all — it measured nothing');
ok(index(joined, 'PUTVAL "h/wwand-wwmodem0/signal_power-rsrp_lte" interval=30 N:-100.000') >= 0,
	'collectd: LTE RSRP as signal_power');
ok(index(joined, 'gauge-sinr_lte" interval=30 N:15.400') >= 0,
	'collectd: SINR converted from 0.1 dB and typed `gauge`');
ok(index(joined, 'temperature-modem" interval=30 N:41.000') >= 0, 'collectd: temperature');
ok(index(joined, 'gauge-registered" interval=30 N:1.000') >= 0, 'collectd: registered flag');

// SINR IS NOT signal_quality (min 0) AND NOT signal_power (max 0): it runs
// roughly -20..+30 dB, so either bound would silently discard half its range.
// Both signs must survive, and both must carry the neutral type.
let neg = join('\n', fmt.collectd_lines('h', 'm', { lte: { snr: -150 } }, {}, 30));
ok(index(neg, 'gauge-sinr_lte" interval=30 N:-15.000') >= 0,
	'collectd: a NEGATIVE SINR survives with its sign');
eq(index(neg, 'signal_quality'), -1, 'collectd: never signal_quality — its floor is 0');

// The untagged RSSI is only emitted when no RAT claimed one, so the same
// measurement cannot land in two files under two names.
let tagged = join('\n', fmt.collectd_lines('h', 'm', { rssi: -70, lte: { rssi: -64 } }, {}, 30));
ok(index(tagged, 'signal_power-rssi_lte') >= 0, 'collectd: the tagged RSSI is emitted');
eq(index(tagged, 'signal_power-rssi"'), -1, 'collectd: and the untagged one is not, beside it');

let untagged = join('\n', fmt.collectd_lines('h', 'm', { rssi: -70 }, {}, 30));
ok(index(untagged, 'signal_power-rssi" interval=30 N:-70.000') >= 0,
	'collectd: with nothing tagged, the bare RSSI is what there is');

// THE SENTINEL TYPE IS PER FIELD. QMI decodes the LTE/WCDMA/GSM RSSI and the
// LTE RSRQ as i8 (sentinel -128) and rsrp/snr/ecio as i16 (sentinel -32768)
// (codec/schema/nas.uc:108-112). A blanket i16 test lets an unavailable -128
// through as a genuine -128 dBm — precisely the silent wrong value this filter
// exists to stop.
let i8s = join('\n', fmt.collectd_lines('h', 'm',
	{ lte: { rsrp: -95, rssi: -128, rsrq: -128, snr: 120 } }, {}, 30));
ok(index(i8s, 'rsrp_lte') >= 0, 'sentinel: the i16 field is kept');
eq(index(i8s, '-128'), -1, 'sentinel: and no i8 sentinel is emitted as a reading');
eq(index(i8s, 'rssi_lte'), -1, 'sentinel: the unavailable RSSI produces no series');
eq(index(i8s, 'rsrq_lte'), -1, 'sentinel: nor the unavailable RSRQ');

// ...and a real -128-adjacent reading is NOT clipped: only the exact sentinel
// goes, so a genuine -127 dBm survives.
let near = join('\n', fmt.collectd_lines('h', 'm', { lte: { rssi: -127 } }, {}, 30));
ok(index(near, 'rssi_lte" interval=30 N:-127.000') >= 0,
	'sentinel: -127 is a reading, not a sentinel');

// 2G HAS NO STRUCT OF ITS OWN — just gsm_rssi beside the others. It used to be
// read by nobody, so a GSM-camped modem recorded no band power at all.
let g = join('\n', fmt.collectd_lines('h', 'm', { gsm_rssi: -90 }, {}, 30));
ok(index(g, 'signal_power-rssi_gsm" interval=30 N:-90.000') >= 0,
	'gsm: the 2G band power is emitted, tagged');
eq(index(g, 'signal_power-rssi"'), -1, 'gsm: and not a second time as untagged');

// The untagged suppression counts what was tagged rather than spot-checking two
// RATs, so a technology the check does not know cannot produce a duplicate.
let nr = join('\n', fmt.collectd_lines('h', 'm',
	{ rssi: -70, nr5g: { rssi: -66 } }, {}, 30));
ok(index(nr, 'rssi_nr5g" interval=30 N:-66.000') >= 0, 'untagged: the 5G RSSI is tagged');
eq(index(nr, 'signal_power-rssi"'), -1,
	'untagged: and the band-wide one is suppressed by it, not only by LTE/3G');

// A modem with no readings at all still reports its state — a gap in the signal
// graphs plus "registered 0" is exactly what an outage should look like.
let dead = join('\n', fmt.collectd_lines('h', 'm', {}, { state: 'ABSENT', attempts: 7 }, 30));
ok(index(dead, 'gauge-registered" interval=30 N:0.000') >= 0, 'collectd: not-ready reports 0');
ok(index(dead, 'gauge-attempts" interval=30 N:7.000') >= 0, 'collectd: the recovery counter rides along');
eq(index(dead, 'signal_power'), -1, 'collectd: and no invented signal values');

// --- aggregation: carriers and summed bandwidth ------------------------------
// The long-term half of ddimension/wwand#14 — the RRD keeps what the browser
// graph only holds for as long as a page is open. Same counting rule as the
// LuCI graph, because an RRD and the status page disagreeing is worse than
// either being absent.

let ca = fmt.carrier_counts({ ca: [
	{ rat: 'lte', role: 'PCC', bandwidth_mhz: 20 },
	{ rat: 'lte', role: 'SCC', bandwidth_mhz: 10, state: 2 },
	{ rat: 'lte', role: 'SCC', bandwidth_mhz: 15, state: 0 },   // deconfigured
	{ rat: 'nr',  role: 'PCC' },
	{ rat: 'nr',  role: 'SCC' },
] });
eq([ ca.lte.n, ca.lte.mhz ], [ 2, 30 ], 'carriers: a deconfigured SCC is not a carrier');
eq(ca.nr.n, 2, 'carriers: both 5G carriers counted under EN-DC');
eq(ca.nr.have_mhz, false, 'carriers: no 5G width reported, none invented');

// ...and an SCC whose state the parser could not read is COUNTED. A carrier the
// modem listed and would not name a state for is more likely in use than not,
// and the QCAINFO parser leaves `state` null for a token it does not know.
ca = fmt.carrier_counts({ ca: [
	{ rat: 'lte', role: 'PCC', bandwidth_mhz: 20 },
	{ rat: 'lte', role: 'SCC', bandwidth_mhz: 10, state: null },
] });
eq([ ca.lte.n, ca.lte.mhz ], [ 2, 30 ], 'carriers: an SCC with an unknown state still counts');

// no carrier list at all: the serving cell is still one carrier
ca = fmt.carrier_counts({ serving: { lte: { bandwidth_mhz: 10 } } });
eq([ ca.lte.n, ca.lte.mhz ], [ 1, 10 ], 'carriers: serving cell is the floor');

// a 5G-capable modem parked on LTE reports the NR band it can SEE; that is not
// a carrier, and dsd is what says so (HW-observed on an RG502QEA, 2026-09-12)
ca = fmt.carrier_counts({ serving: { lte: {}, nr: { band: 'n1' } },
                          dsd: { mode: 'LTE', nr: false } });
eq(ca.nr.n, 0, 'carriers: a visible NR band with the leg down is not a carrier');

ca = fmt.carrier_counts({ serving: { lte: {}, nr: { band: 'n78' } },
                          dsd: { mode: 'NSA', nr: true } });
eq(ca.nr.n, 1, 'carriers: ...and is one once the leg is serving');

eq(fmt.carrier_counts(null).lte.n, 0, 'carriers: no cells at all is zero, not a crash');

// The Fibocom telemetry (telemetry_ncm ca_entries) puts the leg in the ROLE
// TEXT — 'PCC LTE' / 'PCC NR'. It carries `rat` now, but an installed base does
// not, and a reader keyed on `rat` alone counted every Fibocom NR carrier as
// LTE. Observed on a WH3000 Pro at a sponsor site, 2026-09-12.
ca = fmt.carrier_counts({ ca: [
	{ role: 'PCC LTE', bandwidth_mhz: 20 },
	{ role: 'PCC NR' },
	{ role: 'SCC', bandwidth_mhz: 10 },
] });
eq([ ca.lte.n, ca.nr.n ], [ 2, 1 ], 'carriers: the legacy role text still separates the legs');
eq(ca.lte.mhz, 30, 'carriers: ...and the LTE widths still add up');

// an explicit `rat` wins over the role text, so a tagged producer is never
// second-guessed by a string match
ca = fmt.carrier_counts({ ca: [ { rat: 'lte', role: 'PCC NRSOMETHING' } ] });
eq([ ca.lte.n, ca.nr.n ], [ 1, 0 ], 'carriers: an explicit rat beats the role text');

// the PUTVAL lines, and the absence of them
let agg = join('\n', fmt.collectd_lines('h', 'm', {}, {}, 30,
	{ ca: [ { rat: 'lte', role: 'PCC', bandwidth_mhz: 20 },
	        { rat: 'lte', role: 'SCC', bandwidth_mhz: 20, state: 2 } ] }));
ok(index(agg, 'gauge-carriers_lte" interval=30 N:2.000') >= 0, 'collectd: carrier count emitted');
ok(index(agg, 'gauge-bandwidth_lte" interval=30 N:40.000') >= 0, 'collectd: bandwidth summed');
eq(index(agg, 'carriers_nr'), -1, 'collectd: no 5G leg, no 5G series');

// a caller that does not fetch cells records NOTHING, rather than a zero that
// would read as "stopped aggregating"
let nocells = join('\n', fmt.collectd_lines('h', 'm', {}, {}, 30));
eq(index(nocells, 'carriers_'), -1, 'collectd: absent cells emit no aggregation at all');

done('test_wwandctl_fmt');
