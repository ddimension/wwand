// wwand — per-vendor NCM/AT telemetry blocks (extracted from modem_ncm.uc).
//
// The telemetry AT differs per manufacturer; each exported table provides
// best-effort steps, each taking the modem `self` + a completion cb and
// mutating self.signal / self.cells / self.reg_detail using self.at (see the
// section comment below for the exact step contract and metric scaling —
// shapes match the QMI backend so LuCI renders identically). modem_ncm.uc
// wires the tables onto its VENDORS entries.

'use strict';

import * as atcmd from './atcmd.uc';
import * as modem_common from './modem_common.uc';
import * as nasmod from './codec/schema/nas.uc';

// like modem_common.dsd_from_serving, but tagged source:'at' — on the NCM
// backend the QENG/serving parse IS the AT source (the QMI path tags at the
// call site instead)
function dsd_from_serving(serving)
{
	let d = modem_common.dsd_from_serving(serving);

	if (d)
		d.source = 'at';

	return d;
}

// +CSQ: <rssi>,<ber> — rssi 0..31 coded (99 = unknown) -> dBm
function parse_csq(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /\+CSQ:\s*([0-9]+),/);

		if (m) {
			let raw = +m[1];

			return { rssi_raw: raw, rssi: (raw != 99) ? (-113 + 2 * raw) : null };
		}
	}

	return null;
}

// --- per-vendor telemetry ----------------------------------------------------
//
// The telemetry AT differs per manufacturer, so each VENDORS entry carries a
// `telemetry` block instead of the loop hard-coding Quectel commands. A block
// provides best-effort steps, each taking the modem `self` + a completion cb and
// mutating self.signal / self.cells / self.reg_detail using self.at:
//   signal(self, cb)      -> self.signal      (RSSI/RSRP/RSRQ/SNR per RAT)
//   cells(self, cb)       -> self.cells        (QMI GET_CELL_LOCATION_INFO shape:
//                                               lte_intra/lte_inter/nr5g_cell + serving)
//   ca(self, cb)          -> self.cells.ca     (carrier-aggregation carriers)
//   reg_detail(self, cb)  -> self.reg_detail   ({ source, reject_cause, reject_text })
//   locks(self, cb)?      -> self.locks        (cell-lock read-back; optional)
// Every command is best-effort — an AT error is swallowed and the step keeps the
// last-known value. Vendors without a block fall back to TELEMETRY_GENERIC (a
// 3GPP-only CSQ+CESQ+CEER set). `unverified: true` blocks log a one-time warning.
//
// SCALING (matches the QMI backend so the LuCI status page renders identically):
//   - self.signal.{lte,nr5g}: rsrp/rsrq/rssi in plain dBm/dB, snr in 0.1 dB.
//   - cell-structure metrics (lte_intra/lte_inter cells, nr5g_cell): 0.1 dB units
//     (the atcmd parsers already ×10) so they render through LuCI's sig10 (÷10)
//     path exactly like the QMI GET_CELL_LOCATION_INFO set.

// merge a CSQ RSSI floor into self.signal without clobbering per-RAT metrics
function sig_csq_floor(self, s)
{
	let base = { ...(self.signal ?? {}) };

	if (s) {
		base.rssi_raw = s.rssi_raw;

		if (base.lte == null && base.nr5g == null)
			base.rssi = s.rssi;
	}

	self.signal = base;
}

// mirror serving-cell metrics into self.signal.{lte,nr5g} only where a more
// authoritative source (per-branch QRSRP/QRSRQ/QSINR, ^HCSQ, CESQ) left a gap
function fill_signal_from_serving(self, serving)
{
	let sig = { ...(self.signal ?? {}) };

	if (serving?.lte) {
		let cur = { ...(sig.lte ?? {}) };

		cur.rssi = cur.rssi ?? sig.rssi;
		cur.rsrp = cur.rsrp ?? serving.lte.rsrp;
		cur.rsrq = cur.rsrq ?? serving.lte.rsrq;

		if (cur.snr == null && serving.lte.sinr != null)
			cur.snr = serving.lte.sinr * 10;   // QMI snr is 0.1 dB

		sig.lte = cur;
	}

	if (serving?.nr) {
		let cur = { ...(sig.nr5g ?? {}) };

		cur.rsrp = cur.rsrp ?? serving.nr.rsrp;
		cur.rsrq = cur.rsrq ?? serving.nr.rsrq;

		if (cur.snr == null && serving.nr.sinr != null)
			cur.snr = serving.nr.sinr * 10;

		sig.nr5g = cur;
	}

	self.signal = sig;
}

