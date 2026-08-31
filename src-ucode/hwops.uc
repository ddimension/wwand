// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — hardware reset/repower daemon ops, extracted from daemon.uc.
// install() attaches the ubus-facing methods onto the daemon `self` (same
// pattern as netsel_ops.uc); modem/context state stays on self.

'use strict';

import * as carrier from 'wwand.carrier_config';

export function install(self, o)
{
	let log = o.log;
	let check_modem = o.check_modem;
	let board = o.board;
	let board_gpio_ok = o.board_gpio_ok;

	// generic modem reset: dedicated reset GPIO first (per-modem `reset_gpio` or the
	// board default), then backend soft reset (QMI DMS offline->reset, MBIM
	// passthrough-DMS/AT, NCM AT+CFUN=1,1).
	self.modem_reset = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let rg = entry.cfg?.reset_gpio ??
			(board_gpio_ok() ? board?.profile?.reset_gpio : null);

		if (rg && board) {
			let off = entry.cfg?.repower_time ? +entry.cfg.repower_time * 1000 : null;

			log('warn', sprintf('modem %s: admin-requested modem reset (GPIO %s pulse)', ref, rg));

			if (board.reset_pulse(rg, off))
				return cb(null, { ok: true, resetting: true, action: 'gpio', gpio: rg });

			// GPIO configured but unusable -> fall through to the backend reset
			log('warn', sprintf('modem %s: reset GPIO %s unavailable, trying backend reset', ref, rg));
		}

		if (type(entry.modem.reset) != 'function')
			return cb({ error: 'unsupported_on_backend' });

		log('warn', sprintf('modem %s: admin-requested modem reset (backend)', ref));
		entry.modem.reset((err, res) =>
			cb(err, err ? null : { ...res, action: 'backend' }));
	};

	// Carrier configuration (MBN) over QMI PDC: what the modem runs, what else
	// it has, and selecting one. `op` = 'list' | 'get' | 'set'.
	//
	// A selection only takes effect after a modem reset, and the reply says so
	// rather than implying the radio changed underneath the caller — PDC reports
	// it as `pending` until then.
	self.modem_carrier_config = function(ref, op, id, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (!entry.modem?.pdc)
			return cb({ error: 'no_pdc',
			            detail: 'this modem has no QMI PDC service (carrier config unavailable)' });

		if (op == 'list')
			return carrier.list(entry.modem, (err, l) =>
				err ? cb({ error: 'pdc', detail: err }) : cb(null, { configs: l }));

		if (op == 'get')
			return carrier.selected(entry.modem, (err, sel) =>
				err ? cb({ error: 'pdc', detail: err }) : cb(null, sel));

		if (op == 'set') {
			if (!id || id == '')
				return cb({ error: 'no_config_id' });

			return carrier.select(entry.modem, id, (err, r) =>
				err ? cb({ error: 'pdc', detail: err }) : cb(null, r));
		}

		cb({ error: 'invalid_op', op: op });
	};

	// manual hardware repower (ubus modem_repower): reset-GPIO pulse when one
	// applies, else board power-cycle — both gated for multi-modem boxes.
	//
	// Deliberately NOT routed through recovery.usb_repower(), which refuses to
	// act on a modem that has never answered in the selected protocol. That rule
	// is about wwand escalating on its own evidence; a human pressing the button
	// is evidence of a different kind, and a modem that never answered is
	// exactly the one they are most likely to be trying to revive. Keep this
	// path direct — routing it through the primitive to "share the code" would
	// silently take the button away in the case it is for.
	self.repower_modem = function(ref) {
		if (!board)
			return { error: 'no_board_profile' };

		// a named-but-unknown ref must error — silently falling back to the
		// first modem would pulse ANOTHER modem's reset GPIO
		if (ref && !self.modems[ref])
			return { error: 'no_such_modem', ref: ref };

		let cfg = ref ? self.modems[ref].cfg : null;

		if (!cfg)
			for (let n, e in self.modems) { cfg = e.cfg; break; }

		// board defaults only when they unambiguously target this modem (see
		// board_gpio_ok): per-modem reset_gpio is the multi-modem path.
		let rg = cfg?.reset_gpio ?? (board_gpio_ok() ? board.profile?.reset_gpio : null);
		let off = cfg?.repower_time ? +cfg.repower_time * 1000 : null;

		// say who pulsed: the recovery ladder logs its own line and modem_reset
		// logs 'admin-requested', but this path used to log nothing at all, so
		// an operator-triggered pulse was indistinguishable in the log from one
		// the ladder fired — which is exactly what has to be told apart when
		// two pulses overlap.
		if (rg) {
			log('warn', sprintf('modem %s: admin-requested repower (GPIO %s pulse)', ref ?? '-', rg));

			return board.reset_pulse(rg, off) ?
				{ ok: true, action: 'reset', gpio: rg } : { error: 'reset_gpio_unavailable' };
		}

		if (!board_gpio_ok())
			return { error: 'multi_modem_needs_reset_gpio' };

		log('warn', sprintf('modem %s: admin-requested repower (board power cycle)', ref ?? '-'));

		return board.power_cycle(off) ?
			{ ok: true, action: 'power_cycle' } : { error: 'no_power_control' };
	};
};
