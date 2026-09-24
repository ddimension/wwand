// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — native-MBIM protocol backend.
//
// The MBIM implementations of the protocol-neutral telemetry operations, the
// MBIM sibling of qmi_backend.uc. Each op takes the MBIM session client `mc`
// (mbim_client.uc — `mc.command(schema, name, kind, args, cb, opts)`) plus a
// callback, and returns data already normalized into the SAME shapes the QMI
// backend / NAS schema produce (modem `self.signal` and `self.cells`), so the
// daemon's modem_signal / modem_cells surface either backend unchanged. An op
// never touches modem `self` state.
//
// Signal metrics come in two MBIM flavors, mirrored to the two QMI unit
// conventions the daemon already renders:
//   - self.signal  (QMI GET_SIGNAL_INFO): RSRP/RSSI in whole dBm, SNR in 0.1 dB.
//     MBIM v2 Signal State reports CODED indices -> converted here.
//   - self.cells   (QMI GET_CELL_LOCATION_INFO): every metric in 0.1 dB units.
//     MBIM Base Stations Info uses TWO conventions in one message: LTE metrics
//     are signed dBm/dB, NR metrics are unsigned coded indices. Both are
//     converted to 0.1 dB units here. Reading NR with LTE's rule is what
//     ddimension/wwand#30 turned up.
//
// There is no native MBIM carrier-aggregation CID, so there is no get_ca here —
// CA stays passthrough/AT in the core.

'use strict';

import * as struct from 'struct';
import * as mbim from 'wwand.codec.mbim';
import * as hexmod from 'wwand.codec.hex';
import * as bc from 'wwand.codec.mbim_schema.basic_connect';
import * as ext from 'wwand.codec.mbim_schema.ms_basic_connect_ext';
import * as fibocom from 'wwand.codec.mbim_schema.fibocom';
import * as compal from 'wwand.codec.mbim_schema.compal';

// --- native MBIM MS UICC Low Level Access (eSIM/APDU) ------------------------
// Service UUID + CIDs and buffer layouts verified against libmbim 1.32
// (mbim-service-ms-uicc-low-level-access + the generated builder) and the lpac
// mbim apdu driver. A `uicc-ref-byte-array` field is a [length, offset] pair
// (swapped) in the fixed region with the bytes appended (4-byte padded) in the
// variable region, the offset absolute from the start of the InformationBuffer.
const UICC_SERVICE = 'c2f6588e-f037-4bc9-8665-f4d44bd09367';
const UICC_CID_OPEN_CHANNEL = 2;
const UICC_CID_CLOSE_CHANNEL = 3;
const UICC_CID_APDU = 4;
const UICC_CID_RESET = 6;
const UICC_PASS_THROUGH_DISABLE = 0;   // modem resumes normal UICC use after reset
// lpac's proven parameters
const UICC_CHANNEL_GROUP = 1;
const UICC_SECURE_MESSAGING_NONE = 0;
const UICC_CLASS_BYTE_INTER_INDUSTRY = 1;

// zero-pad a byte string up to the next 4-byte boundary
function pad4(s)
{
	for (let need = (4 - length(s) % 4) % 4; need > 0; need--)
		s += chr(0);

	return s;
}

// --- AT over MBIM (Fibocom / Compal vendor CID) ------------------------------
// A drop-in AT engine (same { send, run_sequence, close } contract as the tty
// engine in atcmd.uc) that tunnels each AT line over a vendor MBIM CID instead
// of a serial port — for MBIM modems whose dedicated cdc-wdm AT port is absent
// or dead. Unlike the streaming tty, the vendor CID is request/response: one
// COMMAND carries the AT line, one COMMAND_DONE returns the whole modem reply,
// so a single round trip yields the complete { lines } result.

// parse a raw AT response blob into the same `lines` array the tty engine yields
// (atcmd.uc finish): CR/LF split, trim, drop blanks + the command echo, stop at
// OK/ERROR/+CME|CMS ERROR. Returns { err, lines } (err null on OK).
function at_parse_response(cmd, blob)
{
	let lines = [];

	// normalize CR-only and CRLF to LF, then split
	let norm = replace(replace(sprintf('%s', blob ?? ''), /\r\n/g, '\n'), /\r/g, '\n');

	for (let line in split(norm, '\n')) {
		line = trim(line);

		if (line == '' || line == cmd)     // skip blanks and echo
			continue;

		if (line == 'OK')
			return { err: null, lines: lines };

		if (line == 'ERROR' || line == 'COMMAND NOT SUPPORT')
			return { err: { error: 'ERROR' }, lines: lines };

		let m = match(line, /^\+(CME|CMS) ERROR: *(.*)$/);

		if (m)
			return { err: { error: lc(m[1]), code: m[2] }, lines: lines };

		push(lines, line);
	}

	// no terminator seen: return what we have (best-effort, like a short read)
	return { err: null, lines: lines };
}

