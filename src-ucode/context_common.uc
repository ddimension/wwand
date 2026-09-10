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
	//     top two words and errors out (interface.c:1021-1023).
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
