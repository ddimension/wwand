// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — datapath add-on: Qualcomm NSS offload behind the vendor PCIe/MHI
// driver (`pcie_mhi`, Quectel's mhi_netdev_quectel.c).
//
// The sibling of datapath_rmnet_nss.uc, for the other driver Quectel ships.
// Same idea — the driver registers the QMAP children itself and calls
// `nss_cb->nss_create()` on each, so wwand adopts them rather than creating
// any — but almost every detail differs, which is why this is a second
// datapath and not a flag on the first:
//
//                      qmi_wwan_q (USB)       pcie_mhi (PCIe/MHI)
//   child name         <parent>_<n>           <parent>.<n>   (a DOT)
//   child MAC          the parent's           parent's, last octet = n
//   wire id            0x81 + (n-1)           see map_id below
//   control protocol   QMI only               QMI *and* MBIM
//
// The wire id is where reading the driver mattered most. Under MBIM it is the
// MBIM SESSION ID — the driver writes it into the NDP16 IPS signature
// (`c[3] = tci` in add_mbim_hdr) — and it is NOT a plain offset:
//
//     u16 tci = mux_id;                 // priv->mux_id = mbim_mux_id + offset
//     if (qmap_mode > 1) tci += 1;      // "rmnet_mhi0.X map to session X"
//
// with the RX side confirming it by indexing `mpQmapNetDev[tci - 1 -
// mbim_mux_id]`. So with more than one channel the session id is
// `mbim_mux_id + n`, and `mbim_mux_id` is 0 everywhere except an SDX7x
// (PCI 17cb:0309), where it is 112. On the common board the wire id therefore
// EQUALS wwand's channel number and nothing is remapped at all; only the SDX7x
// needs the offset. With exactly one channel the driver expects `mbim_mux_id`
// itself, with no +1 — a separate case, not an off-by-one.
//
// Under QMI the driver uses the same base as its USB sibling: 0x81 + offset.
//
// NOT HARDWARE-VERIFIED. Every number above is read out of the driver source
// and none of it has run on a board here. The MBIM mapping reaches into
// context_mbim (the session id, and the CONNECT-indication match), so on
// unexpected hardware the failure mode is "the session never comes up" rather
// than something subtle — compare `wire_session_id` in the context status with
// what the modem was asked for.

'use strict';

// the vendor MHI driver's per-netdev knobs, on the PARENT and with no
// subgroup — the same shape qmi_wwan_q uses
function vendor_attr(netdev, name)
{
	return sprintf('/sys/class/net/%s/%s', netdev, name);
}

// The name the driver gives channel `id`: sprintf("%.12s.%d", real_dev->name,
// offset_id + 1). The 12-character truncation is the driver's own.
//
// It is derived from the parent's name AT CREATION TIME. If the parent was
// renamed afterwards, the children keep names built from the old one and this
// no longer finds them — the probe then declines and the built-ins get their
// turn, which is the safe direction. Recovering such children would take a
// pcie_mhi reload; wwand does not rename an MHI parent itself.
function vendor_child(netdev, id)
{
	return sprintf('%.12s.%d', netdev, id);
}

function num_attr(fx, path)
{
	let v = fx.read(path);

	return v ? +trim(v) : 0;
}

function qmap_mode(fx, netdev)
{
	return num_attr(fx, vendor_attr(netdev, 'qmap_mode'));
}

// module parameter, S_IRUGO: 1 = the driver frames MBIM, 0 = QMAP
function mbim_enabled(fx)
{
	return num_attr(fx, '/sys/module/pcie_mhi/parameters/mhi_mbim_enabled') != 0;
}

// The driver's MBIM session base, decided from the PCI id exactly as the driver
// does: `if (vendor == 0x17cb && dev_id == 0x0309) mbim_mux_id = 112`.
//
// The ids are NOT under the netdev's own `device`: the driver does
// SET_NETDEV_DEV(ndev, &mhi_dev->dev), so that symlink points at the MHI
// device, and the PCI device is an ANCESTOR of it (mhi_device -> controller ->
// pci). Walk up a bounded ladder and take the first level that has both
// attributes — reading the wrong level silently yields base 0, which on an
// SDX7x is a session id the modem will never answer.
function pci_id(fx, netdev)
{
	for (let up in [ '', '/..', '/../..', '/../../..', '/../../../..' ]) {
		let base = sprintf('/sys/class/net/%s/device%s', netdev, up);
		let ven = lc(trim(fx.read(base + '/vendor') ?? ''));
		let dev = lc(trim(fx.read(base + '/device') ?? ''));

		if (length(ven) && length(dev))
			return { vendor: ven, device: dev };
	}

	return null;
}

function mbim_base(fx, netdev)
{
	let id = pci_id(fx, netdev);

	return (id?.vendor == '0x17cb' && id?.device == '0x0309') ? 112 : 0;
}

function mac(fx, netdev)
{
	return trim(fx.read(sprintf('/sys/class/net/%s/address', netdev)) ?? '');
}

