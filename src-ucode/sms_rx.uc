// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — what arrives unasked: a new SMS and a Cell Broadcast page.
//
// A new SMS becomes the modem event `sms` ({ storage, index, sender, text,
// timestamp, concat }), a Cell Broadcast message — joined and recognised as
// a repeat by cbs.uc — the event `cell_broadcast`. Three ways in, the same
// split as the SMS transport (sms.uc): QMI WMS (native or over the MBIM
// passthrough) through its Event Report, the native MBIM SMS notifications
// (Message Store Status, and Read for a message delivered unstored), and the
// AT URCs +CMTI, +CMT and +CBM.
//
// What the modem is TOLD is kept to what is needed. The SMS routes stay as the
// firmware has them (store-and-notify is the common default; a message routed
// for transfer arrives in the indication and is acknowledged when the modem
// asks for it). Cell Broadcast is switched on or off only when the modem's
// config says so (`option cell_broadcast`), read before written; unset leaves
// the modem's own setting.
//
//   arm(modem)     -> listen (best-effort, at every registration)
//   messages(modem) -> the last Cell Broadcast messages, newest first

'use strict';

import * as cbs from 'wwand.cbs';
import * as sms from 'wwand.sms';
import * as sms_pdu from 'wwand.sms_pdu';
import * as hexmod from 'wwand.codec.hex';

// QMI storage type -> the storage names sms.uc reads by
function storage_name(st)
{
	return (st == 1) ? 'ME' : 'SM';
}

function store(modem)
{
	modem._cbs = modem._cbs ?? cbs.create_store();

	return modem._cbs;
}

// --- reporting ---------------------------------------------------------------

function emit_sms(modem, m, storage, index, via)
{
	if (!m)
		return;

	let c = m.udh;   // sms_pdu parse_udh: { ref, total, part } of a concatenated message

	modem._emit?.('sms', {
		storage: storage, index: index, via: via,
		sender: m.sender, text: m.text, timestamp: m.timestamp,
		concat: c ? { ref: c.ref, part: c.part, parts: c.total } : null,
	});
}

// a stored message: read it, then report it (unreadable = reported by index)
function stored(modem, storage, index, via)
{
	sms.sms_read(modem, storage, index, (err, res) => {
		if (err || !res?.message)
			return modem._emit?.('sms', { storage: storage, index: index, via: via, text: null });

		emit_sms(modem, res.message, storage, index, via);
	});
}

function broadcast(modem, octets, via)
{
	let msg = cbs.receive(store(modem), octets, time());

	if (msg)
		modem._emit?.('cell_broadcast', { ...msg, via: via });
}

// --- QMI WMS -------------------------------------------------------------------

// transferred messages already reported, by transaction id AND content: an
// ack that failed makes the network send the message again, the same; an id
// alone is reused for new messages once its transaction is done
const SEEN_TX = 32;

function wms_arm(modem, wms)
{
	// the handler once per client; the report switched on until the modem
	// accepted it — a refusal now is tried again at the next registration
	if (!wms._rx_on) {
		wms._rx_on = true;
		wms._rx_tx = [];

		wms.on('EVENT_REPORT_IND', (d) => {
			let tr = d?.transfer_route;

			if (tr) {
				// handed over unstored: a broadcast page, or an SMS routed
				// for transfer — acknowledged when the modem says the host
				// must, or the network sends it again. Acknowledged even when
				// it cannot be decoded: unacknowledged it would come back for
				// ever; it is reported with its raw PDU instead.
				if (tr.ack_indicator == 0)
					wms.request('SEND_ACK', { info: { transaction_id: tr.transaction_id,
						protocol: 1, success: 1 } }, () => null, { no_recovery: true });

				let key = sprintf('%d:%s', tr.transaction_id, hexmod.arr_to_hex(tr.data ?? []));

				if (tr.ack_indicator == 0 && index(wms._rx_tx, key) >= 0)
					return;

				if (tr.ack_indicator == 0) {
					push(wms._rx_tx, key);

					if (length(wms._rx_tx) > SEEN_TX)
						shift(wms._rx_tx);
				}

				if (tr.format == 0x07)
					return broadcast(modem, tr.data, 'qmi');

				if (tr.format == 0x06) {
					let hex = hexmod.arr_to_hex(tr.data);
					let m = sms_pdu.decode_deliver(hex);

					if (m)
						return emit_sms(modem, m, null, null, 'qmi');

					return modem._emit?.('sms', { storage: null, index: null, via: 'qmi', text: null, pdu: hex });
				}

				return;
			}

			if (d?.mt_message)
				stored(modem, storage_name(d.mt_message.storage_type), d.mt_message.memory_index, 'qmi');
		});
	}

	if (!wms._rx_reported)
		wms.request('SET_EVENT_REPORT', { new_mt: 1 }, (err) => { if (!err) wms._rx_reported = true; },
			{ no_recovery: true });
}

