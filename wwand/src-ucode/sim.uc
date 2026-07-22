// wwand — SIM PIN handling: UIM service first, legacy DMS fallback.
//
// sim.unlock(modem, cb) drives the card to a usable state.
//   cb(null, { status: 'ready' | 'no_pin_needed' })  on success
//   cb({ blocked: true, reason: ... })               terminal, do not retry
//   cb({ error: ... })                               transient failure
//
// Preserved behavior from the old proto handler:
// - retry-count guard: never send a PIN when too few tries remain
//   (< 1 left on UIM, < 2 on legacy DMS)
// - QMI error 26 ("no effect") on DMS verify means "PIN not needed"
// - settle delay after successful verify when no card-status indication
//   confirms readiness

'use strict';

import * as uloop from 'uloop';
import * as uimmod from './codec/schema/uim.uc';
import * as dmsmod from './codec/schema/dms.uc';

const QMI_ERR_NO_EFFECT = 26;

// how often to re-poll a card that is still initializing
const CARD_POLL_TRIES = 10;
const CARD_POLL_MS = 1000;

function find_app(card_status)
{
	for (let card in (card_status?.cards ?? [])) {
		if (card.card_state != uimmod.CARD_STATE_PRESENT)
			continue;

		let best = null;

		for (let app in (card.applications ?? [])) {
			if (app.type == uimmod.APP_TYPE_USIM)
				return { card: card, app: app };

			if (app.type == uimmod.APP_TYPE_SIM && !best)
				best = { card: card, app: app };
		}

		if (best)
			return best;
	}

	return null;
}

function unlock_uim(modem, cb, tries)
{
	let uim = modem.uim;
	let pincode = modem.config?.pincode;
	let settle = modem.timing?.sim_settle ?? 5000;

	uim.request('GET_CARD_STATUS', {}, (err, data) => {
		if (err)
			return cb({ error: 'card_status', detail: err });

		let found = find_app(data.card_status);

		if (!found) {
			if ((tries ?? 0) < CARD_POLL_TRIES) {
				uloop.timer(modem.timing?.card_poll ?? CARD_POLL_MS,
					() => unlock_uim(modem, cb, (tries ?? 0) + 1));
				return;
			}

			return cb({ blocked: true, reason: 'no_sim' });
		}

		let app = found.app;

		switch (app.state) {
		case uimmod.APP_STATE_READY:
			return cb(null, {
				status: 'ready',
				pin1_state: app.pin1_state,
				pin1_retries: app.pin1_retries,
			});

		case uimmod.APP_STATE_DETECTED:
		case uimmod.APP_STATE_UNKNOWN:
			// card still initializing
			if ((tries ?? 0) < CARD_POLL_TRIES) {
				uloop.timer(modem.timing?.card_poll ?? CARD_POLL_MS,
					() => unlock_uim(modem, cb, (tries ?? 0) + 1));
				return;
			}

			return cb({ error: 'card_not_ready', state: app.state });

		case uimmod.APP_STATE_PIN1_OR_UPIN_PIN_REQUIRED: {
			let retries = app.upin_replaces_pin1 ? found.card.upin_retries : app.pin1_retries;

			// guard: refuse to burn the last try
			if (retries != null && retries < 1)
				return cb({ blocked: true, reason: 'retries_exhausted', retries: retries });

			if (!pincode)
				return cb({ blocked: true, reason: 'pin_required_no_pin' });

			// best-effort: get card status change indications for readiness
			uim.request('REGISTER_EVENTS', { mask: uimmod.EVENT_CARD_STATUS },
				(e) => null);

			let pin_id = app.upin_replaces_pin1 ? uimmod.PIN_ID_UPIN : uimmod.PIN_ID_PIN1;

			uim.request('VERIFY_PIN', {
				session: { session_type: uimmod.SESSION_TYPE_PRIMARY_GW_PROVISIONING, aid: '' },
				info: { pin_id: pin_id, pin: pincode },
			}, (verr, vdata) => {
				if (verr) {
					return cb({
						blocked: true,
						reason: 'verify_failed',
						detail: verr,
						retries: vdata?.retries?.verify,
					});
				}

				// wait for card-status indication signalling readiness,
				// fall back to a settle timer + one re-check
				let done = false;

				let finish = (ok, detail) => {
					if (done)
						return;

					done = true;

					if (ok)
						cb(null, { status: 'ready' });
					else
						cb({ error: 'unlock_not_confirmed', detail: detail });
				};

				uim.on('CARD_STATUS_IND', (idata) => {
					let f = find_app(idata.card_status);

					if (f?.app?.state == uimmod.APP_STATE_READY)
						finish(true);
				});

				uloop.timer(settle, () => {
					if (done)
						return;

					uim.request('GET_CARD_STATUS', {}, (e2, d2) => {
						let f = find_app(d2?.card_status);
						finish(f?.app?.state == uimmod.APP_STATE_READY, e2);
					});
				});
			});

			return;
		}

		default:
			// puk required, pin blocked, illegal, personalization
			return cb({ blocked: true, reason: 'app_state', state: app.state });
		}
	});
}

