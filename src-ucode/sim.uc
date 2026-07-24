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
import * as backend from './backend.uc';
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

// the PIN to try: a per-SIM override (config wwand_sim matched to the active
// card's ICCID, set on modem.active_sim before unlock) wins over the modem's
// default pincode; an empty override falls through to the modem default.
export function effective_pincode(modem)
{
	// a manual PIN release (the pin-verify ubus method) sets a one-shot override
	// that wins over the configured PIN — used to unlock past the low-retry block.
	if (modem._pin_override != null && modem._pin_override != '')
		return modem._pin_override;

	let sp = modem.active_sim?.pincode;

	if (sp != null && sp != '')
		return sp;

	return modem.config?.pincode;
}

// PIN-safety threshold: with this many verify attempts left (or fewer), do NOT
// auto-enter the PIN — burning the last try locks the SIM to PUK. The daemon
// blocks and waits for a manual release (modem.pin_force, set by the pin-verify
// ubus call). Shared by all backends so the behaviour is uniform.
export const PIN_MIN_RETRIES = 2;

// decide whether to block auto PIN entry given the remaining attempts; returns
// a blocked reason string, or null to proceed. `force` = a manual release.
export function pin_block_reason(retries, force)
{
	if (retries == null || force)
		return null;

	if (retries < 1)
		return 'retries_exhausted';   // 0 left — PUK needed

	if (retries < PIN_MIN_RETRIES)
		return 'pin_retries_low';     // precautionary block, releasable manually

	return null;
}

function unlock_uim(modem, cb, tries)
{
	let uim = modem.uim;
	let pincode = effective_pincode(modem);
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

			// guard: never auto-burn the last try (<= 1 left blocks and waits for
			// a manual release; 0 left needs the PUK)
			let br = pin_block_reason(retries, modem.pin_force);

			if (br)
				return cb({ blocked: true, reason: br, retries: retries });

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
	let pincode = effective_pincode(modem);
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
			// guard: never auto-burn the last try (shared PIN-safety threshold)
			let br = pin_block_reason(pin1.verify_retries, modem.pin_force);

			if (br)
				return cb({ blocked: true, reason: br, retries: pin1.verify_retries });

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

// QMI codes where the transport rejected the op WITHOUT touching the PIN, so it
// is safe to try the next transport: MissingArgument 17, InvalidArgument 48,
// DeviceNotReady 52, AccessDenied 82, NotSupported 94. Real PIN results
// (IncorrectPin 12, PinBlocked 35) stop the chain so we never burn a retry on
// another transport. NoEffect 26 means already in the requested state = done.
const PINLOCK_FALLBACK = { '17': 1, '48': 1, '52': 1, '82': 1, '94': 1 };

// enable (lock) or disable (unlock) the SIM PIN1 query — whether the card asks
// for the PIN at power-on. Needs the current PIN. Tries QMI first (UIM, then
// DMS), falls back to AT+CLCK on a transport rejection. cb(err, { enabled }).
export function set_pin_lock(modem, enable, pin, cb)
{
	let enabled = enable ? 1 : 0;
	let pin_id = uimmod.PIN_ID_PIN1;

	let chain = [];
	if (modem.uim) push(chain, 'uim');
	if (modem.dms) push(chain, 'dms');
	if (modem.at)  push(chain, 'at');

	let i = 0, attempt;

	attempt = () => {
		if (i >= length(chain))
			return cb({ error: 'no_pin_backend' });

		let be = chain[i++];

		let handle = (err, data) => {
			if (err && err.code == 26)                    // NoEffect: already set
				return cb(null, { enabled: !!enable, note: 'no_effect' });

			if (!err)
				return cb(null, { enabled: !!enable });

			// transport rejected the op (PIN untouched) -> try the next; a real
			// PIN error stops here so another transport can't burn a retry
			let transport_reject = (err.error != 'qmi') || PINLOCK_FALLBACK[sprintf('%d', err.code)];

			if (transport_reject && i < length(chain))
				return attempt();

			cb({ error: err.error ?? 'qmi', detail: err, retries: data?.retries?.verify });
		};

		if (be == 'uim')
			return modem.uim.request('SET_PIN_PROTECTION', {
				session: { session_type: uimmod.SESSION_TYPE_PRIMARY_GW_PROVISIONING, aid: '' },
				info: { pin_id: pin_id, enabled: enabled, pin: pin },
			}, handle, { no_recovery: true });

		if (be == 'dms')
			return modem.dms.request('SET_PIN_PROTECTION', {
				info: { pin_id: pin_id, enabled: enabled, pin: pin },
			}, handle, { no_recovery: true });

		// AT+CLCK="SC",<1 lock|0 unlock>,"<pin>"
		modem.at.send(sprintf('AT+CLCK="SC",%d,"%s"', enabled, pin),
			(err) => handle(err ? { error: 'at', detail: err } : null));
	};

	// idempotent: read the current PIN1 state and short-circuit if already in
	// the requested state — avoids a spurious AccessDenied and never touches a
	// retry. PIN1 state 1/2 = enabled, 3 = disabled, 4/5 = blocked. Use UIM
	// (authoritative where present, and what the EG06 uses), else DMS.
	let after_state = (st) => {
		if (st != null) {
			if (st == 4 || st == 5)
				return cb({ error: 'pin_blocked', status: st });

			if (!!enable == (st == 1 || st == 2))
				return cb(null, { enabled: !!enable, already: true });
		}

		attempt();
	};

	if (modem.uim)
		return modem.uim.request('GET_CARD_STATUS', {}, (err, data) =>
			after_state(err ? null : find_app(data.card_status)?.app?.pin1_state),
			{ no_recovery: true });

	if (modem.dms)
		return modem.dms.request('GET_PIN_STATUS', {}, (err, data) =>
			after_state(err ? null : data?.pin1?.status), { no_recovery: true });

	attempt();
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

	// optional EF reads (PLMN lists, identity) that a modem rejects with
	// INVALID_ARGUMENT etc. must not climb the recovery/reboot ladder
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
	}, { no_recovery: true });
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

