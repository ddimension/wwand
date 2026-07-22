// wwand — datapath/link setup: qmi_wwan driver data format, rx_urb_size,
// QMAP mux link creation (rmnet pass-through or qmimux backend), MTU
// sequencing. Port of the old qmi-hotplug logic.
//
// All side effects go through an injectable effects object so the sequence
// is host-testable:
//   fx = { read(path), write(path, data), exists(path), run(argv), log(level, msg) }
//
// Preserved behaviors (see old files/usr/sbin/qmi-hotplug):
// - dl-datagram-max-size from a per-board quirk table (4K default,
//   31K on zyxel lte3301-plus / nr7101), overridable via config
// - rx_urb_size = dl_datagram_max_size + 4 (QMAP header) when muxing
// - parent MTU 1504 while creating rmnet links, then parent MTU = urb size
// - mux child MTU: configured value if > 576, else 1500
// - link down before changing driver format / urb size, up afterwards

'use strict';

import * as fs from 'fs';

export const DEFAULT_DGRAM_SIZE = 4096;

// RMNET_FLAGS_* (linux/if_link.h)
export const RMNET_INGRESS_DEAGGREGATION = 0x01;
export const RMNET_INGRESS_CKSUMV5 = 0x10;
export const RMNET_EGRESS_CKSUMV5 = 0x20;

// board_name prefix -> aggregation size (SoC capability)
const BOARD_DGRAM_SIZES = [
	{ prefix: 'zyxel,lte3301-plus', size: 31 * 1024 },
	{ prefix: 'zyxel,nr7101',       size: 31 * 1024 },
	// SDX20-class boards support 16K; extend as devices get verified
];

// modem model pattern -> aggregation size; takes precedence over the board
// table (USB modems are not tied to a board). The modem clamps the WDA
// request to its real capability and the echoed value drives the driver
// side, so an optimistic entry here is safe.
const MODEL_DGRAM_SIZES = [
	{ pattern: '^RG650E', size: 31 * 1024 },   // SDX72 class
];

export function default_fx(log)
{
	let self = {
		last_error: null,
	};

	self.read = (path) => {
		let f = fs.open(path, 'r');

		if (!f)
			return null;

		let data = f.read('all');
		f.close();

		return data;
	};

	self.write = (path, data) => {
		let f = fs.open(path, 'w');

		if (!f) {
			self.last_error = fs.error();
			return false;
		}

		let ok = f.write(data) == length(data);

		if (!ok)
			self.last_error = fs.error();

		f.close();

		return ok;
	};

	self.exists = (path) => fs.access(path) == true;
	self.glob = (...patterns) => fs.glob(...patterns);
	self.run = (argv) => system(argv);
	self.log = log ?? ((level, msg) => warn(sprintf('%s: %s\n', level, msg)));

	// native rtnl link operations (no ip(8) spawns); the module is required
	// lazily so host tests (fakefx) never need it
	let rtnl = null;

	let rtnl_request = (flags, payload) => {
		rtnl = rtnl ?? require('rtnl');

		// return semantics of rtnl.request(): object = reply data,
		// null = acked without data (SUCCESS for set requests),
		// false = netlink error (details via rtnl.error())
		let r = rtnl.request(rtnl['const'].RTM_NEWLINK, flags, payload);

		if (r === false) {
			self.last_error = rtnl.error();
			return false;
		}

		return true;
	};

	const IFF_UP = 1;

	// opts: { up: bool, mtu: n, rename: 'newname' }
	self.link_set = (dev, opts) => {
		let payload = { dev: dev };

		if (opts.up != null) {
			payload.flags = opts.up ? IFF_UP : 0;
			payload.change = IFF_UP;
		}

		if (opts.mtu != null)
			payload.mtu = opts.mtu;

		if (opts.rename != null)
			payload.ifname = opts.rename;

		return rtnl_request(0, payload);
	};

	// 802.1q VLAN sub-device (cdc_mbim session mux: VLAN id == session id)
	self.link_add_vlan = (name, parent, vid) => {
		rtnl = rtnl ?? require('rtnl');

		let C = rtnl['const'];

		return rtnl_request(C.NLM_F_CREATE | C.NLM_F_EXCL, {
			ifname: name,
			link: parent,
			linkinfo: { type: 'vlan', id: vid },
		});
	};

	// rmnet links need IFLA_RMNET_FLAGS (deaggregation, MAPv5 checksum
	// offload) which the generic rtnl module cannot encode — the raw-netlink
	// helper lives in our own wwand_io module
	self.link_add_rmnet = (name, parent, mux_id, flags) => {
		let qmit = require('wwand_io');

		if (qmit.rmnet_add(name, parent, mux_id, flags ?? 0))
			return true;

		self.last_error = qmit.last_error();

		return false;
	};

	return self;
}

