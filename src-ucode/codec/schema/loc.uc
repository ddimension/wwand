// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI LOC service message schema (service 0x10).
// TLV layouts verified against libqmi data/qmi-service-loc.json (1.38).
// Ships in wwand-gps: the core has no GNSS of its own.

'use strict';

// QmiLocEventRegistrationFlag (qmi-flags64-loc.h, libqmi 1.38)
export const EVENT_POSITION_REPORT = 1;   // 1 << 0
export const EVENT_NMEA = 4;              // 1 << 2

// QmiLocNmeaType ALL (qmi-enums-loc.h, libqmi 1.38: QMI_LOC_NMEA_TYPE_ALL).
// NOT the five named bits (GGA RMC GSV GSA VTG = 0x1F): those are the GPS
// sentences only, and the engine then reports GPS satellites alone although
// it tracks more. With ALL an RG502Q reported GPS, GLONASS and Galileo — 33
// satellites in view instead of 14 (HW-observed on the NR7101, 2026-10-04).
// The proprietary sentences that come along (PQXFI, PSTIS) are counted as
// unparsed by nmea.uc and otherwise ignored.
export const NMEA_TYPES_ALL = 0xFFFF;

// QmiLocSessionStatus
export const SESSION_STATUS_SUCCESS = 0;
export const SESSION_STATUS_IN_PROGRESS = 1;

// QmiLocFixRecurrenceType
export const FIX_RECURRENCE_PERIODIC = 1;

export default {
	service: 0x10,
	messages: {
		REGISTER_EVENTS: {
			id: 0x0021,
			req:  { mask: { t: 0x01, f: 'u64' } },
			resp: {},
		},

		START: {
			id: 0x0022,
			req: {
				session_id:           { t: 0x01, f: 'u8' },
				// QmiLocFixRecurrenceType (libqmi 1.38): 1 = periodic, 2 = single.
				// Optional on the wire, and LEFT OUT the session is a single
				// fix: an RG502Q sent ~60 NMEA sentences and then nothing, the
				// fix aging out behind it (HW-observed on the NR7101, 2026-10-04)
				fix_recurrence:       { t: 0x10, f: 'u32' },
				// 1 = report intermediate fixes too
				intermediate_reports: { t: 0x12, f: 'u32' },
				min_interval_ms:      { t: 0x13, f: 'u32' },
			},
			resp: {},
		},

		// libqmi 1.38 qmi-service-loc.json "Stop": the session START opened,
		// by its id. A session is the modem's, not the client's: releasing
		// the client does not end it (see modem.uc teardown).
		STOP: {
			id: 0x0023,
			req: { session_id: { t: 0x01, f: 'u8' } },
			resp: {},
		},

		// libqmi 1.38 "Set NMEA Types" (message): which sentences the engine
		// emits as NMEA indications. Since 1.26 in libqmi, so not every
		// firmware knows it — a refusal leaves the engine's own default.
		SET_NMEA_TYPES: {
			id: 0x003E,
			req: { types: { t: 0x01, f: 'u32' } },
			resp: {},
		},

		// libqmi 1.38 "NMEA" (indication): one or more sentences as a
		// string, CR/LF-terminated as on a serial port
		NMEA_IND: {
			id: 0x0026,
			ind: {
				nmea: { t: 0x01, f: 'string' },
			},
		},

		POSITION_REPORT_IND: {
			id: 0x0024,
			ind: {
				status:        { t: 0x01, f: 'u32' },
				session_id:    { t: 0x02, f: 'u8' },
				latitude:      { t: 0x10, f: 'f64' },
				longitude:     { t: 0x11, f: 'f64' },
				h_uncertainty: { t: 0x12, f: 'f32' },
				h_speed:       { t: 0x18, f: 'f32' },
				altitude:      { t: 0x1B, f: 'f32' },   // above sea level
				v_uncertainty: { t: 0x1C, f: 'f32' },
				v_speed:       { t: 0x1F, f: 'f32' },
				heading:       { t: 0x20, f: 'f32' },
				technology:    { t: 0x23, f: 'u32' },
				dop:           { t: 0x24, f: { pdop: 'f32', hdop: 'f32', vdop: 'f32' } },
				utc_ms:        { t: 0x25, f: 'u64' },
			},
		},
	},
};
