// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI PDC service message schema (Persistent Device Configuration, 0x24).
//
// **Which carrier configuration (MBN) the modem is running, and switching it.**
//
// A Qualcomm modem ships several carrier configurations — the MBN blobs that
// carry a network's APN defaults, IMS settings, band and roaming policy — and
// picks one. Pick the wrong one and the modem is *technically* fine while
// behaving subtly wrong on that network: attach rejected, IMS absent, a band
// missing. Until now wwand could only nudge this through `AT+QMBNCFG`, which is
// Quectel's spelling and exists nowhere else; PDC is the protocol-native answer
// and works on any Qualcomm modem that exposes the service.
//
// Provenance: entirely **libqmi 1.38** (`data/qmi-service-pdc.json`, since
// 1.18), so every id and TLV here is citable — no proprietary source involved.
//
// The result TLV on the indications is **two** bytes (libqmi: "Indication
// Result", guint16). Decoded as four it comes back null on a real failure —
// and a null result reads as success, so a refused config selection would have
// been reported as done.
//
// THE SHAPE THAT MATTERS: PDC is indication-driven. A request is acknowledged
// almost empty, and the answer arrives later as an INDICATION carrying the same
// **token** the request sent. So every call needs a token, a handler, and a
// timeout — the request completing tells you nothing except that the modem
// accepted it. Same pattern as the long-APDU path in sim.uc, and the same trap:
// reading the response as the answer gets you an empty result that looks real.

'use strict';

// QmiPdcConfigurationType
export const CONFIG_TYPE_SOFTWARE = 0;   // the modem's own software config
export const CONFIG_TYPE_DEVICE   = 1;   // the carrier (MBN) config — what we mean

export const CONFIG_TYPES = { '0': 'software', '1': 'device' };

export default {
	service: 0x24,
	messages: {
		// Subscribe to the indications. Without this the modem accepts the
		// requests below and never reports anything, which reads as a modem
		// that does not support PDC.
		REGISTER: {
			id: 0x0020,
			req:  { enable: { t: 0x10, f: 'u8' } },
			resp: {},
		},

		// Ask for the list. The array comes back on the INDICATION.
		LIST_CONFIGS: {
			id: 0x0024,
			req: {
				token:  { t: 0x10, f: 'u32' },
				config_type: { t: 0x11, f: 'u32' },
			},
			resp: {},
		},

		LIST_CONFIGS_IND: {
			id: 0x0024,
			ind: {
				token:  { t: 0x10, f: 'u32' },
				result: { t: 0x01, f: 'u16' },
				// each id is an opaque blob — a hash the modem uses to name the
				// config. It is not text and must round-trip byte for byte.
				configs: { t: 0x11, f: { n: 'u8', of: {
					config_type: 'u32',
					id: { n: 'u8', of: 'u8' },
				} } },
			},
		},

		// Which one is active, and which is pending a reboot.
		// NOTE the config-type TLV id: **0x01** here, but **0x11** in
		// LIST_CONFIGS above. Same field, two ids — libqmi defines it as a
		// common-ref (0x01) that most messages share, while List Configs
		// carries its own inline definition at 0x11. Getting it wrong is not a
		// decode problem but a MISSING_ARGUMENT from the modem, which is how
		// this was found: the RG650E answered QMI error 17 to the version that
		// reused 0x11 here.
		GET_SELECTED_CONFIG: {
			id: 0x0022,
			req: {
				config_type: { t: 0x01, f: 'u32' },
				token:  { t: 0x10, f: 'u32' },
			},
			resp: {},
		},

		GET_SELECTED_CONFIG_IND: {
			id: 0x0022,
			ind: {
				token:      { t: 0x10, f: 'u32' },
				result:     { t: 0x01, f: 'u16' },
				active_id:  { t: 0x11, f: { n: 'u8', of: 'u8' } },
				// set when a switch has been made but not yet taken effect —
				// PDC changes need a modem reset before they apply
				pending_id: { t: 0x12, f: { n: 'u8', of: 'u8' } },
			},
		},

		// Human-readable detail for one config id: what it calls itself and
		// what version it is. This is what makes a list of hashes usable.
		GET_CONFIG_INFO: {
			id: 0x0028,
			req: {
				config: { t: 0x01, f: { config_type: 'u32', id: { n: 'u8', of: 'u8' } } },
				token:  { t: 0x10, f: 'u32' },
			},
			resp: {},
		},

		GET_CONFIG_INFO_IND: {
			id: 0x0028,
			ind: {
				token:       { t: 0x10, f: 'u32' },
				result:      { t: 0x01, f: 'u16' },
				total_size:  { t: 0x11, f: 'u32' },
				// 'lstring', not 'string': libqmi marks it
				// "size-prefix-format": "guint8", so the payload is one length
				// byte then the text. Read as a bare string it came back with a
				// control character glued to the front — HW on the RG650E:
				// "\u0013Commercial-DT-VOLTE", where 0x13 is 19, the length.
				description: { t: 0x12, f: 'lstring' },
				version:     { t: 0x13, f: 'u32' },
			},
		},

		// Select one. Takes effect after a modem reset — GET_SELECTED reports it
		// as `pending_id` until then, which is why the ubus op says so rather
		// than pretending the switch already happened.
		SET_SELECTED_CONFIG: {
			id: 0x0023,
			req: {
				config: { t: 0x01, f: { config_type: 'u32', id: { n: 'u8', of: 'u8' } } },
				token:  { t: 0x10, f: 'u32' },
			},
			resp: {},
		},

		SET_SELECTED_CONFIG_IND: {
			id: 0x0023,
			ind: {
				token:  { t: 0x10, f: 'u32' },
				result: { t: 0x01, f: 'u16' },
			},
		},

		// Deliberately NOT modelled: LOAD_CONFIG (0x26), ACTIVATE_CONFIG
		// (0x27), DELETE_CONFIG (0x25). Those WRITE or REMOVE carrier blobs on
		// the modem, and a wrong one there is not a misconfiguration but a
		// brick. wwand lists, reads and selects among what the vendor already
		// shipped; putting new blobs on a modem is a firmware operation and
		// belongs to a firmware tool.
	},
};
