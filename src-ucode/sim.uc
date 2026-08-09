// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — SIM PIN handling: UIM service first, legacy DMS fallback.
//
// sim.unlock(modem, cb) drives the card to a usable state.
//   cb(null, { status: 'ready' | 'no_pin_needed' })  on success
//   cb({ blocked: true, reason: ... })               terminal, do not retry
//   cb({ error: ... })                               transient failure
//
// Load-bearing behaviors preserved from the old proto handler:
// - retry-count guard: never send a PIN when too few tries remain
//   (< 1 left on UIM, < 2 on legacy DMS)
// - QMI error 26 ("no effect") on DMS verify means "PIN not needed"
// - settle delay after successful verify when no card-status indication
//   confirms readiness

'use strict';

import * as uloop from 'uloop';
import * as hexmod from './codec/hex.uc';
import * as backend from './backend.uc';
import * as uimmod from './codec/schema/uim.uc';
import * as dmsmod from './codec/schema/dms.uc';
import * as atcmd from './atcmd.uc';

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
};

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
};

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
};

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
			if (err && err.code == QMI_ERR_NO_EFFECT)     // already in the requested state
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
};

// --- card identity (IMSI / ICCID) -------------------------------------------

// SIM files are nibble-swapped BCD — helpers live in codec/hex.uc
const swap_nibbles = hexmod.bcd_swapped_arr;

// module-internal aliases (NOT re-exported; import codec/hex.uc directly)
const hex_to_arr = hexmod.hex_to_arr;
const arr_to_hex = hexmod.arr_to_hex;

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

// --- physical SIM slots ------------------------------------------------------

const CARD_STATES = { '0': 'unknown', '1': 'absent', '2': 'present' };

const decode_iccid = hexmod.decode_iccid;
const decode_eid = hexmod.decode_eid;

// slot list with card/activity state and identifying ICCID; err when the
// modem has no slot-status support (single-slot firmwares often lack it)
export function slot_status(modem, cb)
{
	if (!modem.uim)
		return cb({ error: 'no_uim_client' }, null);

	// single-slot firmwares (e.g. old Huawei sticks) don't implement the
	// message at all — and LuCI polls this method every few seconds. Cache
	// the deterministic refusal instead of hammering the modem and flooding
	// the log on every poll.
	if (modem._slot_status_unsupported)
		return cb({ error: 'unsupported' }, null);

	modem.uim.request('GET_SLOT_STATUS', {}, (err, data) => {
		if (err) {
			// 71 InvalidQmiCommand / 94 NotSupported: permanent for this fw
			if (err.code == 71 || err.code == 94)
				modem._slot_status_unsupported = true;
			return cb(err, null);
		}

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
};

export function switch_slot(modem, physical, cb)
{
	if (!modem.uim)
		return cb({ error: 'no_uim_client' });

	// idempotency guard: switching to the already-active slot would still
	// bounce the SIM (and with it the registration) on most firmwares —
	// read the slot status first and no-op when nothing would change.
	modem.uim.request('GET_SLOT_STATUS', {}, (gerr, data) => {
		let cur = null;

		if (!gerr)
			for (let i, s in (data?.slots ?? []))
				if (s.slot_status == 1 && s.logical_slot == 1)
					cur = i + 1;

		if (cur != null && cur == +physical)
			return cb(null, { unchanged: true });

		modem.uim.request('SWITCH_SLOT', {
			logical: 1, physical: physical,
		}, (err) => cb(err ?? null));
	});
};

// hot-reset the SIM: power the card off and on again (slot 1-based). The modem
// drops its cached SIM state and re-reads the card — the working "apply" after
// an eSIM profile switch (the RG650E ignores the eUICC REFRESH, keeps serving
// the old profile's identity and ends up in limited service). Far lighter than
// a full modem reset: no USB re-enumeration, the data session recovers via the
// normal transient-loss path. NOTE the precedence here deliberately DIFFERS
// from apdu_backend (which probes native MBIM first): for the reset we prefer
// the HW-proven QMI-UIM path and keep the unvalidated MBIM UICC Reset as
// fallback:
//   QMI UIM POWER_OFF/ON_SIM (native, or over the QMI-over-MBIM passthrough)
//   -> native MBIM MS UICC Reset (pure-MBIM firmware)
//   -> AT CFUN=0/1 cycle (NCM/AT modems: powers the (U)SIM down with the
//      stack, the card is re-read on the way back up)
// cb(err).
export function power_cycle(modem, slot, cb)
{
	slot = (+slot >= 1) ? +slot : 1;

	let via_uim = () => {
		modem.uim.request('POWER_OFF_SIM', { slot: slot }, (offerr) => {
			// power on regardless: if off failed because the card was already
			// down, on still brings it back
			modem.uim.request('POWER_ON_SIM', { slot: slot }, (onerr) =>
				cb(onerr ?? offerr ?? null));
		});
	};

	let via_at = () => {
		if (!modem.at)
			return cb({ error: 'no_sim_reset_path' });

		modem.at.send('AT+CFUN=0', (e1) => {
			if (e1)
				return cb(e1);

			modem.at.send('AT+CFUN=1', (e2) => cb(e2 ?? null), { timeout: 15000 });
		}, { timeout: 15000 });
	};

	let via_mbim_or_at = () => {
		if (modem.mbim_uicc?.reset)
			return modem.mbim_uicc.reset((err) => err ? via_at() : cb(null));

		via_at();
	};

	if (modem.uim)
		return via_uim();

	// MBIM modem: prefer the QMI passthrough UIM (same proven path as native
	// QMI); fall through to the native UICC Reset / AT when unavailable
	if (modem._ensure_uim)
		return modem._ensure_uim(() => modem.uim ? via_uim() : via_mbim_or_at());

	via_mbim_or_at();
};

// --- raw APDU channel (eSIM/ES10 foundation) ---------------------------------

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
export const ISDR_AID = 'a0000005591010ffffffff8900000100';

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
};

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
};

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
};

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
};

