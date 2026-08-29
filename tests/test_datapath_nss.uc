// wwand tests — the rmnet_nss vendor datapath add-on (datapath_rmnet_nss.uc).
//
// Every expectation here is taken from the vendor sources, not from the plugin:
//   qmi_wwan_q.c  sprintf(name, "%s_%d", real_dev->name, offset_id + 1)
//                 priv->mux_id = QUECTEL_QMAP_MUX_ID(0x81) + offset_id
//                 attribute group WITHOUT .name -> knobs directly on the netdev
//                 dev->rx_urb_size = qmap_size (driver-owned, no writable knob)
//                 children registered in usbnet probe, one per qmap_mode
//   rmnet_nss.c   publishes rmnet_nss_callbacks; qmi_wwan_q captures
//                 use_qca_nss = !!nss_cb AT CHILD CREATION
//   quectel-cm    profile.muxid = <digit> + 0x80

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as fakefx from './lib/fakefx.uc';
import * as netlink from 'wwand/netlink.uc';

let plug = require('wwand.datapath_rmnet_nss');
let plugins = { rmnet_nss: plug };

// a box with the NSS shim loaded and a vendor parent carrying `qmap_mode`
// children — the shape qmi_wwan_q leaves behind after its USB probe
function vendor_fx(qmap_mode, extra) {
	let present = { '/sys/module/rmnet_nss': true, ...(extra ?? {}) };

	for (let i = 1; i <= qmap_mode; i++)
		present[sprintf('/sys/class/net/wwan0_%d', i)] = true;

	return fakefx.create({
		present: present,
		files: { '/sys/class/net/wwan0/qmap_mode': sprintf("%d\n", qmap_mode) },
	});
}

// --- probe: both halves are required -----------------------------------------

ok(plug.probe(vendor_fx(2), 'wwan0'), 'probe: nss loaded + vendor children present');

// mainline qmi_wwan: knobs under qmi/, no children -> not ours, change nothing
eq(plug.probe(fakefx.create({ present: {
	'/sys/module/rmnet_nss': true,
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
} }), 'wwan0'), false, 'probe: mainline qmi_wwan is not claimed');

// The discriminator is the CHILD, not qmap_mode. qmi_wwan_q registers children
// only when use_rmnet_usb is set (qmap_mode > 1, or three idProducts); with
// qmap_mode == 1 on anything else the parent carries the QMAP itself, no child
// exists and no nss_create() ran. The vendor's own dialer script tests exactly
// this. Claiming such a box would log an error per channel and adopt nothing.
{
	let no_child = fakefx.create({
		present: { '/sys/module/rmnet_nss': true },
		files: { '/sys/class/net/wwan0/qmap_mode': "1\n" },
	});

	eq(plug.probe(no_child, 'wwan0'), false,
		'probe: qmap_mode 1 without a registered child is not claimed');
}

// Vendor children present but the NSS shim is not loaded: STILL claimed. These
// children need adopting whether or not the offload is there, and declining was
// actively harmful — `auto` then fell through to mainline rmnet, whose probe a
// vendor parent satisfies (it wants /sys/module/rmnet and the ABSENCE of a qmi
// group), and rmnet built its own children on a parent that already demuxes
// QMAP internally. The missing shim is reported, not acted on.
{
	let logs = [];
	let noshim = fakefx.create({
		present: { '/sys/class/net/wwan0_1': true, '/sys/class/net/wwan0_2': true },
		files: { '/sys/class/net/wwan0/qmap_mode': "2\n" },
	});
	noshim.log = (lvl, msg) => push(logs, sprintf('%s %s', lvl, msg));

	eq(plug.probe(noshim, 'wwan0'), true, 'probe: vendor children are claimed without the shim too');
	ok(length(filter(logs, (m) => match(m, /^notice .*no NSS offload.*BEFORE qmi_wwan_q/) != null)) == 1,
		'probe: ...but the missing offload and its ordering are named');

	// and it still beats mainline rmnet there — the case that made the gate a
	// mistake in the first place
	let bare = fakefx.create({
		present: { '/sys/class/net/wwan0_1': true, '/sys/module/rmnet': true },
		files: { '/sys/class/net/wwan0/qmap_mode': "1\n" },
	});
	eq(netlink.select_backend(bare, 'wwan0', 'auto', true, plugins, { proto: 'qmi' }), 'rmnet_nss',
		'probe: a vendor box without NSS is not left to mainline rmnet');

	// the status page still tells the two cases apart
	eq(netlink.datapath_status(noshim, 'rmnet_nss', 'wwan0', plugins).nss_shim, 'absent',
		'probe: status reports the shim as absent');
}

