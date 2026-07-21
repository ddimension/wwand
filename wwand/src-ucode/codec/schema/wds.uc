// wwand — QMI WDS service message schema (service 0x01).
// TLV layouts verified against libqmi data/qmi-service-wds.json.

'use strict';

// QmiWdsIpFamily
export const IP_FAMILY_IPV4 = 4;
export const IP_FAMILY_IPV6 = 6;
export const IP_FAMILY_UNSPECIFIED = 8;

// QmiWdsPdpType
export const PDP_TYPE_IPV4 = 0;
export const PDP_TYPE_PPP = 1;
export const PDP_TYPE_IPV6 = 2;
export const PDP_TYPE_IPV4V6 = 3;

// QmiWdsAuthentication (bitmask)
export const AUTH_NONE = 0;
export const AUTH_PAP = 1;
export const AUTH_CHAP = 2;
export const AUTH_BOTH = 3;

// QmiWdsConnectionStatus
export const CONN_DISCONNECTED = 1;
export const CONN_CONNECTED = 2;
export const CONN_SUSPENDED = 3;
export const CONN_AUTHENTICATING = 4;

// QmiWdsProfileType
export const PROFILE_TYPE_3GPP = 0;

// QmiWdsRequestedSettings bits for GET_CURRENT_SETTINGS
export const REQ_SETTINGS_DEFAULT =
	(1 << 2) |   // pdp type
	(1 << 3) |   // apn name
	(1 << 4) |   // dns address
	(1 << 8) |   // ip address
	(1 << 9) |   // gateway info
	(1 << 13) |  // mtu
	(1 << 15);   // ip family

const PROFILE_ID = { t: 0x01, f: { type: 'u8', index: 'u8' } };

