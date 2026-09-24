// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — MBIM Basic Connect service schema (MBIM 1.0).
// Field layouts verified against libmbim data/mbim-service-basic-connect.json;
// CID numbers are the MBIM 1.0 standard values.

'use strict';

import * as struct from 'struct';
import * as mbimcodec from 'wwand.codec.mbim';

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
export const READY_STATE_NOT_INITIALIZED = 0;
export const READY_STATE_INITIALIZED     = 1;
export const READY_STATE_SIM_NOT_INSERTED = 2;

// MbimStatusError (message-level status in the MBIM_COMMAND_DONE header;
// verified vs libmbim mbim-errors.h): 3 = the operation needs a SIM and none
// is inserted — HW-hit answering a PIN query on a SIM-less RM520N-GL.
export const STATUS_SIM_NOT_INSERTED = 3;
export const READY_STATE_BAD_SIM         = 3;
export const READY_STATE_FAILURE         = 4;
export const READY_STATE_NOT_ACTIVATED   = 5;
export const READY_STATE_DEVICE_LOCKED   = 6;

export const READY_STATE_NAMES = {
	'0': 'not initialized', '1': 'initialized', '2': 'SIM not inserted',
	'3': 'bad SIM', '4': 'failure', '5': 'not activated', '6': 'device locked',
};

// MbimPinType / MbimPinState (values verified against libmbim mbim-enums.h)
export const PIN_TYPE_PIN1 = 2;
export const PIN_TYPE_PIN2 = 3;
export const PIN_TYPE_NETWORK_PIN = 6;        // 6..9 = personalization locks
export const PIN_TYPE_CORPORATE_PIN = 9;
export const PIN_TYPE_PUK1 = 11;
export const PIN_TYPE_PUK2 = 12;
export const PIN_STATE_UNLOCKED = 0;
export const PIN_STATE_LOCKED = 1;
export const PIN_OP_ENTER = 0;

// config pdp_type / auth -> MBIM enums — ONE table for both users (the
// CONNECT path in context_mbim and the LTE attach path in modem_mbim), so
// the deliberate 'both'->CHAP collapse can never drift between them.
export const IP_TYPE_FROM_PDP = {
	ipv4: IP_TYPE_IPV4, ipv6: IP_TYPE_IPV6, ipv4v6: IP_TYPE_IPV4V6,
};
export const AUTH_FROM_CFG = {
	none: AUTH_NONE, pap: AUTH_PAP, chap: AUTH_CHAP, both: AUTH_CHAP,
};


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
};

// SUBSCRIBER_READY_STATUS comes in two shapes; see the note at the command.
const RDY_V1 = {
	ready_state: 'u32', subscriber_id: 'string', sim_iccid: 'string',
	ready_info: 'u32', telephone_numbers_count: 'u32',
};

const RDY_V3 = {
	ready_state: 'u32', flags: 'u32', subscriber_id: 'string', sim_iccid: 'string',
	ready_info: 'u32', telephone_numbers_count: 'u32',
};

// THE pairing of version to layout. Exposed on the command as `response_for`
// so that anything which has to produce this buffer rather than read it — the
// test mock, above all — derives the layout from the same place the decoder
// does. A mock that hard-codes one layout while the client picks the other
// tests nothing and fails confusingly.
function rdy_fields(mc)
{
	return mbimcodec.mbimex_v3(mc) ? RDY_V3 : RDY_V1;
}

// MbimProviderState, the bits that say what a scanned operator IS to this SIM
// (mbim-enums.h, libmbim 1.32.0).
export const REGISTER_ACTION_AUTOMATIC = 0;
export const REGISTER_ACTION_MANUAL    = 1;

export const PROVIDER_STATE_HOME       = 1 << 0;
export const PROVIDER_STATE_FORBIDDEN  = 1 << 1;
export const PROVIDER_STATE_PREFERRED  = 1 << 2;
export const PROVIDER_STATE_VISIBLE    = 1 << 3;
export const PROVIDER_STATE_REGISTERED = 1 << 4;
export const PROVIDER_STATE_PREFERRED_MULTICARRIER = 1 << 5;

