// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — SIM / SMS / eSIM / APDU daemon ops, extracted from daemon.uc.
// install() attaches the ubus-facing methods onto the daemon `self` (same
// pattern as netsel_ops.uc); modem/context state stays on self, the lazy
// esim loader is injected so the daemon keeps owning package presence.

'use strict';

import * as sim from 'wwand.sim';
import * as sms from 'wwand.sms';

export function install(self, o)
{
	let log = o.log;
	let check_modem = o.check_modem;
	let load_esim = o.load_esim;

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

	self.modem_sms_delete = function(ref, storage, index, cb) {
		let entry = check_modem(ref, cb);
		if (entry)
			sms.sms_delete(entry.modem, storage ?? 'SM', +index, cb);
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

	self.modem_esim = function(ref, op, params, cb) {
		let br = load_esim_bridge();

		if (!br)
			return cb({ error: 'esim_not_installed' });

		return br.modem_esim(ref, op, params, cb);
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
