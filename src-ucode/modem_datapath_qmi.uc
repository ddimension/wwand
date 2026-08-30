// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI datapath bring-up (extracted from the modem.uc mega-closure).
//
// setup(self, dp, { log, fail }, next): negotiate the WDA data format
// (QMAP/QMAPv5 with rmnet-first checksum-offload and plain-QMAP fallback,
// board/model-clamped aggregation size) and build the kernel datapath
// (netlink.setup: rmnet/qmimux children, MTU, UL aggregation). Stores the
// result on self.datapath ({ backend, v5, parent, urb_size, mux_devs,
// map_ids, wda, ul_agg, ep_id, ep_type }) — note `parent`, not `netdev`: the
// name can move when a mux child claims the stable one, and a reader that
// looked for `netdev` here silently got nothing. Calls next(); every failure
// goes through the shared
// fail(stage, err) (recovery-ladder aware). Skips gracefully on modems
// without netdev/WDA when no mux is required.

'use strict';

import * as netlink from 'wwand.netlink';
import * as wdamod from 'wwand.codec.schema.wda';

// QMAP aggregation maxima offered to the modem in SET_DATA_FORMAT: downlink
// datagrams per aggregate (matches the qmi_wwan/rmnet driver default) and the
// uplink batch the host may send (the modem echoes what it actually honors).
const DL_MAX_DATAGRAMS = 32;
const UL_MAX_DATAGRAMS = 11;

