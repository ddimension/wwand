// wwand — vendor AT response parsers (volatile per-firmware pieces split from
// atcmd.uc, which re-exports them). Each parser takes the reply's `lines` array
// and returns plain data (null/[] when nothing usable). Covered by test_atcmd.

'use strict';

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
};

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
};

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
};

// parse AT+QENG="neighbourcell" (Quectel) into intra- and inter-frequency LTE
// neighbours. rsrp/rsrq/rssi/srxlev come out in QMI 0.1 dB units (×10) so they
// slot straight into the GET_CELL_LOCATION_INFO lte_intra/lte_inter shape and
// render through the same LuCI sig10 (÷10) path as the QMI set. Quectel format
// (QuecCell AT manual), fields after the RAT tag:
//   +QENG: "neighbourcell intra","LTE",<earfcn>,<pcid>,<rsrq>,<rsrp>,<rssi>,<sinr>,<srxlev>,...
//   +QENG: "neighbourcell inter","LTE",<earfcn>,<pcid>,<rsrq>,<rsrp>,<rssi>,<sinr>,<srxlev>,...
//   +QENG: "neighbourcell","LTE",...            (older firmwares; treated as intra)
// QMI Get Cell Location Info carries NO NR neighbour cells (only the NR serving
// cell), so the NR5G neighbour set comes ONLY from here — the single backend-
// neutral source, run over the shared AT side channel. NR field order varies by
// firmware; the ARFCN (large) is told apart from the PCI (<= 1007) by magnitude.
//   +QENG: "neighbourcell","NR5G",<arfcn>,<pci>,<rsrp>,<rsrq>,<sinr>[,...]
//   +QENG: "neighbourcell","NR5G",<pci>,<rsrp>,<rsrq>,<sinr>[,...]  (no arfcn)
// returns { intra:[{earfcn,pci,rsrq,rsrp,rssi,srxlev}], inter:[…],
//           nr:[{arfcn,pci,rsrp,rsrq,sinr}] }.
export function parse_qeng_neighbourcell(lines)
{
	let out = { intra: [], inter: [], nr: [] };
	let num = (s) => (s != null && match(s, /^-?[0-9]+$/)) ? +s : null;
	let x10 = (s) => { let n = num(s); return (n != null) ? n * 10 : null; };

	for (let l in (lines ?? [])) {
		let mn = match(l, /\+QENG:\s*"neighbourcell[^"]*","NR5G",(.*)/);

		if (mn) {
			let f = map(split(mn[1], ','), (x) => trim(x));
			let f0 = num(f[0]);
			let has_arfcn = (f0 != null && f0 > 3300);   // ARFCN >> max PCI (1007)
			let i = has_arfcn ? 1 : 0;
			let cell = {
				arfcn: has_arfcn ? f0 : null, pci: num(f[i]),
				rsrp: x10(f[i + 1]), rsrq: x10(f[i + 2]), sinr: num(f[i + 3]),
			};
			if (cell.pci != null)
				push(out.nr, cell);
			continue;
		}

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
};

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

export function parse_qrsrp(lines) { return qbranch(lines, /\+QRSRP:\s*(.*)/); };
export function parse_qrsrq(lines) { return qbranch(lines, /\+QRSRQ:\s*(.*)/); };
export function parse_qsinr(lines) { return qbranch(lines, /\+QSINR:\s*(.*)/); };

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
};

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
};

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
};

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
};

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
};

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
};

// MeiG (ASR) AT+MENG="servingcell" — MeiG's QENG analogue (HW-verified on the
// SLM770A-R B.0.3 / Cudy LT300 v3). LTE form:
//   +MENG: "servingcell",<state>,"LTE",<is_tdd>,<MCC>,<MNC>,<cellID>,<PCI>,
//          <EARFCN>,<freq_band_ind>,<UL_bw>,<DL_bw>,<TAC>,<RSRP>,<RSRQ>,
//          <RSSI>[,<SINR>],<srxlev>
// Two firmware traps: the manual's format line omits <SINR>, but its parameter
// table (SINR range -20..30 dB), the manual's own example AND real hardware all
// carry it — so accept both the 16- and 17-field form. And RSRQ (also
// neighbour RSRP/RSRQ) can come with a decimal fraction ("-10.5"), which an
// integer-only match silently turned into null.
// rsrp/rsrq/rssi/sinr/srxlev returned in QMI 0.1 dB units (×10);
// rsrp_dbm/rsrq_db/sinr_db kept as plain dBm/dB for self.signal.
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
		let numf = (s) => (s != null && match(s, /^-?[0-9]+(\.[0-9]+)?$/)) ? +s : null;
		let x10 = (v) => (v != null) ? int(v * 10) : null;
		let hn = (s) => (s != null && match(s, /^[0-9A-Fa-f]+$/)) ? hex(s) : null;

		// 17 metric-bearing fields when SINR is present, 16 without
		let sinr = (length(f) >= 17) ? numf(f[15]) : null;
		let srxlev = numf(f[(length(f) >= 17) ? 16 : 15]);

		return {
			rat: 'LTE', mcc: num(f[3]), mnc: f[4], cid: hn(f[5]), pci: num(f[6]),
			earfcn: num(f[7]), band: num(f[8]), tac: hn(f[11]),
			rsrp: x10(numf(f[12])),
			rsrq: x10(numf(f[13])),
			rssi: x10(numf(f[14])),
			sinr: x10(sinr),
			srxlev: x10(srxlev),
			rsrp_dbm: numf(f[12]), rsrq_db: numf(f[13]), sinr_db: sinr,
		};
	}

	return null;
};