// pick the APDU transport once per modem, in order: native MBIM MS UICC Low
// Level Access -> QMI UIM logical channel (native, or over the QMI-over-MBIM
// passthrough) -> AT CCHO/CGLA/CCHC. cb('mbim' | 'qmi' | 'at' | null)
const ISDR_AID = 'a0000005591010ffffffff8900000100';

function apdu_backend(modem, slot, cb)
{
	backend.choose(modem, '_apdu_be', [
		// native MBIM UICC (modem exposes modem.mbim_uicc): probe by opening the
		// ISD-R channel and closing it again
		{ name: 'mbim', probe: (ok) => {
			if (!modem.mbim_uicc)
				return ok(false);

			modem.mbim_uicc.open(ISDR_AID, (err, data) => {
				if (!err && data?.channel != null) {
					modem.mbim_uicc.close(data.channel, () => {});
					return ok(true);
				}
				ok(false);
			});
		} },
		// QMI logical channel: probe with the ISD-R AID; NOT_SUPPORTED -> next.
		// On an MBIM modem modem.uim is null until a UIM client is allocated over
		// the passthrough (modem._ensure_uim) — the fallback for modems whose
		// firmware lacks native MBIM UICC but exposes the QMI passthrough.
		{ name: 'qmi', probe: (ok) => {
			let go = () => {
				if (!modem.uim)
					return ok(false);

				modem.uim.request('OPEN_LOGICAL_CHANNEL', {
					slot: slot, aid: hex_to_arr(ISDR_AID),
				}, (err, data) => {
					if (!err && data.channel_id != null) {
						modem.uim.request('LOGICAL_CHANNEL',
							{ slot: slot, channel_id: data.channel_id, terminate: 1 }, () => {});
						return ok(true);
					}
					ok(false);
				});
			};

			if (!modem.uim && modem._ensure_uim)
				return modem._ensure_uim(() => go());

			go();
		} },
		{ name: 'at', probe: (ok) => ok(!!modem.at) },
	], cb);
}