export function setup(self, dp, o, next)
{
	let log = o.log, fail = o.fail;

		self.set_state('INIT_DATAPATH');

		// Whether this config HAS channels — the only thing that makes a missing
		// mux backend fatal.
		let need_mux = length(dp.mux_links ?? []) > 0;

		// ...and the probes run either way. Asking the datapaths to identify
		// themselves costs a few sysfs lookups and is how an accelerated
		// datapath (rmnet_nss on an ipq807x with NSS) gets to claim the box at
		// all; gating the probe on "this config already has channels" meant it
		// never ran where nobody writes `option mux`. A backend selected with no
		// channels to build falls back to raw_ip in netlink.setup(), so this is
		// safe rather than merely optimistic.
		let want_mux = true;

		if (!dp.netdev) {
			if (need_mux)
				return fail('datapath', { error: 'netdev_unknown' });

			log('info', 'netdev unknown, skipping datapath setup');
			return next();
		}

		// modems without WDA keep their default framing (old behavior:
		// "no wda support, skipping data format switch")
		if (!self.services[sprintf('%d', wdamod.default.service)]) {
			if (need_mux)
				return fail('datapath', { error: 'wda_unavailable_for_mux' });

			log('info', 'no wda service, skipping data format setup');
			return next();
		}

		self.alloc(wdamod.default, (err, wda) => {
			if (err)
				return fail('alloc_wda', err);

			self.wda = wda;

			let fxi = dp.fx ?? netlink.default_fx((level, msg) => log(level, msg));
			let backend = netlink.select_backend(fxi, dp.netdev, dp.mux ?? 'auto',
				want_mux, dp.plugins, { model: self.info?.model, proto: 'qmi' });

			// Nothing claimed the box, or `option mux` named a package that is not
			// installed. Fatal only when channels were actually configured —
			// otherwise the plain raw-IP parent is exactly what this modem wanted,
			// and it is what an unmuxed modem got before the probes ran at all.
			if (backend == null) {
				if (need_mux)
					return fail('datapath', { error: 'mux_backend_unavailable', mux: dp.mux });

				backend = 'raw_ip';
			}

			let dgram = netlink.board_dgram_size(fxi, dp.dgram_size, self.info.model);
			// QMAP header version → the WDA aggregation-protocol value. The
			// ladder is the datapath's own (rmnet: v5, v4, plain), capped by
			// `option qmap_version` when the operator pins one — which is also
			// how a specific version gets exercised on hardware.
			const DAP_FOR = { '5': wdamod.DAP_QMAPV5, '4': wdamod.DAP_QMAPV4,
			                  '1': wdamod.DAP_QMAP };
			// what this datapath can do, asked of the datapath instead of
			// inferred from its name — the name tests here covered the built-in
			// rmnet and silently excluded every datapath added since
			let caps = netlink.datapath_caps(backend, dp.plugins);
			// forward-declared: negotiate() walks this ladder from inside its own
			// body, and ucode does not hoist a `let` to where an earlier arrow
			// can see it
			let rungs = [];
			let negotiate;

			// rmnet supports MAPv5 checksum offload; try it first there and
			// renegotiate plain QMAP when the modem rejects it (some answer
			// a v5 request with aggregation fully disabled)
			negotiate = (dap, ver) => {
				let args = { qos: 0, llp: wdamod.LLP_RAW_IP };

				if (caps.qmap) {
					args.ul_protocol = dap;
					args.dl_protocol = dap;
					args.dl_max_datagrams = DL_MAX_DATAGRAMS;
					args.dl_max_size = dgram;
					// safe even when host-side UL aggregation stays off — the
					// modem then simply receives single-datagram frames
					args.ul_max_datagrams = UL_MAX_DATAGRAMS;
					args.ul_max_size = dgram;
				}

				if (dp.ep_id != null)
					args.endpoint = { type: dp.ep_type ?? wdamod.ENDPOINT_TYPE_HSUSB, iface: dp.ep_id };

				wda.request('SET_DATA_FORMAT', args, (werr, wdata) => {
					if (werr)
						return fail('wda_format', werr);

					// name the version, do not make the reader decode the enum:
					// "aggregation 9/9" is only meaningful if you know 9 is v5.
					log('info', sprintf('wda format negotiated: QMAP v%d (proto %d) ul/dl, llp %d, dl max %d x %d bytes, ul max %d x %d bytes (requested v%d / proto %d, %d bytes)',
						ver, wdata.dl_protocol ?? 0, wdata.llp,
						wdata.dl_max_datagrams ?? 0, wdata.dl_max_size ?? 0,
						wdata.ul_max_datagrams ?? 0, wdata.ul_max_size ?? 0,
						ver, dap, dgram));

					// accepted only if the modem echoed the version we asked for:
					// a different one is a version we cannot drive (rmnet has no
					// flags for v2/v3), so it is treated as a refusal.
					//
					// Both directions are checked, because both are configured
					// from this one answer: dl drives the rmnet ingress flags, ul
					// the egress ones and the uplink coalescing. A modem echoing
					// dl=9 but ul=5 would otherwise be recorded as v5 and get v5
					// egress framing it never agreed to. An ABSENT ul_protocol is
					// not a mismatch — some modems omit the TLV — so it is only
					// compared when the modem actually sent one.
					let ul_ok = (wdata.ul_protocol == null) || (wdata.ul_protocol == dap);
					let aggr_ok = !caps.qmap ||
						(wdata.dl_protocol == dap && ul_ok &&
						 (wdata.dl_max_size ?? 0) > 0);

					if (caps.qmap && wdata.dl_protocol == dap && !ul_ok)
						log('notice', sprintf('modem echoed dl proto %d but ul proto %d — not the symmetric v%d it was asked for',
							wdata.dl_protocol ?? 0, wdata.ul_protocol, ver));

					if (!aggr_ok && length(rungs)) {
						let next_v = shift(rungs);

						log('notice', sprintf('modem rejected aggregation protocol %d, trying qmap v%d',
							dap, next_v));
						return negotiate(DAP_FOR[sprintf('%d', next_v)], next_v);
					}

					if (!aggr_ok)
						return fail('wda_format', { error: 'aggregation_rejected', echo: wdata });

					let v5 = (ver == 5);

					// the modem may clamp the aggregation size; follow it
					let r = netlink.setup(fxi, {
						netdev: dp.netdev,
						backend: backend,
						// the add-on datapaths the daemon loaded (the named one,
						// or all installed ones under 'auto'); setup() picks the
						// implementation for the backend chosen above
						plugins: dp.plugins,
						qmap_version: ver,
						v5: v5,   // derived; for add-ons written before v4
						mux: map(dp.mux_links ?? [], (e) => ({
							id: e.id,
							name: e.name ?? sprintf('%sm%d', dp.netdev, e.id),
							mtu: e.mtu,
						})),
						dgram_size: (wdata.dl_max_size > 0) ? wdata.dl_max_size : dgram,
						mtu: dp.mtu,
						// negotiated uplink aggregation maxima (item 3: host-side
						// rmnet egress coalesce, best-effort where supported)
						ul_agg: { count: wdata.ul_max_datagrams ?? 0, size: wdata.ul_max_size ?? 0 },
					});

					if (!r.ok)
						return fail('datapath', r);

					// A version change while a data session is UP is accepted by
					// SET_DATA_FORMAT but not acted on: HW-observed on the
					// RG650E, where v5 -> v1 left the downlink silent — nothing
					// reached even the USB parent, so it is upstream of rmnet and
					// not a demux problem. The modem latches the aggregation
					// format while a session is active. Taking every context on
					// the modem down is enough (HW-verified); a modem reset also
					// works but is the bigger hammer. Say which, rather than
					// leave the operator with a datapath reporting the new
					// version while no traffic flows.
					let was = self.datapath?.qmap_version;

					if (caps.qmap && was != null && was != ver)
						log('notice', sprintf('QMAP version changed v%d -> v%d while a session was up; the modem latches the format until every context on it goes down (ifdown), so bring them down and back up if the data session stays silent',
							was, ver));

					self.datapath = {
						// what setup() ACTUALLY ran: it drops to raw_ip when the
						// selected backend has no channels to build
						backend: r.backend ?? backend,
						// config channel -> the QMAP id the modem must tag it
						// with. Equal unless the datapath adopts a driver's own
						// children (see map_id in netlink.uc); context.uc binds
						// WDS to this, not to the config number.
						map_ids: r.map_ids,
						// the QMAP header version actually negotiated (1|4|5),
						// and null where QMAP is not on the wire at all: the
						// ladder falls back to rung 1 for a datapath that has no
						// versions to offer (raw_ip), and reporting that as
						// "QMAP v1" would describe a header nobody sends.
						// `v5` stays for everything reading the old boolean
						qmap_version: caps.qmap ? ver : null,
						v5: v5,
						urb_size: r.urb_size,
						mux_devs: r.mux_devs,
						// netlink.setup may move the parent to a raw kernel
						// name (freeing a stale L3 name for a mux child)
						parent: r.parent ?? dp.netdev,
						ep_id: dp.ep_id,
						ep_type: dp.ep_type,
						// the WDA data-aggregation the modem actually negotiated
						// (what makes muxing/aggregation observable in status)
						wda: {
							dl_protocol: wdata.dl_protocol,
							ul_protocol: wdata.ul_protocol,
							dl_max_size: wdata.dl_max_size,
							dl_max_datagrams: wdata.dl_max_datagrams,
							ul_max_size: wdata.ul_max_size,
							ul_max_datagrams: wdata.ul_max_datagrams,
						},
						// host-side uplink aggregation we asked the datapath to coalesce
						ul_agg: (caps.tx_aggr &&
						         (wdata.ul_max_datagrams ?? 0) > 1) ?
							{ size: wdata.ul_max_size, count: wdata.ul_max_datagrams } : null,
					};

					// always name the version — it used to appear only for v5,
					// so "datapath: rmnet" left you guessing between v1 and v4
					log('notice', sprintf('datapath: %s%s%s, mux [%s]',
						backend, caps.qmap ? sprintf('/qmap v%d', ver) : '',
						(r.urb_size != null) ? sprintf(', urb %d', r.urb_size) : '',
						join(' ', r.mux_devs)));
					next();
				});
			};

			// MAPv5 first where the datapath carries checksum offload, with the
			// plain-QMAP fallback for modems that answer v5 with aggregation off
			// the versions to try, best first: what the datapath can drive,
			// capped by an explicit `option qmap_version`
			let want = +(dp.qmap_version ?? 0);

			rungs = filter(caps.qmap_versions, (v) => !want || v <= want);

			if (!length(rungs))
				rungs = [ 1 ];

			let first = shift(rungs);

			negotiate(DAP_FOR[sprintf('%d', first)], first);
		});
};
