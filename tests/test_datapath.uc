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

// minimal caps for the no-channel plugin check further down (the full
// vendor_caps live with the plugin suite at the end of the file)
const vendor_caps_early = { '/sys/class/net/wwan0/qmi/raw_ip': true };

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
eq(netlink.select_backend(fx, 'wwan0', 'raw_ip', true), 'raw_ip', 'backend: forced raw_ip');
eq(netlink.select_backend(fx, 'wwan0', 'ethernet', true), 'ethernet', 'backend: forced ethernet (802.3, qmi)');
eq(netlink.select_backend(fx, 'wwan0', 'ethernet', true, null, { proto: 'mbim' }), null,
	'backend: ethernet is qmi-only — an mbim modem is refused');

// `want_mux` does NOT skip the probes any more: a box with no channels still
// gets identified, which is the only way an accelerated add-on can claim
// hardware where nobody ever writes `option mux`. What want_mux decides is what
// an UNCLAIMED box is — an error when a mux was required, raw_ip otherwise.
eq(netlink.select_backend(fx, 'wwan0', 'auto', false), 'rmnet',
	'backend: the probes run even with no channels configured');
eq(netlink.select_backend(fakefx.create(), 'wwan0', 'auto', false), 'raw_ip',
	'backend: unclaimed and no mux required -> raw_ip, not an error');
eq(netlink.select_backend(fakefx.create(), 'wwan0', 'auto', true), null,
	'backend: unclaimed but a mux WAS required -> the caller must report it');

// the no-mux datapath was called 'none' until 1.6 and is written 'raw-ip' in
// prose. Every config carrying either spelling must keep selecting it — the
// alternative is muxing silently switching back ON on an upgrade.
eq(netlink.select_backend(fx, 'wwan0', 'none', true), 'raw_ip',
	'backend: legacy `none` still selects raw_ip');
eq(netlink.select_backend(fx, 'wwan0', 'raw-ip', true), 'raw_ip',
	'backend: hyphenated raw-ip selects raw_ip');
eq(netlink.canon_mux('none'), 'raw_ip', 'canon: none -> raw_ip');
eq(netlink.canon_mux('raw-ip'), 'raw_ip', 'canon: raw-ip -> raw_ip');
eq(netlink.canon_mux('rmnet_nss'), 'rmnet_nss', 'canon: a plugin name is untouched');
eq(netlink.canon_mux(null), null, 'canon: unset stays unset');

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

// ...and the adopted link must be brought to THIS run's QMAP format. The flags
// live on the parent port and the kernel keeps the previous run's, so a v1 -> v5
// change across a restart would otherwise decode the wrong header: tx climbs,
// rx stays flat, nothing is logged. (HW-hit on the Chateau after the QMAPv5
// constant fix — only `ip link del` cleared it.)
ok(fx.action_index('rmnet_flags_set wwan0m1 mux_id 1 flags 0x1 mask 0x3d') >= 0,
	'rmnet: adopted link gets this run\'s flags re-asserted');

fx = fakefx.create({
	present: { ...caps_rmnet, '/sys/class/net/wwan0m1': true },
	rc: { 'link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x31': 2 },
});
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'rmnet', v5: true,
	mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096 });
eq(res.mux_devs, [ 'wwan0m1' ], 'adopt v5: link adopted');
ok(fx.action_index('rmnet_flags_set wwan0m1 mux_id 1 flags 0x31 mask 0x3d') >= 0,
	'adopt v5: deagg + cksum v5 re-asserted on the surviving child');

// A DOWNGRADE is the case a too-narrow mask gets wrong. The kernel does not
// assign the flags, it applies them masked, so correcting v5 -> v1 with
// mask == flags would leave the v5 checksum bits standing and the port would go
// on misparsing — the very failure being fixed, just quieter. The fake models
// the kernel arithmetic, so this asserts the resulting FORMAT, not the request.
fx = fakefx.create({
	present: { ...caps_rmnet, '/sys/class/net/wwan0m1': true },
	rmnet_data_format: 0x31,   // left behind by a previous v5 run
	rc: { 'link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x1': 2 },
});
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'rmnet',
	mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096 });
eq(res.mux_devs, [ 'wwan0m1' ], 'downgrade: link adopted');
eq(fx.rmnet_data_format, 0x1, 'downgrade: v5 checksum bits cleared, not merely v1 added');

// ...and the reverse, to pin that the mask does not clear what it must set
fx = fakefx.create({
	present: { ...caps_rmnet, '/sys/class/net/wwan0m1': true },
	rmnet_data_format: 0x1,
	rc: { 'link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x31': 2 },
});
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'rmnet', v5: true,
	mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096 });
eq(fx.rmnet_data_format, 0x31, 'upgrade: v1 -> v5 format applied');

// a kernel that refuses the changelink must not lose the adoption — the link is
// still the one carrying traffic; the operator gets a warning naming the fix
fx = fakefx.create({
	present: { ...caps_rmnet, '/sys/class/net/wwan0m1': true },
	rc: { 'rmnet_flags_set wwan0m1 mux_id 1 flags 0x31 mask 0x3d': 2 },
});
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'rmnet', v5: true,
	mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096 });
eq(res.mux_devs, [ 'wwan0m1' ], 'adopt v5: refused changelink still yields a usable channel');
ok(fx.action_index('link_del wwan0m1') >= 0,
	'adopt v5: an uncorrectable link is deleted, not reported as working');
// the create is ATTEMPTED first (fails EEXIST), then the delete, then the real
// create — so it is the second occurrence that proves the recreate happened
eq(length(filter(fx.actions, (a) => a == 'link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x31')), 2,
	'adopt v5: ...and recreated through the create path');

// an older wwand_io.so without the helper must not silently skip the correction
// either — same recreate, plus a warning naming the reason
fx = fakefx.create({
	present: { ...caps_rmnet, '/sys/class/net/wwan0m1': true },
});
delete fx.rmnet_flags_set;
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'rmnet', v5: true,
	mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096 });
eq(res.mux_devs, [ 'wwan0m1' ], 'no helper: channel still usable');
ok(fx.action_index('link_del wwan0m1') >= 0,
	'no helper: link recreated rather than adopted with an unknown format');
