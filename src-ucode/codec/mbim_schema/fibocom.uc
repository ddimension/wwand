// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — MBIM Fibocom vendor service schema (AT command over MBIM).
//
// A single CID that tunnels a raw AT command line over the MBIM control channel:
// the request InformationBuffer is the bare AT string, the response buffer is the
// modem's raw AT output (result lines + final \r\nOK\r\n / \r\nERROR\r\n). This
// is the AT side channel for Fibocom (Foxconn) MBIM modems whose dedicated
// cdc-wdm AT port is absent or unresponsive — the MBIM analogue of the tty AT
// engine in atcmd.uc. The InformationBuffer is opaque bytes (not a schema
// struct), so the transport uses mbim_client.command_raw() with the raw AT
// bytes; `commands[]` exists only so mbim_client.on() could resolve the CID.
//
// Verified against libmbim 1.32.0:
//   UUID  src/libmbim-glib/mbim-uuid.c uuid_fibocom =
//         { ff ff ff ff } { ab ca } { 4b 11 } { a4 e2 } { f2 fc 87 f9 44 88 }
//         -> "ffffffff-abca-4b11-a4e2-f2fc87f94488"  (MBIM_SERVICE_FIBOCOM)
//   CID   src/libmbim-glib/mbim-cid.h MBIM_CID_FIBOCOM_AT_COMMAND = 1
//   Body  data/mbim-service-fibocom.json "AT Command": SET, request + response
//         both "unsized-byte-array" (CommandReq / CommandResp).
//
// NOT HW-validated (no Fibocom modem on hand) — opt-in only (see modem_mbim
// `option at_over_mbim`). NOTE the telemetry parsers (QENG/QNWINFO in
// modem_common) are Quectel-dialect and vendor-gated, so on a Fibocom modem this
// tunnel currently carries only the vendor-neutral AT (e.g. AT+CGMI identity);
// Fibocom-dialect telemetry parsers are a separate follow-up.

'use strict';

export const SERVICE_UUID = 'ffffffff-abca-4b11-a4e2-f2fc87f94488';
export const service = SERVICE_UUID;

export const CID_AT_COMMAND = 1;

// Fibocom sends AT Command as a SET (MBIM_CMD_SET); Compal uses QUERY.
export const AT_CMD_KIND = 'set';

export const commands = {
	AT_COMMAND: { cid: 1, notification: {} },
};

export default commands;