// group a flat inter-frequency neighbour list into { freqs:[{earfcn,cells:[]}] }
// (numeric keys are quoted per the ucode object-key gotcha, looked up via %d)
function group_inter(list)
{
	let byf = {}, order = [];

	for (let c in (list ?? [])) {
		let k = sprintf('%d', c.earfcn ?? -1);

		if (!byf[k]) {
			byf[k] = { earfcn: c.earfcn, cells: [] };
			push(order, k);
		}

		push(byf[k].cells, { pci: c.pci, rsrp: c.rsrp, rsrq: c.rsrq,
		                     rssi: c.rssi, srxlev: c.srxlev });
	}

	if (!length(order))
		return null;

	let freqs = [];

	for (let k in order)
		push(freqs, byf[k]);

	return { freqs: freqs };
}

// build the QMI lte_intra/lte_inter/nr5g_cell shape from a parsed serving cell
// (parse_qeng_servingcell/parse_monsc/parse_meng_servingcell) + a neighbour set
// ({ intra:[], inter:[] } already in 0.1 dB units). `sc` carries mcc/mnc/cid/tac/
// earfcn/pci and dBm rsrp/rsrq (via rsrp_dbm/rsrq_db or serving.lte.*).
function assemble_cells(self, serving, neigh, dsd)
{
	if (!serving || (!serving.lte && !serving.nr))
		return;   // keep last-known cells

	let ca = self.cells?.ca;
	let cells = { serving: serving };
	let sl = serving.lte;

	if (sl) {
		let scells = [];

		// the serving cell is the lte_intra entry whose pci == serving_cell_id
		if (sl.pci != null)
			push(scells, {
				pci: sl.pci,
				rsrp: (sl.rsrp != null) ? sl.rsrp * 10 : null,
				rsrq: (sl.rsrq != null) ? sl.rsrq * 10 : null,
				rssi: (sl.rssi != null) ? sl.rssi * 10 : null,
				srxlev: null,
			});

		for (let c in (neigh?.intra ?? []))
			if (c.pci != sl.pci)
				push(scells, c);

		cells.lte_intra = {
			plmn: (sl.mcc != null && sl.mnc != null) ? sprintf('%d/%s', sl.mcc, sl.mnc) : null,
			tac: sl.tac, global_cell_id: sl.cid, earfcn: sl.earfcn,
			serving_cell_id: sl.pci, cells: scells,
		};

		let inter = group_inter(neigh?.inter);

		if (inter)
			cells.lte_inter = inter;
	}

	let sn = serving.nr;

	if (sn) {
		cells.nr5g_arfcn = sn.arfcn;
		cells.nr5g_cell = {
			plmn: (sn.mcc != null && sn.mnc != null) ? sprintf('%d/%s', sn.mcc, sn.mnc) : null,
			tac: sn.tac, global_cell_id: sn.cid, pci: sn.pci,
			rsrp: (sn.rsrp != null) ? sn.rsrp * 10 : null,
			rsrq: (sn.rsrq != null) ? sn.rsrq * 10 : null,
			snr: (sn.sinr != null) ? sn.sinr * 10 : null,
		};
	}

	if (ca != null)
		cells.ca = ca;

	self.cells = cells;
	self.dsd_status = dsd ?? dsd_from_serving(serving);
	fill_signal_from_serving(self, serving);
}

// --- Quectel / Qualcomm telemetry (primary; verified command syntax) ---------

function tel_quectel_signal(self, cb)
{
	modem_common.telemetry_at(self).send('AT+CSQ', (err, res) => {
		sig_csq_floor(self, err ? null : parse_csq(res?.lines));

		// per-branch QRSRP/QRSRQ/QSINR: authoritative rsrp/rsrq/snr (antenna aim)
		modem_common.telemetry_at(self).send('AT+QRSRP?', (e1, r1) => {
			let rp = e1 ? null : atcmd.parse_qrsrp(r1?.lines);

			modem_common.telemetry_at(self).send('AT+QRSRQ?', (e2, r2) => {
				let rq = e2 ? null : atcmd.parse_qrsrq(r2?.lines);

				modem_common.telemetry_at(self).send('AT+QSINR?', (e3, r3) => {
					let sn = e3 ? null : atcmd.parse_qsinr(r3?.lines);

					let mode = rp?.mode ?? rq?.mode ?? sn?.mode;

					if (mode) {
						let sig = { ...(self.signal ?? {}) };
						let slot = (index(mode, 'NR') >= 0) ? 'nr5g' : 'lte';
						let cur = { ...(sig[slot] ?? {}) };
						let rsrp = atcmd.branch_best(rp, -200);
						let rsrq = atcmd.branch_best(rq, -200);
						let sinr = atcmd.branch_best(sn, -200);

						if (rsrp != null) cur.rsrp = rsrp;
						if (rsrq != null) cur.rsrq = rsrq;
						if (sinr != null) cur.snr = sinr * 10;
						if (slot == 'lte' && cur.rssi == null) cur.rssi = sig.rssi;

						sig[slot] = cur;
						self.signal = sig;
					}

					cb();
				});
			});
		});
	});
}

