// wwand — backend-neutral SMS access (list / read / delete stored messages).
//
// Mirrors sim.apdu_backend: pick the transport once per modem via backend.choose
// (QMI WMS, native or over the MBIM passthrough → AT CMGL/CMGR/CMGD), cache it,
// and dispatch each op by name. All backends return raw PDUs, decoded by the one
// shared sms_pdu.uc. Receive-only — there is no send path.
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

import * as backend from './backend.uc';
import * as sms_pdu from './sms_pdu.uc';
import * as wmsmod from './codec/schema/wms.uc';

// byte array -> lowercase hex string (PDU bytes from the WMS raw-data TLV)
function arr_hex(a)
{
	let s = '';

	for (let b in (a ?? []))
		s += sprintf('%02x', b & 0xff);

	return s;
}

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

		let m = data?.raw?.data ? sms_pdu.decode_deliver(arr_hex(data.raw.data)) : null;

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
		if (be == 'at')
			return at_list(modem, storage, cb);

		cb({ error: 'unsupported_on_backend' }, null);
	});
}

export function sms_read(modem, storage, index, cb)
{
	sms_backend(modem, (be) => {
		if (be == 'qmi')
			return qmi_read(modem, qmi_storage(storage), index, (err, m) => {
				if (!err && m)
					m.storage = storage;
				cb(err, err ? null : { message: m });
			});
		if (be == 'at')
			return at_read(modem, storage, index, cb);

		cb({ error: 'unsupported_on_backend' }, null);
	});
}

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
		if (be == 'at')
			return at_delete(modem, storage, index, cb);

		cb({ error: 'unsupported_on_backend' }, null);
	});
}
