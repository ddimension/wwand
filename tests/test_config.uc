// wwand tests — config model: network-native schema + stock-config compat layer.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as config from 'wwand/config.uc';

// Adoption of bare legacy `proto qmi` interfaces is opt-in (global `takeover`,
// default off). Most tests below exercise the parsing/adoption engine, so they
// parse with takeover ON via padopt(); the dedicated "takeover gate" block near
// the end verifies the default-off behavior with a plain config.parse().
function padopt(raw) {
	raw.network.g = { '.type': 'wwand_globals', takeover: '1' };
	return config.parse(raw);
}

// --- network-native schema ---------------------------------------------------

let r = padopt({
	network: {
		globals: { '.type': 'wwand_globals', log_level: 'debug', hold_max: '120' },
		m0: { '.type': 'wwand_modem', device: '/dev/cdc-wdm0', pincode: '1234',
		      modes: 'lte,nr5g', mux: 'auto', at_init: [ 'ATI' ], location: '1',
		      serial: '99efe861', imei: '868965060008609', repower_time: '10' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'internet',
		       pdp_type: 'ipv4v6', mux_id: '0' },
		wan2: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: '#2',
		        pdp_type: 'ipv4', mux_id: '2', auto: '0' },
	},
});

eq(r.globals.log_level, 'debug', 'native: log level');
eq(r.globals.hold_max, 120, 'native: hold_max parsed (seconds)');
eq(r.modems.m0.device, '/dev/cdc-wdm0', 'native: modem device');
eq(r.modems.m0.at_init, [ 'ATI' ], 'native: at_init list');
eq(r.modems.m0.location, true, 'native: location bool');
eq(r.modems.m0.failreboot, 100, 'native: failreboot default');
eq(r.modems.m0.serial, '99efe861', 'native: modem serial anchor');
eq(r.modems.m0.imei, '868965060008609', 'native: modem imei anchor');
eq(r.modems.m0.repower_time, 10, 'native: repower_time parsed (seconds)');
eq(r.contexts.wan.modem, 'm0', 'native: context modem ref');
eq(r.contexts.wan.interface, 'wan', 'native: interface attached');
eq(r.contexts.wan2.mux_id, 2, 'native: mux id');
eq(r.contexts.wan2.apn, '#2', 'native: profile passthrough apn');
eq(r.contexts.wan.auto, true, 'native: interface auto defaults true');
eq(r.contexts.wan2.auto, false, 'native: auto 0 -> not proactively brought up');
// wan shares the modem with the muxed wan2 -> auto-assigned channel
eq(r.contexts.wan.mux_id, 1, 'native: sibling context auto-muxed');
eq(length(r.warnings), 1, 'native: only the auto-mux warning');
eq(config.context_for_interface(r, 'wan2'), 'wan2', 'native: interface lookup');

// --- old-style compat --------------------------------------------------------

r = padopt({
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
r = padopt({
	network: {
		wan: { '.type': 'interface', proto: 'wwand', modem: 'nope', apn: 'x' },
	},
});
eq(length(keys(r.contexts)), 0, 'edge: unknown modem ref dropped');
ok(length(r.warnings) > 0, 'edge: warning for unknown modem');

// modem without any address info is dropped
r = padopt({
	network: { m1: { '.type': 'wwand_modem', pincode: '1111' } },
});
eq(length(keys(r.modems)), 0, 'edge: modem without device dropped');

// indirect @device reference is skipped with warning
r = padopt({
	network: {
		wan: { '.type': 'interface', proto: 'qmi', device: '@wan6', apn: 'x' },
	},
});
eq(length(keys(r.contexts)), 0, 'edge: @device skipped');

// pincode conflict: first wins, warning emitted
r = padopt({
	network: {
		a: { '.type': 'interface', proto: 'qmi', device: 'wwan0', apn: 'x', pincode: '1111' },
		b: { '.type': 'interface', proto: 'qmi', device: 'wwan0m1', apn: 'y', pincode: '2222' },
	},
});
eq(r.modems.compat_wwan0.pincode, '1111', 'edge: first pincode wins');
ok(length(filter(r.warnings, (w) => index(w, 'conflicting pincode') >= 0)) == 1,
	'edge: pincode conflict warned');

// 'pdptype' option variant (seen in deployed configs) wins over flags
r = padopt({
	network: {
		wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0',
		       apn: 'x', pdptype: 'ipv4', ipv4: '1', ipv6: '1' },
	},
});
eq(r.contexts.wan.pdp_type, 'ipv4', 'compat: pdptype option wins');

// cell lock options on a wwand_modem
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', device: '/dev/cdc-wdm0',
		      lock_4g: '1300:246', lock_persist: '1' },
	},
});
eq(r.modems.m0.lock_4g, [ '1300:246' ], 'native: lock_4g normalized to list');
eq(r.modems.m0.lock_persist, true, 'native: lock_persist');

