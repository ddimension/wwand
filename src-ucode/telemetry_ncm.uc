// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — per-vendor NCM/AT telemetry blocks (extracted from modem_ncm.uc).
// The telemetry AT differs per manufacturer; each exported table provides
// best-effort steps (see the step contract + metric scaling below). Shapes match
// the QMI backend so LuCI renders identically. modem_ncm.uc wires the tables
// onto its VENDORS entries.

'use strict';

import * as atcmd from 'wwand.atcmd';
import * as arfcn_bands from 'wwand.codec.arfcn_bands';
import * as modem_common from 'wwand.modem_common';
import * as nasmod from 'wwand.codec.schema.nas';

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

// --- per-vendor telemetry ----------------------------------------------------
//
// Each block provides best-effort steps, each taking the modem `self` + a
// completion cb and mutating self.signal / self.cells / self.reg_detail via
// self.at:
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

// every vendor signal block opens with the CSQ floor read (the shared
// rssi baseline) before its own per-RAT extras — one opener, not four copies.
// parse_csq/sig_csq_floor live in modem_common (shared with the QMI backend's
// signal fallback).
function csq_first(self, then)
{
	modem_common.telemetry_at(self).send('AT+CSQ', (err, res) => {
		modem_common.sig_csq_floor(self, err ? null : modem_common.parse_csq(res?.lines));
		then();
	});
}

// mirror serving-cell metrics into self.signal.{lte,nr5g} only where a more
// authoritative source (per-branch QRSRP/QRSRQ/QSINR, ^HCSQ, CESQ) left a gap.
// `refresh` (the fibocom path passes it — the serving cells are the ONLY
// signal source there, the CSQ floor adds rssi only): take every serving
// value unconditionally, so the signal block follows the cells tick for tick
// instead of freezing on the first fill (?? keeps first-fill values to
// protect the Quectel per-branch reads).
function fill_signal_from_serving(self, serving, refresh)
{
	let sig = { ...(self.signal ?? {}) };

	if (serving?.lte) {
		let cur = { ...(sig.lte ?? {}) };

		cur.rssi = cur.rssi ?? sig.rssi;
		cur.rsrp = (refresh && serving.lte.rsrp != null) ? serving.lte.rsrp : (cur.rsrp ?? serving.lte.rsrp);
		cur.rsrq = (refresh && serving.lte.rsrq != null) ? serving.lte.rsrq : (cur.rsrq ?? serving.lte.rsrq);

		if (serving.lte.sinr != null && (refresh || cur.snr == null))
			cur.snr = serving.lte.sinr * 10;   // QMI snr is 0.1 dB

		sig.lte = cur;
	}

	if (serving?.nr) {
		let cur = { ...(sig.nr5g ?? {}) };

		cur.rsrp = (refresh && serving.nr.rsrp != null) ? serving.nr.rsrp : (cur.rsrp ?? serving.nr.rsrp);
		cur.rsrq = (refresh && serving.nr.rsrq != null) ? serving.nr.rsrq : (cur.rsrq ?? serving.nr.rsrq);

		if (serving.nr.sinr != null && (refresh || cur.snr == null))
			cur.snr = serving.nr.sinr * 10;

		sig.nr5g = cur;
	}

	// Drop the branch the serving read does NOT report. `sig` starts as a copy
	// of the previous signal block, so a branch that is merely not written this
	// tick would survive unchanged — which is how a modem falling back from 5G
	// to LTE kept showing its last NR RSRP/SINR forever (reported on an FM350-GL
	// riding out heavy rain: serving cell LTE/B3, and two frozen 5G bars under
	// it). Safe here because assemble_cells() returns before this point unless
	// the serving read produced at least one branch, so an empty or failed read
	// never reaches us and cannot blank a live reading. The signal block now
	// follows the serving cells exactly, which is what the status page shows
	// next to it.
	if (!serving?.lte)
		delete sig.lte;

	if (!serving?.nr)
		delete sig.nr5g;

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
// `signal_refresh`: see fill_signal_from_serving.
function assemble_cells(self, serving, neigh, dsd, signal_refresh)
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
	fill_signal_from_serving(self, serving, signal_refresh);
}

// --- Quectel / Qualcomm telemetry (primary; verified command syntax) ---------

