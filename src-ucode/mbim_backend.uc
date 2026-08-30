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
//     MBIM Base Stations Info reports actual dBm/dB (signed) -> scaled x10 here.
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
//   RSRP  index 0..126 -> dBm = index - 156      (0xFFFFFFFF = unknown)
//   SNR   index 0..127 -> dB  = index/2 - 23     (0xFFFFFFFF = unknown)
const UNKNOWN_U32 = 0xFFFFFFFF;

function rssi_dbm(idx)
{
	return (idx != null && idx != bc.RSSI_UNKNOWN) ? (-113 + 2 * idx) : null;
}

function rsrp_dbm(coded)
{
	return (coded != null && coded != UNKNOWN_U32) ? (coded - 156) : null;
}

// SNR in 0.1 dB units to match QMI self.signal snr (rendered /10 by the daemon)
function snr_tenths(coded)
{
	return (coded != null && coded != UNKNOWN_U32) ? (coded * 5 - 230) : null;
}

// "26201" / "262001" -> "262/01" (matching the QMI 'plmn' decode: "mcc/mnc")
function plmn_str(provider_id)
{
	if (!provider_id || length(provider_id) < 4)
		return null;

	return sprintf('%s/%s', substr(provider_id, 0, 3), substr(provider_id, 3));
}

// get_signal(mc, cb): per-RAT signal from the MBIMEx v2 Signal State, normalized
// to the QMI self.signal shape { lte:{rssi,rsrq,rsrp,snr}, nr5g:{rsrp,snr} }, or
// cb(null). MBIM v2 Signal State has no per-RAT RSRQ, so lte.rsrq is null.
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

// map one MBIM LTE cell (serving or neighbour, metrics in actual dBm/dB) into a
// QMI lte_intra.cells[] entry (metrics in 0.1 dB units; rssi/srxlev unavailable)
function lte_cell(c)
{
	return {
		pci:    c.pci,
		rsrq:   (c.rsrq != null) ? c.rsrq * 10 : null,
		rsrp:   (c.rsrp != null) ? c.rsrp * 10 : null,
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
			cells.nr5g_arfcn = nr.nrarfcn;
			cells.nr5g_cell = {
				plmn:           plmn_str(nr.provider_id),
				tac:            nr.tac,
				global_cell_id: nr.nci,
				pci:            nr.pci,
				rsrq:           (nr.rsrq != null) ? nr.rsrq * 10 : null,
				rsrp:           (nr.rsrp != null) ? nr.rsrp * 10 : null,
				snr:            (nr.sinr != null) ? nr.sinr * 10 : null,
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
