// wwand tests — the PCIe/MHI NSS datapath add-on (datapath_rmnet_nss_mhi.uc).
//
// Every expectation is taken from the vendor driver, not from the plugin:
//   mhi_netdev_quectel.c
//     sprintf(qmap_net->name, "%.12s.%d", real_dev->name, offset_id + 1)
//     temp_addr[5] = offset_id + 1        -> child MAC differs in the LAST octet
//     u8 mux_id = QUECTEL_QMAP_MUX_ID + i; if (mhi_mbim_enabled) mux_id = mbim_mux_id + i
//     add_mbim_hdr(): u16 tci = mux_id; if (qmap_mode > 1) tci += 1;  c[3] = tci
//     RX: mpQmapNetDev[qmap_mode == 1 ? 0 : tci - 1 - mbim_mux_id]
//     #define MBIM_MUX_ID_SDX7X 112   // sdx7x is 112-126, others is 0-14
//     mbim_mux_id = 112 only for PCI 17cb:0309

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as fakefx from './lib/fakefx.uc';
import * as netlink from 'wwand/netlink.uc';

let plug = require('wwand.datapath_rmnet_nss_mhi');
let plugins = { rmnet_nss_mhi: plug };

// an MHI parent as the driver leaves it: knobs on the parent, dot-children
function mhi_fx(opts) {
	let o = opts ?? {};
	let mode = o.qmap_mode ?? 2;
	let present = { '/sys/module/pcie_mhi': true, ...(o.present ?? {}) };
	let files = {
		'/sys/class/net/rmnet_mhi0/qmap_mode': sprintf("%d\n", mode),
		'/sys/class/net/rmnet_mhi0/qmap_size': "31744\n",
		'/sys/class/net/rmnet_mhi0/address': "02:11:22:33:44:00\n",
		'/sys/module/pcie_mhi/parameters/mhi_mbim_enabled': (o.mbim ? "1\n" : "0\n"),
		// the PCI ids sit on an ANCESTOR: the driver does
		// SET_NETDEV_DEV(ndev, &mhi_dev->dev), so device/ is the MHI device and
		// the PCI function is two levels up. The fixture models that, because a
		// fixture that invents them under device/ would hide the bug.
		'/sys/class/net/rmnet_mhi0/device/../../vendor': "0x17cb\n",
		'/sys/class/net/rmnet_mhi0/device/../../device': (o.sdx7x ? "0x0309\n" : "0x0306\n"),
		...(o.files ?? {}),
	};

	if (o.nss !== false)
		present['/sys/module/rmnet_nss'] = true;

	// this netdev must be OWNED by the vendor MHI driver, not merely live on a
	// box where the module is loaded
	let fx_links = { '/sys/class/net/rmnet_mhi0/device/driver':
		(o.driver ?? '../../../../bus/mhi/drivers/mhi_netdev') };

	for (let i = 1; i <= mode; i++) {
		present[sprintf('/sys/class/net/rmnet_mhi0.%d', i)] = true;
		files[sprintf('/sys/class/net/rmnet_mhi0.%d/address', i)] =
			sprintf("02:11:22:33:44:%02x\n", i);
	}

	let fx = fakefx.create({ present: present, files: files });
	let orig = fx.readlink;

	fx.readlink = (path) => fx_links[path] ?? (orig ? orig(path) : null);

	return fx;
}

// --- probe --------------------------------------------------------------------

ok(plug.probe(mhi_fx(), 'rmnet_mhi0'), 'probe: vendor MHI parent with registered children');

// the USB sibling's shape must NOT be claimed here: underscore children, no
// pcie_mhi module
eq(plug.probe(fakefx.create({
	present: { '/sys/module/rmnet_nss': true, '/sys/class/net/wwan0_1': true },
	files: { '/sys/class/net/wwan0/qmap_mode': "2\n" },
}), 'wwan0'), false, 'probe: the USB qmi_wwan_q shape is not claimed');

