// wwand tests — shared data-context helpers (context_common.uc).
// The zero-rx accumulator + threshold used identically by the QMI/MBIM/NCM
// contexts; the per-backend context suites exercise it end-to-end, this pins
// the shared unit's edge cases directly.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as cc from 'wwand/context_common.uc';

// --- zero_rx_limit_ms --------------------------------------------------------

eq(cc.zero_rx_limit_ms({ zero_rx_timeout: 30 }, null), 30000, 'limit: seconds -> ms');
eq(cc.zero_rx_limit_ms({}, null), 21600000, 'limit: default 6h when unset');
eq(cc.zero_rx_limit_ms({ zero_rx_timeout: 0 }, null), 0, 'limit: 0 disables');
eq(cc.zero_rx_limit_ms({ zero_rx_timeout: 30 }, { zero_rx_ms: 8 }), 8,
	'limit: timing override wins over config');
eq(cc.zero_rx_limit_ms({ zero_rx_timeout: 30 }, { zero_rx_ms: 0 }), 0,
	'limit: timing override of 0 disables');

// --- rx_stall_watch ----------------------------------------------------------

// healthy link: the cumulative counter keeps rising -> never trips
let w = cc.rx_stall_watch({ limit_ms: () => 100, interval_ms: 50 });
eq(w.feed(10), null, 'watch: first sample never trips');
eq(w.feed(20), null, 'watch: rising counter, no stall');
eq(w.feed(30), null, 'watch: still rising');

// stall: counter stands still; trips once accumulated stall >= limit
w = cc.rx_stall_watch({ limit_ms: () => 100, interval_ms: 50 });
eq(w.feed(100), null, 'stall: prime the baseline');
eq(w.feed(100), null, 'stall: +50ms, below 100 limit');
eq(w.feed(100), 100, 'stall: +50ms reaches 100 -> trips with stalled_ms');

// a single rise mid-stall resets the accumulator
w = cc.rx_stall_watch({ limit_ms: () => 100, interval_ms: 50 });
w.feed(5); w.feed(5);            // stalled 50ms
eq(w.feed(6), null, 'reset: one rise clears the accumulator');
eq(w.feed(6), null, 'reset: +50ms again, back below limit');
eq(w.feed(6), 100, 'reset: only trips after a fresh full stall window');

// a counter that jumps past the threshold in one sample still counts as a rise
w = cc.rx_stall_watch({ limit_ms: () => 100, interval_ms: 200 });
eq(w.feed(1000), null, 'jump: big first value is a rise, not a stall');
eq(w.feed(1000), 200, 'jump: single stalled interval over-limit trips');

// disabled watch (limit 0) never trips no matter how long it stalls
w = cc.rx_stall_watch({ limit_ms: () => 0, interval_ms: 60000 });
eq(w.feed(1), null, 'disabled: no trip #1');
eq(w.feed(1), null, 'disabled: no trip #2');
eq(w.feed(1), null, 'disabled: no trip #3');

// reset() clears state so a reconnect starts fresh
w = cc.rx_stall_watch({ limit_ms: () => 100, interval_ms: 50 });
w.feed(7); w.feed(7);
w.reset();
eq(w.feed(7), null, 'reset(): baseline re-primed after reconnect');
eq(w.feed(7), null, 'reset(): +50ms below limit again');

// limit can change between samples (live config edit): honoured immediately
let lim = 100;
w = cc.rx_stall_watch({ limit_ms: () => lim, interval_ms: 50 });
w.feed(9); w.feed(9);            // stalled 50ms, limit 100 -> no trip yet
lim = 40;                        // shrink the window
eq(w.feed(9), 100, 'live-limit: shrunk threshold trips on the next sample');

done('test_context_common');