// make_at_engine(mc, vendor): vendor is 'fibocom' (default) or 'compal'. Returns
// a duck-typed AT engine. A modem that does not expose the vendor CID NAKs the
// COMMAND -> command_raw yields an mbim error -> send() reports it, exactly like
// a no-AT tty modem, so callers degrade gracefully.
export function make_at_engine(mc, vendor)
{
	let schema = (vendor == 'compal') ? compal : fibocom;
	let cmd_type = (schema.AT_CMD_KIND == 'query') ? mbim.CMD_QUERY : mbim.CMD_SET;

	let self = {};

	self.send = function(cmd, cb, o) {
		// the request InformationBuffer is the bare AT line, CR-terminated
		let req = cmd + '\r';

		mc.command_raw(schema.service, schema.CID_AT_COMMAND, req, (err, info) => {
			if (err)
				return cb ? cb(err, null) : null;

			let r = at_parse_response(cmd, info);

			if (cb)
				cb(r.err, { lines: r.lines });
		}, { cmd_type: cmd_type, timeout: o?.timeout });
	};

	// best-effort sequential run (errors logged by the caller's cb), matching the
	// tty engine's run_sequence contract.
	self.run_sequence = function(cmds, done) {
		let idx = 0, step;

		step = () => {
			if (idx >= length(cmds))
				return done ? done() : null;

			self.send(cmds[idx++], () => step());
		};

		step();
	};

	self.close = () => null;

	return self;
};

// open a logical channel to `aid_hex` (ISD-R for eSIM). cb(err, { channel,
// select_response }). `mc` is the MBIM session client (mbim_client.uc).
export function uicc_open_channel(mc, aid_hex, cb)
{
	let aid = hexmod.hex_to_bin(aid_hex);
	// [ AppIdLength, AppIdOffset(=16), SelectP2Arg(0), ChannelGroup(1) ] + AppId
	let info = struct.pack('<IIII', length(aid), 16, 0, UICC_CHANNEL_GROUP) + pad4(aid);

	mc.command_raw(UICC_SERVICE, UICC_CID_OPEN_CHANNEL, info, (err, resp) => {
		if (err)
			return cb(err, null);

		if (length(resp) < 16)
			return cb({ error: 'uicc_short' }, null);

		let status  = struct.unpack('<I', substr(resp, 0, 4))[0];
		let channel = struct.unpack('<I', substr(resp, 4, 4))[0];
		let rlen    = struct.unpack('<I', substr(resp, 8, 4))[0];
		let roff    = struct.unpack('<I', substr(resp, 12, 4))[0];
		let sel = (roff && rlen && roff + rlen <= length(resp)) ? substr(resp, roff, rlen) : '';

		cb(null, { channel: channel, select_response: hexmod.bin_to_hex(sel), status: status });
	});
};

// transmit `apdu_hex` on `channel`. cb(err, response_hex) where the response
// carries the card data followed by SW1 SW2 (reconstructed from the MBIM Status
// field, exactly as lpac does — the QMI SEND_APDU path returns SW inline too).
export function uicc_apdu(mc, channel, apdu_hex, cb)
{
	let cmd = hexmod.hex_to_bin(apdu_hex);
	// [ Channel, SecureMessaging, ClassByteType, CommandLength, CommandOffset(=20) ] + Command
	let info = struct.pack('<IIIII', channel, UICC_SECURE_MESSAGING_NONE,
		UICC_CLASS_BYTE_INTER_INDUSTRY, length(cmd), 20) + pad4(cmd);

	mc.command_raw(UICC_SERVICE, UICC_CID_APDU, info, (err, resp) => {
		if (err)
			return cb(err, null);

		if (length(resp) < 12)
			return cb({ error: 'uicc_short' }, null);

		let status = struct.unpack('<I', substr(resp, 0, 4))[0];
		let rlen   = struct.unpack('<I', substr(resp, 4, 4))[0];
		let roff   = struct.unpack('<I', substr(resp, 8, 4))[0];
		let data = (roff && rlen && roff + rlen <= length(resp)) ? substr(resp, roff, rlen) : '';

		// append SW1 SW2 from the status word (low byte, then high byte)
		let full = data + chr(status & 0xff) + chr((status >> 8) & 0xff);

		cb(null, hexmod.bin_to_hex(full));
	});
};

