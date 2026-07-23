// wwand — native-MBIM protocol backend.
//
// The MBIM implementations of the protocol-neutral telemetry operations, the
// MBIM sibling of qmi_backend.uc. Each op takes the MBIM session client `mc`
// (mbim_client.uc — `mc.command(schema, name, kind, args, cb, opts)`) plus a
// callback, and returns data already normalized into the SAME shapes the QMI
// backend / NAS schema produce (modem `self.signal` and `self.cells`), so the
// daemon's modem_signal / modem_cells surface either backend unchanged. An op
// never touches modem `self` state.
//
// Signal metrics come in two MBIM flavors, mirrored to the two QMI unit
// conventions the daemon already renders:
//   - self.signal  (QMI GET_SIGNAL_INFO): RSRP/RSSI in whole dBm, SNR in 0.1 dB.
//     MBIM v2 Signal State reports CODED indices -> converted here.
//   - self.cells   (QMI GET_CELL_LOCATION_INFO): every metric in 0.1 dB units.
//     MBIM Base Stations Info reports actual dBm/dB (signed) -> scaled x10 here.
//
// There is no native MBIM carrier-aggregation CID, so there is no get_ca here —
// CA stays passthrough/AT in the core.

'use strict';

import * as bc from './codec/mbim-schema/basic_connect.uc';
import * as ext from './codec/mbim-schema/ms_basic_connect_ext.uc';

// how many neighbour cells to ask the modem for (BASE_STATIONS_INFO caps)
const MAX_CELLS = 16;

// MBIM coded-value conversions (MS-MBIM signal coding):
//   RSSI  index 0..31 -> dBm = -113 + 2*index   (99 = unknown)
//   RSRP  index 0..126 -> dBm = index - 156      (0xFFFFFFFF = unknown)
//   SNR   index 0..127 -> dB  = index/2 - 23     (0xFFFFFFFF = unknown)
const UNKNOWN_U32 = 0xFFFFFFFF;

function rssi_dbm(idx)
{
	return (idx != null && idx != bc.RSSI_UNKNOWN) ? (-113 + 2 * idx) : null;
}

function rsrp_dbm(coded)
{
	return (coded != null && coded != UNKNOWN_U32) ? (coded - 156) : null;
}

// SNR in 0.1 dB units to match QMI self.signal snr (rendered /10 by the daemon)
function snr_tenths(coded)
{
	return (coded != null && coded != UNKNOWN_U32) ? (coded * 5 - 230) : null;
}

// "26201" / "262001" -> "262/01" (matching the QMI 'plmn' decode: "mcc/mnc")
function plmn_str(provider_id)
{
	if (!provider_id || length(provider_id) < 4)
		return null;

	return sprintf('%s/%s', substr(provider_id, 0, 3), substr(provider_id, 3));
}

// get_signal(mc, cb): per-RAT signal from the MBIMEx v2 Signal State, normalized
// to the QMI self.signal shape { lte:{rssi,rsrq,rsrp,snr}, nr5g:{rsrp,snr} }, or
// cb(null). MBIM v2 Signal State has no per-RAT RSRQ, so lte.rsrq is null.
export function get_signal(mc, cb)
{
	mc.command(bc, 'SIGNAL_STATE_V2', 'query', {}, (err, data) => {
		if (err || !data)
			return cb(null);

		let out = {};
		let rssi = rssi_dbm(data.rssi);

		for (let e in (data.rsrp_snr ?? [])) {
			let st = +(e.system_type ?? 0);
			let rsrp = rsrp_dbm(e.rsrp);
			let snr = snr_tenths(e.snr);

			if (st & ext.DATA_CLASS_LTE)
				out.lte = { rssi: rssi, rsrq: null, rsrp: rsrp, snr: snr };

			if (st & (ext.DATA_CLASS_5G_NSA | ext.DATA_CLASS_5G_SA))
				out.nr5g = { rsrp: rsrp, snr: snr };
		}

		// RSSI present but no LTE RsrpSnr entry — still surface the RSSI
		if (!out.lte && rssi != null)
			out.lte = { rssi: rssi, rsrq: null, rsrp: null, snr: null };

		return cb(length(out) ? out : null);
	});
}