// perform a link operation with diagnostics
function link_op(fx, what, dev, opts)
{
	if (fx.link_set(dev, opts))
		return true;

	fx.log('warn', sprintf('%s: link_set %s %J failed%s', what, dev, opts,
		fx.last_error ? sprintf(': %s', fx.last_error) : ''));

	return false;
}

// write a sysfs attribute with meaningful diagnostics: distinguishes an
// absent attribute (feature not provided by this kernel/driver) from a
// failing write, and reports the previous value where readable
function write_attr(fx, path, value, what)
{
	if (!fx.exists(path)) {
		fx.log('warn', sprintf('%s: attribute %s not available on this kernel, skipping (wanted %s)',
			what, path, value));
		return false;
	}

	let before = trim(fx.read(path) ?? '');

	if (before == value)
		return true;

	if (!fx.write(path, value)) {
		fx.log('err', sprintf('%s: writing %s to %s failed%s (current value: %s)',
			what, value, path,
			fx.last_error ? sprintf(': %s', fx.last_error) : '',
			before == '' ? 'unreadable' : before));
		return false;
	}

	return true;
}

export function board_dgram_size(fx, override, model)
{
	if (+override > 0)
		return +override;

	for (let entry in MODEL_DGRAM_SIZES)
		if (match(model ?? '', regexp(entry.pattern)))
			return entry.size;

	let board = trim(fx.read('/tmp/sysinfo/board_name') ?? '');

	for (let entry in BOARD_DGRAM_SIZES)
		if (substr(board, 0, length(entry.prefix)) == entry.prefix)
			return entry.size;

	return DEFAULT_DGRAM_SIZE;
}

// decide the mux backend for a modem
//   cfg_mux: 'auto' | 'rmnet' | 'qmimux' | 'none'
export function select_backend(fx, netdev, cfg_mux, want_mux)
{
	if (!want_mux || cfg_mux == 'none')
		return 'none';

	let has_passthrough = fx.exists(sprintf('/sys/class/net/%s/qmi/pass_through', netdev));
	let has_rmnet = fx.exists('/sys/module/rmnet');
	let has_add_mux = fx.exists(sprintf('/sys/class/net/%s/qmi/add_mux', netdev));

	if (cfg_mux == 'rmnet')
		return (has_passthrough && has_rmnet) ? 'rmnet' : null;

	if (cfg_mux == 'qmimux')
		return has_add_mux ? 'qmimux' : null;

	// auto: prefer rmnet pass-through (preserved preference)
	if (has_passthrough && has_rmnet)
		return 'rmnet';

	if (has_add_mux)
		return 'qmimux';

	return null;
}

function child_mtu(mtu)
{
	return (+mtu > 576) ? +mtu : 1500;
}

