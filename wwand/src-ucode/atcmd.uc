// wwand — AT command engine and AT port discovery.
//
// Replaces comgt/gcom: a serialized command queue over a raw tty with
// line assembly, echo filtering, OK/ERROR/+CME terminators and timeouts.
//
// The engine operates on a transport object { write(data), on_data(cb),
// drain(), close() } — open_transport() provides the real one (native
// wwand_io tty + uloop.handle), tests inject a fake.
//
// Port discovery order (find_tty):
//   1. explicit config override
//   2. board quirk table (integrated modems without usable USB ids)
//   3. atport.uc lookup: USB vid:pid + interface number -> AT role
//      (table generated from ModemManager port-type udev rules)
//   4. old heuristic: first ttyUSB sibling, sorted

'use strict';

import * as uloop from 'uloop';

// the port table (225 devices) is the largest single module — loaded lazily
// on first use so daemon startup does not pay for it when no AT port exists
let atport = null;

function atport_table()
{
	atport = atport ?? require('wwand.atport');

	return atport;
}

const DEFAULT_TIMEOUT = 5000;

// boards whose integrated modem needs a fixed AT port (old
// proto_qmi_find_primary_serial_interface hardcodes)
const BOARD_TTYS = [
	{ prefix: 'zyxel,lte3301', tty: '/dev/ttyUSB2' },
	{ prefix: 'zyxel,nr7101',  tty: '/dev/ttyUSB2' },
];

// devices missing from the generated ModemManager table (atport.uc);
// verified on real hardware
const LOCAL_PORTS = {
	// Quectel RG650E: 0 DIAG, 1 NMEA, 2 AT, 3 AT secondary
	'2c7c:0122': { '2': 'at', '3': 'at2' },
};

// model-specific init sequences (old proto_qmi_serial_init)
const MODEL_QUIRKS = [
	// enable automatic carrier config (MBN) selection; the QMI-native
	// equivalent would be the PDC service (future replacement)
	{ pattern: '^EG06|^EM06|^RG50[02]Q', commands: [ 'AT+QMBNCFG="AutoSel",1' ] },
];

export function model_init_commands(model)
{
	for (let q in MODEL_QUIRKS)
		if (match(model ?? '', regexp(q.pattern)))
			return [ ...q.commands ];

	return [];
}

// eSIM host-access quirks. On some Quectel firmwares (RG650E and relatives)
// the QMI logical channel is NOT_SUPPORTED and the modem's own LPA daemon
// holds the ISD-R exclusively, so host-side ES10 APDU access over AT
// (CCHO/CGLA) only works once the internal LPA is disabled
// (AT+QESIM="lpa_enable",0) and the modem is reset once. Verified on the
// RG650E; the CGLA payload must additionally be quoted (see sim.uc).
export function esim_quirks(model)
{
	// verified on the RG650E only. Other Quectel modems may or may not need
	// this (the RG502Q's QMI logical channel was not tested) — extend the
	// pattern once confirmed on hardware rather than resetting them blindly.
	if (match(model ?? '', /^RG65[0-9]/))
		return { lpa_disable_for_host: true };

	return {};
}

// fallback when NAS system-selection-preference keeps failing (old
// proto_qmi_reset_modes_fallback; harmless ERROR on non-Huawei modems)
export function modes_fallback_command(model)
{
	return 'AT^SYSCFGEX="00",3fffffff,1,4,7fffffffffffffff,,';
}

