// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI UIM service message schema (service 0x0B).
// TLV layouts verified against libqmi data/qmi-service-uim.json.

'use strict';

// QmiUimCardState
export const CARD_STATE_ABSENT = 0;
export const CARD_STATE_PRESENT = 1;
export const CARD_STATE_ERROR = 2;

// QmiUimCardError — why a card sits in CARD_STATE_ERROR. Worth naming: the
// difference between "slot empty" and "card in backwards" is one of these.
export const CARD_ERRORS = {
	'0': 'unknown',
	'1': 'power down',
	'2': 'poll error',
	'3': 'no ATR received',
	'4': 'voltage mismatch',
	'5': 'parity error',
	'6': 'unknown, possibly removed',
	'7': 'technical problem',
};

// QmiUimCardApplicationState
export const APP_STATE_UNKNOWN = 0;
export const APP_STATE_DETECTED = 1;
export const APP_STATE_PIN1_OR_UPIN_PIN_REQUIRED = 2;
export const APP_STATE_PUK1_OR_UPUK_REQUIRED = 3;
export const APP_STATE_CHECK_PERSONALIZATION_STATE = 4;
export const APP_STATE_PIN1_BLOCKED = 5;
export const APP_STATE_ILLEGAL = 6;
export const APP_STATE_READY = 7;

// QmiUimCardApplicationPersonalizationState (the app.personalization_state
// carried alongside APP_STATE_CHECK_PERSONALIZATION_STATE). 3/4/5 = an active
// perso lock; 0/1/2 = nothing to unlock.
export const PERSO_STATE_UNKNOWN = 0;
export const PERSO_STATE_IN_PROGRESS = 1;
export const PERSO_STATE_READY = 2;
export const PERSO_STATE_CODE_REQUIRED = 3;
export const PERSO_STATE_PUK_CODE_REQUIRED = 4;
export const PERSO_STATE_PERMANENTLY_BLOCKED = 5;

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

// QmiUimEventRegistrationFlag — the mask of QMI_UIM_EVENT_REG (0x002E).
//
// libqmi models four of these (0, 1, 2, 4). The rest are device-observed: every
// bit below is documented in the vendor IDL and every indication it unlocks is
// present in the RG650E's own UIM request/indication table (2026-08-30). We arm
// the four that turn a silent SIM failure into a named event and leave the rest
// declared — SAP, simlock and the reduced/extended card-status variants have no
// consumer here, and arming an indication nothing decodes only costs wakeups.
export const EVENT_CARD_STATUS          = (1 << 0);
export const EVENT_SAP_CONNECTION       = (1 << 1);
export const EVENT_EXT_CARD_STATUS      = (1 << 2);
export const EVENT_SESSION_CLOSE        = (1 << 3);
export const EVENT_SLOT_STATUS          = (1 << 4);
export const EVENT_SIM_BUSY             = (1 << 5);
export const EVENT_REDUCED_CARD_STATUS  = (1 << 6);
export const EVENT_RECOVERY_COMPLETE    = (1 << 7);
export const EVENT_SUPPLY_VOLTAGE       = (1 << 8);
export const EVENT_CARD_ACTIVATION      = (1 << 9);
export const EVENT_SIMLOCK_CONFIG       = (1 << 10);
export const EVENT_SIMLOCK_TEMP_UNLOCK  = (1 << 11);

// what wwand actually asks for: card status, plus the four diagnostics below.
// Kept as one constant so the request site reads as a decision rather than a
// bit-fiddle, and so a modem that refuses the whole mask fails in one place.
export const EVENTS_WANTED = EVENT_CARD_STATUS | EVENT_SESSION_CLOSE |
                             EVENT_SIM_BUSY | EVENT_RECOVERY_COMPLETE |
                             EVENT_CARD_ACTIVATION;

// QmiUimSessionCloseCause — why the card dropped our provisioning session.
// This is the difference between "we closed it" and "the card is failing", and
// until now the session simply went away without a word.
export const SESSION_CLOSE_CAUSES = {
	'0':  'unknown',
	'1':  'client request',
	'2':  'card error',
	'3':  'card powered down',
	'4':  'card removed',
	'5':  'refresh',
	'6':  'PIN status unavailable',
	'7':  'internal card recovery',
	'8':  'FDN enabled but unsupported by the terminal',
	'9':  'personalization failure',
	'10': 'file content invalid',
	'11': 'mandatory file missing',
};

// card_activation_status_enum_v01
export const CARD_ACTIVATION_START        = 0;
export const CARD_ACTIVATION_END_SUCCESS  = 1;
export const CARD_ACTIVATION_END_FAILURE  = 2;

