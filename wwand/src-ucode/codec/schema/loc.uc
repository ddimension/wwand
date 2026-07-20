// wwand — QMI LOC service message schema (service 0x10).
// TLV layouts verified against libqmi data/qmi-service-loc.json.

'use strict';

// QmiLocEventRegistrationFlag
export const EVENT_POSITION_REPORT = 1;   // 1 << 0

// QmiLocSessionStatus
export const SESSION_STATUS_SUCCESS = 0;
export const SESSION_STATUS_IN_PROGRESS = 1;

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
				// 1 = report intermediate fixes too
				intermediate_reports: { t: 0x12, f: 'u32' },
				min_interval_ms:      { t: 0x13, f: 'u32' },
			},
			resp: {},
		},

		STOP: {
			id: 0x0023,
			req:  { session_id: { t: 0x01, f: 'u8' } },
			resp: {},
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