// Quectel cell locking (verified on RG650E). Config:
//   lock_4g:  list of 'earfcn:pci' (one entry -> common/4g, several -> 4g_ext)
//   lock_5g:  'pci:arfcn:scs:band' (SA only; NSA follows the locked LTE
//             anchor, the modem answers +CME 902 there — treated as benign)
//   lock_persist: also store the lock in modem NV (save_ctrl)
export function cell_lock_commands(cfg)
{
	let cmds = [];
	let l4 = cfg?.lock_4g ?? [];

	if (type(l4) == 'string')
		l4 = [ l4 ];

	if (length(l4) == 1) {
		let m = match(l4[0], /^([0-9]+):([0-9]+)$/);

		if (m)
			push(cmds, sprintf('AT+QNWLOCK="common/4g",1,%s,%s', m[1], m[2]));
	}
	else if (length(l4) > 1) {
		let parts = [];

		for (let entry in l4) {
			let m = match(entry, /^([0-9]+):([0-9]+)$/);

			if (m)
				push(parts, sprintf('%s,%s', m[1], m[2]));
		}

		if (length(parts))
			push(cmds, sprintf('AT+QNWLOCK="common/4g_ext",%d,%s',
				length(parts), join(',', parts)));
	}

	let l5 = cfg?.lock_5g;

	if (type(l5) == 'string') {
		let m = match(l5, /^([0-9]+):([0-9]+):([0-9]+):([0-9]+)$/);

		if (m)
			push(cmds, sprintf('AT+QNWLOCK="common/5g",%s,%s,%s,%s',
				m[1], m[2], m[3], m[4]));
	}

	if (length(cmds) && cfg?.lock_persist)
		push(cmds, 'AT+QNWLOCK="save_ctrl",1,1');

	return cmds;
}

// parse an AT+QNWLOCK read response into the lock state. Quectel formats:
//   +QNWLOCK: "common/4g",<enable>[,<earfcn>,<pci>[,...]]
//   +QNWLOCK: "common/4g_ext",<enable>,<count>,<earfcn>,<pci>,...
//   +QNWLOCK: "common/5g",<enable>[,<pci>,<arfcn>,<scs>,<band>]
// returns { scope, enabled, values:[...] } for the first matching line, or null
// when the modem answered with no lock line (unsupported / empty).
export function parse_qnwlock(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /\+QNWLOCK:\s*"([^"]+)",([0-9]+)(.*)/);

		if (!m)
			continue;

		let rest = replace(trim(m[3]), /^,/, '');
		let vals = length(rest) ? map(split(rest, ','), (x) => +trim(x)) : [];

		return { scope: m[1], enabled: +m[2] > 0, values: vals };
	}

	return null;
}

// LTE downlink bandwidth in resource blocks -> MHz (E-UTRA transmission BW)
const RB_MHZ = { '6': 1.4, '15': 3, '25': 5, '50': 10, '75': 15, '100': 20 };

// parse AT+QCAINFO response lines into the active LTE carriers. Quectel format:
//   +QCAINFO: "PCC",<earfcn>,<rb>,"LTE BAND <n>",<ul>,<pci>[,<rsrp>,<rsrq>,...]
//   +QCAINFO: "SCC",<earfcn>,<rb>,"LTE BAND <n>",<state>,<pci>[,...]
// returns [ { role, earfcn, rb, bandwidth_mhz, band, pci }, ... ]
export function parse_qcainfo(lines)
{
	let out = [];

	for (let l in (lines ?? [])) {
		let m = match(l, /\+QCAINFO:\s*"(PCC|SCC)",([0-9]+),([0-9]+),"[A-Za-z ]*BAND\s*([0-9]+)",[^,]*,([0-9]+)/);

		if (!m)
			continue;

		push(out, {
			role:          m[1],
			earfcn:        +m[2],
			rb:            +m[3],
			bandwidth_mhz: RB_MHZ[m[3]] ?? null,
			band:          +m[4],
			pci:           +m[5],
		});
	}

	return out;
}

// LTE downlink bandwidth index (Quectel QENG/servingcell) -> MHz
const BW_IDX_MHZ = { '0': 1.4, '1': 3, '2': 5, '3': 10, '4': 15, '5': 20 };

