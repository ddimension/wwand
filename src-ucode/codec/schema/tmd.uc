// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI TMD service message schema (Thermal Mitigation Device, 0x18).
//
// What this answers: **is the modem throttling itself, and which part of it.**
// Not a temperature — TMD deals in mitigation LEVELS per mitigation device
// ("pa", "modem", "cpuv_restriction_cold", …), each 0..max where 0 is
// unmitigated. A modem in level 3 on `pa` is deliberately cutting transmit
// power, which shows up to the user as throughput that collapsed for no
// visible reason while the signal bars stayed put.
//
// wwand already reads a temperature over `AT+QTEMP`, but that is Quectel's
// spelling of a Quectel-only command. TMD is protocol-native, works on any
// Qualcomm modem, and reports the modem's own DECISION rather than a number we
// would have to interpret. The two are complementary, so both are kept.
//
// Provenance: everything here — service id, all six message ids, every TLV id
// and the string encoding — comes from the GPL-2.0 kernel
// (`thermal_mitigation_device_service_v01.{h,c}`, `qmi_encdec.c`,
// `qmi_cooling.c`). No proprietary source was needed, so this whole file is
// citable upstream. libqmi knows the service id and models zero messages.
//
// The one wire detail that is easy to get wrong: a mitigation device id is a
// QMI_STRING nested inside a struct, and `qmi_encode_string_elem` writes a
// length prefix only when `enc_level != 1` — i.e. a nested string carries a
// 1-byte length and no NUL, while a string that IS the whole TLV payload
// carries no prefix at all. Every dev id below is nested, hence 'lstring'.

'use strict';

// Mitigation devices seen in the wild. Not an enum — the modem returns whatever
// its own thermal config defines, and GET_MITIGATION_DEVICE_LIST is the only
// authority. This table exists to make a log line readable, nothing more.
export const DEVICE_LABELS = {
	pa:                     'power amplifier',
	modem:                  'modem',
	modem_bw:               'modem bandwidth',
	modem_current:          'modem current draw',
	cpuv_restriction_cold:  'CPU voltage (cold)',
	vdd_restriction:        'VDD restriction',
	charging_disable:       'charging',
};

export function device_label(id)
{
	return DEVICE_LABELS[id ?? ''] ?? (id ?? 'unknown');
};

// Does a mitigation device throttle the RADIO, or is it reporting an
// environmental condition that happens to use the same interface?
//
// This distinction is not academic and it was not obvious: HW on the NR7101
// (RG502Q) shows `cpr_cold` sitting at level 1 of 3 on a perfectly healthy
// modem — Core Power Reduction for LOW temperature, i.e. the modem noting that
// it is cold, which is a normal operating state and costs no throughput.
// Treating it as "the modem is throttling itself" would put a permanent warning
// on the status page of a box that is working fine.
//
// A denylist rather than an allowlist, because device names are per-modem: the
// RG650E has 28 and the RG502Q 19, with only partial overlap, and new ones must
// default to "this is about the radio" so a real thermal event is never missed.
const ENVIRONMENTAL = [
	/_cold$/,       // cpr_cold, cpuv_restriction_cold — low-temperature limits
	/^cpr/,         // core power reduction
	/^cpuv/,        // CPU voltage restriction
	/^vbatt/,       // battery voltage
	/^charge/,      // charging state
	/^bcl$/,        // battery current limit
	/^wlan/,        // the Wi-Fi side of a combo SoC, not the cellular link
];

export function is_rf_device(id)
{
	for (let re in ENVIRONMENTAL)
		if (match(id ?? '', re))
			return false;

	return true;
};

export default {
	service: 0x18,
	messages: {
		// Which mitigation devices this modem has, and how far each can be
		// driven. Request carries no TLVs at all.
		GET_MITIGATION_DEVICE_LIST: {
			id: 0x0020,
			req: {},
			resp: {
				devices: { t: 0x10, f: { n: 'u8', of: {
					dev_id: 'lstring', max_level: 'u8' } } },
			},
		},

		// Read one device's level. `current` is where it is; `requested` is
		// where something asked it to be — they differ while a change is in
		// flight, and a persistent gap means the modem declined.
		GET_MITIGATION_LEVEL: {
			id: 0x0022,
			req:  { device: { t: 0x01, f: { dev_id: 'lstring' } } },
			resp: {
				current:   { t: 0x10, f: 'u8' },
				requested: { t: 0x11, f: 'u8' },
			},
		},

		// Push instead of poll: register per device, then MITIGATION_LEVEL_REPORT
		// arrives on every change.
		REGISTER_NOTIFICATION: {
			id: 0x0023,
			req:  { device: { t: 0x01, f: { dev_id: 'lstring' } } },
			resp: {},
		},

		DEREGISTER_NOTIFICATION: {
			id: 0x0024,
			req:  { device: { t: 0x01, f: { dev_id: 'lstring' } } },
			resp: {},
		},

		MITIGATION_LEVEL_REPORT_IND: {
			id: 0x0025,
			ind: {
				device: { t: 0x01, f: { dev_id: 'lstring' } },
				level:  { t: 0x02, f: 'u8' },
			},
		},

		// Deliberately NOT modelled: SET_MITIGATION_LEVEL (0x0021). It exists and
		// its layout is known, but wwand has no business *imposing* thermal
		// mitigation on a modem — the modem's own thermal management is the
		// authority, and a host that overrides it can cook the hardware. This is
		// a read-and-report interface on purpose.
	},
};
