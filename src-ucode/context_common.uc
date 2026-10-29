// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — helpers shared by the QMI / MBIM / NCM data-context state machines
// (context.uc, context_mbim.uc, context_ncm.uc). Protocol-neutral: the pieces
// that were near-identical across all three contexts live here once, so a fix
// or behaviour change lands in a single place instead of drifting per backend.

'use strict';

import * as fs from 'fs';
import * as modem_quirks from 'wwand.modem_quirks';

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
// The login belongs to the APN it authenticates against. A card whose
// wwand_sim names its own APN therefore brings its own credentials — none,
// if it gives none — and never the interface's: those were written for the
// interface's APN. Taken field by field, a Telekom card with its own APN got
// the CHAP login of an M2M card configured on the interface, in the attach
// profile and in its data calls (HW-seen on 245, 2026-09-27).
const CREDENTIALS = { auth: true, username: true, password: true };

export function conn_cfg(ctx, field)
{
	let sim = ctx.modem?.active_sim;
	let s = sim?.[field];

	if (s != null && s != '')
		return s;

	if (CREDENTIALS[field] && sim?.apn != null && sim.apn != '')
		return null;

	let v = ctx.config?.[field];

	return (v != null && v != '') ? v : null;
};

// Every connection field a `config wwand_sim` may override, in ONE list.
//
// context_ncm's eff_config() copies them onto a flat object for the AT dial,
// and it carried four of them — so when pdp_type became overridable, NCM went
// on using the interface's value and nothing said so. That is the failure mode
// the comment on effective_pdp() below describes, caught one file later.
// Adding a field to sim_from_section means adding it here, and nowhere else.
export const SIM_OVERRIDABLE = [ 'apn', 'auth', 'username', 'password', 'pdp_type' ];

// The IP family this connection should ask for, resolved and defaulted.
//
// ONE place, because there were eight readers and every one of them spelled
// `self.config.pdp_type ?? 'ipv4v6'` by hand — so a per-SIM override would have
// had to be added to eight sites and would have been missed at the ninth. The
// default belongs here too: 'ipv4v6' is what an interface that never said gets,
// and repeating it at each site is how two of them come to disagree.
//
// Precedence is conn_cfg's: the active card's own value wins over the
// interface's, because the SIM is the more specific statement — a subscription
// that only answers on IPv4 says so about itself, not about the interface it
// happens to be dialled through (ddimension/wwand#35).
//
// A modem whose firmware cannot take IPv6 at all (modem_quirks `ipv4_only`)
// gets ipv4 whatever was configured: asking it for IPv6 is not a degraded
// connection there, it is a crashed modem.
export function effective_pdp(ctx)
{
	let pdp = conn_cfg(ctx, 'pdp_type') ?? 'ipv4v6';

	if (pdp != 'ipv4' && modem_quirks.for_model(ctx?.modem?.info?.model).ipv4_only)
		return 'ipv4';

	return pdp;
};