// parse AT+QENG="servingcell" into the serving LTE cell and any NR5G carrier.
// Quectel formats (field counts vary by firmware; parse defensively):
//   +QENG: "servingcell","<state>"
//   +QENG: "LTE","<dup>",<mcc>,<mnc>,<cid>,<pci>,<earfcn>,<band>,<ulbw>,<dlbw>,
//          <tac>,<rsrp>,<rsrq>,<rssi>,<sinr>,...
//   +QENG: "NR5G-NSA",<mcc>,<mnc>,<pci>,<rsrp>,<sinr>,<rsrq>,<arfcn>,<band>,<dlbw>,<scs>
//   +QENG: "NR5G-SA","<dup>",<mcc>,<mnc>,<cid>,<pci>,<tac>,<arfcn>,<band>,<dlbw>,...
// returns { state, lte: {...}|null, nr: {...}|null }. rsrp/rsrq/sinr are dBm/dB.
export function parse_qeng_servingcell(lines)
{
	let out = { state: null, lte: null, nr: null };
	let num = (s) => (s != null && match(s, /^-?[0-9]+$/)) ? +s : null;
	// QENG reports cell id / TAC as hex strings; decode to a decimal integer
	let hnum = (s) => (s != null && match(s, /^[0-9A-Fa-f]+$/)) ? hex(s) : null;

	for (let l in (lines ?? [])) {
		let m = match(l, /\+QENG:\s*"([^"]+)"(.*)/);

		if (!m)
			continue;

		let kind = m[1];
		// split the remaining CSV, stripping quotes and leading comma
		let rest = replace(trim(m[2]), /^,/, '');
		let f = map(split(rest, ','), (x) => { x = trim(x); return replace(x, /^"|"$/g, ''); });

		if (kind == 'servingcell') {
			out.state = f[0];
		}
		else if (kind == 'LTE') {
			// f: dup,mcc,mnc,cid,pci,earfcn,band,ulbw,dlbw,tac,rsrp,rsrq,rssi,sinr
			out.lte = {
				mcc: num(f[1]), mnc: f[2], cid: hnum(f[3]), tac: hnum(f[9]),
				band: num(f[6]), earfcn: num(f[5]), pci: num(f[4]),
				bandwidth_mhz: BW_IDX_MHZ[f[8]] ?? null,
				rsrp: num(f[10]), rsrq: num(f[11]), rssi: num(f[12]), sinr: num(f[13]),
			};
		}
		else if (kind == 'NR5G-NSA') {
			// mcc,mnc,pci,rsrp,sinr,rsrq,arfcn,band,dlbw,scs (verified on RG502Q)
			out.nr = {
				mode: 'NSA', mcc: num(f[0]), mnc: f[1], band: num(f[7]),
				arfcn: num(f[6]), pci: num(f[2]),
				bandwidth_mhz: BW_IDX_MHZ[f[8]] ?? null,
				rsrp: num(f[3]), sinr: num(f[4]), rsrq: num(f[5]),
			};
		}
		else if (kind == 'NR5G-SA') {
			// dup,mcc,mnc,cid,pci,tac,arfcn,band,dlbw,rsrp,rsrq,sinr (best-effort:
			// SA layout not verified on hardware yet)
			out.nr = {
				mode: 'SA', mcc: num(f[1]), mnc: f[2], cid: hnum(f[3]),
				tac: hnum(f[5]), band: num(f[7]), arfcn: num(f[6]), pci: num(f[4]),
				bandwidth_mhz: BW_IDX_MHZ[f[8]] ?? null,
				rsrp: num(f[9]), rsrq: num(f[10]), sinr: num(f[11]),
			};
		}
	}

	return out;
}

// parse AT+QENG="neighbourcell" (Quectel) into intra- and inter-frequency LTE
// neighbours. rsrp/rsrq/rssi/srxlev come out in QMI 0.1 dB units (×10) so they
// slot straight into the GET_CELL_LOCATION_INFO lte_intra/lte_inter shape and
// render through the same LuCI sig10 (÷10) path as the QMI set. Quectel format
// (QuecCell AT manual), fields after the RAT tag:
//   +QENG: "neighbourcell intra","LTE",<earfcn>,<pcid>,<rsrq>,<rsrp>,<rssi>,<sinr>,<srxlev>,...
//   +QENG: "neighbourcell inter","LTE",<earfcn>,<pcid>,<rsrq>,<rsrp>,<rssi>,<sinr>,<srxlev>,...
//   +QENG: "neighbourcell","LTE",...            (older firmwares; treated as intra)
// returns { intra: [ {earfcn,pci,rsrq,rsrp,rssi,srxlev} ], inter: [ ... ] }.
export function parse_qeng_neighbourcell(lines)
{
	let out = { intra: [], inter: [] };
	let num = (s) => (s != null && match(s, /^-?[0-9]+$/)) ? +s : null;
	let x10 = (s) => { let n = num(s); return (n != null) ? n * 10 : null; };

	for (let l in (lines ?? [])) {
		let m = match(l, /\+QENG:\s*"neighbourcell([^"]*)","LTE",(.*)/);

		if (!m)
			continue;

		let scope = trim(m[1]);   // '' | 'intra' | 'inter'
		let f = map(split(m[2], ','), (x) => trim(x));
		// f: earfcn,pcid,rsrq,rsrp,rssi,sinr,srxlev,...
		let cell = {
			earfcn: num(f[0]), pci: num(f[1]),
			rsrq: x10(f[2]), rsrp: x10(f[3]), rssi: x10(f[4]), srxlev: x10(f[6]),
		};

		if (cell.pci == null)
			continue;

		push((scope == 'inter') ? out.inter : out.intra, cell);
	}

	return out;
}