function unlock_dms(modem, cb, tries)
{
	let dms = modem.dms;
	let pincode = modem.config?.pincode;
	let settle = modem.timing?.sim_settle ?? 5000;

	dms.request('GET_PIN_STATUS', {}, (err, data) => {
		if (err) {
			// modems without any PIN facility fail here; treat as unlocked
			// (matches old code falling through when no pin status found)
			return cb(null, { status: 'no_pin_needed' });
		}

		let pin1 = data.pin1;

		if (!pin1)
			return cb(null, { status: 'no_pin_needed' });

		switch (pin1.status) {
		case 0: // not initialized ("UIM uninitialized" wait loop in old code)
			if ((tries ?? 0) < CARD_POLL_TRIES) {
				uloop.timer(modem.timing?.card_poll ?? CARD_POLL_MS,
					() => unlock_dms(modem, cb, (tries ?? 0) + 1));
				return;
			}

			return cb({ error: 'card_not_ready' });

		case 2: // enabled, verified
		case 3: // disabled
			return cb(null, { status: 'ready' });

		case 1: { // enabled, not verified
			// old guard: refuse when fewer than 2 tries left
			if (pin1.verify_retries != null && pin1.verify_retries < 2)
				return cb({ blocked: true, reason: 'retries_exhausted', retries: pin1.verify_retries });

			if (!pincode)
				return cb({ blocked: true, reason: 'pin_required_no_pin' });

			dms.request('VERIFY_PIN', {
				info: { pin_id: 1, pin: pincode },
			}, (verr, vdata) => {
				if (verr) {
					// "no effect" means the PIN was not needed after all
					if (verr.error == 'qmi' && verr.code == QMI_ERR_NO_EFFECT)
						return cb(null, { status: 'no_pin_needed' });

					return cb({
						blocked: true,
						reason: 'verify_failed',
						detail: verr,
						retries: vdata?.retries?.verify,
					});
				}

				// settle before using the card (old: sleep 5)
				uloop.timer(settle, () => cb(null, { status: 'ready' }));
			});

			return;
		}

		default: // blocked / permanently blocked
			return cb({ blocked: true, reason: 'pin_blocked', state: pin1.status });
		}
	});
}

export function unlock(modem, cb)
{
	if (modem.uim)
		return unlock_uim(modem, cb, 0);

	return unlock_dms(modem, cb, 0);
}

// --- card identity (IMSI / ICCID) -------------------------------------------

// SIM files are nibble-swapped BCD (old proto_qmi_convert_from_uimbyte)
function swap_nibbles(bytes)
{
	let s = '';

	for (let b in (bytes ?? []))
		s += sprintf('%x%x', b & 0xf, b >> 4);

	return s;
}

const EF_IMSI  = { file_id: 0x6F07, path: "\x00\x3F\xFF\x7F" };   // 3F00/7FFF
const EF_ICCID = { file_id: 0x2FE2, path: "\x00\x3F" };           // 3F00