// best-effort read of the three PLMN selector lists; a list reads as null
// when the file is absent (e.g. Telekom SIMs carry no user list)
// the AcT bitmask shared by EF 6F60 and QMI NAS preferred-networks: bit flags
// for the radio access technologies of one PLMN record.
const PLMN_ACT_UTRAN = 0x8000, PLMN_ACT_EUTRAN = 0x4000, PLMN_ACT_NGRAN = 0x0800, PLMN_ACT_GSM = 0x0080;

export function plmn_act_flags(bits)
{
	return {
		gsm:    !!(bits & PLMN_ACT_GSM),
		utran:  !!(bits & PLMN_ACT_UTRAN),
		eutran: !!(bits & PLMN_ACT_EUTRAN),
		ngran:  !!(bits & PLMN_ACT_NGRAN),
	};
};

export function plmn_act_bits(e)
{
	return (e.gsm ? PLMN_ACT_GSM : 0) | (e.utran ? PLMN_ACT_UTRAN : 0) |
	       (e.eutran ? PLMN_ACT_EUTRAN : 0) | (e.ngran ? PLMN_ACT_NGRAN : 0);
};

export function read_plmn_lists(modem, cb)
{
	let out = { user: null, nas: null, operator: null, home: null };

	// map a QMI NAS preferred-networks array to the display shape
	let map_nas = (arr) => map(arr ?? [], (e) => {
		let f = plmn_act_flags(e.rat);
		return { mcc: sprintf('%d', e.mcc),
		         mnc: (e.mnc >= 100) ? sprintf('%d', e.mnc) : sprintf('%02d', e.mnc),
		         gsm: f.gsm, utran: f.utran, eutran: f.eutran, ngran: f.ngran };
	});

	// AT fallback for the USER list: some modems reject a UIM EF read of 6F60
	// (HW-seen: Huawei E392 / EG06 return err 48) or have no UIM (NCM), yet
	// expose the list over AT+CPOL (AT+CPLS=0 selects it, AT+CPOL? dumps it).
	let at_user = (done) => {
		let at = modem.at;

		if (!at)
			return done();

		at.send('AT+CPLS=0', () => {
			at.send('AT+CPOL?', (err, res) => {
				if (!err) {
					let recs = atcmd.parse_cpol(res?.lines) ?? [];

					out.user = map(recs, (r) => ({ mcc: r.mcc, mnc: r.mnc,
						gsm: r.gsm, utran: r.utran, eutran: r.eutran, ngran: r.ngran }));
				}

				done();
			}, { timeout: 8000 });
		}, { timeout: 5000 });
	};

	// user list via the UIM EF, then AT
	let user_via_uim_at = (done) => {
		if (!modem.uim)
			return at_user(done);

		read_ef(modem, EF_PLMN_USER, (u) => {
			out.user = (u != null) ? decode_plmn_act(u) : null;

			if (out.user == null)
				return at_user(done);

			done();
		});
	};

	// NAS is a direct client on QMI (self.nas), only the async with_nas() lazy
	// passthrough on MBIM (and null on NCM) — go through with_nas for parity.
	let with_nas = modem.with_nas ?? ((cb) => cb(modem.nas ?? null));

	// the QMI NAS "preferred networks" list — a SEPARATE list from the SIM
	// EF 6F60 user list (on some modems they even differ: E392 shows 33 via NAS
	// vs 85 via AT+CPOL). Kept in out.nas so the two are managed independently.
	let read_nas = (done) => {
		with_nas((nas) => {
			if (!nas)
				return done();

			nas.request('GET_PREFERRED_NETWORKS', {}, (err, data) => {
				if (!err && data?.preferred_networks != null)
					out.nas = map_nas(data.preferred_networks);

				done();
			});
		});
	};

	// operator + home come only from the UIM EFs (no NAS/AT equivalent)
	let read_op_home = (done) => {
		if (!modem.uim)
			return done();

		read_ef(modem, EF_PLMN_OPER, (o) => {
			out.operator = (o != null) ? decode_plmn_act(o) : null;

			read_ef(modem, EF_PLMN_HOME, (h) => {
				out.home = (h != null) ? decode_plmn_act(h) : null;
				done();
			});
		});
	};

	// user list (EF 6F60) via UIM/AT, NAS list via NAS Get, then operator/home
	user_via_uim_at(() => read_nas(() => read_op_home(() => cb(out))));
};