// open a logical channel to `aid_hex` on physical slot `slot` (1-based);
// cb(err, { channel, select_response })
export function apdu_open(modem, slot, aid_hex, cb)
{
	apdu_backend(modem, slot, (be) => {
		if (be == 'mbim')
			return modem.mbim_uicc.open(aid_hex, (err, d) =>
				cb(err, d ? { channel: d.channel, select_response: d.select_response } : null));

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
	if (modem._apdu_be == 'mbim')
		return modem.mbim_uicc.apdu(channel, apdu_hex, cb);

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
	if (modem._apdu_be == 'mbim')
		return modem.mbim_uicc.close(channel, cb);

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

// try providers in order until one yields a non-null value; each provider is
// (done) => done(value | null). The sustainable fallback shape for identity.
function first_of(providers, cb)
{
	let i = 0, step;

	step = () => {
		if (i >= length(providers))
			return cb(null);

		providers[i++]((v) => (v != null) ? cb(v) : step());
	};

	step();
}

// first line of an AT reply that is a run of >= min digits (IMSI/ICCID)
function at_digits(lines, min)
{
	for (let l in (lines ?? [])) {
		let m = match(trim(l), /([0-9]{8,})/);

		if (m && length(m[1]) >= min)
			return m[1];
	}

	return null;
}

// IMSI / ICCID with a sustainable per-field fallback: UIM EF read -> QMI DMS
// getter -> AT. Modems whose UIM rejects raw EF reads (EG06: InvalidArgument)
// fall through to DMS UIM Get IMSI/ICCID, then to AT (AT+CIMI / AT+QCCID). The
// QMI getters use no_recovery so a rejection never climbs the reboot ladder.
// read just the ICCID (UIM EF read -> DMS getter -> AT). The MF-level EF-ICCID
// is readable BEFORE PIN unlock, so this is used to identify the active card and
// pick a matching per-SIM override (wwand_sim) before choosing the PIN. Already
// trailing-'f'-stripped, matching the ICCID shown in status/LuCI.
export function read_iccid(modem, cb)
{
	let chain = [];
	if (modem.uim)
		push(chain, (done) => read_ef(modem, EF_ICCID, (b) =>
			done(b != null ? replace(swap_nibbles(b), /f+$/, '') : null)));
	push(chain, (done) => modem.dms.request('GET_ICCID', {}, (e, d) =>
		done((!e && length(d?.iccid ?? '')) ? d.iccid : null), { no_recovery: true }));
	if (modem.at)
		push(chain, (done) => modem.at.send('AT+QCCID', (e, r) =>
			done(e ? null : at_digits(r?.lines, 18))));

	first_of(chain, cb);
}

export function read_identity(modem, cb)
{
	let out = { imsi: null, iccid: null, msisdn: null };

	let imsi_chain = [];
	if (modem.uim)
		push(imsi_chain, (done) => read_ef(modem, EF_IMSI, (b) =>
			done(b != null ? substr(swap_nibbles(b), 3) : null)));   // strip len+parity
	push(imsi_chain, (done) => modem.dms.request('GET_IMSI', {}, (e, d) =>
		done((!e && length(d?.imsi ?? '')) ? d.imsi : null), { no_recovery: true }));
	if (modem.at)
		push(imsi_chain, (done) => modem.at.send('AT+CIMI', (e, r) =>
			done(e ? null : at_digits(r?.lines, 14))));

	first_of(imsi_chain, (imsi) => {
		out.imsi = imsi;

		read_iccid(modem, (iccid) => {
			out.iccid = iccid;

			modem.dms.request('GET_MSISDN', {}, (err, data) => {
				if (!err)
					out.msisdn = data.msisdn;

				cb(out);
			});
		});
	});
}
