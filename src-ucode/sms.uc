// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — backend-neutral SMS access (list / read / delete stored messages,
// and send).
//
// Mirrors sim.apdu_backend: pick the transport once per modem via backend.choose
// (QMI WMS, native or over the MBIM passthrough → AT CMGL/CMGR/CMGD), cache it,
// and dispatch each op by name. All backends return raw PDUs, decoded by the one
// shared sms_pdu.uc.
//
// SEND takes a different route on purpose: it does not go through
// backend.choose, because that probes with a List Messages and a modem can be
// perfectly able to send while rejecting List (the Quectel case below). It
// picks QMI WMS whenever a WMS client is up and falls back to AT.
//
// The QMI candidate PROBES by actually issuing a List Messages: some firmware
// (e.g. Quectel RG650E) rejects WMS List with QMI MISSING_ARGUMENT, so the probe
// falls through to the AT path rather than picking a transport that can't list.
//
//   sms_list(modem, storage, cb)    -> cb(err, { messages: [...] })  (reassembled)
//   sms_read(modem, storage, i, cb) -> cb(err, { message: {...}|null })
//   sms_delete(modem, storage, i,cb)-> cb(err, { ok: true })
// `storage` is 'SM'/'SIM'/'UIM' (SIM card) or 'ME'/'NV' (modem store).

'use strict';

import * as backend from 'wwand.backend';
import * as hexmod from 'wwand.codec.hex';
import * as sms_pdu from 'wwand.sms_pdu';
import * as wmsmod from 'wwand.codec.schema.wms';

function is_me(storage)
{
	let s = uc(storage ?? '');

	return (s == 'ME' || s == 'NV');
}

function qmi_storage(storage)
{
	return is_me(storage) ? wmsmod.STORAGE_NV : wmsmod.STORAGE_UIM;
}

// --- QMI WMS path ------------------------------------------------------------

// read one stored message by index -> decoded object (or null on decode fail)
function qmi_read(modem, st, index, cb)
{
	modem.wms.request('RAW_READ', {
		storage: { storage_type: st, memory_index: +index },
		message_mode: wmsmod.MODE_GSM_WCDMA,
	}, (err, data) => {
		if (err)
			return cb({ error: 'qmi', detail: err }, null);

		let m = data?.raw?.data ? sms_pdu.decode_deliver(hexmod.arr_to_hex(data.raw.data)) : null;

		if (m) {
			m.index = +index;
			m.tag = data.raw.tag;
		}

		cb(null, m);
	});
}

function qmi_list(modem, storage, cb)
{
	let st = qmi_storage(storage);

	modem.wms.request('LIST_MESSAGES', {
		storage_type: st,
		message_mode: wmsmod.MODE_GSM_WCDMA,
	}, (err, data) => {
		if (err)
			return cb({ error: 'qmi', detail: err }, null);

		let entries = data?.list ?? [];
		let out = [], i = 0, step;

		step = () => {
			if (i >= length(entries))
				return cb(null, out);

			let e = entries[i++];

			qmi_read(modem, st, e.memory_index, (rerr, m) => {
				if (m) {
					m.storage = storage;
					m.tag = e.tag;
					push(out, m);
				}
				step();
			});
		};

		step();
	});
}

// --- native MBIM SMS path (no storage selector — reads the modem store) ------

function mbim_decode(recs, storage)
{
	let parts = [];

	for (let r in (recs ?? [])) {
		let m = sms_pdu.decode_deliver(r.pdu);
		if (m) {
			m.index = r.index;
			m.storage = storage;
			push(parts, m);
		}
	}

	return parts;
}

function mbim_list(modem, storage, cb)
{
	modem.mbim_sms.read_all((err, recs) =>
		cb(err ? { error: 'mbim', detail: err } : null,
		   err ? null : { messages: sms_pdu.reassemble(mbim_decode(recs, storage)) }));
}

function mbim_read(modem, storage, index, cb)
{
	modem.mbim_sms.read_all((err, recs) => {
		if (err)
			return cb({ error: 'mbim', detail: err }, null);

		let m = null;

		for (let r in (recs ?? []))
			if (r.index == +index) {
				m = sms_pdu.decode_deliver(r.pdu);
				if (m) { m.index = r.index; m.storage = storage; }
				break;
			}

		cb(null, { message: m });
	});
}

// --- AT path (CMGL/CMGR/CMGD in PDU mode) ------------------------------------