// close a logical channel. cb(err)
export function uicc_close_channel(mc, channel, cb)
{
	let info = struct.pack('<II', channel, UICC_CHANNEL_GROUP);

	mc.command_raw(UICC_SERVICE, UICC_CID_CLOSE_CHANNEL, info, (err) => cb(err ?? null));
};

// UICC reset — power-cycle the card at MBIM level (the "apply" after an eSIM
// profile switch on a pure-MBIM modem). PassThroughAction=disable: reset the
// card and let the modem resume normal UICC operation. Verified vs libmbim
// 1.32 (Reset since 1.26; set = PassThroughAction u32, response =
// PassThroughStatus u32). cb(err)
export function uicc_reset(mc, cb)
{
	let info = struct.pack('<I', UICC_PASS_THROUGH_DISABLE);

	mc.command_raw(UICC_SERVICE, UICC_CID_RESET, info, (err) => cb(err ?? null));
};

// --- native MBIM multi-slot (MS BCE SYS_CAPS / SLOT_INFO_STATUS / -----------
// --- DEVICE_SLOT_MAPPINGS) — the sim.uc slot fallback for pure-MBIM modems ---

// MbimUiccSlotState → the QMI-shaped card vocabulary sim.uc surfaces
const SLOT_STATES = {
	'0': { card: 'unknown' },
	'1': { card: 'absent' },                    // powered off, no card
	'2': { card: 'present' },                   // powered off
	'3': { card: 'absent' },
	'4': { card: 'present' },                   // occupied, card not ready yet
	'5': { card: 'present' },
	'6': { card: 'error' },
	'7': { card: 'present', is_euicc: true },   // eSIM, active profile
	'8': { card: 'present', is_euicc: true },   // eSIM, no active profile
};

// slot list in the exact shape sim.uc's QMI GET_SLOT_STATUS path produces.
// SYS_CAPS gives the slot count, DEVICE_SLOT_MAPPINGS the active slot of
// executor 0, SLOT_INFO_STATUS (sequential, 0-based) the per-slot card state.
// The native CIDs carry no per-slot ICCID/EID — those stay null (the caller
// may fill the active slot's identity from the modem info).
// Ask MS Basic Connect Extensions how many cellular stacks this modem has and
// how many may run at once — the question QMI has no message for. Standalone,
// because on a modem that carries the QMI-over-MBIM passthrough the slot list
// comes from QMI-UIM and slot_status() below is never reached, which would
// otherwise leave the only exact source unread.
export function sys_caps(mc, cb)
{
	mc.command(ext, 'SYS_CAPS', 'query', {}, (err, caps) => {
		if (err || !caps)
			return cb(err ?? { error: 'unsupported' }, null);

		cb(null, {
			number_of_executors: caps.number_of_executors ?? null,
			number_of_slots: caps.number_of_slots ?? null,
			concurrency: caps.concurrency ?? null,
			modem_id: caps.modem_id ?? null,
		});
	});
};

export function slot_status(mc, cb)
{
	mc.command(ext, 'SYS_CAPS', 'query', {}, (err, caps) => {
		if (err)
			return cb(err, null);

		let n = caps?.number_of_slots ?? 0;

		if (n < 1)
			return cb({ error: 'unsupported' }, null);

		// SYS_CAPS answers what QMI cannot be asked: how many cellular stacks
		// this modem has and how many may run at once. We only need the slot
		// count here, but throwing the rest away would discard the only exact
		// source either protocol has for it — hand it to the caller.
		mc._multisim_caps = {
			number_of_executors: caps?.number_of_executors ?? null,
			number_of_slots: n,
			concurrency: caps?.concurrency ?? null,
			modem_id: caps?.modem_id ?? null,
		};

		mc.command(ext, 'DEVICE_SLOT_MAPPINGS', 'query', {}, (merr, mapping) => {
			let active = merr ? null : mapping?.slots?.[0];
			let out = [];
			let step;

			step = (i) => {
				if (i >= n)
					return cb(null, out);

				mc.command(ext, 'SLOT_INFO_STATUS', 'query', { slot_index: i }, (serr, si) => {
					let st = serr ? null : SLOT_STATES[sprintf('%d', si?.state ?? 0)];

					push(out, {
						physical: i + 1,
						card: st?.card ?? 'unknown',
						active: (active != null) ? (i == active) : false,
						logical_slot: (active != null && i == active) ? 1 : null,
						iccid: null,
						is_euicc: !!st?.is_euicc,
						eid: null,
					});

					step(i + 1);
				});
			};

			step(0);
		});
	});
};