// The prefix-delegation flag an AT-driven connection asks for: 1/0, or null
// when `ipv6_pd` is unset or the connection carries no IPv6 (nothing to
// delegate). The QMI side has the same rule in its PROFILE_FLAGS table
// (context.uc); this is the copy for the AT paths, which have no table because
// only this one flag reaches them (ncm_vendors.uc `pd` recipes).
export function pd_want(cfg, pdp)
{
	if (cfg?.ipv6_pd == null || pdp == 'ipv4')
		return null;

	return cfg.ipv6_pd ? 1 : 0;
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

// mono(): monotonic seconds (CLOCK_MONOTONIC), for measuring durations like a
// context's connected uptime. Unlike time() it is immune to a wall-clock step,
// which matters on RTC-less boards (PCIe/MHI): the modem connects at boot before
// NTP sets the clock, so a `connected_since` captured with time() and read back
// after the NTP jump yields a bogus multi-hour uptime (forum report: LS3434 saw
// a constant ~18 h on a T99W175). Both the capture and the read must use mono().
export function mono()
{
	return clock(true)[0];
};

// bearer_lost_polls(modem_config, timing): how many CONSECUTIVE dial-status
// answers that list no context it takes to call the bearer gone, while the rx
// byte count stands still. Default 3 (~3 min at the 60 s poll), the modem's
// `bearer_poll_count` overrides it, and `timing.empty_status_polls` is the test
// hook.
//
// FLOOR OF 2, deliberately. The rx condition is weaker than it first looks: a
// bearer that is merely IDLE has a frozen rx counter too, exactly like a dead
// one — traffic vetoes the verdict, but the absence of traffic does not confirm
// it. So the run length is the real protection against a firmware whose status
// answer wwand simply fails to parse, and at 1 a single unparsed answer on an
// idle link would tear down a working connection. Asked for by a reporter who
// wanted 2 to shave a minute off a 2-hourly renumber (ddimension/wwand#25);
// 2 keeps two independent observations, 1 keeps none.
export function bearer_lost_polls(modem_config, timing)
{
	if (timing?.empty_status_polls != null)
		return timing.empty_status_polls;

	let n = +(modem_config?.bearer_poll_count ?? 3);

	// NaN fails this too, and lands on the floor — the same shape num_opt uses
	return (n >= 2) ? n : 2;
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

			// ANY change clears the stall, a decrease included. A cumulative rx
			// counter that goes backwards has been reset or has changed source —
			// a new call restarts the WDS per-call statistics at zero, and the
			// QMI monitor switches between the WDS counters and the kernel
			// netdev's, which are cumulative over different spans. Neither means
			// "nothing arrived", but `total > last` read both as exactly that:
			// `last` stayed at the old high-water mark and every later sample
			// counted as stalled while traffic flowed, until the new counter
			// climbed past a number belonging to a different measurement. That is
			// a zero-rx recovery — a modem reset — fired at a healthy link.
			if (total != last || last < 0) {
				last = total;
				stalled = 0;
				return null;
			}

			stalled += o.interval_ms;

			return (stalled >= o.limit_ms()) ? stalled : null;
		},
	};
};

// tx_queue_stats(dev, root): the transmit side of a data netdev as the
// kernel counts it — { timeouts, tx_packets } — or null when the device has no
// transmit queue to read.
//
// `timeouts` is the netdev watchdog's count, summed over the transmit queues:
// it adds one to /sys/class/net/<dev>/queues/tx-<n>/tx_timeout each time a
// queue has been stopped longer than the driver's watchdog_timeo, the same
// moment it logs "NETDEV WATCHDOG: … transmit queue N timed out"
// (sch_generic.c:530/539, net-sysfs.c:1419-1424, Linux 6.18.41). usbnet's
// timeout is 5 s (usbnet.c:52, :1778), and usbnet stops the queue when its USB
// transmit queue is full (usbnet.c:1504-1505): the modem has stopped taking
// packets.
//
// `tx_packets` is the proof of the opposite. usbnet counts a packet only when
// its URB completed successfully; an unlinked or failed one goes to tx_errors
// (usbnet.c tx_complete, 6.18.41). So it rises only while the modem accepts
// data, which is what tells a recovered queue from a stuck one.
//
// Read the device that OWNS the queue — the qmi_wwan / cdc / mhi parent — not
// a QMAP child.
export function tx_queue_stats(dev, root)
{
	if (!dev || match(dev, /[\/]|^\.\.?$/))
		return null;

	let base = sprintf('%s/%s', root ?? '/sys/class/net', dev);
	let total = null;

	for (let q in (fs.lsdir(base + '/queues') ?? [])) {
		if (!match(q, /^tx-[0-9]+$/))
			continue;

		let v = trim(fs.readfile(sprintf('%s/queues/%s/tx_timeout', base, q)) ?? '');

		if (match(v, /^[0-9]+$/))
			total = (total ?? 0) + +v;
	}

	if (total == null)
		return null;

	let p = trim(fs.readfile(base + '/statistics/tx_packets') ?? '');

	return { timeouts: total, tx_packets: match(p, /^[0-9]+$/) ? +p : null };
};

