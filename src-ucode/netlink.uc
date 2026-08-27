// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
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

	self.readlink = (path) => fs.readlink(path);

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
	self.realpath = (path) => fs.realpath(path);
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
	const IFF_NOARP = 0x80;

	// opts: { up: bool, mtu: n, rename: 'newname', noarp: bool }
	self.link_set = (dev, opts) => {
		let payload = { dev: dev };
		let flags = 0, change = 0;

		if (opts.up != null) {
			flags |= opts.up ? IFF_UP : 0;
			change |= IFF_UP;
		}

		if (opts.noarp != null) {
			flags |= opts.noarp ? IFF_NOARP : 0;
			change |= IFF_NOARP;
		}

		if (change) {
			payload.flags = flags;
			payload.change = change;
		}

		if (opts.mtu != null)
			payload.mtu = opts.mtu;

		if (opts.rename != null)
			payload.ifname = opts.rename;

		return rtnl_request(0, payload);
	};

	// remove a link we created. rtnl_request() is RTM_NEWLINK-only, so this
	// issues its own request.
	self.link_del = (dev) => {
		rtnl = rtnl ?? require('rtnl');

		let r = rtnl.request(rtnl['const'].RTM_DELLINK, 0, { dev: dev });

		if (r === false) {
			self.last_error = rtnl.error();

			return false;
		}

		return true;
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

	// read an existing rmnet child's kernel MAP id (IFLA_RMNET_MUX_ID) — the
	// authoritative value when adopting a link on a daemon restart; null when
	// the link is absent or not an rmnet link (the adopt path then REFUSES the
	// device). Left entirely unset when an older wwand_io.so predates the
	// getter, so the adopt path keeps its tolerant legacy behaviour instead of
	// refusing every adoption it cannot verify.
	if (type(require('wwand_io').rmnet_mux_id) == 'function')
		self.rmnet_mux_id = (name) => require('wwand_io').rmnet_mux_id(name);

	// enable rmnet uplink (egress) QMAP aggregation via the ethtool coalesce
	// TX-aggregation params. Best-effort: false when the kernel/driver has no
	// such knob (e.g. plain mainline without the coalesce op) — callers ignore.
	self.rmnet_tx_aggr = (name, bytes, frames, usecs) => {
		let qmit = require('wwand_io');

		// robust against an older wwand_io.so without this getter
		if (type(qmit.rmnet_tx_aggr) != 'function')
			return false;

		let ok = qmit.rmnet_tx_aggr(name, bytes, frames, usecs);

		if (!ok)
			self.last_error = qmit.last_error();

		return ok;
	};

	return self;
};

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
};

// Pin PCIe runtime PM off for an MHI modem's endpoint (and its bridge).
//
// mhi-pci-generic autosuspends the endpoint into D3 a few seconds after it goes
// idle. A Quectel RM520N-GL (qcom-sdx65m) on a BPi-R4 does not survive the
// resume: the link comes back throwing Uncorrectable(Non-Fatal)/CmpltTO, the
// endpoint stops answering for good, and NOTHING in software gets it back —
// remove+rescan, the bridge's secondary-bus reset and a re-probe of the whole
// mtk-pcie-gen3 controller all leave it at `LTSSM detect.quiet`. Only a cold
// boot does. The board has no modem GPIO to pulse either (M.2 slot power is
// hard-wired, PERST# comes off the PCIe pinmux), so there is no recovery to
// fall back on — which makes NOT suspending the only cure.
//
// wwand holds the control channel open, so the modem is normally busy enough
// not to idle out; the fatal suspend came while the modem sat in SIM_BLOCKED
// with the polls stopped. Hence: pin at bind time, not at datapath setup.
//
// Silent no-op for a USB modem — there is no PCI ancestor to find.
export function pin_runtime_pm(fx, device)
{
	if (!device)
		return null;

	let name = substr(device, rindex(device, '/') + 1);

	if (substr(name, 0, 4) != 'wwan')
		return null;

	let dir = fx.realpath ? fx.realpath(sprintf('/sys/class/wwan/%s/device', name)) : null;
	let pinned = [];

	// climb to the PCI endpoint (…/0003:01:00.0), then to its bridge
	while (dir && dir != '/' && length(pinned) < 2) {
		let base = substr(dir, rindex(dir, '/') + 1);

		if (match(base, /^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]$/)) {
			let knob = sprintf('%s/power/control', dir);

			if (fx.exists(knob) && write_attr(fx, knob, 'on', 'runtime pm'))
				push(pinned, base);
		}

		dir = substr(dir, 0, rindex(dir, '/'));
	}

	if (length(pinned))
		fx.log('info', sprintf('mhi: pinned PCIe runtime PM off for %s', join(', ', pinned)));

	return length(pinned) ? pinned : null;
};