// switch executor 0 to `physical` (1-based): DEVICE_SLOT_MAPPINGS set, built
// raw (the codec encode has no array vocabulary): MapCount=1, one
// [offset=12, size=4] ref pair, then the 4-byte MbimSlot struct. Mirrors the
// sim.uc idempotency guard: already-active slot → { unchanged: true }.
export function slot_switch(mc, physical, cb)
{
	mc.command(ext, 'DEVICE_SLOT_MAPPINGS', 'query', {}, (gerr, mapping) => {
		if (!gerr && mapping?.slots?.[0] == physical - 1)
			return cb(null, { unchanged: true });

		let info = struct.pack('<IIII', 1, 12, 4, physical - 1);

		mc.command_raw(ext.service, ext.commands.DEVICE_SLOT_MAPPINGS.cid, info,
			(err) => cb(err ?? null, null));
	});
};

// --- native MBIM default LTE attach context (MS BCE LTE_ATTACH_CONFIG, CID 3) -
// The MBIM equivalent of the QMI attach-profile write (context.uc
// ensure_attach_profile): programs the APN the modem uses for its *autonomous*
// EPS attach, which happens before any CONNECT. Without it a pure-MBIM modem
// attaches on its stored / carrier-default attach context, and a mismatched
// attach APN gets the whole attach rejected (LIMSRV) before contexts connect.

// get_lte_attach_config(mc, cb): cb(err, { contexts: [ { ip_type, roaming,
// source, access_string, user_name, password, compression, auth_protocol } ] }).
// The modem returns three contexts (one per roaming condition) for the SIM.
export function get_lte_attach_config(mc, cb)
{
	mc.command(ext, 'LTE_ATTACH_CONFIG', 'query', {}, (err, data) => cb(err, data));
};

// set_lte_attach_config(mc, contexts, cb): overwrite the default attach contexts.
// `contexts` must hold exactly three (home/partner/non-partner) or the modem
// rejects the Set. Built raw (no ms-struct-array encode in the codec), mirroring
// slot_switch; the Set response (CONFIG_INFO) is ignored beyond its status.
export function set_lte_attach_config(mc, contexts, cb)
{
	let info = ext.encode_set_lte_attach_config(contexts);

	mc.command_raw(ext.service, ext.commands.LTE_ATTACH_CONFIG.cid, info,
		(err) => cb(err ?? null));
};

// --- native MBIM SMS service (uuid_sms, verified vs libmbim 1.32) ------------
// The SMS service has NO storage selector (READ/DELETE act on the modem's
// configured SMS store), unlike the QMI WMS path — so this is the fallback for
// pure-MBIM firmware without the passthrough. PDU format only (no CDMA).
const SMS_SERVICE = '533fbeeb-14fe-4467-9f90-33a223e56c3f';
const SMS_CID_READ = 2;
const SMS_CID_DELETE = 4;
const SMS_FORMAT_PDU = 0;
const SMS_FLAG_ALL = 0;
const SMS_FLAG_INDEX = 1;

function _u(buf, p) { return (p + 4 <= length(buf)) ? struct.unpack('<I', substr(buf, p, 4))[0] : 0; }

// sms_read_all(mc, cb): read every stored PDU. cb(err, [{ index, status, pdu }]).
// Response (MbimSmsRead, PDU): Format(u32), MessagesCount(u32), then a
// ref-struct-array — MessagesCount [offset,size] pairs, each pointing to a
// MbimSmsPduReadRecord { MessageIndex(u32), MessageStatus(u32),
// PduData ref-byte-array [offset,size] }. All offsets are from the buffer start.
export function sms_read_all(mc, cb)
{
	let info = struct.pack('<III', SMS_FORMAT_PDU, SMS_FLAG_ALL, 0);

	mc.command_raw(SMS_SERVICE, SMS_CID_READ, info, (err, resp) => {
		if (err)
			return cb(err, null);

		let count = _u(resp, 4), out = [];

		for (let i = 0; i < count; i++) {
			let off = _u(resp, 8 + i * 8);             // ref pair: [offset, size]
			let idx = _u(resp, off), status = _u(resp, off + 4);
			let poff = _u(resp, off + 8), psize = _u(resp, off + 12);

			push(out, { index: idx, status: status, pdu: hexmod.bin_to_hex(substr(resp, poff, psize)) });
		}

		cb(null, out);
	});
};