function tel_quectel_cells(self, cb)
{
	modem_common.telemetry_at(self).send('AT+QENG="servingcell"', (err, res) => {
		let serving = err ? null : atcmd.parse_qeng_servingcell(res?.lines);

		modem_common.telemetry_at(self).send('AT+QENG="neighbourcell"', (e2, r2) => {
			let neigh = e2 ? null : atcmd.parse_qeng_neighbourcell(r2?.lines);

			assemble_cells(self, serving, neigh);
			if (self.cells)
				self.cells.nr5g_neigh = (neigh && length(neigh.nr)) ? neigh.nr : null;
			cb();
		});
	});
}

function tel_quectel_ca(self, cb)
{
	modem_common.telemetry_at(self).send('AT+QCAINFO', (err, res) => {
		if (!err && self.cells)
			self.cells.ca = atcmd.parse_qcainfo(res?.lines);

		cb();
	});
}

// cell-lock read-back: expose whether a 4G/5G lock is currently armed so the
// status / settings pages can show it (mirrors nothing in QMI, but useful)
function tel_quectel_locks(self, cb)
{
	modem_common.telemetry_at(self).send('AT+QNWLOCK="common/4g"', (e1, r1) => {
		let l4 = e1 ? null : atcmd.parse_qnwlock(r1?.lines);

		modem_common.telemetry_at(self).send('AT+QNWLOCK="common/5g"', (e2, r2) => {
			let l5 = e2 ? null : atcmd.parse_qnwlock(r2?.lines);
			let locks = {};

			if (l4) locks.lte = { enabled: l4.enabled, values: l4.values };
			if (l5) locks.nr5g = { enabled: l5.enabled, values: l5.values };

			self.locks = length(locks) ? locks : null;
			cb();
		});
	});
}

// --- generic 3GPP telemetry (always-available fallback) ----------------------

function merge_cesq_signal(self, c)
{
	let sig = { ...(self.signal ?? {}) };

	if (c.lte && (c.lte.rsrp != null || c.lte.rsrq != null)) {
		let cur = { ...(sig.lte ?? {}) };

		cur.rssi = cur.rssi ?? sig.rssi;
		if (c.lte.rsrp != null) cur.rsrp = cur.rsrp ?? c.lte.rsrp;
		if (c.lte.rsrq != null) cur.rsrq = cur.rsrq ?? c.lte.rsrq;
		sig.lte = cur;
	}

	if (c.wcdma && c.wcdma.rscp != null)
		sig.wcdma = { rssi: sig.rssi, rscp: c.wcdma.rscp, ecio: c.wcdma.ecno };

	if (c.gsm_rssi != null)
		sig.gsm_rssi = c.gsm_rssi;

	self.signal = sig;
}

function tel_generic_signal(self, cb)
{
	modem_common.telemetry_at(self).send('AT+CSQ', (err, res) => {
		sig_csq_floor(self, err ? null : parse_csq(res?.lines));

		modem_common.telemetry_at(self).send('AT+CESQ', (e2, r2) => {
			let c = e2 ? null : atcmd.parse_cesq(r2?.lines);

			if (c)
				merge_cesq_signal(self, c);

			cb();
		});
	});
}

// generic 3GPP has no portable serving-cell command -> keep last-known cells
function tel_noop(self, cb) { cb(); }

// AT+CEER reject-cause -> reg_detail (mapped through the QMI REJECT_CAUSE table).
// Only populated when a numeric cause is present (a benign "no cause" reply must
// not masquerade as a rejection; on_registered clears reg_detail outright).
function tel_ceer_reg_detail(self, cb)
{
	modem_common.telemetry_at(self).send('AT+CEER', (err, res) => {
		let c = err ? null : atcmd.parse_ceer(res?.lines);

		if (c && c.cause != null)
			self.reg_detail = {
				source: 'at',
				reject_cause: c.cause,
				reject_text: nasmod.REJECT_CAUSE[sprintf('%d', c.cause)] ?? c.text,
			};

		cb();
	});
}

// --- Huawei telemetry (BEST-EFFORT — see atcmd parser notes) -----------------

