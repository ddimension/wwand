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
export const RMNET_INGRESS_CKSUMV4 = 0x04;
export const RMNET_EGRESS_CKSUMV4 = 0x08;
export const RMNET_INGRESS_CKSUMV5 = 0x10;
export const RMNET_EGRESS_CKSUMV5 = 0x20;

// rmnet ingress/egress flags for a negotiated QMAP version. v1 carries no
// checksum offload at all, so it is deaggregation only; v4 and v5 are separate
// header formats with separate flags — telling rmnet the wrong one is not a
// downgrade, it is a misparse.
export function rmnet_flags(qmap_version)
{
	let f = RMNET_INGRESS_DEAGGREGATION;

	if (qmap_version == 5)
		f |= RMNET_INGRESS_CKSUMV5 | RMNET_EGRESS_CKSUMV5;
	else if (qmap_version == 4)
		f |= RMNET_INGRESS_CKSUMV4 | RMNET_EGRESS_CKSUMV4;

	return f;
};

// The bits rmnet_flags() can produce, i.e. the QMAP format bits this datapath
// OWNS. A correction on an existing link needs it because the kernel does not
// assign the flags, it applies them MASKED (rmnet_changelink(),
// drivers/net/ethernet/qualcomm/rmnet/rmnet_config.c; checked against 6.18.41):
//   port->data_format &= ~flags->mask;  port->data_format |= flags->flags & mask
// so a mask of only the wanted bits leaves the previous version's standing —
// downgrading v5 -> v1 with mask 0x01 keeps the v5 checksum bits and the port
// still misparses. With this mask a correction produces the same format a fresh
// create would for every bit wwand manages. Deliberately NOT included:
// RMNET_FLAGS_INGRESS_MAP_COMMANDS (0x02), which wwand never sets and which is
// not ours to clear — so that one bit is the exception to the sentence above,
// surviving a correction where rmnet_newlink() (whose base is
// INGRESS_DEAGGREGATION alone) would have dropped it.
export const RMNET_FLAGS_MASK = RMNET_INGRESS_DEAGGREGATION |
	RMNET_INGRESS_CKSUMV4 | RMNET_EGRESS_CKSUMV4 |
	RMNET_INGRESS_CKSUMV5 | RMNET_EGRESS_CKSUMV5;

// --- datapath plugins --------------------------------------------------------
//
// wwand ships three datapaths — two QMI mux backends (rmnet, qmimux) and the
// cdc_mbim session mux (vlan) — and they are entries in this same interface
// (see BUILTIN further down) rather than private shortcuts beside it: the path
// an add-on takes is the path every install exercises, instead of a seam only
// third parties ever touch. A third party can add one
// — a vendor driver with its own mux mechanism — WITHOUT patching wwand: an
// add-on package ships `wwand/datapath_<name>.uc`, a require()-able plain script
// that RETURNS its implementation. The daemon require()s it when a modem's
// `option mux` names it (the lazy pattern and the control_note of the
// control-backend packages) and threads the object down to setup() here.
//
// Threaded through deliberately, NOT collected in a module-level registry:
// ucode gives a require()d plain script its OWN copies of the modules it
// imports, so a plugin calling a register_backend() in this file would populate
// a DIFFERENT netlink instance than the daemon's and vanish without a trace
// (verified on the interpreter — the shared-state assumption looks right and
// silently is not). For the same reason a plugin should not import wwand
// modules for anything but pure helpers; everything it needs is handed to it.
//
//   // wwand/datapath_vendorx.uc
//   'use strict';
//   return {
//       // optional: the control protocols this datapath fits, default [ 'qmi' ]
//       // — an MBIM box is never offered a qmi_wwan mux under 'auto'.
//       proto: [ 'qmi' ],

