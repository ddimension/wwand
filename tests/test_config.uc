// wwand tests — config model: new schema parsing + old-config compat layer.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as config from 'wwand/config.uc';

// --- new schema --------------------------------------------------------------

let r = config.parse({
	wwand: {
		globals: { '.type': 'wwand', log_level: 'debug', hold_max: '120' },
		m0: { '.type': 'modem', device: '/dev/cdc-wdm0', pincode: '1234',
		      modes: 'lte,nr5g', mux: 'auto', at_init: [ 'ATI' ], location: '1' },
		wan_ctx: { '.type': 'context', modem: 'm0', apn: 'internet',
		           pdp_type: 'ipv4v6', mux_id: '0' },
		wan2_ctx: { '.type': 'context', modem: 'm0', apn: '#2',
		            pdp_type: 'ipv4', mux_id: '2' },
	},
	network: {
		wan: { '.type': 'interface', proto: 'qmi', context: 'wan_ctx' },
		wan2: { '.type': 'interface', proto: 'qmi', context: 'wan2_ctx', auto: '0' },
	},
});

eq(r.globals.log_level, 'debug', 'new: log level');
eq(r.globals.hold_max, 120, 'new: hold_max parsed (seconds)');
eq(r.modems.m0.device, '/dev/cdc-wdm0', 'new: modem device');
eq(r.modems.m0.at_init, [ 'ATI' ], 'new: at_init list');
eq(r.modems.m0.location, true, 'new: location bool');
eq(r.modems.m0.failreboot, 100, 'new: failreboot default');
eq(r.contexts.wan_ctx.modem, 'm0', 'new: context modem ref');
eq(r.contexts.wan_ctx.interface, 'wan', 'new: interface attached');
eq(r.contexts.wan2_ctx.mux_id, 2, 'new: mux id');
eq(r.contexts.wan2_ctx.apn, '#2', 'new: profile passthrough apn');
eq(r.contexts.wan_ctx.auto, true, 'new: interface auto defaults true');
eq(r.contexts.wan2_ctx.auto, false, 'new: auto 0 -> not proactively brought up');
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
		        lock_4g: [ '1300:246' ], lock_persist: '1', sim_slot: '2' },
		wanc: { '.type': 'interface', proto: 'qmi', device: 'wwan0m3',
		        apn: 'off', disabled: '1' },
		lan: { '.type': 'interface', proto: 'static' },
	},
});

// a disabled qmi interface is ignored entirely (no context synthesized)
eq(r.contexts.wanc, null, 'compat: disabled interface produces no context');

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
eq(m.sim_slot, 2, 'compat: sim_slot moved to modem');

let c = r.contexts.wan;
eq(c.modem, 'compat_wwan0', 'compat: context modem ref');
eq(c.interface, 'wan', 'compat: interface name');
eq(c.auto, true, 'compat: auto defaults true');
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

// --- network-native model (WireGuard-style, everything in /etc/config/network) -

r = config.parse({
	network: {
		globals: { '.type': 'wwand_globals', log_level: 'notice', hold_max: '45' },
		m0: { '.type': 'wwand_modem', usb_path: '1-1.2', pincode: '1234',
		      sim_slot: '1', modes: 'lte,nr5g', mcc: '262', mnc: '01' },
		// per-SIM override, matched at runtime by (modem, iccid)
		telekom: { '.type': 'wwand_sim', modem: 'm0', iccid: '8949...01',
		           pincode: '5678', apn: 'internet.t-d1.de', auth: 'chap' },
		// connection: references the modem, connection options inline
		wan: { '.type': 'interface', proto: 'qmi', modem: 'm0',
		       apn: 'internet', pdp_type: 'ipv4v6', auth: 'chap' },
	},
});

eq(r.globals.log_level, 'notice', 'net: wwand_globals log_level');
eq(r.globals.hold_max, 45, 'net: wwand_globals hold_max');
eq(r.modems.m0.usb_path, '1-1.2', 'net: wwand_modem usb_path');
eq(r.modems.m0.pincode, '1234', 'net: wwand_modem pincode (default)');
eq(r.modems.m0.sim_slot, 1, 'net: wwand_modem sim_slot');
eq(r.modems.m0.mcc, '262', 'net: mcc on the modem');
eq(r.contexts.wan.modem, 'm0', 'net: interface option modem -> context bound to modem');
eq(r.contexts.wan.interface, 'wan', 'net: interface name recorded');
eq(r.contexts.wan.apn, 'internet', 'net: apn inline on the interface');
eq(r.contexts.wan.pdp_type, 'ipv4v6', 'net: pdp_type inline');
eq(r.contexts.wan.auth, 'chap', 'net: auth inline');

// the SIM override is attached to its modem for runtime iccid matching
eq(length(r.modems.m0.sims ?? []), 1, 'net: wwand_sim attached to its modem');
eq(r.modems.m0.sims[0].iccid, '8949...01', 'net: sim override iccid');
eq(r.modems.m0.sims[0].pincode, '5678', 'net: sim override pincode');
eq(r.modems.m0.sims[0].apn, 'internet.t-d1.de', 'net: sim override apn');

// legacy pdptype alias on a network-native interface
r = config.parse({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1' },
		wan: { '.type': 'interface', proto: 'qmi', modem: 'm0', pdptype: 'ipv4' },
	},
});
eq(r.contexts.wan.pdp_type, 'ipv4', 'net: legacy pdptype alias honoured');

