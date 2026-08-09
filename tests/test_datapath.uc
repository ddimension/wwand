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

// item 7 (vendor link_state per-mux gate) + item 3 (uplink QMAP aggregation)
fx = fakefx.create({ present: { ...caps_rmnet, '/sys/class/net/wwan0/link_state': true } });
res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet', v5: true,
	mux: [ { id: 1, name: 'wwan0m1' }, { id: 2, name: 'wwan0m2' } ], dgram_size: 4096,
	ul_agg: { count: 11, size: 8192 },
});
eq(res.ok, true, 'agg: ok');
ok(fx.action_index('write /sys/class/net/wwan0/link_state 1') >= 0, 'agg: link_state enables mux 1');
ok(fx.action_index('write /sys/class/net/wwan0/link_state 2') >= 0, 'agg: link_state enables mux 2');
ok(fx.action_index('rmnet_tx_aggr wwan0m1 bytes 8192 frames 11 usecs 800') >= 0,
	'agg: uplink aggregation configured from negotiated maxima');

// no link_state node + aggregation count<=1 -> neither poke happens
fx = fakefx.create({ present: caps_rmnet });
netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet', v5: true,
	mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096,
	ul_agg: { count: 1, size: 8192 },
});
eq(length(filter(fx.actions, (a) => match(a, /link_state|rmnet_tx_aggr/) != null)), 0,
	'agg: no link_state / no aggregation when unsupported or count<=1');

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

// --- ep_iface_number / ep_type_number (sysfs readlink derivation) -------------
// The WDA/WDS endpoint TLVs must carry the modem's real USB interface number
// and bus type; a wrong value silently breaks QMAP. Driven via the fx seam.
let eplinks = {};
let epfx = { readlink: (p) => eplinks[p] ?? null };

// plain netdev: /device -> ...usb3/3-1/3-1:1.4 -> iface 4, HSUSB
eplinks = { '/sys/class/net/wwan0/device':
	'../../../devices/platform/soc/8af8800.usb/usb3/3-1/3-1:1.4' };
eq(netlink.ep_iface_number('wwan0', epfx), 4, 'ep: usb interface number from :1.4');
eq(netlink.ep_type_number('wwan0', epfx), 2, 'ep: /usbN/ path -> HSUSB (2)');

// the SHORT relative symlink form the kernel actually emits for a usbnet device
// (fs.readlink is not -f): "../../../3-1:1.4" — no /usbN component at all, so the
// iface number must come from the bus-port token, not a path match (HW-seen on
// the RG650E: a /usbN guard here broke the mux with endpoint_unknown)
eplinks = { '/sys/class/net/wwan0/device': '../../../3-1:1.4' };
eq(netlink.ep_iface_number('wwan0', epfx), 4, 'ep: iface from the bare relative symlink (../../../3-1:1.4)');
eplinks = { '/sys/class/net/wwan0/device': '../../../3-1.2:1.0' };
eq(netlink.ep_iface_number('wwan0', epfx), 0, 'ep: iface from a hub-port relative symlink (3-1.2:1.0)');

// vlan/mux child: no /device, falls back to lower_0/device
eplinks = { '/sys/class/net/wwan0m1/lower_0/device':
	'../../../devices/platform/soc/8af8800.usb/usb3/3-1/3-1:1.2' };
eq(netlink.ep_iface_number('wwan0m1', epfx), 2, 'ep: lower_0 fallback for a mux child');
eq(netlink.ep_type_number('wwan0m1', epfx), 2, 'ep: lower_0 bus type');

// PCIe/MHI modem: PCI BDF, no usb component -> PCIE (3), no iface number
eplinks = { '/sys/class/net/mhi0/device':
	'../../../devices/pci0001:00/0001:00:00.0/0001:01:00.0' };
eq(netlink.ep_iface_number('mhi0', epfx), null, 'ep: PCIe device has no usb iface number');
eq(netlink.ep_type_number('mhi0', epfx), 3, 'ep: PCI BDF -> PCIE (3)');

// xHCI-on-PCI: the sysfs path contains BOTH a PCI BDF (the xHCI parent) and a
// /usbN component — usb must win (the regression the code comment warns about)
eplinks = { '/sys/class/net/wwan1/device':
	'../../../devices/pci0000:00/0000:00:14.0/usb3/3-1/3-1:1.3' };
eq(netlink.ep_type_number('wwan1', epfx), 2, 'ep: xHCI-on-PCI still classifies as HSUSB');

// nothing resolvable
eplinks = {};
eq(netlink.ep_iface_number('nope', epfx), null, 'ep: missing links -> null');
eq(netlink.ep_type_number('nope', epfx), null, 'ep: missing links -> null type');

// --- datapath_stats: parent-vs-children aggregation ratio --------------------
let stat = {};
let statfx = { read: (p) => stat[p] ?? null };
let cnt = (dev, rxp, txp, rxb, txb) => {
	stat[sprintf('/sys/class/net/%s/statistics/rx_packets', dev)] = '' + rxp;
	stat[sprintf('/sys/class/net/%s/statistics/tx_packets', dev)] = '' + txp;
	stat[sprintf('/sys/class/net/%s/statistics/rx_bytes', dev)] = '' + rxb;
	stat[sprintf('/sys/class/net/%s/statistics/tx_bytes', dev)] = '' + txb;
};
// parent RX 100 QMAP frames carrying 250 demuxed packets across 2 children;
// TX 20 QMAP frames aggregating 40 host packets
cnt('wwan0', 100, 20, 500000, 20000);
cnt('wwan0m1', 150, 30, 300000, 15000);
cnt('wwan0m2', 100, 10, 200000, 5000);
let ds = netlink.datapath_stats(statfx, 'wwan0', [ 'wwan0m1', 'wwan0m2' ]);
eq(ds.parent.rx_packets, 100, 'stats: parent rx_packets');
eq(ds.rx_aggregation, 2.5, 'stats: rx aggregation = 250 demuxed / 100 frames');
eq(ds.tx_aggregation, 2.0, 'stats: tx aggregation = 40 host pkts / 20 frames');
eq(ds.children['wwan0m1'].rx_bytes, 300000, 'stats: child byte counter');

// unreadable counters -> null ratio, no throw
stat = {};
let ds2 = netlink.datapath_stats(statfx, 'wwanX', [ 'wwanXm1' ]);
eq(ds2.rx_aggregation, null, 'stats: missing counters -> null aggregation');
eq(ds2.parent.rx_packets, null, 'stats: missing parent counter -> null');

// --- cdc_ncm_params: NTB aggregation params for MBIM/NCM datapaths -----------
let ntbfx = { read: (p) => {
	let m = match(p, /\/cdc_ncm\/(.+)$/);
	if (!m) return null;
	return ({ rx_max: '16384', tx_max: '16384', wNtbOutMaxDatagrams: '16',
	          tx_timer_usecs: '400', min_tx_pkt: '13312' })[m[1]];
} };
let ntb = netlink.cdc_ncm_params(ntbfx, 'wwand0');
eq(ntb.rx_max, 16384, 'ntb: rx_max (downlink NTB buffer)');
eq(ntb.tx_max, 16384, 'ntb: tx_max');
eq(ntb.tx_max_datagrams, 16, 'ntb: wNtbOutMaxDatagrams -> tx_max_datagrams');
eq(ntb.tx_timer_usecs, 400, 'ntb: coalescing timer');
// a QMI qmi_wwan parent has no cdc_ncm dir -> null (not NTB-framed)
eq(netlink.cdc_ncm_params({ read: () => null }, 'wwan0'), null,
	'ntb: non-cdc_ncm device -> null');

done('test_datapath');