// Remove mux children of `netdev` that the CURRENT configuration does not ask
// for. Nothing did this before, so a config that dropped multiplexing left its
// children behind: on a BPi-R4, deleting the muxed interfaces left
// `wwand0@mhi_hwip0` and `wwand1@mhi_hwip0` attached, the parent stuck at the
// rmnet MTU 1504 (`link_set mhi_hwip0 mtu 1500` -> EPERM, a device with rmnet
// children refuses it), and — worst — the name the next non-mux setup wants for
// its L3 device already taken by an orphan.
//
// Identified by `iflink` alone: sysfs does NOT expose the rtnl link kind. A
// real rmnet child's uevent carries only INTERFACE and IFINDEX — no DEVTYPE —
// so a devtype filter matches nothing on hardware (it did pass against a
// fixture that invented one, which is why this note is here). Stacking is the
// signal, and it is enough: wwand owns the link layer of a modem datapath
// netdev by design, so a stacked child of it that the config does not name is
// ours to remove — rmnet on the QMI path, VLAN on the cdc_mbim session path.
function prune_mux_children(fx, netdev, wanted)
{
	if (!fx.link_del)
		return;

	let ifindex = trim(fx.read(sprintf('/sys/class/net/%s/ifindex', netdev)) ?? '');

	if (!length(ifindex))
		return;

	let keep = {};

	for (let w in (wanted ?? []))
		keep[w] = true;

	for (let path in (fx.glob('/sys/class/net/*') ?? [])) {
		let name = substr(path, rindex(path, '/') + 1);

		if (name == netdev || keep[name])
			continue;

		if (trim(fx.read(sprintf('%s/iflink', path)) ?? '') != ifindex)
			continue;

		if (fx.link_del(name))
			fx.log('notice', sprintf('datapath: removed stale mux child %s of %s',
				name, netdev));
		else
			fx.log('warn', sprintf('datapath: could not remove stale mux child %s%s',
				name, fx.last_error ? sprintf(': %s', fx.last_error) : ''));
	}
}

// decide the mux backend for a modem
//   cfg_mux: 'auto' | 'rmnet' | 'qmimux' | 'none'
export function select_backend(fx, netdev, cfg_mux, want_mux)
{
	if (!want_mux || cfg_mux == 'none')
		return 'none';

	// pass_through is qmi_wwan's way of handing raw QMAP frames to rmnet.
	// A driver without the `qmi` group never parses the frames itself, so it
	// needs no such switch — rmnet stacks on it directly (mhi_net/MHI).
	let no_qmi_group = !fx.exists(sprintf('/sys/class/net/%s/qmi', netdev));
	let has_passthrough = no_qmi_group ||
		fx.exists(sprintf('/sys/class/net/%s/qmi/pass_through', netdev));
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
};

// resolve a mux child / raw-ip MTU: a configured value above the IPv4 minimum
// (576) is used as-is, otherwise 1500. An explicitly configured but out-of-range
// value is logged (not silently swallowed) so a typo is visible; an unset value
// falls through to the default without noise.
function child_mtu(mtu, fx, what)
{
	if (+mtu > 576)
		return +mtu;

	if (fx && mtu != null && mtu != '')
		fx.log('warn', sprintf('%s: ignoring invalid MTU %J (must be > 576), using 1500',
			what ?? 'mtu', mtu));

	return 1500;
}

