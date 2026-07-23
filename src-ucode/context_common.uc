// wwand — helpers shared by the QMI / MBIM / NCM data-context state machines
// (context.uc, context_mbim.uc, context_ncm.uc). Protocol-neutral: the pieces
// that were near-identical across all three contexts live here once, so a fix
// or behaviour change lands in a single place instead of drifting per backend.

'use strict';

// zero_rx_limit_ms(modem_config, timing): the zero-rx stall threshold in ms.
//   timing.zero_rx_ms — explicit override (tests) when not null.
//   else the modem's `zero_rx_timeout` in seconds (default 21600 = 6 h).
// Returns 0 to mean "watchdog disabled".
export function zero_rx_limit_ms(modem_config, timing)
{
	if (timing?.zero_rx_ms != null)
		return timing.zero_rx_ms;

	let secs = +(modem_config?.zero_rx_timeout ?? 21600);

	return (secs > 0) ? secs * 1000 : 0;
}

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
}
