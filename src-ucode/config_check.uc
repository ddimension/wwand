// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — live-config validation (extracted from the modem.uc mega-closure).
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
import * as atcmd from 'wwand.atcmd';
import * as nasmod from 'wwand.codec.schema.nas';

// compare the live modem against self.config + modem_quirks and populate
// self.config_warnings = [ { check, severity:'warn'|'info', message, expected,
// actual } ]. Uses with_nas so it also works if extended to MBIM later. A
// gated auto_correct hook (config.auto_correct_config, default OFF) can then
// re-apply a known fix; otherwise the mismatch is only warned. cb() always.
export function validate(self, log, cb)
{
	cb = cb ?? (() => null);
	self.config_warnings = [];   // refreshed on every init

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

		if (self.config.mcc && self.config.mnc)
			args.network_selection = {
				mode: nasmod.NETWORK_SELECTION_MANUAL,
				mcc: +self.config.mcc, mnc: +self.config.mnc,
			};

		if (mask == null && args.network_selection == null)
			return done();

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
		});
	};

	// A LOCK THE CONFIG NO LONGER ASKS FOR IS RELEASED.
	//
	// cell_lock_commands() only ever emits a lock when one is CONFIGURED, so
	// deleting `lock_4g` used to leave the modem locked forever: nothing was
	// sent, and the modem kept searching for a cell that may not exist. With
	// `lock_persist` the lock is in modem NV, so it survived reboots and
	// AT+CFUN resets too — a box that could not be recovered by editing the
	// config at all. Found on an NR7101 locked to EARFCN 1300 / PCI 246, a cell
	// not receivable there: permanent "servingcell","SEARCH", never attached
	// (2026-09-11). Releasing it brought the modem up on EARFCN 6300 within
	// seconds.
	//
	// Read-before-write, like every other setting in this tree: the release is
	// sent only when the modem actually reports a lock, so a box that never had
	// one costs one read. `save_ctrl` follows a release because the lock being
	// cleared may have been persisted by an EARLIER config — without it a power
	// cycle would restore it (HW-verified on the NR7101).
	let release_lock = (which, cb) => {
		if (!self.at)
			return cb();

		self.at.send(sprintf('AT+QNWLOCK="common/%s"', which), (e, r) => {
			let lk = e ? null : atcmd.parse_qnwlock(r?.lines);

			if (!lk || !lk.enabled)
				return cb();

			log('notice', sprintf('modem reports a %s cell lock the config does not ask for — releasing it (a lock nothing configured keeps the modem searching for a cell that may not be there)',
				uc(which)));

			self.at.send(sprintf('AT+QNWLOCK="common/%s",0', which), (e2) => {
				if (e2) {
					add(sprintf('lock_%s', which), 'warn',
						sprintf('a %s cell lock is set on the modem and could not be released: %J',
							uc(which), e2), 'released', 'still set');
					return cb();
				}

				// persist the RELEASE, in case the lock was saved to NV
				self.at.send('AT+QNWLOCK="save_ctrl",1,1', () => cb());
			});
		});
	};

	// cell locks: if config sets lock_4g/lock_5g, read them back (best-effort
	// AT+QNWLOCK) and warn if the modem reports them off / unreadable. When it
	// sets NEITHER, make sure the modem is not carrying one from an older
	// config — see release_lock above.
	check_locks = () => {
		let l4 = self.config.lock_4g ?? [];

		if (type(l4) == 'string')
			l4 = [ l4 ];

		let l5 = self.config.lock_5g;

		if (!self.at)
			return check_autoconnect();

		if (!length(l4) && !l5)
			return release_lock('4g', () => release_lock('5g', check_autoconnect));

		let check5 = () => {
			if (!l5)
				return check_autoconnect();

			self.at.send('AT+QNWLOCK="common/5g"', (e, r) => {
				let lk = atcmd.parse_qnwlock(r?.lines);

				if (e || !lk || !lk.enabled)
					add('lock_5g', 'warn',
						sprintf('configured 5G cell lock %s is not applied on the modem', l5),
						l5, (lk && lk.enabled) ? 'set' : 'off');

				check_autoconnect();
			});
		};

		if (!length(l4))
			return check5();

		self.at.send('AT+QNWLOCK="common/4g"', (e, r) => {
			let lk = atcmd.parse_qnwlock(r?.lines);

			if (e || !lk || !lk.enabled)
				add('lock_4g', 'warn',
					sprintf('configured 4G cell lock [%s] is not applied on the modem', join(',', l4)),
					l4, (lk && lk.enabled) ? 'set' : 'off');

			check5();
		});
	};

	let want = qmi_backend.parse_modes(self.config.modes);
	let pinned = self.config.mcc && self.config.mnc;

	// NAS system-selection prefs: RAT mode mask + auto/manual network
	// selection. Only read when config actually constrains one of them —
	// nothing to validate otherwise, and it avoids a needless GET.
	self.with_nas((nas) => {
		if (!nas || (want == null && !pinned))
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