// VISIBLE_PROVIDERS (cid 8) — a scanned operator list, which the field-spec
// codec cannot express: ProvidersCount then a ref-struct-array of MbimProvider,
// each of which carries two STRINGS of its own.
//
// Two offset bases, and getting them the wrong way round is the classic way to
// decode this into garbage that still looks like data:
//   - the (offset, size) pairs of the ARRAY are relative to the information
//     buffer, like every other ref-struct-array here;
//   - the (offset, size) pairs of the two strings INSIDE a provider are
//     relative to THAT PROVIDER's start. libmbim reads the pair at
//     `information_buffer_offset + relative_offset` and the data at
//     `information_buffer_offset + struct_start_offset + offset`
//     (mbim-message.c:553-565, 1.32.0, checked 2026-09-20).
//
// MbimProvider fixed part (mbim-service-basic-connect.json:189-205): ProviderId
// (string pair), ProviderState u32, ProviderName (string pair), CellularClass
// u32, Rssi u32, ErrorRate u32 — 32 bytes, then the string data.
//
// Returns { operators: [...] } in the same shape the QMI NAS scan produces, so
// the ubus API and LuCI need no second vocabulary.
export function decode_visible_providers(info)
{
	let buf = info ?? '';

	if (length(buf) < 4)
		return { operators: [] };

	let n = struct.unpack('<I', substr(buf, 0, 4))[0];

	if (length(buf) < 4 + n * 8)
		return { operators: [] };

	// A STRING BELONGS TO ITS OWN PROVIDER. Bounding it against the whole
	// information buffer only stops a read off the end — it lets a malformed
	// record point at the fixed fields, the pair table, or the NEXT provider's
	// name, and the result is a wrong operator that looks exactly like a right
	// one. So it must start past this record's 32-byte fixed part, end inside
	// this record, and carry an even number of bytes, because UTF-16LE does.
	let str_at = (base, len, rel) => {
		if (base + rel + 8 > length(buf))
			return null;

		let off = struct.unpack('<I', substr(buf, base + rel, 4))[0];
		let size = struct.unpack('<I', substr(buf, base + rel + 4, 4))[0];

		if (size == 0)
			return null;

		if (off < 32 || size % 2 != 0 || off + size > len)
			return null;

		return mbimcodec.utf16le_decode(substr(buf, base + off, size));
	};

	let out = [];

	for (let i = 0; i < n; i++) {
		let off = struct.unpack('<I', substr(buf, 4 + i * 8, 4))[0];
		let len = struct.unpack('<I', substr(buf, 8 + i * 8, 4))[0];

		// an entry that does not fit, or is shorter than its own fixed part,
		// ends the list rather than being guessed at
		if (off < 4 + n * 8 || len < 32 || off + len > length(buf))
			break;

		let state = struct.unpack('<I', substr(buf, off + 8, 4))[0];
		let id = str_at(off, len, 0);

		// The PLMN comes as the concatenated digits ('26201' / '262011'), which
		// is what the QMI side reports as mcc/mnc — split it the same way so one
		// renderer serves both. A 6-digit id is a 3-digit MNC.
		//
		// EXACTLY five or six DIGITS, not "at least five": a longer id would
		// produce an mnc_digits of 4 and a non-numeric one would be coerced to
		// a number, and both would then travel as a usable scan result. An id
		// that is not a PLMN leaves the three fields absent and keeps the name
		// — which is still the useful half.
		let plmn = match(id ?? '', /^([0-9][0-9][0-9])([0-9][0-9][0-9]?)$/);

		push(out, {
			mcc: plmn ? +plmn[1] : null,
			mnc: plmn ? +plmn[2] : null,
			mnc_digits: plmn ? length(plmn[2]) : null,
			provider_id: id,
			description: str_at(off, len, 12),
			// the QMI scan's status bits, filled from what MBIM actually says
			// rather than invented: anything it does not report stays absent.
			home: !!(state & PROVIDER_STATE_HOME),
			forbidden: !!(state & PROVIDER_STATE_FORBIDDEN),
			preferred: !!(state & PROVIDER_STATE_PREFERRED),
			registered: !!(state & PROVIDER_STATE_REGISTERED),
			cellular_class: struct.unpack('<I', substr(buf, off + 20, 4))[0],
		});
	}

	return { operators: out };
};

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

		// v3 INSERTS `Flags` AFTER ReadyState, which moves SubscriberId and
		// SimIccId four bytes along. Reading a v3 answer with the v1 layout
		// takes Flags for the SubscriberId offset and yields nothing: an
		// RM520N-GL reported an empty imsi/iccid for exactly this reason while
		// AT+CIMI and the UICC slot query both read the card fine. libmbim
		// 1.32.0, mbim-service-ms-basic-connect-v3.json. Found 2026-09-19.
		//
		// WHICH LAYOUT APPLIES IS DECIDED PER MODEM, not once for the tree. The
		// mistake worth naming: the v3 field was briefly unconditional, on the
		// reasoning that a v1 answer simply would not carry it and `string`
		// reads its offsets out of the buffer anyway. It does — but the FIXED
		// part is positional, so on a v1 buffer `flags` eats the SubscriberId
		// offset and every field after it shifts by one. The result is not an
		// obvious failure: the imsi comes back MISSING ITS FIRST DIGIT and the
		// iccid null (measured). Same class as BASE_STATIONS_INFO in the ext
		// schema — see the note there.
		SUBSCRIBER_READY_STATUS: {
			cid: 2,
			response: RDY_V1,
			notification: RDY_V1,
			response_for: rdy_fields,
			decode: (info, mc) => mbimcodec.decode_info(rdy_fields(mc), info),
		},

		PIN: {
			cid: 4,
			set: { pin_type: 'u32', pin_operation: 'u32', pin: 'string', new_pin: 'string' },
			response: { pin_type: 'u32', pin_state: 'u32', remaining_attempts: 'u32' },
		},

		// MbimRegisterAction (mbim-enums.h, libmbim 1.32.0)
		REGISTER_STATE: {
			cid: 9,
			// ProviderId (string), RegisterAction, DataClass
			// (mbim-service-basic-connect.json:260-270). DataClass 0 = "any",
			// which is what a selection that says nothing about RAT means.
			set: { provider_id: 'string', register_action: 'u32', data_class: 'u32' },
			// preferred_data_classes is the MBIMEx v2 addition, APPENDED after
			// the v1 nine (libmbim 1.32.0, mbim-service-ms-basic-connect-v2.json,
			// checked 2026-09-20) — so the same layout reads both and a v1 modem
			// answers null for it. What the network PREFERS, as against
			// available_data_classes, which is what it offers.
			response: {
				nw_error: 'u32', register_state: 'u32', register_mode: 'u32',
				available_data_classes: 'u32', current_cellular_class: 'u32',
				provider_id: 'string', provider_name: 'string',
				roaming_text: 'string', registration_flag: 'u32',
				preferred_data_classes: 'u32',
			},
			notification: {
				nw_error: 'u32', register_state: 'u32', register_mode: 'u32',
				available_data_classes: 'u32', current_cellular_class: 'u32',
				provider_id: 'string', provider_name: 'string',
				roaming_text: 'string', registration_flag: 'u32',
				preferred_data_classes: 'u32',
			},
		},

		// The three trailing fields are MBIMEx additions and are APPENDED, not
		// inserted — the v1 five are an exact byte prefix of the v3 eight
		// (libmbim 1.32.0, mbim-service-ms-basic-connect-v3.json vs
		// -basic-connect.json, checked 2026-09-20). So one layout serves every
		// version: a modem that speaks v1 simply stops after downlink_speed and
		// the decoder answers null for the rest, which is what absent means.
		//
		// `data_subclass` is the one worth having. MbimDataSubclass is a
		// bitmask — 5G_ENDC / 5G_NR / 5G_NEDC / 5G_ELTE / 5G_NGENDC — so it
		// says NSA from SA outright, where the telemetry otherwise infers it.
		// `tai` is MbimTai inline (PlmnMcc u16, PlmnMnc u16, Tac u32), which is
		// why the codec needed a u16.
		//
		// NOTE for v2: that version names the third field CurrentDataClass
		// rather than HighestAvailableDataClass. Same position, same width —
		// the decode is right either way, the NAME is optimistic on a v2 modem.
		PACKET_SERVICE: {
			cid: 10,
			set: { packet_service_action: 'u32' },
			response: {
				nw_error: 'u32', packet_service_state: 'u32',
				highest_available_data_class: 'u32',
				uplink_speed: 'u64', downlink_speed: 'u64',
				frequency_range: 'u32', data_subclass: 'u32',
				tai_mcc: 'u16', tai_mnc: 'u16', tai_tac: 'u32',
			},
			notification: {
				nw_error: 'u32', packet_service_state: 'u32',
				highest_available_data_class: 'u32',
				uplink_speed: 'u64', downlink_speed: 'u64',
				frequency_range: 'u32', data_subclass: 'u32',
				tai_mcc: 'u16', tai_mnc: 'u16', tai_tac: 'u32',
			},
		},

		// MbimRadioSwitchState hardware/software radio state (CID 3).
		RADIO_STATE: {
			cid: 3,
			// query carries no payload; the response is the same pair as the
			// notification (mbim-service-basic-connect.json, libmbim 1.32:
			// query is empty, response is HwRadioState + SwRadioState)
			query: {},
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
			decode: decode_visible_providers,
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

		// WHAT THE MODEM MAY TELL US UNASKED. Without this the modem uses its
		// own default set, and on the RM520N-GL that set is nearly empty:
		// measured over four minutes of a live connection (GL-X3000,
		// 2026-09-20), the ONLY indications that arrived were CONNECT and
		// LTE_ATTACH_INFO — no SIGNAL_STATE, no REGISTER_STATE, no
		// PACKET_SERVICE, no SUBSCRIBER_READY_STATUS. Every `on()` this daemon
		// registers for those was listening to silence, and the telemetry that
		// should have been event-driven was carried entirely by polling.
		//
		// Encoded by hand: the payload is a ref-struct-array of
		// variable-length entries, which the field-spec codec does not express
		// (mbimmod.encode_subscribe_list / decode_subscribe_list, layout from
		// libmbim 1.32.0 mbim-service-basic-connect.json:699-724).
		DEVICE_SERVICE_SUBSCRIBE_LIST: {
			cid: 19,
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
