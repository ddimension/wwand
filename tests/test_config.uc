// wwand tests — config model: network-native schema + stock-config compat layer.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as config from 'wwand/config.uc';

// wwand manages `proto wwand` and nothing else — a stock `proto qmi` interface
// is never adopted, so exactly one stack owns any given interface. padopt() used
// to enable the old global `takeover` for the adoption tests; it is now a plain
// parse and kept only so the call sites below read unchanged.
function padopt(raw) {
	return config.parse(raw);
}

// --- network-native schema ---------------------------------------------------

let r = padopt({
	network: {
		globals: { '.type': 'wwand_globals', log_level: 'debug', hold_max: '120' },
		m0: { '.type': 'wwand_modem', device: '/dev/cdc-wdm0', pincode: '1234',
		      modes: 'lte,nr5g', mux: 'auto', at_init: [ 'ATI' ], location: '1',
		      serial: '99efe861', imei: '350000000000000', repower_time: '10' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'internet',
		       pdp_type: 'ipv4v6', mux_id: '0' },
		wan2: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: '#2',
		        pdp_type: 'ipv4', mux_id: '2', auto: '0',
		        hard_reconnect_on_ip_change: '1' },
	},
});

eq(r.globals.log_level, 'debug', 'native: log level');
eq(r.globals.hold_max, 120, 'native: hold_max parsed (seconds)');
eq(r.modems.m0.device, '/dev/cdc-wdm0', 'native: modem device');
eq(r.modems.m0.at_init, [ 'ATI' ], 'native: at_init list');
eq(r.modems.m0.location, true, 'native: location bool');
eq(r.modems.m0.failreboot, 100, 'native: failreboot default');
eq(r.modems.m0.serial, '99efe861', 'native: modem serial anchor');
eq(r.modems.m0.imei, '350000000000000', 'native: modem imei anchor');
eq(r.modems.m0.repower_time, 10, 'native: repower_time parsed (seconds)');
eq(r.contexts.wan.modem, 'm0', 'native: context modem ref');
eq(r.contexts.wan.interface, 'wan', 'native: interface attached');
eq(r.contexts.wan2.mux_id, 2, 'native: mux id');
eq(r.contexts.wan2.hard_reconnect_on_ip_change, true, 'native: hard_reconnect_on_ip_change parsed (bool)');
eq(r.contexts.wan.hard_reconnect_on_ip_change, false, 'native: hard_reconnect defaults off');
eq(r.contexts.wan2.apn, '#2', 'native: profile passthrough apn');
eq(r.contexts.wan.auto, true, 'native: interface auto defaults true');
eq(r.contexts.wan2.auto, false, 'native: auto 0 -> not proactively brought up');
// wan shares the modem with the muxed wan2 -> auto-assigned channel
eq(r.contexts.wan.mux_id, 1, 'native: sibling context auto-muxed');
eq(length(r.warnings), 1, 'native: only the auto-mux warning');
eq(config.context_for_interface(r, 'wan2'), 'wan2', 'native: interface lookup');

// --- named PLMN lists (wwand_plmnlist) + plmn_list attach --------------------
r = config.parse({
	network: {
		flist:  { '.type': 'wwand_plmnlist', type: 'fplmn', plmn: [ '26202', '310410' ] },
		nlist:  { '.type': 'wwand_plmnlist', type: 'nas', plmn: [ '26201 utran,eutran' ] },
		notype: { '.type': 'wwand_plmnlist', plmn: [ '26203' ] },
		mp:     { '.type': 'wwand_modem', device: '/dev/cdc-wdm0', plmn_list: 'flist' },
		msim:   { '.type': 'wwand_sim', iccid: '8988000000012345678', plmn_list: 'nlist' },
		bad:    { '.type': 'wwand_modem', device: '/dev/cdc-wdm9', plmn_list: 'ghost' },
		wan:    { '.type': 'interface', proto: 'wwand', modem: 'mp', apn: 'i' },
	},
});
eq(r.plmnlists.flist.type, 'fplmn', 'plmnlist: fplmn type parsed');
eq(r.plmnlists.flist.entries[0], { mcc: '262', mnc: '02', gsm: false, utran: false, eutran: false, ngran: false },
	'plmnlist: fplmn entry parsed (no AcT flags set)');