//       // optional: your own driver-format switch, run before the urb/MTU
//       // work — this is where the built-in rmnet writes qmi_wwan's
//       // pass_through. Return true, or an error string to fail setup with.
//       pre: (fx, ctx) => true,
//
//       // Does this box belong to me? A plugin that answers yes here is
//       // preferred over the built-ins under `option mux 'auto'`, so the probe
//       // IS the contract — make it specific. Omit probe entirely to be
//       // explicit-only (usable, but only when `option mux` names you).
//       probe: (fx, netdev, info) => fx.exists('/sys/module/rmnet_nss'),
//
//       // create/adopt the children, fill ctx.mux_mtus, return their names
//       links: (fx, ctx) => { … return [ 'wwand0' ]; },
//
//       // optional: drop children this config no longer wants. The default
//       // (by iflink) covers anything that is a real netdev child of netdev.
//       prune: (fx, netdev, wanted) => { … },
//
//       // optional, default = `aggregate`: QMAP frames ride the PARENT, so the
//       // parent-vs-children packet ratio measures aggregation and the WDA data
//       // format applies. Distinct from `aggregate`, which says whether WWAND
//       // does the urb/MTU arithmetic — a datapath adopting a driver's channels
//       // has QMAP on the wire while the driver owns the buffers.
//       qmap: true,
//
//       // optional, default false: this datapath can carry MAPv5 checksum
//       // offload, so the WDA format is negotiated as QMAPv5 first (with the
//       // plain-QMAP fallback). Kept a capability rather than a name test —
//       // the built-in rmnet is not the only datapath that can do it.
//       qmap_v5: true,
//
//       // optional: extra rows for the status page — whatever this datapath
//       // knows that the generic block cannot (the vendor NSS one reports the
//       // driver's channel count, its RX buffer and whether the shim loaded).
//       // Read-only, called on demand; keys are shown as given.
//       status: (fx, netdev) => ({ … }),
//
//       // optional: opt into the rmnet-style uplink aggregation call
//       tx_aggr: true,
//
//       // optional, default TRUE — this datapath aggregates QMAP frames on the
//       // parent, so the shared code adds the 4-byte QMAP header to the
//       // datagram size, writes rx_urb_size and puts that size on the parent
//       // MTU. A datapath that muxes some other way (the built-in vlan) sets
//       // false and sizes the parent itself inside links().
//       aggregate: true,
//
//       // optional, default TRUE — this datapath reprograms the parent
//       // driver's link-layer format (qmi_wwan's raw_ip and whatever `pre`
//       // writes), which the driver only accepts while the parent is DOWN, so
//       // the shared code bounces it first. false means "do not touch the
//       // parent's format" and therefore "do not bounce it" — which is not
//       // cosmetic: on a daemon restart that adopts a live session, bouncing
//       // the parent would drop the traffic it is adopting.
//       programs_parent: true,
//
//       // optional: this datapath's own child naming. Return null for a mux
//       // entry that gets no child at all (vlan: session 0 rides the parent
//       // untagged). Default: entry.name, else '<parent>m<id>'.
//       child_name: (netdev, entry) => entry.name ?? sprintf('%sm%d', netdev, entry.id),
//
//       // optional: the id the MODEM must tag this channel with on the wire,
//       // when it differs from the config's channel number. Only a datapath
//       // whose children the kernel already created knows this — the vendor
//       // qmi_wwan_q numbers its children 0x81 upwards, so a config channel 1
//       // is QMAP id 0x81 on the wire and binding WDS to 1 makes the driver
//       // drop every frame ("unknow mux_id"). `netdev` is passed because the
//       // answer can depend on the device: the Quectel MHI driver offsets MBIM
//       // session ids by 112 on an SDX7x and by nothing elsewhere.
//       // setup() returns these as `map_ids`; the QMI context binds
//       // BIND_MUX_DATA_PORT to it and the MBIM context uses it as the session
//       // id. `fx` comes along so the answer can be READ rather than assumed,
//       // through the same injectable effects object everything else uses.
//       // Default: entry.id.
//       map_id: (entry, netdev, fx) => entry.id,
//   };
//
// links() gets a ctx carrying { netdev (the parent, possibly already renamed),
// sys (its /sys/class/net/<dev>/qmi), mux ([{ id, name?, mtu? }]), urb_size, v5,
// mux_mtus (OUT: child -> configured mtu), opts } plus the four helpers this
// module uses itself — ctx.link(what, dev, opts), ctx.write_attr(path, value,
// what), ctx.child_mtu(mtu, what) and ctx.child_name(entry) (the same naming
// the shared prune and rename used, yours included) — so the common case needs
// no imports at all. Everything around links() stays shared: pruning, moving a parent off a
// child's name, urb/MTU handling, link up, the vendor link_state gate and
// uplink aggregation.
//
// Choosing one. `option mux 'vendorx'` names it outright and always wins. Under
// the default 'auto' the rule is just the probe: an installed plugin whose
// probe() recognises the box (and whose `proto` covers the modem's control
// protocol) is preferred over the built-ins. That is how an
// accelerated datapath takes over on the hardware it belongs to (rmnet_nss on an
// ipq807x with NSS) without anyone editing a config — a zero-config autosetup
// box included, which is exactly where nobody will. The probes run whatever the
// channel count; a datapath selected with no children to build is dropped to
// raw_ip in setup(), which is what makes that safe.
//
// The probe is therefore the whole contract, and it must be specific: a plugin
// installed on hardware it does not fit has to say so and change nothing. A
// plugin with NO probe is explicit-only — something that cannot tell whether it
// fits must be asked for by name. Should several probes match, the first by name
// wins and the others are named in the log; the choice is logged at notice
// either way, and status reports the datapath that actually came up.
//
// `raw_ip` is the one name with no implementation behind it: it means "no mux
// at all", the plain raw-IP parent. It was spelled `none` until 1.6 and that
// spelling still works everywhere a config can carry it — see canon_mux().
//
// `ethernet` is the second such pseudo-mode (QMI-only): "no mux, and the
// parent KEEPS the kernel's 802.3 ethernet framing" — setup() re-asserts
// raw_ip = N (idempotent) and sets NOARP (static /32 + device route on a
// point-to-point hop, the RNDIS optimization). It is the datapath for old
// QMI stacks that cannot negotiate the link-layer format at all (no WDA
// service — the kernel link is whatever the driver chose, and 802.3 is the
// qmi_wwan default). Nothing aggregates, nothing muxes.