// mux: two interfaces on one wwand_modem
r = config.parse({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1', mux: 'rmnet' },
		wan: { '.type': 'interface', proto: 'qmi', modem: 'm0', device: 'wwan0m1', apn: 'internet' },
		ims: { '.type': 'interface', proto: 'qmi', modem: 'm0', device: 'wwan0m2', apn: 'ims' },
	},
});
eq(r.contexts.wan.mux_id, 1, 'net-mux: wan channel 1');
eq(r.contexts.ims.mux_id, 2, 'net-mux: ims channel 2');
eq(r.contexts.wan.modem, 'm0', 'net-mux: both share the modem');
eq(r.contexts.ims.modem, 'm0', 'net-mux: both share the modem (2)');

// explicit option mux_id (the 2-field UX: Modem + Mux channel)
r = config.parse({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1', mux: 'rmnet' },
		wan: { '.type': 'interface', proto: 'qmi', modem: 'm0', mux_id: '3', apn: 'internet' },
	},
});
eq(r.contexts.wan.mux_id, 3, 'net: explicit mux_id honoured');
eq(r.contexts.wan.muxed, true, 'net: explicit mux_id -> muxed');
eq(r.contexts.wan.mux_link, 'wwan0m3', 'net: mux_link derived from mux_id');

// guards
r = config.parse({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1' },
		bad_sim: { '.type': 'wwand_sim', modem: 'm0' },              // no iccid
		orphan: { '.type': 'wwand_sim', modem: 'nope', iccid: 'x' }, // unknown modem
		wan: { '.type': 'interface', proto: 'qmi', modem: 'ghost' }, // unknown modem
	},
});
ok(length(filter(r.warnings, w => index(w, 'no iccid') >= 0)) == 1, 'guard: wwand_sim without iccid warns');
ok(length(filter(r.warnings, w => index(w, "unknown modem 'nope'") >= 0)) == 1, 'guard: sim unknown modem warns');
ok(length(filter(r.warnings, w => index(w, "unknown modem 'ghost'") >= 0)) == 1, 'guard: interface unknown modem warns');
eq(r.contexts.wan, null, 'guard: interface with unknown modem builds no context');

// --- migrate_plan: convert old configs to the network-native model -----------

function mp_set(ch, section, opt) {
	for (let c in ch)
		if (c[0] == 'set' && c[2] == section && c[3] == opt)
			return c[4];
	return null;
}
function mp_has(ch, op, section, opt) {
	for (let c in ch)
		if (c[0] == op && c[2] == section && c[3] == opt)
			return true;
	return false;
}

// stock OpenWrt `proto mbim` interface -> proto qmi + wwand_modem
let ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'mbim', device: '/dev/cdc-wdm0',
	       apn: 'internet', pincode: '1234', pdptype: 'ipv4', auth: 'chap' },
} });
ok(mp_has(ch, 'add', 'wwmodem0', null), 'migrate-mbim: wwand_modem section created');
eq(mp_set(ch, 'wwmodem0', 'device'), '/dev/cdc-wdm0', 'migrate-mbim: device -> modem');
eq(mp_set(ch, 'wwmodem0', 'pincode'), '1234', 'migrate-mbim: pincode -> modem');
eq(mp_set(ch, 'wan', 'proto'), 'qmi', 'migrate-mbim: proto -> qmi');
eq(mp_set(ch, 'wan', 'modem'), 'wwmodem0', 'migrate-mbim: option modem set');
eq(mp_set(ch, 'wan', 'pdp_type'), 'ipv4', 'migrate-mbim: pdptype -> pdp_type');
ok(mp_has(ch, 'delete', 'wan', 'pincode'), 'migrate-mbim: pincode stripped off interface');
ok(mp_has(ch, 'delete', 'wan', 'device'), 'migrate-mbim: device stripped off interface');
ok(mp_has(ch, 'delete', 'wan', 'pdptype'), 'migrate-mbim: legacy pdptype deleted');
// apn/auth stay on the interface (not deleted, not re-set)
ok(!mp_has(ch, 'delete', 'wan', 'apn'), 'migrate-mbim: apn kept on interface');

// stock `proto ncm` with `mode` -> modes on the modem
ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'ncm', device: 'wwan0', apn: 'web', mode: 'lte' },
} });
eq(mp_set(ch, 'wwmodem0', 'modes'), 'lte', 'migrate-ncm: mode -> modes on modem');
eq(mp_set(ch, 'wan', 'proto'), 'qmi', 'migrate-ncm: proto -> qmi');
ok(mp_has(ch, 'delete', 'wan', 'mode'), 'migrate-ncm: stock mode stripped');

// wwand legacy inline proto qmi with a mux device -> modem netdev + mux_id
ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0m1', apn: 'internet' },
} });
eq(mp_set(ch, 'wwmodem0', 'device'), 'wwan0', 'migrate-mux: modem device = parent netdev');
eq(mp_set(ch, 'wan', 'mux_id'), '1', 'migrate-mux: mux channel derived from wwan0m1');
eq(mp_set(ch, 'wan', 'modem'), 'wwmodem0', 'migrate-mux: option modem');

// already network-native -> no changes
ch = config.migrate_plan({ network: {
	m0: { '.type': 'wwand_modem', usb_path: '1-1' },
	wan: { '.type': 'interface', proto: 'qmi', modem: 'm0', apn: 'internet' },
} });
eq(length(ch), 0, 'migrate: already new-style produces no changes');

// two interfaces sharing one modem device -> one wwand_modem
ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0m1', apn: 'internet' },
	ims: { '.type': 'interface', proto: 'qmi', device: 'wwan0m2', apn: 'ims' },
} });
eq(mp_set(ch, 'wan', 'modem'), 'wwmodem0', 'migrate-share: wan -> wwmodem0');
eq(mp_set(ch, 'ims', 'modem'), 'wwmodem0', 'migrate-share: ims -> same wwmodem0');
eq(length(filter(ch, c => c[0] == 'add' && c[4] == 'wwand_modem')), 1, 'migrate-share: exactly one wwand_modem for a shared device');

done('test_config');
