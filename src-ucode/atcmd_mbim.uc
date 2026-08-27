// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — AT over MBIM: an atcmd transport that carries AT commands inside
// MBIM instead of over a tty.
//
// WHY: a PCIe/MHI modem often has no AT port at all. The generic Qualcomm
// entry in mhi-pci-generic declares DIAG/MBIM/QMI/IPCR/FIREHOSE/IP_SW0/IP_HW0
// but no DUN channel, and DUN is what mhi_wwan_ctrl turns into /dev/wwanNat0.
// Without AT there is no vendor telemetry, no protocol switch, no AT+QSIMDET.
// But MBIM is a SEPARATE MHI channel with its own node, so a QMI-driven modem
// can open it purely as an AT side-channel — no kernel patch, no mode switch.
//
// Quectel's pipe: service QDU 6427015f-579d-48f5-8c54-f43ed1e76f83, CID 8, SET
//   request  InformationBuffer = u32 LE CommandType (0 = AT, 1 = SYSTEM)
//                                || raw ASCII command
//   response InformationBuffer = u32 LE Status      (0 = OK, 1 = FAIL)
//                                || raw ASCII response
// Both byte arrays are unsized and UNPADDED — no offset/length pair, unlike
// ordinary MBIM string fields. HW-verified on a Quectel RM520N-GL over MHI
// while the QMI backend held /dev/wwan0qmi0.
//
// The pipe is request/response, not a byte stream, so this module adapts:
// writes are buffered until the engine terminates a command, the transaction
// runs, and the answer is handed back through the same on_data callback the
// tty transport uses. The engine above cannot tell the difference.
//
// LIMITATION: a request/response pipe carries no unsolicited output. URCs that
// a modem would push on a real AT port never arrive here. Everything wwand
// polls works; anything that waits for a URC does not, and callers that care
// should keep using a tty when one exists.

'use strict';

import * as uloop from 'uloop';
import * as struct from 'struct';
import * as transport from 'wwand.transport';
import * as mbim_client from 'wwand.mbim_client';
import * as mbimmod from 'wwand.codec.mbim';
import * as hexmod from 'wwand.codec.hex';

export const QDU_UUID = '6427015f-579d-48f5-8c54-f43ed1e76f83';
export const QDU_CID_COMMAND = 8;

export const CMD_TYPE_AT = 0;

// MBIM Basic Connect, CID 16 = DEVICE_SERVICES — the standard "what do you
// support" query, answered by every MBIM function.
const BASIC_CONNECT_UUID = 'a289cc33-bcbb-8b4f-b6b0-133ec2aae6df';
const CID_DEVICE_SERVICES = 16;

// The reply is a table of DEVICE_SERVICE elements, each opening with its 16-byte
// service UUID. Rather than walk the offset/size pairs, just look for the raw
// UUID bytes: the only place they can appear is such an element.
function has_service(info, uuid)
{
	return index(info ?? '', hexmod.hex_to_bin(replace(uuid, /-/g, ''))) >= 0;
}

// a single AT round trip; generous because some vendor commands (COPS=?) take
// tens of seconds and the engine's own timeout is the one that should fire
const CMD_TIMEOUT = 90000;

// Strip the command echo. The modem answers with the command it was handed,
// terminated by CR, and only then the response proper: "ATI\r" + "\r\nQuectel…".
// Cut exactly the echo and its CR — not through the first newline, which would
// eat the CRLF that opens the response and leave the engine a first line that
// no tty would ever produce. Falls back to the newline cut for a modem that
// echoes something other than what it was given.
function strip_echo(body, cmd)
{
	body = body ?? '';

	if (length(cmd) && substr(body, 0, length(cmd)) == cmd) {
		let rest = substr(body, length(cmd));

		return (substr(rest, 0, 1) == "\r") ? substr(rest, 1) : rest;
	}

	let nl = index(body, "\n");

	return (nl >= 0) ? substr(body, nl + 1) : body;
};