// Configure driver-side datapath. opts = {
//   netdev, backend ('none'|'rmnet'|'qmimux'),
//   mux: [ { id: 1, name: 'wwan0m1', mtu: 1500 }, ... ],
//   dgram_size,
// }
// Returns { ok, urb_size, mux_devs: [ 'wwan0m1', ... ], error? }
// rmnet backend: one rmnet child per mux entry, tolerating pre-existing links
// on a daemon restart. Fills mux_mtus, returns the created child dev names.
// (preserved MTU dance: 1504 while adding links, then the urb size on the parent)
function setup_rmnet_links(fx, netdev, mux, v5, urb_size, mux_mtus)
{
	let mux_devs = [];

	link_op(fx, 'rmnet mtu', netdev, { mtu: 1504 });

	// deaggregation is mandatory (multi-packet QMAP frames); v5 adds checksum
	// offload negotiated via WDA
	let rmnet_flags = RMNET_INGRESS_DEAGGREGATION |
		(v5 ? (RMNET_INGRESS_CKSUMV5 | RMNET_EGRESS_CKSUMV5) : 0);

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

			// adopt: the kernel is the source of truth for the MAP id. Read it back
			// and warn on a mismatch with our config id (config drifted while the
			// link survived a restart) — the existing link is kept, not recreated.
			// A device of that name that is NOT an rmnet link (e.g. the parent
			// itself, or a foreign dev) must never be adopted: it would report a
			// working mux while the traffic dies on the raw device.
			let kid = fx.rmnet_mux_id ? fx.rmnet_mux_id(child) : null;

			if (fx.rmnet_mux_id && kid == null) {
				fx.log('err', sprintf('rmnet %s: existing device is not an rmnet mux child — not adopting', child));
				continue;
			}

			if (kid != null && kid != id)
				fx.log('warn', sprintf('rmnet %s: kernel MAP id %d != config %d (kept existing link)',
					child, kid, id));
		}

		push(mux_devs, child);
	}

	link_op(fx, 'parent mtu', netdev, { mtu: urb_size });

	return mux_devs;
}

// qmimux backend: qmi_wwan creates qmimuxN on the add_mux write with no mux_id
// sysfs attribute, so identify the new link by diffing the qmimux* set and
// rename it to our scheme. Fills mux_mtus, returns the child dev names.
function setup_qmimux_links(fx, netdev, sys, mux, urb_size, mux_mtus)
{
	let mux_devs = [];

	for (let entry in mux) {
		let id = entry.id;
		let child = entry.name ?? sprintf('%sm%d', netdev, id);

		mux_mtus[child] = entry.mtu;

		if (!fx.exists(sprintf('/sys/class/net/%s', child))) {
			let before = {};

			for (let p in (fx.glob('/sys/class/net/qmimux*') ?? []))
				before[p] = true;

			if (!write_attr(fx, sprintf('%s/add_mux', sys), sprintf('%d\n', id), 'qmimux create'))
				continue;

			let created = null;

			for (let p in (fx.glob('/sys/class/net/qmimux*') ?? [])) {
				if (!before[p]) {
					created = substr(p, rindex(p, '/') + 1);
					break;
				}
			}

			if (created)
				link_op(fx, 'qmimux rename', created, { rename: child });
			else {
				// couldn't create/identify the link — skip it (don't add a
				// phantom to mux_devs, matching the rmnet path's behaviour)
				fx.log('err', sprintf('could not identify qmimux link for mux id %d', id));
				continue;
			}
		}

		push(mux_devs, child);
	}

	link_op(fx, 'parent mtu', netdev, { mtu: urb_size });

	return mux_devs;
}

// lowest free `<prefix>N` netdev name (prefix defaults to 'wwan'), e.g. the raw
// kernel-style name to move a stale-renamed parent back to. (Declared before
// setup() — ucode resolves module-level names textually, no hoisting.)
function free_raw_name(fx, prefix)
{
	let p = prefix ?? 'wwan';

	for (let i = 0; i < 32; i++) {
		let name = sprintf('%s%d', p, i);

		if (!fx.exists(sprintf('/sys/class/net/%s', name)))
			return name;
	}

	return null;
}