// --- naming and the QMAP id on the wire --------------------------------------

eq(plug.child_name('wwan0', { id: 1 }), 'wwan0_1', 'name: <parent>_<n>, the driver scheme');
eq(plug.child_name('wwan0', { id: 3 }), 'wwan0_3', 'name: ...for every channel');
eq(plug.map_id({ id: 1 }), 0x81, 'map: channel 1 is 0x81 on the wire (QUECTEL_QMAP_MUX_ID)');
eq(plug.map_id({ id: 2 }), 0x82, 'map: ...+ offset for the next');
// the driver's arithmetic is an addition (0x81 + offset_id), not a bit set —
// they agree only while the channel stays below 128, and quectel-cm's own
// link_state write reads muxid back as (muxid - 0x80), which addition preserves
eq(plug.map_id({ id: 200 }), 0x80 + 200, 'map: it is addition, not a bit set');

// --- setup(): adopt, never create --------------------------------------------

let fx = vendor_fx(2);
let res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet_nss', plugins: plugins,
	mux: [ { id: 1, mtu: 1500 }, { id: 2, mtu: 1430 } ], dgram_size: 4096,
});

eq(res.ok, true, 'setup: ok');
eq(res.backend, 'rmnet_nss', 'setup: the add-on ran');
eq(res.mux_devs, [ 'wwan0_1', 'wwan0_2' ], 'setup: the driver children are adopted');
eq(res.map_ids, { '1': 0x81, '2': 0x82 }, 'setup: map ids reported for the WDS bind');

// nothing is created and nothing is removed
eq(length(fx.matching('link_add_rmnet')), 0, 'setup: no rmnet link created');
eq(length(fx.matching('add_mux')), 0, 'setup: no qmimux create');
eq(length(fx.matching('link_del')), 0, 'setup: no child deleted — the kernel owns them');

// the parent is neither bounced nor reprogrammed: there is no qmi group to
// write, and qmap_open() refuses while the parent is down
eq(fx.action_index('link_set wwan0 down'), -1, 'setup: parent never bounced');
eq(length(fx.matching('raw_ip')), 0, 'setup: no driver format written');
eq(length(fx.matching('rx_urb_size')), 0, 'setup: urb size is the driver\'s, not ours');
eq(res.urb_size, null, 'setup: no aggregation buffer reported');
eq(fx.action_index('link_set wwan0 mtu 4100'), -1, 'setup: no aggregation MTU on the parent');

// what it DOES do: parent up, child MTUs, children up
ok(fx.action_index('link_set wwan0 up') >= 0, 'setup: parent up (qmap_open needs it)');
ok(fx.action_index('link_set wwan0_1 mtu 1500') >= 0, 'setup: child mtu');
ok(fx.action_index('link_set wwan0_2 mtu 1430') >= 0, 'setup: second child mtu');
ok(fx.action_index('link_set wwan0_1 up') >= 0, 'setup: child up');

// --- link_state: the shared gate, with the driver's semantics ----------------
//
// link_state_store(): offset_id = (link_state & 0x7F) - 1, and 0x80 CLEARS. So
// writing the channel number enables that channel — which is what the shared
// code already does. Pinned here because it is the one write this datapath
// depends on and it is easy to "fix" into 0x81.
fx = vendor_fx(2, { '/sys/class/net/wwan0/link_state': true });
netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet_nss', plugins: plugins,
	mux: [ { id: 1 }, { id: 2 } ], dgram_size: 4096,
});
ok(fx.action_index('write /sys/class/net/wwan0/link_state 1') >= 0, 'link_state: channel 1 enabled');
ok(fx.action_index('write /sys/class/net/wwan0/link_state 2') >= 0, 'link_state: channel 2 enabled');