// a plugin object is only usable if it can actually build the links
export function valid_plugin(impl)
{
	return type(impl) == 'object' && type(impl.links) == 'function';
};

// The no-mux datapath is `raw_ip` — it names what the parent actually is
// (plain raw-IP framing) instead of what it is not. Two older spellings keep
// working, because a name in a config file is a promise: `none`, which is what
// every install before 1.6 has in `option mux`, and the hyphenated `raw-ip`,
// which is how the thing is written in prose and therefore what people type.
// Underscore is the canonical separator here — a datapath name doubles as the
// module name of an add-on package (`wwand.datapath_<name>`), and a module path
// cannot carry a hyphen at all.
export function canon_mux(name)
{
	if (name == null || name == '')
		return null;

	let n = replace('' + name, /-/g, '_');

	return (n == 'none') ? 'raw_ip' : n;
};

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

	// re-assert the QMAP flags on an ALREADY EXISTING rmnet child (netlink
	// changelink). Needed on the adopt path only: the flags live on the PARENT
	// (`port->data_format`, one per real_dev) and the kernel assigns them
	// wholesale, so a child surviving a restart otherwise keeps the format the
	// PREVIOUS run negotiated. Same guard as above — an older wwand_io.so
	// leaves it unset and the adopt path skips the correction rather than
	// failing the adoption.
	if (type(require('wwand_io').rmnet_flags_set) == 'function')
		self.rmnet_flags_set = (name, mux_id, flags, mask) => {
			let qmit = require('wwand_io');

			if (qmit.rmnet_flags_set(name, mux_id, flags, mask ?? flags))
				return true;

			self.last_error = qmit.last_error();

			return false;
		};

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
//   netdev, backend ('raw_ip'|'rmnet'|'qmimux'|'vlan'|a plugin name),
//   mux: [ { id: 1, name: 'wwan0m1', mtu: 1500 }, ... ],
//   dgram_size,
// }
// Returns { ok, urb_size, mux_devs: [ 'wwan0m1', ... ], error? }
// rmnet backend: one rmnet child per mux entry, tolerating pre-existing links
// on a daemon restart. Fills mux_mtus, returns the created child dev names.
// (preserved MTU dance: 1504 while adding links, then the urb size on the parent)
function setup_rmnet_links(fx, netdev, mux, qmap_version, urb_size, mux_mtus, child_name)
{
	let mux_devs = [];

	link_op(fx, 'rmnet mtu', netdev, { mtu: 1504 });

	// deaggregation is mandatory (multi-packet QMAP frames); v4/v5 add the
	// checksum offload WDA negotiated, each with its own flag pair
	let flags = rmnet_flags(qmap_version);

	for (let entry in mux) {
		let id = entry.id;
		let child = child_name(entry);

		mux_mtus[child] = entry.mtu;

		if (!fx.link_add_rmnet(child, netdev, id, flags)) {
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

			// The child is kept, but its FORMAT must still follow this run's
			// negotiation: the flags sit on the parent port and the kernel keeps
			// whatever the previous run set. A box moving from plain QMAP to v5
			// would otherwise come back from a restart decoding the wrong header
			// — tx climbing, rx flat, and no message anywhere. Done
			// unconditionally rather than after reading the flags back: with the
			// full mask the correction is idempotent, so the same-version case
			// costs one netlink round trip and needs no getter.
			// The MAP id goes along because the kernel's validate rejects a
			// change message without one; pass the id the link ACTUALLY has, so a
			// config that drifted (warned about just above) cannot remap it here.
			let corrected = false;

			if (fx.rmnet_flags_set)
				corrected = fx.rmnet_flags_set(child, kid ?? id, flags, RMNET_FLAGS_MASK);
			else
				fx.log('warn', sprintf('rmnet %s: this wwand_io.so has no rmnet_flags_set — the adopted link cannot be brought to this run\'s QMAP format',
					child));

			// A link whose format could not be corrected must not be reported as a
			// working mux: that is the exact silent failure this whole path exists
			// to end. Recreating restores correctness through the create path,
			// which the kernel treats as an assignment. It costs the
			// non-destructive restart, so it happens ONLY here — never on the
			// normal adopt, where the correction succeeds.
			if (!corrected) {
				fx.log('notice', sprintf('rmnet %s: recreating the adopted link to apply QMAP flags 0x%02x%s',
					child, flags, fx.last_error ? sprintf(' (%s)', fx.last_error) : ''));

				if (!fx.link_del || !fx.link_del(child)) {
					fx.log('err', sprintf('rmnet %s: could not delete the stale link — channel %d left unclaimed rather than reported as working',
						child, id));
					continue;
				}

				if (!fx.link_add_rmnet(child, netdev, id, flags)) {
					fx.log('err', sprintf('rmnet %s: recreate failed%s — channel %d left unclaimed',
						child, fx.last_error ? sprintf(': %s', fx.last_error) : '', id));
					continue;
				}
			}
		}

		push(mux_devs, child);
	}

	return mux_devs;
}