// switch broadcast on with `channels`, or off (null) — only when it differs
function wms_broadcast(modem, wms, want, log)
{
	wms.request('GET_BROADCAST_CONFIG', { mode: 1 }, (err, d) => {
		let cur = err ? null : d?.config;
		let on = (want != null);
		let have = map(filter(cur?.channels ?? [], (c) => c.selected), (c) => sprintf('%d-%d', c.start, c.end));
		let need = map(want ?? [], (c) => sprintf('%d-%d', c.start, c.end));

		if (cur && !!cur.activated == on && (!on || join(',', sort(have)) == join(',', sort(need))))
			return log?.('debug', 'cell broadcast: already as configured');

		let activate = () => wms.request('SET_BROADCAST_ACTIVATION', { activation: { mode: 1, activate: on ? 1 : 0 } },
			(aerr) => log?.(aerr ? 'warn' : 'notice', aerr
				? sprintf('cell broadcast: switching %s refused (%J)', on ? 'on' : 'off', aerr)
				: sprintf('cell broadcast: %s%s', on ? 'on, channels ' : 'off', on ? cbs.cscb_mids(want) : '')),
			{ no_recovery: true });

		if (!on)
			return activate();

		wms.request('SET_BROADCAST_CONFIG', { mode: 1,
			channels: map(want, (c) => ({ start: c.start, end: c.end, selected: 1 })) }, (cerr) => {
			if (cerr)
				return log?.('warn', sprintf('cell broadcast: channel list refused (%J)', cerr));

			activate();
		}, { no_recovery: true });
	}, { no_recovery: true });
}

// --- AT ------------------------------------------------------------------------

// `+CMTI: "SM",3` / `+CMT: [<alpha>],<len>\n<pdu>` / `+CBM: <len>\n<pdu>`
export function parse_at(line)
{
	let m = match(line ?? '', /^\+CMTI:[ ]*"([A-Z]+)"[ ]*,[ ]*([0-9]+)/);

	if (m)
		return { kind: 'stored', storage: m[1], index: +m[2] };

	m = match(line ?? '', /^\+(CMT|CBM):[^\n]*\n([0-9A-Fa-f]+)$/);

	if (m)
		return { kind: (m[1] == 'CBM') ? 'broadcast' : 'sms', pdu: m[2] };

	return null;
};

function at_note(modem, line)
{
	let e = parse_at(line);

	if (!e)
		return;

	// the store as the modem named it: MT is the combined one, its indices
	// are not ME's (27.005 3.1)
	if (e.kind == 'stored')
		return stored(modem, e.storage, e.index, 'at');

	if (e.kind == 'broadcast')
		return broadcast(modem, hexmod.hex_to_arr(e.pdu), 'at');

	emit_sms(modem, sms_pdu.decode_deliver(e.pdu), null, null, 'at');
}

