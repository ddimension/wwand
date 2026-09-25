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

// --- fmt_locks: a disarmed lock is not a lock -------------------------------
//
// The CLI printed `%J` of the daemon's object, which on an EC200A read
//   locks lte={ "enabled": false, "values": [ 0, 0 ] }
// — raw JSON at the user, reporting a lock on a modem locked to nothing
// (ddimension/wwand#19). luci-app-wwand already rendered this correctly
// (format.js:645); this is the CLI catching up, and the expectations below are
// deliberately the same ones, so the two surfaces cannot drift apart again.

eq(fmt.fmt_locks(null), null, 'locks: nothing at all -> no line');
eq(fmt.fmt_locks({}), null, 'locks: an empty object -> no line');
eq(fmt.fmt_locks({ lte: { enabled: false, values: [ 0, 0 ] } }), null,
	'locks: HIS case — disarmed, so there is nothing to report');
eq(fmt.fmt_locks({ lte: { enabled: 0, values: [ 1850, 100 ] } }), null,
	'locks: a numeric 0 disarms too, not only a real false');
eq(fmt.fmt_locks({ lte: { enabled: 0.0, values: [ 1850, 100 ] } }), null,
	'locks: ...and a double zero');
eq(fmt.fmt_locks({ wcdma: { enabled: false, uarfcn: 10713 } }), null,
	'locks: an unknown rat obeys the same disarmed rule as the known two');

eq(fmt.fmt_locks({ lte: { enabled: true, values: [ 1850, 100 ] } }), 'LTE 1850:100',
	'locks: an armed LTE lock is earfcn:pci, not JSON');
eq(fmt.fmt_locks({ lte: { enabled: true, values: [ 1850, 100, 3200, 7 ] } }),
	'LTE 1850:100, 3200:7', 'locks: two LTE cells group in pairs');
eq(fmt.fmt_locks({ nr5g: { enabled: true, values: [ 7, 632448, 1, 78 ] } }),
	'NR5G 7:632448:1:78', 'locks: NR5G groups in fours');
eq(fmt.fmt_locks({ lte: { enabled: true, values: [ 1850, 100 ] },
                   nr5g: { enabled: true, values: [ 7, 632448, 1, 78 ] } }),
	'LTE 1850:100 · NR5G 7:632448:1:78', 'locks: both rats, in a fixed order');

// shapes that are not { enabled, values } must not degrade to a bare "armed",
// because that silently drops what the lock actually holds
eq(fmt.fmt_locks({ lte: true }), 'LTE armed',
	'locks: a payload-free true IS the armed-without-detail spelling');
eq(fmt.fmt_locks({ lte: { enabled: true, values: [] } }), 'LTE armed',
	'locks: armed with an empty value list says so rather than printing nothing');
eq(fmt.fmt_locks({ lte: { enabled: true, values: [ 1850, 100, 3200 ] } }),
	'LTE 1850, 100, 3200',
	'locks: a value count that does not divide by the width is listed, not mis-paired');
eq(fmt.fmt_locks({ wcdma: { enabled: true, uarfcn: 10713 } }), 'wcdma uarfcn=10713',
	'locks: a rat the daemon grows later is shown, just without a spelling');
eq(fmt.fmt_locks({ lte: [ 1850, 100 ] }), 'LTE 1850:100',
	'locks: the payload may BE the array, with no wrapper');
eq(fmt.fmt_locks({ lte: '1850:100' }), 'LTE 1850:100',
	'locks: a scalar payload is its own value');
// reading a property off a scalar THROWS in ucode (it is merely undefined in the
// JS this mirrors), so the container type is checked before anything is indexed
eq(fmt.fmt_locks('nonsense'), null, 'locks: a scalar container is refused, not dereferenced');
eq(fmt.fmt_locks(true), null, 'locks: ...including a bare true');

// --- the MBIMEx extras, in the CLI -------------------------------------------
//
// The page renders these; the CLI did not, and this tree has been caught by
// exactly that asymmetry before — max_sessions and the temperature row both sat
// parsed and unprintable for as long as they existed.