export default {
	service: 0x01,
	messages: {
		SET_EVENT_REPORT: {
			id: 0x0001,
			req: {
				stats: { t: 0x11, f: { interval: 'u8', indicators: 'i32' } },
			},
			resp: {},
		},

		EVENT_REPORT_IND: {
			id: 0x0001,
			ind: {
				tx_packets_ok: { t: 0x10, f: 'u32' },
				rx_packets_ok: { t: 0x11, f: 'u32' },
				tx_bytes_ok:   { t: 0x19, f: 'u64' },
				rx_bytes_ok:   { t: 0x1A, f: 'u64' },
			},
		},

		START_NETWORK: {
			id: 0x0020,
			req: {
				apn:               { t: 0x14, f: 'string' },
				auth:              { t: 0x16, f: 'u8' },
				username:          { t: 0x17, f: 'string' },
				password:          { t: 0x18, f: 'string' },
				ip_family:         { t: 0x19, f: 'u8' },
				profile_3gpp:      { t: 0x31, f: 'u8' },
				enable_autoconnect:{ t: 0x33, f: 'u8' },
			},
			resp: {
				pdh:               { t: 0x01, f: 'u32' },
				call_end_reason:   { t: 0x10, f: 'u16' },
				verbose_call_end:  { t: 0x11, f: { type: 'u16', reason: 'i16' } },
			},
		},

		STOP_NETWORK: {
			id: 0x0021,
			req: {
				pdh:                 { t: 0x01, f: 'u32' },
				disable_autoconnect: { t: 0x10, f: 'u8' },
			},
			resp: {},
		},

		GET_PACKET_SERVICE_STATUS: {
			id: 0x0022,
			req:  {},
			resp: { status: { t: 0x01, f: 'u8' } },
		},

		PACKET_SERVICE_STATUS_IND: {
			id: 0x0022,
			ind: {
				status:           { t: 0x01, f: { status: 'u8', reconfigure: 'u8' } },
				call_end_reason:  { t: 0x10, f: 'u16' },
				verbose_call_end: { t: 0x11, f: { type: 'u16', reason: 'i16' } },
				ip_family:        { t: 0x12, f: 'u8' },
			},
		},

		// current + modem-computed maximum channel rate (bits/sec) for the
		// active radio link — the max up/down bandwidth the current cell
		// configuration (bandwidth, MIMO, modulation, CA) can deliver.
		GET_CHANNEL_RATES: {
			id: 0x0023,
			req: {},
			resp: {
				rates: { t: 0x01, f: {
					tx_rate:     'u32',
					rx_rate:     'u32',
					max_tx_rate: 'u32',
					max_rx_rate: 'u32',
				} },
			},
		},

		GET_PACKET_STATISTICS: {
			id: 0x0024,
			req:  { mask: { t: 0x01, f: 'u32' } },
			resp: {
				tx_packets_ok:      { t: 0x10, f: 'u32' },
				rx_packets_ok:      { t: 0x11, f: 'u32' },
				tx_packets_error:   { t: 0x12, f: 'u32' },
				rx_packets_error:   { t: 0x13, f: 'u32' },
				tx_overflows:       { t: 0x14, f: 'u32' },
				rx_overflows:       { t: 0x15, f: 'u32' },
				tx_bytes_ok:        { t: 0x19, f: 'u64' },
				rx_bytes_ok:        { t: 0x1A, f: 'u64' },
				tx_packets_dropped: { t: 0x25, f: 'u32' },
				rx_packets_dropped: { t: 0x26, f: 'u32' },
			},
		},

		MODIFY_PROFILE: {
			id: 0x0028,
			req: {
				profile:             PROFILE_ID,
				profile_name:        { t: 0x10, f: 'string' },
				pdp_type:            { t: 0x11, f: 'u8' },
				apn:                 { t: 0x14, f: 'string' },
				username:            { t: 0x1B, f: 'string' },
				password:            { t: 0x1C, f: 'string' },
				auth:                { t: 0x1D, f: 'u8' },
				apn_disabled:        { t: 0x2F, f: 'u8' },
				roaming_disallowed:  { t: 0x3E, f: 'u8' },
			},
			resp: {
				// extended error code on failure
				ext_error: { t: 0xE0, f: 'u16' },
			},
		},

		GET_PROFILE_SETTINGS: {
			id: 0x002B,
			req: { profile: PROFILE_ID },
			resp: {
				profile_name: { t: 0x10, f: 'string' },
				pdp_type:     { t: 0x11, f: 'u8' },
				apn:          { t: 0x14, f: 'string' },
				username:     { t: 0x1B, f: 'string' },
				auth:         { t: 0x1D, f: 'u8' },
				apn_disabled: { t: 0x2F, f: 'u8' },
			},
		},

		GET_DEFAULT_SETTINGS: {
			id: 0x002C,
			req: { profile_type: { t: 0x01, f: 'u8' } },
			resp: {
				pdp_type: { t: 0x11, f: 'u8' },
				apn:      { t: 0x14, f: 'string' },
			},
		},

		GET_CURRENT_SETTINGS: {
			id: 0x002D,
			req: { requested: { t: 0x10, f: 'u32' } },
			resp: {
				pdp_type:     { t: 0x11, f: 'u8' },
				apn:          { t: 0x14, f: 'string' },
				dns1:         { t: 0x15, f: 'ipv4' },
				dns2:         { t: 0x16, f: 'ipv4' },
				ipv4:         { t: 0x1E, f: 'ipv4' },
				gateway:      { t: 0x20, f: 'ipv4' },
				netmask:      { t: 0x21, f: 'ipv4' },
				ipv6:         { t: 0x25, f: { addr: 'ipv6', plen: 'u8' } },
				ipv6_gateway: { t: 0x26, f: { addr: 'ipv6', plen: 'u8' } },
				ipv6_dns1:    { t: 0x27, f: 'ipv6' },
				ipv6_dns2:    { t: 0x28, f: 'ipv6' },
				mtu:          { t: 0x29, f: 'u32' },
				ip_family:    { t: 0x2B, f: 'u8' },
			},
		},

		SET_DEFAULT_PROFILE_NUMBER: {
			id: 0x004A,
			req: {
				profile: { t: 0x01, f: { type: 'u8', family: 'u8', index: 'u8' } },
			},
			resp: {},
		},

		SET_IP_FAMILY: {
			id: 0x004D,
			req:  { preference: { t: 0x01, f: 'u8' } },
			resp: {},
		},

		BIND_MUX_DATA_PORT: {
			id: 0x00A2,
			req: {
				endpoint: { t: 0x10, f: { type: 'u32', iface: 'u32' } },
				mux_id:   { t: 0x11, f: 'u8' },
			},
			resp: {},
		},
	},
};