eq(r.plmnlists.flist.entries[1].mnc, '410', 'plmnlist: 3-digit MNC entry');
eq(r.plmnlists.nlist.type, 'nas', 'plmnlist: nas type');
eq(r.plmnlists.nlist.entries[0].eutran, true, 'plmnlist: nas entry AcT parsed');
eq(r.plmnlists.notype.type, 'nas', 'plmnlist: missing type -> nas default');
eq(r.modems.mp.plmn_restore, { type: 'fplmn', entries: r.plmnlists.flist.entries },
	'plmnlist: modem plmn_list resolves to fplmn restore');
eq(r.sims.msim.plmn_restore.type, 'nas', 'plmnlist: per-SIM plmn_list resolves (nas)');
ok(length(filter(r.warnings, (w) => match(w, /unknown plmn_list 'ghost'/))) == 1,
	'plmnlist: dangling plmn_list reference warns');

// --- unknown/dead options are flagged with a typo hint -----------------------
// ('pin' instead of 'pincode' silently produced "PIN required but none
// configured" -> SIM_BLOCKED on real hardware)

r = padopt({
	network: {
		m0:  { '.type': 'wwand_modem', device: '/dev/cdc-wdm0', pin: '0000', bogus: 'x' },
		s0:  { '.type': 'wwand_sim', iccid: '8988000000012345678', pincode: '1234', pn: 'y' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'i' },
	},
});
ok(length(filter(r.warnings, (w) => match(w, /wwand_modem m0: unknown option 'pin'/) && match(w, /did you mean 'pincode'/))) == 1,
	'unknown-opt: pin suggests pincode');
ok(length(filter(r.warnings, (w) => match(w, /unknown option 'bogus' \(ignored\)/))) == 1,
	'unknown-opt: bogus flagged (no hint)');
eq(length(r.modems.m0.config_notes), 2, 'unknown-opt: notes attached to the modem config');
ok(length(filter(r.warnings, (w) => match(w, /wwand_sim s0: unknown option 'pn'/))) == 1,
	'unknown-opt: sim section checked too');

// --- old-style compat --------------------------------------------------------