ok(length(filter(fx.actions, (a) => match(a, /^log warn .*no rmnet_flags_set/))) > 0,
	'no helper: the skew is reported');

// stale-renamed parent occupies the mux child name (a config update bounced the
// datapath through a channel-less snapshot, which renamed the raw netdev to the
// stable L3 name): the parent must move back to a raw kernel name and the child
// is created on the moved parent — never silently adopted onto the parent
// itself (HW-hit on the Chateau: link up, QMAP-muxed traffic on the raw parent,
// no data).
fx = fakefx.create({ present: {
	'/sys/class/net/wwand0/qmi/pass_through': true,
	'/sys/class/net/wwand0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
	'/sys/class/net/wwand0/qmi/add_mux': true,
	'/sys/class/net/wwand0': true,
} });
res = netlink.setup(fx, { netdev: 'wwand0', backend: 'rmnet',
	mux: [ { id: 1, name: 'wwand0' } ], dgram_size: 4096 });
eq(res.ok, true, 'collision: ok');
eq(res.parent, 'wwan0', 'collision: parent moved to the free raw name');
ok(fx.action_index('link_set wwand0 name wwan0') >= 0, 'collision: parent rename emitted');
ok(fx.action_index('link_add_rmnet wwand0 link wwan0 mux_id 1 flags 0x1') >= 0,
	'collision: child created on the moved parent');
eq(res.mux_devs, [ 'wwand0' ], 'collision: child owns the stable L3 name');

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

// A rename that fails must NOT be reported as a working channel. The kernel's
// qmimux0 stays behind under its own name while MTU, link-up and netifd all
// address the name we wanted, so a setup reported ok here hands the control
// backend a device that does not exist: a modem that looks connected with no
// usable interface. Unclaimed is the honest outcome, and setup must fail.
fx = fakefx.create({
	present: {
		'/sys/class/net/wwan0/qmi/add_mux': true,
		'/sys/class/net/wwan0/qmi/raw_ip': true,
	},
	rc: { 'link_set qmimux0 name wwan0m3': true },
});

res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'qmimux',
	mux: [ { id: 3, name: 'wwan0m3' } ], dgram_size: 16384,
});

eq(res.ok, false, 'qmimux: a failed rename fails the setup');
ok(index(res.error ?? '', 'wwan0m3') >= 0, 'qmimux: ...naming the channel that was not created');
eq(res.mux_devs, [ ], 'qmimux: ...and no phantom child is reported');

// The same completeness rule for rmnet, whose links() already skips a channel
// it could not build ("left unclaimed rather than reported as working") —
// skipping was only half of it until setup acted on the shortfall.
fx = fakefx.create({ present: caps_rmnet,
	rc: { 'link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x1': true } });

res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet',
	mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096,
});

eq(res.ok, false, 'rmnet: a channel that could not be created fails the setup');
ok(index(res.error ?? '', 'wwan0m1') >= 0, 'rmnet: ...naming the channel');

// urb size attribute missing (mainline usbnet): silently skipped, parent MTU
// carries the urb size — setup still succeeds and writes no urb attribute
fx = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/add_mux': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
} });
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'qmimux', mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096 });
eq(res.ok, true, 'nourb: setup still succeeds');
eq(length(fx.matching('rx_urb_size')), 0, 'nourb: no urb write when the attribute is absent');
ok(fx.action_index('link_set wwan0 mtu 4100') >= 0,
	'nourb: parent MTU carries the urb size (4100)');

// essential attribute missing from a group that DOES exist: setup fails clearly
fx = fakefx.create({ present: { '/sys/class/net/wwan0/qmi': true } });
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'none', dgram_size: 4096 });
eq(res.ok, false, 'noattr: raw_ip missing is fatal');
eq(netlink.setup(fakefx.create({ present: { '/sys/class/net/wwan0/qmi': true } }),
	{ netdev: 'wwan0', backend: 'raw_ip', dgram_size: 4096 }).error, 'raw_ip unavailable',
	'noattr: the legacy `none` and canonical `raw_ip` spellings behave identically');
eq(res.error, 'raw_ip unavailable', 'noattr: error names the attribute');

// no `qmi` group at all: a raw-IP-by-construction driver (mhi_net on PCIe/MHI).
// There is no knob to set, so the datapath must come up rather than fail.
fx = fakefx.create();
res = netlink.setup(fx, { netdev: 'mhi_hwip0', backend: 'raw_ip', dgram_size: 4096 });
eq(res.ok, true, 'mhi: no qmi sysfs group is not an error');
eq(length(fx.matching('raw_ip')), 0, 'mhi: nothing written into a group that does not exist');
ok(fx.action_index('link_set mhi_hwip0 up') > 0, 'mhi: datapath brought up');

// ...and rmnet may still stack on it: pass_through is qmi_wwan-specific
fx = fakefx.create({ present: { '/sys/module/rmnet': true } });
eq(netlink.select_backend(fx, 'mhi_hwip0', 'auto', true), 'rmnet',
	'mhi: rmnet selected without a pass_through knob');
fx = fakefx.create({ present: { '/sys/class/net/wwan0/qmi/add_mux': true } });
eq(netlink.select_backend(fx, 'wwan0', 'rmnet', true), null,
	'qmi_wwan without pass_through still cannot do rmnet');

// --- stale mux children ------------------------------------------------------
//
// Nothing used to remove mux children when the configuration stopped asking for
// them. On a BPi-R4 that left `wwand0@mhi_hwip0` and `wwand1@mhi_hwip0`
// attached after the muxed interfaces were deleted: the parent stayed pinned at
// the rmnet MTU (link_set mtu 1500 -> EPERM, a device with rmnet children
// refuses it) and the name the next non-mux setup wanted for its L3 device was
// already taken by an orphan.
//
// Identified by iflink, not by devtype: a real rmnet child's uevent carries
// only INTERFACE and IFINDEX (checked on hardware), so a devtype filter would
// pass here against an invented fixture and match nothing in the field.

