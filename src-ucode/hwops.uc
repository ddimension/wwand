// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — hardware reset/repower daemon ops, extracted from daemon.uc.
// install() attaches the ubus-facing methods onto the daemon `self` (same
// pattern as netsel_ops.uc); modem/context state stays on self.

'use strict';

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

	// manual hardware repower (ubus modem_repower): reset-GPIO pulse when one
	// applies, else board power-cycle — both gated for multi-modem boxes.
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

		if (rg)
			return board.reset_pulse(rg, off) ?
				{ ok: true, action: 'reset', gpio: rg } : { error: 'reset_gpio_unavailable' };

		if (!board_gpio_ok())
			return { error: 'multi_modem_needs_reset_gpio' };

		return board.power_cycle(off) ?
			{ ok: true, action: 'power_cycle' } : { error: 'no_power_control' };
	};
};