function tel_quectel_signal(self, cb)
{
	csq_first(self, () => {
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
						// the branch this read does NOT report must not survive
						// from a previous RAT — a 5G->LTE fallback kept showing
						// its last NR RSRP/SINR forever (same finding as the
						// fibocom serving path; field-reported on an FM350-GL
						// in heavy rain). The cells mirror below re-fills the
						// dropped branch when the serving read still reports it.
						delete sig[(slot == 'nr5g') ? 'lte' : 'nr5g'];
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
	csq_first(self, () => {
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
	csq_first(self, () => {
		modem_common.telemetry_at(self).send('AT^HCSQ?', (e2, r2) => {
			let h = e2 ? null : atcmd.parse_hcsq(r2?.lines);

			// ^HCSQ names the active radio mode ("LTE"/"WCDMA"/"GSM") — the
			// only tech source a cells-less huawei-cdc stack (E3372H) offers;
			// carries it into reg so the status page can name the network
			// type generically (no cells -> no serving-cell derivation)
			if (h?.mode && self.reg)
				self.reg.tech = lc(h.mode);

			if (h?.lte) {
				let sig = { ...(self.signal ?? {}) };
				let cur = { ...(sig.lte ?? {}) };

				cur.rssi = (h.lte.rssi != null) ? h.lte.rssi : (cur.rssi ?? sig.rssi);
				if (h.lte.rsrp != null) cur.rsrp = h.lte.rsrp;
				if (h.lte.rsrq != null) cur.rsrq = h.lte.rsrq;
				if (h.lte.sinr != null) cur.snr = h.lte.sinr * 10;
				sig.lte = cur;
				// ^HCSQ has no NR branch — an LTE report means the modem is not
				// on NR; a stale nr5g from an earlier serving read must not
				// survive (same freeze finding as the quectel/fibocom paths)
				delete sig.nr5g;
				self.signal = sig;
			}

			cb();
		});
	});
}

// shared serving-row builders: every vendor parser feeds the same shape —
// fields a source row lacks (GTCAINFO has no identity/rsrq/sinr, GTCCINFO NR
// has no band/rsrp) come out null
function mk_lte(r)
{
	return {
		band: r.band ?? null, earfcn: r.earfcn ?? null, pci: r.pci ?? null,
		mcc: r.mcc ?? null, mnc: r.mnc ?? null, cid: r.cid ?? null, tac: r.tac ?? null,
		rsrp: r.rsrp ?? null, rsrq: r.rsrq ?? null, sinr: r.sinr ?? null,
		bw_mhz: r.bw_mhz ?? null,
	};
}

function mk_nr(r)
{
	return {
		band: r.band ?? null, arfcn: r.arfcn ?? null, pci: r.pci ?? null,
		mcc: r.mcc ?? null, mnc: r.mnc ?? null, cid: r.cid ?? null, tac: r.tac ?? null,
		rsrp: r.rsrp ?? null, rsrq: r.rsrq ?? null, sinr: r.sinr ?? null,
		bw_mhz: r.bw_mhz ?? null,
	};
}

// wrap a parse_monsc/parse_meng_servingcell descriptor as a serving object with
// dBm rsrp/rsrq for fill_signal_from_serving + assemble_cells
function sc_to_serving(sc)
{
	return { lte: mk_lte({
		band: sc.band, earfcn: sc.earfcn, pci: sc.pci, mcc: sc.mcc, mnc: sc.mnc,
		cid: sc.cid, tac: sc.tac, rsrp: sc.rsrp_dbm, rsrq: sc.rsrq_db,
		sinr: sc.sinr_db ?? null,
	}) };
}

function tel_huawei_cells(self, cb)
{
	// a stick that rejects BOTH reads rejects them forever — latch the pair
	// off after one full miss instead of re-asking (and re-logging the ERROR)
	// on every telemetry tick. HW: the E3372H over the huawei_cdc_ncm wdm
	// channel answers ^MONSC/^MONNC with ERROR on every read (2026-08-31).
	if (self._mon_latched)
		return cb();

	modem_common.telemetry_at(self).send('AT^MONSC', (err, res) => {
		let sc = err ? null : atcmd.parse_monsc(res?.lines);

		modem_common.telemetry_at(self).send('AT^MONNC', (e2, r2) => {
			let nc = e2 ? null : atcmd.parse_monnc(r2?.lines);

			if (!sc && !nc) {
				self._mon_latched = true;
				return cb();
			}

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

// --- Fibocom (FM350-GL / MediaTek T700) --------------------------------------
// Two serving-cell read-backs exist across Fibocom firmwares: GTCAINFO (FM190
// capture) and GTCCINFO (the T700's row format). The cells step tries GTCAINFO
// first and falls back to GTCCINFO — the FM350-GL answers AT+GTCAINFO? with an
// EMPTY body (field-verified) and serves its data via AT+GTCCINFO?.

// AT+GTCAINFO? is the Fibocom serving/CA cell read-back (FM190 captures; the
// GTCCINFO row of the same generation corroborates the field offsets, as does
// the 3ginfo-lite parser for older modules):
//
//   +GTCAINFO:
//   LTE PCC:     <band+100>,<pci>,<earfcn>,<rsrp+141>,...
//   NR PCC:      ...,<arfcn>,<rsrp+141>,...,<band>
//   LTE SCC<n>:  2,0,<band+100>,<pci>,<earfcn>,<rsrp+141>,...
//
// Only the corroborated offsets are parsed. rsrq/sinr positions and the NR PCC
// pci slot are UNVERIFIED and deliberately left null — a wrong offset silently
// shows garbage on the status page. Bands tolerate the +100 offset conditionally
// (>100 => subtract; NR band 77-style values are reported directly).
// shared token/offset readers for the Fibocom parsers (the same conventions
// appear in GTCAINFO and GTCCINFO): 255 = the "no measurement" sentinel,
// the LTE band is reported with a +100 offset (tolerate direct reports,
// 0 = unknown), RSRP is reported as value + 141
function numtok(s)
{
	s = trim(s ?? '');

	if (!length(s))
		return null;

	let m = match(s, /^-?[0-9]+$/);

	return m ? +s : null;
}

function hxtok(s)
{
	s = trim(s ?? '');

	return length(s) ? hex('0x' + s) : null;
}

function band_of(v)
{
	return (v != null && v > 0 && v != 255) ? ((v > 100) ? v - 100 : v) : null;
}

function rsrp_of(v)
{
	return (v != null && v != 255) ? v - 141 : null;
}

export function parse_gtcainfo(lines)
{
	let lte = null, nr = null, sccs = [];

	// numeric field read: empty/non-numeric -> null (fields can be blank)
	let f = (fields, i) => numtok(fields[i] ?? '');
	// LTE band +100 offset / RSRP +141 offset (255-sentinel-guarded)
	let band = band_of;
	let rsrp = rsrp_of;

	// T700 layout (field-verified on a real FM350-GL): "PCC:" and "SCC n:"
	// labels, and the LAST field is the RSRP as a SIGNED dBm value (-88) —
	// no offset. 255 marks "no measurement" on the offset-coded rows; on the
	// signed row the T700 reports 0 when the signal is too weak to measure
	// (HW-observed on the live FM350-GL, 2026-08-30 — the status page read
	// that 0 as a perfect 0 dBm). RSRP is physically bounded to -140..-44
	// dBm (3GPP TS 36.133, 9.1.4), so anything above -44 is a sentinel too,
	// never a measurement.
	let last_signed = (fields) => {
		let v = f(fields, length(fields) - 1);

		return (v != null && v != 255 && v <= -44) ? v : null;
	};

	for (let l in (lines ?? [])) {
		let m = match(l, /^\s*LTE PCC:\s*(.*)$/);

		if (m) {
			let fl = split(m[1], ',');

			lte = {
				band:  band(f(fl, 0)),
				pci:   f(fl, 1),
				earfcn: f(fl, 2),
				rsrp:  rsrp(f(fl, 3)),
				rsrq:  null,   // offset unverified
				sinr:  null,
			};
			continue;
		}

		m = match(l, /^\s*NR PCC:\s*(.*)$/);

		if (m) {
			let fl = split(m[1], ',');

			nr = {
				band:  band(f(fl, 8)),
				arfcn: f(fl, 2),
				pci:   null,   // slot differs from GTCCINFO's pci — unverified
				rsrp:  rsrp(f(fl, 3)),
				rsrq:  null,
				sinr:  null,
			};
			continue;
		}

		m = match(l, /^\s*LTE SCC[0-9]+:\s*(.*)$/);

		if (m) {
			let fl = split(m[1], ',');

			push(sccs, {
				band:  band(f(fl, 2)),
				pci:   f(fl, 3),
				earfcn: f(fl, 4),
				rsrp:  rsrp(f(fl, 5)),
			});
			continue;
		}

		// T700 "PCC: <band+100>,<pci>,<earfcn>,...,<rsrp dBm>" — the serving
		// LTE cell; rsrp is the signed LAST field, no +141 offset
		m = match(l, /^\s*PCC:\s*(.*)$/);

		if (m) {
			let fl = split(m[1], ',');
			let b0 = f(fl, 0);

			// the NR carrier row carries the NR band with a +5000 offset
			// (5041 = n41) and lands BEFORE the LTE row under EN-DC
			// (field-verified live: B3 anchor + n41) — slot 1 = PCI,
			// slot 2 = ARFCN, rsrp is the signed last field
			if (b0 != null && b0 >= 5000) {
				nr = {
					band:  b0 - 5000,
					pci:   f(fl, 1),
					arfcn: f(fl, 2),
					rsrp:  last_signed(fl),
					rsrq:  null,
					sinr:  null,
				};
				continue;
			}

			lte = {
				band:  band(f(fl, 0)),
				pci:   f(fl, 1),
				earfcn: f(fl, 2),
				rsrp:  last_signed(fl),
				rsrq:  null,
				sinr:  null,
			};
			continue;
		}

		// T700 "SCC <n>: 2,0,<band+100>,<pci>,<earfcn>,...,<rsrp dBm>"
		m = match(l, /^\s*SCC [0-9]+:\s*(.*)$/);

		if (m) {
			let fl = split(m[1], ',');

			push(sccs, {
				band:  band(f(fl, 2)),
				pci:   f(fl, 3),
				earfcn: f(fl, 4),
				rsrp:  last_signed(fl),
			});
		}
	}

	if (!lte && !nr)
		return null;

	return { lte: lte, nr: nr, sccs: sccs };
};

// AT+GTCCINFO? — the Fibocom serving-cell row (one row per RAT). Field offsets
// FIELD-VERIFIED on a real FM350-GL (2026-08-19/20, WH3000 Pro) and
// cross-checked against the FM190 captures + the 3ginfo-lite parser:
//   +GTCCINFO:
//   <id>,<rat>,<mcc>,<mnc>,<tac>,<cid>,<earfcn>,<pci>,<band+100>,<bw>,
//   <sinr*2>,<rsrp?>,<rsrp>,<rsrq>
//   rat 4=LTE, 9=NR. tac/cid are ALWAYS hex (both captures). earfcn/pci are
//   decimal on the T700 (38927 = B40, cross-checked against the band field)
//   but HEX on some FM190 firmwares (4FF) — a pure-digit token is decided by
//   the 3GPP band cross-check (decimal first, hex when that alone fits the
//   band). band carries the +100 offset (conditional, like GTCAINFO).
//   LTE scales (field-verified against the live CSQ/CESQ + GTCAINFO reads):
//     rsrp = v-141 (54 -> -87 dBm), rsrq = (v-34)/2-3, sinr = v/2 (dB).
//   NR scales (3ginfo-lite's field-derived 0e8d7127 table for exactly this
//   modem, cross-checked against SIMULTANEOUS GTCAINFO PCC reads on the live
//   T700, 2026-08-20 — the PCC row carries the signed rsrp dBm last):
//     rsrp = v/2-121 (68->-87, 70->-86, 71->-85.5 vs PCC -87/-86/-85; the
//     3ginfo v-157 alternative lands 1-2 dB off on the live samples),
//     sinr = v/2 (27-28 -> 13.5-14 dB; 3ginfo's (v-45)/2-1 goes negative
//     on this firmware),
//     rsrq = (v-87)/2 (64-65 -> -11.5/-11.0 — the 3ginfo FM350 formula).
//   bw: v/5 MHz for BOTH rats (the 3ginfo convert_bw table: 75 -> 15 MHz B3,
//   100 -> 20 MHz B40, 300 -> 60 MHz n41).
export function parse_gtccinfo(lines)
{
	let lte = null, nr = null;

	// token with A-F -> hex, else decimal; empty -> null
	let num = (s) => match(trim(s ?? ''), /[A-Fa-f]/) ? hxtok(s) : numtok(s);

	// 255 is the "no measurement" sentinel and empty slots appear during a
	// cell change (partial row) — both must stay null: +'' would read 0
	// and hex('0x') would read 0, latching zeros into the serving cell
	let hx = hxtok;
	let dec = numtok;
	let band = band_of;
	let rsrp = rsrp_of;
	let rsrq = (v) => (v != null && v != 255) ? (v - 34) / 2.0 - 3 : null;
	let sinr = (v) => (v != null && v != 255) ? v / 2.0 : null;
	let rsrp_nr = (v) => (v != null && v != 255) ? v / 2.0 - 121 : null;
	let rsrq_nr = (v) => (v != null && v != 255) ? (v - 87) / 2.0 : null;
	let bw_mhz = (v) => (v != null && v != 255 && v > 0) ? v / 5.0 : null;

	// ambiguous pure-digit token (T700 decimal vs FM190 hex): decimal first,
	// but take hex when only that reading lands in the reported band. Empty
	// slots (partial row during a cell change) stay null — never 0.
	let dec_or_hex = (s, want_band) => {
		if (!length(trim(s ?? '')))
			return null;

		let d = +s;
		// lte_band returns band names as strings ('B40') — compare numerically
		let fits = (x) => {
			let b = arfcn_bands.lte_band(x)?.band;

			return (b != null) ? (+substr(b, 1) == want_band) : false;
		};

		if (want_band == null || fits(d))
			return d;

		let h = hex('0x' + s);

		return fits(h) ? h : d;
	};

	// identity fields: the LONG all-F token (FFFFFFF / 00FFFFFFF) is the
	// modem's "no identity" placeholder on the NR row — surface it as null,
	// never as a huge bogus tac/cid. Short all-F values are legitimate
	// (TAC 0xFF, ECI 0xFFFFFF) and parse normally.
	let hxid = (s) => {
		let t = trim(s ?? '');

		return (length(t) >= 7 && match(t, /^0*F+$/)) ? null : hx(s);
	};

	for (let l in (lines ?? [])) {
		let m = match(l, /^\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]*)\s*,\s*([0-9]*)\s*,\s*([0-9A-Fa-f]*)\s*,\s*([0-9A-Fa-f]*)\s*,\s*([0-9A-Fa-f]*)\s*,\s*([0-9A-Fa-f]*)\s*,\s*([0-9A-Fa-f]*)\s*,\s*([0-9A-Fa-f]*)\s*,\s*([0-9A-Fa-f]*)\s*,\s*([0-9A-Fa-f]*)\s*,\s*([0-9A-Fa-f]*)\s*,\s*([0-9A-Fa-f]*)/);

		if (!m)
			continue;

		let rat = +m[2];

		// an LTE row must carry mcc/mnc — empty identity is a partial/corrupt
		// read (keep the last-known cell). The T700's NR row legitimately
		// carries them EMPTY (identity lives on the LTE row — field-verified:
		// 1,9,,,FFFFFFF,00FFFFFFF,<arfcn>,<pci>,<band>...)
		if (rat != 9 && !length(trim(m[3] ?? '')))
			continue;

		if (rat == 9) {
			let nb = num(m[9]);

			nr = {
				mcc: dec(m[3]), mnc: dec(m[4]),
				tac: hxid(m[5]), cid: hxid(m[6]),
				arfcn: num(m[7]), pci: num(m[8]),
				// the +5000 band offset holds for NR (5078 = n78 FM190,
				// 5041 = n41 T700); the trailing metrics carry NR scales
				// (cross-validated against simultaneous GTCAINFO reads —
				// see the header comment)
				band:  (nb != null && nb >= 5000) ? nb - 5000 : null,
				rsrp: rsrp_nr(num(m[13])), rsrq: rsrq_nr(num(m[14])),
				sinr: sinr(num(m[11])),
				bw_mhz: bw_mhz(num(m[10])),
			};
		}
		else {
			let b = band(num(m[9]));
			let earfcn = null;
			let pci = null;

			if (length(trim(m[7] ?? ''))) {
				earfcn = (match(m[7], /[A-Fa-f]/) != null)
					? hx(m[7]) : dec_or_hex(m[7], b);

				if (length(trim(m[8] ?? ''))) {
					// pci reads on the same base the earfcn decision picked
					pci = (match(m[8], /[A-Fa-f]/) != null)
						? hx(m[8]) : ((earfcn == +m[7]) ? +m[8] : hx(m[8]));
				}
			}

			lte = {
				mcc: dec(m[3]), mnc: dec(m[4]),
				tac: hxid(m[5]), cid: hxid(m[6]),
				earfcn: earfcn, pci: pci,
				band: b,
				rsrp: rsrp(num(m[13])), rsrq: rsrq(num(m[14])),
				sinr: sinr(num(m[11])),
				bw_mhz: bw_mhz(num(m[10])),
			};
		}
	}

	return (lte || nr) ? { lte: lte, nr: nr } : null;
};

// GTCAINFO yields no per-RAT rsrq/sinr and no neighbours: only the serving
// cells (LTE anchor + NR carrier under EN-DC) and the LTE aggregation SCCs
// make it into the standard cells shape.
function tel_fibocom_signal(self, cb)
{
	csq_first(self, cb);
};

// the carrier/CA table for the fibocom telemetry: the EN-DC primary carriers
// (the GTCAINFO PCC rows — LTE anchor + NR carrier; GTCCINFO enriches them
// with rsrq/sinr via the serving rows) plus any LTE SCC aggregation rows.
// 0.1 dB scaling matches the QMI CA entries so the LuCI table renders both
// backends identically. Exported for the unit tests.
export function ca_entries(serving, sccs)
{
	let ca = [];

	if (serving?.lte)
		push(ca, {
			role: 'PCC LTE',
			earfcn: serving.lte.earfcn,
			rb: null,
			bandwidth_mhz: serving.lte.bw_mhz ?? null,
			band: serving.lte.band,
			pci: serving.lte.pci,
			rsrp: (serving.lte.rsrp != null) ? serving.lte.rsrp * 10 : null,
			rsrq: (serving.lte.rsrq != null) ? serving.lte.rsrq * 10 : null,
		});

	if (serving?.nr)
		push(ca, {
			role: 'PCC NR',
			earfcn: serving.nr.arfcn,
			rb: null,
			bandwidth_mhz: serving.nr.bw_mhz ?? null,
			band: serving.nr.band,
			pci: serving.nr.pci,
			rsrp: (serving.nr.rsrp != null) ? serving.nr.rsrp * 10 : null,
			rsrq: (serving.nr.rsrq != null) ? serving.nr.rsrq * 10 : null,
		});

	for (let s in (sccs ?? []))
		push(ca, {
			role: 'SCC',
			earfcn: s.earfcn,
			rb: null,
			bandwidth_mhz: null,
			band: s.band,
			pci: s.pci,
			rsrp: (s.rsrp != null) ? s.rsrp * 10 : null,
		});

	return ca;
};

function tel_fibocom_cells(self, cb)
{
	// shared assembly: fill the standard cells shape from a parsed serving
	// descriptor (GTCAINFO or GTCCINFO), keep any GTCAINFO SCC aggregation
	// rows; the serving-row builders (mk_lte/mk_nr) are module-level

	let apply_serving = (serving, sccs) => {
		// the fibocom signal block has no source of its own beyond the CSQ
		// rssi floor — refresh signal.{lte,nr5g} from the serving cells on
		// every tick (the shared fill keeps first-fill values otherwise)
		assemble_cells(self, serving, { intra: [], inter: [] }, null, true);

		if (!self.cells)
			return;

		let ca = ca_entries(serving, sccs);

		if (length(ca))
			self.cells.ca = ca;
	};

	// best of both read-backs: GTCCINFO enriches a GTCAINFO serving cell with
	// the identity (mcc/mnc/tac/cid) and rsrq/sinr/bw the PCC row lacks; it
	// also covers the moment right after a cell change where GTCAINFO is
	// empty. The two reads are sequential (~1 s apart): a handover between
	// them would put TWO DIFFERENT CELLS on the wire — the enrichment is
	// therefore paired per RAT on pci+band (null on either side = unknown,
	// not a mismatch) and a non-matching GTCCINFO row is dropped whole
	// (identity included: never glue the old cell's tac/cid onto the new
	// one). GTCAINFO stays authoritative — it is the fresher read and the
	// only source of the signed rsrp.
	let enrich_and_apply = (serving, sccs) => {
		if (!serving)
			return cb();

		modem_common.telemetry_at(self).send('AT+GTCCINFO?', (e3, r3) => {
			let c = e3 ? null : parse_gtccinfo(r3?.lines);

			// a partial row (cell change) must not overwrite/zero-fill the
			// serving identity — only enrich with plausible values
			let fill = (dst, v) => (v != null && v != 0) ? v : dst;

			let same_cell = (a, b) => {
				if (!a || !b)
					return false;

				for (let k in [ 'pci', 'band' ])
					if (a[k] != null && b[k] != null && a[k] != b[k])
						return false;

				return true;
			};

			if (same_cell(serving.lte, c?.lte)) {
				serving.lte.mcc = fill(serving.lte.mcc, c.lte.mcc);
				serving.lte.mnc = fill(serving.lte.mnc, c.lte.mnc);
				serving.lte.cid = fill(serving.lte.cid, c.lte.cid);
				serving.lte.tac = fill(serving.lte.tac, c.lte.tac);
				serving.lte.band = fill(serving.lte.band, c.lte.band);
				serving.lte.rsrq = fill(serving.lte.rsrq, c.lte.rsrq);
				serving.lte.sinr = fill(serving.lte.sinr, c.lte.sinr);
				serving.lte.bw_mhz = fill(serving.lte.bw_mhz, c.lte.bw_mhz);
			}

			// the NR PCC row lacks rsrq/sinr/bw — the GTCCINFO NR row
			// carries them (NR scales, see parse_gtccinfo). The signed
			// GTCAINFO rsrp stays untouched (it is the authoritative,
			// directly-reported value; the derived one only feeds the
			// GTCCINFO-only create path below).
			if (same_cell(serving.nr, c?.nr)) {
				serving.nr.band = fill(serving.nr.band, c.nr.band);
				serving.nr.rsrq = fill(serving.nr.rsrq, c.nr.rsrq);
				serving.nr.sinr = fill(serving.nr.sinr, c.nr.sinr);
				serving.nr.bw_mhz = fill(serving.nr.bw_mhz, c.nr.bw_mhz);
			}

			if (c?.nr && !serving?.nr)
				serving.nr = {
					arfcn: c.nr.arfcn, pci: c.nr.pci,
					mcc: c.nr.mcc, mnc: c.nr.mnc, cid: c.nr.cid, tac: c.nr.tac,
					band: c.nr.band, rsrp: c.nr.rsrp, rsrq: c.nr.rsrq,
					sinr: c.nr.sinr, bw_mhz: c.nr.bw_mhz,
				};

			apply_serving(serving, sccs);
			cb();
		});
	};

	modem_common.telemetry_at(self).send('AT+GTCAINFO?', (err, res) => {
		let g = err ? null : parse_gtcainfo(res?.lines);

		if (g) {
			let serving = {};

			if (g.lte)
				serving.lte = mk_lte(g.lte);

			if (g.nr)
				serving.nr = mk_nr(g.nr);

			return enrich_and_apply(serving, g.sccs);
		}

		// T700 firmwares answer GTCAINFO? with an empty body — GTCCINFO? is
		// their serving-cell row (field-verified on a real FM350-GL)
		modem_common.telemetry_at(self).send('AT+GTCCINFO?', (e2, r2) => {
			let c = e2 ? null : parse_gtccinfo(r2?.lines);

			if (!c)
				return cb();

			let serving = {};

			if (c.lte)
				serving.lte = mk_lte(c.lte);

			if (c.nr)
				serving.nr = mk_nr(c.nr);

			// the serving descriptor is already complete (parsed from this same
			// read) — apply directly instead of the GTCAINFO-path enrichment
			// re-query, which would just re-ask GTCCINFO? for identical values
			apply_serving(serving, []);
			cb();
		});
	});
};

const TELEMETRY_FIBOCOM = {
	signal: tel_fibocom_signal, cells: tel_fibocom_cells,
	ca: tel_noop, reg_detail: tel_ceer_reg_detail,
	// HW-validated on a WH3000 Pro + FM350-GL (GTCAINFO PCC/SCC +
	// GTCCINFO enrichment, field offsets cross-checked live)
};

const TELEMETRY_GENERIC = {
	signal: tel_generic_signal, cells: tel_noop,
	ca: tel_noop, reg_detail: tel_ceer_reg_detail,
};

// exported vendor tables (wired onto VENDORS in modem_ncm.uc)
export const QUECTEL = TELEMETRY_QUECTEL;
export const HUAWEI  = TELEMETRY_HUAWEI;
export const MEIG    = TELEMETRY_MEIG;
export const FIBOCOM = TELEMETRY_FIBOCOM;
export const GENERIC = TELEMETRY_GENERIC;
