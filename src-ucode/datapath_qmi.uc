// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI datapath bring-up (extracted from the modem.uc mega-closure).
//
// setup(self, dp, { log, fail }, next): negotiate the WDA data format
// (QMAP/QMAPv5 with rmnet-first checksum-offload and plain-QMAP fallback,
// board/model-clamped aggregation size) and build the kernel datapath
// (netlink.setup: rmnet/qmimux children, MTU, UL aggregation). Stores the
// result on self.datapath ({ backend, v5, netdev, urb_size, mux_devs,
// ep_id, ep_type }) and calls next(); every failure goes through the shared
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
			let negotiate;

			// rmnet supports MAPv5 checksum offload; try it first there and
			// renegotiate plain QMAP when the modem rejects it (some answer
			// a v5 request with aggregation fully disabled)
			negotiate = (dap, allow_fallback) => {
				let args = { qos: 0, llp: wdamod.LLP_RAW_IP };

				if (backend != 'raw_ip') {
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

					log('info', sprintf('wda format negotiated: llp %d, ul/dl aggregation %d/%d, dl max %d x %d bytes, ul max %d x %d bytes (requested proto %d, %d bytes)',
						wdata.llp, wdata.ul_protocol ?? 0, wdata.dl_protocol ?? 0,
						wdata.dl_max_datagrams ?? 0, wdata.dl_max_size ?? 0,
						wdata.ul_max_datagrams ?? 0, wdata.ul_max_size ?? 0, dap, dgram));

					let aggr_ok = (backend == 'raw_ip') ||
						((wdata.dl_protocol == wdamod.DAP_QMAP ||
						  wdata.dl_protocol == wdamod.DAP_QMAPV5) &&
						 (wdata.dl_max_size ?? 0) > 0);

					if (!aggr_ok && allow_fallback && dap != wdamod.DAP_QMAP) {
						log('notice', sprintf('modem rejected aggregation protocol %d, renegotiating plain qmap', dap));
						return negotiate(wdamod.DAP_QMAP, false);
					}

					if (!aggr_ok)
						return fail('wda_format', { error: 'aggregation_rejected', echo: wdata });

					let v5 = (wdata.dl_protocol == wdamod.DAP_QMAPV5);

					// the modem may clamp the aggregation size; follow it
					let r = netlink.setup(fxi, {
						netdev: dp.netdev,
						backend: backend,
						// the add-on datapaths the daemon loaded (the named one,
						// or all installed ones under 'auto'); setup() picks the
						// implementation for the backend chosen above
						plugins: dp.plugins,
						v5: v5,
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

					self.datapath = {
						// what setup() ACTUALLY ran: it drops to raw_ip when the
						// selected backend has no channels to build
						backend: r.backend ?? backend,
						// config channel -> the QMAP id the modem must tag it
						// with. Equal unless the datapath adopts a driver's own
						// children (see map_id in netlink.uc); context.uc binds
						// WDS to this, not to the config number.
						map_ids: r.map_ids,
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
						// host-side uplink aggregation we asked rmnet to coalesce
						ul_agg: (backend == 'rmnet' &&
						         (wdata.ul_max_datagrams ?? 0) > 1) ?
							{ size: wdata.ul_max_size, count: wdata.ul_max_datagrams } : null,
					};

					log('notice', sprintf('datapath: %s%s%s, mux [%s]',
						backend, v5 ? '/qmapv5' : '',
						(r.urb_size != null) ? sprintf(', urb %d', r.urb_size) : '',
						join(' ', r.mux_devs)));
					next();
				});
			};

			negotiate((backend == 'rmnet') ? wdamod.DAP_QMAPV5 : wdamod.DAP_QMAP,
				backend == 'rmnet');
		});
};
