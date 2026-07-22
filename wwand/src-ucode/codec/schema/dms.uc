// wwand — QMI DMS service message schema (service 0x02).
//
// Operating modes (SET/GET_OPERATING_MODE): 0 online, 1 low_power, 2 factory
// test, 3 offline, 4 reset, 5 shutting_down, 6 persistent_low_power.
//
// PIN status (legacy DMS UIM): 0 not initialized, 1 enabled/not verified,
// 2 enabled/verified, 3 disabled, 4 blocked, 5 permanently blocked.

'use strict';

export const OPMODE_ONLINE = 0;
export const OPMODE_LOW_POWER = 1;
export const OPMODE_OFFLINE = 3;
export const OPMODE_RESET = 4;

export default {
	service: 0x02,
	messages: {
		GET_MANUFACTURER: {
			id: 0x0021,
			req:  {},
			resp: { manufacturer: { t: 0x01, f: 'string' } },
		},

		GET_MSISDN: {
			id: 0x0024,
			req:  {},
			resp: {
				msisdn: { t: 0x01, f: 'string' },
			},
		},

		GET_CAPABILITIES: {
			id: 0x0020,
			req:  {},
			resp: {
				capabilities: { t: 0x01, f: {
					max_tx_rate:      'u32',
					max_rx_rate:      'u32',
					data_service_cap: 'u8',
					sim_cap:          'u8',
					radio_ifs:        { n: 'u8', of: 'u8' },
				} },
			},
		},

		GET_MODEL: {
			id: 0x0022,
			req:  {},
			resp: { model: { t: 0x01, f: 'string' } },
		},

		GET_REVISION: {
			id: 0x0023,
			req:  {},
			resp: { revision: { t: 0x01, f: 'string' } },
		},

		GET_IDS: {
			id: 0x0025,
			req:  {},
			resp: {
				esn:  { t: 0x10, f: 'string' },
				imei: { t: 0x11, f: 'string' },
				meid: { t: 0x12, f: 'string' },
			},
		},

		VERIFY_PIN: {
			// legacy DMS PIN path, kept for modems without UIM service
			id: 0x0028,
			req:  { info: { t: 0x01, f: { pin_id: 'u8', pin: 'lstring' } } },
			resp: { retries: { t: 0x10, f: { verify: 'u8', unblock: 'u8' } } },
		},

		// enable/disable the PIN1 query (SIM PIN lock); DMS fallback for modems
		// without UIM. enabled=1 requires the PIN at power-on. libqmi 1.38 0x0027.
		SET_PIN_PROTECTION: {
			id: 0x0027,
			req:  { info: { t: 0x01, f: { pin_id: 'u8', enabled: 'u8', pin: 'lstring' } } },
			resp: { retries: { t: 0x10, f: { verify: 'u8', unblock: 'u8' } } },
		},

		GET_PIN_STATUS: {
			id: 0x002B,
			req:  {},
			resp: {
				pin1: { t: 0x11, f: { status: 'u8', verify_retries: 'u8', unblock_retries: 'u8' } },
				pin2: { t: 0x12, f: { status: 'u8', verify_retries: 'u8', unblock_retries: 'u8' } },
			},
		},

		GET_OPERATING_MODE: {
			id: 0x002D,
			req:  {},
			resp: {
				mode:            { t: 0x01, f: 'u8' },
				offline_reason:  { t: 0x10, f: 'u16' },
				hw_restricted:   { t: 0x11, f: 'u8' },
			},
		},

		SET_OPERATING_MODE: {
			id: 0x002E,
			req:  { mode: { t: 0x01, f: 'u8' } },
			resp: {},
		},

		GET_ICCID: {
			// legacy DMS path
			id: 0x003C,
			req:  {},
			resp: { iccid: { t: 0x01, f: 'string' } },
		},

		GET_IMSI: {
			// legacy DMS path
			id: 0x0043,
			req:  {},
			resp: { imsi: { t: 0x01, f: 'string' } },
		},
	},
};
