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

// --- apply_iface_id: prefix from the network, identifier from the config -----
//
// The control-protocol path of `option ip6ifaceid`. Some networks rotate the
// interface identifier on a live bearer while the prefix stays put, which kills
// every source-restricted route and firewall rule pinned to the address; a
// fixed identifier inside the same /64 is legitimate on 3GPP, where the whole
// /64 belongs to this UE (RFC 6459 5.2).

// the plain case: /64 kept, host part replaced
eq(cc.apply_iface_id('2001:db8:1:2:aaaa:bbbb:cccc:dddd', '::1'),
	'2001:db8:1:2:0:0:0:1', 'iface_id: prefix kept, identifier replaced');
eq(cc.apply_iface_id('2001:db8:1:2:aaaa:bbbb:cccc:dddd', '::1234:5678'),
	'2001:db8:1:2:0:0:1234:5678', 'iface_id: multi-group identifier');

// EMPTY IS THE DEFAULT AND MUST CHANGE NOTHING. netifd's own ip6ifaceid
// defaults to ::1; ours must not, or an upgrade silently renumbers every
// existing installation.
eq(cc.apply_iface_id('2001:db8:1:2:aaaa:bbbb:cccc:dddd', ''),
	'2001:db8:1:2:aaaa:bbbb:cccc:dddd', 'iface_id: empty leaves the address alone');
eq(cc.apply_iface_id('2001:db8:1:2:aaaa:bbbb:cccc:dddd', null),
	'2001:db8:1:2:aaaa:bbbb:cccc:dddd', 'iface_id: unset leaves the address alone');

// the kernel generation modes name something the kernel does to an address it
// GENERATES — meaningless for one handed to us, and honoured on the RA path
for (let m in [ 'eui64', 'random', 'stable', 'EUI64' ])
	eq(cc.apply_iface_id('2001:db8:1:2:aaaa:bbbb:cccc:dddd', m),
		'2001:db8:1:2:aaaa:bbbb:cccc:dddd',
		sprintf('iface_id: kernel mode %s does not rewrite a pushed address', m));

// A COMPRESSED input must not be split naively. The QMI/MBIM codec and the NCM
// byte decoder all emit the uncompressed eight-group form, but
// ncm_vendors.parse_cgpaddr passes the modem's v6 slot through verbatim and a
// modem may well print `::` there — splitting that on ':' would build the
// address out of the wrong groups.
eq(cc.apply_iface_id('2001:db8:1:2::1', '::42'),
	'2001:db8:1:2:0:0:0:42', 'iface_id: compressed address expands correctly');
// seven groups written out, so `::` stands for exactly ONE zero: the prefix is
// 2001:db8:0:2 and not 2001:db8:0:0 — the whole reason this must not be split
// on ':' without expanding first
eq(cc.apply_iface_id('2001:db8::2:0:0:0:1', '::7'),
	'2001:db8:0:2:0:0:0:7', 'iface_id: :: in the middle expands by position');

// garbage in any position leaves the address untouched rather than producing a
// plausible-looking wrong one
eq(cc.apply_iface_id('2001:db8:1:2:aaaa:bbbb:cccc:dddd', 'garbage'),
	'2001:db8:1:2:aaaa:bbbb:cccc:dddd', 'iface_id: non-address value ignored');
eq(cc.apply_iface_id('2001:db8:1:2:aaaa:bbbb:cccc:dddd', '::zzzz'),
	'2001:db8:1:2:aaaa:bbbb:cccc:dddd', 'iface_id: non-hex identifier ignored');
eq(cc.apply_iface_id('10.0.0.1', '::1'), '10.0.0.1', 'iface_id: an IPv4 string is left alone');
eq(cc.apply_iface_id('2001:db8:1:2:3', '::1'), '2001:db8:1:2:3',
	'iface_id: a truncated literal is not "fixed" into something else');
eq(cc.apply_iface_id(null, '::1'), null, 'iface_id: no address, nothing to do');

// --- values that must be REFUSED, not quietly turned into some address ------
//
// Each of these produced a plausible-looking wrong address before, which is the
// worst failure mode for an option nobody re-reads after setting it once.

// an all-zero identifier is <prefix>:: — the subnet-router ANYCAST address,
// which is not a host address at all
for (let z in [ '::', '::0', '1::', '0:0:0:0::' ])
	eq(cc.apply_iface_id('2001:db8:1:2:aaaa:bbbb:cccc:dddd', z),
		'2001:db8:1:2:aaaa:bbbb:cccc:dddd',
		sprintf('iface_id: all-zero identifier %s is refused (anycast)', z));

// a whole address in the identifier field: keeping only its low half would hide
// the operator's mistake and hand out an address they never asked for. netifd
// refuses the same thing for its own ip6ifaceid (interface.c:1021-1023).
for (let a in [ 'fe80::1', '2001:db8::1', '::1:2:3:4:5' ])
	eq(cc.apply_iface_id('2001:db8:1:2:aaaa:bbbb:cccc:dddd', a),
		'2001:db8:1:2:aaaa:bbbb:cccc:dddd',
		sprintf('iface_id: %s has a network part and is refused', a));

// `::` must compress AT LEAST ONE group (RFC 4291 2.2). Eight groups plus a
// `::` is malformed, and the address side is the one that can carry it:
// ncm_vendors.parse_cgpaddr passes the modem's text through verbatim.
eq(cc.apply_iface_id('2001:db8:1:2:aaaa:bbbb:cccc:dddd::', '::1'),
	'2001:db8:1:2:aaaa:bbbb:cccc:dddd::',
	'iface_id: a redundant :: makes the address malformed -> left alone');
eq(cc.apply_iface_id('::1:2:3:4:5:6:7:8', '::1'), '::1:2:3:4:5:6:7:8',
	'iface_id: ...same when the :: is leading');

// and the legitimate compressed spellings still work
eq(cc.apply_iface_id('2001:db8:1:2::1', '::42'), '2001:db8:1:2:0:0:0:42',
	'iface_id: a real compression is still accepted');


done('test_context_common');