// --- a channel beyond qmap_mode ----------------------------------------------
//
// The count is fixed at insmod (module parameter, S_IRUGO), so the actionable
// advice is a modprobe.d edit — the error has to say so rather than "failed".
fx = vendor_fx(1);
res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet_nss', plugins: plugins,
	mux: [ { id: 1 }, { id: 2 } ], dgram_size: 4096,
});
eq(res.mux_devs, [ 'wwan0_1' ], 'overflow: the channels that exist are still adopted');
ok(length(filter(fx.actions, (a) => match(a, /channel 2 needs qmap_mode >= 2 but .* was loaded with 1.*modprobe/) != null)) == 1,
	'overflow: the error names the shortfall and where to change it');

// --- adopting is not the same as trusting a name -----------------------------
//
// Three ways the rename/adopt path can be handed a device that is not ours.
// None of them may end with that device in mux_devs: the shared code would set
// its MTU and netifd would bind to it, while the real channel stays unclaimed —
// link up, no traffic, which is the exact failure this datapath exists to avoid.

// (a) the target name is taken by something else while the vendor child is there
fx = vendor_fx(2, { '/sys/class/net/wwand0': true });
res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet_nss', plugins: plugins,
	mux: [ { id: 1, name: 'wwand0', mtu: 1500 } ], dgram_size: 4096,
});
eq(res.mux_devs, [ ], 'taken: the channel is left unclaimed, not bound to a stranger');
eq(fx.action_index('link_set wwan0_1 name wwand0'), -1, 'taken: no rename is even attempted');
ok(length(filter(fx.actions, (a) => match(a, /cannot give wwan0_1 the name wwand0/) != null)) == 1,
	'taken: and the collision is named');

// (b) the rename itself fails
fx = fakefx.create({
	present: { '/sys/module/rmnet_nss': true, '/sys/class/net/wwan0_1': true },
	files: { '/sys/class/net/wwan0/qmap_mode': "1\n" },
	rc: { 'link_set wwan0_1 name wwand0': 2 },
});
res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet_nss', plugins: plugins,
	mux: [ { id: 1, name: 'wwand0', mtu: 1500 } ], dgram_size: 4096,
});
eq(res.mux_devs, [ ], 'renamefail: a failed rename does not report the target anyway');

// (c) on a restart, a device carrying the target name that is NOT a child of
// this parent. The driver copies the parent's MAC onto every child, so a
// differing address rules it out (an all-zero raw-IP address proves nothing,
// which is why this rejects rather than confirms).
fx = fakefx.create({
	present: { '/sys/module/rmnet_nss': true, '/sys/class/net/wwand0': true },
	files: { '/sys/class/net/wwan0/qmap_mode': "2\n",
	         '/sys/class/net/wwan0/address': "02:11:22:33:44:55\n",
	         '/sys/class/net/wwand0/address': "02:aa:bb:cc:dd:ee\n" },
});
res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet_nss', plugins: plugins,
	mux: [ { id: 1, name: 'wwand0', mtu: 1500 } ], dgram_size: 4096,
});
eq(res.mux_devs, [ ], 'foreign: a same-named device with another MAC is refused');
ok(length(filter(fx.actions, (a) => match(a, /not a child of wwan0 \(different MAC\)/) != null)) == 1,
	'foreign: and the reason is the identity, not the name');

// ...while the real child, which carries the parent's MAC, is adopted
fx = fakefx.create({
	present: { '/sys/module/rmnet_nss': true, '/sys/class/net/wwand0': true },
	files: { '/sys/class/net/wwan0/qmap_mode': "2\n",
	         '/sys/class/net/wwan0/address': "02:11:22:33:44:55\n",
	         '/sys/class/net/wwand0/address': "02:11:22:33:44:55\n" },
});
res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet_nss', plugins: plugins,
	mux: [ { id: 1, name: 'wwand0', mtu: 1500 } ], dgram_size: 4096,
});
eq(res.mux_devs, [ 'wwand0' ], 'restart: the real child is still adopted');

// (d) an earlier configuration renamed this channel to a name nothing uses now:
// neither the canonical nor the wanted name exists, though qmap_mode says the
// channel is there. Only a driver reload restores it, so the error says that
// rather than blaming qmap_mode.
fx = vendor_fx(0, {});
fx.files['/sys/class/net/wwan0/qmap_mode'] = "2\n";
res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet_nss', plugins: plugins,
	mux: [ { id: 1, name: 'wwand5', mtu: 1500 } ], dgram_size: 4096,
});
eq(res.mux_devs, [ ], 'stale-name: nothing is adopted');
ok(length(filter(fx.actions, (a) => match(a, /an earlier configuration renamed this channel/) != null)) == 1,
	'stale-name: and the error points at the reload, not at qmap_mode');

