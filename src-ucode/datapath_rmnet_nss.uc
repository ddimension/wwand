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
// What this datapath IS, precisely: the adopter for qmi_wwan_q's own QMAP
// children. NSS is what makes it worth having — and what it is named after —
// but it is not a condition for using it. The driver decides the offload by
// itself (`use_qca_nss = !!nss_cb`, captured when it creates each child, so a
// module loaded after it bound is too late), and either way these children need
// a datapath that adopts rather than creates.
//
// So the probe is the vendor signature alone. Gating it on the shim as well was
// worse than useless: on a vendor box without NSS this declined, `auto` fell
// through to mainline rmnet — whose probe a vendor parent satisfies, since it
// asks for /sys/module/rmnet and the ABSENCE of a `qmi` group — and rmnet then
// built its own children on a parent that already demuxes QMAP internally. A
// missing shim is reported instead, once, with the ordering that would fix it.

'use strict';

// where the vendor driver puts its per-netdev knobs (no `qmi` subgroup)
function vendor_attr(netdev, name)
{
	return sprintf('/sys/class/net/%s/%s', netdev, name);
}

// a netdev's MAC, for the one identity check the driver makes available
function mac(fx, netdev)
{
	return trim(fx.read(sprintf('/sys/class/net/%s/address', netdev)) ?? '');
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

	description: 'QMAP over the vendor qmi_wwan_q (Qualcomm NSS offload when the shim is loaded)',

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
	probe: (fx, netdev, info) => {
		// The children are named after the parent as it was AT DRIVER PROBE
		// TIME and never renamed afterwards, so a parent that wwand has since
		// renamed to its stable L3 name no longer shares their stem. Probing
		// only `<netdev>_1` then finds nothing and the box falls back to
		// raw_ip — on a parent that IS in QMAP framing, so no traffic can flow
		// and the interface never leaves IDLE. Self-fulfilling and silent.
		// Field-found on an IPQ807x/RG500Q NSS board (2026-09-03).
		//
		// `info.kernel_netdev` is that pre-rename name, which the daemon keeps
		// precisely because only it can answer this. No MAC guessing needed:
		// wwand did the rename and therefore knows both names.
		if (!fx.exists(sprintf('/sys/class/net/%s', vendor_child(netdev, 1))) &&
		    !(info?.kernel_netdev &&
		      fx.exists(sprintf('/sys/class/net/%s', vendor_child(info.kernel_netdev, 1)))))
			return false;

		// Claimed either way — these children need adopting, not creating. But a
		// missing shim cannot be fixed after the fact (the driver captured the
		// answer when it created them), so say so rather than let the operator
		// wonder why the offload never appeared. `status` carries the same fact
		// to the status page.
		if (!fx.exists('/sys/module/rmnet_nss'))
			fx.log('notice', sprintf('rmnet_nss: adopting the vendor QMAP channels of %s, but /sys/module/rmnet_nss is absent — no NSS offload; load rmnet_nss BEFORE qmi_wwan_q binds',
				netdev));

		return true;
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

	// ...but QMAP is very much on the wire: the parent carries aggregated frames
	// and the children the demuxed packets, so the aggregation ratio on the
	// status page means what it means everywhere else. `aggregate` is about who
	// sizes the buffers, which here is the driver.
	qmap: true,

	// MAPv5 is deliberately NOT declared. An earlier version of this file did,
	// reasoning that quectel-cm "sends 0x05" — but 0x05 is the enum value for
	// plain QMAP; v5 is 0x09. quectel-cm defaults to exactly that and raises it
	// only when the DRIVER reports v5 through rmnet_info, which it reads over an
	// ioctl this datapath has no equivalent for. So plain QMAP is what the
	// reference client does here by default, and it is what we do. A board that
	// wants v5 needs the driver's answer, not a guess from us.

	// The children belong to the KERNEL: only a qmi_wwan_q reload creates or
	// removes them. Never prune.
	//
	// Note what this is NOT protecting against. The shared prune matches a child
	// by its `iflink` pointing at the parent, and these children do not report
	// one — the driver sets no ndo_get_iflink and does not link them as an upper
	// device, so iflink is each child's own ifindex. The default would therefore
	// find nothing to delete rather than delete the wrong thing. This override
	// makes the intent explicit and keeps it true if that ever changes.
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

		// Same reason as in probe(): after a parent rename the children still
		// carry the kernel's original stem, so look for them under that name
		// when the current one yields nothing.
		let stem = ctx.netdev;

		if (!fx.exists(sprintf('/sys/class/net/%s', vendor_child(stem, 1))) &&
		    ctx.opts?.netdev_kernel &&
		    fx.exists(sprintf('/sys/class/net/%s', vendor_child(ctx.opts.netdev_kernel, 1))))
			stem = ctx.opts.netdev_kernel;

		for (let entry in ctx.mux) {
			let from = vendor_child(stem, entry.id);
			let child = ctx.child_name(entry);

			if (!fx.exists(sprintf('/sys/class/net/%s', from))) {
				// A restart that already renamed it. Adoption is by NAME here,
				// which a name alone cannot justify, so take the one identity
				// the driver gives us: it copies the parent's MAC onto every
				// child (__dev_addr_set(qmap_net, real_dev->dev_addr)). That
				// proves nothing about WHICH parent when both are raw-IP
				// devices with an all-zero address, but it does reject an
				// ordinary netdev that happens to carry this name.
				if (fx.exists(sprintf('/sys/class/net/%s', child))) {
					if (mac(fx, child) == mac(fx, ctx.netdev)) {
						ctx.mux_mtus[child] = entry.mtu;
						push(out, child);
					}
					else {
						fx.log('err', sprintf('rmnet_nss: %s exists but is not a child of %s (different MAC) — channel %d left unclaimed rather than binding the wrong device',
							child, ctx.netdev, entry.id));
					}

					continue;
				}

				// Two different causes, two different fixes, so say which.
				if (entry.id > have)
					fx.log('err', sprintf('rmnet_nss: channel %d needs qmap_mode >= %d but qmi_wwan_q was loaded with %d — raise it in modprobe.d (it is a module parameter, fixed at insmod)',
						entry.id, entry.id, have));
				else
					fx.log('err', sprintf('rmnet_nss: neither %s nor %s exists though qmap_mode is %d — an earlier configuration renamed this channel to a name it no longer uses, and only a qmi_wwan_q reload restores it',
						from, child, have));

				continue;
			}

			// Never rename onto an occupied name: the rename fails, and pushing
			// the target anyway would report a device we do not own — the shared
			// code would then set the MTU on it and netifd bind to it, with the
			// real channel left unclaimed. (The parent holding the name is
			// handled before links() runs; this is anything else.)
			if (child != from) {
				if (fx.exists(sprintf('/sys/class/net/%s', child))) {
					fx.log('err', sprintf('rmnet_nss: cannot give %s the name %s — it is taken by another device; channel %d left unclaimed',
						from, child, entry.id));
					continue;
				}

				if (!ctx.link('rmnet_nss rename', from, { rename: child })) {
					fx.log('err', sprintf('rmnet_nss: renaming %s to %s failed; channel %d left unclaimed',
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
