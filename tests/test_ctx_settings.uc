// wwand tests — context settings side effects (ctx_settings.uc).
// Focus: _apply_iface_id, the RA-path half of `option ip6ifaceid`. The
// substitution itself is covered in test_context_common (control-protocol path)
// and the kernel-mechanism choice in test_datapath; what is pinned here is the
// WIRING — that the option reaches the link layer at all, and that an unset one
// touches nothing. A gate that silently skips is exactly the failure this
// cannot afford: the option would look implemented and do nothing.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as ctx_settings from 'wwand/ctx_settings.uc';

let calls, logs;

function mkself(cfg) {
	let self = {};

	calls = [];
	logs = [];

	// datapath_fx stand-in: records what the link layer was asked to do
	let fx = {
		exists: (p) => true,
		read: (p) => (index(p, 'addr_gen_mode') >= 0) ? "0\n" : "0x1003\n",
		write: (p, v) => { push(calls, [ 'write', p, v ]); return true; },
		set_iface_token: (dev, tok) => { push(calls, [ 'token', dev, tok ]); return true; },
		log: (level, msg) => push(logs, msg),
		last_error: null,
	};

	ctx_settings.install(self, {
		log: (level, msg) => push(logs, msg),
		read_config: null,
		datapath_fx: fx,
	});

	return { self: self, entry: { cfg: cfg, ctx: { settings: null } } };
}

// --- unset: the default, and it must not touch the link at all --------------
let t = mkself({});
t.self._apply_iface_id('wwan0', t.entry, 'wwand0');
eq(length(calls), 0, 'wiring: no ip6ifaceid -> the link layer is not touched');

t = mkself({ ip6ifaceid: '' });
t.self._apply_iface_id('wwan0', t.entry, 'wwand0');
eq(length(calls), 0, 'wiring: an empty ip6ifaceid is the same as unset');

// --- a literal reaches the kernel as a token --------------------------------
t = mkself({ ip6ifaceid: '::1234' });
t.self._apply_iface_id('wwan0', t.entry, 'wwand0');
eq(calls, [ [ 'token', 'wwand0', '::1234' ] ],
	'wiring: a literal identifier is sent as the kernel token, on the l3 netdev');

// --- a generation mode goes to addr_gen_mode instead ------------------------
// (the fake reports addr_gen_mode 0, which IS eui64, so `random` is the value
// that must produce a write)
t = mkself({ ip6ifaceid: 'random' });
t.self._apply_iface_id('wwan0', t.entry, 'wwand0');
eq(length(filter(calls, (c) => c[0] == 'token')), 0,
	'wiring: a generation mode sends no token');
eq(calls, [ [ 'write', '/proc/sys/net/ipv6/conf/wwand0/addr_gen_mode', '3' ] ],
	'wiring: random writes addr_gen_mode 3 on the l3 netdev');

// and it stays idempotent: asking for the mode the device already has writes
// nothing, so a re-applied option does not churn the sysctl on every up
t = mkself({ ip6ifaceid: 'eui64' });
t.self._apply_iface_id('wwan0', t.entry, 'wwand0');
eq(length(calls), 0, 'wiring: a mode already in force is not rewritten');

// --- NOT gated on settings.ipv6 ---------------------------------------------
//
// _enable_ipv6 beside it only runs when the control protocol produced an
// address. This one must run anyway: the whole point of the RA path is that
// there is no such address, and copying that gate would have made the option a
// no-op exactly where it is needed.
t = mkself({ ip6ifaceid: '::9' });
t.entry.ctx.settings = null;
t.self._apply_iface_id('wwan0', t.entry, 'wwand0');
eq(calls, [ [ 'token', 'wwand0', '::9' ] ],
	'wiring: applied even with no ipv6 settings from the control protocol');

// no netdev yet (modem not enumerated) -> nothing, no crash
t = mkself({ ip6ifaceid: '::9' });
t.self._apply_iface_id('wwan0', t.entry, null);
eq(length(calls), 0, 'wiring: no netdev -> nothing attempted');

done('test_ctx_settings');
