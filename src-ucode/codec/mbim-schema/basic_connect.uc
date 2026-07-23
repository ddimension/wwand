// wwand — MBIM Basic Connect service schema (MBIM 1.0).
// Field layouts verified against libmbim data/mbim-service-basic-connect.json;
// CID numbers are the MBIM 1.0 standard values.

'use strict';

import * as struct from 'struct';

export const SERVICE_UUID = 'a289cc33-bcbb-8b4f-b6b0-133ec2aae6df';

// context type UUIDs
export const CONTEXT_TYPE_INTERNET = '7e5e2a7e-4e6f-7272-736b-656e7e5e2a7e';

// MbimActivationState
export const ACTIVATION_DEACTIVATED = 0;
export const ACTIVATION_ACTIVATED = 1;
export const ACTIVATION_ACTIVATING = 2;

// MbimActivationCommand
export const ACTIVATION_CMD_DEACTIVATE = 0;
export const ACTIVATION_CMD_ACTIVATE = 1;

// MbimContextIpType
export const IP_TYPE_DEFAULT = 0;
export const IP_TYPE_IPV4 = 1;
export const IP_TYPE_IPV6 = 2;
export const IP_TYPE_IPV4V6 = 3;

// MbimAuthProtocol
export const AUTH_NONE = 0;
export const AUTH_PAP = 1;
export const AUTH_CHAP = 2;
export const AUTH_MSCHAPV2 = 3;

// MbimSubscriberReadyState
export const READY_STATE_INITIALIZED = 1;

// MbimPinType / MbimPinState
export const PIN_TYPE_PIN1 = 2;
export const PIN_STATE_UNLOCKED = 0;
export const PIN_STATE_LOCKED = 1;
export const PIN_OP_ENTER = 0;

// MbimRegisterState — values verified against libmbim mbim-enums.h. (Earlier
// wwand used 1/2/3 for home/roaming/partner, which only worked for the home
// case by accident — a real modem reports home=3, so the old 3==PARTNER check
// matched — and would have misclassified roaming (4). Now correct.)
export const REGISTER_STATE_DEREGISTERED = 1;
export const REGISTER_STATE_SEARCHING = 2;
export const REGISTER_STATE_HOME = 3;
export const REGISTER_STATE_ROAMING = 4;
export const REGISTER_STATE_PARTNER = 5;
export const REGISTER_STATE_DENIED = 6;

// MbimPacketServiceAction / State
export const PACKET_SERVICE_ATTACH = 0;
export const PACKET_SERVICE_STATE_ATTACHED = 2;

// MbimRadioSwitchState
export const RADIO_STATE_OFF = 0;
export const RADIO_STATE_ON = 1;

// MBIM RSSI coding: index 0..31 -> -113..-51 dBm (step 2); 99 = unknown.
export const RSSI_UNKNOWN = 99;

// --- v2 Signal State custom decode ------------------------------------------
// The MBIMEx v2 Signal State (basic-connect service, same CID 11 as v1) appends
// an ms-struct-array of MbimRsrpSnrInfo {Rsrp,Snr,RsrpThreshold,SnrThreshold,
// SystemType} — five guint32 each — after the v1 fixed fields. ms-struct-array
// (an [offset,size] pointer to a [count][elems] region) is not expressible in
// the InformationBuffer codec vocabulary, so decode the raw buffer here.
// Verified vs libmbim data/mbim-service-ms-basic-connect-v2.json.
function _u32(buf, p)
{
	return (p + 4 <= length(buf)) ? struct.unpack('<I', substr(buf, p, 4))[0] : 0;
}

export function decode_signal_state_v2(info)
{
	let res = {
		rssi:                     _u32(info, 0),
		error_rate:               _u32(info, 4),
		signal_strength_interval: _u32(info, 8),
		rssi_threshold:           _u32(info, 12),
		error_rate_threshold:     _u32(info, 16),
		rsrp_snr:                 [],
	};

	// RsrpSnr ms-struct-array pointer at offset 20 (offset + size)
	let ptr = _u32(info, 20);

	if (ptr > 0 && ptr + 4 <= length(info)) {
		let count = _u32(info, ptr);
		let o = ptr + 4;

		for (let i = 0; i < count && o + 20 <= length(info); i++, o += 20)
			push(res.rsrp_snr, {
				rsrp:        _u32(info, o),
				snr:         _u32(info, o + 4),
				system_type: _u32(info, o + 16),   // MbimDataClass bitmask
			});
	}

	return res;
}

export const service = SERVICE_UUID;