// map one MBIM LTE cell (serving or neighbour, metrics in actual dBm/dB) into a
// QMI lte_intra.cells[] entry (metrics in 0.1 dB units; rssi/srxlev unavailable)
function lte_cell(c)
{
	return {
		pci:    c.pci,
		rsrq:   (c.rsrq != null) ? c.rsrq * 10 : null,
		rsrp:   (c.rsrp != null) ? c.rsrp * 10 : null,
		rssi:   null,
		srxlev: null,
	};
}

// get_cells(mc, cb): serving + neighbour cell info from Base Stations Info,
// normalized to the QMI self.cells shape (lte_intra + nr5g_cell/nr5g_arfcn), or
// cb(null) when the modem reports neither an LTE nor an NR serving cell.
export function get_cells(mc, cb)
{
	mc.command(ext, 'BASE_STATIONS_INFO', 'query', {
		max_gsm_count: 0, max_umts_count: 0, max_tdscdma_count: 0,
		max_lte_count: MAX_CELLS, max_cdma_count: 0, max_nr_count: MAX_CELLS,
	}, (err, data) => {
		if (err || !data)
			return cb(null);

		let cells = {};
		let lte = data.lte_serving;

		if (lte) {
			let list = [ lte_cell(lte) ];

			for (let n in (data.lte_neighbors ?? []))
				push(list, lte_cell(n));

			cells.lte_intra = {
				plmn:            plmn_str(lte.provider_id),
				tac:             lte.tac,
				global_cell_id:  lte.cell_id,
				earfcn:          lte.earfcn,
				serving_cell_id: lte.pci,
				cells:           list,
			};
		}

		let nr = (data.nr_serving ?? [])[0];

		if (nr) {
			cells.nr5g_arfcn = nr.nrarfcn;
			cells.nr5g_cell = {
				plmn:           plmn_str(nr.provider_id),
				tac:            nr.tac,
				global_cell_id: nr.nci,
				pci:            nr.pci,
				rsrq:           (nr.rsrq != null) ? nr.rsrq * 10 : null,
				rsrp:           (nr.rsrp != null) ? nr.rsrp * 10 : null,
				snr:            (nr.sinr != null) ? nr.sinr * 10 : null,
			};
		}

		return cb(length(cells) ? cells : null);
	});
}

// get_data_mode(mc, cb): data-system mode { mode, lte, nr } (mode LTE/NSA/SA) —
// the MBIM analogue of qmi_backend.get_data_mode. Derived from the register
// state's available data classes (MbimDataClass bitmask: LTE / 5G-NSA / 5G-SA).
// REGISTRATION_PARAMETERS carries no data-class field, so the register state's
// class mask is the native-MBIM source. cb(null) on error / no data.
export function get_data_mode(mc, cb)
{
	mc.command(bc, 'REGISTER_STATE', 'query', {}, (err, data) => {
		if (err || data?.available_data_classes == null)
			return cb(null);

		let dc = data.available_data_classes;
		let lte = (dc & ext.DATA_CLASS_LTE) != 0;
		let nr = (dc & (ext.DATA_CLASS_5G_NSA | ext.DATA_CLASS_5G_SA)) != 0;
		let mode = nr ? (lte ? 'NSA' : 'SA') : (lte ? 'LTE' : null);

		cb({ mode: mode, lte: lte, nr: nr });
	});
}

// get_reg_detail(mc, cb): why (not) registered, from the register state —
// { source:'mbim', limited?, reject_cause? } or cb(null) on error. nw_error is
// the 3GPP TS 24.008 reject cause (the clear-text mapping is the core's job);
// a denied registration is flagged as limited service.
export function get_reg_detail(mc, cb)
{
	mc.command(bc, 'REGISTER_STATE', 'query', {}, (err, data) => {
		if (err || !data)
			return cb(null);

		let d = { source: 'mbim' };

		if (data.nw_error != null && data.nw_error != 0)
			d.reject_cause = data.nw_error;

		d.limited = (data.register_state == bc.REGISTER_STATE_DENIED);

		cb(d);
	}, { no_recovery: true });
}
