// wwand — MBIM Basic Connect service schema (MBIM 1.0).
// Field layouts verified against libmbim data/mbim-service-basic-connect.json;
// CID numbers are the MBIM 1.0 standard values.

'use strict';

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

// MbimRegisterState
export const REGISTER_STATE_HOME = 1;
export const REGISTER_STATE_ROAMING = 2;
export const REGISTER_STATE_PARTNER = 3;

// MbimPacketServiceAction / State
export const PACKET_SERVICE_ATTACH = 0;
export const PACKET_SERVICE_STATE_ATTACHED = 2;

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
