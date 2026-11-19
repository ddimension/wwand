// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI Voice service (0x09), the USSD subset. Message ids, TLV ids and
// layouts verified against libqmi 1.38 data/qmi-service-voice.json and
// qmi-enums-voice.h (2026-11-19):
//   Indication Register 0x0003 (:22-106), Originate USSD 0x003A (:371-446),
//   Answer USSD 0x003B (:449-467), Cancel USSD 0x003C (:470-475),
//   Release USSD indication 0x003D (:478-482), USSD indication 0x003E
//   (:485-516).
// USS Data is { u8 coding scheme, u8 count + u8[] }; the UTF-16 variant is a
// u8 count of 16-bit units, little-endian on the wire like every QMI integer —
// which is what the codec's u16 array reads.

'use strict';

// QmiVoiceUssDataCodingScheme — NOT the 23.038 DCS byte
export const USS_DCS_UNKNOWN = 0x00;
export const USS_DCS_ASCII   = 0x01;
export const USS_DCS_8BIT    = 0x02;
export const USS_DCS_UCS2    = 0x03;

// QmiVoiceUserAction
export const USER_ACTION_UNKNOWN      = 0x00;
export const USER_ACTION_NOT_REQUIRED = 0x01;
export const USER_ACTION_REQUIRED     = 0x02;

const USS = { dcs: 'u8', data: { n: 'u8', of: 'u8' } };

export default {
	service: 0x09,
	messages: {
		// only the USSD flag: the other event classes (calls, DTMF, ...) stay
		// at the firmware's default, which nothing here would consume
		INDICATION_REGISTER: {
			id: 0x0003,
			req:  { ussd: { t: 0x16, f: 'u8' } },
			resp: {},
		},

		// blocking: the response carries the network's first answer, so the
		// request needs the long timeout (ModemManager waits 100 s,
		// mm-broadband-modem-qmi.c:10799, 1.25.95)
		ORIGINATE_USSD: {
			id: 0x003A,
			req:  { uss: { t: 0x01, f: USS } },
			resp: {
				failure_cause: { t: 0x10, f: 'u16' },
				uss:           { t: 0x12, f: USS },
				utf16:         { t: 0x16, f: { n: 'u8', of: 'u16' } },
			},
		},

		ANSWER_USSD: {
			id: 0x003B,
			req:  { uss: { t: 0x01, f: USS } },
			resp: {},
		},

		CANCEL_USSD: {
			id: 0x003C,
			req:  {},
			resp: {},
		},

		// the network ended the session; no TLVs at all
		RELEASE_USSD_IND: {
			id: 0x003D,
			ind: {},
		},

		USSD_IND: {
			id: 0x003E,
			ind: {
				user_action: { t: 0x01, f: 'u8' },
				uss:         { t: 0x10, f: USS },
				utf16:       { t: 0x11, f: { n: 'u8', of: 'u16' } },
			},
		},
	},
};
