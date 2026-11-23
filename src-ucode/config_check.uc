// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — live-config validation, kept out of the modem.uc closure.
//
// validate(self, log, cb): compare the live modem against self.config +
// modem_quirks and populate self.config_warnings = [ { check,
// severity:'warn'|'info', message, expected, actual } ]; a gated
// auto-correct hook (config.auto_correct_config, default OFF) re-applies
// known fixes, otherwise mismatches only warn. cb() always. Uses with_nas so
// it also works if extended to MBIM later.

'use strict';

import * as qmi_backend from 'wwand.qmi_backend';
import * as modem_quirks from 'wwand.modem_quirks';
import * as cell_lock from 'wwand.cell_lock';
import * as nasmod from 'wwand.codec.schema.nas';
import * as modem_common from 'wwand.modem_common';

// The acquisition-order checks over one GET_SYSTEM_SELECTION_PREFERENCE reply
// `d`, as config_warnings entries: a configured `rat_order` the modem does not
// hold, and a RAT the mode mask allows that the order leaves out — that one
// may never be searched for: a T99W175 with NR5G enabled and an order of
// lte,umts never tried SA (ddimension/wwand#75). Shared by the QMI validate
// pass below and the MBIM init (sync_rat_order). `rats` = the RAT slugs the
// modem supports (modem_common.mode_rats), or null when unknown: a mode mask
// often has every bit set, and an RG650E "allowing" GSM it has no radio for
// is not a gap (HW-seen on the Chateau, 2026-10-30). [] when the modem
// reports no order.
export function rat_order_warnings(config, d, rats)
{
	let out = [];
	let ao = d?.acquisition_order;

	if (type(ao) != 'array' || !length(ao))
		return out;

	let have = join(',', nasmod.rat_order_names(ao));
	let order = nasmod.rat_order_ids(config?.rat_order);

	if (order != null && !nasmod.rat_order_holds(ao, order))
		push(out, { check: 'rat_order', severity: 'warn',
			message: nasmod.rat_order_writable(ao)
				? sprintf('modem RAT order %s does not match configured rat_order "%s"',
					have, config.rat_order)
				: sprintf('configured rat_order "%s" is not applied: the modem\'s order %s has slots QMI cannot name (IoT technologies) — set it with the vendor command',
					config.rat_order, have),
			expected: config.rat_order, actual: have });

	// the mode bits that map to one radio interface; CDMA's bit pair is left
	// out, the order lists 1x and EVDO apart
	let live = d.mode_preference;
	let left_out = [];

	if (live != null)
		for (let name in [ 'gsm', 'umts', 'lte', 'td-scdma', 'nr5g' ])
			if ((live & nasmod.MODE_BITS[name]) && index(ao, nasmod.RAT_ORDER_IDS[name]) < 0 &&
			    (type(rats) != 'array' || index(rats, name) >= 0))
				push(left_out, name);

	if (length(left_out)) {
		let pron = (length(left_out) == 1) ? 'it' : 'them';

		push(out, { check: 'rat_order', severity: 'warn',
			message: sprintf('modem allows %s, but its RAT acquisition order (%s) leaves %s out, so the modem may never search for %s — set option rat_order',
				join(',', left_out), have, pron, pron),
			expected: join(',', left_out), actual: have });
	}

	return out;
};

// MBIM's half of `option rat_order`: the QMI init writes it beside the mode
// mask (modem_init_qmi step_confnet_apply) and validate() below checks it; an
// MBIM modem has neither pass, and the order is QMI-only state, so it goes
// through the QMI-over-MBIM passthrough NAS here — written when configured
// and different, then checked the same way. A modem without a passthrough
// keeps its own order; a configured one is then reported, not dropped
// silently. Replaces this function's earlier entries, so a re-init does not
// stack them. cb() always.
export function sync_rat_order(self, log, cb)
{
	let warn = (list) => {
		self.config_warnings = filter(self.config_warnings ?? [], (w) => w.check != 'rat_order');

		for (let w in list)
			push(self.config_warnings, w);

		cb();
	};

	let order = nasmod.rat_order_ids(self.config?.rat_order);

	self.with_nas((nas) => {
		if (!nas)
			return warn(order ? [ { check: 'rat_order', severity: 'warn',
				message: sprintf('rat_order "%s" is not applied: it needs QMI NAS, and this modem offers no QMI passthrough',
					self.config.rat_order),
				expected: self.config.rat_order, actual: null } ] : []);

		nas.request('GET_SYSTEM_SELECTION_PREFERENCE', {}, (err, d) => {
			if (err || !d)
				return warn([]);   // unreadable -> nothing to say

			if (order == null || nasmod.rat_order_holds(d.acquisition_order, order) ||
			    (type(d.acquisition_order) == 'array' && !nasmod.rat_order_writable(d.acquisition_order)))
				return warn(rat_order_warnings(self.config, d, modem_common.mode_rats(self)));

			log('notice', sprintf('setting RAT order "%s" (modem had %s)', self.config.rat_order,
				join(',', nasmod.rat_order_names(d.acquisition_order)) || '?'));

			// permanent, like the QMI init write (modem_init_qmi step_confnet_apply)
			nas.request('SET_SYSTEM_SELECTION_PREFERENCE', { acquisition_order: order, change_duration: 1 }, (serr) => {
				if (serr) {
					log('warn', sprintf('setting the RAT order failed: %J', serr));
					return warn(rat_order_warnings(self.config, d, modem_common.mode_rats(self)));
				}

				warn(rat_order_warnings(self.config, { ...d, acquisition_order: order }, modem_common.mode_rats(self)));
			}, { no_recovery: true });
		}, { no_recovery: true });
	});
};