function read_ef(modem, ef, cb, session_type)
{
	session_type = session_type ?? uimmod.SESSION_TYPE_PRIMARY_GW_PROVISIONING;

	modem.uim.request('READ_TRANSPARENT', {
		session:   { session_type: session_type, aid: '' },
		file:      { file_id: ef.file_id, path: ef.path },
		read_info: { offset: 0, len: 0 },
	}, (err, data) => {
		if (err) {
			// MF-level files (e.g. ICCID) need the card session on some
			// modems (RG650E answers error 48 on the provisioning session)
			if (session_type == uimmod.SESSION_TYPE_PRIMARY_GW_PROVISIONING)
				return read_ef(modem, ef, cb, uimmod.SESSION_TYPE_CARD_SLOT_1);

			if (modem.log_fn)
				modem.log_fn('warn', sprintf('uim read of file %04x failed: %J', ef.file_id, err));

			return cb(null);
		}

		cb(data.data);
	});
}

// best-effort: reads IMSI, ICCID and MSISDN; absent values stay null
// --- physical SIM slots ------------------------------------------------------

const CARD_STATES = { '0': 'unknown', '1': 'absent', '2': 'present' };

// decode a raw nibble-swapped BCD ICCID string (lstring bytes) to digits
function decode_iccid(raw)
{
	let s = '';

	for (let i = 0; i < length(raw ?? ''); i++) {
		let b = ord(raw, i);
		s += sprintf('%x%x', b & 0xf, b >> 4);
	}

	return replace(s, /f+$/, '');
}

// EID is plain BCD, high nibble first (SGP.02) — no nibble swap
function decode_eid(raw)
{
	let s = '';

	for (let i = 0; i < length(raw ?? ''); i++) {
		let b = ord(raw, i);
		s += sprintf('%x%x', b >> 4, b & 0xf);
	}

	return s;
}

// slot list with card/activity state and identifying ICCID; err when the
// modem has no slot-status support (single-slot firmwares often lack it)
export function slot_status(modem, cb)
{
	if (!modem.uim)
		return cb({ error: 'no_uim_client' }, null);

	modem.uim.request('GET_SLOT_STATUS', {}, (err, data) => {
		if (err)
			return cb(err, null);

		let out = map(data.slots ?? [], (s, i) => {
			let info = data.info?.[i];
			let eid = data.eids?.[i]?.eid;

			return {
				physical: i + 1,
				card: CARD_STATES[sprintf('%d', s.card_status)] ?? sprintf('%d', s.card_status),
				active: s.slot_status == 1,
				logical_slot: s.logical_slot,
				iccid: length(s.iccid ?? '') ? decode_iccid(s.iccid) : null,
				is_euicc: !!info?.is_euicc,
				eid: length(eid ?? '') ? decode_eid(eid) : null,
			};
		});

		cb(null, out);
	});
}

export function switch_slot(modem, physical, cb)
{
	if (!modem.uim)
		return cb({ error: 'no_uim_client' });

	modem.uim.request('SWITCH_SLOT', {
		logical: 1, physical: physical,
	}, (err) => cb(err ?? null));
}

// --- raw APDU channel (eSIM/ES10 foundation) ---------------------------------

export function hex_to_arr(s)
{
	let raw = hexdec(s ?? '');
	let out = [];

	for (let i = 0; i < length(raw ?? ''); i++)
		push(out, ord(raw, i));

	return out;
}

export function arr_to_hex(a)
{
	let s = '';

	for (let b in (a ?? []))
		s += sprintf('%02x', b);

	return s;
}

// APDU transport is either QMI UIM (SEND_APDU + logical channel) or, on
// firmwares that return NOT_SUPPORTED for the QMI channel (e.g. RG650E), the
// standard 3GPP AT commands CCHO/CGLA/CCHC. The eUICC's ISD-R must be free of
// the modem's internal LPA for the AT path (AT+QESIM="lpa_enable",0 + reset).