// MeiG (ASR) AT+MENG="neighbourcell" (BEST-EFFORT). LTE form — NOTE the metric
// order is RSRP,RSRQ (opposite of Quectel's neighbourcell rsrq,rsrp):
//   +MENG: "neighbourcell intra","LTE",<EARFCN>,<PCI>,<RSRP>,<RSRQ>,-,-,<srxlev>,...
export function parse_meng_neighbourcell(lines)
{
	let out = { intra: [], inter: [] };
	let num = (s) => (s != null && match(s, /^-?[0-9]+$/)) ? +s : null;
	// metrics may carry a decimal fraction on real firmware (e.g. rsrq -17.5)
	let numf = (s) => (s != null && match(s, /^-?[0-9]+(\.[0-9]+)?$/)) ? +s : null;
	let x10 = (v) => (v != null) ? int(v * 10) : null;

	for (let l in (lines ?? [])) {
		let m = match(l, /\+MENG:\s*"?\s*neighbourcell([^",]*)"?,"LTE",(.*)/);

		if (!m)
			continue;

		let scope = trim(m[1]);
		let f = map(split(m[2], ','), (x) => trim(x));

		if (num(f[1]) == null)
			continue;

		let cell = { earfcn: num(f[0]), pci: num(f[1]),
			rsrp: x10(numf(f[2])),
			rsrq: x10(numf(f[3])),
			srxlev: x10(numf(f[6])) };

		push((scope == 'inter') ? out.inter : out.intra, cell);
	}

	return out;
};

// MeiG AT^CELLLOCK? read-back — one line per RAT:
//   ^CELLLOCK: <enable>[,<rat>,<lock_type>,<arfcn>[,<pci/psc>]]
// (lock_type 0 = frequency, 1 = frequency+cell, per the SLM770A manual 8.12).
// Returns a list of { enabled, rat, lock_type, arfcn, pci } or null.
export function parse_celllock(lines)
{
	let out = [];
	let num = (s) => (s != null && match(s, /^-?[0-9]+$/)) ? +s : null;

	for (let l in (lines ?? [])) {
		let m = match(l, /\^CELLLOCK:\s*(.*)/);

		if (!m)
			continue;

		let f = map(split(m[1], ','), (x) => replace(trim(x), /^"|"$/g, ''));

		if (num(f[0]) == null)
			continue;

		push(out, { enabled: num(f[0]) == 1, rat: f[1] ?? null,
			lock_type: num(f[2]), arfcn: num(f[3]), pci: num(f[4]) });
	}

	return length(out) ? out : null;
};

// AT+COPS? read form — the idempotency guard for network selection:
//   +COPS: <mode>[,<format>,"<oper>"[,<AcT>]]
// Returns { mode, format, oper, plmn } (plmn = digits-only oper when the
// read format is numeric, i.e. format 2) or null.
// parse ATI output into { manufacturer, model, revision } (null when nothing
// useful). Two shapes in the wild:
//   labeled: "Manufacturer: huawei" / "Model: E398" / "Revision: 11.x"
//   bare:    "Quectel\nRG650E-EU\n..." (line 1 manufacturer, line 2 model)
// URC noise (^RSSI etc.) and +-prefixed lines are ignored — old sticks spew
// unsolicited status on the same port.
export function parse_ati(lines)
{
	let out = {};
	let bare = [];

	for (let l in (lines ?? [])) {
		l = trim(l);

		if (!length(l) || l == 'OK' || uc(substr(l, 0, 3)) == 'ATI')
			continue;

		let m = match(l, /^([A-Za-z ]+): *(.+)$/);

		if (m) {
			let k = lc(trim(m[1]));

			if (k == 'manufacturer')
				out.manufacturer = trim(m[2]);
			else if (k == 'model')
				out.model = trim(m[2]);
			else if (k == 'revision')
				out.revision = trim(m[2]);
		}
		else if (substr(l, 0, 1) != '+' && substr(l, 0, 1) != '^')
			push(bare, l);
	}

	if (!out.model && length(bare) >= 2) {
		out.manufacturer = out.manufacturer ?? bare[0];
		out.model = bare[1];

		if (length(bare) >= 3)
			out.revision = out.revision ?? bare[2];
	}

	return (out.model || out.manufacturer) ? out : null;
};

export function parse_cops_read(lines)
{
	for (let l in (lines ?? [])) {
		// plain capturing group for the optional tail — ucode regexes are
		// POSIX ERE underneath, (?:...) is not portable across builds
		let m = match(l, /\+COPS:\s*([0-9]+)(\s*,\s*([0-9]+)\s*,\s*"([^"]*)")?/);

		if (!m)
			continue;

		let format = (m[3] != null) ? +m[3] : null;
		let oper = m[4] ?? null;

		return { mode: +m[1], format: format, oper: oper,
			plmn: (format == 2 && oper != null && match(oper, /^[0-9]+$/)) ? oper : null };
	}

	return null;
};

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
};