// mixed muxed/unmuxed contexts on one modem: the unmuxed one gets a channel
r = padopt({
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
r = padopt({
	network: {
		wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0', apn: 'a' },
	},
});
eq(r.contexts.wan.mux_id, 0, 'automux: plain modem untouched');

// explicit m0 device: muxed with auto channel, link keeps the configured name
r = padopt({
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
r = padopt({
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

r = padopt({
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
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1' },
		wan: { '.type': 'interface', proto: 'qmi', modem: 'm0', pdptype: 'ipv4' },
	},
});
eq(r.contexts.wan.pdp_type, 'ipv4', 'net: legacy pdptype alias honoured');

// the current proto name `wwand` parses identically to the legacy `qmi` alias
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'internet' },
	},
});
eq(r.contexts.wan.modem, 'm0', 'net: proto wwand interface bound to modem');
eq(r.contexts.wan.apn, 'internet', 'net: proto wwand apn inline');

// mux: two interfaces on one wwand_modem
r = padopt({
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
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1', mux: 'rmnet' },
		wan: { '.type': 'interface', proto: 'qmi', modem: 'm0', mux_id: '3', apn: 'internet' },
	},
});
eq(r.contexts.wan.mux_id, 3, 'net: explicit mux_id honoured');
eq(r.contexts.wan.muxed, true, 'net: explicit mux_id -> muxed');
eq(r.contexts.wan.mux_link, 'wwand0', 'net: derived mux child now auto-named wwand0');

// native path: a BARE netdev device + mux_id must derive <netdev>m<mux_id>, not
// name the child the same as the parent (regression: mux_link was 'wwan0')
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', device: 'wwan0', mux: 'rmnet' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'wwan0', mux_id: '1', apn: 'internet' },
	},
});
eq(r.contexts.wan.mux_id, 1, 'net: bare-netdev device + mux_id -> mux_id 1');
eq(r.contexts.wan.mux_link, 'wwand0', 'net: bare parent + mux_id -> auto wwand0 (never the parent name)');

// native path: an explicit muxed device name is used as-is + its suffix -> mux_id
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', device: 'wwan0', mux: 'rmnet' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'wwan0m2', apn: 'internet' },
	},
});
eq(r.contexts.wan.mux_id, 2, 'net: mux id derived from explicit device name');
eq(r.contexts.wan.mux_link, 'wwan0m2', 'net: explicit muxed device name used as-is');

// compat path (no `option modem`): a separate option mux_id must be honoured
// (regression: the compat path ignored mux_id and only read the device suffix)
r = padopt({
	network: {
		wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0', mux_id: '4', apn: 'internet' },
	},
});
eq(r.contexts.wan.mux_id, 4, 'compat: explicit mux_id honoured');
eq(r.contexts.wan.muxed, true, 'compat: explicit mux_id -> muxed');
eq(r.contexts.wan.mux_link, 'wwand0', 'compat: bare parent + mux_id -> auto wwand0');

// --- stable L3 names (wwandN auto-assignment) --------------------------------
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', device: '/dev/cdc-wdm0' },
		m1: { '.type': 'wwand_modem', device: '/dev/cdc-wdm1' },
		a: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'x' },
		b: { '.type': 'interface', proto: 'wwand', modem: 'm1', apn: 'y' },
		c: { '.type': 'interface', proto: 'wwand', modem: 'm0', mux_id: '2', apn: 'z' },
	},
});
eq(r.contexts.a.l3_name, 'wwand0', 'l3: first context auto wwand0');
eq(r.contexts.b.l3_name, 'wwand1', 'l3: second context auto wwand1 (across modems)');
eq(r.contexts.c.l3_name, 'wwand2', 'l3: muxed context in the same namespace');
eq(r.contexts.c.mux_link, 'wwand2', 'l3: mux child claimed under the wwandN name');