// +CMGL response: "+CMGL: <index>,<stat>,<alpha>,<len>" then a PDU hex line.
function parse_cmgl(lines)
{
	let out = [], pending = null;

	for (let l in (lines ?? [])) {
		let m = match(l, /^\+CMGL:\s*([0-9]+),([0-9]+),[^,]*,([0-9]+)/);

		if (m) {
			pending = { index: +m[1] };
			continue;
		}

		let t = trim(l);

		if (pending && length(t) && !match(t, /^\+/)) {
			pending.pdu = t;
			push(out, pending);
			pending = null;
		}
	}

	return out;
}

function at_prepare(modem, storage, next)
{
	let mem = is_me(storage) ? 'ME' : 'SM';

	modem.at.send(sprintf('AT+CPMS="%s","%s","%s"', mem, mem, mem), () =>
		modem.at.send('AT+CMGF=0', () => next()));
}

function at_list(modem, storage, cb)
{
	at_prepare(modem, storage, () => {
		modem.at.send('AT+CMGL=4', (err, res) => {
			if (err)
				return cb({ error: 'at', detail: err }, null);

			let parts = [];

			for (let e in parse_cmgl(res?.lines)) {
				let m = sms_pdu.decode_deliver(e.pdu);
				if (m) {
					m.index = e.index;
					m.storage = storage;
					push(parts, m);
				}
			}

			cb(null, { messages: sms_pdu.reassemble(parts) });
		});
	});
}

function at_read(modem, storage, index, cb)
{
	at_prepare(modem, storage, () => {
		modem.at.send(sprintf('AT+CMGR=%d', +index), (err, res) => {
			if (err)
				return cb({ error: 'at', detail: err }, null);

			let pdu = null;

			for (let l in (res?.lines ?? [])) {
				let t = trim(l);
				if (length(t) && !match(t, /^\+/) && !match(t, /^OK$/)) {
					pdu = t;
					break;
				}
			}

			let m = pdu ? sms_pdu.decode_deliver(pdu) : null;

			if (m) {
				m.index = +index;
				m.storage = storage;
			}

			cb(null, { message: m });
		});
	});
}

function at_delete(modem, storage, index, cb)
{
	at_prepare(modem, storage, () => {
		modem.at.send(sprintf('AT+CMGD=%d', +index), (err) =>
			cb(err ? { error: 'at', detail: err } : null, err ? null : { ok: true }));
	});
}

// --- backend selection -------------------------------------------------------

function sms_backend(modem, cb)
{
	backend.choose(modem, '_sms_be', [
		// QMI WMS — native, or over the QMI-over-MBIM passthrough (modem._ensure_wms
		// allocates the WMS client on first use, like _ensure_uim). Probe by an
		// actual List Messages so a modem whose firmware rejects WMS List falls to AT.
		{ name: 'qmi', probe: (ok) => {
			let go = () => {
				if (!modem.wms)
					return ok(false);

				modem.wms.request('LIST_MESSAGES', {
					storage_type: wmsmod.STORAGE_UIM,
					message_mode: wmsmod.MODE_GSM_WCDMA,
				}, (err) => ok(!err));
			};

			if (!modem.wms && modem._ensure_wms)
				return modem._ensure_wms(() => go());

			go();
		} },
		// native MBIM SMS — fallback for a pure-MBIM modem without the passthrough.
		// After qmi because it has no storage selector (reads the modem's store).
		{ name: 'mbim', probe: (ok) => {
			if (!modem.mbim_sms)
				return ok(false);

			modem.mbim_sms.read_all((err) => ok(!err));
		} },
		// AT CMGL/CMGR/CMGD in PDU mode — the universal fallback.
		{ name: 'at', probe: (ok) => ok(!!modem.at) },
	], cb);
}

// --- public API --------------------------------------------------------------

export function sms_list(modem, storage, cb)
{
	sms_backend(modem, (be) => {
		if (be == 'qmi')
			return qmi_list(modem, storage, (err, parts) =>
				cb(err, err ? null : { messages: sms_pdu.reassemble(parts) }));
		if (be == 'mbim')
			return mbim_list(modem, storage, cb);
		if (be == 'at')
			return at_list(modem, storage, cb);

		cb({ error: 'unsupported_on_backend' }, null);
	});
};