// sms_delete(mc, index, cb): delete one stored message by index.
export function sms_delete(mc, index, cb)
{
	let info = struct.pack('<II', SMS_FLAG_INDEX, +index);

	mc.command_raw(SMS_SERVICE, SMS_CID_DELETE, info, (err) => cb(err ?? null));
};

// how many neighbour cells to ask the modem for (BASE_STATIONS_INFO caps)
const MAX_CELLS = 16;

// MBIM coded-value conversions (MS-MBIM signal coding):
//   RSSI  index 0..31 -> dBm = -113 + 2*index   (99 = unknown)
//   RSRP  index 0..127 -> dBm = index - 157      (0xFFFFFFFF = unknown)
//   SNR   index 0..127 -> dB  = index/2 - 23.5   (0xFFFFFFFF = unknown)
// Both are 3GPP report buckets, so index 0 is "below the floor" and the top
// index is "at or above the ceiling" — a saturated reading, NOT a missing one.
const UNKNOWN_U32 = 0xFFFFFFFF;

// Base Stations Info NR offsets — WHOLE dB steps (libmbim 1.32.0,
// mbimcli-ms-basic-connect-extensions.c:1410-1412). Do NOT share these with
// the Signal State helpers below: that message codes SNR in HALF-dB steps and
// has no RSRQ at all, so the only thing genuinely common between the two is
// the index space itself. Raised by Codex review, 2026-09-22.
const NR_RSRP_OFFSET = -156;
const NR_RSRQ_OFFSET = -43;
const NR_SINR_OFFSET = -23;

// Ceiling on the index itself, not a plausibility bound on the dB it maps to.
// These are 7-bit report indices — libmbim bounds the Signal State ones at
// exactly that width (mbimcli-basic-connect.c:1879,1884) though it leaves the
// cell ones unbounded — so a word above 127 is not a reading in any of the
// three mappings, whatever the sentinel says. (The cell offsets below are NOT
// the Signal State encoding, so this is the width they share and not much
// else.) The H5000M in ddimension/wwand#30 sends signed physical values in
// these fields, which as unsigned words land near 2^32 and would otherwise be
// published as astronomic signal levels. Raised by Codex review, 2026-09-22.
const NR_CODED_MAX = 127;

// LTE cell metrics are read signed, so the 0xFFFFFFFF unknown arrives as -1
const LTE_METRIC_UNKNOWN = -1;

function rssi_dbm(idx)
{
	return (idx != null && idx != bc.RSSI_UNKNOWN) ? (-113 + 2 * idx) : null;
}

// Signal State RSRP. The index is OFF BY ONE from the obvious reading: 3GPP's
// report mapping spends index 0 on "below the floor", so index 1 IS the floor
// (-156 dBm) and the dBm is coded-157, not coded-156. That convention is why
// the two encodings in this file disagree by one step and must stay apart.
// libmbim spells the offset out — `-157 + rsrp` (1.32.0,
// mbimcli-basic-connect.c:1882) — and wwand had -156, so every MBIM RSRP read
// one dB optimistic. Found while checking the cell decoders for
// ddimension/wwand#30, 2026-09-22.
//
// What is NOT copied from there is the guard beside it, `if (rsrp >= 127)
// unknown` (:1879). 127 is the top bucket, "at or above -30 dBm" — and -157+127
// is exactly -30, so libmbim's own formula covers it. Collapsing it to unknown
// is a display choice in a CLI; on a router it would blank the signal bars at
// the moment the signal is best. The domain check below rejects the sentinel
// and anything outside the 7-bit index space, and nothing else. Raised by Codex
// review, which was right to push back on my first attempt.
function rsrp_dbm(coded)
{
	return (coded != null && coded <= NR_CODED_MAX) ? (coded - 157) : null;
}

// Signal State SNR in 0.1 dB units to match QMI self.signal snr (rendered /10
// by the daemon). Same off-by-one, in half-dB steps: `-23.5 + snr * 0.5`
// (mbimcli-basic-connect.c:1887), top bucket 127 = 40.0 dB. Note this is NOT
// the Base Stations Info SINR encoding, which steps in whole dB — see
// NR_SINR_OFFSET.
function snr_tenths(coded)
{
	return (coded != null && coded <= NR_CODED_MAX) ? (coded * 5 - 235) : null;
}

// "26201" / "262001" -> "262/01" (matching the QMI 'plmn' decode: "mcc/mnc")
function plmn_str(provider_id)
{
	if (!provider_id || length(provider_id) < 4)
		return null;

	return sprintf('%s/%s', substr(provider_id, 0, 3), substr(provider_id, 3));
}

