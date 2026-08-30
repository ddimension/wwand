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
import * as hexmod from 'wwand.codec.hex';
import * as backend from 'wwand.backend';
import * as uimmod from 'wwand.codec.schema.uim';
import * as sim_plmn from 'wwand.sim_plmn';

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

			// remember it: every EF read on an unusable slot answers err 48,
			// and the LuCI status poll asks for four PLMN files a time
			// (6F60/61/62/7B) — four warnings per poll for a slot we already
			// know we cannot read.
			modem._no_card = true;

			// "no application" is not the same as "no card". A card that is
			// physically there but never answers sits in CARD_STATE_ERROR with
			// an error code that says why — `no ATR received` is what a SIM
			// inserted the wrong way round looks like, and reporting that as
			// `no_sim` sends people hunting for the wrong fault (it did:
			// BPi-R4 bring-up, hours spent on the slot wiring and the modem).
			for (let card in (data.card_status?.cards ?? [])) {
				if (card.card_state != uimmod.CARD_STATE_ERROR)
					continue;

				let why = uimmod.CARD_ERRORS[sprintf('%d', card.error_code)]
					?? sprintf('code %d', card.error_code);

				return cb({ blocked: true, reason: 'card_error',
				            card_error: why, card_error_code: card.error_code });
			}

			return cb({ blocked: true, reason: 'no_sim' });
		}

		modem._no_card = false;

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

		case uimmod.APP_STATE_CHECK_PERSONALIZATION_STATE: {
			// NOT a PIN/PUK lock — the modem asks the host to check network/SP
			// personalization. Unless a perso code is actually required the card
			// is usable. Some modems (Huawei E392) report this state PERSISTENTLY
			// over QMI-UIM while AT already reports the SIM READY, so a blanket
			// block here wedges a perfectly usable SIM.
			let ps = app.personalization_state;

			// a real, active personalization lock -> honest block
			if (ps == uimmod.PERSO_STATE_CODE_REQUIRED ||
			    ps == uimmod.PERSO_STATE_PUK_CODE_REQUIRED ||
			    ps == uimmod.PERSO_STATE_PERMANENTLY_BLOCKED) {
				return cb({
					blocked: true,
					reason: 'personalization',
					state: app.state,
					perso_state: ps,
					perso_feature: app.personalization_feature,
					perso_retries: app.personalization_retries,
				});
			}

			// no active lock: give the card a few polls to settle to READY (like
			// DETECTED/UNKNOWN); if it never leaves state 4 (the Huawei quirk),
			// let it through as ready.
			if ((tries ?? 0) < CARD_POLL_TRIES) {
				uloop.timer(modem.timing?.card_poll ?? CARD_POLL_MS,
					() => unlock_uim(modem, cb, (tries ?? 0) + 1));
				return;
			}

			return cb(null, {
				status: 'ready',
				pin1_state: app.pin1_state,
				pin1_retries: app.pin1_retries,
			});
		}

		case uimmod.APP_STATE_PUK1_OR_UPUK_REQUIRED: {
			// PUK-locked: surface it distinctly (LuCI/CLI show the PUK dialog)
			// with the remaining unblock attempts so the user knows the risk.
			let pukr = app.upin_replaces_pin1 ? found.card.upuk_retries : app.puk1_retries;
			return cb({ blocked: true, reason: 'puk_required',
			            puk_retries: pukr, retries: pukr });
		}

		default:
			// pin blocked, illegal, or an unmapped terminal state
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

		case 4: // blocked -> PUK required (5 = permanently blocked)
			return cb({ blocked: true, reason: 'puk_required',
			            puk_retries: pin1.unblock_retries, retries: pin1.unblock_retries });

		default: // permanently blocked, illegal
			return cb({ blocked: true, reason: 'pin_blocked', state: pin1.status });
		}
	});
}