// explicit device pins the name; auto assignment skips it
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', device: '/dev/cdc-wdm0' },
		a: { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'wwand0', apn: 'x' },
		b: { '.type': 'interface', proto: 'wwand', modem: 'm0', mux_id: '1', apn: 'y' },
	},
});
eq(r.contexts.a.l3_name, 'wwand0', 'l3: explicit wwand0 honoured');
eq(r.contexts.b.l3_name, 'wwand1', 'l3: auto assignment skips the pinned name');

// a control-device path never becomes an L3 name
r = padopt({
	network: {
		wan: { '.type': 'interface', proto: 'qmi', device: '/dev/cdc-wdm0', apn: 'x' },
	},
});
eq(r.contexts.wan.l3_name, 'wwand0', 'l3: /dev control path -> auto name');

// modem hardware-quirk options reach the modem config
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', device: '/dev/cdc-wdm0', fcc_auth: 'foxconn:0' },
	},
});
eq(r.modems.m0.fcc_auth, 'foxconn:0', 'modem: fcc_auth passed through');

// wwand_sim.modem is OPTIONAL: an unbound sim applies to every modem (matched
// by ICCID), a bound one only to its modem
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1' },
		m1: { '.type': 'wwand_modem', usb_path: '1-2' },
		anysim:  { '.type': 'wwand_sim', iccid: '8949X', pincode: '4321' },   // no modem
		m0only:  { '.type': 'wwand_sim', modem: 'm0', iccid: '8949Y', pincode: '1111' },
	},
});
eq(length(r.modems.m0.sims ?? []), 2, 'sim-unbound: m0 gets the unbound sim + its own');
eq(length(r.modems.m1.sims ?? []), 1, 'sim-unbound: m1 gets only the unbound sim');

// guards
r = padopt({
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

// --- takeover gate (default off) ---------------------------------------------
// Adoption of a bare legacy `proto qmi` interface is opt-in. By default (no
// takeover) wwand ignores it — uqmi keeps it — while a `proto wwand` interface,
// and any interface carrying `option modem`, is always managed. Enabling the
// global `takeover` restores adoption of the bare qmi interface.
r = config.parse({
	network: {
		q: { '.type': 'interface', proto: 'qmi', device: 'wwan0', apn: 'a' },
		w: { '.type': 'interface', proto: 'wwand', device: 'wwan1', apn: 'b' },
	},
});
eq(r.contexts.q, null, 'gate: bare proto qmi NOT adopted when takeover off');
ok(r.contexts.w != null, 'gate: proto wwand always managed regardless of takeover');

r = config.parse({
	network: {
		g: { '.type': 'wwand_globals', takeover: '1' },
		q: { '.type': 'interface', proto: 'qmi', device: 'wwan0', apn: 'a' },
	},
});
ok(r.contexts.q != null, 'gate: bare proto qmi adopted when takeover on');

// migrate_plan is the explicit (user-triggered) conversion path — independent of
// the takeover gate; it converts regardless.
eq(r.globals.takeover, true, 'gate: takeover parsed true');

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

// stock OpenWrt `proto mbim` interface -> proto wwand + wwand_modem
let ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'mbim', device: '/dev/cdc-wdm0',
	       apn: 'internet', pincode: '1234', pdptype: 'ipv4', auth: 'chap' },
} });
ok(mp_has(ch, 'add', 'wwmodem0', null), 'migrate-mbim: wwand_modem section created');
eq(mp_set(ch, 'wwmodem0', 'device'), '/dev/cdc-wdm0', 'migrate-mbim: device -> modem');
eq(mp_set(ch, 'wwmodem0', 'pincode'), '1234', 'migrate-mbim: pincode -> modem');
eq(mp_set(ch, 'wan', 'proto'), 'wwand', 'migrate-mbim: proto -> wwand');
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
eq(mp_set(ch, 'wwmodem0', 'device'), 'wwan0', 'migrate-ncm: non-mux device = old netdev name');
eq(mp_set(ch, 'wan', 'proto'), 'wwand', 'migrate-ncm: proto -> wwand');
ok(mp_has(ch, 'delete', 'wan', 'mode'), 'migrate-ncm: stock mode stripped');