// get_signal(mc, cb): per-RAT signal from Signal State, normalized to the QMI
// self.signal shape { lte:{rssi,rsrq,rsrp,snr}, nr5g:{rsrp,snr} }, or cb(null).
// That layout has no per-RAT RSRQ, so lte.rsrq is null.
//
// v1/v2-COMPATIBLE, not v2-only, and the name of the schema entry oversells it:
// wwand negotiates no MBIMEx version (mbim_client.open()), so a conforming
// device answers the v1 Signal State — which is the first 20 bytes, identical
// in both, with no RsrpSnr tail. The query is empty either way, and the loop
// below simply finds nothing, leaving the RSSI-only line at the end. A device
// that volunteers the v2 tail is read in full. So this degrades rather than
// misparses; what it does NOT do is prove the device speaks v2. Raised by
// Codex review, 2026-09-19.
export function get_signal(mc, cb)
{
	mc.command(bc, 'SIGNAL_STATE_V2', 'query', {}, (err, data) => {
		if (err || !data)
			return cb(null);

		let out = {};
		let rssi = rssi_dbm(data.rssi);

		for (let e in (data.rsrp_snr ?? [])) {
			let st = +(e.system_type ?? 0);
			let rsrp = rsrp_dbm(e.rsrp);
			let snr = snr_tenths(e.snr);

			if (st & ext.DATA_CLASS_LTE)
				out.lte = { rssi: rssi, rsrq: null, rsrp: rsrp, snr: snr };

			if (st & (ext.DATA_CLASS_5G_NSA | ext.DATA_CLASS_5G_SA))
				out.nr5g = { rsrp: rsrp, snr: snr };
		}

		// RSSI present but no LTE RsrpSnr entry — still surface the RSSI
		if (!out.lte && rssi != null)
			out.lte = { rssi: rssi, rsrq: null, rsrp: null, snr: null };

		return cb(length(out) ? out : null);
	});
};

// LTE cell metrics: signed, already in dBm/dB, unknown = 0xFFFFFFFF read
// signed, i.e. -1 (libmbim 1.32.0, mbimcli-ms-basic-connect-extensions.c:
// 1207-1212 PRINT_VALIDATED_INT compares against (gint32)invalid, applied to
// rsrp/rsrq at :1346-1347). -1 is not a reading a cell can produce anyway —
// RSRQ tops out near -3 dB — but it was being published as one.
function lte_metric(v)
{
	return (v != null && v != LTE_METRIC_UNKNOWN) ? v * 10 : null;
}

// NR cell metrics are NOT dBm. They are coded indices with a fixed offset —
// RSRP = v-156 dBm, RSRQ = v-43 dB, SINR = v-23 dB, unknown = 0xFFFFFFFF
// (libmbim 1.32.0, mbimcli-ms-basic-connect-extensions.c:1410-1412 via
// PRINT_VALIDATED_SCALED_UINT at :1214-1219). LTE in the same message is the
// other convention (:1346), which is how this came to be read as dBm for both.
//
// The signal path in this very file already had it right (rsrp_dbm/snr_tenths
// above decode SIGNAL_STATE's NR indices) — so wwand was publishing the same
// modem's NR RSRP two different ways depending on which message it came from.
// Reported in ddimension/wwand#30 by miku2365 (H5000M), 2026-09-22.
// ...and then the hardware answered the question this refusal was standing in
// for. miku2365 ran mbimcli with --device-open-ms-mbimex-v3 (ddimension/wwand#30,
// 2026-09-23) and it printed RSRP -266 dBm, RSRQ -783 dB, SINR 212 dB. Inverting
// libmbim's own transform — `((gint32)number) + scale`, 1.32.0
// mbimcli-ms-basic-connect-extensions.c:1214-1219 — gives the words actually on
// the wire: -110, -740, 235. None of them is a 7-bit index, and -110 dBm is
// exactly what an RSRP reads on a weak 5G cell.
//
// So the firmware fills the NR block the way the spec defines the LTE one. That
// is not a wild guess about this vendor: libmbim prints LTE rsrp/rsrq with
// PRINT_VALIDATED_INT (signed, no offset, :1346-1347) three dozen lines above
// printing the NR ones with PRINT_VALIDATED_SCALED_UINT (:1410-1412). Two
// conventions in one message is the trap this whole decoder was rewritten for;
// this modem simply fell into the other half of it.
//
// Refusing the word outright was right while its meaning was unknown and is
// wrong now — for RSRP. Before 2026-09-22 wwand published `raw * 10` here and
// was accidentally CORRECT on this hardware; f51beb2 replaced that with silence.
// So: a word that reads as a NEGATIVE i32 is taken as a direct value, and only
// when it lands in the very dB domain the coded mapping can produce — the two
// encodings have to describe the same physical range, so the offset defines the
// bound and no separate plausibility table is needed.
//
// RSRQ AND SINR STAY REFUSED, deliberately. -740 is outside the coded domain
// under every scale that would make it a dB figure (-74, -7.4, -740), and 235 is
// positive, so neither can be read without inventing a unit for it. A wrong
// number on a signal page is worse than a missing one, and the measurement that
// would settle them — the same cell's SIGNAL_STATE decode at the same moment —
// has been asked for.
function as_i32(v)
{
	return (v >= 0x80000000) ? (v - 0x100000000) : v;
}