export const CARD_ACTIVATION_STATES = {
	'0': 'started', '1': 'completed', '2': 'failed',
};

// refresh_enforcement_policy_mask on REFRESH_IND (0x0033) — what the card is
// willing to interrupt to push the refresh through. DATA_CALL is the one that
// matters on a router: it means the card will pull the session out from under
// an active data call rather than wait.
export const REFRESH_ENFORCE_NAVIGATING_MENU = (1 << 0);
export const REFRESH_ENFORCE_DATA_CALL       = (1 << 1);
export const REFRESH_ENFORCE_VOICE_CALL      = (1 << 2);

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

		// Write Transparent (update a transparent EF, e.g. EF_FPLMN 6F7B).
		// NOTE: libqmi 1.38 ships NO binding for this message — its layout is
		// derived from the QMI UIM spec and mirrors READ_TRANSPARENT (0x0020),
		// with the read_info replaced by write data. Locked by a wire-buffer
		// test (test_qmi_backend) and HW-validated on the RG650E (E392 rejects
		// UIM and uses the AT+CRSM path instead).
		WRITE_TRANSPARENT: {
			id: 0x0022,
			req: {
				session:    SESSION,
				file:       { t: 0x02, f: { file_id: 'u16', path: 'lstring' } },
				write_data: { t: 0x03, f: { offset: 'u16', data: { n: 'u16', of: 'u8' } } },
			},
			resp: {
				// card SW1/SW2 status word (optional; present on most modems)
				card_result: { t: 0x10, f: { sw1: 'u8', sw2: 'u8' } },
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
				// Declared, deliberately not sent. 0x00 (the default, and what
				// we get today) returns intermediate procedure bytes; 0x01 asks
				// the card for the final result and status words only. The
				// current behaviour is HW-proven with lpac, which does its own
				// 61xx/6Cxx handling, so changing what we ask for would be a
				// change to a working path for no established gain.
				procedure_bytes: { t: 0x11, f: 'u8' },
				// Uplink chunking, for an APDU too large for one QMI message:
				// same token across the chunks, offset counting from 0.
				long_request: { t: 0x12, f: {
					total_length: 'u16', token: 'u32', offset: 'u16' } },
			},
			resp: {
				response: { t: 0x10, f: { n: 'u16', of: 'u8' } },
				// The card's answer did not fit in the response. Then TLV 0x10 is
				// ABSENT and this carries the token to reassemble from the
				// SEND_APDU indications instead. Modelled by neither libqmi nor,
				// until now, wwand — so a long answer read as "no response TLV"
				// looked like a card that had nothing to say. That is silent
				// truncation, and eSIM is exactly where it bites: an ES10 profile
				// list or a certificate routinely exceeds one message.
				long_response: { t: 0x11, f: {
					total_length: 'u16', token: 'u32' } },
			},
		},

		// The chunks of a long response. `apdu` carries a u16 count
		// (QMI_IDL_FLAGS_SZ_IS_16 in the IDL, max 1024) — a u8 count would
		// decode the first chunk as garbage of plausible length.
		SEND_APDU_IND: {
			id: 0x003B,
			ind: {
				chunk: { t: 0x01, f: {
					token: 'u32', total_length: 'u16', offset: 'u16',
					apdu: { n: 'u16', of: 'u8' } } },
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

		// PUK entry: unblocks a PUK-locked PIN and sets a NEW pin in one op.
		// Verified vs libqmi 1.38 qmi-service-uim.json ("Unblock PIN" 0x0027:
		// Session + Info 0x02 { PIN ID u8, PUK string, New PIN string };
		// response 0x10 Retries Remaining { verify u8, unblock u8 }).
		UNBLOCK_PIN: {
			id: 0x0027,
			req: {
				session: SESSION,
				info:    { t: 0x02, f: { pin_id: 'u8', puk: 'lstring', new_pin: 'lstring' } },
			},
			resp: {
				retries: { t: 0x10, f: { verify: 'u8', unblock: 'u8' } },
			},
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

		// SIM hot-reset (card power off/on, slot 1-based). The modem discards
		// its cached SIM state and re-reads the card — the "apply" after an
		// eSIM profile switch. Verified vs libqmi 1.38 (0x0030/0x0031).
		POWER_OFF_SIM: {
			id: 0x0030,
			req:  { slot: { t: 0x01, f: 'u8' } },
			resp: {},
		},

		POWER_ON_SIM: {
			id: 0x0031,
			req:  { slot: { t: 0x01, f: 'u8' } },
			resp: {},
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

		// SIM/eUICC refresh registration + indication. A network- or LPA-initiated
		// refresh (e.g. an eSIM profile switch, or a SIM OTA file update) is pushed
		// as a Refresh indication so wwand can re-read identity (ICCID/IMSI may
		// change) instead of running stale. Verified vs libqmi qmi-service-uim.json:
		//   Refresh Register All (0x0044): UIM Session 0x01 + Info 0x02
		//                                  { register_flag u8 }.
		//   Refresh (0x0033): Event 0x10 sequence, leading fixed fields
		//                     { stage u8, mode u8, session_type u8 } followed by the
		//                     variable aid/files arrays (not needed here — the
		//                     leading fields tell us a refresh happened and its
		//                     stage; the decoder ignores the trailing arrays).
		REFRESH_REGISTER_ALL: {
			id: 0x0044,
			req: {
				session:  SESSION,
				register: { t: 0x02, f: { register_flag: 'u8' } },
				// Optional, and the half of the refresh protocol libqmi does not
				// model. Voting for init puts us in the WAIT_FOR_OK stage: the
				// card asks before it refreshes and waits for REFRESH_OK (0x002B).
				// Both answers have a cost — a client that votes and never
				// answers stalls the card, one that does not vote gets its
				// session pulled mid-data-call — so this is only sent together
				// with a handler that always replies. See modem.uc.
				vote:     { t: 0x10, f: { vote_for_init: 'u8' } },
			},
			resp: {},
		},

		// The answer to a WAIT_FOR_OK refresh. libqmi models neither this message
		// nor the vote above, so a libqmi-based stack structurally cannot complete
		// that handshake. Message id is openly attested (Gobi eQMI_UIM_REFRESH_OK
		// = 43 = 0x2B) and present in the RG650E request table; the TLV pair is
		// device-observed: 0x01 session (aggregate), 0x02 ok_to_refresh u8.
		REFRESH_OK: {
			id: 0x002B,
			req: {
				session: SESSION,
				ok:      { t: 0x02, f: { ok_to_refresh: 'u8' } },
			},
			resp: {},
		},

		REFRESH_IND: {
			id: 0x0033,
			ind: {
				event: { t: 0x10, f: {
					stage: 'u8', mode: 'u8', session_type: 'u8' } },
				// u64, not u32 — the IDL marks it GENERIC_8_BYTE. Getting the
				// width wrong here would not fail, it would silently swallow the
				// following TLV.
				enforcement: { t: 0x11, f: 'u64' },
			},
		},

		// --- diagnostics: the four indications EVENTS_WANTED arms ---------------
		// Every one of these is a failure the daemon could previously only observe
		// as "the SIM stopped working". TLV ids are device-observed against the
		// vendor IDL encoder tables and cross-checked against the RG650E's own
		// indication table.

		// A provisioning session the card closed on us, with the reason. Note
		// `cause` is FOUR bytes (GENERIC_4_BYTE in the IDL) even though every
		// defined value fits in one.
		SESSION_CLOSED_IND: {
			id: 0x0043,
			ind: {
				slot:         { t: 0x01, f: 'u8' },
				aid:          { t: 0x10, f: 'lstring' },
				channel_id:   { t: 0x11, f: 'u8' },
				session_type: { t: 0x12, f: 'u8' },
				cause:        { t: 0x13, f: 'u32' },
				// which mandatory file was missing or unreadable, when that is
				// the cause — the one field that says *what* to go and look at
				file_id:      { t: 0x14, f: 'u16' },
			},
		},

		// "the card is busy" — one byte per slot. A busy card refuses reads, and
		// without this a PIN or ICCID read just times out for no visible reason.
		SIM_BUSY_STATUS_IND: {
			id: 0x004A,
			ind: { busy: { t: 0x10, f: { n: 'u8', of: 'u8' } } },
		},

		// the card completed an internal recovery: everything cached about it
		// (sessions, channels, file contents) is now suspect
		RECOVERY_IND: {
			id: 0x0050,
			ind: { slot: { t: 0x01, f: 'u8' } },
		},

		// card activation start/end — the window in which a card is present but
		// not yet usable, which otherwise reads as a broken SIM
		CARD_ACTIVATION_STATUS_IND: {
			id: 0x0055,
			ind: {
				slot:   { t: 0x01, f: 'u8' },
				status: { t: 0x02, f: 'u32' },
			},
		},
	},
};

// QmiUimRefreshStage — the refresh lifecycle. START precedes the file changes,
// END_SUCCESS / END_FAILURE bracket completion; we re-read identity on END_SUCCESS.
export const REFRESH_STAGE_WAIT_FOR_OK   = 0;
export const REFRESH_STAGE_START         = 1;
export const REFRESH_STAGE_END_SUCCESS   = 2;
export const REFRESH_STAGE_END_FAILURE   = 3;