// AT+CNMI, read and changed only in the parts asked for (27.005 3.4.1):
// `mt` 1 = a stored SMS is announced (+CMTI), `bm` 2 = a broadcast page is
// sent on (+CBM). The rest stays as the modem has it; the setting is
// volatile and set again at every registration.
function at_cnmi(modem, mt, bm, log)
{
	modem.at.send('AT+CNMI?', (err, res) => {
		let cur = null;

		for (let l in (res?.lines ?? [])) {
			let m = match(l, /^\+CNMI:[ ]*([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+)/);

			if (m)
				cur = [ +m[1], +m[2], +m[3], +m[4], +m[5] ];
		}

		let want = cur ? [ ...cur ] : [ 2, 0, 0, 0, 0 ];

		// mode 0 buffers everything in the modem: nothing would arrive
		if (want[0] == 0)
			want[0] = 2;
		if (mt != null)
			want[1] = mt;
		if (bm != null)
			want[2] = bm;

		if (cur && join(',', cur) == join(',', want))
			return;

		modem.at.send(sprintf('AT+CNMI=%s', join(',', want)), (serr) => {
			if (serr)
				log?.('info', sprintf('AT+CNMI=%s refused (%J): the modem keeps its own setting', join(',', want), serr));
		});
	});
}

function at_broadcast(modem, want, log)
{
	// PDU mode, or +CBM arrives as text (27.005 3.4.1)
	modem.at.send('AT+CMGF=0', () =>
		// off = mode 0 (accept) with no identifier, not mode 1 (reject) with
		// none, which rejects nothing (27.005 3.3.4)
		modem.at.send((want != null) ? sprintf('AT+CSCB=0,"%s",""', cbs.cscb_mids(want)) : 'AT+CSCB=0,"",""',
			(err) => log?.(err ? 'warn' : 'notice', err
				? sprintf('cell broadcast: AT+CSCB refused (%J)', err)
				: sprintf('cell broadcast: %s', (want != null) ? 'on, channels ' + cbs.cscb_mids(want) : 'off'))));
}

// --- public API ----------------------------------------------------------------

// The config says: `cell_broadcast` '1' / '0' / unset, `cb_channels`.
// -> channels to switch on, false to switch off, null to leave alone
function wanted(modem)
{
	let v = modem.config?.cell_broadcast;

	if (v == null || v == '')
		return null;

	if (v == '0' || v == 0 || v === false)
		return false;

	return cbs.parse_channels(modem.config?.cb_channels) ?? cbs.DEFAULT_CHANNELS;
}

export function arm(modem, log)
{
	let want = wanted(modem);

	modem._sms_note = (src, d) => {
		if (src == 'at')
			return at_note(modem, d);

		// native MBIM: a stored message announced, or one delivered unstored
		if (src == 'mbim_stored')
			return stored(modem, 'ME', d, 'mbim');

		if (src == 'mbim_pdu')
			return emit_sms(modem, sms_pdu.decode_deliver(d), null, null, 'mbim');
	};

	let with_at = () => {
		if (!modem.at)
			return;

		// the AT URCs carry the SMS only where no other SMS transport does,
		// and the broadcast pages only where WMS does not — over both, every
		// page would come twice
		let sms_on_at = !modem.wms && !modem.mbim_sms;
		let bm = (want == null || modem.wms) ? null : (want ? 2 : 0);

		if (sms_on_at || bm != null)
			at_cnmi(modem, sms_on_at ? 1 : null, bm, log);

		if (want != null && !modem.wms)
			at_broadcast(modem, want || null, log);
	};

	let go = () => {
		if (modem.wms) {
			wms_arm(modem, modem.wms);

			if (want != null)
				wms_broadcast(modem, modem.wms, want || null, log);
		}

		with_at();
	};

	if (!modem.wms && type(modem._ensure_wms) == 'function')
		return modem._ensure_wms(() => go());

	go();
};

export function messages(modem)
{
	return modem?._cbs?.messages ?? [];
};