fx = fakefx.create({
	present: {
		'/sys/class/net/wwan0': true,
		'/sys/class/net/wwan0m1': true,
		'/sys/class/net/wwan0m2': true,
		'/sys/class/net/eth0.7': true,
	},
	files: {
		'/sys/class/net/wwan0/ifindex':   '10
',
		'/sys/class/net/wwan0m1/ifindex': '13
',
		'/sys/class/net/wwan0m1/iflink':  '10
',
		'/sys/class/net/wwan0m2/ifindex': '14
',
		'/sys/class/net/wwan0m2/iflink':  '10
',
		// somebody else's vlan on the same parent — not ours to remove
		'/sys/class/net/eth0.7/ifindex':  '15
',
		'/sys/class/net/eth0.7/iflink':   '3
',
		'/sys/class/net/eth0.7/uevent':   "DEVTYPE=vlan
",
	},
});

res = netlink.setup(fx, { netdev: 'wwan0', backend: 'raw_ip', dgram_size: 4096 });
eq(res.ok, true, 'prune: plain raw-ip setup succeeds');
ok(fx.action_index('link_del wwan0m1') >= 0, 'prune: a child the config dropped is removed');
ok(fx.action_index('link_del wwan0m2') >= 0, 'prune: the second one too');
eq(fx.action_index('link_del eth0.7'), -1, 'prune: a link stacked on another parent is left alone');

// a child the config still wants survives
fx = fakefx.create({
	present: {
		'/sys/class/net/wwan0': true,
		'/sys/class/net/wwan0m1': true,
		'/sys/class/net/wwan0m2': true,
		'/sys/class/net/wwan0/qmi/raw_ip': true,
		'/sys/module/rmnet': true,
	},
	files: {
		'/sys/class/net/wwan0/ifindex':   '10
',
		'/sys/class/net/wwan0m1/ifindex': '13
',
		'/sys/class/net/wwan0m1/iflink':  '10
',
		'/sys/class/net/wwan0m2/ifindex': '14
',
		'/sys/class/net/wwan0m2/iflink':  '10
',
	},
});

res = netlink.setup(fx, { netdev: 'wwan0', backend: 'rmnet',
	mux: [ { id: 1 } ], dgram_size: 4096 });
eq(fx.action_index('link_del wwan0m1'), -1, 'prune: the child still configured is kept');
ok(fx.action_index('link_del wwan0m2') >= 0, 'prune: the one dropped from the config goes');

// --- MHI runtime PM pin ------------------------------------------------------
//
// The endpoint must never runtime-suspend: on the RM520N/BPi-R4 the resume
// kills it beyond any software reset. Pin the endpoint AND its bridge.

let PCI_EP = '/sys/devices/platform/soc/11280000.pcie/pci0003:00/0003:00:00.0/0003:01:00.0';

fx = fakefx.create({ present: {
	[PCI_EP + '/power/control']: true,
	['/sys/devices/platform/soc/11280000.pcie/pci0003:00/0003:00:00.0/power/control']: true,
} });
fx.realpath = (p) => (p == '/sys/class/wwan/wwan0qmi0/device')
	? PCI_EP + '/mhi0/wwan/wwan0' : null;

eq(netlink.pin_runtime_pm(fx, '/dev/wwan0qmi0'), [ '0003:01:00.0', '0003:00:00.0' ],
	'mhi: endpoint and bridge both pinned');
ok(fx.action_index('write ' + PCI_EP + '/power/control on') >= 0,
	'mhi: the endpoint knob is actually written');

// a USB modem has no PCI ancestor — silent no-op, no writes at all
fx = fakefx.create();
eq(netlink.pin_runtime_pm(fx, '/dev/cdc-wdm0'), null, 'usb: nothing to pin');
eq(length(fx.matching('power/control')), 0, 'usb: no runtime-pm writes');

// wwan port whose parent chain carries no PCI node (a USB modem behind the
// kernel wwan framework) — the climb must simply come up empty
fx = fakefx.create();
fx.realpath = (p) => '/sys/devices/platform/soc/usb@11200000/wwan/wwan0';
eq(netlink.pin_runtime_pm(fx, '/dev/wwan0qmi0'), null, 'wwan-over-usb: nothing to pin');

// A backend selected on a box with NO channels must not apply its framing:
// rmnet's pass_through hands the raw QMAP frames to a child that does not
// exist — link up, no traffic. This is what makes probing an unmuxed box safe,
// so it is pinned rather than assumed.
fx = fakefx.create({ present: caps_rmnet });
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'rmnet', mux: [], dgram_size: 4096 });
eq(res.ok, true, 'nochan: setup succeeds');
eq(res.backend, 'raw_ip', 'nochan: the effective backend is raw_ip, and says so');
eq(res.urb_size, null, 'nochan: no aggregation buffer');
eq(length(fx.matching('pass_through')), 0, 'nochan: rmnet pre() never runs');
eq(length(fx.matching('rx_urb_size')), 0, 'nochan: no urb write');
eq(fx.action_index('link_set wwan0 mtu 4100'), -1, 'nochan: no aggregation MTU on the parent');
ok(fx.action_index('write /sys/class/net/wwan0/qmi/raw_ip Y') >= 0,
	'nochan: ...but raw_ip framing is still programmed, as for any unmuxed modem');
ok(fx.action_index('link_set wwan0 mtu 1500') >= 0, 'nochan: plain child MTU on the parent');
ok(length(filter(fx.actions, (a) => match(a, /no mux channels configured/) != null)) == 1,
	'nochan: the drop to raw_ip is logged, not silent');

// the same for an add-on, which is the case that made this necessary
fx = fakefx.create({ present: vendor_caps_early });
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'vendorx', mux: [],
	plugins: { vendorx: { links: () => [ 'never' ] } }, dgram_size: 4096 });
eq(res.backend, 'raw_ip', 'nochan: a plugin with no channels is raw_ip too');
eq(res.mux_devs, [], 'nochan: its links() is never called');

// ...but its OWN prune() still does: a datapath whose children the kernel owns
// (a vendor driver creating them at module load) keeps them by overriding
// prune, and dropping to raw_ip before that would reach the default prune and
// delete exactly those — unrecoverable without a module reload.
let pruned_early = [];
fx = fakefx.create({ present: vendor_caps_early });
netlink.setup(fx, { netdev: 'wwan0', backend: 'vendorx', mux: [], dgram_size: 4096,
	plugins: { vendorx: { links: () => [], prune: (f, nd, w) => push(pruned_early, nd) } } });
eq(pruned_early, [ 'wwan0' ], 'nochan: the backend prune()s before the fallback, not the default one');

