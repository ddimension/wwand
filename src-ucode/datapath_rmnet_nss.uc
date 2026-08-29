// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — datapath add-on: Qualcomm NSS offload behind the vendor qmi_wwan_q.
//
// On a QSDK/NSS build (ipq807x and friends) the modem datapath is offloaded to
// the NSS cores. The attach point is a global callback contract: rmnet_nss
// publishes `struct rmnet_nss_cb *rmnet_nss_callbacks`, and the VENDOR
// qmi_wwan_q driver calls `nss_cb->nss_create(qmap_net)` on each QMAP netdev it
// creates. Mainline rmnet has no such call, so wwand's built-in rmnet/qmimux
// datapaths produce children that never reach the NSS shim — traffic forwards,
// but on the CPU.
//
// So this datapath creates nothing. The children already exist: qmi_wwan_q
// registers them in its USB probe, one per `qmap_mode` (a module parameter,
// S_IRUGO — fixed at insmod, there is no runtime knob). wwand's job is to adopt
// them and let the shared code do MTU, link up and the per-channel link_state
// gate.
//
// Everything below is keyed to what that driver actually does, because none of
// it can be guessed:
//
//   * Naming. `sprintf(name, "%s_%d", real_dev->name, offset_id + 1)` — so the
//     children are wwan0_1 … wwan0_N, not the wwan0mN of the built-ins.
//   * QMAP ids. `priv->mux_id = QUECTEL_QMAP_MUX_ID + offset_id` with
//     QUECTEL_QMAP_MUX_ID = 0x81. Channel 1 is therefore 0x81 ON THE WIRE, and
//     the driver drops anything else ("drop qmap unknow mux_id"). quectel-cm
//     agrees: `profile.muxid = <digit> + 0x80`. Hence map_id below — binding
//     WDS to the config number would silently kill every downlink frame.
//   * Sysfs. The driver's attribute group carries NO `.name`, so `qmap_mode`,
//     `qmap_size` and `link_state` sit DIRECTLY on the netdev — there is no
//     `qmi/` group at all, and therefore no raw_ip, no pass_through, no
//     add_mux and no rx_urb_size. Nothing for us to program: the driver sets
//     `dev->rx_urb_size = qmap_size` itself at bind.
//   * link_state. On the PARENT, read/write, `offset_id = (link_state & 0x7F) - 1`
//     and the 0x80 bit CLEARS. quectel-cm writes the same thing from the other
//     side — `(link_state ? 0x00 : 0x80) + (muxid - 0x80)`, and its muxid is
//     0x80 + channel — so both agree the value is the channel number. That is
//     what wwand's shared code already writes; on mainline the node does not
//     exist and the write no-ops. It matters on 5G modems: the driver starts
//     them with `link_state = !lte_a`, i.e. carrier off until someone writes.
//
// Availability is gated on rmnet_nss being LOADED, not merely installed, and
// that is not pedantry: qmi_wwan_q captures `use_qca_nss = !!nss_cb` when it
// creates each child, so a module loaded after the modem's driver bound is too
// late — the children exist without an NSS context. An installed-but-unloaded
// rmnet_nss is reported rather than claimed, since claiming it would hand back
// a datapath with no offload and no way to tell.

'use strict';

// where the vendor driver puts its per-netdev knobs (no `qmi` subgroup)
function vendor_attr(netdev, name)
{
	return sprintf('/sys/class/net/%s/%s', netdev, name);
}

// the name qmi_wwan_q gives channel `id`: sprintf("%s_%d", real_dev->name,
// offset_id + 1), so channel 1 is <parent>_1
function vendor_child(netdev, id)
{
	return sprintf('%s_%d', netdev, id);
}

// how many QMAP children qmi_wwan_q registered for this parent, 0 if it is not
// that driver. `qmap_mode` is the module parameter it was loaded with.
function qmap_mode(fx, netdev)
{
	let v = fx.read(vendor_attr(netdev, 'qmap_mode'));

	return v ? +trim(v) : 0;
}