export function setup(fx, opts)
{
	let netdev = opts.netdev;
	let backend = opts.backend ?? 'none';
	let mux = opts.mux ?? [];

	// Drop children the current config no longer asks for, BEFORE any naming
	// work: a stale child may be sitting on the very name this setup wants,
	// and it also pins the parent's MTU.
	prune_mux_children(fx, netdev,
		map(mux, (e) => e.name ?? sprintf('%sm%d', netdev, e.id)));

	// A mux child cannot share the parent's name. This happens when the parent
	// still carries a stable "wwandN" name from a previous NON-mux config (the
	// daemon renames the raw netdev to the L3 name when there are no mux
	// channels) and the config now switched to muxing — move the parent back
	// to a raw kernel name first so the child can take the name (mirrors
	// setup_mbim). Without this, link_add_rmnet/add_mux collides and the
	// pre-existing-link tolerance below silently adopts the PARENT as its own
	// mux child: the L3 then sits on the raw parent while the session traffic
	// is QMAP-muxed — link up, no data (HW-hit on the Chateau after a config
	// update bounced the datapath through a channel-less snapshot).
	if (backend != 'none') {
		for (let entry in mux) {
			let child = entry.name ?? sprintf('%sm%d', netdev, entry.id);

			if (child != netdev)
				continue;

			let raw = free_raw_name(fx);

			if (raw && fx.link_set(netdev, { rename: raw })) {
				fx.log('notice', sprintf('datapath: parent %s renamed to raw %s so the mux child can take the name',
					netdev, raw));
				netdev = raw;
			}
			else {
				return { ok: false,
					error: sprintf('parent %s occupies a mux child name and could not be moved', netdev) };
			}

			break;
		}
	}

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
	// The knobs live in qmi_wwan's `qmi` sysfs group; a driver that is raw-IP
	// by construction (mhi_net on a PCIe/MHI modem) has no such group at all,
	// and there is then nothing to set and nothing to fail on. Only a knob
	// MISSING from an EXISTING group is fatal.
	if (fx.exists(sys)) {
		if (!write_attr(fx, sprintf('%s/raw_ip', sys), 'Y', 'driver format'))
			return { ok: false, error: 'raw_ip unavailable' };

		if (backend == 'rmnet' &&
		    !write_attr(fx, sprintf('%s/pass_through', sys), 'Y', 'driver format'))
			return { ok: false, error: 'pass_through unavailable' };
	}
	else {
		fx.log('info', sprintf('datapath: %s has no qmi sysfs group — raw-IP driver, link-layer format left to it',
			netdev));
	}

	// rx urb size: the sysfs attribute only exists on kernels carrying the
	// vendor patch; mainline usbnet derives the urb size from the parent
	// MTU (hard_mtu), which this sequence sets to urb_size further down —
	// so a missing attribute is expected and fully covered
	if (backend != 'none') {
		let urb_attr = sprintf('%s/rx_urb_size', sys);

		if (fx.exists(urb_attr))
			write_attr(fx, urb_attr, sprintf('%d', urb_size), 'urb size');
	}

	if (backend == 'rmnet')
		mux_devs = setup_rmnet_links(fx, netdev, mux, opts.v5, urb_size, mux_mtus);
	else if (backend == 'qmimux')
		mux_devs = setup_qmimux_links(fx, netdev, sys, mux, urb_size, mux_mtus);
	else
		// plain raw-ip: plain MTU on the parent (config or 1500)
		link_op(fx, 'mtu', netdev, { mtu: child_mtu(opts.mtu, fx, netdev) });

	// child MTUs and link up
	link_op(fx, 'link up', netdev, { up: true });

	for (let child in mux_devs) {
		link_op(fx, 'child mtu', child, { mtu: child_mtu(mux_mtus[child], fx, child) });
		link_op(fx, 'child up', child, { up: true });
	}

	// vendor qmi_wwan (Quectel) gates each mux's data flow through a per-PDP
	// link_state write: `mux_id` enables it, `0x80|mux_id` disables it.
	// Mainline qmi_wwan has no such node (data flows once the WDS session and
	// carrier are up), so this is best-effort and existence-gated — a no-op on
	// mainline, but on a vendor kernel it is what actually opens the mux.
	let link_state = sprintf('/sys/class/net/%s/link_state', netdev);
	if (fx.exists(link_state)) {
		let ids = length(mux) ? map(mux, (e) => e.id) : [ 0 ];
		for (let id in ids)
			write_attr(fx, link_state, sprintf('%d\n', id & 0x7f), 'link_state enable');
	}

	// item 3: switch host-side uplink QMAP aggregation on to match what WDA
	// negotiated with the modem. Mainline rmnet exposes this only through the
	// ethtool TX-aggregation coalesce (default max_frames=1 = off); best-effort,
	// rmnet-only (qmimux/none/mbim have no such knob). Aggregation is shared per
	// real_dev port, so configuring any one child updates it.
	if (backend == 'rmnet' && fx.rmnet_tx_aggr &&
	    opts.ul_agg && (opts.ul_agg.count ?? 0) > 1 && (opts.ul_agg.size ?? 0) > 0) {
		for (let child in mux_devs) {
			if (fx.rmnet_tx_aggr(child, opts.ul_agg.size, opts.ul_agg.count, 800))
				fx.log('notice', sprintf('%s: uplink aggregation on (%d frames / %d bytes)',
					child, opts.ul_agg.count, opts.ul_agg.size));
			else
				fx.log('info', sprintf('%s: uplink aggregation unavailable, kernel default kept%s',
					child, fx.last_error ? sprintf(': %s', fx.last_error) : ''));
		}
	}

	// urb_size only means something for a muxed backend (the aggregation buffer);
	// on plain raw-ip the parent just carries the child MTU, so report null.
	// `parent` follows a possibly-moved parent name (see the rename above).
	return { ok: true, urb_size: (backend != 'none') ? urb_size : null,
	         mux_devs: mux_devs, parent: netdev };
};