function tel_huawei_signal(self, cb)
{
	modem_common.telemetry_at(self).send('AT+CSQ', (err, res) => {
		sig_csq_floor(self, err ? null : parse_csq(res?.lines));

		modem_common.telemetry_at(self).send('AT^HCSQ?', (e2, r2) => {
			let h = e2 ? null : atcmd.parse_hcsq(r2?.lines);

			if (h?.lte) {
				let sig = { ...(self.signal ?? {}) };
				let cur = { ...(sig.lte ?? {}) };

				cur.rssi = (h.lte.rssi != null) ? h.lte.rssi : (cur.rssi ?? sig.rssi);
				if (h.lte.rsrp != null) cur.rsrp = h.lte.rsrp;
				if (h.lte.rsrq != null) cur.rsrq = h.lte.rsrq;
				if (h.lte.sinr != null) cur.snr = h.lte.sinr * 10;
				sig.lte = cur;
				self.signal = sig;
			}

			cb();
		});
	});
}

// wrap a parse_monsc/parse_meng_servingcell descriptor as a serving object with
// dBm rsrp/rsrq for fill_signal_from_serving + assemble_cells
function sc_to_serving(sc)
{
	return { lte: {
		band: sc.band, earfcn: sc.earfcn, pci: sc.pci, mcc: sc.mcc, mnc: sc.mnc,
		cid: sc.cid, tac: sc.tac, rsrp: sc.rsrp_dbm, rsrq: sc.rsrq_db,
		sinr: sc.sinr_db ?? null,
	} };
}

function tel_huawei_cells(self, cb)
{
	modem_common.telemetry_at(self).send('AT^MONSC', (err, res) => {
		let sc = err ? null : atcmd.parse_monsc(res?.lines);

		modem_common.telemetry_at(self).send('AT^MONNC', (e2, r2) => {
			let nc = e2 ? null : atcmd.parse_monnc(r2?.lines);

			if (sc) {
				let serving = sc_to_serving(sc);
				// serving.lte.rsrp is dBm; assemble_cells ×10 for the intra entry
				assemble_cells(self, serving, { intra: nc ?? [], inter: [] },
					{ mode: 'LTE', lte: true, nr: false, source: 'at' });
			}

			cb();
		});
	});
}

// --- MeiG (ASR) telemetry (AT+MENG, MeiG's QENG analogue; HW-verified on the
// SLM770A-R / Cudy LT300 v3) --------------------------------------------------

function tel_meig_cells(self, cb)
{
	modem_common.telemetry_at(self).send('AT+MENG="servingcell"', (err, res) => {
		let sc = err ? null : atcmd.parse_meng_servingcell(res?.lines);

		modem_common.telemetry_at(self).send('AT+MENG="neighbourcell"', (e2, r2) => {
			let nc = e2 ? null : atcmd.parse_meng_neighbourcell(r2?.lines);

			if (sc) {
				let serving = sc_to_serving(sc);
				assemble_cells(self, serving, nc ?? { intra: [], inter: [] },
					{ mode: 'LTE', lte: true, nr: false, source: 'at' });
			}

			cb();
		});
	});
}

const TELEMETRY_QUECTEL = {
	signal: tel_quectel_signal, cells: tel_quectel_cells,
	ca: tel_quectel_ca, reg_detail: tel_ceer_reg_detail, locks: tel_quectel_locks,
};

const TELEMETRY_HUAWEI = {
	signal: tel_huawei_signal, cells: tel_huawei_cells,
	ca: tel_noop, reg_detail: tel_ceer_reg_detail, unverified: true,
};

// MeiG AT^CELLLOCK? read-back (Huawei-style; set-side needs CFUN cycling per
// the manual, so wwand only *reports* the lock state for now).
function tel_meig_locks(self, cb)
{
	modem_common.telemetry_at(self).send('AT^CELLLOCK?', (err, res) => {
		let ls = err ? null : atcmd.parse_celllock(res?.lines);
		let locks = {};

		for (let e in (ls ?? [])) {
			if (e.rat != null && e.rat != 'LTE')
				continue;

			let vals = [];
			if (e.arfcn != null) push(vals, e.arfcn);
			if (e.pci != null) push(vals, e.pci);
			locks.lte = { enabled: e.enabled, values: vals };
		}

		self.locks = length(locks) ? locks : null;
		cb();
	});
}

const TELEMETRY_MEIG = {
	signal: tel_generic_signal, cells: tel_meig_cells,
	ca: tel_noop, reg_detail: tel_ceer_reg_detail, locks: tel_meig_locks,
};

const TELEMETRY_GENERIC = {
	signal: tel_generic_signal, cells: tel_noop,
	ca: tel_noop, reg_detail: tel_ceer_reg_detail,
};

// exported vendor tables (wired onto VENDORS in modem_ncm.uc)
export const QUECTEL = TELEMETRY_QUECTEL;
export const HUAWEI  = TELEMETRY_HUAWEI;
export const MEIG    = TELEMETRY_MEIG;
export const GENERIC = TELEMETRY_GENERIC;