// --- AT (CCHO/CGLA/CCHC) transport ---
function at_apdu_open(modem, aid_hex, cb)
{
	modem.at.send(sprintf('AT+CCHO="%s"', uc(aid_hex)), (err, res) => {
		if (err)
			return cb(err, null);

		for (let l in (res?.lines ?? [])) {
			let m = match(l, /\+CCHO: *([0-9]+)/);

			if (m)
				return cb(null, { channel: +m[1], select_response: '' });
		}

		cb({ error: 'no_channel' }, null);
	}, { timeout: 15000 });
}

function at_apdu_send(modem, channel, apdu_hex, cb)
{
	let h = uc(apdu_hex);

	// CGLA length is the command length in hex characters (2 * bytes); the
	// APDU MUST be quoted — Quectel rejects the unquoted form with ERROR.
	// The response comes back quoted too: +CGLA: <len>,"<hex>"
	modem.at.send(sprintf('AT+CGLA=%d,%d,"%s"', channel, length(h), h), (err, res) => {
		if (err)
			return cb(err, null);

		for (let l in (res?.lines ?? [])) {
			let m = match(l, /\+CGLA: *[0-9]+,"?([0-9A-Fa-f]+)"?/);

			if (m)
				return cb(null, lc(m[1]));
		}

		cb({ error: 'no_response' }, null);
	}, { timeout: 30000 });
}

function at_apdu_close(modem, channel, cb)
{
	modem.at.send(sprintf('AT+CCHC=%d', channel), (err) => cb(err ?? null));
}

// pick the APDU transport once per modem: prefer QMI, fall back to AT CCHO
// when the QMI logical channel is unsupported. cb('qmi' | 'at' | null)
function apdu_backend(modem, slot, cb)
{
	if (modem._apdu_be != null)
		return cb(modem._apdu_be || null);

	if (!modem.uim) {
		modem._apdu_be = modem.at ? 'at' : '';
		return cb(modem._apdu_be || null);
	}

	// probe the QMI channel with the ISD-R AID; NOT_SUPPORTED -> AT
	modem.uim.request('OPEN_LOGICAL_CHANNEL', {
		slot: slot, aid: hex_to_arr('a0000005591010ffffffff8900000100'),
	}, (err, data) => {
		if (!err && data.channel_id != null) {
			modem.uim.request('LOGICAL_CHANNEL',
				{ slot: slot, channel_id: data.channel_id, terminate: 1 }, () => {});
			modem._apdu_be = 'qmi';
			return cb('qmi');
		}

		modem._apdu_be = modem.at ? 'at' : '';
		cb(modem._apdu_be || null);
	});
}

// open a logical channel to `aid_hex` on physical slot `slot` (1-based);
// cb(err, { channel, select_response })
export function apdu_open(modem, slot, aid_hex, cb)
{
	apdu_backend(modem, slot, (be) => {
		if (be == 'at')
			return at_apdu_open(modem, aid_hex, cb);

		if (be != 'qmi')
			return cb({ error: 'no_apdu_channel' }, null);

		modem.uim.request('OPEN_LOGICAL_CHANNEL', {
			slot: slot, aid: hex_to_arr(aid_hex),
		}, (err, data) => {
			if (err || data.channel_id == null)
				return cb(err ?? { error: 'no_channel' }, null);

			cb(null, { channel: data.channel_id,
			           select_response: arr_to_hex(data.select_response) });
		});
	});
}

export function apdu_send(modem, slot, channel, apdu_hex, cb)
{
	if (modem._apdu_be == 'at')
		return at_apdu_send(modem, channel, apdu_hex, cb);

	if (!modem.uim)
		return cb({ error: 'no_uim_client' }, null);

	modem.uim.request('SEND_APDU', {
		slot: slot, channel_id: channel, apdu: hex_to_arr(apdu_hex),
	}, (err, data) => {
		if (err)
			return cb(err, null);

		cb(null, arr_to_hex(data.response));
	}, { timeout: 30000 });
}