// compare the live modem against self.config + modem_quirks and populate
// self.config_warnings = [ { check, severity:'warn'|'info', message, expected,
// actual } ]. Uses with_nas so it also works if extended to MBIM later. A
// gated auto_correct hook (config.auto_correct_config, default OFF) can then
// re-apply a known fix; otherwise the mismatch is only warned. cb() always.
export function validate(self, log, cb)
{
	cb = cb ?? (() => null);
	// refreshed on every init — except what the AT init owns (the 5G NR mode,
	// modem_common.init_commands), which may have run first and does not run
	// again before the next AT open
	self.config_warnings = filter(self.config_warnings ?? [], (w) => w.check == 'nr5g_mode');

	let quirks = modem_quirks.for_model(self.info?.model);

	// static per-firmware heads-up notes
	for (let w in (quirks.warn ?? []))
		push(self.config_warnings, {
			check: 'quirk', severity: 'info',
			message: w, expected: null, actual: null,
		});

	// parse-time dead-option notes ('pin' vs 'pincode' & co): the reset above
	// wiped the scaffolding seed, re-add them so they survive every re-init
	for (let n in (self.config?.config_notes ?? []))
		push(self.config_warnings, {
			check: 'config', severity: 'warn',
			message: n, expected: null, actual: null,
		});

	// a deferred init reset that never took (refused, or acked and the modem
	// stayed on the bus — modem_init_qmi.uc step_apply_init_reset). Nothing
	// re-requests it: the NV values are already written, so the quirk probe and
	// the idempotency guard both read "nothing to change" on every later boot
	// while the LIVE modem keeps the old values. Carried on `self` because the
	// reset happens before this function, which clears config_warnings.
	for (let r in (self._reset_unapplied ?? []))
		push(self.config_warnings, {
			check: 'init_reset', severity: 'warn',
			message: sprintf('%s needs a modem reset to take effect (the deferred init reset did not happen)', r),
			expected: null, actual: null,
		});

	let add = (check, severity, message, expected, actual) =>
		push(self.config_warnings, {
			check: check, severity: severity, message: message,
			expected: expected, actual: actual,
		});

	// forward-declared: these best-effort checks chain through async AT reads
	let check_locks, check_autoconnect, finish, maybe_autocorrect;

	// gated corrective action (example): re-apply the NAS system-selection
	// preference when it drifted from config. Only ACTS when the operator
	// opted in via config.auto_correct_config; otherwise it is a pure warn.
	maybe_autocorrect = (done) => {
		if (!self.config.auto_correct_config || !self.nas)
			return done();

		let fixable = filter(self.config_warnings, (w) =>
			w.check == 'mode_preference' || w.check == 'network_selection');

		if (!length(fixable))
			return done();

		let mask = qmi_backend.parse_modes(self.config.modes);
		let args = {};

		if (mask != null)
			args.mode_preference = mask;

		// with the MNC's width alongside it: `option mnc '030'` and '30' are
		// different operators and both become the integer 30 (libqmi 1.38, Set
		// System Selection Preference input 0x1A).
		if (self.config.mcc && self.config.mnc) {
			args.network_selection = {
				mode: nasmod.NETWORK_SELECTION_MANUAL,
				mcc: +self.config.mcc, mnc: +self.config.mnc,
			};
			args.mnc_pcs_digit =
				(modem_common.mnc_width(self.config.mnc) == 3) ? 1 : 0;
		}

		if (mask == null && args.network_selection == null)
			return done();

		args.change_duration = 1;   // permanent, like the init write (modem_init_qmi)

		log('notice', 'auto_correct_config: re-applying NAS system selection preference');
		self.nas.request('SET_SYSTEM_SELECTION_PREFERENCE', args, (err) => {
			if (err)
				log('warn', sprintf('auto_correct_config: re-apply failed: %J', err));

			done();
		}, { no_recovery: true });
	};

	finish = () => {
		if (length(self.config_warnings))
			log('warn', sprintf('config validation: %d issue(s) [%s]',
				length(self.config_warnings),
				join(' ', map(self.config_warnings, (w) => w.check))));
		else
			log('info', 'config validation: modem matches config');

		maybe_autocorrect(() => cb());
	};

	// autoconnect: a rogue modem-side autoconnect competes with wwand for the
	// data call. Quectel AT+QCFG="autoconnect" best-effort (also reuse the
	// attach-profile detail from reg_detail if a probe already populated it).
	check_autoconnect = () => {
		if (self.reg_detail?.attach?.autoconnect)
			add('autoconnect', 'warn',
				'modem attach profile has autoconnect enabled; it competes with wwand',
				'disabled', 'enabled');

		if (!self.at)
			return finish();

		self.at.send('AT+QCFG="autoconnect"', (e, r) => {
			if (!e)
				for (let l in (r?.lines ?? [])) {
					let m = match(l, /\+QCFG:\s*"autoconnect",([0-9]+)/);

					if (m && +m[1] > 0)
						add('autoconnect', 'warn',
							sprintf('modem autoconnect is enabled (mode %d); it competes with wwand for the data call', +m[1]),
							'disabled', sprintf('mode %d', +m[1]));
				}

			finish();
		}, { probe: true });   // not every Quectel has the setting (RG50xQ)
	};

	// cell locks: brought to what the config asks for — set when configured,
	// RELEASED when not (a stale lock keeps a modem searching for a cell that
	// may not be there), in whichever dialect the modem answers
	// (cell_lock.uc). The QMI modem syncs here and not after its AT init
	// (modem_common.run_at_init): this is where config_warnings are rebuilt,
	// and a modem without an AT port still has its NAS client.
	check_locks = () => cell_lock.sync(self, log, add, check_autoconnect);

	let want = qmi_backend.parse_modes(self.config.modes);
	let pinned = self.config.mcc && self.config.mnc;

	// NAS system-selection prefs: RAT mode mask, acquisition order and
	// auto/manual network selection. Read even when config constrains none
	// of them: a RAT the mode mask allows and the acquisition order leaves
	// out may never be searched for — a T99W175 with NR5G enabled and an
	// order of lte,umts never tried SA (ddimension/wwand#75).
	self.with_nas((nas) => {
		if (!nas)
			return check_locks();

		nas.request('GET_SYSTEM_SELECTION_PREFERENCE', {}, (err, d) => {
			if (err || !d)
				return check_locks();   // unreadable -> skip

			let live = (d.mode_preference != null) ? (d.mode_preference & nasmod.MODE_ALL) : null;

			// RAT/mode: modem must allow exactly the configured RAT set
			if (want != null && live != null && live != (want & nasmod.MODE_ALL)) {
				let extra = live & ~want & nasmod.MODE_ALL;
				let missing = want & ~live & nasmod.MODE_ALL;

				add('mode_preference', 'warn',
					sprintf('modem RAT mask 0x%02x does not match configured modes "%s" (0x%02x)%s%s',
						live, self.config.modes, want & nasmod.MODE_ALL,
						extra ? sprintf('; modem also allows 0x%02x', extra) : '',
						missing ? sprintf('; config also wants 0x%02x', missing) : ''),
					want & nasmod.MODE_ALL, live);
			}

			for (let w in rat_order_warnings(self.config, d, modem_common.mode_rats(self)))
				push(self.config_warnings, w);

			// network selection: config pins a PLMN -> expect manual; the GET
			// reply carries only the mode (u8), so a wrong manual PLMN is caught
			// later by registration, not here.
			if (self.config.mcc && self.config.mnc) {
				if (d.network_selection == nasmod.NETWORK_SELECTION_AUTOMATIC)
					add('network_selection', 'warn',
						sprintf('config pins PLMN %d/%02d but modem is in automatic network selection',
							+self.config.mcc, +self.config.mnc),
						'manual', 'automatic');
			}
			else if (d.network_selection == nasmod.NETWORK_SELECTION_MANUAL) {
				add('network_selection', 'info',
					'modem is in manual network selection but no PLMN is configured',
					'automatic', 'manual');
			}

			check_locks();
		}, { no_recovery: true });
	});
};