// How long the timeout count may stay still before a stall counts as over.
// The watchdog re-fires every watchdog_timeo (5 s on usbnet) while the queue
// stays stopped, but usbnet's timeout handler unlinks the queued URBs, which
// can wake the queue for a moment before it fills again — so a hang that never
// lets up does not raise the count on every 10 s sample. Three samples of
// silence separate "over" from "between two firings". A queue that recovered
// in between ends the stall sooner, through tx_packets.
export const TX_STALL_QUIET_S = 30;

// tx_stall_watch(o): a modem's transmit stalls, from tx_queue_stats.
//
//   o.read(dev)  -> { timeouts, tx_packets } or null   (default tx_queue_stats)
//   o.limit_s()  -> how long a stall may last before it trips (0 = never)
//   o.log(level, msg)
//
// Returns { sample(dev, now_s, proto_errors, armed) -> 'trip' | null,
// view(now_s) }. sample() is called on a steady tick (the daemon's 10 s one)
// with the modem's data netdev, its protocol error counter, and whether a data
// session is up on it; it returns 'trip' ONCE per stall, when one has lasted
// limit_s while armed. view() is what status() reports:
// { netdev, timeouts, stalled_s } — timeouts counted since this watch began,
// stalled_s null when the queue is moving.
//
// A STALL IS A QUEUE THAT TIMED OUT AND HAS NOT MOVED SINCE. It ends when
// tx_packets rises (the modem took data again) or the timeouts stop for
// TX_STALL_QUIET_S. Without the first condition, separate incidents that each
// recovered — a timeout every 20 s on a link that carries traffic in between —
// would add up to one long stall and reset a working modem.
//
// NOT ARMED, NOT TRIPPED. With no session up there is no data path to rescue,
// and the recovery behind a trip may power-cycle the modem; the stall is still
// counted and reported, just never acted on.
//
// The counter outlives the modem object (it belongs to the netdev), so the
// first reading is a BASELINE, never an event: a stall from before this watch
// began is not this modem's to act on. A counter that goes backwards is a new
// netdev under the same name and is rebased the same way.
//
// The protocol error counter is sampled at the start of a stall so the log can
// say whether the control channel failed with it. Both together is a modem
// that stopped answering altogether; a TX stall with the control channel still
// answering points at the data path or the radio instead.
export function tx_stall_watch(o)
{
	let read = o.read ?? tx_queue_stats;
	let dev = null, last = null, last_pkts = null, count = 0;
	let since = null, last_rise = null, pe_start = 0, tripped = false;

	let control = (pe) => (pe > pe_start)
		? sprintf('the control channel failed too (%d protocol errors)', pe - pe_start)
		: 'the control channel kept answering';

	let end = (why, pe) => {
		o.log('info', sprintf('tx stall on %s: %s after %ds; %s',
			dev, why, last_rise - since, control(pe)));
		since = null;
		tripped = false;
	};

	return {
		sample: function(netdev, now, proto_errors, armed) {
			let st = netdev ? read(netdev) : null;
			let total = st?.timeouts;
			let pkts = st?.tx_packets;
			let pe = +(proto_errors ?? 0);

			if (total == null || netdev != dev || last == null || total < last) {
				if (since != null && netdev != dev)
					o.log('info', sprintf('tx stall on %s: watch moved to %s', dev, netdev ?? 'no netdev'));

				dev = netdev;
				last = total;
				last_pkts = pkts;
				since = null;
				tripped = false;
				return null;
			}

			let delta = total - last;
			let moved = (pkts != null && last_pkts != null && pkts > last_pkts);

			last = total;
			last_pkts = pkts;

			if (since != null && moved)
				end('moving again', pe);
			else if (since != null && delta == 0 && now - last_rise >= TX_STALL_QUIET_S)
				end('no more timeouts', pe);

			if (delta > 0) {
				count += delta;
				last_rise = now;

				if (since == null) {
					since = now;
					pe_start = pe;
					tripped = false;
					o.log('warn', sprintf('tx stall on %s: the kernel watchdog timed out its transmit queue (%d so far) — the modem is not taking packets',
						dev, count));
				}
			}

			if (since == null || tripped || !armed)
				return null;

			let limit = +(o.limit_s() ?? 0);

			if (limit > 0 && now - since >= limit) {
				tripped = true;
				o.log('err', sprintf('tx stall on %s: %ds with the transmit queue stuck, %s — resetting the modem',
					dev, now - since, control(pe)));
				return 'trip';
			}

			return null;
		},

		view: function(now) {
			return dev ? {
				netdev: dev,
				timeouts: count,
				stalled_s: (since != null) ? now - since : null,
			} : null;
		},
	};
};