// WHICH CONVENTION THIS CELL USES, decided ONCE from RSRP and applied to all
// three fields. Deciding per field was wrong and the second hardware sample
// proved it: on 2026-09-24 the same H5000M reported RSRP -120 (direct) alongside
// SINR 60, and 60 lands INSIDE the 7-bit index space — so a per-field rule read
// it as an index and published 37.0 dB while the QMI-over-MBIM passthrough and
// SIGNAL_STATE both said 13-14 dB at that moment. A firmware does not mix the two
// conventions inside one struct; RSRP is the field whose SIGN settles which one
// it is, so it decides for the struct.
function nr_convention(rsrp)
{
	// NO RSRP IS NOT EVIDENCE OF THE ODD CONVENTION — the spec is the default,
	// and only a negative RSRP argues against it. A modem that cannot measure
	// RSRP this instant (the 0xFFFFFFFF sentinel, a measurement gap) may still
	// report valid RSRQ and SINR indices, and refusing them here discarded two
	// good readings for the absence of a third. Codex review, 2026-09-24, against
	// a first version that returned null and dropped them. The hole this leaves
	// is narrow by construction: a firmware using the direct convention sends
	// RSRP as its primary measurement, so the sentinel and that convention
	// practically do not co-occur.
	if (rsrp == null || rsrp == UNKNOWN_U32)
		return 'coded';

	if (rsrp <= NR_CODED_MAX)
		return 'coded';

	let s = as_i32(rsrp);

	// negative and inside the domain: the direct convention. Anything else is a
	// word neither reading explains, which IS evidence the struct is not to be
	// trusted — so the dependent fields get nothing (null, distinct from both
	// conventions above).
	return (s < 0 && s >= NR_RSRP_OFFSET && s <= NR_RSRP_OFFSET + NR_CODED_MAX)
		? 'direct' : null;
}

function nr_metric(v, offset)
{
	if (v == null || v == UNKNOWN_U32)
		return null;

	// the spec path: a 7-bit report index
	if (v <= NR_CODED_MAX)
		return (v + offset) * 10;

	let s = as_i32(v);

	// a direct physical value, accepted only inside the domain the index
	// mapping spans (offset .. offset + 127) and only where the sign settles
	// that it cannot be an index at all.
	//
	// `s < 0` IS REDUNDANT TODAY AND STAYS. With these three offsets the widest
	// domain ends at +104, and we only get here when the word is already above
	// 127, so a non-negative reading fails the upper bound on its own (Codex
	// review, 2026-09-23, which was right about the redundancy). It is kept
	// because it encodes the actual rule rather than an arithmetic accident of
	// the current constants: only a negative word can be one of these direct
	// values, and a fourth metric with a larger offset would silently start
	// admitting positive words the moment this line went away.
	if (s < 0 && s >= offset && s <= offset + NR_CODED_MAX)
		return s * 10;

	return null;
}

// map one MBIM LTE cell (serving or neighbour) into a QMI lte_intra.cells[]
// entry (metrics in 0.1 dB units; rssi/srxlev unavailable)
function lte_cell(c)
{
	return {
		pci:    c.pci,
		rsrq:   lte_metric(c.rsrq),
		rsrp:   lte_metric(c.rsrp),
		rssi:   null,
		srxlev: null,
	};
}