return {
	proto: [ 'qmi' ],

	description: 'QMAP over the vendor qmi_wwan_q with Qualcomm NSS offload',

	// Specific on purpose (the contract asks for it), and keyed on what is
	// actually observable rather than on what `qmap_mode` implies.
	//
	// `qmap_mode > 0` is NOT the same as "there are children to adopt".
	// qmi_wwan_q only registers them when `use_rmnet_usb` is set, which it turns
	// on for qmap_mode > 1 and for three idProducts; with qmap_mode == 1 on
	// anything else the PARENT carries the QMAP itself (mpQmapNetDev[0] =
	// dev->net) and no child exists — and no nss_create() is called either.
	// The vendor's own dialer script tests exactly this, falling back to the
	// bare parent when `<netdev>_1` is missing, so that is the discriminator
	// used here. It also rules out mainline qmi_wwan, whose knobs live under
	// `qmi/` and which never creates such a child.
	probe: (fx, netdev) => {
		if (!fx.exists(sprintf('/sys/class/net/%s', vendor_child(netdev, 1))))
			return false;

		if (fx.exists('/sys/module/rmnet_nss'))
			return true;

		// The vendor driver is here with channels, but the NSS shim is not — and
		// it cannot be fixed after the fact: qmi_wwan_q captures whether NSS is
		// available at the moment it creates each child, so a modprobe now would
		// leave them without an NSS context and nothing would say so. Say it
		// once, here, rather than let the operator wonder why nothing changed.
		fx.log('notice', sprintf('rmnet_nss: %s has vendor QMAP channels but /sys/module/rmnet_nss is absent — load rmnet_nss BEFORE qmi_wwan_q binds to get the offload; not claiming this datapath',
			netdev));

		return false;
	},

	// The name the child ends up with: the context's stable wwandN when the
	// config names one, because that is what netifd binds `option device` to —
	// an adopted child left as wwan0_1 would leave the interface unclaimed. The
	// vendor's own name is only where it STARTS (see links()); qmimux does the
	// same dance with its qmimuxN.
	child_name: (netdev, entry) => entry.name ?? vendor_child(netdev, entry.id),

	// ...and the id the modem must tag it with, which is the driver's, not the
	// config's: priv->mux_id = QUECTEL_QMAP_MUX_ID(0x81) + offset_id, i.e.
	// 0x80 + channel. Written as the driver's arithmetic rather than as a bit
	// set, which only happens to agree while the channel stays below 128.
	map_id: (entry) => 0x80 + entry.id,

	// no driver format to program (there is no `qmi` sysfs group) and therefore
	// no reason to bounce the parent — which matters here more than elsewhere:
	// these children survive a wwand restart, and the parent must stay up for
	// them (qmap_open() returns -ENETDOWN while it is down).
	programs_parent: false,

	// the driver sized its own RX buffers from qmap_size at bind and exposes no
	// writable knob; the parent MTU is not the aggregation buffer here.
	aggregate: false,

	// The children belong to the KERNEL. The default prune removes every netdev
	// whose iflink is this parent and that the config does not name — which here
	// would delete channels only a module reload can bring back. Never prune.
	prune: (fx, netdev, wanted) => null,

	// what the status page shows beyond the generic rows: the driver's own view
	// of the datapath. All three are read-only — the channel count and buffer
	// are fixed at insmod, and the shim either published its callbacks before
	// the modem's driver bound or it did not.
	status: (fx, netdev) => {
		let size = fx.read(vendor_attr(netdev, 'qmap_size'));

		return {
			nss_shim: fx.exists('/sys/module/rmnet_nss') ? 'loaded' : 'absent',
			qmap_mode: qmap_mode(fx, netdev),
			qmap_size: size ? +trim(size) : null,
		};
	},

	// Adopt, never create — then rename onto the context's stable name, which is
	// what netifd binds to. The driver already registered these in its USB probe
	// and called nss_create() on each; renaming keeps the NSS context (it is
	// keyed on the netdev, not on its name).
	links: (fx, ctx) => {
		let out = [];
		let have = qmap_mode(fx, ctx.netdev);

		for (let entry in ctx.mux) {
			let from = vendor_child(ctx.netdev, entry.id);
			let child = ctx.child_name(entry);

			if (!fx.exists(sprintf('/sys/class/net/%s', from))) {
				// tolerate a restart that already renamed it
				if (fx.exists(sprintf('/sys/class/net/%s', child))) {
					ctx.mux_mtus[child] = entry.mtu;
					push(out, child);
					continue;
				}

				// precise, because the fix is a specific one: the channel count
				// is fixed at insmod, so this is a modprobe.d edit, not a config
				// one. Skipping (rather than failing) matches the built-ins.
				fx.log('err', sprintf('rmnet_nss: %s does not exist — qmi_wwan_q was loaded with qmap_mode=%d, so channels 1..%d exist; raise it in modprobe.d to use channel %d',
					from, have, have, entry.id));
				continue;
			}

			if (child != from)
				ctx.link('rmnet_nss rename', from, { rename: child });

			ctx.mux_mtus[child] = entry.mtu;
			push(out, child);
		}

		return out;
	},
};
