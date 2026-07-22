// wwand tests — config model: new schema parsing + old-config compat layer.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as config from 'wwand/config.uc';

// --- new schema --------------------------------------------------------------

let r = config.parse({
	wwand: {
		globals: { '.type': 'wwand', log_level: 'debug' },
		m0: { '.type': 'modem', device: '/dev/cdc-wdm0', pincode: '1234',
		      modes: 'lte,nr5g', mux: 'auto', at_init: [ 'ATI' ], location: '1' },
		wan_ctx: { '.type': 'context', modem: 'm0', apn: 'internet',
		           pdp_type: 'ipv4v6', mux_id: '0' },
		wan2_ctx: { '.type': 'context', modem: 'm0', apn: '#2',
		            pdp_type: 'ipv4', mux_id: '2' },
	},
	network: {
		wan: { '.type': 'interface', proto: 'qmi', context: 'wan_ctx' },
		wan2: { '.type': 'interface', proto: 'qmi', context: 'wan2_ctx' },
	},
});

eq(r.globals.log_level, 'debug', 'new: log level');
eq(r.modems.m0.device, '/dev/cdc-wdm0', 'new: modem device');
eq(r.modems.m0.at_init, [ 'ATI' ], 'new: at_init list');
eq(r.modems.m0.location, true, 'new: location bool');
eq(r.modems.m0.failreboot, 100, 'new: failreboot default');
eq(r.contexts.wan_ctx.modem, 'm0', 'new: context modem ref');
eq(r.contexts.wan_ctx.interface, 'wan', 'new: interface attached');
eq(r.contexts.wan2_ctx.mux_id, 2, 'new: mux id');
eq(r.contexts.wan2_ctx.apn, '#2', 'new: profile passthrough apn');
// wan_ctx shares the modem with the muxed wan2_ctx -> auto-assigned channel
eq(r.contexts.wan_ctx.mux_id, 1, 'new: sibling context auto-muxed');
eq(length(r.warnings), 1, 'new: only the auto-mux warning');
eq(config.context_for_interface(r, 'wan2'), 'wan2_ctx', 'new: interface lookup');

// --- old-style compat --------------------------------------------------------

r = config.parse({
	network: {
		wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0',
		       apn: 'internet.telekom', pincode: '4321', modes: 'lte',
		       username: 'tm', password: 'tm', ipv6: '0',
		       zero_rx_timeout: '3600', failreboot: '50', delay: '5',
		       dhcp: '1', strongestnetwork: '1', location: '2',
		       metric: '10', use_pushed_mtu: '1', mtu: '1430' },
		wanb: { '.type': 'interface', proto: 'qmi', device: 'wwan0m2',
		        apn: 'work', ipv4: '1', ipv6: '1',
		        lock_4g: [ '1300:246' ], lock_persist: '1' },
		lan: { '.type': 'interface', proto: 'static' },
	},
});

// one modem synthesized for the shared parent netdev
eq(length(keys(r.modems)), 1, 'compat: one modem for wwan0 + wwan0m2');

let m = r.modems.compat_wwan0;
eq(m.netdev, 'wwan0', 'compat: parent netdev');
eq(m.pincode, '4321', 'compat: pincode moved to modem');
eq(m.modes, 'lte', 'compat: modes moved to modem');
eq(m.zero_rx_timeout, 3600, 'compat: zero rx timeout');
eq(m.failreboot, 50, 'compat: failreboot');
eq(m.delay, 5, 'compat: delay');
eq(m.location, true, 'compat: location>1 becomes true');
// cell lock lives on the interface sections in old configs (LuCI writes it
// there) — it must end up on the synthesized modem
eq(m.lock_4g, [ '1300:246' ], 'compat: lock_4g moved to modem');
eq(m.lock_persist, true, 'compat: lock_persist moved to modem');

let c = r.contexts.wan;
eq(c.modem, 'compat_wwan0', 'compat: context modem ref');
eq(c.interface, 'wan', 'compat: interface name');
// wwan0m2 sibling forces muxing; the parent context gets a free channel
eq(c.mux_id, 1, 'compat: wwan0 auto-muxed alongside wwan0m2');
eq(c.pdp_type, 'ipv4', 'compat: ipv6=0 -> ipv4');
eq(c.apn, 'internet.telekom', 'compat: apn');
eq(c.username, 'tm', 'compat: username');
eq(c.mtu, 1430, 'compat: mtu');
eq(c.use_pushed_mtu, true, 'compat: pushed mtu enabled');
eq(c.use_pushed_prefix, false, 'compat: pushed prefix off by default');

eq(r.contexts.wanb.mux_id, 2, 'compat: wwan0m2 -> mux 2');
eq(r.contexts.wanb.pdp_type, 'ipv4v6', 'compat: dual stack default');

