// wwand — QMI DMS service message schema (service 0x02).
//
// Operating modes (SET_OPERATING_MODE): 0 online, 1 low_power, 2 factory
// test, 3 offline, 4 reset, 5 shutting_down, 6 persistent_low_power.
//
// PIN status (legacy DMS UIM): 0 not initialized, 1 enabled/not verified,
// 2 enabled/verified, 3 disabled, 4 blocked, 5 permanently blocked.

'use strict';

export const OPMODE_ONLINE = 0;
export const OPMODE_LOW_POWER = 1;
export const OPMODE_OFFLINE = 3;
export const OPMODE_RESET = 4;
export const OPMODE_PERSISTENT_LOW_POWER = 6;
export const OPMODE_MODE_ONLY_LOW_POWER = 7;

// human-readable operating-mode names (for the DMS event-report log). Keys are
// strings; look up via sprintf('%d', mode).
export const OPMODE_NAMES = {
	'0': 'online', '1': 'low power', '2': 'factory test', '3': 'offline',
	'4': 'resetting', '5': 'shutting down', '6': 'persistent low power',
	'7': 'mode-only low power', '8': 'network test',
};

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

		SET_OPERATING_MODE: {
			id: 0x002E,
			req:  { mode: { t: 0x01, f: 'u8' } },
			resp: {},
		},

		// verified vs libqmi qmi-service-dms.json msg 0x002D: Mode 0x01 u8,
		// Offline Reason 0x10 u16 (only when offline), Hardware Restricted
		// Mode 0x11 u8. Used to detect an FCC-RF-locked modem that stays in
		// (persistent) low power after a set-online.
		GET_OPERATING_MODE: {
			id: 0x002D,
			req:  {},
			resp: { mode: { t: 0x01, f: 'u8' }, offline_reason: { t: 0x10, f: 'u16' },
			        hw_restricted: { t: 0x11, f: 'u8' } },
		},

		// FCC authentication (RF unlock for laptop-SKU modems). Verified vs
		// libqmi qmi-service-dms.json:
		//   Set FCC Authentication 0x555F — no input (Quectel EM05/EM120/EM160
		//   in Lenovo SKUs).
		//   Foxconn Set FCC Authentication 0x5571 — Value 0x01 u8 (Foxconn
		//   SDX55 T99W175 / Dell DW5821e-class, magic usually 0).
		//   Foxconn Set FCC Authentication v2 (same id 0x5571) — Magic String
		//   0x01 + Magic Number 0x02 u8 (T99W373-class SDX62).
		// Same-id entries are fine: requests encode by NAME and responses are
		// matched to the pending transaction, not decoded by id lookup.
		SET_FCC_AUTHENTICATION: {
			id: 0x555F,
			req:  {},
			resp: {},
		},

		FOXCONN_SET_FCC_AUTHENTICATION: {
			id: 0x5571,
			req:  { value: { t: 0x01, f: 'u8' } },
			resp: {},
		},

		FOXCONN_SET_FCC_AUTHENTICATION_V2: {
			id: 0x5571,
			req:  { magic_string: { t: 0x01, f: 'string' },
			        magic_number: { t: 0x02, f: 'u8' } },
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

		// DMS event report — notices an EXTERNAL change to the modem's operating
		// mode (someone toggled airplane mode / RF off via AT, another tool, or a
		// front-panel switch) or PIN state, without wwand having initiated it.
		// Verified vs libqmi qmi-service-dms.json msg 0x0001:
		//   Set Event Report input  PIN State Reporting 0x12, Operating Mode
		//                           Reporting 0x14, UIM State Reporting 0x15 (u8).
		//   Event Report indication PIN1 Status 0x11 / PIN2 Status 0x12 sequence
		//                           { current_status u8, verify_retries u8,
		//                             unblock_retries u8 }; Operating Mode 0x14 u8;
		//                           UIM State 0x15 u8.
		SET_EVENT_REPORT: {
			id: 0x0001,
			req: {
				pin_state:      { t: 0x12, f: 'u8' },
				operating_mode: { t: 0x14, f: 'u8' },
				uim_state:      { t: 0x15, f: 'u8' },
			},
			resp: {},
		},

		EVENT_REPORT_IND: {
			id: 0x0001,
			ind: {
				pin1_status: { t: 0x11, f: {
					current_status: 'u8', verify_retries: 'u8', unblock_retries: 'u8' } },
				pin2_status: { t: 0x12, f: {
					current_status: 'u8', verify_retries: 'u8', unblock_retries: 'u8' } },
				operating_mode: { t: 0x14, f: 'u8' },
				uim_state:      { t: 0x15, f: 'u8' },
			},
		},
	},
};