// cdc_mbim session datapath: session 0 is the untagged parent netdev,
// sessions > 0 are 802.1q VLAN sub-devices whose VLAN id equals the MBIM
// session id. Children are named after the context's expected link name
// (mux_link) so netifd's device binding matches without config changes.
// Mirrors QMI/rmnet: the parent stays a RAW kernel name (wwanN), each child is
// the stable wwandN — so returns the (possibly moved) parent name.
export function setup_mbim(fx, opts)
{
	let netdev = opts.netdev;
	let mux_devs = [];
	let mux_mtus = {};

	// A muxed child cannot share the parent's name. This happens when the parent
	// still carries a stable "wwandN" name from a previous untagged (session-0)
	// config and is now being muxed — move the parent back to a raw kernel name
	// first, so the child can take the name (QMI keeps the parent raw wwanN and
	// the rmnet child wwandN for exactly this reason). Without this, link_add_vlan
	// would collide with the parent, silently leaving the L3 on the untagged
	// parent while the session is VLAN-tagged — no traffic.
	for (let entry in (opts.mux ?? [])) {
		if (!(entry.id > 0))
			continue;

		let child = entry.name ?? sprintf('%s.%d', netdev, entry.id);

		if (child == netdev) {
			let raw = free_raw_name(fx);

			if (raw && fx.link_set(netdev, { rename: raw })) {
				fx.log('notice', sprintf('mbim: parent %s renamed to raw %s so the mux child can take the name',
					netdev, raw));
				netdev = raw;
			}
			else {
				fx.log('err', sprintf('mbim: parent %s occupies the mux child name and could not be moved',
					netdev));
			}

			break;
		}
	}

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

	// the parent trunk must carry VLAN-tagged child frames: its MTU has to be at
	// least the largest child MTU + 4 (the 802.1q tag), else the kernel rejects a
	// child MTU that exceeds the parent. Bump it (floor 1504 for a 1500 child).
	let parent_mtu = 1504;

	for (let child in mux_devs) {
		let cm = child_mtu(mux_mtus[child]) + 4;

		if (cm > parent_mtu)
			parent_mtu = cm;
	}

	if (length(mux_devs))
		link_op(fx, 'parent mtu', netdev, { mtu: parent_mtu });

	link_op(fx, 'link up', netdev, { up: true });

	for (let child in mux_devs) {
		link_op(fx, 'child mtu', child, { mtu: child_mtu(mux_mtus[child], fx, child) });
		link_op(fx, 'child up', child, { up: true });
	}

	return { ok: true, mux_devs: mux_devs, parent: netdev };
};

// endpoint interface number for WDA/bind-mux (e.g. .../1-1.2:1.4 -> 4)
export function ep_iface_number(netdev, fx)
{
	let rl = fx?.readlink ?? fs.readlink;

	for (let link in [ sprintf('/sys/class/net/%s/device', netdev),
	                   sprintf('/sys/class/net/%s/lower_0/device', netdev) ]) {
		let target = rl(link);

		if (target == null)
			continue;

		// USB interface component is the `<bus>-<port>[.<port>]:<cfg>.<iface>`
		// form (e.g. "3-1:1.4", possibly as the bare relative symlink target
		// "../../../3-1:1.4"). Require the `-`-bearing bus-port token so a bare
		// PCI BDF ("0001:01:00.0") does NOT match the ":<cfg>.<iface>" suffix and
		// report a bogus interface 0 for an MHI/PCIe modem.
		let m = match(target, /[0-9]+-[0-9.]+:[0-9]+\.([0-9]+)$/);

		if (m)
			return +m[1];
	}

	return null;
};