// Write the USER-controlled preferred PLMN list (EF 6F60 / PLMNwAcT) via the
// standard 3GPP AT interface — backend-neutral (every backend has an AT side
// channel), avoiding a modem-specific QMI/UIM record-write. entries is the
// desired list IN PRIORITY ORDER: [ { mcc, mnc, gsm, utran, eutran, ngran } ].
//
// Sequence (27.007 §7.19): AT+CPLS=0 selects the user list; read the current
// records (AT+CPOL?), delete them (highest index first so lower indices don't
// shift), then write the new list at explicit indices 1..N. Per record the AcT
// flags are GSM,GSM-compact,UTRAN,E-UTRAN[,NG-RAN]; the 5th (NG-RAN) field is
// only emitted when 5G is requested, since LTE-only firmwares reject it.
// On success reads the list BACK through the QMI/UIM path (read_plmn_lists) so
// the caller can cross-verify the AT write actually landed in the SIM EF.
export function write_user_plmn(modem, entries, cb)
{
	let at = modem.at;
	let list = entries ?? [];
	let esc = (s) => replace(sprintf('%s', s ?? ''), /[^0-9]/g, '');

	// forward-declared: write_at / del_existing / try_write recurse (self-
	// referencing let arrows hit the ucode TDZ otherwise — see CLAUDE.md)
	let finish, write_at, del_existing, try_write, at_path;

	finish = () => {
		// cross-verify via the independent QMI/UIM read path (best-effort:
		// NCM modems without a UIM client just return null)
		read_plmn_lists(modem, (lists) => cb(null, { ok: true, written: length(list), user: lists.user }));
	};

	// AcT-field arities to try, in order: 5 fields (GSM,GSM-compact,UTRAN,E-UTRAN,
	// NG-RAN — Rel-15 / 5G modems), 4 (no NG-RAN — LTE modems), 0 (numeric-only,
	// oldest firmwares). The first arity a modem accepts is remembered so the rest
	// of the list writes without re-probing.
	let ACT_ARITIES = [ 5, 4, 0 ];
	let arity_i = 0;

	let acts_for = (e, arity) => {
		if (arity == 0)
			return '';

		let f = [ e.gsm ? 1 : 0, 0, e.utran ? 1 : 0, e.eutran ? 1 : 0 ];   // GSM,GSMc,UTRAN,E-UTRAN

		if (arity == 5)
			push(f, e.ngran ? 1 : 0);

		return ',' + join(',', f);
	};

	try_write = (i, plmn, ai) => {
		if (ai >= length(ACT_ARITIES))
			return cb({ error: 'cpol_write', at_index: i, plmn: plmn,
			            note: 'rejected at every AcT arity — SIM may be write-protected (ADM)' });

		at.send(sprintf('AT+CPOL=%d,2,"%s"%s', i + 1, plmn, acts_for(list[i], ACT_ARITIES[ai])), (werr) => {
			if (werr)
				return try_write(i, plmn, ai + 1);   // step down the AcT arity

			arity_i = ai;   // remember the arity this modem accepts
			write_at(i + 1);
		}, { timeout: 5000 });
	};

	write_at = (i) => {
		if (i >= length(list))
			return finish();

		let plmn = esc(list[i].mcc) + esc(list[i].mnc);

		if (!match(plmn, /^[0-9]{5,6}$/))
			return cb({ error: 'invalid_plmn', at_index: i, plmn: plmn });

		try_write(i, plmn, arity_i);
	};

	del_existing = (indices, k) => {
		if (k < 0)
			return write_at(0);

		// tolerate a delete error (record may already be empty)
		at.send(sprintf('AT+CPOL=%d', indices[k]), () => del_existing(indices, k - 1),
			{ timeout: 5000 });
	};

	// the AT+CPOL path (fallback / NCM): select the user list (some modems lack
	// AT+CPLS — tolerate), read the current records, clear them, write the new
	// order.
	at_path = () => {
		if (!at)
			return cb({ error: 'no_write_channel' });

		at.send('AT+CPLS=0', () => {
			at.send('AT+CPOL?', (err, res) => {
				let cur = err ? [] : (atcmd.parse_cpol(res?.lines) ?? []);
				let indices = sort(map(cur, (e) => e.index), (a, b) => a - b);

				del_existing(indices, length(indices) - 1);
			}, { timeout: 8000 });
		}, { timeout: 5000 });
	};

	// the EF 6F60 user list is written over AT+CPOL (UIM record write is refused
	// by the modems on hand); the QMI NAS "preferred networks" list is a separate
	// type written by write_nas_plmn().
	at_path();
};

