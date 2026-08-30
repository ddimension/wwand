// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI CAT service message schema (Card Application Toolkit, 0x0A).
//
// Only the configuration pair, and for one reason: **a headless CPE has no UI.**
//
// SIM Application Toolkit lets the operator push SETUP MENU, DISPLAY TEXT,
// PLAY TONE and friends at the terminal, and the terminal answers with a
// TERMINAL PROFILE saying what it can honour. A modem in its default mode
// advertises a phone's profile — because that is what the modem was designed
// into — and then an operator OTA campaign sends a proactive command that
// nothing on this box will ever render or answer. The card waits, and a card
// waiting on a terminal response is a card that can stall.
//
// So this is a way to tell the truth: either DISABLED (0x00), an explicit "do
// not route toolkit to a control point at all", or one of the custom modes with
// a terminal profile that claims only what we can actually do.
//
// wwand does NOT set this by itself. The default is to leave the modem exactly
// as the vendor configured it — changing toolkit behaviour unasked could break
// a working deployment in ways that only show up on one operator's network.
// It is a config knob (`option cat_mode`), applied read-before-write.
//
// Provenance: the service id (0x0A) and the message list 0x0020-0x002E are
// openly attested — ofono has `#define QMI_SERVICE_CAT 10`, and the old Gobi
// `eQMIMessageCAT` enumerates the messages. libqmi ships no CAT json at all, so
// it models none of this. The TLV widths below are device-observed.
//
// One width that must not be guessed: `cat_config_mode` is declared in C as a
// 32-bit enum (the -2147483647 forcing idiom) but the IDL encodes it as
// QMI_IDL_1_BYTE_ENUM — ONE byte on the wire. Reading the C declaration and
// assuming four would have silently swallowed the TLV behind it.

'use strict';

// cat_config_mode_enum
export const MODE_DISABLED         = 0x00;   // toolkit not routed to a control point
export const MODE_GOBI             = 0x01;
export const MODE_ANDROID          = 0x02;
export const MODE_DECODED          = 0x03;
export const MODE_DECODED_PULLONLY = 0x04;
export const MODE_CUSTOM_RAW       = 0x05;   // custom terminal profile, raw format
export const MODE_CUSTOM_DECODED   = 0x06;   // custom terminal profile, decoded

// what `option cat_mode` accepts, and what it means on the wire
export const MODES = {
	disabled:         MODE_DISABLED,
	gobi:             MODE_GOBI,
	android:          MODE_ANDROID,
	decoded:          MODE_DECODED,
	decoded_pullonly: MODE_DECODED_PULLONLY,
	custom_raw:       MODE_CUSTOM_RAW,
	custom_decoded:   MODE_CUSTOM_DECODED,
};

export const MODE_NAMES = {
	'0': 'disabled', '1': 'gobi', '2': 'android', '3': 'decoded',
	'4': 'decoded_pullonly', '5': 'custom_raw', '6': 'custom_decoded',
};

export function mode_name(v)
{
	return MODE_NAMES[sprintf('%d', v ?? -1)] ?? sprintf('unknown (%d)', v ?? -1);
};

export default {
	service: 0x0A,
	messages: {
		GET_CONFIGURATION: {
			id: 0x002E,
			req: {},
			resp: {
				mode:      { t: 0x10, f: 'u8' },
				// ETSI TS 102 223 §5.2 bitmask; only meaningful in the custom modes
				custom_tp: { t: 0x11, f: { n: 'u8', of: 'u8' } },
			},
		},

		SET_CONFIGURATION: {
			id: 0x002D,
			req: {
				mode:      { t: 0x01, f: 'u8' },
				custom_tp: { t: 0x10, f: { n: 'u8', of: 'u8' } },
			},
			resp: {},
		},
	},
};