// IPv4 netmask -> prefix length. One table for the two converters (dotted
// string form in the QMI context, octet-array form in the NCM CGCONTRDP
// parser) — they had drifted into two identical copies.
export const NETMASK_BITS = {
	'255': 8, '254': 7, '252': 6, '248': 5,
	'240': 4, '224': 3, '192': 2, '128': 1, '0': 0,
};

export function mask_octets_to_prefix(octets)
{
	let bits = 0;

	for (let octet in octets) {
		let b = NETMASK_BITS[octet];

		if (b == null)
			return null;

		bits += b;
	}

	return bits;
};

// export functions are NOT hoisted in ucode — mask_octets_to_prefix above
export function netmask_to_prefix(netmask)
{
	if (netmask == null)
		return null;

	return mask_octets_to_prefix(split(netmask, '.'));
};

// the shared /32 point-to-point rule: a pushed prefix wins only under
// option use_pushed_prefix; otherwise the connection stays a /32 (parity
// across all three backends — QMI/MBIM/NCM). debug-logs the override once
// per differing push.
export function v4_prefix(config, pushed, log)
{
	if (config?.use_pushed_prefix && pushed != null)
		return pushed;

	if (pushed != null && pushed != 32)
		log?.('debug', sprintf('network pushed ipv4 prefix /%d, forcing /32', pushed));

	return 32;
};

// expand an IPv6 literal to exactly eight hextet strings, or null.
//
// The QMI/MBIM codec and the NCM byte decoder all produce the uncompressed
// eight-group form already (tlv.uc `ipv6`, ncm_vendors.bytes_to_ipv6), so this
// is a no-op for them. It exists for the one source that does not:
// ncm_vendors.parse_cgpaddr takes the modem's v6 slot VERBATIM, and a modem is
// free to print `::` there. Splitting such a string on ':' without expanding it
// would silently build an address out of the wrong groups.
function expand_v6(a)
{
	if (index(a, ':') < 0)
		return null;

	let parts = split(a, '::');

	if (length(parts) > 2)
		return null;

	let head = (length(parts[0]) ? split(parts[0], ':') : []);
	let tail = (length(parts) == 2 && length(parts[1])) ? split(parts[1], ':') : [];

	// no '::' -> the literal must already be complete
	if (length(parts) == 1) {
		if (length(head) != 8)
			return null;

		tail = [];
	}

	// With `::` present it must compress AT LEAST ONE group (RFC 4291 §2.2):
	// eight groups already written out plus a `::` is not a shorthand, it is
	// malformed. Accepting it meant a bad verbatim CGPADDR slot — the one
	// source that is not normalised — still produced a rewritten address
	// instead of being left alone. Only for the compressed spelling: an
	// uncompressed literal legitimately has all eight.
	if (length(head) + length(tail) > (length(parts) == 2 ? 7 : 8))
		return null;

	let out = [ ...head ];

	if (length(parts) == 2)
		for (let i = length(head) + length(tail); i < 8; i++)
			push(out, '0');

	for (let t in tail)
		push(out, t);

	if (length(out) != 8)
		return null;

	for (let g in out)
		if (!match(g, /^[0-9A-Fa-f]{1,4}$/))
			return null;

	return out;
}