// a config that names only channels producing no child (MBIM session 0) is the
// same case — the count that decides is children, not mux entries
fx = fakefx.create();
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'vlan', mux: [ { id: 0, name: null } ] });
eq(res.backend, 'raw_ip', 'nochan: session-0-only reports raw_ip, not a vlan with no children');

// --- plain raw-ip ------------------------------------------------------------

fx = fakefx.create({ present: { '/sys/class/net/wwan0/qmi/raw_ip': true } });

res = netlink.setup(fx, { netdev: 'wwan0', backend: 'raw_ip', dgram_size: 4096, mtu: 1430 });

eq(res.ok, true, 'plain: ok');
eq(res.mux_devs, [], 'plain: no mux devices');
eq(res.urb_size, null, 'plain: urb_size null for a non-muxed raw-ip datapath');
eq(length(fx.matching('rx_urb_size')), 0, 'plain: no urb write');
ok(fx.action_index('write /sys/class/net/wwan0/qmi/raw_ip Y') > 0, 'plain: raw_ip set');
ok(fx.action_index('link_set wwan0 mtu 1430') > 0, 'plain: configured mtu');
ok(fx.action_index('link_set wwan0 up') > 0, 'plain: up');

// invalid configured MTU is logged (not silently swallowed) and falls to 1500
fx = fakefx.create({ present: { '/sys/class/net/wwan0/qmi/raw_ip': true } });
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'raw_ip', dgram_size: 4096, mtu: 400 });
eq(res.ok, true, 'badmtu: setup ok');
ok(fx.action_index('link_set wwan0 mtu 1500') > 0, 'badmtu: too-small mtu falls to 1500');
ok(fx.action_index('log warn wwan0: ignoring invalid MTU 400') >= 0, 'badmtu: substitution is logged');

// an unset MTU uses the default WITHOUT a warning (no noise on the common path)
fx = fakefx.create({ present: { '/sys/class/net/wwan0/qmi/raw_ip': true } });
netlink.setup(fx, { netdev: 'wwan0', backend: 'raw_ip', dgram_size: 4096 });
eq(length(fx.matching('ignoring invalid MTU')), 0, 'badmtu: no warning when mtu is unset');

// --- ethernet (802.3, kernel framing kept) -----------------------------------
//
// The pseudo-mode for old QMI stacks that cannot negotiate the link-layer
// format (no WDA service): the parent keeps the kernel's 802.3 framing
// (raw_ip re-asserted to N — idempotent). NO NOARP: the 802.3 function is an
// L2 bridge into the GGSN segment and the gateway resolves via (proxy-)ARP
// from the network side (HW-verified on the Huawei E1820, 2026-08-31).

fx = fakefx.create({ present: { '/sys/class/net/wwan0/qmi/raw_ip': true } });

res = netlink.setup(fx, { netdev: 'wwan0', backend: 'ethernet', dgram_size: 4096, mtu: 1430 });

eq(res.ok, true, 'eth: ok');
eq(res.backend, 'ethernet', 'eth: setup reports the backend it ran');
eq(res.mux_devs, [], 'eth: no mux devices');
eq(res.urb_size, null, 'eth: urb_size null — nothing aggregates');
eq(length(fx.matching('rx_urb_size')), 0, 'eth: no urb write');
ok(fx.action_index('write /sys/class/net/wwan0/qmi/raw_ip N') > 0, 'eth: raw_ip re-asserted to N (802.3)');
eq(fx.action_index('write /sys/class/net/wwan0/qmi/raw_ip Y'), -1, 'eth: never raw-ip');
ok(fx.action_index('link_set wwan0 mtu 1430') > 0, 'eth: configured mtu');
eq(fx.action_index('link_set wwan0 noarp'), -1, 'eth: NOARP NOT set (ARP stays on, L2 bridge)');
ok(fx.action_index('link_set wwan0 up') > 0, 'eth: up');

// already 802.3 (the driver default): the N write is skipped as idempotent
fx = fakefx.create({
	present: { '/sys/class/net/wwan0/qmi/raw_ip': true },
	files: { '/sys/class/net/wwan0/qmi/raw_ip': 'N\n' },
});

res = netlink.setup(fx, { netdev: 'wwan0', backend: 'ethernet', dgram_size: 4096 });

eq(res.ok, true, 'eth-idem: ok');
eq(length(fx.matching('raw_ip')), 0, 'eth-idem: no write when already N');

// a mux link on an ethernet datapath is impossible config — the parent is the
// datapath, and there is nothing to bind a child to
fx = fakefx.create({ present: { '/sys/class/net/wwan0/qmi/raw_ip': true } });

res = netlink.setup(fx, { netdev: 'wwan0', backend: 'ethernet', dgram_size: 4096,
                          mux: [ { id: 1, name: 'wwan0m1' } ] });

eq(res.ok, true, 'eth-mux: setup ok (caller guards the config)');
eq(res.mux_devs, [], 'eth-mux: no children built on an unmuxed datapath');

// --- cdc_mbim session datapath (the built-in `vlan` backend) ----------------
//
// It goes through the SAME netlink.setup() as the QMI backends — it used to be
// a setup_mbim() of its own and the copy drifted (the stale-child prune was
// fixed in setup() and missed there). What follows therefore also pins the
// parts of that shared path a VLAN mux must NOT get: no QMAP urb arithmetic,
// and no parent bounce.

fx = fakefx.create();

res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'vlan',
	mux: [ { id: 1, name: 'wwan0m1', mtu: 1500 }, { id: 2, name: 'wwan0m2' } ],
});

eq(res.ok, true, 'mbim: ok');
eq(res.backend, 'vlan', 'mbim: setup reports the backend it ran');
eq(res.urb_size, null, 'mbim: no QMAP urb size on a VLAN mux');
eq(length(fx.matching('rx_urb_size')), 0, 'mbim: no urb write');
// the parent carries a live session on a daemon restart; bouncing it to
// reprogram a link-layer format this backend does not touch would drop it
eq(fx.action_index('link_set wwan0 down'), -1, 'mbim: parent is never bounced');
eq(length(fx.matching('raw_ip')), 0, 'mbim: no qmi_wwan format write');
eq(res.mux_devs, [ 'wwan0m1', 'wwan0m2' ], 'mbim: vlan children named after mux_link');
eq(res.parent, 'wwan0', 'mbim: parent name reported');
ok(fx.action_index('link_add_vlan wwan0m1 link wwan0 id 1') >= 0, 'mbim: session 1 vlan');
ok(fx.action_index('link_add_vlan wwan0m2 link wwan0 id 2') >= 0, 'mbim: session 2 vlan');
ok(fx.action_index('link_set wwan0 mtu 1504') >= 0, 'mbim: parent mtu bumped to child+4 (VLAN tag headroom)');
ok(fx.action_index('link_set wwan0 up') >= 0, 'mbim: parent up');
ok(fx.action_index('link_set wwan0m1 up') >= 0, 'mbim: child up');