r = padopt({
	network: {
		wan: { '.type': 'interface', proto: 'wwand', device: 'wwan0',
		       apn: 'internet.telekom', pincode: '4321', modes: 'lte',
		       username: 'tm', password: 'tm', ipv6: '0',
		       zero_rx_timeout: '3600', failreboot: '50', delay: '5',
		       dhcp: '1', strongestnetwork: '1', location: '2',
		       metric: '10', use_pushed_mtu: '1', mtu: '1430' },
		wanb: { '.type': 'interface', proto: 'wwand', device: 'wwan0m2',
		        apn: 'work', ipv4: '1', ipv6: '1',
		        lock_4g: [ '1300:246' ], lock_persist: '1', sim_slot: '2' },
		wanc: { '.type': 'interface', proto: 'wwand', device: 'wwan0m3',
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
		wan: { '.type': 'interface', proto: 'wwand', device: '@wan6', apn: 'x' },
	},
});
eq(length(keys(r.contexts)), 0, 'edge: @device skipped');

// pincode conflict: first wins, warning emitted
r = padopt({
	network: {
		a: { '.type': 'interface', proto: 'wwand', device: 'wwan0', apn: 'x', pincode: '1111' },
		b: { '.type': 'interface', proto: 'wwand', device: 'wwan0m1', apn: 'y', pincode: '2222' },
	},
});
eq(r.modems.compat_wwan0.pincode, '1111', 'edge: first pincode wins');
ok(length(filter(r.warnings, (w) => index(w, 'conflicting pincode') >= 0)) == 1,
	'edge: pincode conflict warned');

// 'pdptype' option variant (seen in deployed configs) wins over flags
r = padopt({
	network: {
		wan: { '.type': 'interface', proto: 'wwand', device: 'wwan0',
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
		wan: { '.type': 'interface', proto: 'wwand', device: 'wwan0', apn: 'a' },
		wanb: { '.type': 'interface', proto: 'wwand', device: 'wwan0m1', apn: 'b' },
	},
});
eq(r.contexts.wanb.mux_id, 1, 'automux: explicit mux kept');
eq(r.contexts.wan.mux_id, 2, 'automux: parent context assigned free channel');
ok(length(filter(r.warnings, (w) => index(w, 'auto-assigned mux id') >= 0)) == 1,
	'automux: warning emitted');

// no mux anywhere: nothing auto-assigned
r = padopt({
	network: {
		wan: { '.type': 'interface', proto: 'wwand', device: 'wwan0', apn: 'a' },
	},
});
eq(r.contexts.wan.mux_id, 0, 'automux: plain modem untouched');

// explicit m0 device: muxed with auto channel, link keeps the configured name
r = padopt({
	network: {
		wwan0m0: { '.type': 'interface', proto: 'wwand', device: 'wwan0m0', apn: 'a' },
		wwan0m1: { '.type': 'interface', proto: 'wwand', device: 'wwan0m1', apn: 'b' },
	},
});
eq(r.contexts.wwan0m1.mux_id, 1, 'm0: explicit channel kept');
eq(r.contexts.wwan0m0.muxed, true, 'm0: marked muxed');
eq(r.contexts.wwan0m0.mux_id, 2, 'm0: free channel assigned');
eq(r.contexts.wwan0m0.mux_link, 'wwan0m0', 'm0: link name preserved');

// m0 alone also enables muxing
r = padopt({
	network: {
		wwan0m0: { '.type': 'interface', proto: 'wwand', device: 'wwan0m0', apn: 'a' },
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
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0',
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
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', pdptype: 'ipv4' },
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
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'wwan0m1', apn: 'internet' },
		ims: { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'wwan0m2', apn: 'ims' },
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
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', mux_id: '3', apn: 'internet' },
	},
});
eq(r.contexts.wan.mux_id, 3, 'net: explicit mux_id honoured');
eq(r.contexts.wan.muxed, true, 'net: explicit mux_id -> muxed');
eq(r.contexts.wan.mux_link, 'wwand0', 'net: derived mux child now auto-named wwand0');

// mux_id range. QMAP/rmnet channels are 8 bit with 0 = untagged parent, so the
// kernel takes 1..254. An out-of-range value used to be passed straight down to
// wwand_io, which casts it to uint16_t for IFLA_RMNET_MUX_ID: 65537 SILENTLY
// became channel 1 and collided with a real one, while 300 only surfaced as an
// obscure link-creation errno. Now it warns and drops muxing for the interface.
let mux_bad = (raw) => padopt({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1', mux: 'rmnet' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', mux_id: raw, apn: 'internet' },
	},
});

r = mux_bad('65537');
eq(r.contexts.wan.mux_id, 0, 'mux range: 65537 rejected (would alias channel 1)');
eq(r.contexts.wan.muxed, false, 'mux range: rejected id disables muxing');
ok(length(filter(r.warnings, (w) => index(w, 'mux_id') >= 0)) == 1,
	'mux range: 65537 warns');

r = mux_bad('300');
eq(r.contexts.wan.mux_id, 0, 'mux range: 300 rejected (kernel -ERANGE)');

r = mux_bad('255');
eq(r.contexts.wan.mux_id, 0, 'mux range: 255 rejected (RMNET_MAX_LOGICAL_EP - 1)');

r = mux_bad('254');
eq(r.contexts.wan.mux_id, 254, 'mux range: 254 is the highest valid channel');
eq(r.contexts.wan.muxed, true, 'mux range: 254 muxed');

r = mux_bad('-1');
eq(r.contexts.wan.mux_id, 0, 'mux range: negative rejected');

r = mux_bad('abc');
eq(r.contexts.wan.mux_id, 0, 'mux range: non-numeric rejected');

r = mux_bad('1.5');
eq(r.contexts.wan.mux_id, 0, 'mux range: fractional rejected');