// legacy ipv4/ipv6 boolean flags (no pdptype) -> derived pdp_type, so the
// family constraint survives migration instead of widening to ipv4v6
ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0', apn: 'x',
	       ipv4: '1', ipv6: '0' },
} });
eq(mp_set(ch, 'wan', 'pdp_type'), 'ipv4', 'migrate-v4only: ipv4=1/ipv6=0 -> pdp_type ipv4');
ok(mp_has(ch, 'delete', 'wan', 'ipv6'), 'migrate-v4only: legacy ipv6 flag stripped');

// an explicit pdptype still wins over the flags
ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0', apn: 'x',
	       pdptype: 'ipv6', ipv4: '1', ipv6: '0' },
} });
eq(mp_set(ch, 'wan', 'pdp_type'), 'ipv6', 'migrate: explicit pdptype wins over ipv4/ipv6 flags');

// wwand legacy inline proto qmi with a mux device -> modem netdev + mux_id
ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0m1', apn: 'internet' },
} });
// a muxed interface `device` (wwan0mN) anchors the modem on the PARENT netdev
// name in `device` (discovery resolves a non-/dev `device` as a netdev); the
// mN becomes the connection's mux channel.
eq(mp_set(ch, 'wwmodem0', 'device'), 'wwan0', 'migrate-mux: modem device = parent netdev name');
eq(mp_set(ch, 'wan', 'mux_id'), '1', 'migrate-mux: mux channel derived from wwan0m1');
eq(mp_set(ch, 'wan', 'modem'), 'wwmodem0', 'migrate-mux: option modem');

// the optional USB anchor is NOT migrated onto the modem (path stays user-only,
// like wireless `path`), but it IS stripped off the interface. The modem is
// anchored on the netdev name instead.
ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0m1',
	       usb_path: '3-1', apn: 'internet' },
} });
eq(mp_set(ch, 'wwmodem0', 'device'), 'wwan0', 'migrate-path: modem anchored on netdev, not usb_path');
eq(mp_set(ch, 'wwmodem0', 'usb_path'), null, 'migrate-path: usb_path NOT set on modem');
eq(mp_set(ch, 'wwmodem0', 'path'), null, 'migrate-path: path NOT actively set on modem');
ok(mp_has(ch, 'delete', 'wan', 'usb_path'), 'migrate-path: usb_path stripped off interface');

// the modem `path` option is read (preferred), with `usb_path` still accepted
r = padopt({ network: {
	m0: { '.type': 'wwand_modem', path: '1-1.4' },
	wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'x' },
} });
eq(r.modems.m0.usb_path, '1-1.4', 'net: wwand_modem `path` read as the USB anchor');
r = padopt({ network: {
	m0: { '.type': 'wwand_modem', usb_path: '1-1.5' },
	wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'x' },
} });
eq(r.modems.m0.usb_path, '1-1.5', 'net: legacy `usb_path` still accepted');

// already network-native (proto wwand + option modem) -> no changes
ch = config.migrate_plan({ network: {
	m0: { '.type': 'wwand_modem', usb_path: '1-1' },
	wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'internet' },
} });
eq(length(ch), 0, 'migrate: already new-style produces no changes');

// network-native but still on the legacy `qmi` proto name (written by an older
// wwand) -> upgraded in place to `wwand`, nothing else touched
ch = config.migrate_plan({ network: {
	m0: { '.type': 'wwand_modem', usb_path: '1-1' },
	wan: { '.type': 'interface', proto: 'qmi', modem: 'm0', apn: 'internet' },
} });
eq(length(ch), 1, 'migrate: legacy qmi+modem yields exactly one change');
eq(mp_set(ch, 'wan', 'proto'), 'wwand', 'migrate: qmi+modem proto upgraded to wwand');

// two interfaces sharing one modem device -> one wwand_modem
ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'qmi', device: 'wwan0m1', apn: 'internet' },
	ims: { '.type': 'interface', proto: 'qmi', device: 'wwan0m2', apn: 'ims' },
} });
eq(mp_set(ch, 'wan', 'modem'), 'wwmodem0', 'migrate-share: wan -> wwmodem0');
eq(mp_set(ch, 'ims', 'modem'), 'wwmodem0', 'migrate-share: ims -> same wwmodem0');
eq(length(filter(ch, c => c[0] == 'add' && c[4] == 'wwand_modem')), 1, 'migrate-share: exactly one wwand_modem for a shared device');