// Build the transport on an ALREADY-OPEN MBIM client. `on_close` is what the
// transport calls when the engine closes it — whoever owns the client decides
// whether that means closing anything.
function make_transport(cl, path, log, on_close, first_timeout)
{
	let self = { closed: false, kind: 'mbim', path: path };
	let data_cb = null;
	let buf = '';
	let busy = false;
	let answered = false;
	let queue = [];
	let pump;

	let deliver = (text) => {
		if (data_cb && length(text ?? ''))
			data_cb(text);
	};

	let run = (cmd) => {
		busy = true;

		let info = struct.pack('<I', CMD_TYPE_AT) + cmd;
		// The FIRST command is the caller's probe. On a borrowed client it must
		// not sit in flight for the full timeout: an RM520N-GL that ADVERTISES
		// the QDU service still never answered CID 8, and the probe blocked the
		// control channel of a modem carrying live traffic for 90 s. Later
		// commands keep the long timeout — `AT+COPS=?` legitimately takes a
		// minute.
		let timeout = (first_timeout && !answered) ? first_timeout : CMD_TIMEOUT;

		cl.command_raw(QDU_UUID, QDU_CID_COMMAND, info, (cerr, out) => {
			busy = false;
			answered = answered || !cerr;

			if (cerr) {
				// Give the engine something terminal to parse rather than
				// letting its timeout run: a dead pipe should fail the
				// command, not stall the queue behind it.
				log('warn', sprintf('AT over MBIM: %J', cerr));
				deliver("\r\nERROR\r\n");
			}
			else {
				let status = (length(out) >= 4)
					? struct.unpack('<I', substr(out, 0, 4))[0] : 1;
				let body = strip_echo(substr(out, 4), cmd);

				if (status != 0)
					log('debug', sprintf('AT over MBIM: status %d', status));

				// the engine wants the response framed like a tty's
				deliver(length(body) ? body : "\r\nERROR\r\n");
			}

			pump();
		}, { timeout: timeout });
	};

	pump = () => {
		if (busy || !length(queue))
			return;

		run(shift(queue));
	};

	// The engine writes `cmd + '\r'`, and an SMS body terminated by ^Z.
	// Both mark a complete unit of work, which is exactly the granularity
	// the QDU pipe wants.
	self.write = (data) => {
		buf += data ?? '';

		while (true) {
			let cut = -1;

			for (let i = 0; i < length(buf); i++) {
				let c = substr(buf, i, 1);

				if (c == "\r" || c == "\n" || c == "\x1a") {
					cut = i;
					break;
				}
			}

			if (cut < 0)
				break;

			let cmd = substr(buf, 0, cut);
			buf = substr(buf, cut + 1);

			if (length(trim(cmd)))
				push(queue, cmd);
		}

		pump();

		return true;
	};

	self.on_data = (fn) => { data_cb = fn; };

	// nothing arrives unbidden on a request/response pipe
	self.drain = () => null;

	self.close = () => {
		if (self.closed)
			return;

		self.closed = true;
		queue = [];

		if (on_close)
			on_close();
	};

	return self;
};

// attach(client, path, o, cb): ride an MBIM client someone else already owns —
// the case where MBIM is what DRIVES the modem. Opening a second client on the
// same device is not an option: MBIM_OPEN resets the function and would drop a
// live data session. Never closes the borrowed client.
//
// Asks the device what it supports FIRST. QDU is a vendor extension and a
// modem that lacks it does not answer at all — measured on an RM520N-GL
// (RM520NGLAAR03A03M4G): a probe command sat in flight until it timed out 90 s
// later, on the control channel of a modem carrying live traffic. A borrowed
// client is not a place to send speculative commands, and DEVICE_SERVICES is
// the cheap question every MBIM device does answer.
export function attach(cl, path, o, cb)
{
	let log = o?.log ?? ((level, msg) => null);

	if (!cl)
		return cb(null);

	cl.command_raw(BASIC_CONNECT_UUID, CID_DEVICE_SERVICES, '', (err, out) => {
		if (err) {
			log('info', sprintf('AT over MBIM: %s did not answer DEVICE_SERVICES (%J)',
				path, err));
			return cb(null);
		}

		if (!has_service(out, QDU_UUID)) {
			log('info', sprintf('AT over MBIM: %s does not offer the QDU service', path));
			return cb(null);
		}

		log('info', sprintf('AT over MBIM on the control client of %s (QDU CID %d)',
			path, QDU_CID_COMMAND));

		// 8 s is plenty for `AT` and bounds what a modem that lists the
		// service but ignores the CID can cost us.
		cb(make_transport(cl, path, log, null, 8000));
	}, { timeout: 10000, cmd_type: mbimmod.CMD_QUERY });
};

// open(path, o, cb): open the device ourselves, for a modem driven by some
// OTHER backend (QMI over MHI, typically) whose MBIM channel is idle.
// o = { log, open_hub?, make_client? } (the two hooks are test seams).
// cb(transport) on success, cb(null) on any failure — callers treat AT as
// optional, so this never throws.
export function open(path, o, cb)
{
	let log = o?.log ?? ((level, msg) => null);
	let open_hub = o?.open_hub ?? transport.open;
	let make_client = o?.make_client ?? mbim_client.create;

	let cl = null;
	let hub = open_hub(path, {
		on_raw: (h, msg) => {
			let dec = mbimmod.decode(msg);

			if (dec && cl)
				cl.on_message(dec);
		},
		on_gone: () => {
			log('warn', sprintf('AT/MBIM %s: device disappeared', path));
		},
	});

	if (!hub) {
		log('warn', sprintf('cannot open %s for AT over MBIM', path));
		return cb(null);
	}

	cl = make_client(hub, null);

	cl.open((err) => {
		if (err) {
			log('warn', sprintf('AT over MBIM: MBIM_OPEN on %s failed: %J', path, err));
			hub.close();
			return cb(null);
		}

		let self = make_transport(cl, path, log,
			() => cl.close(() => hub.close()));

		log('info', sprintf('AT over MBIM pipe open on %s (QDU CID %d)',
			path, QDU_CID_COMMAND));

		cb(self);
	});
};