// session 0 rides the parent netdev — no sub-device
fx = fakefx.create();
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'vlan', mux: [ { id: 0, name: null } ] });
eq(res.mux_devs, [], 'mbim: session 0 has no vlan child');
eq(length(fx.matching('link_add_vlan')), 0, 'mbim: session 0 creates no link');

// ...and the shared prune must not delete a child on account of a session-0
// entry naming nothing: child_name() returning null means "no child", not "a
// child called null" that nothing in the wanted list can match.
fx = fakefx.create({ present: { '/sys/class/net/wwan0.1': true },
	files: { '/sys/class/net/wwan0/ifindex': "3\n",
	         '/sys/class/net/wwan0.1/iflink': "3\n" } });
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'vlan',
	mux: [ { id: 0, name: null }, { id: 1, name: 'wwan0.1', mtu: 1500 } ] });
eq(fx.action_index('link_del wwan0.1'), -1, 'mbim: a wanted child survives a session-0 sibling');

// stale parent name: a mux child wants the parent's own name (parent still
// carries a stable wwandN name from a prior untagged session-0 config). The
// parent must be moved to a free raw name so the child can take it — like QMI
// (raw parent + wwandN child). Regression: without this the VLAN silently
// collapses onto the untagged parent and no traffic flows.
fx = fakefx.create({ present: { '/sys/class/net/wwand0': true } });
res = netlink.setup(fx, { netdev: 'wwand0', backend: 'vlan',
	mux: [ { id: 1, name: 'wwand0', mtu: 1500 } ] });
eq(res.parent, 'wwan0', 'mbim-stale: parent moved to a free raw name (wwan0)');
ok(fx.action_index('link_set wwand0 name wwan0') >= 0, 'mbim-stale: parent renamed off the child name');
ok(fx.action_index('link_add_vlan wwand0 link wwan0 id 1') >= 0, 'mbim-stale: vlan child wwand0 created on the raw parent');
eq(res.mux_devs, [ 'wwand0' ], 'mbim-stale: child keeps the stable name wwand0');

// default naming when a context named no link: VLAN children are <parent>.<id>,
// not the QMAP <parent>m<id> — netifd binds on that name.
fx = fakefx.create();
res = netlink.setup(fx, { netdev: 'wwan0', backend: 'vlan', mux: [ { id: 3 } ] });
eq(res.mux_devs, [ 'wwan0.3' ], 'mbim: default child name is <parent>.<session>');

// selection: 'auto' on an MBIM modem lands on vlan and never on a qmi_wwan mux,
// even on a box whose kernel offers both (the rmnet module is global).
fx = fakefx.create({ present: caps_rmnet });
eq(netlink.select_backend(fx, 'wwan0', 'auto', true, null, { proto: 'mbim' }), 'vlan',
	'mbim: auto selects vlan for an mbim modem');
eq(netlink.select_backend(fx, 'wwan0', 'auto', true, null, { proto: 'qmi' }), 'rmnet',
	'mbim: the same box still gets rmnet for a qmi modem');
eq(netlink.select_backend(fx, 'wwan0', 'auto', true, null, { proto: 'ncm' }), null,
	'mbim: a protocol with no mux gets no built-in');
eq(netlink.select_backend(fx, 'wwan0', 'raw_ip', true, null, { proto: 'mbim' }), 'raw_ip',
	'mbim: raw_ip switches the session mux off');

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

// a child younger than its parent (recreated on a QMAP renegotiation, a config
// change, a manual `ip link del`) makes the two lifetime counters cover
// different periods. The quotient then falls below 1, which no real aggregation
// can be — every parent frame carries at least one child packet — so it must be
// reported as absent, not as "0.00" (which the status page reads as "no
// aggregation"). Observed on the Chateau: child 409 packets, parent 66941.
stat = {};
cnt('wwan0', 66941, 56525, 4016924, 3079448);
cnt('wwan0m1', 409, 367, 25649, 26997);
let ds_young = netlink.datapath_stats(statfx, 'wwan0', [ 'wwan0m1' ]);
eq(ds_young.rx_aggregation, null, 'stats: sub-unity ratio suppressed (child younger than parent)');
eq(ds_young.tx_aggregation, null, 'stats: sub-unity tx ratio suppressed');
eq(ds_young.children['wwan0m1'].rx_packets, 409, 'stats: raw counters still reported');

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

// --- datapath plugins --------------------------------------------------------
//
// A third-party datapath is handed in as an object (never registered in a
// module-level table: a require()d plain script gets its OWN copies of the
// modules it imports, so registering would populate a different netlink
// instance than the daemon's — see the plugin comment in netlink.uc).

let calls = [];
let plug = {
	probe: (pfx, netdev) => pfx.exists(sprintf('/sys/class/net/%s/vendor_mux', netdev)),
	links: (pfx, ctx) => {
		push(calls, ctx);

		let out = [];

		for (let e in ctx.mux) {
			let child = e.name ?? sprintf('%sm%d', ctx.netdev, e.id);

			ctx.mux_mtus[child] = e.mtu;
			ctx.write_attr(sprintf('%s/vendor_add', ctx.sys), sprintf('%d', e.id), 'vendor add');
			ctx.link('vendor rename', sprintf('vendor%d', e.id), { rename: child });
			push(out, child);
		}

		return out;
	},
};

// the plugin's own sysfs node exists here; write_attr() skips absent ones (so a
// vendor knob missing on this kernel is a warning, not a failure)
const vendor_caps = { ...caps_rmnet,
	'/sys/class/net/wwan0/vendor_mux': true,
	'/sys/class/net/wwan0/qmi/vendor_add': true,
};

