// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — context reconnect engine (extracted from the daemon.uc factory).
//
// The daemon (no per-interface monitor) keeps each context up. A TRANSIENT
// loss keeps the netifd interface up and reconnects the session in place
// (renew, no teardown → PD/VRF preserved); a PERMANENT loss or the hold
// timeout drives the interface down. netifd runs the proto no-proto-task.
//
// install(self, o) attaches (underscored — the daemon binds them to locals so
// its call sites read unchanged):
//   _activate            bring a context up; queues on pending_up until READY
//   _clear_reconnect     cancel retry/hold timers, reset the backoff counter
//   _retry_activate      capped-backoff supervisor retry loop
//   _enter_reconnecting  transient-loss reconnect bounded by the hold timer
//   set_hold_max_ms / _hold_max_ms   live reconnect-hold ceiling (reload/status)
// o = { log, timing, down_interface } — modem/context state stays on self.

'use strict';

import * as uloop from 'uloop';

const UP_GUARD_MS = 150000;

export function install(self, o)
{
	let log = o.log;
	let timing = o.timing;
	let down_interface = o.down_interface;

	let hold_max_ms = timing?.hold_max_ms ?? 90000;

	// re-read the reconnect-hold ceiling live on reload; applied on the next
	// reconnect. Kept out of apply_config so a create-time timing override is
	// never clobbered by the config default.
	self.set_hold_max_ms = function(ms) {
		if (ms > 0)
			hold_max_ms = ms;
	};

	// current ceiling, read by status()
	self._hold_max_ms = function() {
		return hold_max_ms;
	};

	// forward-declared: ucode closures capture only already-declared vars, and
	// these self/mutually reference (the TDZ trap — see CLAUDE.md ucode gotchas)
	let activate, clear_reconnect, retry_activate, enter_reconnecting;

	// bring context `name` up; queues on pending_up until the modem is READY.
	activate = (name, cb) => {
		let entry = self.contexts[name];

		if (!entry?.ctx)
			return cb({ error: 'no_such_context', ref: name });

		let modem = entry.ctx.modem;

		if (modem.state == 'SIM_BLOCKED')
			return cb({ error: 'sim_blocked' });

		if (entry.ctx.state == 'CONNECTED')
			return cb(null, self._up_result(name, entry));

		if (modem.state != 'READY') {
			log('info', sprintf('interface %s: modem not ready (%s), queueing activation',
				name, modem.state));

			let fired = false, guard_timer = null;
			let guarded = (err, res) => {
				if (fired)
					return;

				fired = true;

				// cancel the guard so the reply closure isn't retained for
				// the full window after the queue already flushed
				if (guard_timer) { guard_timer.cancel(); guard_timer = null; }

				cb(err, res);
			};

			push(entry.pending_up, guarded);

			guard_timer = uloop.timer(UP_GUARD_MS, () => {
				guard_timer = null;
				entry.pending_up = filter(entry.pending_up, (p) => p != guarded);
				guarded({ error: 'timeout', modem_state: modem.state });
			});

			return;
		}

		entry.ctx.up((err) => {
			// registration lost mid-attempt: requeue until READY again (keeps
			// netifd's setup long-poll open instead of failing)
			if (err?.error == 'suspended')
				return activate(name, cb);

			cb(err, err ? null : self._up_result(name, entry));
		});
	};

	clear_reconnect = (name) => {
		let entry = self.contexts[name];

		if (!entry)
			return;

		if (entry.retry_timer) { entry.retry_timer.cancel(); entry.retry_timer = null; }
		if (entry.hold_timer)  { entry.hold_timer.cancel();  entry.hold_timer = null; }
		entry.retry_n = 0;
	};

	// internal reconnect with capped backoff; self-schedules until CONNECTED or
	// enter_reconnecting's hold timer gives up. Daemon's own supervisor loop
	// (does NOT use pending_up).
	retry_activate = (name) => {
		let entry = self.contexts[name];

		if (!entry?.ctx || !entry.wanted || entry.ctx.state == 'CONNECTED')
			return;

		let modem = entry.ctx.modem;

		if (modem.state == 'SIM_BLOCKED')
			return;   // permanent; handled by the sim_blocked path (down)

		let schedule = () => {
			entry.retry_n = (entry.retry_n ?? 0) + 1;
			let delay = min(entry.retry_n * (timing?.backoff_min ?? 2000),
			                timing?.backoff_max ?? 30000);
			entry.retry_timer = uloop.timer(delay, () => {
				entry.retry_timer = null;
				retry_activate(name);
			});
		};

		if (modem.state != 'READY' || entry.ctx.state != 'IDLE')
			return schedule();   // wait for recovery / an in-flight attempt

		entry.ctx.up((err) => {
			if (err && entry.wanted && entry.ctx?.state != 'CONNECTED')
				schedule();
			// success is handled by the 'up' event (clear_reconnect + renew)
		});
	};

	// transient loss: keep the interface up and reconnect in place; a hold timer
	// bounds the blackhole and downs the interface if we never recover.
	enter_reconnecting = (name) => {
		let entry = self.contexts[name];

		if (!entry?.ctx || !entry.wanted || entry.hold_timer)
			return;   // not wanted, or already reconnecting

		entry.hold_timer = uloop.timer(hold_max_ms, () => {
			entry.hold_timer = null;

			if (entry.ctx?.state != 'CONNECTED') {
				log('warn', sprintf('interface %s: reconnect hold expired, downing %s',
					name, entry.cfg.interface));
				clear_reconnect(name);

				// clear `wanted` now (not only when context_down later fires) so a
				// `registered` in the gap can't re-kick the interface we're tearing
				// down. `_holdexpiry` marks this as an INVOLUNTARY give-up (blackhole
				// too long), not operator intent: context_down re-arms it so a later
				// `registered` (service returned) reconnects — see modem_registered.
				entry.wanted = false;
				entry._holdexpiry = true;

				// netifd's ubus `down` clears autostart, which the ready path
				// reads as operator intent — mark it so our own down is not
				// mistaken for an ifdown (see daemon.uc, modem_registered)
				entry._our_down = true;

				if (down_interface && entry.cfg.interface)
					down_interface(entry.cfg.interface);
			}
		});

		retry_activate(name);
	};

	self._activate = activate;
	self._clear_reconnect = clear_reconnect;
	self._retry_activate = retry_activate;
	self._enter_reconnecting = enter_reconnecting;
};