// Configure driver-side datapath. opts = {
//   netdev, backend ('none'|'rmnet'|'qmimux'),
//   mux: [ { id: 1, name: 'wwan0m1', mtu: 1500 }, ... ],
//   dgram_size,
// }
// Returns { ok, urb_size, mux_devs: [ 'wwan0m1', ... ], error? }
export function setup(fx, opts)
{
	let netdev = opts.netdev;
	let backend = opts.backend ?? 'none';
	let mux = opts.mux ?? [];
	let sys = sprintf('/sys/class/net/%s/qmi', netdev);
	let mux_devs = [];
	let mux_mtus = {};

	let urb_size = opts.dgram_size ?? DEFAULT_DGRAM_SIZE;

	// QMAP header overhead on the USB frame
	if (backend != 'none')
		urb_size += 4;

	link_op(fx, 'datapath', netdev, { up: false });

	// driver link-layer format: essential, bail out on failure. raw_ip must
	// be set first — the driver refuses pass-through on a non-raw-ip device.
	if (!write_attr(fx, sprintf('%s/raw_ip', sys), 'Y', 'driver format'))
		return { ok: false, error: 'raw_ip unavailable' };

	if (backend == 'rmnet' &&
	    !write_attr(fx, sprintf('%s/pass_through', sys), 'Y', 'driver format'))
		return { ok: false, error: 'pass_through unavailable' };

	// rx urb size: the sysfs attribute only exists on kernels carrying the
	// vendor patch; mainline usbnet derives the urb size from the parent
	// MTU (hard_mtu), which this sequence sets to urb_size further down —
	// so a missing attribute is expected and fully covered
	if (backend != 'none') {
		let urb_attr = sprintf('%s/rx_urb_size', sys);

		if (fx.exists(urb_attr))
			write_attr(fx, urb_attr, sprintf('%d', urb_size), 'urb size');
		else
			fx.log('info', sprintf('no rx_urb_size attribute, parent MTU %d covers the urb size (mainline usbnet)', urb_size));
	}

	if (backend == 'rmnet') {
		// preserved MTU dance: 1504 while adding links, then urb size
		link_op(fx, 'rmnet mtu', netdev, { mtu: 1504 });

		// deaggregation is mandatory (multi-packet QMAP frames), v5 adds
		// checksum offload negotiated via WDA
		let rmnet_flags = RMNET_INGRESS_DEAGGREGATION |
			(opts.v5 ? (RMNET_INGRESS_CKSUMV5 | RMNET_EGRESS_CKSUMV5) : 0);

		for (let entry in mux) {
			let id = entry.id;
			let child = entry.name ?? sprintf('%sm%d', netdev, id);

			mux_mtus[child] = entry.mtu;

			if (!fx.link_add_rmnet(child, netdev, id, rmnet_flags)) {
				// tolerate pre-existing links (daemon restart)
				if (!fx.exists(sprintf('/sys/class/net/%s', child))) {
					fx.log('err', sprintf('failed to create rmnet link %s%s', child,
						fx.last_error ? sprintf(': %s', fx.last_error) : ''));
					continue;
				}
			}

			push(mux_devs, child);
		}

		link_op(fx, 'parent mtu', netdev, { mtu: urb_size });
	}
	else if (backend == 'qmimux') {
		for (let entry in mux) {
			let id = entry.id;
			let child = entry.name ?? sprintf('%sm%d', netdev, id);

			mux_mtus[child] = entry.mtu;

			if (!fx.exists(sprintf('/sys/class/net/%s', child))) {
				// qmi_wwan creates qmimuxN on add_mux write (no mux_id sysfs
				// attribute on current kernels) — identify the new link by
				// diffing the qmimux* set, then rename to our scheme
				let before = {};

				for (let p in (fx.glob('/sys/class/net/qmimux*') ?? []))
					before[p] = true;

				if (!write_attr(fx, sprintf('%s/add_mux', sys), sprintf('%d\n', id), 'qmimux create')) {
					continue;
				}

				let created = null;

				for (let p in (fx.glob('/sys/class/net/qmimux*') ?? [])) {
					if (!before[p]) {
						created = substr(p, rindex(p, '/') + 1);
						break;
					}
				}

				if (created)
					link_op(fx, 'qmimux rename', created, { rename: child });
				else
					fx.log('err', sprintf('could not identify qmimux link for mux id %d', id));
			}

			push(mux_devs, child);
		}

		link_op(fx, 'parent mtu', netdev, { mtu: urb_size });
	}
	else {
		// plain raw-ip: plain MTU on the parent (config or 1500)
		link_op(fx, 'mtu', netdev, { mtu: child_mtu(opts.mtu) });
	}

	// child MTUs and link up
	link_op(fx, 'link up', netdev, { up: true });

	for (let child in mux_devs) {
		link_op(fx, 'child mtu', child, { mtu: child_mtu(mux_mtus[child]) });
		link_op(fx, 'child up', child, { up: true });
	}

	return { ok: true, urb_size: urb_size, mux_devs: mux_devs };
}

// cdc_mbim session datapath: session 0 is the untagged parent netdev,
// sessions > 0 are 802.1q VLAN sub-devices whose VLAN id equals the MBIM
// session id. Children are named after the context's expected link name
// (mux_link) so netifd's device binding matches without config changes.
export function setup_mbim(fx, opts)
{
	let netdev = opts.netdev;
	let mux_devs = [];
	let mux_mtus = {};

	for (let entry in (opts.mux ?? [])) {
		if (!(entry.id > 0))
			continue;   // session 0 rides the parent, no sub-device

		let child = entry.name ?? sprintf('%s.%d', netdev, entry.id);

		mux_mtus[child] = entry.mtu;

		if (!fx.link_add_vlan(child, netdev, entry.id)) {
			// tolerate pre-existing links (daemon restart)
			if (!fx.exists(sprintf('/sys/class/net/%s', child))) {
				fx.log('err', sprintf('failed to create vlan link %s%s', child,
					fx.last_error ? sprintf(': %s', fx.last_error) : ''));
				continue;
			}
		}

		push(mux_devs, child);
	}

	link_op(fx, 'link up', netdev, { up: true });

	for (let child in mux_devs) {
		link_op(fx, 'child mtu', child, { mtu: child_mtu(mux_mtus[child]) });
		link_op(fx, 'child up', child, { up: true });
	}

	return { ok: true, mux_devs: mux_devs };
}

// endpoint interface number for WDA/bind-mux (e.g. .../1-1.2:1.4 -> 4)
export function ep_iface_number(netdev)
{
	for (let link in [ sprintf('/sys/class/net/%s/device', netdev),
	                   sprintf('/sys/class/net/%s/lower_0/device', netdev) ]) {
		let target = fs.readlink(link);

		if (target == null)
			continue;

		let m = match(target, /:[0-9]+\.([0-9]+)$/);

		if (m)
			return +m[1];
	}

	return null;
}
