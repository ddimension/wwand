// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — context reconnect engine, kept out of the daemon.uc factory so the
// hold/backoff logic can be read on its own.
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
//   _give_up             our own re-armable down (hold expiry, operator detach)
//   set_hold_max_ms / _hold_max_ms   live reconnect-hold ceiling (reload/status)
// o = { log, timing, down_interface, mark_our_down } — modem/context state
// stays on self. `mark_our_down` is the daemon's interface-keyed our-down
// marker (daemon.uc); the hold-expiry give-up needs it and install() refuses
// without it.

'use strict';

import * as uloop from 'uloop';
import * as siminventory from 'wwand.siminventory';
import * as context_common from 'wwand.context_common';

const UP_GUARD_MS = 150000;

export function install(self, o)
{
	let log = o.log;
	let timing = o.timing;
	let down_interface = o.down_interface;
	// NOT defaulted to a no-op. It is needed on exactly one path — the
	// hold-expiry give-up — and a silent default there loses the marker that
	// keeps netifd's cleared autostart from reading as an operator ifdown,
	// which is a correctness invariant and not a nicety.
	let mark_our_down = o.mark_our_down;

	if (type(mark_our_down) != 'function')
		die('reconnect.install: mark_our_down dependency is required');

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
	let activate, clear_reconnect, retry_activate, enter_reconnecting, give_up;

	// seconds left of a throttle the modem reported for this interface's APN,
	// 0 when none (or its time is unknown or over)
	let throttle_left = (entry) => {
		let until = entry?.throttle?.until;

		return (until != null) ? max(0, until - context_common.mono()) : 0;
	};

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

		// netifd's setup during a throttle: answered at once rather than
		// dialled into the back-off (daemon.uc note_throttle)
		if (throttle_left(entry) > 0) {
			// ...and someone has to own the dial after it: an interface given
			// up before (or never started) has no retry chain
			if (!entry.retry_timer) {
				let mine = entry;

				// the same interface, still wanted — a reload in between may
				// have put a different one under this name
				uloop.timer(0, () => {
					if (self.contexts[name] === mine && mine.wanted)
						retry_activate(name);
				});
			}

			return cb({ error: 'throttled', apn: entry.throttle.apn, retry_in: throttle_left(entry) });
		}

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
			// CANCEL BEFORE REPLACING. A dropped uloop handle still fires, so
			// assigning over a pending retry leaves TWO chains walking the same
			// entry: both increment retry_n, both eventually call ctx.up(), and
			// the backoff they were meant to space out collapses. Reachable
			// whenever something reaches retry_activate while a retry is
			// already scheduled: the modem-ready and adoption paths call it
			// directly (daemon.uc:1158,:1200), and the sim_refresh handler gets
			// there through enter_reconnecting.
			if (entry.retry_timer) {
				entry.retry_timer.cancel();
				entry.retry_timer = null;
			}

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

		// a radio cycle or detach is running (modem_common
		// with_sessions_released): the modem still reads READY until the
		// registration goes, and a dial now lands in the radio-off window
		if (modem._reattaching)
			return schedule();

		// Parked radio (`option lowpower`, a card lent to another modem): a
		// dial cannot register, and every failed one counts toward the
		// recovery ladder, whose cycles and resets end the park. Wait
		// instead; the hold timer gives up cleanly, and the `registered` a
		// woken modem reports re-arms the interface (modem_registered).
		if (modem.lowpower_parked)
			return schedule();

		// detached by the operator (netsel_ops modem_detach): the same wait —
		// a dial would fail on a detached modem and count toward the ladder,
		// whose radio cycle would then undo the detach. modem_attach hands
		// the interface back.
		if (modem.detached)
			return schedule();

		// ...and a radio a plugin holds, parked or not. Not every held modem
		// is parked: one whose backend cannot switch its radio off, or that
		// registered before the hold was asked, is READY on its own card —
		// and this path, unlike context_up, had no word about the hold: a
		// non-destructive wwand restart adopted the still-up interface and
		// dialled on the local card of a modem waiting for its remote SIM.
		// Waits the same way; the hold's end is picked up by the next try.
		if (self.plugins_radio_hold?.(entry.cfg?.modem ?? modem.id)) {
			if (!entry._held_retry_logged)
				log('notice', sprintf('interface %s: not dialling — %s', name,
					self.plugins_radio_hold(entry.cfg?.modem ?? modem.id)));
			entry._held_retry_logged = true;
			return schedule();
		}

		entry._held_retry_logged = false;

		// AN ICCID-BOUND INTERFACE DIALS ONLY ON ITS CARD. Right after its own
		// slot switch the modem still reads READY for a moment, and this path
		// dialled the new interface on whatever answered — profile 2 of a
		// card not read yet (HW, NR7101, 2026-11-07: "invalid profile id").
		// No retry is scheduled: the `registered` that follows the card's
		// bring-up kicks the interface (daemon.uc modem_registered), and its
		// setup takes the next step (sim_binding).
		let bound = siminventory.norm_iccid(entry.cfg?.iccid);

		if (bound && bound != siminventory.norm_iccid(modem.info?.iccid))
			return;

		// the modem holds this APN back (daemon.uc note_throttle): a dial
		// before the back-off ends is refused the same way. While the time is
		// being asked, the ordinary backoff stands; once known, the next try
		// waits for its end — and the reconnect hold is deferred past the
		// throttle's end (below), not fired in the middle of an outage whose
		// end is known and that no `registered` would recover from.
		if (entry.throttle?.querying)
			return schedule();

		let left = throttle_left(entry);

		if (left > 0) {
			if (entry.retry_timer)
				entry.retry_timer.cancel();

			// Defer the give-up hold past the throttle, don't drop it: giving
			// the interface up mid-throttle is wrong (the outage end is known
			// and no `registered` follows a throttle), but a hold that never
			// fired again would turn the throttle into an UNBOUNDED retry loop
			// once ordinary failures persist after it. Re-arm it to land a
			// full hold_max_ms after the throttle clears; a dial that succeeds
			// first cancels it (clear_reconnect on the 'up' event).
			if (entry.hold_timer)
				entry.hold_timer.cancel();
			entry.hold_timer = uloop.timer(left * 1000 + 1000 + hold_max_ms, () => {
				entry.hold_timer = null;
				give_up(name, 'reconnect hold expired');
			});

			let thr = entry.throttle;

			entry.retry_timer = uloop.timer(left * 1000 + 1000, () => {
				entry.retry_timer = null;

				if (entry.throttle === thr)
					entry.throttle = null;

				retry_activate(name);
			});
			return;
		}

		entry.ctx.up((err) => {
			if (err && entry.wanted && entry.ctx?.state != 'CONNECTED')
				schedule();
			// success is handled by the 'up' event (clear_reconnect + renew)
		});
	};

	// Our own INVOLUNTARY give-up on an interface: down in netifd, but
	// re-armable — the modem's next `registered` reconnects it
	// (daemon.uc modem_registered), unlike an operator ifdown. Taken when the
	// reconnect hold expires and when the operator detaches the modem
	// (netsel_ops modem_detach), whose attach then registers again.
	give_up = (name, why) => {
		let entry = self.contexts[name];

		if (!entry)
			return;

		log('warn', sprintf('interface %s: %s, downing %s', name, why, entry.cfg.interface));
		clear_reconnect(name);

		// clear `wanted` now (not only when context_down later fires) so a
		// `registered` in the gap can't re-kick the interface we're tearing
		// down. `_holdexpiry` marks this as an INVOLUNTARY give-up, not operator
		// intent: context_down re-arms it so a later `registered` (service
		// returned) reconnects — see modem_registered.
		entry.wanted = false;
		entry._holdexpiry = true;

		// netifd's ubus `down` clears autostart, which the ready path
		// reads as operator intent — mark it so our own down is not
		// mistaken for an ifdown (see daemon.uc, modem_registered).
		// STAMPED, because that marker is bounded: an unstamped one reads
		// as infinitely old and would be ignored outright.
		//
		// Through the DAEMON, because the marker is keyed by interface
		// there and no longer lives on this entry — writing the old fields
		// here left the hold-expiry give-up, the very path that reaches
		// this line and the one ddimension/wwand#35 took, unmarked for
		// every reader.
		mark_our_down(entry);

		if (down_interface && entry.cfg.interface)
			down_interface(entry.cfg.interface);
	};

	// transient loss: keep the interface up and reconnect in place; a hold timer
	// bounds the blackhole and downs the interface if we never recover.
	enter_reconnecting = (name) => {
		let entry = self.contexts[name];

		if (!entry?.ctx || !entry.wanted || entry.hold_timer)
			return;   // not wanted, or already reconnecting

		entry.hold_timer = uloop.timer(hold_max_ms, () => {
			entry.hold_timer = null;

			if (entry.ctx?.state != 'CONNECTED')
				give_up(name, 'reconnect hold expired');
		});

		retry_activate(name);
	};

	self._activate = activate;
	self._clear_reconnect = clear_reconnect;
	self._retry_activate = retry_activate;
	self._enter_reconnecting = enter_reconnecting;
	self._give_up = give_up;
};