// data subclass: the modem's own statement of how 5G is attached, as against
// `rat`, which is derived from the shape of the cell environment
eq(fmt.data_subclass(1), 'ENDC', 'subclass: bit 0 is ENDC — 5G on an LTE anchor');
eq(fmt.data_subclass(2), '5G NR', 'subclass: bit 1 is standalone');
eq(fmt.data_subclass(1 | 8), 'ENDC + ELTE', 'subclass: it is a mask');
eq(fmt.data_subclass(1 << 20), '0x100000', 'subclass: an unknown bit is reported, not dropped');
// ...INCLUDING BESIDE A KNOWN ONE. The first version fell back to hex only when
// nothing was recognised, so 0x21 came back as a bare "ENDC" and the bit this
// table does not know vanished — the one case where silence is worst.
eq(fmt.data_subclass(0x21), 'ENDC + 0x20',
   'subclass: an unknown bit survives next to a known one');
eq(fmt.frequency_range(5), 'FR1 (sub-6 GHz) + 0x4',
   'range: ...and the same on the frequency range');
eq(fmt.data_subclass(0), null, 'subclass: zero means the modem said nothing');
eq(fmt.data_subclass(null), null, 'subclass: ...and so does an absent field');

eq(fmt.frequency_range(1), 'FR1 (sub-6 GHz)', 'range: resolved, not left as a code');
// the wording is IDENTICAL to luci-app-wwand's format.js on purpose: a CLI and
// a page that disagree about the same value are worse than either alone
eq(fmt.frequency_range(3), 'FR1 (sub-6 GHz) + FR2 (mmWave, 24 GHz and above)',
   'range: aggregation spans both, worded as the page words it');
eq(fmt.frequency_range(0), null, 'range: zero is absent');

// THE ATTACH TAI AND THE WIDTH TRAP. MbimTai carries the MNC as a bare u16 with
// no digit count, so padding it to two would invent an operator: 310/030 and
// 310/30 are different networks. The registration's PLMN knows the width; it is
// borrowed only when it names the same network.
eq(fmt.tai_text({ mcc: 310, mnc: 30, tac: 4030 },
                { mcc: 310, mnc: 30, mnc_digits: 3 }),
   '310/030 tac 4030', 'tai: the width is borrowed from the registration');
eq(fmt.tai_text({ mcc: 262, mnc: 1, tac: 4030 },
                { mcc: 262, mnc: 1, mnc_digits: 2 }),
   '262/01 tac 4030', 'tai: ...and a two-digit MNC still pads');
// a DIFFERENT network in the registration says nothing about this one's width,
// so the number is printed as the modem gave it rather than padded on a guess
eq(fmt.tai_text({ mcc: 310, mnc: 30, tac: 4030 },
                { mcc: 262, mnc: 1, mnc_digits: 2 }),
   '310/30 tac 4030', 'tai: a mismatched PLMN lends no width');
eq(fmt.tai_text(null, null), null, 'tai: no TAI, no row');
// EVERY PART OR NONE: a half-filled TAI rendered as `310/0 tac 0`, which looks
// like a tracking area and is not one
eq(fmt.tai_text({ mcc: 310 }, null), null, 'tai: a missing MNC is not a zero');
eq(fmt.tai_text({ mcc: 310, mnc: 30 }, null), null, 'tai: ...nor is a missing TAC');

// --- the CLI's 5g row, where its decision now lives --------------------------
//
// It used to be built inline in wwandctl.uc, which has no seam a test can
// reach — so reverting the whole row left every test green.
eq(fmt.packet_service_text({ frequency_range: 1, data_subclass: 1 }, null),
   'FR1 (sub-6 GHz)', 'ps row: the frequency range alone');
eq(fmt.packet_service_text({ frequency_range: 1,
                             tai: { mcc: 262, mnc: 1, tac: 4030 } },
                           { mcc: 262, mnc: 1, mnc_digits: 2 }),
   'FR1 (sub-6 GHz) · attach TAI 262/01 tac 4030',
   'ps row: ...and the attach TAI beside it');
// every non-MBIMEx backend: no row rather than an empty one
eq(fmt.packet_service_text(null, null), null, 'ps row: nothing to say, no row');
eq(fmt.packet_service_text({ data_subclass: 1 }, null), null,
   'ps row: the subclass belongs on the network line, not here');
eq(fmt.packet_service_text({ frequency_range: 0, tai: {} }, null), null,
   'ps row: zeroes and an empty TAI are absence, not content');
// a scalar would THROW on a property read in ucode, which aborts the CLI
eq(fmt.packet_service_text(true, null), null, 'ps row: a scalar is refused, not dereferenced');