// deprecated options produce warnings
let dep = filter(r.warnings, (w) => index(w, 'no longer supported') >= 0);
eq(length(dep), 2, 'compat: dhcp + strongestnetwork warned');

// --- edge cases --------------------------------------------------------------

// unknown modem reference drops the context
r = config.parse({
	wwand: { c1: { '.type': 'context', modem: 'nope', apn: 'x' } },
});
eq(length(keys(r.contexts)), 0, 'edge: unknown modem ref dropped');
ok(length(r.warnings) > 0, 'edge: warning for unknown modem');

// modem without any address info is dropped
r = config.parse({
	wwand: { m1: { '.type': 'modem', pincode: '1111' } },
});
eq(length(keys(r.modems)), 0, 'edge: modem without device dropped');

// indirect @device reference is skipped with warning
r = config.parse({
	network: {
		wan: { '.type': 'interface', proto: 'qmi', device: '@wan6', apn: 'x' },
	},
});
eq(length(keys(r.contexts)), 0, 'edge: @device skipped');

// pincode conflict: first wins, warning emitted
r = config.parse({
	network: {
		a: { '.type': 'interface', proto: 'qmi', device: 'wwan0', apn: 'x', pincode: '1111' },
		b: { '.type': 'interface', proto: 'qmi', device: 'wwan0m1', apn: 'y', pincode: '2222' },
	},
});
eq(r.modems.compat_wwan0.pincode, '1111', 'edge: first pincode wins');
ok(length(filter(r.warnings, (w) => index(w, 'conflicting pincode') >= 0)) == 1,
	'edge: pincode conflict warned');

// 'pdptype' option variant (seen in deployed configs) wins over flags
r = config.parse({
	network: {
		wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0',
		       apn: 'x', pdptype: 'ipv4', ipv4: '1', ipv6: '1' },
	},
});
eq(r.contexts.wan.pdp_type, 'ipv4', 'compat: pdptype option wins');

// cell lock options on new-style modems
r = config.parse({
	wwand: {
		m0: { '.type': 'modem', device: '/dev/cdc-wdm0',
		      lock_4g: '1300:246', lock_persist: '1' },
	},
});
eq(r.modems.m0.lock_4g, [ '1300:246' ], 'new: lock_4g normalized to list');
eq(r.modems.m0.lock_persist, true, 'new: lock_persist');

// mixed muxed/unmuxed contexts on one modem: the unmuxed one gets a channel
r = config.parse({
	network: {
		wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0', apn: 'a' },
		wanb: { '.type': 'interface', proto: 'qmi', device: 'wwan0m1', apn: 'b' },
	},
});
eq(r.contexts.wanb.mux_id, 1, 'automux: explicit mux kept');
eq(r.contexts.wan.mux_id, 2, 'automux: parent context assigned free channel');
ok(length(filter(r.warnings, (w) => index(w, 'auto-assigned mux id') >= 0)) == 1,
	'automux: warning emitted');

// no mux anywhere: nothing auto-assigned
r = config.parse({
	network: {
		wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0', apn: 'a' },
	},
});
eq(r.contexts.wan.mux_id, 0, 'automux: plain modem untouched');

// explicit m0 device: muxed with auto channel, link keeps the configured name
r = config.parse({
	network: {
		wwan0m0: { '.type': 'interface', proto: 'qmi', device: 'wwan0m0', apn: 'a' },
		wwan0m1: { '.type': 'interface', proto: 'qmi', device: 'wwan0m1', apn: 'b' },
	},
});
eq(r.contexts.wwan0m1.mux_id, 1, 'm0: explicit channel kept');
eq(r.contexts.wwan0m0.muxed, true, 'm0: marked muxed');
eq(r.contexts.wwan0m0.mux_id, 2, 'm0: free channel assigned');
eq(r.contexts.wwan0m0.mux_link, 'wwan0m0', 'm0: link name preserved');

// m0 alone also enables muxing
r = config.parse({
	network: {
		wwan0m0: { '.type': 'interface', proto: 'qmi', device: 'wwan0m0', apn: 'a' },
	},
});
eq(r.contexts.wwan0m0.mux_id, 1, 'm0-solo: channel assigned');
eq(r.contexts.wwan0m0.mux_link, 'wwan0m0', 'm0-solo: link name');

// parse_netdev
eq(config.parse_netdev('wwan0m3'), { netdev: 'wwan0', mux_id: 3, muxed: true }, 'parse_netdev mux');
eq(config.parse_netdev('wwan1'), { netdev: 'wwan1', mux_id: 0, muxed: false }, 'parse_netdev plain');
eq(config.parse_netdev('eth0'), { netdev: 'eth0', mux_id: 0, muxed: false }, 'parse_netdev other');

done('test_config');