// two contexts of ONE modem must not claim the same QMAP channel: the second
// rmnet link cannot be created on that parent, and whichever comes up owns the
// other's downlink frames. The first claimant (uci order) keeps the id.
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1', mux: 'rmnet' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', mux_id: '3', apn: 'a' },
		ims: { '.type': 'interface', proto: 'wwand', modem: 'm0', mux_id: '3', apn: 'b' },
	},
});
eq(r.contexts.wan.mux_id, 3, 'mux dup: first claimant keeps the channel');
ok(r.contexts.ims.mux_id != 3 && r.contexts.ims.mux_id > 0,
	'mux dup: second gets a different channel');
eq(r.contexts.ims.muxed, true, 'mux dup: second stays muxed');
ok(length(filter(r.warnings, (w) => index(w, 'already used by interface wan') >= 0)) == 1,
	'mux dup: collision warned, naming the other interface');

// the same channel on DIFFERENT modems is fine
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1', mux: 'rmnet' },
		m1: { '.type': 'wwand_modem', usb_path: '1-2', mux: 'rmnet' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', mux_id: '1', apn: 'a' },
		wanb: { '.type': 'interface', proto: 'wwand', modem: 'm1', mux_id: '1', apn: 'b' },
	},
});
eq(r.contexts.wan.mux_id, 1, 'mux dup: per-modem namespace (m0)');
eq(r.contexts.wanb.mux_id, 1, 'mux dup: per-modem namespace (m1)');
eq(length(filter(r.warnings, (w) => index(w, 'already used') >= 0)), 0,
	'mux dup: no warning across modems');

// AT backends interpolate apn/user/password into QUOTED AT strings, which have
// no escape mechanism — the engine refuses such a command outright, so warn at
// parse time where the user can still see why. QMI/MBIM carry them as TLVs.
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1', pincode: '12ab' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0',
		       apn: 'inter"net', username: "a\rATD*99#", password: 'ok' },
	},
});
ok(length(filter(r.warnings, (w) => index(w, 'interface wan: apn contains') >= 0)) == 1,
	'at-safe: quoted apn warned');
ok(length(filter(r.warnings, (w) => index(w, 'interface wan: username contains') >= 0)) == 1,
	'at-safe: control char in username warned');
eq(length(filter(r.warnings, (w) => index(w, 'password contains') >= 0)), 0,
	'at-safe: clean password not warned');
ok(length(filter(r.warnings, (w) => index(w, 'pincode must be digits') >= 0)) == 1,
	'at-safe: non-numeric pincode warned');
ok(!length(filter(r.warnings, (w) => index(w, 'ATD*99#') >= 0)),
	'at-safe: the offending value is never put in the warning');

// `option mux` may name a datapath plugin, which the daemon require()s as
// wwand.datapath_<name> — so the value lands in a MODULE PATH and its shape is
// checked here. Whether the package exists is a runtime question (control_note).
r = padopt({
	network: {
		m0: { '.type': 'wwand_modem', usb_path: '1-1', mux: 'vendor_x2' },
		m1: { '.type': 'wwand_modem', usb_path: '1-2', mux: '../evil' },
		m2: { '.type': 'wwand_modem', usb_path: '1-3', mux: 'rmnet' },
	},
});
eq(r.modems.m0.mux, 'vendor_x2', 'mux name: a plugin name passes through');
eq(r.modems.m1.mux, 'auto', 'mux name: a path-shaped value is refused');
eq(r.modems.m2.mux, 'rmnet', 'mux name: built-ins unaffected');
ok(length(filter(r.warnings, (w) => index(w, 'invalid mux') >= 0)) == 1,
	'mux name: exactly the bad one warns');

// the compat parser (no `option modem`) resolves the channel through the same
// helper — the two interface parsers must not drift
r = padopt({
	network: {
		wanq: { '.type': 'interface', proto: 'wwand', device: 'wwan0',
		        mux_id: '9999', apn: 'internet' },
	},
});
eq(r.contexts.wanq?.mux_id, 0, 'mux range: compat parser validates too');

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
		wan: { '.type': 'interface', proto: 'wwand', device: 'wwan0', mux_id: '4', apn: 'internet' },
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
		wan: { '.type': 'interface', proto: 'wwand', device: '/dev/cdc-wdm0', apn: 'x' },
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
		wan: { '.type': 'interface', proto: 'wwand', modem: 'ghost' }, // unknown modem
	},
});
ok(length(filter(r.warnings, w => index(w, 'no iccid') >= 0)) == 1, 'guard: wwand_sim without iccid warns');
ok(length(filter(r.warnings, w => index(w, "unknown modem 'nope'") >= 0)) == 1, 'guard: sim unknown modem warns');
ok(length(filter(r.warnings, w => index(w, "unknown modem 'ghost'") >= 0)) == 1, 'guard: interface unknown modem warns');
eq(r.contexts.wan, null, 'guard: interface with unknown modem builds no context');