// --- reg_text: the attach is a SECOND answer to "why not registered" ---------
//
// A wrong attach APN registers the radio and never attaches, so the reject
// cause is empty and only the attach carries the reason. The CLI said a bare
// "not registered" in precisely the case somebody runs it to find out
// (reproduced on a GL-X3000, 2026-09-20).
eq(fmt.reg_text({ state: 'REGISTERING', registration: { registration: 0 },
	attach_info: { state_text: 'detached',
	               ceer_text: 'Requested service option not subscribed' } }),
   'not registered: attach: Requested service option not subscribed',
   'reg_text: the extended error report explains a stuck registration');

// a mapped 3GPP cause wins over the raw report
eq(fmt.reg_text({ state: 'REGISTERING', registration: { registration: 0 },
	attach_info: { state_text: 'detached', ceer_text: 'EMM cause 33',
	               nw_error_text: 'requested service option not subscribed' } }),
   'not registered: attach: requested service option not subscribed',
   'reg_text: ...and a mapped cause is preferred over the raw text');

// both halves when both have something to say
eq(fmt.reg_text({ state: 'REGISTERING', registration: { registration: 0 },
	registration_detail: { reject_text: 'PLMN not allowed' },
	attach_info: { state_text: 'detached' } }),
   'not registered: PLMN not allowed · attach: detached',
   'reg_text: registration and attach are reported side by side');

// ...and nothing invented when there is nothing. This one passed BEFORE the
// change too — it is a guard rail against the addition inventing text, not
// evidence for it, and saying so is cheaper than someone later mistaking it for
// coverage.
eq(fmt.reg_text({ state: 'REGISTERING', registration: { registration: 0 } }),
   'not registered', 'reg_text: no detail, no invention');

// the discriminating shape of the same idea: an attach_info whose every field
// is null must not produce "not registered: attach: " with nothing after it
eq(fmt.reg_text({ state: 'REGISTERING', registration: { registration: 0 },
	attach_info: { state: 0, nw_error_text: null, ceer_text: null, state_text: null } }),
   'not registered', 'reg_text: an empty attach_info adds no dangling label');

// a registered modem carries the subclass beside the derived RAT
eq(fmt.reg_text({ state: 'READY', rat: 'LTE',
	registration: { registration: 1, plmn: { mcc: 262, mnc: 1, description: 'Telekom.de' } },
	packet_service: { data_subclass: 1 } }),
   'Telekom.de (262/01), LTE · ENDC',
   'reg_text: the modem says ENDC where the cell environment says LTE');


// --- recovery_text: the ladder in the CLI (evidence: ddimension/wwand#40) -----
{
	let rungs = [ { at: 8, action: 'opmode_cycle' }, { at: 16, action: 'modem_reset' },
	              { at: 24, action: 'usb_repower' }, { at: 101, action: 'reboot' } ];

	eq(fmt.recovery_text({ armed: true, attempts: 0, rungs: rungs }), null,
	   'recovery: armed with no failures says nothing');
	eq(fmt.recovery_text({ armed: true, attempts: 3, rungs: rungs,
	                       next: { at: 8, action: 'opmode_cycle', in: 5 } }),
	   'armed · 3 failed attempts · next: opmode_cycle at 8 (in 5)',
	   'recovery: armed names the next rung and the distance to it');
	eq(fmt.recovery_text({ armed: false, attempts: 4, rungs: rungs, unarmed_reset: 'available' }),
	   'NOT armed (never answered in this protocol) · 4 failed attempts · reset-line pulse at attempt 24 (in 20)',
	   'recovery: unarmed with a reset line says WHEN the one pulse comes');
	eq(fmt.recovery_text({ armed: false, attempts: 30, rungs: rungs, unarmed_reset: 'spent' }),
	   'NOT armed (never answered in this protocol) · 30 failed attempts · reset-line pulse already used this outage',
	   'recovery: and that it has been used');
	eq(fmt.recovery_text({ armed: false, attempts: 1, rungs: rungs, unarmed_reset: null }),
	   'NOT armed (never answered in this protocol) · 1 failed attempt · nothing physical until the control channel answers',
	   'recovery: without a reset line, that nothing will happen on its own');
	eq(fmt.recovery_text({ armed: false, attempts: 30, rungs: rungs, unarmed_reset: 'available' }),
	   'NOT armed (never answered in this protocol) · 30 failed attempts · reset-line pulse on the next failed attempt',
	   'recovery: past the threshold and unused, it is the NEXT failure (Codex review)');
	eq(fmt.recovery_text(null), null, 'recovery: a modem with no recovery view prints no line');
}

done('test_wwandctl_fmt');