export function apdu_close(modem, slot, channel, cb)
{
	if (modem._apdu_be == 'at')
		return at_apdu_close(modem, channel, cb);

	if (!modem.uim)
		return cb({ error: 'no_uim_client' });

	modem.uim.request('LOGICAL_CHANNEL', {
		slot: slot, channel_id: channel, terminate: 1,
	}, (err) => cb(err ?? null));
}

// --- PLMN selector lists (settings editor) -----------------------------------

const EF_PLMN_USER = { file_id: 0x6F60, path: "\x00\x3F\xFF\x7F" };   // PLMNwAcT
const EF_PLMN_OPER = { file_id: 0x6F61, path: "\x00\x3F\xFF\x7F" };   // OPLMNwAcT
const EF_PLMN_HOME = { file_id: 0x6F62, path: "\x00\x3F\xFF\x7F" };   // HPLMNwAcT

// decode PLMNwAcT records (TS 31.102): 5 bytes each — 3 bytes BCD PLMN
// (nibble-swapped, 0xF filler = 2-digit MNC) + 2 bytes access-technology mask
export function decode_plmn_act(bytes)
{
	let out = [];

	for (let i = 0; i + 4 < length(bytes ?? []); i += 5) {
		let b = slice(bytes, i, i + 5);

		if (b[0] == 0xFF)
			continue;   // empty slot

		let d = [ b[0] & 0xF, b[0] >> 4, b[1] & 0xF, b[1] >> 4, b[2] & 0xF, b[2] >> 4 ];
		let act = (b[3] << 8) | b[4];

		push(out, {
			mcc: sprintf('%d%d%d', d[0], d[1], d[2]),
			mnc: sprintf('%d%d', d[4], d[5]) + ((d[3] == 0xF) ? '' : sprintf('%d', d[3])),
			act: act,
			utran:  !!(act & 0x8000),
			eutran: !!(act & 0x4000),
			ngran:  !!(act & 0x0800),
			gsm:    !!(act & 0x0080),
		});
	}

	return out;
}

// best-effort read of the three PLMN selector lists; a list reads as null
// when the file is absent (e.g. Telekom SIMs carry no user list)
export function read_plmn_lists(modem, cb)
{
	let out = { user: null, operator: null, home: null };

	if (!modem.uim)
		return cb(out);   // DMS legacy path has no generic file read

	read_ef(modem, EF_PLMN_USER, (u) => {
		out.user = (u != null) ? decode_plmn_act(u) : null;

		read_ef(modem, EF_PLMN_OPER, (o) => {
			out.operator = (o != null) ? decode_plmn_act(o) : null;

			read_ef(modem, EF_PLMN_HOME, (h) => {
				out.home = (h != null) ? decode_plmn_act(h) : null;
				cb(out);
			});
		});
	});
}

export function read_identity(modem, cb)
{
	let out = { imsi: null, iccid: null, msisdn: null };

	let finish_msisdn = () => {
		modem.dms.request('GET_MSISDN', {}, (err, data) => {
			if (!err)
				out.msisdn = data.msisdn;

			cb(out);
		});
	};

	if (modem.uim) {
		read_ef(modem, EF_IMSI, (imsi_bytes) => {
			if (imsi_bytes != null) {
				// first byte is the length, first digit the parity nibble
				let s = swap_nibbles(imsi_bytes);
				out.imsi = substr(s, 3);
			}

			read_ef(modem, EF_ICCID, (iccid_bytes) => {
				if (iccid_bytes != null)
					out.iccid = replace(swap_nibbles(iccid_bytes), /f+$/, '');

				finish_msisdn();
			});
		});

		return;
	}

	// legacy DMS path
	modem.dms.request('GET_IMSI', {}, (e1, d1) => {
		if (!e1)
			out.imsi = d1.imsi;

		modem.dms.request('GET_ICCID', {}, (e2, d2) => {
			if (!e2)
				out.iccid = d2.iccid;

			finish_msisdn();
		});
	});
}
