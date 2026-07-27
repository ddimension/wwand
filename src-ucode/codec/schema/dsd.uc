// wwand — QMI DSD (Data System Determination) service schema (service 0x2A).
// Reports which radio access technologies currently provide data service —
// the clean way to tell LTE-only from 5G NSA (LTE+NR) from 5G SA.
// TLV layout verified against libqmi data/qmi-service-dsd.json.

'use strict';

// QmiDsdRadioAccessTechnology (the RAT field of each available system)
export const RAT_UNKNOWN = 0;
export const RAT_WCDMA   = 1;
export const RAT_GERAN   = 2;
export const RAT_LTE     = 3;
export const RAT_TDSCDMA = 4;
export const RAT_WLAN    = 5;
export const RAT_5G      = 6;

// list of systems currently available for data service (shared by the polled
// GET_SYSTEM_STATUS response and the unsolicited SYSTEM_STATUS_IND)
const AVAILABLE_SYSTEMS_F = { t: 0x10, f: { n: 'u8', of: {
	technology: 'u32',
	rat:        'u32',
	so_mask:    'u64',
} } };

export default {
	service: 0x2A,
	messages: {
		GET_SYSTEM_STATUS: {
			id: 0x0024,
			req: {},
			resp: { available_systems: AVAILABLE_SYSTEMS_F },
		},

		// register for / unregister from the unsolicited data-system change
		// indication (live LTE ↔ 5G-NSA ↔ 5G-SA transitions without polling)
		SYSTEM_STATUS_CHANGE: {
			id: 0x0025,
			req:  { register: { t: 0x11, f: 'u8' } },
			resp: {},
		},

		SYSTEM_STATUS_IND: {
			id: 0x0026,
			ind: { available_systems: AVAILABLE_SYSTEMS_F },
		},
	},
};