// the module is loaded but THIS netdev belongs to another driver: not ours.
// Without the driver check, qmap_mode plus a dot-child would be enough to claim
// somebody else's device on a box with several vendor drivers.
eq(plug.probe(mhi_fx({ driver: '../../../../bus/usb/drivers/qmi_wwan_q' }), 'rmnet_mhi0'), false,
	'probe: a netdev owned by another driver is not claimed');

// knobs but no registered child (a plain VLAN on some other netdev, or
// qmap_mode set with nothing built): not ours
eq(plug.probe(fakefx.create({
	present: { '/sys/module/pcie_mhi': true, '/sys/module/rmnet_nss': true },
	files: { '/sys/class/net/rmnet_mhi0/qmap_mode': "2\n" },
}), 'rmnet_mhi0'), false, 'probe: no registered child -> not claimed');

// no NSS shim: still claimed (the children need adopting either way), but said
{
	let logs = [];
	let fx = mhi_fx({ nss: false });
	fx.log = (l, m) => push(logs, sprintf('%s %s', l, m));
	eq(plug.probe(fx, 'rmnet_mhi0'), true, 'probe: claimed without the shim too');
	ok(length(filter(logs, (m) => match(m, /no NSS offload.*BEFORE pcie_mhi/) != null)) == 1,
		'probe: ...and the ordering is named');
}

// --- the wire id, which is the whole point ------------------------------------

// QMAP framing: the USB sibling's base, 0x81 + offset
eq(plug.map_id({ id: 1 }, 'rmnet_mhi0', mhi_fx({ mbim: false })), 0x81, 'qmap: channel 1 -> 0x81');
eq(plug.map_id({ id: 2 }, 'rmnet_mhi0', mhi_fx({ mbim: false })), 0x82, 'qmap: channel 2 -> 0x82');

// MBIM on ordinary hardware: mbim_mux_id is 0 and the driver adds 1, so the
// session id EQUALS wwand's channel number — nothing is remapped
eq(plug.map_id({ id: 1 }, 'rmnet_mhi0', mhi_fx({ mbim: true })), 1,
	'mbim: session id equals the channel on non-SDX7x (the driver adds the 1)');
eq(plug.map_id({ id: 2 }, 'rmnet_mhi0', mhi_fx({ mbim: true })), 2, 'mbim: ...and for channel 2');

// MBIM on an SDX7x (PCI 17cb:0309): offset by 112
eq(plug.map_id({ id: 1 }, 'rmnet_mhi0', mhi_fx({ mbim: true, sdx7x: true })), 113,
	'mbim/sdx7x: channel 1 -> session 113');
eq(plug.map_id({ id: 2 }, 'rmnet_mhi0', mhi_fx({ mbim: true, sdx7x: true })), 114,
	'mbim/sdx7x: channel 2 -> session 114');

// the SDX7x base is read from the PCI ANCESTOR; a fixture with nothing there
// must fall back to 0 rather than silently pretending
eq(plug.map_id({ id: 1 }, 'rmnet_mhi0', fakefx.create({
	present: { '/sys/module/pcie_mhi': true },
	files: { '/sys/class/net/rmnet_mhi0/qmap_mode': "2\n",
	         '/sys/module/pcie_mhi/parameters/mhi_mbim_enabled': "1\n" },
})), 1, 'mbim: an unreadable PCI id means base 0, not a guess');

// a single channel is a SEPARATE case: the driver expects the base itself,
// without the +1 (add_mbim_hdr only adds it when qmap_mode > 1)
eq(plug.map_id({ id: 1 }, 'rmnet_mhi0', mhi_fx({ mbim: true, qmap_mode: 1 })), 0,
	'mbim/single: the base itself, no +1');
eq(plug.map_id({ id: 1 }, 'rmnet_mhi0', mhi_fx({ mbim: true, qmap_mode: 1, sdx7x: true })), 112,
	'mbim/single on sdx7x: 112, no +1');

// --- naming and adoption -------------------------------------------------------