// v6_prefix(addr, plen): the NETWORK part of `addr`, host bits cleared.
//
// A source-restricted route's source field is a PREFIX, and we were handing it
// a host address with a prefix length stapled on — `2408:…:c052:1c79/64` where
// `2408:…:e53a::/64` is meant. netifd does not clean that up: it masks the
// destination of an IPv4 route (interface-ip.c, "Mask out IPv4 host bits") and
// it masks a delegated prefix (interface_ip_add_device_prefix ->
// clear_if_addr), but a route SOURCE is parsed WITHOUT masking and emitted as
// given (netifd 2026.07.08 — parsed at interface-ip.c:491-504, put on the wire
// at system-linux.c:3927-3931). The kernel then masks it
// itself, so the result happens to be right — which is why this survived: it
// was wrong in the field that carries it, not in the route that came out.
//
// Returns null when the input cannot be taken apart safely, so callers can
// decide rather than be handed a plausible wrong answer.
export function v6_prefix(addr, plen)
{
	let g = expand_v6(trim(sprintf('%s', addr ?? '')));

	// The LENGTH IS CHECKED AS TEXT, not by coercing it. `+x` turns a
	// non-numeric string into NaN, and every comparison against NaN is false —
	// so a range check written the obvious way lets a garbage length through
	// and returns the address UNMASKED, which is precisely the plausible wrong
	// answer this function exists not to give. `true` would coerce to /1 and a
	// fraction would silently truncate. A decimal string and an integral float
	// both print as their digits and are accepted, which is what the codecs and
	// ubus actually hand over.
	let ps = (plen == null) ? '' : trim(sprintf('%s', plen));

	if (!g || !match(ps, /^[0-9]{1,3}$/))
		return null;

	let n = +ps;

	if (n > 128)
		return null;

	let out = [];

	for (let i = 0; i < 8; i++) {
		let v = hex(g[i]);
		let bits = n - (i * 16);   // bits of THIS group that are network

		if (bits <= 0)
			v = 0;
		else if (bits < 16)
			v &= (0xffff << (16 - bits)) & 0xffff;

		push(out, sprintf('%x', v));
	}

	return join(':', out);
};

// an expanded literal is usable as an interface identifier when its network
// half is empty and its host half is not.
function valid_iface_id(g)
{
	if (type(g) != 'array' || length(g) != 8)
		return false;

	for (let i = 0; i < 4; i++)
		if (hex(g[i]) != 0)
			return false;

	for (let i = 4; i < 8; i++)
		if (hex(g[i]) != 0)
			return true;

	return false;
};

