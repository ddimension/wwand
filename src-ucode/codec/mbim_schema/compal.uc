// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — MBIM Compal vendor service schema (AT command over MBIM).
//
// Sibling of fibocom.uc: the Compal vendor CID also tunnels a raw AT line, but
// issues it as a QUERY (not a SET). Same opaque-byte InformationBuffer, same
// engine (mbim_backend.make_at_engine) — only the service UUID and command type
// differ. Compal-branded modules are rebadged Foxconn/Fibocom parts found in a
// few laptop SKUs.
//
// Verified against libmbim 1.32.0:
//   UUID  src/libmbim-glib/mbim-uuid.c uuid_compal =
//         { a2 a3 2a 97 } { ca b1 } { 4f 57 } { 9a e1 } { 45 1c 74 dd a9 57 }
//         -> "a2a32a97-cab1-4f57-9ae1-451c74dda957"  (MBIM_SERVICE_COMPAL)
//   CID   src/libmbim-glib/mbim-cid.h MBIM_CID_COMPAL_AT_COMMAND = 1
//   Body  data/mbim-service-compal.json "AT Command": QUERY, request +
//         response "unsized-byte-array" (CommandReq / CommandResp).
//
// NOT HW-validated (no Compal modem on hand) — opt-in only.

'use strict';

export const SERVICE_UUID = 'a2a32a97-cab1-4f57-9ae1-451c74dda957';
export const service = SERVICE_UUID;

export const CID_AT_COMMAND = 1;

// Compal issues AT Command as a QUERY (MBIM_CMD_QUERY), unlike Fibocom's SET.
export const AT_CMD_KIND = 'query';

export const commands = {
	AT_COMMAND: { cid: 1, notification: {} },
};

export default commands;