// Write the QMI NAS "preferred networks" list (NAS Set Preferred Networks) —
// a separate list from the EF 6F60 user list (write_user_plmn). Via with_nas()
// so MBIM's QMI-over-MBIM passthrough has parity with QMI; NCM (no NAS) errors.
// entries: [ { mcc, mnc, gsm, utran, eutran, ngran } ]. Reads back via NAS Get.
export function write_nas_plmn(modem, entries, cb)
{
	let list = entries ?? [];
	let esc = (s) => replace(sprintf('%s', s ?? ''), /[^0-9]/g, '');
	let with_nas = modem.with_nas ?? ((cb2) => cb2(modem.nas ?? null));

	with_nas((nas) => {
		if (!nas)
			return cb({ error: 'no_nas_client' });

		let pn = [];

		for (let e in list) {
			let mcc = +esc(e.mcc), mnc = +esc(e.mnc);

			if (!(mcc >= 100 && mcc <= 999) || !(mnc >= 0 && mnc <= 999))
				return cb({ error: 'invalid_plmn', plmn: esc(e.mcc) + esc(e.mnc) });

			push(pn, { mcc: mcc, mnc: mnc, rat: plmn_act_bits(e) });
		}

		nas.request('SET_PREFERRED_NETWORKS',
			{ preferred_networks: pn, clear_previous: 1 }, (err) => {
				if (err)
					return cb({ error: 'nas_set', detail: err });

				// read back the NAS list for cross-verification
				read_plmn_lists(modem, (lists) => cb(null, { ok: true, written: length(list), nas: lists.nas }));
			});
	});
};