// qmimux backend: qmi_wwan creates qmimuxN on the add_mux write with no mux_id
// sysfs attribute, so identify the new link by diffing the qmimux* set and
// rename it to our scheme. Fills mux_mtus, returns the child dev names.
function setup_qmimux_links(fx, netdev, sys, mux, urb_size, mux_mtus, child_name)
{
	let mux_devs = [];

	for (let entry in mux) {
		let id = entry.id;
		let child = child_name(entry);

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

	return mux_devs;
}

// cdc_mbim session datapath: session 0 is the untagged parent netdev, sessions
// > 0 are 802.1q VLAN sub-devices whose VLAN id equals the MBIM session id.
// Children are named after the context's expected link name (mux_link) so
// netifd's device binding matches without config changes.
//
// The parent trunk must carry VLAN-tagged child frames, so its MTU has to be at
// least the largest child MTU + 4 (the 802.1q tag) or the kernel rejects the
// child MTU. That is why this backend sets the parent MTU itself and declares
// `aggregate: false`: the shared code's parent MTU is the QMAP aggregation
// buffer, which means nothing here.
function setup_vlan_links(fx, ctx)
{
	let mux_devs = [];

	for (let entry in ctx.mux) {
		let child = ctx.child_name(entry);

		if (child == null)
			continue;   // session 0 rides the parent, no sub-device

		ctx.mux_mtus[child] = entry.mtu;

		if (!fx.link_add_vlan(child, ctx.netdev, entry.id)) {
			// tolerate pre-existing links (daemon restart)
			if (!fx.exists(sprintf('/sys/class/net/%s', child))) {
				fx.log('err', sprintf('failed to create vlan link %s%s', child,
					fx.last_error ? sprintf(': %s', fx.last_error) : ''));
				continue;
			}
		}

		push(mux_devs, child);
	}

	// floor 1504 = a 1500-byte child plus the tag
	let parent_mtu = 1504;

	for (let child in mux_devs) {
		let cm = ctx.child_mtu(ctx.mux_mtus[child]) + 4;

		if (cm > parent_mtu)
			parent_mtu = cm;
	}

	if (length(mux_devs))
		ctx.link('parent mtu', ctx.netdev, { mtu: parent_mtu });

	return mux_devs;
}

// pass_through is qmi_wwan's way of handing raw QMAP frames to rmnet. A driver
// without the `qmi` group never parses the frames itself, so it needs no such
// switch — rmnet stacks on it directly (mhi_net/MHI).
function rmnet_usable(fx, netdev)
{
	let no_qmi_group = !fx.exists(sprintf('/sys/class/net/%s/qmi', netdev));

	return (no_qmi_group ||
	        fx.exists(sprintf('/sys/class/net/%s/qmi/pass_through', netdev))) &&
	       fx.exists('/sys/module/rmnet');
}

// The built-in datapaths, expressed through the SAME contract as an add-on
// (see the plugin comment at the top of this file). Deliberately not a private
// shortcut next to a public plugin path: one code path means the extension
// point is exercised by every install rather than by third parties only — the
// way an unused seam quietly stops working.
const BUILTIN = {
	rmnet: {
		proto: [ 'qmi' ],
		description: 'QMAP over the kernel rmnet driver (qmi_wwan pass-through)',
		// mainline rmnet carries MAPv5 checksum offload
		qmap_v5: true,
		probe: (fx, netdev) => rmnet_usable(fx, netdev),
		// qmi_wwan hands the raw QMAP frames to rmnet only with this set; a
		// driver without the `qmi` group has nothing to switch (mhi_net/MHI)
		pre: (fx, ctx) => {
			if (!fx.exists(ctx.sys))
				return true;

			return write_attr(fx, sprintf('%s/pass_through', ctx.sys), 'Y', 'driver format')
				? true : 'pass_through unavailable';
		},
		links: (fx, ctx) => setup_rmnet_links(fx, ctx.netdev, ctx.mux,
			ctx.qmap_version, ctx.urb_size, ctx.mux_mtus, ctx.child_name),
		// the QMAP header formats this datapath can drive, best first — the
		// caller negotiates down this ladder. rmnet has a flag pair for v4 and
		// for v5; anything else is plain QMAP.
		qmap_versions: [ 5, 4, 1 ],
		// mainline rmnet is the one with the ethtool egress-coalesce knob
		tx_aggr: true,
	},
	qmimux: {
		proto: [ 'qmi' ],
		description: "QMAP over qmi_wwan's own add_mux",
		probe: (fx, netdev) => fx.exists(sprintf('/sys/class/net/%s/qmi/add_mux', netdev)),
		links: (fx, ctx) => setup_qmimux_links(fx, ctx.netdev, ctx.sys, ctx.mux,
			ctx.urb_size, ctx.mux_mtus, ctx.child_name),
	},
	vlan: {
		proto: [ 'mbim' ],
		description: 'cdc_mbim sessions as 802.1q sub-devices',
		links: setup_vlan_links,
		// not a QMAP aggregator and it programs no driver format: no urb
		// arithmetic, and the parent must not be bounced (see the contract)
		aggregate: false,
		programs_parent: false,
		child_name: (netdev, entry) => (entry.id > 0)
			? (entry.name ?? sprintf('%s.%d', netdev, entry.id))
			: null,
		// No probe on purpose. It is the only datapath cdc_mbim has, the MBIM
		// backend names it, and there is nothing to recognise: a probe here
		// would either be a tautology or lock out the one caller.
	},
};

// preference among the built-ins under 'auto' (add-ons are tried before these).
// ONE list for every protocol: which of these entries a given modem may see is
// the entry's own `proto`, not a second table that has to be kept in step.
// rmnet before qmimux is preserved from years of field use, not alphabetical
// luck. A protocol appearing in no entry gets no built-in at all — NCM's
// cdc_ncm/cdc_ether datapath has no mux to pick.
const BUILTIN_ORDER = [ 'rmnet', 'qmimux', 'vlan' ];

// the control protocols a datapath declares itself for. The default is `qmi`:
// an add-on written before this field existed was necessarily a QMI one, and
// silently widening it to every protocol would offer MBIM modems a qmi_wwan mux.
export function datapath_protos(impl)
{
	return [ ...(impl?.proto ?? [ 'qmi' ]) ];
};

// is this datapath usable on a modem speaking `proto`?
function serves(impl, proto)
{
	return index(datapath_protos(impl), proto) >= 0;
}

// the pseudo-modes: not implementations, so they are not in BUILTIN, and they
// apply to every control protocol (`raw_ip` is what NCM effectively is).
const MODES = [
	{ name: 'auto',   kind: 'mode',
	  description: 'pick the best datapath for this hardware' },
	{ name: 'raw_ip', kind: 'mode',
	  description: 'no multiplexing — one plain raw-IP interface' },
	{ name: 'ethernet', kind: 'mode',
	  description: 'no multiplexing — the parent stays in 802.3 ethernet framing (raw_ip off), ARP off (point-to-point hop)' },
];

// What a UI offering `option mux` may show, built from the datapaths themselves
// so it cannot go stale behind a hardcoded copy. Each entry carries the control
// protocols it serves, since offering an MBIM modem a qmi_wwan mux is offering
// a config that cannot work. The daemon appends the installed add-ons, being
// the side that loads them.
export function datapath_catalog()
{
	let out = map(MODES, (e) => ({ ...e, proto: null }));

	for (let name in BUILTIN_ORDER)
		push(out, {
			name: name,
			kind: 'builtin',
			proto: datapath_protos(BUILTIN[name]),
			description: BUILTIN[name].description,
		});

	return out;
};

// mux modes this module implements itself (everything else needs a plugin)
export function builtin_mux(name)
{
	let n = canon_mux(name);

	return n == 'auto' || n == 'raw_ip' || n == 'ethernet' || exists(BUILTIN, n);
};

// `plugins` is a name -> implementation object IN PREFERENCE ORDER (ucode keeps
// insertion order; the daemon inserts by declared `auto` priority). `info`
// carries what the caller knows about the modem: { model, proto } — the control
// protocol decides which datapaths are candidates at all ('qmi' when unset,
// which is what every caller before MBIM joined this path meant).
export function select_backend(fx, netdev, cfg_mux, want_mux, plugins, info)
{
	let mux = canon_mux(cfg_mux) ?? 'auto';
	let proto = info?.proto ?? 'qmi';

	// Explicitly switched off: nothing to probe.
	//
	// `want_mux` deliberately does NOT short-circuit here any more. It used to,
	// and that meant a box with no channels configured never ran a single
	// probe — so an accelerated datapath could not introduce itself on exactly
	// the installs that never write `option mux`. The probes run now whatever
	// the channel count; want_mux only decides what an UNCLAIMED box is: an
	// error when a mux was required, the plain raw-IP parent otherwise.
	if (mux == 'raw_ip')
		return 'raw_ip';

	// `ethernet` is the other explicit pseudo-mode: keep the kernel-chosen 802.3
	// framing. Unlike raw_ip it is a QMI-only concept — an NCM datapath IS the
	// driver's ethernet-style link already, and MBIM rides a raw-IP trunk.
	if (mux == 'ethernet') {
		if (proto != 'qmi') {
			fx.log('err', sprintf('datapath: ethernet serves qmi, not %s — `option mux` names a datapath this modem cannot use',
				proto));
			return null;
		}

		return 'ethernet';
	}

	// Named outright: that one or nothing — never a quiet substitution. Built-in
	// or add-on makes no difference here; both answer the same probe().
	//
	// The declared protocol IS enforced, unlike the probe's "you asked for it"
	// latitude: a datapath states which control protocols it serves, and one it
	// does not serve is not a risky choice but an impossible one — rmnet's QMAP
	// framing on a cdc_mbim session cannot carry traffic however firmly it was
	// named. Reported like a missing package rather than built and left broken.
	if (mux != 'auto') {
		let impl = BUILTIN[mux] ?? plugins?.[mux];

		if (!valid_plugin(impl))
			return null;   // caller reports the missing package

		if (!serves(impl, proto)) {
			fx.log('err', sprintf('datapath: %s serves %s, not %s — `option mux` names a datapath this modem cannot use',
				mux, join('/', datapath_protos(impl)), proto));
			return null;
		}

		return (!impl.probe || impl.probe(fx, netdev, info)) ? mux : null;
	}

	// 'auto': an add-on that recognises the box comes before the built-ins (see
	// the plugin comment above). No probe = no offer.
	{
		let matched = [];

		for (let name, impl in (plugins ?? {}))
			if (!BUILTIN[name] && valid_plugin(impl) && impl.probe &&
			    serves(impl, proto) && impl.probe(fx, netdev, info))
				push(matched, name);

		if (length(matched)) {
			// deterministic, and a second match is a packaging mistake worth
			// seeing rather than a coin flip
			sort(matched);

			if (length(matched) > 1)
				fx.log('warn', sprintf('datapath: %d plugins claim this device (%s) — using %s; name one with `option mux` to be sure',
					length(matched), join(', ', matched), matched[0]));

			fx.log('notice', sprintf('datapath: %s selected by probe (over the built-ins)', matched[0]));

			return matched[0];
		}
	}

	// then the built-ins for this control protocol, in their own preference
	// order (rmnet pass-through first — preserved from years of field use, not
	// alphabetical luck). A built-in without a probe is the only datapath its
	// protocol has, so there is nothing to ask.
	for (let name in BUILTIN_ORDER) {
		let impl = BUILTIN[name];

		if (serves(impl, proto) && (!impl.probe || impl.probe(fx, netdev, info)))
			return name;
	}

	// nothing claimed the box. Under `auto` that is only an error if a mux was
	// actually required — otherwise the answer is the plain raw-IP parent, which
	// is what an unmuxed modem wanted anyway.
	return want_mux ? null : 'raw_ip';
};


// What a datapath can do, by name — for the callers that used to test the name
// itself. Those tests were the same mistake in three places: `backend ==
// 'rmnet'` decided QMAPv5 and uplink coalescing, and `!= 'rmnet' && != 'qmimux'`
// decided whether the aggregation ratio means anything, so every datapath added
// later silently fell outside all three.
export function datapath_caps(backend, plugins)
{
	let n = canon_mux(backend) ?? '';
	let impl = BUILTIN[n] ?? plugins?.[n];
	let aggregate = impl ? (impl.aggregate !== false) : false;

	return {
		// wwand does the urb/parent-MTU arithmetic
		aggregate: aggregate,
		// QMAP is on the wire (defaults to the above; a datapath that adopts a
		// driver's channels overrides it — the driver owns the buffers, but the
		// frames are still QMAP)
		qmap: impl ? (impl.qmap ?? aggregate) : false,
		// the QMAP header versions this datapath can drive, best first. Default
		// [1]: plain QMAP is the only thing a datapath that says nothing can be
		// assumed to handle, since v4 and v5 need format-specific handling.
		qmap_versions: impl
			? [ ...(impl.qmap_versions ?? (impl.qmap_v5 === true ? [ 5, 1 ] : [ 1 ])) ]
			: [],
		// host-side uplink coalescing is available
		tx_aggr: (impl?.tx_aggr === true),
		// the wire framing the parent carries: 802.3 (the kernel default) or
		// raw-IP. A boolean, not the WDA enum — netlink stays codec-free; the
		// caller maps it onto the WDA link-layer protocol value.
		llp_802_3: (n == 'ethernet'),
	};
};

// Extra status rows a datapath contributes, or null. Looked up by NAME because
// that is all the running modem records — the implementation itself is not kept
// anywhere after setup, and re-deriving it here keeps `status` free of state.
export function datapath_status(fx, backend, netdev, plugins)
{
	let impl = BUILTIN[canon_mux(backend) ?? ''] ?? plugins?.[canon_mux(backend) ?? ''];

	if (type(impl?.status) != 'function' || !netdev)
		return null;

	return impl.status(fx, netdev);
};

// Can this modem carry a mux channel at all? The question autosetup asks before
// writing a `mux_id`: QMI only (an MBIM session is not a QMAP channel and NCM
// has no mux), and only when some datapath actually claims THIS netdev — rmnet
// is a global module but qmimux reads this device's own `add_mux` node and an
// add-on answers with its own probe, so the answer is per modem, not per box.
export function mux_available(fx, netdev, proto, plugins)
{
	if (proto != 'qmi' || !netdev)
		return false;

	let be = select_backend(fx, netdev, 'auto', true, plugins, { proto: proto });

	return be != null && be != 'raw_ip';
};

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
	let backend = canon_mux(opts.backend) ?? 'raw_ip';
	let mux = opts.mux ?? [];

	// built-in or add-on: one lookup, one contract (see the plugin comment at
	// the top). 'raw_ip' and 'ethernet' are the backends that have no
	// implementation — they are the plain parent, not a mux.
	let impl = BUILTIN[backend] ?? opts.plugins?.[backend];

	if (!valid_plugin(impl))
		impl = null;

	if (backend != 'raw_ip' && backend != 'ethernet' && !impl)
		return { ok: false, error: sprintf('no implementation for datapath backend %J', backend) };

	// one naming rule per backend, used by the prune below, by the parent-rename
	// collision check and by links() itself (ctx.child_name) — the three places
	// that MUST agree on what a child is called. null = this entry gets no child.
	let child_of = (nd, e) => (type(impl?.child_name) == 'function')
		? impl.child_name(nd, e)
		: (e.name ?? sprintf('%sm%d', nd, e.id));

	// Drop children the current config no longer asks for, BEFORE any naming
	// work: a stale child may be sitting on the very name this setup wants,
	// and it also pins the parent's MTU.
	let wanted = filter(map(mux, (e) => child_of(netdev, e)), (n) => n != null);
	let prune = (type(impl?.prune) == 'function') ? impl.prune : prune_mux_children;

	prune(fx, netdev, wanted);

	// A backend with no children to build has nothing to do, and doing it anyway
	// is not harmless: rmnet's `pre` writes qmi_wwan's pass_through, which hands
	// the raw QMAP frames to an rmnet child that does not exist — link up, no
	// traffic. Same for the aggregation buffer landing on the parent MTU. So a
	// config that names no channel IS raw_ip, whatever was selected — which is
	// what makes probing an unmuxed box safe (see select_backend).
	//
	// Deliberately AFTER prune, so the backend's own prune() still runs: a
	// datapath whose children the KERNEL owns (a vendor driver creating them at
	// module load) overrides prune to keep them, and letting the fallback reach
	// the default prune instead would delete exactly those.
	if (impl && !length(wanted)) {
		// notice, not info: select_backend announces a probe match at notice, so
		// leaving the outcome below the default level would print "rmnet_nss
		// selected" and never say it went unused.
		fx.log('notice', sprintf('datapath: %s selected but no mux channels configured — plain raw-IP parent',
			backend));
		impl = null;
		backend = 'raw_ip';
	}

	// this datapath aggregates QMAP on the parent, and programs the parent
	// driver's link-layer format — both default to what the QMI mux backends do
	// (see the contract at the top). raw_ip aggregates nothing but still has its
	// framing programmed: setting qmi_wwan's raw_ip is the whole point of it.
	let aggregate = impl ? (impl.aggregate !== false) : false;
	let programs_parent = impl ? (impl.programs_parent !== false) : true;

	// A mux child cannot share the parent's name. This happens when the parent
	// still carries a stable "wwandN" name from a previous NON-mux config (the
	// daemon renames the raw netdev to the L3 name when there are no mux
	// channels) and the config now switched to muxing — move the parent back
	// to a raw kernel name first so the child can take the name. Without this,
	// link_add_rmnet/add_mux/add_vlan collides and the pre-existing-link
	// tolerance below silently adopts the PARENT as its own mux child: the L3
	// then sits on the raw parent while the session traffic is muxed — link up,
	// no data (HW-hit on the Chateau after a config update bounced the datapath
	// through a channel-less snapshot; the MBIM session mux had the same fix).
	if (impl) {
		for (let entry in mux) {
			let child = child_of(netdev, entry);

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

	// The QMAP id the modem must tag each channel with, keyed by the CONFIG
	// channel number — identical to it unless the datapath says otherwise (see
	// map_id in the contract). Returned so the control side can bind WDS to
	// what the kernel side actually expects; the two used to be assumed equal,
	// which is true for every datapath that creates its own children and false
	// for one that adopts a driver's.
	let map_ids = {};

	for (let entry in mux)
		map_ids[sprintf('%d', entry.id)] =
			(type(impl?.map_id) == 'function') ? impl.map_id(entry, netdev, fx) : entry.id;

	let urb_size = opts.dgram_size ?? DEFAULT_DGRAM_SIZE;

	// QMAP header overhead on the USB frame
	if (aggregate)
		urb_size += 4;

	// Only bounce the parent when its link-layer format is about to change: the
	// driver accepts that only while the device is down, and a bounce is not
	// free — on a daemon restart that adopts a live session it drops the very
	// traffic it is adopting. So it takes both a backend that programs the
	// parent at all (vlan does not) and something to actually program: the qmi
	// sysfs group, or a backend `pre` (which is how the MHI datapath, whose
	// driver has no such group, still gets its format switch).
	if (programs_parent && (fx.exists(sys) || type(impl?.pre) == 'function'))
		link_op(fx, 'datapath', netdev, { up: false });

	// driver link-layer format: essential, bail out on failure. raw_ip must
	// be set first — the driver refuses pass-through on a non-raw-ip device.
	// The knobs live in qmi_wwan's `qmi` sysfs group; a driver that is raw-IP
	// by construction (mhi_net on a PCIe/MHI modem) has no such group at all,
	// and there is then nothing to set and nothing to fail on. Only a knob
	// MISSING from an EXISTING group is fatal.
	//
	// `ethernet` writes 'N' — an idempotent re-assert of the kernel default.
	// The write still matters: the parent may carry raw_ip=Y from a previous
	// raw-ip config on the same modem, and an 802.3 link with the raw-ip flag
	// set carries garbage.
	if (programs_parent) {
		if (fx.exists(sys)) {
			if (!write_attr(fx, sprintf('%s/raw_ip', sys),
			                (backend == 'ethernet') ? 'N' : 'Y', 'driver format'))
				return { ok: false, error: 'raw_ip unavailable' };
		}
		else {
			fx.log('info', sprintf('datapath: %s has no qmi sysfs group — raw-IP driver, link-layer format left to it',
				netdev));
		}
	}

	// the backend's own driver-format switch, before the urb/MTU work: rmnet
	// needs qmi_wwan's pass_through here, and a vendor datapath is likely to
	// need a knob of its own at exactly this point. Returns true, or the error
	// string to fail the whole setup with.
	if (impl?.pre) {
		let perr = impl.pre(fx, { netdev: netdev, sys: sys, opts: opts });

		if (perr !== true)
			return { ok: false,
			         error: (type(perr) == 'string') ? perr
			                : sprintf('%s: driver format not available', backend) };
	}

	// rx urb size: the sysfs attribute only exists on kernels carrying the
	// vendor patch; mainline usbnet derives the urb size from the parent
	// MTU (hard_mtu), which this sequence sets to urb_size further down —
	// so a missing attribute is expected and fully covered
	if (aggregate) {
		let urb_attr = sprintf('%s/rx_urb_size', sys);

		if (fx.exists(urb_attr))
			write_attr(fx, urb_attr, sprintf('%d', urb_size), 'urb size');
	}

	if (impl)
		mux_devs = impl.links(fx, {
			netdev: netdev, sys: sys, mux: mux, urb_size: urb_size,
			// the negotiated QMAP header version (1 | 4 | 5). `v5` stays as the
			// boolean it always was so an add-on written before v4 existed keeps
			// working unchanged.
			qmap_version: opts.qmap_version ?? (opts.v5 ? 5 : 1),
			v5: opts.v5 ?? (opts.qmap_version == 5),
			mux_mtus: mux_mtus, opts: opts,
			// the helpers this module uses itself, so an add-on needs no
			// wwand imports (whose instances would be its own copies anyway)
			link: (what, dev, o) => link_op(fx, what, dev, o),
			write_attr: (path, value, what) => write_attr(fx, path, value, what),
			child_mtu: (mtu, what) => child_mtu(mtu, fx, what),
			child_name: (e) => child_of(netdev, e),
		}) ?? [];
	else {
		// 'raw_ip' / 'ethernet' — no mux: plain MTU on the parent (config or 1500)
		link_op(fx, 'mtu', netdev, { mtu: child_mtu(opts.mtu, fx, netdev) });

		// 802.3 link, point-to-point hop: the addressing is static (WDS /32 +
		// device route), so ARP would only burn radio airtime on a neighbour
		// that is never resolved — the same NOARP optimization the RNDIS
		// datapath runs (p2p framing, no neighbour resolution needed).
		if (backend == 'ethernet')
			link_op(fx, 'noarp', netdev, { noarp: true });
	}

	// the aggregation buffer belongs on the parent for every QMAP backend —
	// shared here rather than repeated in each one (a backend that needs a
	// different parent MTU declares aggregate:false and sets it in links(),
	// which runs just above)
	if (aggregate)
		link_op(fx, 'parent mtu', netdev, { mtu: urb_size });

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
	// rmnet-only (qmimux/raw_ip/vlan have no such knob). Aggregation is shared per
	// real_dev port, so configuring any one child updates it.
	if (impl?.tx_aggr && fx.rmnet_tx_aggr &&
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

	// urb_size only means something for a QMAP backend (the aggregation buffer);
	// elsewhere the parent carries the child MTU or the VLAN trunk size, so
	// report null. `parent` follows a possibly-moved parent name (see above).
	return { ok: true, urb_size: aggregate ? urb_size : null,
	         backend: backend, mux_devs: mux_devs, map_ids: map_ids,
	         parent: netdev };
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
	//
	// Below 1.0 the number is not a low ratio, it is a MEANINGLESS one: every
	// parent frame carries at least one child packet, so a mean under one can
	// only mean the two counters do not cover the same period — the child is
	// younger than its parent (any recreation: a config change, a QMAP
	// renegotiation, a manual `ip link del`) or parent frames go somewhere the
	// child list does not cover. These are lifetime counters, so that state
	// persists until the parent is reset. Report nothing rather than a "0.00"
	// that reads as "aggregation is off".
	let ratio = (num, den) => {
		if (!den || den <= 0 || num == null)
			return null;

		let r = int(num * 100.0 / den) / 100.0;

		return (r < 1.0) ? null : r;
	};

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