// per-Rx-branch signal (Quectel), the antenna-alignment source:
//   +QRSRP: <b0>,<b1>,<b2>,<b3>,<sysmode>   (dBm; sysmode = LTE | NR5G | ...)
//   +QRSRQ: <b0>,<b1>,<b2>,<b3>,<sysmode>   (dB)
//   +QSINR: <b0>,<b1>,<b2>,<b3>,<sysmode>   (dB)
// returns { mode, branches:[ints] } for the first matching line (or null).
function qbranch(lines, re)
{
	for (let l in (lines ?? [])) {
		let m = match(l, re);

		if (!m)
			continue;

		let mode = null, branches = [];

		for (let x in split(m[1], ',')) {
			x = trim(x);

			if (match(x, /^-?[0-9]+$/))
				push(branches, +x);
			else if (x != '')
				mode = x;   // trailing sysmode token
		}

		return { mode: mode, branches: branches };
	}

	return null;
}

export function parse_qrsrp(lines) { return qbranch(lines, /\+QRSRP:\s*(.*)/); }
export function parse_qrsrq(lines) { return qbranch(lines, /\+QRSRQ:\s*(.*)/); }
export function parse_qsinr(lines) { return qbranch(lines, /\+QSINR:\s*(.*)/); }

// pick the strongest valid Rx branch from a qbranch() result, ignoring the
// modem's not-available sentinels (RSRP -140, RSRQ/SINR very negative, 0 fill).
export function branch_best(b, floor)
{
	if (!b || !length(b.branches))
		return null;

	let best = null;

	for (let v in b.branches)
		if (v > (floor ?? -900) && (best == null || v > best))
			best = v;

	return best;
}

// AT+CEER extended error report -> { text, cause }. Firmwares return either a
// free-text reason or a numeric cause; extract a cause number when one follows
// the word "cause" (or the payload is purely numeric) so the caller can map it
// through the QMI REJECT_CAUSE table. Best-effort (format varies by vendor).
export function parse_ceer(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /\+CEER:\s*(.*)/);

		if (!m)
			continue;

		let text = trim(m[1]);

		if (text == '')
			continue;

		let cause = null;
		let mc = match(text, /cause[^0-9-]*(-?[0-9]+)/i);

		if (mc)
			cause = +mc[1];
		else if (match(text, /^-?[0-9]+$/))
			cause = +text;

		return { text: text, cause: cause };
	}

	return null;
}

// AT+CESQ extended signal quality (3GPP TS 27.007 §8.69), the always-available
// 3GPP-generic signal source:
//   +CESQ: <rxlev>,<ber>,<rscp>,<ecno>,<rsrq>,<rsrp>
// coded indices -> dBm/dB (99 GSM / 255 non-GSM = not available). Returns
// { gsm_rssi, wcdma:{rscp,ecno}, lte:{rsrp,rsrq} } (dBm / dB) for self.signal.
export function parse_cesq(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /\+CESQ:\s*([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+)/);

		if (!m)
			continue;

		let rxlev = +m[1], rscp = +m[3], ecno = +m[4], rsrq = +m[5], rsrp = +m[6];
		let out = { gsm_rssi: null, wcdma: null, lte: null };

		if (rxlev != 99)
			out.gsm_rssi = -110 + rxlev;

		if (rscp != 255 || ecno != 255)
			out.wcdma = { rscp: (rscp != 255) ? (-120 + rscp) : null,
			              ecno: (ecno != 255) ? (-24 + ecno * 0.5) : null };

		if (rsrq != 255 || rsrp != 255)
			out.lte = { rsrq: (rsrq != 255) ? (-19.5 + rsrq * 0.5) : null,
			            rsrp: (rsrp != 255) ? (-140 + rsrp) : null };

		return out;
	}

	return null;
}