let pfx = fakefx.create({ present: vendor_caps });

// candidates are passed as a name -> impl map (the daemon builds it)
let plugmap = { vendorx: plug };

// named explicitly -> the plugin, after its own probe
eq(netlink.select_backend(pfx, 'wwan0', 'vendorx', true, plugmap), 'vendorx',
	'plugin: chosen when option mux names it');
eq(netlink.select_backend(pfx, 'wwan0', 'vendorx', true, null), null,
	'plugin: named but package missing -> null (caller reports it)');
eq(netlink.select_backend(pfx, 'wwan0', 'vendorx', true, { vendorx: { probe: () => true } }), null,
	'plugin: object without links() is not a datapath');

// a plugin whose probe says no is not silently replaced by a built-in
eq(netlink.select_backend(fakefx.create({ present: caps_rmnet }), 'wwan0', 'vendorx', true, plugmap),
	null, 'plugin: probe false -> null, never falls back to rmnet');

// --- auto: the probe decides -------------------------------------------------
//
// An installed plugin that recognises the box is preferred over the built-ins —
// that is how an accelerated datapath (rmnet_nss on ipq807x) takes over on a
// zero-config box, where nobody will ever write `option mux`.
eq(netlink.select_backend(pfx, 'wwan0', 'auto', true, plugmap), 'vendorx',
	'auto: a matching plugin beats rmnet');

// ... on hardware it does not fit, it changes nothing
eq(netlink.select_backend(fakefx.create({ present: caps_rmnet }), 'wwan0', 'auto', true, plugmap),
	'rmnet', 'auto: a plugin whose probe says no leaves rmnet alone');

// no probe = cannot tell = must be asked for by name
eq(netlink.select_backend(pfx, 'wwan0', 'auto', true, { blind: { links: () => [] } }), 'rmnet',
	'auto: a plugin without probe() never self-selects');
eq(netlink.select_backend(pfx, 'wwan0', 'blind', true, { blind: { links: () => [] } }), 'blind',
	'auto: ... but naming it still works');

// two claimants: deterministic by name, and loud about it
let twofx = fakefx.create({ present: vendor_caps });
let logs2 = [];
twofx.log = (lvl, msg) => push(logs2, sprintf('%s %s', lvl, msg));
eq(netlink.select_backend(twofx, 'wwan0', 'auto', true,
	{ zeta: plug, alpha: plug }), 'alpha', 'auto: several matches -> first by name');
ok(length(filter(logs2, (m) => match(m, /^warn .*plugins claim this device/))) == 1,
	'auto: a second claimant is warned about, not silently dropped');

// the generic parts of setup() must still run around links()
res = netlink.setup(pfx, {
	netdev: 'wwan0', backend: 'vendorx', plugins: plugmap,
	mux: [ { id: 1, name: 'wwand0' }, { id: 2, name: 'wwand1', mtu: 1430 } ],
	dgram_size: 4096,
});

eq(res.ok, true, 'plugin: setup ok');
eq(res.mux_devs, [ 'wwand0', 'wwand1' ], 'plugin: children reported');
eq(res.urb_size, 4100, 'plugin: urb still dgram + qmap header');
eq(length(calls), 1, 'plugin: links() called once');
eq(calls[0].netdev, 'wwan0', 'plugin ctx: parent');
eq(calls[0].sys, '/sys/class/net/wwan0/qmi', 'plugin ctx: sysfs dir');
eq(calls[0].urb_size, 4100, 'plugin ctx: urb size');
eq(length(calls[0].mux), 2, 'plugin ctx: mux entries');

ok(pfx.action_index('write /sys/class/net/wwan0/qmi/vendor_add 1') > 0,
	'plugin: its own sysfs write ran (ctx.write_attr)');
let i_purb = pfx.action_index('link_set wwan0 mtu 4100');
let i_pup = pfx.action_index('link_set wwan0 up');
ok(i_purb > pfx.action_index('write /sys/class/net/wwan0/qmi/vendor_add 2'),
	'plugin: shared parent mtu after links()');
ok(i_pup > i_purb, 'plugin: shared link up after that');
ok(pfx.action_index('link_set wwand1 mtu 1430') > i_pup,
	'plugin: shared child mtu from the ctx.mux_mtus it filled');
ok(pfx.action_index('write /sys/class/net/wwan0/qmi/rx_urb_size 4100') > 0,
	'plugin: shared urb-size write still happens');

// prune stays the shared one unless the plugin brings its own
let pruned = [];
let plug2 = { ...plug, prune: (a, nd, wanted) => push(pruned, [ nd, wanted ]) };

netlink.setup(fakefx.create({ present: vendor_caps }), {
	netdev: 'wwan0', backend: 'vendorx', plugins: { vendorx: plug2 },
	mux: [ { id: 1, name: 'wwand0' } ], dgram_size: 4096,
});

eq(pruned, [ [ 'wwan0', [ 'wwand0' ] ] ], 'plugin: own prune() used when provided');

// the pre() hook: the backend's own driver-format switch, before the urb/MTU
// work. rmnet's pass_through goes through it (the built-ins use the same
// contract as an add-on), and a plugin can fail the whole setup from there.
let prefx = fakefx.create({ present: vendor_caps });
res = netlink.setup(prefx, {
	netdev: 'wwan0', backend: 'vendorx', dgram_size: 4096,
	plugins: { vendorx: { ...plug, pre: () => 'vendor knob missing' } },
	mux: [ { id: 1, name: 'wwand0' } ],
});
eq(res, { ok: false, error: 'vendor knob missing' }, 'pre: a string aborts setup with it');
eq(prefx.action_index('link_set wwan0 mtu 4100'), -1, 'pre: nothing after it ran');

// the built-in rmnet takes the same route for pass_through
let ptfx = fakefx.create({ present: caps_rmnet });
netlink.setup(ptfx, { netdev: 'wwan0', backend: 'rmnet',
	mux: [ { id: 1, name: 'wwan0m1' } ], dgram_size: 4096 });
ok(ptfx.action_index('write /sys/class/net/wwan0/qmi/pass_through Y') > 0,
	'pre: rmnet still writes pass_through (through the same hook)');

