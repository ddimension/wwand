// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — SIM / SMS / eSIM / APDU daemon ops, kept apart from daemon.uc.
// install() attaches the ubus-facing methods onto the daemon `self` (same
// pattern as netsel_ops.uc); modem/context state stays on self, the lazy
// esim loader is injected so the daemon keeps owning package presence.

'use strict';

import * as uloop from 'uloop';
import * as sim from 'wwand.sim';
import * as sms from 'wwand.sms';

export function install(self, o)
{
	let log = o.log;
	let check_modem = o.check_modem;
	let load_esim = o.load_esim;

	// injectable so the deferred card re-read can be driven from a test: this
	// module's only timer is armed after a slot switch, long after the suite's
	// uloop has stopped (tests/test_sim.uc runs it at :1548 and the simops
	// block sits below that), so a real uloop.timer there is unobservable.
	let defer = o.defer ?? ((ms, fn) => uloop.timer(ms, fn));

	// physical SIM slots: list (status page) and switch (guarded; the modem
	// re-initializes the SIM stack after a switch, recovery handles the rest)
	self.modem_sim_slots = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		sim.slot_status(entry.modem, (err, slots) => {
			if (err)
				return cb({ error: 'sim_transport', detail: err });

			// alongside the slots, what SHAPE of multi-SIM this modem is. Purely
			// descriptive — see sim.multisim. It is the one thing we cannot
			// determine for hardware we do not own, so it is worth reporting
			// wherever someone does own it.
			// On MBIM the exact figures come from SYS_CAPS, and they are worth
			// one extra round trip: a modem carrying the QMI-over-MBIM
			// passthrough answers the slot list over QMI-UIM, so without asking
			// separately we would infer what the modem can simply state.
			if (entry.modem?.read_multisim_caps)
				return entry.modem.read_multisim_caps((caps) =>
					cb(null, { slots: slots, multisim: sim.multisim(slots, caps) }));

			cb(null, { slots: slots, multisim: sim.multisim(slots, null) });
		});
	};

	// The modem's own read of an eUICC's profiles, without lpac. See
	// sim.euicc_profiles: this is for the card lpac structurally cannot
	// enumerate — an M2M eUICC with no local ES10 — not a replacement for it.
	self.modem_euicc_profiles = function(ref, slot, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		sim.euicc_profiles(entry.modem, slot, (err, profiles) => {
			if (err)
				return cb({ error: 'euicc_read', detail: err });

			cb(null, { slot: +(slot ?? 1) || 1, profiles: profiles });
		});
	};

	self.modem_sim_switch_slot = function(ref, physical, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (!(physical > 0))
			return cb({ error: 'invalid_slot' });

		sim.switch_slot(entry.modem, physical, (err, res) => {
			if (err)
				return cb({ error: 'sim_transport', detail: err });

			// idempotency guard: slot already active — nothing switched, keep caches
			if (res?.unchanged) {
				log('info', sprintf('modem %s: SIM slot %d already active — not switching', ref, physical));
				return cb(null, { slot: physical, unchanged: true });
			}

			// a different slot may hold a different eUICC — drop the cached
			// eSIM/APDU backends so they are re-probed, and clear the
			// once-per-object refresh guard + the stale surface data
			delete entry.modem._esim_be;
			delete entry.modem._apdu_be;
			delete entry.modem._esim_refreshed;
			delete entry.modem.esim_info;

			// AND THE CARD ITSELF, which that list forgot. Everything cleared
			// below describes the card that just left: its identity, the slot
			// it sat in, and the card-side events the UIM indications reported
			// about it. None of it is re-read on its own — a slot switch does
			// not restart the init chain — so the status page went on showing
			// the previous SIM's ICCID and its parting "session closed: card
			// removed" indefinitely, through a switch BACK as well, because
			// nothing on either path ever clears them (evidence:
			// ddimension/wwand#39, NR7101).
			//
			// modem.uc:1531-1536 already states the rule — card-side
			// diagnostics belong to the card we were talking to — and acts on
			// it during teardown. This path is the other place a card changes
			// underneath us, and it did not.
			let m = entry.modem;

			m.sim_note = null;
			m.sim_busy = false;
			m.active_slot = null;

			// AND THE MATCHED PER-SIM OVERRIDE, which is the one that can do
			// damage rather than merely mislead. `active_sim` is the wwand_sim
			// entry resolved for the card that just left, and effective_pincode
			// prefers its `pincode` over the modem's own (sim.uc:57-70) — so
			// the unlock scheduled below would have offered the OLD card's PIN
			// to the new one and spent one of three attempts on it. Its APN and
			// credentials would have applied too, until a reapply replaced it.
			m.active_sim = null;

			if (m.info) {
				m.info.iccid = null;
				m.info.imsi = null;
				m.info.msisdn = null;
			}

			// ...then read the card that arrived, the way an eSIM profile
			// switch does (esim_bridge apply_sim_reset): give the firmware a
			// moment, unlock — a PIN can re-arm with a different card — and
			// run the full per-SIM reapply, which re-matches the wwand_sim
			// override and the attach profile.
			//
			// RE-CHECKED WHEN THE TIMER FIRES, not when it is armed, and on TWO
			// counts. On the AT backends the switch ends in a CFUN reset that
			// re-enumerates the modem, so `entry.modem` can by then be a
			// different object or gone — identity covers that. But ordinary
			// backend recovery tears the SAME object down and starts it again
			// (modem_common make_fail), which identity does not see: the timer
			// belongs to this module, not to the modem, so it outlives the
			// teardown and would talk to a client that is mid-initialisation.
			// `_gen` is the counter both backends already bump on teardown
			// (modem.uc:1475, modem_mbim.uc:1891); NCM has none and degrades to
			// the identity check, which is the case its reset already answers.
			let gen = m._gen;

			if (m.reapply_sim)
				defer(2000, () => {
					if (self.modems?.[ref]?.modem !== m || m._gen !== gen)
						return;

					sim.unlock(m, () => m.reapply_sim());
				});

			log('notice', sprintf('modem %s: switched to SIM slot %d', ref, physical));
			cb(null, { slot: physical });
		});
	};

	self.modem_sim_pin_lock = function(ref, pin, enable, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (!length(pin ?? ''))
			return cb({ error: 'missing_pin' });

		sim.set_pin_lock(entry.modem, enable, pin, (err, res) => {
			if (!err)
				log('notice', sprintf('modem %s: SIM PIN query %s', ref, enable ? 'enabled' : 'disabled'));
			cb(err, res);
		});
	};

	// raw APDU channel (eSIM foundation; also used by the lpac glue).
	// op: 'open' {slot, aid} -> {channel, select_response}
	//     'send' {slot, channel, apdu} -> {response}
	//     'close' {slot, channel} -> {}
	self.modem_apdu = function(ref, op, params, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let slot = +(params?.slot ?? 1);

		switch (op) {
		case 'open':
			return sim.apdu_open(entry.modem, slot, params?.aid ?? '', (err, res) =>
				cb(err ? { error: 'sim_transport', detail: err } : null, res));

		case 'send':
			return sim.apdu_send(entry.modem, slot, +(params?.channel ?? 0), params?.apdu ?? '',
				(err, res) => cb(err ? { error: 'sim_transport', detail: err } : null,
				                 err ? null : { response: res }));

		case 'close':
			return sim.apdu_close(entry.modem, slot, +(params?.channel ?? 0), (err) =>
				cb(err ? { error: 'sim_transport', detail: err } : null, err ? null : {}));

		default:
			return cb({ error: 'invalid_op', op: op });
		}
	};

	// SMS list/read/delete. `storage` 'SM' (SIM) or 'ME' (modem). Backend-neutral
	// (sms.uc dispatches QMI-WMS / MBIM / AT); unsupported_on_backend when none.
	self.modem_sms_list = function(ref, storage, cb) {
		let entry = check_modem(ref, cb);
		if (entry)
			sms.sms_list(entry.modem, storage ?? 'SM', cb);
	};

	self.modem_sms_read = function(ref, storage, index, cb) {
		let entry = check_modem(ref, cb);
		if (entry)
			sms.sms_read(entry.modem, storage ?? 'SM', +index, cb);
	};

	// `indices` deletes a SET in one call; `index` stays for the single-message
	// callers that predate it (and keeps their plain { ok: true } reply shape).
	// Not a "delete all": see the comment on sms.sms_delete for why a bulk
	// primitive is the wrong thing to expose here at all.
	self.modem_sms_delete = function(ref, storage, index, indices, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		// AN EMPTY SELECTION MUST NOT DELETE ANYTHING.
		//
		// An omitted `index` reaches here as null, and `+null` is 0 in ucode
		// (measured on the host interpreter, 2026-09-19) — so `indices: []`
		// used to fall through to "delete index 0" and issue a real delete.
		// HW-confirmed on an NR7101: the modem answered +CMS ERROR 321
		// (invalid memory index), which it only does because the command was
		// actually sent. On a card whose slot 0 is occupied, that message
		// would simply be gone (2026-09-12).
		//
		// ubus does NOT default-fill a declared argument: the policy in ubus.uc
		// is validation only, and req.args carries what the caller sent and
		// nothing else. Either mechanism produces the same symptom, which makes
		// the wrong one easy to believe — and believing it invites
		// "fixing" the `?? default` patterns elsewhere in this tree that work
		// precisely because the key is absent.
		//
		// So a positive index is required. SMS storage records are numbered from
		// 1 (3GPP TS 51.011 EF_SMS is a linear fixed file, record 1 upwards), so
		// this refuses nothing a modem can actually address.
		let which = (type(indices) == 'array' && length(indices)) ? indices
			: ((+index > 0) ? +index : null);

		if (which == null)
			return cb({ error: 'no_index' }, null);

		sms.sms_delete(entry.modem, storage ?? 'SM', which, cb);
	};

	self.modem_sms_send = function(ref, number, text, cb) {
		let entry = check_modem(ref, cb);
		if (entry)
			sms.sms_send(entry.modem, number, text, cb);
	};

	// eSIM download/notification bridge (optional wwand-esim, esim_bridge.uc); lazy.
	let esim_bridge = null;
	let load_esim_bridge = () => {
		if (esim_bridge === false)
			return null;

		if (!esim_bridge) {
			let esim = load_esim();
			let mod = null;

			if (esim) {
				try { mod = require('wwand.esim_bridge'); }
				catch (e) { mod = null; }
			}

			if (!mod) {
				esim_bridge = false;
				return null;
			}

			esim_bridge = mod.create({
				esim: esim,
				log: log,
				modem_of: (ref) => self.modems[ref],
			});
		}

		return esim_bridge;
	};

	// Operations that change what is on the card or tell the SM-DP+ about it.
	// Refused on a card the eIM manages (`option ipa`): in IoT eUICC emulation
	// the assistant keeps the card's state in its own nvstate (the profile to
	// roll back to, the pending results), and a change made past it leaves
	// that out of step with the card — the next eIM package then acts on a
	// profile that is not there. Pending notifications belong to the eIM too:
	// sent by lpac they are removed from the card before the eIM sees them.
	// `force: true` is the way past it, for a technician who knows.
	// forward-declared: modem_esim below uses it, and a `let` declared further
	// down is an undeclared variable to a closure created above it
	let load_ipa;

	const IPA_LOCKED = { download: true, enable: true, disable: true, delete: true, notify: true };

	self.modem_esim = function(ref, op, params, cb) {
		let br = load_esim_bridge();

		if (!br)
			return cb({ error: 'esim_not_installed' });

		// and only while something actually manages it: with option ipa set
		// but wwand-ipa missing, nothing keeps a record to protect, and a lock
		// then only blocks the one way left to change the card
		if (IPA_LOCKED[op] && self.modems[ref]?.ipa?.ipa && !params?.force && load_ipa())
			return cb({ error: 'ipa_managed',
			            detail: 'this card is managed by an eIM (option ipa); pass force to override' });

		return br.modem_esim(ref, op, params, cb);
	};

	// The connection generation of a modem: a token that changes with every new
	// data session and is null while none is up. The IPA waits on it after a
	// profile change — "connected" alone is true again before the old session
	// has even been dropped. Contexts in name order, so a modem with two
	// interfaces answers the same one each time.
	let online_token = (ref) => {
		for (let name in sort(keys(self.contexts))) {
			let c = self.contexts[name];

			if (c?.cfg?.modem == ref && c.ctx?.state == 'CONNECTED')
				return sprintf('%s:%d', name, c._conn_seq ?? 0);
		}

		return null;
	};
	self._online_token = online_token;   // test seam (test_ipa)

	// eSIM fleet management (optional wwand-ipa, ipa.uc); lazy, and loaded
	// only once a modem carries `option ipa`. It runs through the eSIM bridge,
	// so without wwand-esim there is nothing to load.
	let ipa = null;
	load_ipa = () => {
		if (ipa === false)
			return null;

		if (!ipa) {
			let br = load_esim_bridge();
			let mod = null;

			if (br) {
				try { mod = (o.require_ipa ?? (() => require('wwand.ipa')))(); }
				catch (e) { mod = null; }
			}

			if (!mod) {
				ipa = false;
				log('warn', 'ipa: a modem has option ipa, but wwand-ipa is not installed');
				return null;
			}

			ipa = mod.create({
				bridge: br,
				esim: load_esim(),
				log: log,
				modem_of: (ref) => self.modems[ref],
				online: online_token,
				// installed on self by hwops.install, which runs after this
				// module's install: resolved at call time, not now
				modem_reset: (ref, cb) => self.modem_reset(ref, cb),
				// the same record the esim_ready bring-up read fills (status
				// `esim`), so what the eIM changed shows up there
				refresh: (ref, eid, slot, cb) => self.modem_esim(ref, 'profiles', { slot: slot }, (e, r) => {
					let m = self.modems[ref]?.modem;

					if (e || !m)
						return;

					m.esim_info = { eid: eid, profiles: r?.profiles ?? [] };
					cb?.(m.esim_info.profiles);
				}),
			});
		}

		return ipa;
	};

	self.ipa_tick = function() {
		for (let name, entry in self.modems)
			if (entry?.ipa?.ipa)
				load_ipa()?.tick(name, entry.ipa);
	};

	self.modem_ipa = function(ref, op, params, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let m = load_ipa();

		if (!m)
			return cb({ error: 'ipa_not_installed' });

		switch (op ?? 'status') {
		case 'status':
			return cb(null, m.status(ref, entry.ipa));

		case 'poll':
			if (!entry.ipa?.ipa)
				return cb({ error: 'ipa_disabled', detail: 'set option ipa on this modem' });

			return m.poll(ref, entry.ipa, cb);

		default:
			return cb({ error: 'invalid_op', op: op });
		}
	};

	// SIM PLMN selector lists (settings editor; user list is editable on SIMs
	// that carry EF 6F60 — absent lists read as null)
	self.modem_plmn_lists = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		// read_plmn_lists falls back to AT+CPOL for the user list, so a modem
		// with no UIM client (NCM) or one that rejects UIM EF reads (E392) still
		// returns its user list; MBIM modems get the passthrough UIM on demand
		// (_ensure_uim). Only a modem with none of the three is stuck.
		if (!entry.modem.uim && !entry.modem.at && !entry.modem._ensure_uim)
			return cb({ error: 'no_sim_transport' });

		sim.read_plmn_lists(entry.modem, (lists) => cb(null, lists));
	};

	// write a preferred-PLMN list. `list_type` selects which one: 'nas' (the QMI
	// NAS preferred-networks list) or 'user' (the SIM EF 6F60 user list via
	// AT+CPOL). entries: [ { mcc, mnc, gsm, utran, eutran, ngran } ] in priority
	// order; the daemon reads it back for cross-verification.
	self.modem_plmn_set = function(ref, list_type, entries, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (type(entries) != 'array')
			return cb({ error: 'invalid_entries' });

		if (index([ 'user', 'nas', 'fplmn' ], list_type) < 0)
			return cb({ error: 'invalid_list_type', list_type: list_type });

		log('notice', sprintf('modem %s: writing %d %s PLMN record(s)', ref, length(entries), list_type));

		sim.write_plmn(entry.modem, list_type, entries, cb);
	};

	// apply this modem's configured plmn list (wwand_modem option plmn_list) on
	// demand — the "restore now" button. Uses the same type-aware write + logging
	// as the pre-radio-on hook.
	self.modem_plmn_restore = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		// the effective list = per-SIM (active card) override, else the modem's —
		// same resolution as the boot-time restore, so "restore now" applies the
		// SAME list the daemon would at radio-on.
		let r = sim.effective_plmn_restore(entry.modem);

		if (type(r) != 'object' || type(r.entries) != 'array' || !length(r.entries))
			return cb({ error: 'no_configured_list' });

		let kind = (r.type == 'nas') ? 'nas' : (r.type == 'fplmn') ? 'fplmn' : 'user';

		log('notice', sprintf('modem %s: restoring the configured %s list (%d records)',
			ref, kind, length(r.entries)));

		sim.write_plmn(entry.modem, kind, r.entries, cb);
	};

	// manual PIN release: enter the PIN past the low-retry safety block (with <=1
	// attempt left the daemon refuses to auto-enter, to avoid burning the last try
	// into a PUK lock). Optional `pin` overrides the configured one. The one-shot
	// pin_force/_pin_override flags clear on the next registered/sim_blocked event.
	self.sim_pin_verify = function(ref, pin, cb) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return cb({ error: 'no_such_modem', ref: ref });

		entry.modem.pin_force = true;

		if (pin != null && pin != '')
			entry.modem._pin_override = pin;

		log('warn', sprintf('modem %s: manual PIN release requested (entering PIN past the low-retry guard)', ref));

		entry.modem.stop();
		entry.modem.start();

		cb(null, { ok: true });
	};

	// PUK entry (ubus modem_sim_puk): unblock a PUK-locked SIM and set a NEW
	// PIN in one operation. Digits-only validation keeps it AT/shell-safe; the
	// transport chain in sim.unblock_puk never retries a PUK on a second
	// transport (wrong PUKs brick the SIM). On success the state machine
	// restarts with the new PIN as a one-shot override — the CONFIGURED
	// pincode must still be updated by the user (surfaced in the reply).
	self.sim_puk_unblock = function(ref, puk, new_pin, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (!match(puk ?? '', /^[0-9]{8}$/))
			return cb({ error: 'invalid_puk', detail: 'PUK must be 8 digits' });

		if (!match(new_pin ?? '', /^[0-9]{4,8}$/))
			return cb({ error: 'invalid_pin', detail: 'new PIN must be 4-8 digits' });

		log('warn', sprintf('modem %s: PUK entry requested (unblock + set new PIN)', ref));

		sim.unblock_puk(entry.modem, puk, new_pin, (err, res) => {
			if (err)
				return cb(err);

			entry.modem._pin_override = new_pin;
			entry.modem.pin_force = true;
			entry.modem.stop();
			entry.modem.start();

			cb(null, { ...res,
				note: 'SIM unblocked - update the configured pincode to the new PIN' });
		});
	};
};
