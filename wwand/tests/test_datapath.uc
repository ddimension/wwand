// wwand tests — datapath/link setup logic (netlink.uc).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as fakefx from './lib/fakefx.uc';
import * as netlink from 'wwand/netlink.uc';

// --- board quirk table -------------------------------------------------------

let fx = fakefx.create({ files: { '/tmp/sysinfo/board_name': "zyxel,nr7101\n" } });
eq(netlink.board_dgram_size(fx, 0), 31744, 'quirk: nr7101 31K');
eq(netlink.board_dgram_size(fx, 16384), 16384, 'quirk: explicit override wins');

fx = fakefx.create({ files: { '/tmp/sysinfo/board_name': "generic,board\n" } });
eq(netlink.board_dgram_size(fx, 0), 4096, 'quirk: default 4K');

fx = fakefx.create();
eq(netlink.board_dgram_size(fx, 0), 4096, 'quirk: missing board file -> default');
eq(netlink.board_dgram_size(fx, 0, 'RG650E-EU'), 31744, 'quirk: model table wins');
eq(netlink.board_dgram_size(fx, 8192, 'RG650E-EU'), 8192, 'quirk: override beats model');

// --- backend selection -------------------------------------------------------

let caps_rmnet = {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
	'/sys/class/net/wwan0/qmi/add_mux': true,
	'/sys/class/net/wwan0/qmi/rx_urb_size': true,
};

fx = fakefx.create({ present: caps_rmnet });
eq(netlink.select_backend(fx, 'wwan0', 'auto', true), 'rmnet', 'backend: auto prefers rmnet');
eq(netlink.select_backend(fx, 'wwan0', 'qmimux', true), 'qmimux', 'backend: forced qmimux');
eq(netlink.select_backend(fx, 'wwan0', 'none', true), 'none', 'backend: forced none');
eq(netlink.select_backend(fx, 'wwan0', 'auto', false), 'none', 'backend: no mux wanted');

fx = fakefx.create({ present: { '/sys/class/net/wwan0/qmi/add_mux': true } });
eq(netlink.select_backend(fx, 'wwan0', 'auto', true), 'qmimux', 'backend: qmimux fallback');
eq(netlink.select_backend(fx, 'wwan0', 'rmnet', true), null, 'backend: forced rmnet unavailable');

fx = fakefx.create();
eq(netlink.select_backend(fx, 'wwan0', 'auto', true), null, 'backend: nothing available');

// --- rmnet setup sequence ----------------------------------------------------

fx = fakefx.create({ present: caps_rmnet });

let res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet',
	mux: [ { id: 1, name: 'wwan0m1' }, { id: 2, name: 'wwan0m2', mtu: 1430 } ],
	dgram_size: 4096,
});

eq(res.ok, true, 'rmnet: ok');
eq(res.urb_size, 4100, 'rmnet: urb = dgram + qmap header');
eq(res.mux_devs, [ 'wwan0m1', 'wwan0m2' ], 'rmnet: mux devices');

ok(fx.action_index('link_set wwan0 down') == 0, 'rmnet: link down first');
let i_rawip = fx.action_index('write /sys/class/net/wwan0/qmi/raw_ip Y');
let i_pt = fx.action_index('write /sys/class/net/wwan0/qmi/pass_through Y');
ok(i_rawip > 0 && i_pt > i_rawip, 'rmnet: raw_ip before pass_through');
ok(fx.action_index('write /sys/class/net/wwan0/qmi/rx_urb_size 4100') > 0, 'rmnet: urb size written');

let i_mtu1504 = fx.action_index('mtu 1504');
let i_add1 = fx.action_index('link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x1');
let i_add2 = fx.action_index('link_add_rmnet wwan0m2 link wwan0 mux_id 2 flags 0x1');
let i_mtu_urb = fx.action_index('link_set wwan0 mtu 4100');
let i_up = fx.action_index('link_set wwan0 up');

ok(i_mtu1504 >= 0 && i_add1 > i_mtu1504 && i_add2 > i_add1, 'rmnet: 1504 before link add');
ok(i_mtu_urb > i_add2, 'rmnet: parent mtu urb after links');
ok(i_up > i_mtu_urb, 'rmnet: up last');
ok(fx.action_index('link_set wwan0m1 mtu 1500') > i_up, 'rmnet: child default mtu 1500');
ok(fx.action_index('link_set wwan0m2 mtu 1430') > i_up, 'rmnet: child configured mtu');

// pre-existing link tolerated (daemon restart)
fx = fakefx.create({
	present: { ...caps_rmnet, '/sys/class/net/wwan0m1': true },
	rc: { 'link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x1': 2 },
});
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'rmnet', mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096 });
eq(res.mux_devs, [ 'wwan0m1' ], 'rmnet: existing link tolerated');