// --- the adopted child takes the context's stable name -----------------------
//
// netifd binds `option device` to the context's wwandN. An adopted child left
// under the driver's own wwan0_1 would leave the interface unclaimed — the same
// reason qmimux renames its qmimuxN. The NSS context survives it: it is keyed on
// the netdev, not on its name.
fx = vendor_fx(2);
res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet_nss', plugins: plugins,
	mux: [ { id: 1, name: 'wwand0', mtu: 1500 } ], dgram_size: 4096,
});
eq(res.mux_devs, [ 'wwand0' ], 'rename: the child reports its stable name');
ok(fx.action_index('link_set wwan0_1 name wwand0') >= 0, 'rename: driver name -> stable name');
eq(res.map_ids, { '1': 0x81 }, 'rename: the wire id is unaffected by the name');

// a restart finds it already renamed: adopt it as it is, do not error
fx = fakefx.create({
	present: { '/sys/module/rmnet_nss': true, '/sys/class/net/wwand0': true },
	files: { '/sys/class/net/wwan0/qmap_mode': "2\n" },
});
res = netlink.setup(fx, {
	netdev: 'wwan0', backend: 'rmnet_nss', plugins: plugins,
	mux: [ { id: 1, name: 'wwand0', mtu: 1500 } ], dgram_size: 4096,
});
eq(res.mux_devs, [ 'wwand0' ], 'restart: an already-renamed child is adopted');
eq(length(fx.matching('name wwand0')), 0, 'restart: not renamed twice');

// --- status rows -------------------------------------------------------------
//
// What the status page can say about this datapath beyond the generic block.
// All three are read-only: the channel count and the RX buffer are fixed at
// insmod, and the shim either published its callbacks before the modem's driver
// bound or it did not.
let st = netlink.datapath_status(
	fakefx.create({
		present: { '/sys/module/rmnet_nss': true },
		files: { '/sys/class/net/wwan0/qmap_mode': "4\n",
		         '/sys/class/net/wwan0/qmap_size': "16384\n" },
	}), 'rmnet_nss', 'wwan0', plugins);

eq(st.nss_shim, 'loaded', 'status: the NSS shim is reported');
eq(st.qmap_mode, 4, 'status: the driver channel count');
eq(st.qmap_size, 16384, 'status: the driver RX buffer');

// a datapath that contributes nothing must not invent an empty block
eq(netlink.datapath_status(fakefx.create(), 'rmnet', 'wwan0', null), null,
	'status: a datapath with no status() contributes none');
eq(netlink.datapath_status(fakefx.create(), 'rmnet_nss', null, plugins), null,
	'status: ...and neither does one with no netdev');

// --- capabilities -------------------------------------------------------------
//
// The driver owns the RX buffers (rx_urb_size = qmap_size at bind), but QMAP is
// on the wire — so the aggregation ratio on the status page means what it means
// everywhere else, and the WDA format still applies. MAPv5 follows the
// reference client for this driver (quectel-cm: qmap_version = 0x05), since the
// driver fixes its own version at bind and exposes it nowhere.
eq(netlink.datapath_caps('rmnet_nss', plugins),
	{ aggregate: false, qmap: true, qmap_v5: true, tx_aggr: false },
	'caps: driver owns the buffers, QMAP on the wire, v5 offered, no ethtool knob');

// --- selection ---------------------------------------------------------------

// under 'auto' the add-on beats the built-ins on a box where both would probe
// true: rmnet's probe only wants /sys/module/rmnet and the absence of a qmi
// group, which a vendor parent satisfies — that is the CPU-forwarding trap.
fx = vendor_fx(2, { '/sys/module/rmnet': true });
eq(netlink.select_backend(fx, 'wwan0', 'auto', true, plugins, { proto: 'qmi' }), 'rmnet_nss',
	'select: the add-on wins over mainline rmnet on a vendor+NSS box');
eq(netlink.select_backend(fx, 'wwan0', 'auto', true, null, { proto: 'qmi' }), 'rmnet',
	'select: ...and without the package installed, rmnet is what would run');

// autosetup asks the same question, so such a box gets a mux_id
eq(netlink.mux_available(fx, 'wwan0', 'qmi', plugins), true,
	'autosetup: an NSS box is offered a mux channel');

done('test_datapath_nss');