// Huawei ^HCSQ signal (BEST-EFFORT — conversion formulas per the Huawei ME909 /
// NetEngine AR AT spec, not verified on wwand hardware):
//   ^HCSQ: "GSM",<rssi>
//   ^HCSQ: "WCDMA",<rssi>,<rscp>,<ecio>
//   ^HCSQ: "LTE",<rssi>,<rsrp>,<sinr>,<rsrq>
// raw index -> dBm/dB: rssi=v-121, rsrp=v-141, sinr=v/5-20, rsrq=v/2-19.5.
// Some firmwares prefix the report-config pair `<n>,<m>,` — tolerated.
export function parse_hcsq(lines)
{
	for (let l in (lines ?? [])) {
		// optional leading report-config pair `<n>,<m>,` (m[1]) then "<mode>",rest
		let m = match(l, /\^HCSQ:\s*([0-9]+,[0-9]+,)?"([^"]+)",(.*)/);

		if (!m)
			continue;

		let mode = m[2];
		let f = map(split(m[3], ','), (x) => trim(x));
		let v = (i) => (f[i] != null && match(f[i], /^[0-9]+$/)) ? +f[i] : null;
		let out = { mode: mode, gsm_rssi: null, wcdma: null, lte: null };

		if (mode == 'LTE') {
			let rssi = v(0), rsrp = v(1), sinr = v(2), rsrq = v(3);

			out.lte = {
				rssi: (rssi != null) ? rssi - 121 : null,
				rsrp: (rsrp != null) ? rsrp - 141 : null,
				sinr: (sinr != null) ? (sinr * 0.2 - 20) : null,
				rsrq: (rsrq != null) ? (rsrq * 0.5 - 19.5) : null,
			};
		}
		else if (mode == 'WCDMA') {
			let rssi = v(0), rscp = v(1), ecio = v(2);

			out.wcdma = { rssi: (rssi != null) ? rssi - 121 : null,
			              rscp: (rscp != null) ? rscp - 121 : null,
			              ecio: (ecio != null) ? (ecio * 0.5 - 32) : null };
		}
		else if (mode == 'GSM') {
			let rssi = v(0);

			out.gsm_rssi = (rssi != null) ? rssi - 121 : null;
		}

		return out;
	}

	return null;
}

// Huawei ^MONSC serving cell (BEST-EFFORT). LTE form:
//   ^MONSC: LTE,<mcc>,<mnc>,<arfcn>,<cellid-hex>,<pci>,<tac-hex>,<rsrp>,<rsrq>,<rxlev>
// rsrp/rsrq are already dBm/dB; returned in QMI 0.1 dB units (×10) plus the
// mcc/mnc/earfcn/pci/tac/cid identifiers for the lte_intra shape.
export function parse_monsc(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /\^MONSC:\s*LTE,(.*)/);

		if (!m)
			continue;

		let f = map(split(m[1], ','), (x) => trim(x));
		let num = (s) => (s != null && match(s, /^-?[0-9]+$/)) ? +s : null;
		let hn = (s) => (s != null && match(s, /^[0-9A-Fa-f]+$/)) ? hex(s) : null;

		return {
			rat: 'LTE', mcc: num(f[0]), mnc: f[1], earfcn: num(f[2]),
			cid: hn(f[3]), pci: num(f[4]), tac: hn(f[5]),
			rsrp: (num(f[6]) != null) ? num(f[6]) * 10 : null,
			rsrq: (num(f[7]) != null) ? num(f[7]) * 10 : null,
			rssi: (num(f[8]) != null) ? num(f[8]) * 10 : null,
			rsrp_dbm: num(f[6]), rsrq_db: num(f[7]),
		};
	}

	return null;
}

