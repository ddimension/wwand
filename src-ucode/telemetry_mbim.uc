// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — MBIM telemetry (signal / cells / CA / data-mode / registration
// detail + the slow log loop and the fast watch loop).
//
// Extracted from the modem_mbim.uc mega-closure (maintainability audit),
// mirroring telemetry_qmi.uc: install(self, { log, emit }) attaches the
// _refresh_* methods, watch and _start_telemetry to the modem object and
// returns { stop } for teardown.
//
// Every capability picks its transport per modem via backend.choose(). For the
// live telemetry (signal / cells / data-mode / reg-detail) the QMI-over-MBIM
// passthrough is preferred, then native MBIM (MS Basic Connect Extensions),
// then AT: the passthrough reuses the battle-tested QMI decode and — HW-shown
// on the EG06 — yields far richer data (RSRP/SNR, full serving + neighbour
// cells) than this modem's native MBIM (rssi-only signal, sparse cells). Native
// MBIM is the fallback for modems without a working passthrough. Capabilities
// that don't depend on the live transport are native-first regardless:
// caps.rats from MBIM DEVICE_CAPS, the current RAT from dsd_status — so they
// work even with no passthrough and a dead AT port (see modem_common).

'use strict';

import * as uloop from 'uloop';
import * as tlv from 'wwand.codec.tlv';
import * as backend from 'wwand.backend';
import * as qmi_backend from 'wwand.qmi_backend';
import * as mbim_backend from 'wwand.mbim_backend';
import * as modem_common from 'wwand.modem_common';
import * as atcmd from 'wwand.atcmd';
import * as bc from 'wwand.codec.mbim_schema.basic_connect';

