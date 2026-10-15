// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — MBIM MS Voice Extensions schema: NITZ only.
//
// The native MBIM counterpart of QMI NAS NETWORK_TIME_IND and of +CTZV. The
// service name says "voice", but NITZ is the network's time and has nothing
// to do with calls; it is simply where Microsoft put it.
//
// Verified against libmbim 1.32.0:
//   UUID  src/libmbim-glib/mbim-uuid.c uuid_ms_voice_extensions =
//         { 8d 8b 9e ba } { 37 be } { 44 9b } { 8f 1e } { 61 cb 03 4a 70 2e }
//         -> "8d8b9eba-37be-449b-8f1e-61cb034a702e"
//   CID   src/libmbim-glib/mbim-cid.h MBIM_CID_MS_VOICE_EXTENSIONS_NITZ = 10
//   Body  data/mbim-service-ms-voice-extensions.json "NITZ": query empty;
//         response = notification = Year, Month, Day, Hour, Minute, Second,
//         TimeZoneOffsetMinutes, DaylightSavingTimeOffsetMinutes, DataClass,
//         all guint32.

'use strict';

export const SERVICE_UUID = '8d8b9eba-37be-449b-8f1e-61cb034a702e';
export const service = SERVICE_UUID;

const NITZ_FIELDS = {
	year: 'u32', month: 'u32', day: 'u32',
	hour: 'u32', minute: 'u32', second: 'u32',
	tz_offset_min: 'u32', dst_offset_min: 'u32', data_class: 'u32',
};

export const commands = {
	NITZ: {
		cid: 10,
		query: {},
		response: NITZ_FIELDS,
		notification: NITZ_FIELDS,
	},
};

// guint32 on the wire, but a zone WEST of Greenwich is negative minutes
// (libmbim declares the field unsigned and mbimcli prints it with %u, so it
// is no help here); 0xFFFFFFFF is what a modem without a zone sends, and
// reading it as -1 minute would be a wrong zone rather than none.
export function tz_minutes(v)
{
	if (v == null || v == 0xFFFFFFFF)
		return null;

	return (v >= 0x80000000) ? v - 0x100000000 : v;
};

export default commands;