// --- IPv6 interface identifier (option ip6ifaceid / ifaceid) -----------------
//
// apply_iface_id(addr, value): keep the /64 the network gave us and replace the
// low 64 bits with a configured identifier. This is the CONTROL-PROTOCOL path —
// the address the modem hands us over QMI/MBIM/NCM, which we push to netifd
// ourselves and which the kernel's SLAAC generation never touches. The RA path
// is the kernel's business and lives in netlink.apply_iface_id().
//
// Operators want this because some networks rotate the address on a live
// bearer: the interface identifier changes every minute or so while the prefix
// stays put, and every source-restricted route, firewall rule and DNS record
// pinned to the address dies with it. A fixed identifier inside the same /64 is
// legitimate on 3GPP — the whole /64 belongs to this UE (RFC 6459 §5.2), and a
// modem forwarding traffic from a self-chosen identifier has been confirmed on
// hardware (RM520F-GL, reported 2026-09-10).
//
// It does NOT stabilise anything if the operator rotates the PREFIX; nothing
// can, and the docs say so.
//
// Only a literal `::x` applies here. 'eui64'/'random'/'stable' name the
// KERNEL's generation modes, which have no meaning for an address that was
// handed to us rather than generated — those values are honoured on the RA path
// and deliberately ignored here.
//
// Returns the rewritten address, or `addr` unchanged when there is nothing to
// do or the input is not something we can safely take apart.
// iface_id_ok(value): would apply_iface_id() accept this literal? config.uc
// calls it to warn at parse time instead of leaving the operator to wonder why
// a value they set changed nothing. Kernel generation-mode names are not
// literals and are not this function's business.
// A MODEM THAT RE-RANDOMIZES THE IPv6 INTERFACE IDENTIFIER MUST NOT RENUMBER
// THE INTERFACE. Some firmware hands back a different low 64 bits on every
// settings query while prefix/gateway/DNS stay put (seen on the RG502Q), and
// adopting each variant renews the interface on every poll — every 60 s by
// default, which is long enough to break anything holding a v6 connection.
// Treat a same-prefix address as unchanged and keep the one netifd configured.
//
// Lived in context_monitor_qmi.uc as a local closure. The MBIM refresh compared
// its whole settings object with a flat %J and had no equivalent, while its own
// comment claimed "QMI parity via context_monitor_qmi" — so on MBIM the same
// firmware renumbered on every tick. Shared rather than copied.
export function keep_stable_v6(before, after)
{
	if (!before?.addr || !after?.addr || after.addr == before.addr ||
	    after.plen != before.plen)
		return after;

	let ab = iptoarr(after.addr), bb = iptoarr(before.addr);
	let plen = after.plen ?? 64;
	let n = int(plen / 8);

	if (!ab || !bb)
		return after;

	for (let i = 0; i < n; i++)
		if (ab[i] != bb[i])
			return after;

	// AND THE BITS THAT DO NOT FILL A BYTE. Comparing only whole octets meant
	// a /65 was judged on its first 64 bits, so two addresses in DIFFERENT
	// /65 networks read as an interface-identifier change and the old address
	// was kept — the one case where keeping it is exactly wrong. /64 is the
	// common case and unaffected (plen % 8 == 0).
	let rest = plen % 8;

	if (rest) {
		let mask = 0xff << (8 - rest);

		if ((ab[n] & mask) != (bb[n] & mask))
			return after;
	}

	return { ...after, addr: before.addr };
};

export function iface_id_ok(value)
{
	let g = expand_v6(trim(value ?? ''));

	return g ? valid_iface_id(g) : false;
};

export function apply_iface_id(addr, value)
{
	value = trim(value ?? '');

	if (addr == null || addr == '' || value == '')
		return addr;

	// the kernel-mode names are not identifiers — leave the address alone
	if (index([ 'eui64', 'random', 'stable', 'none' ], lc(value)) >= 0)
		return addr;

	let host = expand_v6(value);
	let base = expand_v6(addr);

	if (!host || !base)
		return addr;

	// An identifier is the LOW half and nothing else. Two refusals, both of
	// which would otherwise produce a plausible-looking wrong address rather
	// than an error:
	//
	//   - a non-zero network part is a whole address in the wrong field
	//     (`fe80::1`, `2001:db8::1`). Silently keeping its low half would hide
	//     the mistake and hand out an address the operator never asked for.
	//     netifd refuses the same thing for its own ip6ifaceid — it checks the
	//     top two words and errors out (interface.c:1021-1023, netifd 2026-09-10).
	//   - an all-zero identifier (`::`, `::0`, `1::`) makes <prefix>:: — the
	//     subnet-router ANYCAST address, which is not a host address at all.
	//
	// Refusing means leaving the address exactly as the network assigned it;
	// config.uc warns about the value so this is not silent.
	if (!valid_iface_id(host))
		return addr;

	// prefix from the network, identifier from the config
	return join(':', [ ...slice(base, 0, 4), ...slice(host, 4, 8) ]);
};