// Huawei ^MONNC neighbour cells (BEST-EFFORT; field layout not verified —
// parsed defensively as earfcn,pci,rsrp,rsrq,...). Metrics in 0.1 dB units.
export function parse_monnc(lines)
{
	let out = [];
	let num = (s) => (s != null && match(s, /^-?[0-9]+$/)) ? +s : null;

	for (let l in (lines ?? [])) {
		let m = match(l, /\^MONNC:\s*LTE,(.*)/);

		if (!m)
			continue;

		let f = map(split(m[1], ','), (x) => trim(x));

		if (num(f[1]) == null)
			continue;

		push(out, { earfcn: num(f[0]), pci: num(f[1]),
			rsrp: (num(f[2]) != null) ? num(f[2]) * 10 : null,
			rsrq: (num(f[3]) != null) ? num(f[3]) * 10 : null });
	}

	return out;
}

// MeiG (ASR) AT+MENG="servingcell" — MeiG's QENG analogue (BEST-EFFORT; verified
// against the SLM770A/SLM750 AT manual but not on wwand hardware). LTE form:
//   +MENG: "servingcell",<state>,"LTE",<is_tdd>,<MCC>,<MNC>,<cellID>,<PCI>,
//          <EARFCN>,<freq_band_ind>,<UL_bw>,<DL_bw>,<TAC>,<RSRP>,<RSRQ>,<RSSI>,<srxlev>
// rsrp/rsrq/rssi/srxlev returned in QMI 0.1 dB units (×10); rsrp_dbm/rsrq_db kept
// as plain dBm/dB for self.signal.
export function parse_meng_servingcell(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /\+MENG:\s*"?\s*servingcell\s*"?,(.*)/);

		if (!m)
			continue;

		let f = map(split(m[1], ','), (x) => replace(trim(x), /^"|"$/g, ''));

		if (f[1] != 'LTE')
			continue;   // only LTE mapped (MeiG SLM7xx are Cat4 LTE)

		let num = (s) => (s != null && match(s, /^-?[0-9]+$/)) ? +s : null;
		let hn = (s) => (s != null && match(s, /^[0-9A-Fa-f]+$/)) ? hex(s) : null;

		return {
			rat: 'LTE', mcc: num(f[3]), mnc: f[4], cid: hn(f[5]), pci: num(f[6]),
			earfcn: num(f[7]), band: num(f[8]), tac: hn(f[11]),
			rsrp: (num(f[12]) != null) ? num(f[12]) * 10 : null,
			rsrq: (num(f[13]) != null) ? num(f[13]) * 10 : null,
			rssi: (num(f[14]) != null) ? num(f[14]) * 10 : null,
			srxlev: (num(f[15]) != null) ? num(f[15]) * 10 : null,
			rsrp_dbm: num(f[12]), rsrq_db: num(f[13]),
		};
	}

	return null;
}

// MeiG (ASR) AT+MENG="neighbourcell" (BEST-EFFORT). LTE form — NOTE the metric
// order is RSRP,RSRQ (opposite of Quectel's neighbourcell rsrq,rsrp):
//   +MENG: "neighbourcell intra","LTE",<EARFCN>,<PCI>,<RSRP>,<RSRQ>,-,-,<srxlev>,...
export function parse_meng_neighbourcell(lines)
{
	let out = { intra: [], inter: [] };
	let num = (s) => (s != null && match(s, /^-?[0-9]+$/)) ? +s : null;

	for (let l in (lines ?? [])) {
		let m = match(l, /\+MENG:\s*"?\s*neighbourcell([^",]*)"?,"LTE",(.*)/);

		if (!m)
			continue;

		let scope = trim(m[1]);
		let f = map(split(m[2], ','), (x) => trim(x));

		if (num(f[1]) == null)
			continue;

		let cell = { earfcn: num(f[0]), pci: num(f[1]),
			rsrp: (num(f[2]) != null) ? num(f[2]) * 10 : null,
			rsrq: (num(f[3]) != null) ? num(f[3]) * 10 : null,
			srxlev: (num(f[6]) != null) ? num(f[6]) * 10 : null };

		push((scope == 'inter') ? out.inter : out.intra, cell);
	}

	return out;
}