export function sms_read(modem, storage, index, cb)
{
	sms_backend(modem, (be) => {
		if (be == 'qmi')
			return qmi_read(modem, qmi_storage(storage), index, (err, m) => {
				if (!err && m)
					m.storage = storage;
				cb(err, err ? null : { message: m });
			});
		if (be == 'mbim')
			return mbim_read(modem, storage, index, cb);
		if (be == 'at')
			return at_read(modem, storage, index, cb);

		cb({ error: 'unsupported_on_backend' }, null);
	});
};

export function sms_delete(modem, storage, index, cb)
{
	sms_backend(modem, (be) => {
		if (be == 'qmi')
			return modem.wms.request('DELETE', {
				storage: qmi_storage(storage),
				memory_index: +index,
				message_mode: wmsmod.MODE_GSM_WCDMA,
			}, (err) => cb(err ? { error: 'qmi', detail: err } : null,
			               err ? null : { ok: true }));
		if (be == 'mbim')
			return modem.mbim_sms.del(+index, (err) =>
				cb(err ? { error: 'mbim', detail: err } : null, err ? null : { ok: true }));
		if (be == 'at')
			return at_delete(modem, storage, index, cb);

		cb({ error: 'unsupported_on_backend' }, null);
	});
};

// rolling 8-bit concatenation reference for multipart sends (no RNG in ucode)
let concat_ref = 0;

// send an SMS. Encodes SMS-SUBMIT PDU(s) (GSM7/UCS2, auto-segmented), then
// dispatches: QMI WMS RAW_SEND (native or over the MBIM passthrough) else
// AT+CMGS PDU mode. A native-MBIM-only modem with no AT falls through to
// unsupported (no native MBIM SMS_SEND path yet). cb(err, { parts, refs }).
export function sms_send(modem, number, text, cb)
{
	if (!length(number ?? '') || text == null)
		return cb({ error: 'invalid_argument' });

	concat_ref = (concat_ref + 1) & 0xff;
	let pdus = sms_pdu.encode_submit(number, text, { ref: concat_ref });

	// WMS is allocated lazily, and a SEND can be the first SMS operation on the
	// modem — the list/read/delete path reaches _ensure_wms through
	// sms_backend(), this one does not. Without this a send-first on a QMI-only
	// modem found modem.wms null and fell through to an AT path that may not
	// exist, which is not what "lazily on first use" promises anywhere else.
	// forward-declared: ucode has no hoisting, and this is referenced from the
	// _ensure_wms continuation below before its own initialiser is reached
	let go;

	go = () => {
	// QMI WMS whenever a WMS client is up (native or passthrough); else AT
	if (modem.wms) {
		let refs = [], i = 0, step;

		step = () => {
			if (i >= length(pdus))
				return cb(null, { parts: length(pdus), refs: refs });

			modem.wms.request('RAW_SEND', {
				raw: { format: wmsmod.FORMAT_GSM_WCDMA_PP,
				       data: hexmod.hex_to_arr(pdus[i].pdu) },
			}, (err, data) => {
				if (err)
					return cb({ error: 'qmi', detail: err, sent: i });

				push(refs, data?.message_id);
				i++;
				step();
			});
		};

		return step();
	}

	if (modem.at) {
		modem.at.send('AT+CMGF=0', () => {
			let refs = [], i = 0, step;

			step = () => {
				if (i >= length(pdus))
					return cb(null, { parts: length(pdus), refs: refs });

				// AT+CMGS=<tpdu length in octets, excluding the SMSC byte>
				modem.at.send_pdu(sprintf('AT+CMGS=%d', pdus[i].tpdu_len), pdus[i].pdu,
					(err, res) => {
						if (err)
							return cb({ error: 'at', detail: err, sent: i });

						for (let l in (res?.lines ?? [])) {
							let m = match(l, /\+CMGS:\s*([0-9]+)/);
							if (m) push(refs, +m[1]);
						}
						i++;
						step();
					});
			};

			step();
		});

		return;
	}

		cb({ error: 'unsupported_on_backend' });
	};

	// WMS is allocated lazily, and a SEND can be the first SMS operation on the
	// modem — the list/read/delete path reaches _ensure_wms through
	// sms_backend(), this one does not. Without this a send-first on a QMI-only
	// modem found modem.wms null and fell through to an AT path that may not
	// exist, which is not what "lazily on first use" promises anywhere else.
	if (!modem.wms && type(modem._ensure_wms) == 'function')
		return modem._ensure_wms(() => go());

	return go();
};