// an add-on cannot shadow a built-in name
eq(netlink.select_backend(fakefx.create({ present: caps_rmnet }), 'wwan0', 'rmnet', true,
	{ rmnet: { links: () => [], probe: () => false } }), 'rmnet',
	'plugin: a built-in name resolves to the built-in, not to an add-on');

// built-in names ignore a passed plugin entirely
eq(netlink.builtin_mux('rmnet'), true, 'builtin_mux: rmnet');
eq(netlink.builtin_mux('vendorx'), false, 'builtin_mux: a plugin name is not built-in');
eq(netlink.valid_plugin({ links: () => [] }), true, 'valid_plugin: needs links()');
eq(netlink.valid_plugin({}), false, 'valid_plugin: rejects an object without it');

// a plugin is for the control protocols it declares (default qmi): under 'auto'
// an MBIM box must not be handed a qmi_wwan mux, which cannot work there
eq(netlink.select_backend(pfx, 'wwan0', 'auto', true, plugmap, { proto: 'mbim' }), 'vlan',
	'plugin: a qmi-only plugin does not claim an mbim modem');
eq(netlink.select_backend(pfx, 'wwan0', 'auto', true,
	{ vendorx: { ...plug, proto: [ 'qmi', 'mbim' ] } }, { proto: 'mbim' }), 'vendorx',
	'plugin: ... one that declares mbim does');
// The declared protocol is enforced even when the datapath is NAMED, unlike the
// probe's "you asked for it" latitude: a protocol a datapath does not serve is
// not a risky choice but an impossible one — rmnet's QMAP framing on a cdc_mbim
// session cannot carry traffic however firmly it was named. Refused like a
// missing package, and said out loud.
{
	let logs3 = [];
	let lfx = fakefx.create({ present: vendor_caps });
	lfx.log = (lvl, msg) => push(logs3, sprintf('%s %s', lvl, msg));

	eq(netlink.select_backend(lfx, 'wwan0', 'vendorx', true, plugmap, { proto: 'mbim' }), null,
		'plugin: naming a qmi datapath on an mbim modem is refused');
	ok(length(filter(logs3, (m) => match(m, /^err .*serves qmi, not mbim/) != null)) == 1,
		'plugin: ...and the reason names both protocols');

	// the same datapath on the protocol it does serve is of course fine
	eq(netlink.select_backend(pfx, 'wwan0', 'vendorx', true, plugmap, { proto: 'qmi' }), 'vendorx',
		'plugin: named and serving this protocol -> chosen');

	// a built-in is not special: naming the MBIM session mux on a QMI modem is
	// refused the same way
	eq(netlink.select_backend(pfx, 'wwan0', 'vlan', true, null, { proto: 'qmi' }), null,
		'builtin: naming vlan on a qmi modem is refused too');
	eq(netlink.select_backend(fakefx.create({ present: caps_rmnet }), 'wwan0', 'rmnet', true,
		null, { proto: 'mbim' }), null,
		'builtin: ...and rmnet on an mbim modem');
}

// `aggregate: false` opts out of the QMAP arithmetic: no header add-on, no
// rx_urb_size, no aggregation buffer forced onto the parent MTU — the backend
// sizes the parent inside links() (this is what the built-in vlan does)
fx = fakefx.create({ present: vendor_caps });
res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'vendorx', dgram_size: 4096,
	plugins: { vendorx: { ...plug, aggregate: false } },
	mux: [ { id: 1, name: 'wwan0m1' } ],
});
eq(res.ok, true, 'plugin-noagg: ok');
eq(res.urb_size, null, 'plugin-noagg: no urb size reported');
eq(length(fx.matching('rx_urb_size')), 0, 'plugin-noagg: no urb write');
eq(fx.action_index('link_set wwan0 mtu 4100'), -1, 'plugin-noagg: parent MTU left to links()');

// `programs_parent: false` says "I touch no driver format" — so the parent is
// neither bounced nor written to. A plugin that does program one (the default)
// still gets the bounce.
fx = fakefx.create({ present: vendor_caps });
netlink.setup(fx, {
	netdev: 'wwan0', backend: 'vendorx', dgram_size: 4096,
	plugins: { vendorx: { ...plug, programs_parent: false } },
	mux: [ { id: 1, name: 'wwan0m1' } ],
});
eq(fx.action_index('link_set wwan0 down'), -1, 'plugin-nofmt: parent not bounced');
eq(length(fx.matching('qmi/raw_ip')), 0, 'plugin-nofmt: driver format left alone');

// child_name() is the ONE naming rule: the shared prune, the parent-rename
// collision check and links() must agree, or a stale child survives under a
// name the wanted list never mentions
fx = fakefx.create({ present: { ...vendor_caps, '/sys/class/net/vx1': true },
	files: { '/sys/class/net/wwan0/ifindex': "3\n",
	         '/sys/class/net/vx1/iflink': "3\n" } });
netlink.setup(fx, {
	netdev: 'wwan0', backend: 'vendorx', dgram_size: 4096,
	plugins: { vendorx: { ...plug,
		child_name: (nd, e) => sprintf('vx%d', e.id) } },
	mux: [ { id: 1 } ],
});
eq(fx.action_index('link_del vx1'), -1,
	'plugin-naming: prune keeps the child the plugin would name itself');

// --- autosetup: may this modem carry a mux channel? ---------------------------
//
// What decides whether the zero-config path writes a `mux_id`. Per MODEM: rmnet
// is a global module, but qmimux reads THIS netdev's add_mux node and an add-on
// probes this device — so on a two-modem box the answer may differ, and a check
// keyed on the box would be wrong.
eq(netlink.mux_available(fakefx.create({ present: caps_rmnet }), 'wwan0', 'qmi', null), true,
	'mux_available: qmi modem on an rmnet box');
eq(netlink.mux_available(fakefx.create({ present: { '/sys/class/net/wwan0/qmi/add_mux': true } }),
	'wwan0', 'qmi', null), true, 'mux_available: qmimux counts too');
eq(netlink.mux_available(fakefx.create(), 'wwan0', 'qmi', null), false,
	'mux_available: no mux datapath on this box');
eq(netlink.mux_available(fakefx.create({ present: caps_rmnet }), null, 'qmi', null), false,
	'mux_available: no netdev resolved yet -> no channel');