export const commands = {
		DEVICE_CAPS: {
			cid: 1,
			response: {
				device_type: 'u32', cellular_class: 'u32', voice_class: 'u32',
				sim_class: 'u32', data_class: 'u32', sms_caps: 'u32',
				control_caps: 'u32', max_sessions: 'u32',
				custom_data_class: 'string', device_id: 'string',
				firmware_info: 'string', hardware_info: 'string',
			},
		},

		SUBSCRIBER_READY_STATUS: {
			cid: 2,
			response: {
				ready_state: 'u32', subscriber_id: 'string', sim_iccid: 'string',
				ready_info: 'u32', telephone_numbers_count: 'u32',
			},
			notification: {
				ready_state: 'u32', subscriber_id: 'string', sim_iccid: 'string',
				ready_info: 'u32', telephone_numbers_count: 'u32',
			},
		},

		PIN: {
			cid: 4,
			set: { pin_type: 'u32', pin_operation: 'u32', pin: 'string', new_pin: 'string' },
			response: { pin_type: 'u32', pin_state: 'u32', remaining_attempts: 'u32' },
		},

		REGISTER_STATE: {
			cid: 9,
			response: {
				nw_error: 'u32', register_state: 'u32', register_mode: 'u32',
				available_data_classes: 'u32', current_cellular_class: 'u32',
				provider_id: 'string', provider_name: 'string',
				roaming_text: 'string', registration_flag: 'u32',
			},
			notification: {
				nw_error: 'u32', register_state: 'u32', register_mode: 'u32',
				available_data_classes: 'u32', current_cellular_class: 'u32',
				provider_id: 'string', provider_name: 'string',
				roaming_text: 'string', registration_flag: 'u32',
			},
		},

		PACKET_SERVICE: {
			cid: 10,
			set: { packet_service_action: 'u32' },
			response: {
				nw_error: 'u32', packet_service_state: 'u32',
				highest_available_data_class: 'u32',
				uplink_speed: 'u64', downlink_speed: 'u64',
			},
			notification: {
				nw_error: 'u32', packet_service_state: 'u32',
				highest_available_data_class: 'u32',
				uplink_speed: 'u64', downlink_speed: 'u64',
			},
		},

		// MbimRadioSwitchState hardware/software radio state (CID 3).
		RADIO_STATE: {
			cid: 3,
			set: { radio_state: 'u32' },
			response: { hw_radio_state: 'u32', sw_radio_state: 'u32' },
			notification: { hw_radio_state: 'u32', sw_radio_state: 'u32' },
		},

		// Visible (scanned) providers (CID 8). The response is ProvidersCount +
		// a ref-struct-array of MbimProvider (variable structs carrying
		// ProviderId/ProviderName strings) which the InformationBuffer codec
		// cannot express; only the leading count is decoded (no op consumes the
		// provider list — defined for parity / manual callers).
		VISIBLE_PROVIDERS: {
			cid: 8,
			query: { action: 'u32' },   // MbimVisibleProvidersAction
			response: { providers_count: 'u32' },
		},

		SIGNAL_STATE: {
			cid: 11,
			response: {
				rssi: 'u32', error_rate: 'u32', signal_strength_interval: 'u32',
				rssi_threshold: 'u32', error_rate_threshold: 'u32',
			},
			notification: {
				rssi: 'u32', error_rate: 'u32', signal_strength_interval: 'u32',
				rssi_threshold: 'u32', error_rate_threshold: 'u32',
			},
		},

		// MBIMEx v2 Signal State (same CID 11) with per-RAT RSRP/SNR. Uses a
		// custom decode (see decode_signal_state_v2) since the ms-struct-array
		// tail is not codec-expressible. Look up by name — the shared CID is
		// resolved per-name in mbim_client.command.
		SIGNAL_STATE_V2: {
			cid: 11,
			query: {},
			decode: decode_signal_state_v2,
		},

		CONNECT: {
			cid: 12,
			set: {
				session_id: 'u32', activation_command: 'u32',
				access_string: 'string', user_name: 'string', password: 'string',
				compression: 'u32', auth_protocol: 'u32', ip_type: 'u32',
				context_type: 'uuid',
			},
			response: {
				session_id: 'u32', activation_state: 'u32', voice_call_state: 'u32',
				ip_type: 'u32', context_type: 'uuid', nw_error: 'u32',
			},
			notification: {
				session_id: 'u32', activation_state: 'u32', voice_call_state: 'u32',
				ip_type: 'u32', context_type: 'uuid', nw_error: 'u32',
			},
		},

		IP_CONFIGURATION: {
			cid: 15,
			query: { session_id: 'u32' },
			response: {
				session_id: 'u32',
				ipv4_available: 'u32', ipv6_available: 'u32',
				ipv4_count: 'u32',
				ipv4_addresses: { array: 'ipv4_count', of: { prefix: 'u32', address: 'ipv4' } },
				ipv6_count: 'u32',
				ipv6_addresses: { array: 'ipv6_count', of: { prefix: 'u32', address: 'ipv6' } },
				ipv4_gateway: 'ref-ipv4',
				ipv6_gateway: 'ref-ipv6',
				ipv4_dns_count: 'u32',
				ipv4_dns: { array: 'ipv4_dns_count', of: 'ipv4' },
				ipv6_dns_count: 'u32',
				ipv6_dns: { array: 'ipv6_dns_count', of: 'ipv6' },
				ipv4_mtu: 'u32', ipv6_mtu: 'u32',
			},
		},

		PACKET_STATISTICS: {
			cid: 20,
			response: {
				in_discards: 'u32', in_errors: 'u32',
				in_octets: 'u64', in_packets: 'u64',
				out_octets: 'u64', out_packets: 'u64',
				out_errors: 'u32', out_discards: 'u32',
			},
		},
	};

export default commands;
