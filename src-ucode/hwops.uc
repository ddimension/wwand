// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — hardware reset/repower daemon ops, kept apart from daemon.uc.
// install() attaches the ubus-facing methods onto the daemon `self` (same
// pattern as netsel_ops.uc); modem/context state stays on self.

'use strict';

import * as uloop from 'uloop';
import * as carrier from 'wwand.carrier_config';

export function install(self, o)
{
	let log = o.log;
	let check_modem = o.check_modem;
	let board = o.board;
	let board_gpio_ok = o.board_gpio_ok;

	// pending reset-line fallbacks, by modem: a daemon that stops (also the
	// non-destructive stop_local, which leaves the modem objects running)
	// must not pulse hardware a second later, and a newer modem_reset
	// replaces an older request's fallback rather than adding a second one
	let fallback_timers = {};

	self.cancel_reset_fallbacks = function() {
		for (let ref, t in fallback_timers)
			t?.cancel?.();

		fallback_timers = {};
	};

	// How long a soft reset gets to take the modem off the bus before the line
	// is pulsed: per modem `reset_fallback` (seconds), else 30 s. A rebooting
	// USB modem leaves the bus within seconds; the one measured here came
	// back after ~10 s (MikroTik board, reset line; daemon.uc, the comment
	// on the usb_repower rung). Defined BEFORE modem_reset: ucode resolves a
	// closure's lexical references at definition time.
	let fallback_ms = (entry) => {
		let s = +(entry.cfg?.reset_fallback ?? 0);

		return ((s > 0) ? s * 1000 : (o.reset_fallback_ms ?? 30000));
	};

	// Generic modem reset: the modem's OWN reset first (QMI DMS offline->reset,
	// MBIM passthrough-DMS/AT, NCM AT+CFUN=1,1), and the reset line (per-modem
	// `reset_gpio` or the board default) only as the fallback.
	//
	// WHY THAT ORDER. A pulse of the reset line cuts the modem off mid-write:
	// it gets no chance to flush its file system, and a modem's EFS/NV is
	// exactly what such a cut can corrupt (ddimension/openwrt-repo#4). Its own
	// reset is the graceful one. The line stays as the fallback for the case it
	// exists for — a modem whose control channel no longer acts on a reset:
	// pulsed at once when the soft reset is refused, and after `reset_fallback`
	// (default 30 s) when the modem acknowledged it but never dropped off the
	// bus, which a real reboot does. The recovery ladder's own hardware rung is
	// separate and unchanged (daemon usb_repower): it is reached because the
	// soft path has already failed.
	self.modem_reset = function(ref, cb) {
		fallback_timers[ref]?.cancel?.();
		delete fallback_timers[ref];

		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let rg = entry.cfg?.reset_gpio ??
			(board_gpio_ok() ? board?.profile?.reset_gpio : null);
		let off = entry.cfg?.repower_time ? +entry.cfg.repower_time * 1000 : null;
		let line = (rg && board) ? rg : null;

		let pulse = (why) => {
			log('warn', sprintf('modem %s: modem reset by GPIO %s pulse (%s)', ref, line, why));
			return board.reset_pulse(line, off);
		};

		let m = entry.modem;

		if (type(m?.reset) != 'function') {
			if (line && pulse('no soft reset on this backend'))
				return cb(null, { ok: true, resetting: true, action: 'gpio', gpio: line });

			return cb({ error: 'unsupported_on_backend' });
		}

		let absent0 = m._absent_count ?? 0;

		log('warn', sprintf('modem %s: admin-requested modem reset (backend)', ref));

		m.reset((err, res) => {
			if (err) {
				// refused or unanswered: the line is what is left
				if (line && pulse(sprintf('soft reset failed: %J', err)))
					return cb(null, { ok: true, resetting: true, action: 'gpio', gpio: line });

				return cb(err);
			}

			if (line) {
				let wait = fallback_ms(entry);
				// two statements, never `(o.timer ?? uloop.timer)(…)`: a called
				// parenthesized `??` with a member expression on the right
				// overwrites a neighbouring local — `wait` read back as NaN
				// below (docs/gotchas.md)
				let arm = o.timer ?? uloop.timer;

				fallback_timers[ref] = arm(wait, () => {
					delete fallback_timers[ref];

					let now = self.modems?.[ref];

					// rebooted: the modem object was replaced (hotplug), or it
					// went ABSENT since the reset was asked for
					if (now?.modem !== m || (m._absent_count ?? 0) > absent0)
						return;

					pulse(sprintf('no reboot within %d s of the soft reset', wait / 1000));
				});

				return cb(null, { ...res, action: 'backend', fallback_gpio: line,
					fallback_in: wait / 1000 });
			}

			cb(null, { ...res, action: 'backend' });
		});
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

		// NO PDC IS NOT THE SAME AS NO ANSWER. MBIMEx v3 has a carrier
		// configuration of its own (MODEM_CONFIGURATION, ext cid 16), which
		// modem_mbim reads at init and keeps — reachable on a modem with no QMI
		// PDC service at all, which is exactly the case a PDC-only check
		// refuses outright.
		//
		// READ ONLY, and it says so: MBIM has a status and a name and no way to
		// SELECT a configuration. A `set` here is genuinely unavailable, and
		// answering it with the read would be worse than refusing.
		if (!entry.modem?.pdc) {
			let mc = entry.modem?.modem_config;

			if (mc != null && (op == 'get' || op == 'list')) {
				let one = { id: mc.name ?? '(unnamed)', description: mc.name ?? null,
				            status: mc.status, status_text: mc.status_text };

				return cb(null, (op == 'list')
					? { configs: [ one ], source: 'mbim', read_only: true }
					: { active: mc.name ?? null, status: mc.status,
					    status_text: mc.status_text, source: 'mbim', read_only: true });
			}

			return cb({ error: 'no_pdc',
			            detail: (mc != null && op == 'set')
			                ? 'this modem reports its carrier configuration over MBIM, which can read it but not select one — selecting needs the QMI PDC service'
			                : 'this modem has no QMI PDC service (carrier config unavailable)' });
		}

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
	// WHAT a repower would do, without doing it. Extracted so the status page
	// can show the operator which of the two hardware actions their box would
	// actually take — and extracted rather than reimplemented there, because a
	// second copy of this precedence is a second answer that drifts from the
	// first. repower_modem() below is its only other caller.
	self.repower_plan = function(ref) {
		if (!board)
			return { action: 'none', error: 'no_board_profile' };

		if (ref && !self.modems[ref])
			return { action: 'none', error: 'no_such_modem', ref: ref };

		let cfg = ref ? self.modems[ref].cfg : null;

		if (!cfg)
			for (let n, e in self.modems) { cfg = e.cfg; break; }

		// board defaults only when they unambiguously target this modem (see
		// board_gpio_ok): per-modem reset_gpio is the multi-modem path.
		let rg = cfg?.reset_gpio ?? (board_gpio_ok() && !board.profile?.repower_uses_power ? board.profile?.reset_gpio : null);

		if (rg)
			return { action: 'reset_gpio', gpio: rg,
			         source: cfg?.reset_gpio ? 'modem' : 'board',
			         off_ms: cfg?.repower_time ? +cfg.repower_time * 1000 : null };

		if (!board_gpio_ok())
			return { action: 'none', error: 'multi_modem_needs_reset_gpio' };

		// `has_power` is REPORTED, not gated on. The old path simply called
		// power_cycle() and reported no_power_control when the call came back
		// false, and turning that into a precondition changed behaviour: a
		// board object without the flag (the test's, and any profile that does
		// not set it) stopped power-cycling at all. A plan describes the
		// intent; whether the pins are there is the board's answer to give.
		return { action: 'power_cycle', has_power: !!board.has_power,
		         off_ms: cfg?.repower_time ? +cfg.repower_time * 1000 : null };
	};

	self.repower_modem = function(ref) {
		let plan = self.repower_plan(ref);

		// the error SHAPE is preserved: the old path returned { error } alone
		// for the errors that carry no reference, and a consumer testing the
		// response shape would see a new `ref: null` member otherwise
		if (plan.error && plan.action == 'none')
			return plan.ref != null
				? { error: plan.error, ref: plan.ref }
				: { error: plan.error };

		let rg = (plan.action == 'reset_gpio') ? plan.gpio : null;
		let off = plan.off_ms;

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

		log('warn', sprintf('modem %s: admin-requested repower (board power cycle)', ref ?? '-'));

		return board.power_cycle(off) ?
			{ ok: true, action: 'power_cycle' } : { error: 'no_power_control' };
	};
};
