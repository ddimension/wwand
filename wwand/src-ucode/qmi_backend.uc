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

import * as dsdmod from './codec/schema/dsd.uc';

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