// pre-radio-on DEBUG dump (called by every backend right before it enables the
// radio): the current NAS preferred-networks list + the SIM/network state to
// the debug log. Never stalls bring-up (always cb()).
export function log_preradio(modem, log, cb)
{
	let with_nas = modem.with_nas ?? ((c) => c(modem.nas ?? null));

	log('debug', sprintf('pre-radio: sim/network imsi=%s iccid=%s reg=%J',
		modem.info?.imsi ?? '?', modem.info?.iccid ?? '?',
		modem.reg ?? modem.registration ?? null));

	with_nas((nas) => {
		if (!nas)
			return cb();

		nas.request('GET_PREFERRED_NETWORKS', {}, (err, data) => {
			let pn = err ? null : (data?.preferred_networks ?? []);

			log('debug', (pn == null) ? 'pre-radio: nas preferred networks unavailable'
				: sprintf('pre-radio: nas preferred networks = %d record(s) %J', length(pn), pn));

			cb();
		});
	});
};

// the effective configured PLMN list to restore: a per-SIM list (matched active
// card, wwand_sim option plmn_list) wins over the modem's (wwand_modem option
// plmn_list). { type, entries } or null.
export function effective_plmn_restore(modem)
{
	return modem.active_sim?.plmn_restore ?? modem.config?.plmn_restore ?? null;
};

// restore the configured user/NAS preferred list (run after SIM unlock, before
// registration — so a per-SIM list resolves). Logs any failure so a write-
// protected SIM / rejecting modem is visible. Always cb().
export function restore_preferred_plmn(modem, log, cb)
{
	let r = effective_plmn_restore(modem);

	if (type(r) != 'object' || type(r.entries) != 'array' || !length(r.entries))
		return cb();

	let kind = (r.type == 'nas') ? 'nas' : 'user';
	let writer = (kind == 'nas') ? write_nas_plmn : write_user_plmn;

	writer(modem, r.entries, (err, res) => {
		if (err)
			log('err', sprintf('%s preferred-list restore FAILED: %J', kind, err));
		else
			log('notice', sprintf('restored %d %s preferred-list record(s) from config', res.written, kind));

		cb();
	});
};

// sequential-provider ladder: try providers in order until one yields non-null.
const first_of = backend.first_of;

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

// read just the ICCID (UIM EF read -> DMS getter -> AT; modems whose UIM
// rejects raw EF reads, e.g. the EG06, fall through — no_recovery keeps a
// rejection off the reboot ladder). The MF-level EF-ICCID is readable BEFORE
// PIN unlock, so this identifies the active card and picks a matching per-SIM
// override (wwand_sim) before choosing the PIN. Already trailing-'f'-stripped,
// matching the ICCID shown in status/LuCI.
export function read_iccid(modem, cb)
{
	let chain = [];
	if (modem.uim)
		push(chain, (done) => read_ef(modem, EF_ICCID, (b) =>
			done(b != null ? hexmod.bytes_to_iccid(b) : null)));
	push(chain, (done) => modem.dms.request('GET_ICCID', {}, (e, d) =>
		done((!e && length(d?.iccid ?? '')) ? d.iccid : null), { no_recovery: true }));
	if (modem.at)
		push(chain, (done) => modem.at.send('AT+QCCID', (e, r) =>
			done(e ? null : at_digits(r?.lines, 18))));

	first_of(chain, cb);
};

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
};
