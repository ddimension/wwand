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

// --- the shim's reply carries the MASKED prefix ------------------------------
//
// _settings_result is the one place that builds what the netifd shim reads, so
// the masked source belongs here rather than in each backend's build_settings.
// The shim puts it in the source field of the source-restricted default route,
// which is a PREFIX — netifd forwards that field to RTA_SRC untouched.
{
	let tt = mkself({});

	tt.entry.ctx.settings = {
		ipv4: { addr: '10.1.2.3', prefix: 32 },
		ipv6: { addr: '2408:844f:1521:e53a:20ce:e172:c052:1c79', plen: 64,
		        dns: [ '2001:4860:4860::8888' ] },
	};

	let r = tt.self._settings_result('wwan0', tt.entry, 'wwand0');

	eq(r.ipv6?.prefix, '2408:844f:1521:e53a:0:0:0:0',
		'settings: the reply carries the masked network part');
	eq(r.ipv6?.addr, '2408:844f:1521:e53a:20ce:e172:c052:1c79',
		'settings: ...beside the host address, which the shim still needs');
	eq(r.ipv6?.dns, [ '2001:4860:4860::8888' ], 'settings: the rest of the block is intact');

	// a COPY, not a mutation: ctx.settings is the context's own state and goes
	// to other consumers unchanged
	eq(tt.entry.ctx.settings.ipv6.prefix, null,
		'settings: the context state is not written to');

	// an address the helper cannot take apart must not invent a prefix
	tt.entry.ctx.settings.ipv6 = { addr: 'nonsense', plen: 64 };
	eq(tt.self._settings_result('wwan0', tt.entry, 'wwand0').ipv6?.prefix, null,
		'settings: an unparsable address yields no prefix rather than a wrong one');

	// no v6 at all (ipv4-only PDP) must stay exactly as it was
	tt.entry.ctx.settings.ipv6 = null;
	eq(tt.self._settings_result('wwan0', tt.entry, 'wwand0').ipv6, null,
		'settings: an ipv4-only context is untouched');
}

done('test_ctx_settings');