export function unlock(modem, cb)
{
	if (modem.uim)
		return unlock_uim(modem, cb, 0);

	if (modem.dms)
		return unlock_dms(modem, cb, 0);

	// no QMI clients (native-MBIM-UICC or NCM modem): try to bring up the
	// passthrough UIM on demand (MBIM), else report cleanly — callers like the
	// eSIM apply path just continue; the backend's own init owns AT+CPIN.
	// Without this guard unlock_dms would null-deref modem.dms.
	if (modem._ensure_uim) {
		modem._ensure_uim((uim) => {
			if (uim && modem.uim)
				return unlock_uim(modem, cb, 0);

			cb(null, { status: 'no_unlock_backend' });
		});
		return;
	}

	return cb(null, { status: 'no_unlock_backend' });
};

// QMI codes where the transport rejected the op WITHOUT touching the PIN, so it
// is safe to try the next transport: MissingArgument 17, InvalidArgument 48,
// DeviceNotReady 52, AccessDenied 82, NotSupported 94. Real PIN results
// (IncorrectPin 12, PinBlocked 35) stop the chain so we never burn a retry on
// another transport. NoEffect 26 means already in the requested state = done.
const PINLOCK_FALLBACK = { '17': 1, '48': 1, '52': 1, '82': 1, '94': 1 };

// PUK entry: unblock a PUK-locked PIN1 and set a NEW pin in one operation (a
// PUK-locked card refuses plain verify). Transport chain UIM -> native MBIM
// (duck-typed modem.mbim_pin, keeps this base module free of mbim imports) ->
// AT+CPIN="<puk>","<newpin>". SAFETY: fall through ONLY after a QMI transport
// rejection that provably never reached the card (PINLOCK_FALLBACK codes) —
// an attempt that reached the card is terminal, whatever the transport said:
// ~10 wrong PUKs brick the SIM permanently, so no second transport may ever
// re-try the same PUK. cb(err, { unblocked, via, retries }).
export function unblock_puk(modem, puk, new_pin, cb)
{
	let chain = [];
	if (modem.uim)      push(chain, 'uim');
	if (modem.mbim_pin) push(chain, 'mbim');
	if (modem.at)       push(chain, 'at');

	if (!length(chain))
		return cb({ error: 'no_sim_transport' });

	let i = 0, attempt;

	attempt = () => {
		let be = chain[i++];

		let handle = (err, data) => {
			if (!err)
				return cb(null, { unblocked: true, via: be,
				                  retries: data?.retries ?? null });

			// only the QMI reject codes guarantee the card was not touched
			let transport_reject = (be == 'uim') &&
				(err.error == 'qmi') && PINLOCK_FALLBACK[sprintf('%d', err.code)];

			if (transport_reject && i < length(chain))
				return attempt();

			cb({ error: err.error ?? 'unblock_failed', detail: err,
			     retries: err.retries ?? data?.retries?.unblock });
		};

		if (be == 'uim')
			return modem.uim.request('UNBLOCK_PIN', {
				session: { session_type: uimmod.SESSION_TYPE_PRIMARY_GW_PROVISIONING, aid: '' },
				info: { pin_id: uimmod.PIN_ID_PIN1, puk: puk, new_pin: new_pin },
			}, (err, data) => handle(err ? { ...err, retries: data?.retries?.unblock } : null, data),
			{ no_recovery: true });

		if (be == 'mbim')
			return modem.mbim_pin.unblock(puk, new_pin, handle);

		// AT+CPIN with two arguments = PUK + new PIN (3GPP TS 27.007)
		modem.at.send(sprintf('AT+CPIN="%s","%s"', puk, new_pin),
			(err) => handle(err ? { error: 'at', detail: err } : null));
	};

	attempt();
};

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

// generic transparent-EF reader — lives in sim_plmn.uc (the EF read/write
// module); aliased here for the identity paths below
const read_ef = sim_plmn.read_ef;

// --- physical SIM slots ------------------------------------------------------

const CARD_STATES = { '0': 'unknown', '1': 'absent', '2': 'present' };