// --- proto ownership: `proto qmi` is never adopted ---------------------------
// uqmi owns `proto qmi`. wwand claims only `proto wwand`, so a given interface
// (and its control device) has exactly one owner and netifd's handler load order
// never decides anything. There is no switch that changes this — the former
// global `takeover` is gone.
r = config.parse({
	network: {
		q: { '.type': 'interface', proto: 'qmi', device: 'wwan0', apn: 'a' },
		w: { '.type': 'interface', proto: 'wwand', device: 'wwan1', apn: 'b' },
	},
});
eq(r.contexts.q, null, 'ownership: bare proto qmi is left to uqmi');
ok(r.contexts.w != null, 'ownership: proto wwand is managed');

// a stale `option takeover` in a carried-over config must not resurrect it
r = config.parse({
	network: {
		g: { '.type': 'wwand_globals', takeover: '1' },
		q: { '.type': 'interface', proto: 'qmi', device: 'wwan0', apn: 'a' },
	},
});
eq(r.contexts.q, null, 'ownership: a leftover option takeover does not re-enable adoption');
eq(r.globals.takeover, null, 'ownership: takeover is no longer a global');

// migrate_plan is the explicit (user-triggered) conversion path and converts a
// `proto qmi` interface regardless — that is how an interface changes owner.

// --- device blocklist --------------------------------------------------------
// A device named by a NON-wwand interface belongs to that stack. Two dialers on
// one control node is the one failure the coexistence model has to prevent, and
// packaging cannot express it — so the daemon collects the claims here.
r = config.parse({
	network: {
		wan:  { '.type': 'interface', proto: 'qmi', device: '/dev/cdc-wdm0' },
		lan:  { '.type': 'interface', proto: 'static', device: 'br-lan' },
		ncm:  { '.type': 'interface', proto: 'ncm', ifname: 'wwan1', ctldevice: '/dev/ttyUSB2' },
		mine: { '.type': 'interface', proto: 'wwand', device: 'wwan0', apn: 'a' },
	},
});

eq(r.blocked['/dev/cdc-wdm0'], { interface: 'wan', proto: 'qmi' },
	'blocklist: a stock qmi interface claims its control device');
eq(r.blocked['br-lan'], { interface: 'lan', proto: 'static' },
	'blocklist: any non-wwand proto claims its device, not just cellular ones');
eq(r.blocked.wwan1, { interface: 'ncm', proto: 'ncm' }, 'blocklist: ifname counts');
eq(r.blocked['/dev/ttyUSB2'], { interface: 'ncm', proto: 'ncm' }, 'blocklist: ctldevice counts');
eq(r.blocked.wwan0, null, 'blocklist: wwand-owned devices are NOT blocked');

// a DISABLED interface is never brought up by netifd, so it owns nothing — a
// stale section must not block a device forever
r = config.parse({
	network: {
		old: { '.type': 'interface', proto: 'qmi', device: '/dev/cdc-wdm0', disabled: '1' },
	},
});
eq(r.blocked['/dev/cdc-wdm0'], null, 'blocklist: a disabled interface claims nothing');

// `@name` references an interface, not a device
r = config.parse({
	network: { six: { '.type': 'interface', proto: 'dhcpv6', device: '@wan' } },
});
eq(r.blocked['@wan'], null, 'blocklist: an @alias is not a device claim');