// rmnet with negotiated MAPv5: checksum offload flags on the links
fx = fakefx.create({ present: caps_rmnet });
res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet', v5: true,
	mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096,
});
eq(res.ok, true, 'v5: ok');
ok(fx.action_index('link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x31') >= 0,
	'v5: deagg + cksum v5 flags');

// --- qmimux setup sequence ---------------------------------------------------

fx = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/add_mux': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
} });

res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'qmimux',
	mux: [ { id: 3, name: 'wwan0m3' } ], dgram_size: 16384,
});

eq(res.ok, true, 'qmimux: ok');
eq(res.urb_size, 16388, 'qmimux: urb size');
eq(res.mux_devs, [ 'wwan0m3' ], 'qmimux: mux device');
ok(fx.action_index('write /sys/class/net/wwan0/qmi/raw_ip Y') > 0, 'qmimux: raw_ip set');
ok(fx.action_index('write /sys/class/net/wwan0/qmi/add_mux 3') > 0, 'qmimux: add_mux written');
ok(fx.action_index('link_set qmimux0 name wwan0m3') > 0, 'qmimux: renamed');

// urb size attribute missing (kernel 6.12): skipped with a clear log line
fx = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/add_mux': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
} });
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'qmimux', mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096 });
eq(res.ok, true, 'nourb: setup still succeeds');
ok(fx.action_index('log info no rx_urb_size attribute, parent MTU 4100 covers') >= 0,
	'nourb: mainline fallback explained in log');

// essential attribute missing: setup fails with clear error
fx = fakefx.create();
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'none', dgram_size: 4096 });
eq(res.ok, false, 'noattr: raw_ip missing is fatal');
eq(res.error, 'raw_ip unavailable', 'noattr: error names the attribute');

// --- plain raw-ip ------------------------------------------------------------

fx = fakefx.create({ present: { '/sys/class/net/wwan0/qmi/raw_ip': true } });

res = netlink.setup(fx, { netdev: 'wwan0', backend: 'none', dgram_size: 4096, mtu: 1430 });

eq(res.ok, true, 'plain: ok');
eq(res.mux_devs, [], 'plain: no mux devices');
eq(length(fx.matching('rx_urb_size')), 0, 'plain: no urb write');
ok(fx.action_index('write /sys/class/net/wwan0/qmi/raw_ip Y') > 0, 'plain: raw_ip set');
ok(fx.action_index('link_set wwan0 mtu 1430') > 0, 'plain: configured mtu');
ok(fx.action_index('link_set wwan0 up') > 0, 'plain: up');

// --- cdc_mbim session datapath ----------------------------------------------

fx = fakefx.create();

res = netlink.setup_mbim(fx, {
	netdev: 'wwan0',
	mux: [ { id: 1, name: 'wwan0m1', mtu: 1500 }, { id: 2, name: 'wwan0m2' } ],
});

eq(res.ok, true, 'mbim: ok');
eq(res.mux_devs, [ 'wwan0m1', 'wwan0m2' ], 'mbim: vlan children named after mux_link');
ok(fx.action_index('link_add_vlan wwan0m1 link wwan0 id 1') >= 0, 'mbim: session 1 vlan');
ok(fx.action_index('link_add_vlan wwan0m2 link wwan0 id 2') >= 0, 'mbim: session 2 vlan');
ok(fx.action_index('link_set wwan0 up') >= 0, 'mbim: parent up');
ok(fx.action_index('link_set wwan0m1 up') >= 0, 'mbim: child up');

// session 0 rides the parent netdev — no sub-device
fx = fakefx.create();
res = netlink.setup_mbim(fx, { netdev: 'wwan0', mux: [ { id: 0, name: null } ] });
eq(res.mux_devs, [], 'mbim: session 0 has no vlan child');

// --- VRF compatibility invariant --------------------------------------------
// The datapath layer must only ever touch the link layer (mux creation, MTU,
// carrier, rename, up/down) and sysctl/qmi sysfs — never IP addresses or
// routes. Addressing and routing are netifd's job so they land in the
// interface's VRF / routing table (ip4table/ip6table). A direct 'ip route',
// 'ip addr' or 'ip rule' here would bypass that and silently break VRF
// setups. Assert a full mux bring-up records no such action.
fx = fakefx.create({ present: caps_rmnet });
netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet',
	mux: [ { id: 1, name: 'wwan0m1' }, { id: 2, name: 'wwan0m2' } ], dgram_size: 4096,
});
let forbidden = filter(fx.actions, (a) =>
	match(a, /(^|[ \/])(ip6?[ ]+(route|addr|address|rule|neigh)|(route|addr|rule)_(add|del))/) != null);
eq(length(forbidden), 0, 'vrf: datapath performs no direct addressing/routing');

done('test_datapath');