eq(plug.child_name('rmnet_mhi0', { id: 1 }), 'rmnet_mhi0.1', 'name: <parent>.<n>, a dot');
eq(plug.child_name('rmnet_mhi0', { id: 2, name: 'wwand0' }), 'wwand0',
	'name: a configured stable name wins — netifd binds to it');

let fx = mhi_fx();
let res = netlink.setup(fx, {
	netdev: 'rmnet_mhi0', backend: 'rmnet_nss_mhi', plugins: plugins,
	mux: [ { id: 1, name: 'wwand0', mtu: 1500 } ], dgram_size: 4096,
});
eq(res.ok, true, 'setup: ok');
eq(res.mux_devs, [ 'wwand0' ], 'setup: the driver child is adopted under the stable name');
ok(fx.action_index('link_set rmnet_mhi0.1 name wwand0') >= 0, 'setup: renamed, not created');
eq(length(fx.matching('link_add')), 0, 'setup: nothing is created');
eq(length(fx.matching('link_del')), 0, 'setup: nothing is deleted — the kernel owns them');
eq(fx.action_index('link_set rmnet_mhi0 down'), -1, 'setup: the parent is never bounced');
eq(res.urb_size, null, 'setup: the driver owns the buffers');
// this fixture runs the driver in QMAP framing, so the wire id is the USB
// sibling's base — the MBIM identity case is covered by the map_id block above
eq(res.map_ids, { '1': 0x81 }, 'setup: map_ids carries the QMAP wire id');

// the child MAC differs from the parent in the LAST octet, so adoption after a
// restart compares the first five — comparing the whole address would reject
// every real child
// built explicitly rather than through the fixture: the point is that
// rmnet_mhi0.1 is GONE (renamed by an earlier run) and wwand0 is what is left.
function renamed_fx(child_mac) {
	return fakefx.create({
		present: { '/sys/module/pcie_mhi': true, '/sys/module/rmnet_nss': true,
		           '/sys/class/net/wwand0': true },
		files: { '/sys/class/net/rmnet_mhi0/qmap_mode': "2\n",
		         '/sys/class/net/rmnet_mhi0/address': "02:11:22:33:44:00\n",
		         '/sys/module/pcie_mhi/parameters/mhi_mbim_enabled': "0\n",
		         '/sys/class/net/wwand0/address': child_mac },
	});
}

res = netlink.setup(renamed_fx("02:11:22:33:44:01\n"), {
	netdev: 'rmnet_mhi0', backend: 'rmnet_nss_mhi', plugins: plugins,
	mux: [ { id: 1, name: 'wwand0', mtu: 1500 } ], dgram_size: 4096,
});
eq(res.mux_devs, [ 'wwand0' ], 'restart: an already-renamed child is adopted on the first five octets');

// ...and a stranger under that name is not
res = netlink.setup(renamed_fx("de:ad:be:ef:00:01\n"), {
	netdev: 'rmnet_mhi0', backend: 'rmnet_nss_mhi', plugins: plugins,
	mux: [ { id: 1, name: 'wwand0', mtu: 1500 } ], dgram_size: 4096,
});
eq(res.mux_devs, [ ], 'restart: a same-named device with a foreign MAC is refused');

// --- selection ------------------------------------------------------------------

eq(netlink.select_backend(mhi_fx(), 'rmnet_mhi0', 'auto', true, plugins, { proto: 'mbim' }),
	'rmnet_nss_mhi', 'select: claims an MBIM modem on this hardware');
eq(netlink.select_backend(mhi_fx(), 'rmnet_mhi0', 'auto', true, plugins, { proto: 'qmi' }),
	'rmnet_nss_mhi', 'select: ...and a QMI one, the driver serves both');
eq(netlink.datapath_caps('rmnet_nss_mhi', plugins),
	{ aggregate: false, qmap: true, qmap_versions: [ 1 ], tx_aggr: false },
	'caps: driver owns the buffers, QMAP on the wire, plain QMAP only');

done('test_datapath_nss_mhi');