export function install(self, o)
{
	let log = o.log, emit = o.emit;
	let telemetry_timer = null;
	let telem_watch;

	// signal: prefer the QMI passthrough (GET_SIGNAL_INFO — reuses the battle-
	// tested QMI decode), then native MBIMEx v2 Signal State as a fallback for
	// modems without the passthrough. (The native MS-ext buffer decode is not yet
	// validated against real-HW buffers — on the EG06 it returned only rssi with
	// null rsrp/rsrq/snr and misaligned cells, while the passthrough is correct.)
	// Stores self.signal (QMI GET_SIGNAL_INFO shape).
	self._refresh_signal = function(cb) {
		cb = cb ?? (() => null);

		backend.choose(self, '_sig_be', [
			{ name: 'qmi', probe: (ok) => self._ensure_pt((up) => up
				? self.pt.nas.request('GET_SIGNAL_INFO', {},
					(e, d) => ok(!e && tlv.has_payload(d)), { no_recovery: true })
				: ok(false)) },
			{ name: 'mbim', probe: (ok) => self.mbim
				? mbim_backend.get_signal(self.mbim, (s) => ok(s != null))
				: ok(false) },
		], (be) => {
			if (be == 'mbim')
				return mbim_backend.get_signal(self.mbim, (s) => { if (s) self.signal = s; cb(); });

			if (be == 'qmi')
				return self.pt.nas.request('GET_SIGNAL_INFO', {}, (e, d) => {
					if (!e && tlv.has_payload(d))
						self.signal = d;
					cb();
				}, { no_recovery: true });

			cb();
		});
	};

	// cells: passthrough NAS cell-location info (decoded + scrubbed exactly as the
	// QMI backend — richest serving + neighbour detail), else native MBIM Base
	// Stations Info, else a best-effort AT QENG serving cell. Stores self.cells,
	// preserving any carrier-aggregation set.
	self._refresh_cells = function(cb) {
		cb = cb ?? (() => null);

		let ca = self.cells?.ca;
		let store = (c) => {
			if (c) {
				if (ca != null)
					c.ca = ca;
				// carry the AT-QENG serving detail (LTE/NR band + bandwidth)
				// forward: MBIM's fast loop refreshes cells but not the serving
				// detail, so without this the band flickers out during 1 s polling
				modem_common.preserve_serving(c, self.cells);
				self.cells = c;
			}
			cb();
		};

		backend.choose(self, '_cells_be', [
			{ name: 'qmi', probe: (ok) => self._ensure_pt((up) => up
				? self.pt.nas.request('GET_CELL_LOCATION_INFO', {},
					(e, d) => ok(!e && tlv.has_payload(d)), { no_recovery: true })
				: ok(false)) },
			{ name: 'mbim', probe: (ok) => self.mbim
				? mbim_backend.get_cells(self.mbim, (c) => ok(c != null))
				: ok(false) },
			{ name: 'at', probe: (ok) => ok(!!self.at) },
		], (be) => {
			if (be == 'mbim')
				return mbim_backend.get_cells(self.mbim, (c) => store(c));

			if (be == 'qmi')
				return self.pt.nas.request('GET_CELL_LOCATION_INFO', {}, (e, d) =>
					store((!e && tlv.has_payload(d)) ? modem_common.clean_cell_metrics(d) : null),
					{ no_recovery: true });

			if (be == 'at')
				return modem_common.telemetry_at(self).send('AT+QENG="servingcell"', (e, r) => {
					let serving = e ? null : atcmd.parse_qeng_servingcell(r?.lines);
					store(serving ? { serving: serving } : null);
				});

			cb();
		});
	};

	// carrier aggregation: passthrough NAS GET_LTE_CPHY_CA_INFO, else AT+QCAINFO
	// (no native MBIM CA CID). Stores self.cells.ca. Mirrors the CA fetch in
	// telemetry_qmi.uc.
	self._refresh_ca = function(cb) {
		cb = cb ?? (() => null);

		if (!self.cells)   // nowhere to hang CA yet
			return cb();

		let store = (ca) => { if (self.cells) self.cells.ca = ca ?? []; cb(); };

		backend.choose(self, '_ca_be', [
			{ name: 'qmi', probe: (ok) => self._ensure_pt((up) => up
				? qmi_backend.get_ca(self.pt.nas, (ca) => ok(ca != null))
				: ok(false)) },
			{ name: 'at', probe: (ok) => ok(!!self.at) },
		], (be) => {
			if (be == 'qmi')
				return qmi_backend.get_ca(self.pt.nas, (ca) => store(ca ?? []));

			if (be == 'at')
				return modem_common.telemetry_at(self).send('AT+QCAINFO', (e, r) =>
					store(e ? [] : atcmd.parse_qcainfo(r?.lines)));

			store([]);
		});
	};

	// data-system mode (LTE/NSA/SA): passthrough DSD, else the native MBIM
	// register-state class mask, else the AT QENG serving detail. Stores
	// self.dsd_status.
	self._refresh_data_mode = function(cb) {
		cb = cb ?? (() => null);

		backend.choose(self, '_dsd_be', [
			{ name: 'qmi', probe: (ok) => self._ensure_pt((up) => (up && self.pt.dsd)
				? qmi_backend.get_data_mode(self.pt.dsd, (m) => ok(m != null))
				: ok(false)) },
			{ name: 'mbim', probe: (ok) => self.mbim
				? mbim_backend.get_data_mode(self.mbim, (m) => ok(m != null))
				: ok(false) },
			{ name: 'at', probe: (ok) => ok(self.cells?.serving?.lte != null ||
			                                self.cells?.serving?.nr != null) },
		], (be) => {
			let tag = (s) => { if (s) s.source = be; return s; };

			if (be == 'mbim')
				return mbim_backend.get_data_mode(self.mbim, (m) => { self.dsd_status = tag(m); cb(); });

			if (be == 'qmi')
				return qmi_backend.get_data_mode(self.pt.dsd, (m) => { self.dsd_status = tag(m); cb(); });

			if (be == 'at')
				self.dsd_status = tag(modem_common.dsd_from_serving(self.cells?.serving));

			cb();
		});
	};

	// registration detail (reject cause / limited service): passthrough NAS
	// system-info, else the native MBIM register state. Stores self.reg_detail.
	self._refresh_reg_detail = function(cb) {
		cb = cb ?? (() => null);

		backend.choose(self, '_regd_be', [
			{ name: 'qmi', probe: (ok) => self._ensure_pt((up) => up
				? qmi_backend.get_reg_detail(self.pt.nas, (d) => ok(d != null))
				: ok(false)) },
			{ name: 'mbim', probe: (ok) => self.mbim
				? mbim_backend.get_reg_detail(self.mbim, (d) => ok(d != null))
				: ok(false) },
		], (be) => {
			if (be == 'mbim')
				return mbim_backend.get_reg_detail(self.mbim, (d) => { if (d) self.reg_detail = d; cb(); });

			if (be == 'qmi')
				return qmi_backend.get_reg_detail(self.pt.nas, (d) => { if (d) self.reg_detail = d; cb(); });

			cb();
		});
	};

	// serving-cell band/bandwidth over AT +QENG. Neither the native MBIM cell
	// info nor the QMI-passthrough GET_CELL_LOCATION_INFO carries the LTE/NR band,
	// so read it separately over AT — UNCONDITIONALLY, not only when AT happens to
	// win the cells/data-mode choose (on a modem with a working passthrough the
	// AT branch there never runs, so serving.band was never populated). Slow-loop
	// only; preserve_serving() then carries it across the band-less 1 s cell
	// refreshes. Latches off on a dead AT port (EG06) via telemetry_at. Stores
	// self.cells.serving.
	self._refresh_serving = function(cb) {
		cb = cb ?? (() => null);

		if (!self.at || !self.cells || !modem_common.qeng_ok(self))
			return cb();

		modem_common.telemetry_at(self).send('AT+QENG="servingcell"', (e, r) => {
			if (!e && self.cells) {
				let s = atcmd.parse_qeng_servingcell(r?.lines);
				if (s && (s.lte || s.nr))
					self.cells.serving = s;
			}
			cb();
		});
	};

	let emit_telemetry = () => emit('telemetry', { signal: self.signal, cells: self.cells, reg: self.reg });

	let log_telemetry = () => {
		log('notice', sprintf('telemetry: %s', modem_common.format_telemetry(self)));
	};

	// Fast "watch" loop: while a consumer polls modem_signal/modem_cells, refresh
	// the LuCI-visible data (signal + cells + CA) at most once a second,
	// non-overlapping so the cadence stretches when the modem is busy. Reverts to
	// the slow telemetry timer after polling stops. The adaptive cadence lives in
	// modem_common.watch_driver (shared with the QMI backend); this is just the
	// MBIM refresh body. done() is called exactly once per cycle (finish or bail).
	let refresh_fast = (done) => {
		self._refresh_signal(() => {
			if (!self.mbim)
				return done();

			self._refresh_cells(() => self._refresh_ca(() => {
				// vendor-neutral serving band/bandwidth from the CA-info PCC (over
				// the passthrough) — works on any MBIM modem, not just Quectel-AT
				modem_common.serving_from_ca(self);
				// EARFCN/NR-ARFCN -> band for band-less transports (native MBIM on
				// Intel/MediaTek: no QENG, no CA-info) — only fills when unset, so
				// the CA-info band above always wins.
				modem_common.fill_serving_band(self);
				modem_common.fetch_nr_neighbours(self, () => {
					emit_telemetry();
					done();
				});
			}));
		});
	};

	telem_watch = modem_common.watch_driver({
		alive:   () => self.mbim != null,
		ready:   () => self.state == 'READY',
		refresh: refresh_fast,
	});

	// called by the daemon whenever modem_signal / modem_cells is queried
	self.watch = () => telem_watch.watch();

	// Slow telemetry loop (the stats interval): the baseline v1 SIGNAL_STATE
	// query (kept working for modems without V2 / passthrough) plus the richer
	// signal, data-system mode, registration detail and cells — so the periodic
	// telemetry log line is as complete as QMI's (the passthrough serves cells
	// via NAS GET_CELL_LOCATION_INFO just like the QMI backend).
	self._start_telemetry = function() {
		if (telemetry_timer)
			return;

		let interval = +(self.config.stats_interval ?? 60) * 1000;

		if (interval <= 0)
			return;

		let tick;

		tick = () => {
			if (!self.mbim)
				return;

			// v1 RSSI floor first, then let the rich per-RAT refresh overwrite it
			self.mbim.command(bc, 'SIGNAL_STATE', 'query', {}, (err, data) => {
				if (!err && !self.signal?.lte && !self.signal?.nr5g) {
					let dbm = (data.rssi != null && data.rssi != 99)
						? (-113 + 2 * data.rssi) : null;
					self.signal = { rssi_raw: data.rssi, rssi: dbm };
				}

				self._refresh_signal(() => self._refresh_data_mode(() => self._refresh_reg_detail(() => self._refresh_cells(() => self._refresh_serving(() =>
					// modem temperature + fine access-tech/caps (IoT/RedCap)
					// over the AT side channel (best-effort, slow loop —
					// QMI/NCM parity; status `rat`/`caps` stayed null on MBIM
					// without this). Where AT is dead (EG06) both latch off
					// after the first timeout, so no per-tick re-tries.
					modem_common.collect_temperature(self, () =>
					    modem_common.probe_iot_rat(self, () => {
						if (!self.mbim)
							return;

						log_telemetry();
						emit_telemetry();
						telemetry_timer = uloop.timer(interval, tick);
					})))))));
			});
		};

		telemetry_timer = uloop.timer(min(interval, 5000), tick);
	};

	return {
		stop: () => {
			if (telemetry_timer) {
				telemetry_timer.cancel();
				telemetry_timer = null;
			}
			telem_watch.stop();
		},
	};
};