return {
	// the driver serves both control protocols; which one is running decides
	// the wire id, not which datapath is chosen
	proto: [ 'qmi', 'mbim' ],

	description: 'QMAP over the vendor PCIe/MHI driver with Qualcomm NSS offload',

	// Specific: the vendor MHI module, its knobs on THIS parent, and a child it
	// actually registered. The child check is what separates this from its USB
	// sibling (dot vs underscore) and from a plain 802.1q VLAN on a netdev that
	// happens to carry those knobs.
	probe: (fx, netdev) => {
		if (!fx.exists('/sys/module/pcie_mhi'))
			return false;

		// ...and THIS netdev must be one of its own. The module being loaded
		// says nothing about the candidate; on a box with several vendor
		// drivers, `qmap_mode` plus a predictably named dot-child is not enough
		// to tell them apart.
		let drv = fx.readlink ? fx.readlink(sprintf('/sys/class/net/%s/device/driver', netdev)) : null;

		if (!drv || !match(drv, /(^|\/)mhi_netdev$/))
			return false;

		if (qmap_mode(fx, netdev) < 1)
			return false;

		if (!fx.exists(sprintf('/sys/class/net/%s', vendor_child(netdev, 1))))
			return false;

		// Claimed either way — the children need adopting regardless — but a
		// missing shim cannot be fixed afterwards (the driver captures whether
		// NSS is available when it creates each child), so say so once.
		if (!fx.exists('/sys/module/rmnet_nss'))
			fx.log('notice', sprintf('rmnet_nss_mhi: adopting the vendor QMAP channels of %s, but /sys/module/rmnet_nss is absent — no NSS offload; load rmnet_nss BEFORE pcie_mhi binds',
				netdev));

		return true;
	},

	child_name: (netdev, entry) => entry.name ?? vendor_child(netdev, entry.id),

	map_id: (entry, netdev, fx) => {
		if (!mbim_enabled(fx))
			return 0x80 + entry.id;   // QMAP: QUECTEL_QMAP_MUX_ID + offset

		let base = mbim_base(fx, netdev);

		// one channel: the driver expects the base itself, with no +1
		return (qmap_mode(fx, netdev) <= 1) ? base : (base + entry.id);
	},

	// as with the USB sibling: no driver format to program, the driver sized its
	// own buffers, and the parent must stay up for the children
	programs_parent: false,
	aggregate: false,
	qmap: true,

	// the children are the kernel's; only a pcie_mhi reload creates or removes
	// them, and the shared prune matches on iflink, which they do not report
	prune: (fx, netdev, wanted) => null,

	status: (fx, netdev) => {
		let mbim = mbim_enabled(fx);

		return {
			nss_shim: fx.exists('/sys/module/rmnet_nss') ? 'loaded' : 'absent',
			framing: mbim ? 'mbim' : 'qmap',
			qmap_mode: qmap_mode(fx, netdev),
			qmap_size: num_attr(fx, vendor_attr(netdev, 'qmap_size')) || null,
			mbim_session_base: mbim ? mbim_base(fx, netdev) : null,
		};
	},

	// adopt, then rename onto the context's stable name — netifd binds
	// `option device` to that, and the NSS context is keyed on the netdev
	links: (fx, ctx) => {
		let out = [];
		let have = qmap_mode(fx, ctx.netdev);

		for (let entry in ctx.mux) {
			let from = vendor_child(ctx.netdev, entry.id);
			let child = ctx.child_name(entry);

			if (!fx.exists(sprintf('/sys/class/net/%s', from))) {
				// Already renamed by an earlier run. The driver copies the
				// parent's MAC and then overwrites the LAST octet with the
				// channel number, so — unlike the USB sibling — identity here is
				// the first five octets, not the whole address.
				if (fx.exists(sprintf('/sys/class/net/%s', child))) {
					// first five octets: the driver copies the parent's address
					// and overwrites the LAST one with the channel number. An
					// all-zero address is the raw-IP default and identifies
					// nothing, so it is refused rather than matched — otherwise
					// every 00:00:00:00:00:* device on the box qualifies.
					let pmac = mac(fx, ctx.netdev);

					if (length(pmac) >= 14 && substr(pmac, 0, 14) != '00:00:00:00:00' &&
					    substr(mac(fx, child), 0, 14) == substr(pmac, 0, 14)) {
						ctx.mux_mtus[child] = entry.mtu;
						push(out, child);
					}
					else {
						fx.log('err', sprintf('rmnet_nss_mhi: %s exists but is not a child of %s — channel %d left unclaimed rather than binding the wrong device',
							child, ctx.netdev, entry.id));
					}

					continue;
				}

				if (entry.id > have)
					fx.log('err', sprintf('rmnet_nss_mhi: channel %d needs qmap_mode >= %d but pcie_mhi was loaded with %d — raise it in modprobe.d (module parameter, fixed at insmod)',
						entry.id, entry.id, have));
				else
					fx.log('err', sprintf('rmnet_nss_mhi: neither %s nor %s exists though qmap_mode is %d — an earlier configuration renamed this channel, and only a pcie_mhi reload restores it',
						from, child, have));

				continue;
			}

			if (child != from) {
				if (fx.exists(sprintf('/sys/class/net/%s', child))) {
					fx.log('err', sprintf('rmnet_nss_mhi: cannot give %s the name %s — it is taken by another device; channel %d left unclaimed',
						from, child, entry.id));
					continue;
				}

				if (!ctx.link('rmnet_nss_mhi rename', from, { rename: child })) {
					fx.log('err', sprintf('rmnet_nss_mhi: renaming %s to %s failed; channel %d left unclaimed',
						from, child, entry.id));
					continue;
				}
			}

			ctx.mux_mtus[child] = entry.mtu;
			push(out, child);
		}

		return out;
	},
};