// get_cells(mc, cb): serving + neighbour cell info from Base Stations Info,
// normalized to the QMI self.cells shape (lte_intra + nr5g_cell/nr5g_arfcn), or
// cb(null) when the modem reports neither an LTE nor an NR serving cell.
export function get_cells(mc, cb)
{
	mc.command(ext, 'BASE_STATIONS_INFO', 'query', {
		max_gsm_count: 0, max_umts_count: 0, max_tdscdma_count: 0,
		max_lte_count: MAX_CELLS, max_cdma_count: 0, max_nr_count: MAX_CELLS,
	}, (err, data) => {
		if (err || !data)
			return cb(null);

		let cells = {};
		let lte = data.lte_serving;

		if (lte) {
			let list = [ lte_cell(lte) ];

			for (let n in (data.lte_neighbors ?? []))
				push(list, lte_cell(n));

			cells.lte_intra = {
				plmn:            plmn_str(lte.provider_id),
				tac:             lte.tac,
				global_cell_id:  lte.cell_id,
				earfcn:          lte.earfcn,
				serving_cell_id: lte.pci,
				cells:           list,
			};
		}

		let nr = (data.nr_serving ?? [])[0];

		if (nr) {
			let nr_conv = nr_convention(nr.rsrp);

			cells.nr5g_arfcn = nr.nrarfcn;
			cells.nr5g_cell = {
				plmn:           plmn_str(nr.provider_id),
				tac:            nr.tac,
				global_cell_id: nr.nci,
				pci:            nr.pci,
				// ONE decision for the struct (nr_convention). In `direct`
				// mode only RSRP is published: it is corroborated (-110 and
				// -120 dBm on a weak 5G cell, two samples) and its sign is what
				// identified the convention in the first place. RSRQ and SINR
				// get no reading under that convention because none has ever
				// been corroborated — -740 and -930 are outside every scale that
				// would make them a dB figure, and 60 would read as 37 dB where
				// two independent sources said 13. Refused for want of evidence,
				// not for want of a rule; the measurement that would settle them
				// has been asked for (ddimension/wwand#30).
				rsrq:           (nr_conv == 'coded') ? nr_metric(nr.rsrq, NR_RSRQ_OFFSET) : null,
				rsrp:           nr_metric(nr.rsrp, NR_RSRP_OFFSET),
				snr:            (nr_conv == 'coded') ? nr_metric(nr.sinr, NR_SINR_OFFSET) : null,
			};
		}

		return cb(length(cells) ? cells : null);
	});
};

// get_data_mode(mc, cb): data-system mode { mode, lte, nr } (mode LTE/NSA/SA) —
// the MBIM analogue of qmi_backend.get_data_mode. Derived from the register
// state's available data classes (MbimDataClass bitmask: LTE / 5G-NSA / 5G-SA).
// REGISTRATION_PARAMETERS carries no data-class field, so the register state's
// class mask is the native-MBIM source. cb(null) on error / no data.
export function get_data_mode(mc, cb)
{
	mc.command(bc, 'REGISTER_STATE', 'query', {}, (err, data) => {
		if (err || data?.available_data_classes == null)
			return cb(null);

		let dc = data.available_data_classes;
		let lte = (dc & ext.DATA_CLASS_LTE) != 0;
		let nr = (dc & (ext.DATA_CLASS_5G_NSA | ext.DATA_CLASS_5G_SA)) != 0;
		let mode = nr ? (lte ? 'NSA' : 'SA') : (lte ? 'LTE' : null);

		// NO MODE IS NOT A MODE. Returning { mode: null } here reads as a
		// successful answer to every caller — it is a truthy object — so the
		// backend keeps the choice it won and reports "unknown RAT" forever,
		// while a rung further down the ladder could have read the serving cell
		// and known the answer.
		//
		// Reached in the field by CUSTOM alone (0x80000000): libmbim's name for
		// a class that is proprietary or not in the enum, which some modems
		// report for 5G when the MBIM extensions were never negotiated. A
		// Quectel RM520F-GL carried NR5G-SA traffic while reporting exactly
		// that, and wwand showed no RAT at all (ddimension/wwand#30).
		if (mode == null)
			return cb(null);

		cb({ mode: mode, lte: lte, nr: nr });
	});
};

// get_reg_detail(mc, cb): why (not) registered, from the register state —
// { source:'mbim', limited?, reject_cause? } or cb(null) on error. nw_error is
// the 3GPP TS 24.008 reject cause (the clear-text mapping is the core's job);
// a denied registration is flagged as limited service.
export function get_reg_detail(mc, cb)
{
	mc.command(bc, 'REGISTER_STATE', 'query', {}, (err, data) => {
		if (err || !data)
			return cb(null);

		let d = { source: 'mbim' };

		if (data.nw_error != null && data.nw_error != 0)
			d.reject_cause = data.nw_error;

		d.limited = (data.register_state == bc.REGISTER_STATE_DENIED);

		cb(d);
	}, { no_recovery: true });
};
