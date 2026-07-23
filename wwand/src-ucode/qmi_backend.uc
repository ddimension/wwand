// wwand — QMI protocol backend.
//
// The QMI implementations of the protocol-neutral modem/context operations
// defined in docs/backend-interface.md. The state-machine core (modem.uc /
// context.uc) delegates the wire work here so the QMI specifics — service ids,
// CID management, TLV shapes, error codes, codec/schema imports — stay out of
// the lifecycle/policy logic. Each op takes the QMI client(s) it needs plus a
// callback and returns normalized data; it never touches modem `self` state.
//
// Extracted incrementally from modem.uc/context.uc (see the migration plan in
// docs/backend-interface.md). This is one of the two backends behind the same
// operation surface; MBIM is the other.

'use strict';

import * as dmsmod from './codec/schema/dms.uc';
import * as dsdmod from './codec/schema/dsd.uc';
import * as nasmod from './codec/schema/nas.uc';

const OPMODE = {
	online:    dmsmod.OPMODE_ONLINE,
	low_power: dmsmod.OPMODE_LOW_POWER,
	offline:   dmsmod.OPMODE_OFFLINE,
	reset:     dmsmod.OPMODE_RESET,
};

// set_opmode(dms, mode, cb): mode is 'online'|'low_power'|'offline'|'reset'.
// QMI error 26 ("no effect" — already in that mode) is normalized to success.
export function set_opmode(dms, mode, cb)
{
	dms.request('SET_OPERATING_MODE', { mode: OPMODE[mode] }, (err) => {
		if (err && err.error == 'qmi' && err.code == 26)
			err = null;

		if (cb)
			cb(err);
	});
}

// QmiNasDLBandwidth enum -> MHz (LTE carrier bandwidth)
const CA_BW_MHZ = { '0': 1.4, '1': 3, '2': 5, '3': 10, '4': 15, '5': 20 };

// get_ca(nas, cb): active LTE carrier aggregation, normalized to
// [ { role, earfcn, pci, bandwidth_mhz, state? }, ... ], or null when the modem
// reports no CA data. Band/frequency are derived from earfcn in the UI.
// QmiNasScellState: 0 deconfigured, 1 deactivated, 2 activated.
export function get_ca(nas, cb)
{
	nas.request('GET_LTE_CPHY_CA_INFO', {}, (e, d) => {
		if (e || (!d?.pcell && !d?.scells))
			return cb(null);

		let out = [];

		if (d.pcell)
			push(out, { role: 'PCC', earfcn: d.pcell.earfcn, pci: d.pcell.pci,
			            bandwidth_mhz: CA_BW_MHZ[sprintf('%d', d.pcell.dl_bandwidth)] ?? null });

		for (let s in (d.scells ?? []))
			push(out, { role: 'SCC', earfcn: s.earfcn, pci: s.pci,
			            bandwidth_mhz: CA_BW_MHZ[sprintf('%d', s.dl_bandwidth)] ?? null,
			            state: s.state });

		cb(out);
	});
}

// get_data_mode(dsd, cb): data-system mode from the DSD service — { mode, lte,
// nr } with mode LTE / NSA / SA — or null when unavailable. 5G present with LTE
// = NSA (NR anchored on LTE); 5G alone = SA; LTE alone = LTE.
export function get_data_mode(dsd, cb)
{
	dsd.request('GET_SYSTEM_STATUS', {}, (e, d) => {
		if (e || d?.available_systems == null)
			return cb(null);

		let rats = {};

		for (let s in d.available_systems)
			if (s.rat == dsdmod.RAT_LTE) rats.lte = true;
			else if (s.rat == dsdmod.RAT_5G) rats.nr = true;

		let mode = rats.nr ? (rats.lte ? 'NSA' : 'SA') : (rats.lte ? 'LTE' : null);

		cb({ mode: mode, lte: !!rats.lte, nr: !!rats.nr });
	});
}

// get_reg_detail(nas, cb): why (not) registered, from QMI GET_SYSTEM_INFO —
// { source:'qmi', limited?, reject_cause?, reject_domain? } or null on error.
// The clear-text mapping + the AT+CEER top-up are the core's job (protocol-
// neutral). no_recovery: an unsupported message must not climb the reboot ladder.
export function get_reg_detail(nas, cb)
{
	nas.request('GET_SYSTEM_INFO', {}, (err, data) => {
		if (err)
			return cb(null);

		let d = { source: 'qmi' };
		let ss = data.lte_service_status?.status;

		if (ss != null)
			d.limited = (ss == nasmod.SVC_STATUS_LIMITED ||
			             ss == nasmod.SVC_STATUS_LIMITED_REGIONAL);

		let ri = data.lte_sys_info;

		if (ri?.reject_valid && ri.reject_cause) {
			d.reject_cause = ri.reject_cause;
			d.reject_domain = ri.reject_domain;
		}

		cb(d);
	}, { no_recovery: true });
}

// --- context (WDS) operations ------------------------------------------------

const RAT_LTE = (1 << 5), RAT_5GNR = (1 << 10);
const STATS_MASK = 0x3FF;

// get_channel_rates(wds, cb): current + max tx/rx link rate (bits/sec) or null.
export function get_channel_rates(wds, cb)
{
	wds.request('GET_CHANNEL_RATES', {}, (err, data) => cb((!err && data?.rates) ? data.rates : null));
}

// get_bearer(wds, cb): the RAT actually carrying this session's data, as a
// label ('LTE' / '5G NR' / 'LTE + 5G' / 'other') or null.
export function get_bearer(wds, cb)
{
	wds.request('GET_CURRENT_DATA_BEARER_TECHNOLOGY', {}, (err, data) => {
		let m = (!err) ? data?.current?.rat_mask : null;

		if (m == null)
			return cb(null);

		let lte = (m & RAT_LTE) != 0, nr = (m & RAT_5GNR) != 0;
		cb(nr ? (lte ? 'LTE + 5G' : '5G NR') : (lte ? 'LTE' : (m ? 'other' : null)));
	});
}

// get_packet_stats(wds, cb): raw per-call packet counters, or null when the
// modem didn't answer (the caller aggregates across families + masks sentinels).
export function get_packet_stats(wds, cb)
{
	wds.request('GET_PACKET_STATISTICS', { mask: STATS_MASK }, (err, data) =>
		cb((err || data?.rx_packets_ok == null) ? null : data));
}

// read_info(dms, cb): identity + capabilities.
// cb(info) with { manufacturer?, model?, revision?, imei?, meid?, capabilities? }
// (fields the modem didn't answer are simply absent).
export function read_info(dms, cb)
{
	let info = {};

	dms.request('GET_MANUFACTURER', {}, (e0, d0) => {
		if (!e0)
			info.manufacturer = d0.manufacturer;

		dms.request('GET_MODEL', {}, (e1, d1) => {
			if (!e1)
				info.model = d1.model;

			dms.request('GET_REVISION', {}, (e2, d2) => {
				if (!e2)
					info.revision = d2.revision;

				dms.request('GET_IDS', {}, (e3, d3) => {
					if (!e3) {
						info.imei = d3.imei;
						info.meid = d3.meid;
					}

					dms.request('GET_CAPABILITIES', {}, (e4, d4) => {
						if (!e4 && d4.capabilities)
							info.capabilities = d4.capabilities;

						cb(info);
					});
				});
			});
		});
	});
}
