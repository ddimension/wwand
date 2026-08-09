// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — helpers shared by the QMI / MBIM / NCM data-context state machines
// (context.uc, context_mbim.uc, context_ncm.uc). Protocol-neutral: the pieces
// that were near-identical across all three contexts live here once, so a fix
// or behaviour change lands in a single place instead of drifting per backend.

'use strict';

// zero_rx_limit_ms(modem_config, timing): the zero-rx stall threshold in ms.
//   timing.zero_rx_ms — explicit override (tests) when not null.
//   else the modem's `zero_rx_timeout` in seconds (default 21600 = 6 h).
// Returns 0 to mean "watchdog disabled".
// effective connection field (apn/auth/username/password) for a context: a
// per-SIM override (config wwand_sim, matched to the active card by ICCID)
// WINS over the interface's own value — the SIM-specific entry is more
// specific than the SIM-agnostic dial profile, same specificity rule as the
// PIN (wwand_sim -> wwand_modem). The interface value is the generic default;
// card-provisioned values remain the last fallback where supported. Empty
// strings count as unset on both levels.
export function conn_cfg(ctx, field)
{
	let s = ctx.modem?.active_sim?.[field];

	if (s != null && s != '')
		return s;

	let v = ctx.config?.[field];

	return (v != null && v != '') ? v : null;
};

// the complete context state machine: IDLE -> PREPARING (QMI) | ACTIVATING
// (MBIM/NCM dial directly) -> CONNECTED -> IDLE; every activation stage may
// fall back to IDLE on failure/teardown. Used by ctx_scaffolding's warn-only
// transition guard.
export const CONTEXT_TRANSITIONS = {
	IDLE:       { PREPARING: true, ACTIVATING: true },
	PREPARING:  { ACTIVATING: true, IDLE: true },
	ACTIVATING: { CONNECTED: true, IDLE: true },
	CONNECTED:  { IDLE: true },
};

// shared context plumbing (the context-side mirror of
// modem_common.scaffolding): the emit/set_state pair every context carries,
// plus the common tail of _fail — stop stats, back to IDLE, clear settings,
// emit 'error', complete the pending up() callback. Backends run their
// transport-specific cleanup (deactivate / unbind / release CIDs) first and
// then call fail_finish. o: { deps, log, stop_stats: () => … } (stop_stats as
// a thunk — it is forward-declared in the callers).
export function ctx_scaffolding(self, o)
{
	let emit = (event, data) => {
		if (o.deps?.on_event)
			o.deps.on_event(self, event, data);
	};

	let set_state = (state) => {
		if (self.state == state)
			return;

		// warn-only transition guard: the context machine is small enough for
		// a complete matrix — an illegal edge here is a logic bug upstream
		if (!(state in CONTEXT_TRANSITIONS))
			o.log('warn', sprintf('set_state: unknown interface state %J (typo?)', state));
		else if (!(CONTEXT_TRANSITIONS[self.state] ?? {})[state])
			o.log('warn', sprintf('set_state: unexpected transition %s -> %s', self.state, state));

		o.log('info', sprintf('state %s -> %s', self.state, state));
		self.state = state;
	};

	let fail_finish = (err, cb) => {
		o.stop_stats();
		set_state('IDLE');
		self.settings = null;
		emit('error', err);

		if (cb)
			cb(err);
	};

	return { emit: emit, set_state: set_state, fail_finish: fail_finish };
};

export function zero_rx_limit_ms(modem_config, timing)
{
	if (timing?.zero_rx_ms != null)
		return timing.zero_rx_ms;

	let secs = +(modem_config?.zero_rx_timeout ?? 21600);

	return (secs > 0) ? secs * 1000 : 0;
};

// rx_stall_watch(o): the shared zero-rx accumulator behind all three data
// contexts. Each context samples a *cumulative* rx counter once per stats
// interval (QMI rx_packets, MBIM in_packets, NCM rx_bytes) and feeds it here;
// the accumulator tracks how long that counter has stood still and reports a
// trip once the configured limit is crossed.
//
//   o.limit_ms    () => ms   — current stall threshold (0 disables the watch)
//   o.interval_ms number     — wall time each sample represents
//
// Returns { reset(), feed(total) }:
//   reset()      — call on (re)connect, before the first sample.
//   feed(total)  — returns the stalled_ms when the stall limit is crossed
//                  (the caller should then stop sampling + emit 'zero_rx'),
//                  or null while the link is healthy / the watch is disabled.
export function rx_stall_watch(o)
{
	let last = -1;
	let stalled = 0;

	return {
		reset: function() {
			last = -1;
			stalled = 0;
		},

		feed: function(total) {
			if (o.limit_ms() <= 0)
				return null;

			if (total > last || last < 0) {
				last = total;
				stalled = 0;
				return null;
			}

			stalled += o.interval_ms;

			return (stalled >= o.limit_ms()) ? stalled : null;
		},
	};
};