// derive the QMI data endpoint type from the netdev's bus. The WDA
// SET_DATA_FORMAT and WDS BIND_MUX endpoint TLVs must carry the real bus so a
// PCIe-attached modem (e.g. RG500Q on M.2 / MHI) gets ENDPOINT_TYPE_PCIE (3),
// not HSUSB (2). A USB device's sysfs path always contains a `/usbN` component
// (its xHCI parent is on PCI, hence the usb check must win first); an MHI/PCIe
// modem has only the PCI BDF. Returns 2 (HSUSB), 3 (PCIE), or null.
export function ep_type_number(netdev, fx)
{
	const EP_HSUSB = 2, EP_PCIE = 3;
	let rl = fx?.readlink ?? fs.readlink;

	for (let link in [ sprintf('/sys/class/net/%s/device', netdev),
	                   sprintf('/sys/class/net/%s/lower_0/device', netdev) ]) {
		let target = rl(link);

		if (target == null)
			continue;

		if (match(target, /\/usb[0-9]/))
			return EP_HSUSB;

		if (match(target, /[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]/))
			return EP_PCIE;
	}

	return null;
};

// Live datapath / aggregation statistics from the netdev byte+packet counters.
// For QMAP muxing (rmnet/qmimux) the PARENT usbnet device receives one counter
// tick per USB frame (a frame may carry several muxed+aggregated packets),
// while each mux CHILD counts the deaggregated IP packets. So
//   rx_aggregation = sum(child rx_packets) / parent rx_packets
// is the mean number of packets the modem packed into each downlink frame — a
// real, mainline-observable measure of how much aggregation actually happened
// (1.0 = none, higher = better). Uplink is the same the other way. Returns
// per-device counters plus the derived ratios; null fields where a counter is
// unreadable. fx.read defaults to sysfs.
export function datapath_stats(fx, parent, children)
{
	let rl = fx?.read ?? (default_fx()).read;
	let ctr = (dev, name) => {
		let v = rl(sprintf('/sys/class/net/%s/statistics/%s', dev, name));
		return (v != null && match(trim(v), /^[0-9]+$/)) ? +trim(v) : null;
	};
	let dev_stats = (dev) => ({
		rx_packets: ctr(dev, 'rx_packets'), tx_packets: ctr(dev, 'tx_packets'),
		rx_bytes: ctr(dev, 'rx_bytes'), tx_bytes: ctr(dev, 'tx_bytes'),
	});

	let p = parent ? dev_stats(parent) : null;
	let kids = {};
	let sum_rx = 0, sum_tx = 0, have = false;

	for (let c in (children ?? [])) {
		let s = dev_stats(c);
		kids[c] = s;

		if (s.rx_packets != null) { sum_rx += s.rx_packets; have = true; }
		if (s.tx_packets != null) { sum_tx += s.tx_packets; have = true; }
	}

	// aggregation ratio only makes sense when a parent frame count exists and is
	// distinct from the children (QMAP); round to 2 decimals. NB ucode does
	// integer division for int/int — force float with the 100.0 factor.
	let ratio = (num, den) => (den && den > 0 && num != null) ?
		(int(num * 100.0 / den) / 100.0) : null;

	return {
		parent: p ? { dev: parent, ...p } : null,
		children: kids,
		rx_aggregation: (p && have) ? ratio(sum_rx, p.rx_packets) : null,
		tx_aggregation: (p && have) ? ratio(sum_tx, p.tx_packets) : null,
	};
};

// cdc_ncm / cdc_mbim NTB aggregation parameters, exposed by the usbnet cdc_ncm
// framing layer under /sys/class/net/<dev>/cdc_ncm/. This is the MBIM/NCM
// analogue of the QMI WDA aggregation config: several IP datagrams are packed
// into one USB NTB (NCM Transfer Block). Returns the load-bearing knobs (rx/tx
// max NTB size, max uplink datagrams per block, the coalescing timer) or null
// when the device is not cdc_ncm-framed (e.g. a QMI qmi_wwan parent). fx.read
// defaults to sysfs.
export function cdc_ncm_params(fx, dev)
{
	if (!dev)
		return null;

	let rl = fx?.read ?? (default_fx()).read;
	let base = sprintf('/sys/class/net/%s/cdc_ncm', dev);
	let num = (f) => {
		let v = rl(sprintf('%s/%s', base, f));
		return (v != null && match(trim(v), /^[0-9]+$/)) ? +trim(v) : null;
	};

	let rx_max = num('rx_max');

	// no cdc_ncm dir -> not NTB-framed
	if (rx_max == null && num('dwNtbInMaxSize') == null)
		return null;

	return {
		rx_max: rx_max ?? num('dwNtbInMaxSize'),
		tx_max: num('tx_max') ?? num('dwNtbOutMaxSize'),
		tx_max_datagrams: num('wNtbOutMaxDatagrams'),
		tx_timer_usecs: num('tx_timer_usecs'),
		min_tx_pkt: num('min_tx_pkt'),
	};
};
