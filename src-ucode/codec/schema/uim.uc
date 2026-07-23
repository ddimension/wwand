// wwand — QMI UIM service message schema (service 0x0B).
// TLV layouts verified against libqmi data/qmi-service-uim.json.

'use strict';

// QmiUimCardState
export const CARD_STATE_ABSENT = 0;
export const CARD_STATE_PRESENT = 1;
export const CARD_STATE_ERROR = 2;

// QmiUimCardApplicationState
export const APP_STATE_UNKNOWN = 0;
export const APP_STATE_DETECTED = 1;
export const APP_STATE_PIN1_OR_UPIN_PIN_REQUIRED = 2;
export const APP_STATE_PUK1_OR_UPUK_REQUIRED = 3;
export const APP_STATE_CHECK_PERSONALIZATION_STATE = 4;
export const APP_STATE_PIN1_BLOCKED = 5;
export const APP_STATE_ILLEGAL = 6;
export const APP_STATE_READY = 7;

// QmiUimCardApplicationType
export const APP_TYPE_SIM = 1;
export const APP_TYPE_USIM = 2;

// QmiUimPinId
export const PIN_ID_PIN1 = 1;
export const PIN_ID_PIN2 = 2;
export const PIN_ID_UPIN = 3;

// QmiUimSessionType
export const SESSION_TYPE_PRIMARY_GW_PROVISIONING = 0;
export const SESSION_TYPE_CARD_SLOT_1 = 6;

// QmiUimEventRegistrationFlag
export const EVENT_CARD_STATUS = (1 << 0);

// UIM Session TLV: mandatory on most requests. aid stays empty for
// provisioning sessions.
const SESSION = { t: 0x01, f: { session_type: 'u8', aid: 'lstring' } };

const CARD_STATUS_FMT = {
	index_gw_primary:  'u16',
	index_1x_primary:  'u16',
	index_gw_secondary:'u16',
	index_1x_secondary:'u16',
	cards: { n: 'u8', of: {
		card_state:   'u8',
		upin_state:   'u8',
		upin_retries: 'u8',
		upuk_retries: 'u8',
		error_code:   'u8',
		applications: { n: 'u8', of: {
			type:                  'u8',
			state:                 'u8',
			personalization_state: 'u8',
			personalization_feature: 'u8',
			personalization_retries: 'u8',
			personalization_unblock_retries: 'u8',
			aid:                   'lstring',
			upin_replaces_pin1:    'u8',
			pin1_state:            'u8',
			pin1_retries:          'u8',
			puk1_retries:          'u8',
			pin2_state:            'u8',
			pin2_retries:          'u8',
			puk2_retries:          'u8',
		} },
	} },
};

export default {
	service: 0x0B,
	messages: {
		READ_TRANSPARENT: {
			id: 0x0020,
			req: {
				session:   SESSION,
				// path: raw bytes, u16-le pairs, e.g. "\x00\x3F\xFF\x7F" for 3F00/7FFF
				file:      { t: 0x02, f: { file_id: 'u16', path: 'lstring' } },
				read_info: { t: 0x03, f: { offset: 'u16', len: 'u16' } },
			},
			resp: {
				data: { t: 0x11, f: { n: 'u16', of: 'u8' } },
			},
		},

		// physical SIM slot status/selection (multi-slot devices). Verified
		// against libqmi 1.38: TLV 0x10 = u8-counted array of slot structs
		// with a length-prefixed raw ICCID (nibble-swapped BCD).
		SWITCH_SLOT: {
			id: 0x0046,
			req: {
				logical:  { t: 0x01, f: 'u8' },
				physical: { t: 0x02, f: 'u32' },
			},
			resp: {},
		},

		GET_SLOT_STATUS: {
			id: 0x0047,
			req: {},
			resp: {
				slots: { t: 0x10, f: { n: 'u8', of: {
					card_status:  'u32',   // 0 unknown, 1 absent, 2 present
					slot_status:  'u32',   // 0 inactive, 1 active
					logical_slot: 'u8',
					iccid:        'lstring',
				} } },
				// per-slot card details incl. the eUICC flag (same order)
				info: { t: 0x11, f: { n: 'u8', of: {
					card_protocol:      'u32',
					valid_applications: 'u8',
					atr:                'lstring',
					is_euicc:           'u8',
				} } },
				// per-slot EID (empty on non-eUICC slots; same order)
				eids: { t: 0x12, f: { n: 'u8', of: { eid: 'lstring' } } },
			},
		},

		// raw APDU access (eSIM/ES10 traffic runs over a logical channel to
		// the ISD-R). Verified against libqmi 1.38: APDU arrays are u16-
		// prefixed, AID/select-response u8-prefixed.
		SEND_APDU: {
			id: 0x003B,
			req: {
				slot:       { t: 0x01, f: 'u8' },
				apdu:       { t: 0x02, f: { n: 'u16', of: 'u8' } },
				channel_id: { t: 0x10, f: 'u8' },
			},
			resp: {
				response: { t: 0x10, f: { n: 'u16', of: 'u8' } },
			},
		},

		OPEN_LOGICAL_CHANNEL: {
			id: 0x0042,
			req: {
				slot: { t: 0x01, f: 'u8' },
				aid:  { t: 0x10, f: { n: 'u8', of: 'u8' } },
			},
			resp: {
				channel_id:      { t: 0x10, f: 'u8' },
				select_response: { t: 0x12, f: { n: 'u8', of: 'u8' } },
			},
		},

		LOGICAL_CHANNEL: {
			id: 0x003F,
			req: {
				slot:       { t: 0x01, f: 'u8' },
				channel_id: { t: 0x11, f: 'u8' },
				terminate:  { t: 0x13, f: 'u8' },
			},
			resp: {},
		},

		VERIFY_PIN: {
			id: 0x0026,
			req: {
				session: SESSION,
				info:    { t: 0x02, f: { pin_id: 'u8', pin: 'lstring' } },
			},
			resp: {
				retries: { t: 0x10, f: { verify: 'u8', unblock: 'u8' } },
			},
		},

		// enable/disable the PIN1 query (SIM PIN lock). enabled=1 requires the
		// PIN at power-on, 0 removes it. Verified against libqmi 1.38 (0x0025).
		SET_PIN_PROTECTION: {
			id: 0x0025,
			req: {
				session: SESSION,
				info:    { t: 0x02, f: { pin_id: 'u8', enabled: 'u8', pin: 'lstring' } },
			},
			resp: {
				retries: { t: 0x10, f: { verify: 'u8', unblock: 'u8' } },
			},
		},

		REGISTER_EVENTS: {
			id: 0x002E,
			req:  { mask: { t: 0x01, f: 'u32' } },
			resp: { mask: { t: 0x10, f: 'u32' } },
		},

		GET_CARD_STATUS: {
			id: 0x002F,
			req:  {},
			resp: { card_status: { t: 0x10, f: CARD_STATUS_FMT } },
		},

		CARD_STATUS_IND: {
			id: 0x0032,
			ind: { card_status: { t: 0x10, f: CARD_STATUS_FMT } },
		},
	},
};