const decode_iccid = hexmod.decode_iccid;
const decode_eid = hexmod.decode_eid;

// slot list with card/activity state and identifying ICCID; err when the
// modem has no slot-status support (single-slot firmwares often lack it)
export function slot_status(modem, cb)
{
	// single-slot firmwares (e.g. old Huawei sticks) don't implement the
	// message at all — and LuCI polls this method every few seconds. Cache
	// the deterministic refusal instead of hammering the modem and flooding
	// the log on every poll.
	if (modem._slot_status_unsupported)
		return cb({ error: 'unsupported' }, null);

	// NCM/AT modems: dual-slot management via the vendor AT recipe
	// (modem_ncm.slot_status — Fibocom GTDUALSIM etc.)
	if (modem.slot_status)
		return modem.slot_status(cb);

	// native MBIM slot CIDs (MS BCE SysCaps/SlotInfoStatus/DeviceSlotMappings)
	// — the pure-MBIM fallback. They carry no per-slot ICCID/EID, so fill the
	// active slot's identity from what the modem itself reported.
	let via_mbim = () => {
		if (!modem.mbim_slots)
			return cb({ error: 'no_uim_client' }, null);

		modem.mbim_slots.status((err, slots) => {
			if (err)
				return cb(err, null);

			for (let s in slots)
				if (s.active && s.iccid == null)
					s.iccid = modem.info?.iccid ?? null;

			cb(null, slots);
		});
	};

	// this modem's QMI UIM refused GET_SLOT_STATUS earlier — go native directly
	if (modem._slot_via_mbim)
		return via_mbim();

	// MBIM modem: prefer the QMI passthrough UIM client (richer: per-slot
	// ICCID/EID, same proven path as APDU/power_cycle) — bring it up on
	// first use, then fall back to the native slot CIDs
	if (!modem.uim && modem._ensure_uim)
		return modem._ensure_uim(() =>
			modem.uim ? slot_status(modem, cb) : via_mbim());

	if (!modem.uim)
		return via_mbim();

	modem.uim.request('GET_SLOT_STATUS', {}, (err, data) => {
		if (err) {
			// 71 InvalidQmiCommand / 94 NotSupported: permanent for this fw —
			// go native MBIM when available, otherwise cache the refusal
			if (err.code == 71 || err.code == 94) {
				if (modem.mbim_slots) {
					modem._slot_via_mbim = true;
					return via_mbim();
				}
				modem._slot_status_unsupported = true;
			}
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

// Summarise the multi-SIM shape of a modem from a slot list. Read-only: this
// says what the hardware IS, never changes it.
//
// The vocabulary is MBIM's, because MBIM is the protocol that names it — a
// *slot* holds a card, an *executor* is a cellular stack that can register, and
// the two are mapped onto each other. MS Basic Connect Extensions reports the
// counts directly (SYS_CAPS: NumberOfExecutors / NumberOfSlots / Concurrency).
// QMI has no equivalent message at all: Qualcomm's own MBIM implementation
// writes the executor count and concurrency as literal 1 rather than asking the
// modem, which is as clear a statement as one could want that the question is
// not askable over QMI. There the executor count is inferred from how many
// DISTINCT logical slots the physical slots report, which is a lower bound and
// is marked as such.
//
//   1 executor              -> DSSA, dual SIM single active (slot switching)
//   >1, concurrency 1       -> DSDS, both registered, one carries traffic
//   concurrency >1          -> DSDA, both usable at once
//
// wwand implements DSSA. The rest is reported so that anyone holding hardware
// that can do more can say so, which is the one thing we cannot do ourselves.
export function multisim(slots, caps)
{
	let n_slots = length(slots ?? []);

	if (!n_slots)
		return null;

	// distinct logical slots actually claimed by a card; null where the modem
	// does not report one (MBIM's native path only knows the active slot's)
	let logical = {};

	for (let s in slots)
		if (s.logical_slot != null)
			logical[sprintf('%d', s.logical_slot)] = true;

	let inferred = length(keys(logical));
	let executors = caps?.number_of_executors ?? (inferred > 0 ? inferred : null);
	let concurrency = caps?.concurrency ?? null;
	let mode = null;

	if (executors != null && executors <= 1)
		mode = 'dssa';
	else if (executors != null && concurrency != null)
		mode = (concurrency > 1) ? 'dsda' : 'dsds';

	return {
		slots: n_slots,
		executors: executors,
		concurrency: concurrency,
		mode: mode,
		// 64-bit modem identity, MBIM only. Its purpose there is to tell you
		// that several control nodes belong to one physical modem; over QMI the
		// question does not arise, because there is only ever one node.
		modem_id: caps?.modem_id ?? null,
		// where the numbers came from, because they are not equally trustworthy
		source: caps ? 'mbim-sys-caps' : 'qmi-logical-slots',
		exact: caps != null,
	};
};

export function switch_slot(modem, physical, cb)
{
	// native MBIM DEVICE_SLOT_MAPPINGS set — pure-MBIM fallback (carries its
	// own idempotency guard in mbim_backend.slot_switch)
	let via_mbim = () => modem.mbim_slots
		? modem.mbim_slots.switch_to(physical, cb)
		: cb({ error: 'no_uim_client' });

	// NCM/AT modems: vendor AT slot switch (modem_ncm.switch_slot)
	if (modem.switch_slot)
		return modem.switch_slot(physical, cb);

	if (modem._slot_via_mbim)
		return via_mbim();

	// MBIM modem: same passthrough-UIM bring-up as slot_status above
	if (!modem.uim && modem._ensure_uim)
		return modem._ensure_uim(() =>
			modem.uim ? switch_slot(modem, physical, cb) : via_mbim());

	if (!modem.uim)
		return via_mbim();

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
			// the session id comes either with a +CCHO: prefix or as a BARE
			// integer line — the T700 answers the bare form (field-verified)
			let m = match(l, /\+CCHO: *([0-9]+)/) ?? match(l, /^([0-9]+)$/);

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
// Implementation extracted to sim_plmn.uc (PLMN/FPLMN codec + EF read/write);
// re-exported here so consumers keep the stable sim.<name> API.

export const decode_plmn_act = sim_plmn.decode_plmn_act;
export const decode_fplmn = sim_plmn.decode_fplmn;
export const encode_fplmn = sim_plmn.encode_fplmn;
export const read_fplmn = sim_plmn.read_fplmn;
export const write_fplmn = sim_plmn.write_fplmn;
export const plmn_act_flags = sim_plmn.plmn_act_flags;
export const plmn_act_bits = sim_plmn.plmn_act_bits;
export const read_plmn_lists = sim_plmn.read_plmn_lists;
export const write_user_plmn = sim_plmn.write_user_plmn;
export const write_nas_plmn = sim_plmn.write_nas_plmn;
export const write_plmn = sim_plmn.write_plmn;
export const log_preradio = sim_plmn.log_preradio;
export const effective_plmn_restore = sim_plmn.effective_plmn_restore;
export const restore_preferred_plmn = sim_plmn.restore_preferred_plmn;

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
	if (modem.dms)
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
	if (modem.dms)
		push(imsi_chain, (done) => modem.dms.request('GET_IMSI', {}, (e, d) =>
			done((!e && length(d?.imsi ?? '')) ? d.imsi : null), { no_recovery: true }));
	if (modem.at)
		push(imsi_chain, (done) => modem.at.send('AT+CIMI', (e, r) =>
			done(e ? null : at_digits(r?.lines, 14))));

	first_of(imsi_chain, (imsi) => {
		out.imsi = imsi;

		read_iccid(modem, (iccid) => {
			out.iccid = iccid;

			if (!modem.dms)
				return cb(out);

			modem.dms.request('GET_MSISDN', {}, (err, data) => {
				if (!err)
					out.msisdn = data.msisdn;

				cb(out);
			});
		});
	});
};