// parse an AT+COPS=? test response into the visible operators (the AT-backend
// network scan, COPS being the AT equivalent of QMI Network Scan). The +COPS:
// line carries a list of parenthesised operator descriptors followed by the
// supported <mode>/<AcT> value ranges:
//   +COPS: (<stat>,"<long>","<short>","<mccmnc>"[,<AcT>]),(...),,(0-4),(0,1,2)
// <stat>: 0 unknown, 1 available, 2 current, 3 forbidden. Returns
// [ { mcc, mnc, name, status:'available'|'current'|'forbidden' }, ... ]; the
// trailing numeric value-range groups (no quoted mccmnc) are skipped.
export function parse_cops_scan(lines)
{
	let out = [];

	for (let l in (lines ?? [])) {
		let m = match(l, /\+COPS:\s*(.*)/);

		if (!m)
			continue;

		for (let g in (match(m[1], /\(([^()]*)\)/g) ?? [])) {
			let f = split(g[1], ',');

			if (length(f) < 4)
				continue;   // a mode/AcT value-range group, not an operator

			let numeric = replace(trim(f[3]), /"/g, '');

			if (!match(numeric, /^[0-9]{5,6}$/))
				continue;   // no quoted PLMN id -> not an operator descriptor

			let stat = +trim(f[0]);

			push(out, {
				mcc:    +substr(numeric, 0, 3),
				mnc:    +substr(numeric, 3),
				name:   replace(trim(f[1]), /"/g, ''),
				status: (stat == 2) ? 'current' : (stat == 3) ? 'forbidden' : 'available',
			});
		}
	}

	return out;
}

// --- AT port discovery -------------------------------------------------------

const ROLE_PREFERENCE = { at: 3, at2: 2, ppp: 1 };

// find_tty(fx, device, tty_override, base_override):
//   device        a cdc-wdm control device ('/dev/cdc-wdmN'); the USB parent is
//                 derived from it. May be null when base_override is supplied.
//   base_override an explicit sysfs USB-device base to enumerate tty siblings
//                 under (used by discovery.uc for NCM/PPP modems, which have no
//                 cdc-wdm to anchor on — the base is the netdev's or usb_path's
//                 USB device dir).
export function find_tty(fx, device, tty_override, base_override)
{
	if (tty_override != null && tty_override != '')
		return tty_override;

	// board quirks first: integrated modems
	let board = trim(fx.read('/tmp/sysinfo/board_name') ?? '');

	for (let b in BOARD_TTYS)
		if (substr(board, 0, length(b.prefix)) == b.prefix)
			return b.tty;

	let base = base_override;

	if (base == null) {
		if (device == null)
			return null;   // no cdc-wdm anchor and no explicit base

		let name = substr(device, rindex(device, '/') + 1);
		base = sprintf('/sys/class/usbmisc/%s/device/..', name);
	}

	// enumerate tty siblings below the same USB device
	let tty_paths = fx.glob(sprintf('%s/*/tty*', base)) ?? [];
	let found = [];

	for (let path in tty_paths) {
		let tty = substr(path, rindex(path, '/') + 1);

		if (substr(tty, 0, 3) != 'tty')
			continue;

		let ifdir = substr(path, 0, rindex(path, '/'));
		let ifnum_raw = trim(fx.read(sprintf('%s/bInterfaceNumber', ifdir)) ?? '');

		push(found, {
			tty: tty,
			ifnum: length(ifnum_raw) ? hex('0x' + ifnum_raw) : null,
		});
	}

	if (!length(found))
		return null;

	// exact role lookup via USB ids
	let vid = lc(trim(fx.read(sprintf('%s/idVendor', base)) ?? ''));
	let pid = lc(trim(fx.read(sprintf('%s/idProduct', base)) ?? ''));
	let usbid = sprintf('%s:%s', vid, pid);
	let ports = LOCAL_PORTS[usbid] ?? atport_table()[usbid];

	if (ports) {
		let best = null, best_score = 0;

		for (let f in found) {
			let role = (f.ifnum != null) ? ports[sprintf('%d', f.ifnum)] : null;
			let score = ROLE_PREFERENCE[role] ?? 0;

			if (score > best_score) {
				best = f;
				best_score = score;
			}
		}

		if (best)
			return sprintf('/dev/%s', best.tty);
	}

	// heuristic fallback: first tty, sorted (old behavior)
	let names = sort(map(found, (f) => f.tty));

	return sprintf('/dev/%s', names[0]);
}

// --- transport ---------------------------------------------------------------

// real tty transport; kept separate so the engine stays host-testable
export function open_transport(path, baud, log)
{
	// deferred import: wwand_io is a native module, tests never load it
	let qmit = require('wwand_io');

	let handle = qmit.open_tty(path, baud ?? 115200);

	if (!handle) {
		if (log)
			log('warn', sprintf('cannot open %s: %s', path, qmit.last_error()));

		return null;
	}

	let self = { closed: false };
	let data_cb = null;

	let uhandle = uloop.handle(handle.fileno(), (events) => {
		while (true) {
			let chunk = handle.read();

			if (chunk === null || chunk === false)
				break;

			if (data_cb)
				data_cb(chunk);
		}
	}, uloop.ULOOP_READ);

	self.write = (data) => handle.write(data);
	self.on_data = (cb) => { data_cb = cb; };
	self.drain = () => {
		while (true) {
			let chunk = handle.read();

			if (chunk === null || chunk === false)
				break;
		}
	};
	self.close = () => {
		if (self.closed)
			return;

		self.closed = true;

		if (uhandle)
			uhandle.delete();

		handle.close();
	};

	return self;
}

// --- engine ------------------------------------------------------------------

export function create(transport, opts)
{
	let log = opts?.log ?? ((level, msg) => warn(sprintf('%s: at: %s\n', level, msg)));

	let self = {
		queue: [],
		current: null,
		buffer: '',
	};

	let finish, next;

	finish = (err, lines) => {
		let cur = self.current;

		if (!cur)
			return;

		self.current = null;

		if (cur.timer)
			cur.timer.cancel();

		if (cur.cb)
			cur.cb(err, { lines: lines });

		next();
	};

	next = () => {
		if (self.current || !length(self.queue))
			return;

		let cur = self.current = shift(self.queue);

		self.buffer = '';
		cur.lines = [];

		cur.timer = uloop.timer(cur.timeout, () => {
			log('warn', sprintf('timeout waiting for reply to %s', cur.cmd));
			finish({ error: 'timeout' }, cur.lines);
		});

		transport.write(cur.cmd + '\r');
	};

	transport.on_data((chunk) => {
		let cur = self.current;

		if (!cur) {
			// unsolicited data outside a command: discard
			return;
		}

		self.buffer += chunk;

		let idx;

		while ((idx = index(self.buffer, '\n')) >= 0) {
			let line = trim(substr(self.buffer, 0, idx));

			self.buffer = substr(self.buffer, idx + 1);

			if (line == '' || line == cur.cmd)   // skip blanks and echo
				continue;

			if (line == 'OK')
				return finish(null, cur.lines);

			if (line == 'ERROR' || line == 'COMMAND NOT SUPPORT')
				return finish({ error: 'ERROR' }, cur.lines);

			let m = match(line, /^\+(CME|CMS) ERROR: *(.*)$/);

			if (m)
				return finish({ error: lc(m[1]), code: m[2] }, cur.lines);

			push(cur.lines, line);
		}
	});

	self.send = function(cmd, cb, o) {
		push(self.queue, {
			cmd: cmd,
			cb: cb,
			timeout: o?.timeout ?? DEFAULT_TIMEOUT,
		});

		next();
	};

	// run a list of commands sequentially, best-effort (errors logged only)
	self.run_sequence = function(cmds, done) {
		let idx = 0;
		let step;

		step = () => {
			if (idx >= length(cmds))
				return done ? done() : null;

			let cmd = cmds[idx++];

			self.send(cmd, (err, res) => {
				if (err)
					log('warn', sprintf('%s failed: %J', cmd, err));
				else
					log('info', sprintf('%s ok', cmd));

				step();
			});
		};

		step();
	};

	// discard pending serial noise (old M9200B empty_serial_buffers quirk)
	self.drain = function() {
		if (!self.current && transport.drain)
			transport.drain();
	};

	self.close = function() {
		if (self.current?.timer)
			self.current.timer.cancel();

		self.current = null;
		self.queue = [];
		transport.close();
	};

	return self;
}