// first claimant wins the attribution; the device is blocked either way
r = config.parse({
	network: {
		a: { '.type': 'interface', proto: 'qmi', device: '/dev/cdc-wdm0' },
		b: { '.type': 'interface', proto: 'mbim', device: '/dev/cdc-wdm0' },
	},
});
eq(r.blocked['/dev/cdc-wdm0'].interface, 'a', 'blocklist: first claimant is attributed');

// path-shaped claims: uqmi/umbim `devpath` and wwan.sh `bus`. wwan.sh declares
// NO `device` option at all, so without these two a `proto wwan` interface
// claims a modem entirely invisibly.
r = config.parse({
	network: {
		q: { '.type': 'interface', proto: 'qmi',  devpath: '/sys/devices/platform/x/usb1/1-1' },
		w: { '.type': 'interface', proto: 'wwan', bus: '1-2' },
		d: { '.type': 'interface', proto: 'mbim', devpath: '/sys/devices/y', disabled: '1' },
	},
});

eq(r.blocked_paths['/sys/devices/platform/x/usb1/1-1'],
	{ interface: 'q', proto: 'qmi', opt: 'devpath' }, 'blocklist: qmi devpath collected');
eq(r.blocked_paths['1-2'], { interface: 'w', proto: 'wwan', opt: 'bus' },
	'blocklist: wwan bus collected (that proto has no device option at all)');
eq(r.blocked_paths['/sys/devices/y'], null,
	'blocklist: a disabled interface claims no path either');

// `device` is not always a device NAME. Raised by a maintainer on
// openwrt/packages#30185: the coexistence check covered qmi/mbim/ncm/wwan but
// not 3g, directip and modemmanager. comgt's 3g and directip declare
// `device:device` — a real device node, already covered by the name branch.
// modemmanager declares a plain `device` and puts a SYSFS PATH in it
// ("validate sysfs path given in config", modemmanager.sh), which can never
// match a /dev node or a netdev name, so it has to be recorded as a path too.
r = config.parse({
	network: {
		mm: { '.type': 'interface', proto: 'modemmanager',
		      device: '/sys/devices/platform/soc/usb1/1-1' },
		g3: { '.type': 'interface', proto: '3g',       device: '/dev/ttyUSB0' },
		di: { '.type': 'interface', proto: 'directip', device: '/dev/ttyUSB2' },
		ix: { '.type': 'interface', proto: 'modemmanager', device: '0' },
	},
});

eq(r.blocked_paths['/sys/devices/platform/soc/usb1/1-1'],
	{ interface: 'mm', proto: 'modemmanager', opt: 'device' },
	'blocklist: a modemmanager sysfs path in `device` is a PATH claim');
eq(r.blocked['/sys/devices/platform/soc/usb1/1-1'].proto, 'modemmanager',
	'blocklist: and stays a literal claim as well');
eq(r.blocked['/dev/ttyUSB0'], { interface: 'g3', proto: '3g' },
	'blocklist: comgt 3g binds by device node, covered by the name branch');
eq(r.blocked['/dev/ttyUSB2'], { interface: 'di', proto: 'directip' },
	'blocklist: comgt directip likewise');
eq(r.blocked_paths['/dev/ttyUSB0'], null,
	'blocklist: a device NODE is not turned into a path claim');
eq(r.blocked_paths['0'], null,
	'blocklist: an mmcli index names no hardware and is not a path claim');

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

// collision guard: a box ALREADY carrying wwmodem0 (an existing wwand modem)
// must not have a migration overwrite it — the new section skips to wwmodem1.
ch = config.migrate_plan({ network: {
	wwmodem0: { '.type': 'wwand_modem', serial: 'abc' },
	other:    { '.type': 'interface', proto: 'wwand', modem: 'wwmodem0', apn: 'a' },
	wan:      { '.type': 'interface', proto: 'mbim', device: '/dev/cdc-wdm0', apn: 'internet' },
} });
ok(mp_has(ch, 'add', 'wwmodem1', null), 'migrate-collision: new section is wwmodem1, not wwmodem0');
ok(!mp_has(ch, 'add', 'wwmodem0', null), 'migrate-collision: existing wwmodem0 untouched');
eq(mp_set(ch, 'wan', 'modem'), 'wwmodem1', 'migrate-collision: interface links the fresh wwmodem1');

done('test_config');