// the other backends keep their defaults: an MBIM session is not a QMAP channel
// and NCM has no mux at all
eq(netlink.mux_available(fakefx.create({ present: caps_rmnet }), 'wwan0', 'mbim', null), false,
	'mux_available: mbim keeps its default');
eq(netlink.mux_available(fakefx.create({ present: caps_rmnet }), 'wwan0', 'ncm', null), false,
	'mux_available: ncm keeps its default');
eq(netlink.mux_available(fakefx.create({ present: caps_rmnet }), 'wwan0', null, null), false,
	'mux_available: unknown protocol keeps its default');

// two modems, one box: the second has no mux node of its own, so it is NOT
// given a channel just because the first one could take it
{
	let twobox = fakefx.create({ present: {
		'/sys/class/net/wwan0/qmi/add_mux': true,   // modem A can mux
		'/sys/class/net/wwan1/qmi/raw_ip': true,    // modem B cannot
	} });

	eq(netlink.mux_available(twobox, 'wwan0', 'qmi', null), true,  'mux_available: modem A yes');
	eq(netlink.mux_available(twobox, 'wwan1', 'qmi', null), false, 'mux_available: modem B no');
}

// an add-on that claims the box makes it available even without a built-in
eq(netlink.mux_available(fakefx.create({ present: { '/sys/class/net/wwan0/vendor_mux': true } }),
	'wwan0', 'qmi', { vendorx: plug }), true,
	'mux_available: an add-on datapath counts as available');

// --- capabilities, asked of the datapath instead of its name -----------------
//
// Three callers used to test the NAME: `backend == 'rmnet'` decided QMAPv5 and
// uplink coalescing, `!= 'rmnet' && != 'qmimux'` decided whether the
// aggregation ratio means anything. Every datapath added later fell outside all
// three silently, which is what these capabilities exist to prevent.
eq(netlink.datapath_caps('rmnet', null),
	{ aggregate: true, qmap: true, qmap_versions: [ 5, 4, 1 ], tx_aggr: true, llp_802_3: false },
	'caps: rmnet drives every QMAP version it has rmnet flags for');
eq(netlink.datapath_caps('qmimux', null),
	{ aggregate: true, qmap: true, qmap_versions: [ 1 ], tx_aggr: false, llp_802_3: false },
	'caps: qmimux aggregates plain QMAP only, and has no coalesce knob');
eq(netlink.datapath_caps('ethernet', null),
	{ aggregate: false, qmap: false, qmap_versions: [ ], tx_aggr: false, llp_802_3: true },
	'caps: ethernet is the 802.3 link — no QMAP, no aggregation');
eq(netlink.datapath_caps('raw_ip', null).llp_802_3, false,
	'caps: raw_ip is raw framing, not 802.3');

// the ladder is descending preference, and it is what the negotiation walks
eq(netlink.datapath_caps('rmnet', null).qmap_versions[0], 5, 'caps: best first');
eq(netlink.rmnet_flags(5), 0x01 | 0x10 | 0x20, 'flags: v5 = deagg + CKSUMV5 pair');
eq(netlink.rmnet_flags(4), 0x01 | 0x04 | 0x08, 'flags: v4 = deagg + CKSUMV4 pair');
eq(netlink.rmnet_flags(1), 0x01, 'flags: plain QMAP is deaggregation only');
eq(netlink.datapath_caps('vlan', null).qmap, false,
	'caps: a VLAN mux is not QMAP');
eq(netlink.datapath_caps('raw_ip', null).qmap, false, 'caps: no mux, no QMAP');
eq(netlink.datapath_caps('none', null).qmap, false, 'caps: ...under the old spelling too');
eq(netlink.datapath_caps('nosuch', null),
	{ aggregate: false, qmap: false, qmap_versions: [ ], tx_aggr: false, llp_802_3: false },
	'caps: an unknown datapath claims nothing');

// `qmap` defaults to `aggregate` but is a DIFFERENT question: aggregate is who
// sizes the buffers, qmap is what rides the wire. A datapath adopting a
// driver's channels answers false and true.
eq(netlink.datapath_caps('x', { x: { links: () => [], aggregate: false } }).qmap, false,
	'caps: qmap follows aggregate by default');
eq(netlink.datapath_caps('x', { x: { links: () => [], aggregate: false, qmap: true } }).qmap, true,
	'caps: ...and can be set the other way when the driver owns the buffers');

// --- the catalog a UI offers for `option mux` --------------------------------
//
// netlink owns the list of what it implements; a UI carrying its own copy is a
// list that goes stale the day a datapath is added.
let cat = netlink.datapath_catalog();
let byname = {};
for (let e in cat)
	byname[e.name] = e;

eq(sort(keys(byname)), [ 'auto', 'ethernet', 'qmimux', 'raw_ip', 'rmnet', 'vlan' ],
	'catalog: every built-in and pseudo-mode is listed');
eq(byname.rmnet.proto, [ 'qmi' ], 'catalog: rmnet is a qmi datapath');
eq(byname.qmimux.proto, [ 'qmi' ], 'catalog: qmimux too');
// the catalog is BUILT from the datapaths, not a second table beside them — so
// a datapath and its catalog entry cannot disagree about what it serves
eq(netlink.datapath_protos({ proto: [ 'mbim' ] }), [ 'mbim' ], 'catalog: declared protos are read back');
eq(netlink.datapath_protos({}), [ 'qmi' ], 'catalog: qmi is the default for an add-on that says nothing');
eq(netlink.datapath_protos(null), [ 'qmi' ], 'catalog: ...and for no object at all');
eq(byname.vlan.proto, [ 'mbim' ], 'catalog: vlan is an mbim datapath');
eq(byname.auto.proto, null, 'catalog: a mode applies to every protocol');
eq(byname.raw_ip.kind, 'mode', 'catalog: raw_ip is a mode, not an implementation');
eq(byname.ethernet.kind, 'mode', 'catalog: ethernet is a mode too (802.3, no implementation)');
ok(length(byname.qmimux.description) > 0, 'catalog: every entry describes itself');

// the caller gets copies — editing what it was handed must not edit the table
byname.rmnet.proto[0] = 'clobbered';
eq(netlink.datapath_catalog()[3].proto, [ 'qmi' ], 'catalog: the module table is not aliased');

done('test_datapath');