// --- migrate_plan: ModemManager (`proto modemmanager`) ------------------------
// MM's `device` is a full sysfs path -> the modem's `path` anchor (interface
// component stripped); allowedauth/allowedmode/plmn/iptype/signalrate are
// translated; the MM-runtime and init_* options are stripped; apn/creds/metric
// stay on the interface untouched.
ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'modemmanager',
	       device: '/sys/devices/platform/soc/8af8800.usb/usb1/1-1',
	       apn: 'internet.telekom', allowedauth: [ 'pap', 'chap' ],
	       username: 't', password: 'p', pincode: '1234', iptype: 'ipv4',
	       plmn: '26201', allowedmode: '4g|5g', preferredmode: '5g',
	       signalrate: '30', allow_roaming: '1', init_epsbearer: 'none',
	       metric: '10' },
} });
ok(mp_has(ch, 'add', 'wwmodem0', null), 'migrate-mm: wwand_modem created');
eq(mp_set(ch, 'wwmodem0', 'path'), 'platform/soc/8af8800.usb/usb1/1-1',
	'migrate-mm: sysfs device -> modem path (prefix stripped)');
eq(mp_set(ch, 'wwmodem0', 'pincode'), '1234', 'migrate-mm: pincode -> modem');
eq(mp_set(ch, 'wwmodem0', 'modes'), 'lte,nr5g', 'migrate-mm: allowedmode 4g|5g -> lte,nr5g');
eq(mp_set(ch, 'wwmodem0', 'mcc'), '262', 'migrate-mm: plmn mcc');
eq(mp_set(ch, 'wwmodem0', 'mnc'), '01', 'migrate-mm: plmn mnc keeps the leading zero');
eq(mp_set(ch, 'wwmodem0', 'stats_interval'), '30', 'migrate-mm: signalrate -> stats_interval');
eq(mp_set(ch, 'wan', 'proto'), 'wwand', 'migrate-mm: proto -> wwand');
eq(mp_set(ch, 'wan', 'modem'), 'wwmodem0', 'migrate-mm: option modem set');
eq(mp_set(ch, 'wan', 'pdp_type'), 'ipv4', 'migrate-mm: iptype -> pdp_type');
eq(mp_set(ch, 'wan', 'auth'), 'both', 'migrate-mm: pap+chap -> both');
ok(mp_has(ch, 'delete', 'wan', 'device'), 'migrate-mm: device stripped');
ok(mp_has(ch, 'delete', 'wan', 'iptype'), 'migrate-mm: iptype stripped');
ok(mp_has(ch, 'delete', 'wan', 'plmn'), 'migrate-mm: plmn stripped');
ok(mp_has(ch, 'delete', 'wan', 'preferredmode'), 'migrate-mm: preferredmode stripped (no wwand equivalent)');
ok(mp_has(ch, 'delete', 'wan', 'init_epsbearer'), 'migrate-mm: init_* stripped (attach follows apn)');
ok(mp_has(ch, 'delete', 'wan', 'allow_roaming'), 'migrate-mm: allow_roaming stripped');
ok(!mp_has(ch, 'delete', 'wan', 'apn'), 'migrate-mm: apn kept on interface');
ok(!mp_has(ch, 'delete', 'wan', 'metric'), 'migrate-mm: metric kept (generic netifd)');

// edge cases: string-form auth, bare usb id, unmappable mode/auth -> omitted
ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'modemmanager', device: '1-1.2',
	       apn: 'x', allowedauth: 'chap', allowedmode: 'any' },
} });
eq(mp_set(ch, 'wwmodem0', 'path'), '1-1.2', 'migrate-mm: bare usb id kept verbatim');
eq(mp_set(ch, 'wan', 'auth'), 'chap', 'migrate-mm: string allowedauth chap');
ok(!mp_has(ch, 'set', 'wwmodem0', 'modes'), 'migrate-mm: allowedmode any -> no modes written');

ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'modemmanager', device: '1-1',
	       apn: 'x', allowedauth: [ 'eap' ], plmn: 'garbage' },
} });
ok(!mp_has(ch, 'set', 'wan', 'auth'), 'migrate-mm: eap-only auth -> no auth written');
ok(!mp_has(ch, 'set', 'wwmodem0', 'mcc'), 'migrate-mm: malformed plmn dropped');

// device-less MM section: nothing to anchor on -> skipped entirely
ch = config.migrate_plan({ network: {
	wan: { '.type': 'interface', proto: 'modemmanager', apn: 'x' },
} });
eq(length(ch), 0, 'migrate-mm: no device -> not migratable, no changes');

done('test_config');
