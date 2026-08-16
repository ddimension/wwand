// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI telemetry subsystem (extracted from the modem.uc mega-closure).
//
// install(self, o) attaches the telemetry surface to a QMI modem object:
//   self.watch()                 fast-loop trigger (daemon calls it on every
//                                modem_signal/modem_cells query)
//   self._start_telemetry()      the slow periodic cell/log tick
//   self._log_telemetry()        one telemetry log line + 'telemetry' emit
//   self._fetch_ca_info(cb)      CA carriers (QMI GET_LTE_CPHY_CA_INFO or
//                                AT+QCAINFO, cached via backend.choose)
//   self._arm_data_mode_ind()    live DSD data-system change indication
//   self._determine_data_mode(cb) NSA/SA/LTE mode (DSD -> QENG -> radio_ifs)
// and returns { stop } for modem.teardown. o = { log, emit }. All timers and
// the adaptive watch driver are owned here; state lands on the usual modem
// fields (self.signal / self.cells / self.dsd_status) so status/ubus and the
// MBIM/NCM siblings stay shape-identical.

'use strict';

import * as uloop from 'uloop';
import * as tlv from './codec/tlv.uc';
import * as backend from './backend.uc';
import * as qmi_backend from './qmi_backend.uc';
import * as modem_common from './modem_common.uc';
import * as atcmd from './atcmd.uc';


export function install(self, o)
{
	let log = o.log, emit = o.emit;
	let telemetry_timer = null;
	let telem_watch;

	// periodic telemetry: cell environment, signal, operator — the compact
	// per-interval log line replaces what the old proto handler logged during
	// setup, and the collected data feeds future lock automation
	// Fast "watch" mode: while a consumer (the LuCI status page) actively
	// polls modem_signal/modem_cells, refresh signal + cell info at most once
	// per second, non-overlapping so the cadence stretches automatically when
	// the modem is busy (load-adaptive). Reverts to the slow telemetry timer a
	// few seconds after polling stops. Signal also keeps arriving via the NAS
	// SIGNAL_INFO indication subscription between refreshes.
	const NEIGH_HOLD = 30;             // s: hold last-seen neighbours over drops

	// store a fresh GET_CELL_LOCATION_INFO result. The modem reports the intra-
	// frequency neighbour list only intermittently (a measurement cycle), so a
	// bare serving-cell-only result would make the UI neighbour list flicker in
	// and out — hold the last-seen neighbours for NEIGH_HOLD seconds instead.
	let store_cells = (data) => {
		modem_common.clean_cell_metrics(data);   // -32768 sentinels -> null before anyone reads them

		let li = data?.lte_intra;

		if (li) {
			if (length(li.cells ?? []) > 1)
				self._neigh = { cells: li.cells, scid: li.serving_cell_id, ts: time() };
			else if (self._neigh && self._neigh.scid == li.serving_cell_id &&
			         (time() - self._neigh.ts) < NEIGH_HOLD)
				li.cells = self._neigh.cells;   // carry the recent set over
		}

		// carry the AT-derived serving detail (LTE/NR band + bandwidth) forward —
		// NAS cell-location has no band; a fresh QENG read overwrites it later
		modem_common.preserve_serving(data, self.cells);

		self.cells = data;
	};

	// one fast-telemetry refresh cycle: signal first, then cells, then (while
	// watched) CA + data-system mode, then emit. Calls done() exactly once when
	// the cycle finishes or bails (channel gone) — the shared watch_driver uses
	// done() to schedule the next cycle non-overlapping. The adaptive cadence /
	// decay / teardown all live in modem_common.watch_driver now.
	let refresh_fast = (done) => {
		self.nas.request('GET_SIGNAL_INFO', {}, (serr, sdata) => {
			// keep last-known on an empty/invalid answer instead of blanking it
			if (!serr && tlv.has_payload(sdata))
				self.signal = sdata;

			if (!self.nas)
				return done();

			self.nas.request('GET_CELL_LOCATION_INFO', {}, (cerr, cdata) => {
				if (!cerr && tlv.has_payload(cdata))
					store_cells(cdata);

				let after = () => {
					if (self.cells)
						emit('telemetry', { cells: self.cells, signal: self.signal, reg: self.reg });

					done();
				};

				// per-carrier CA info, then the data-system mode (NSA/SA/LTE) —
				// both only while watched (LuCI open). Extracted into named
				// methods to keep this poll pyramid shallow.
				if (!self.cells)
					return after();

				self._fetch_ca_info(() => self._determine_data_mode(() => {
					// vendor-neutral serving band/bandwidth from the CA-info PCC —
					// after data-mode so a Quectel AT+QENG serving (exact) wins;
					// fills for every other modem that has no QENG.
					modem_common.serving_from_ca(self);
					modem_common.fetch_nr_neighbours(self, after);
				}));
			});
		});
	};

	telem_watch = modem_common.watch_driver({
		alive:   () => self.nas != null,
		ready:   () => self.state == 'READY',
		refresh: refresh_fast,
	});

	// carrier-aggregation carriers for the status page: prefer QMI
	// GET_LTE_CPHY_CA_INFO, fall back to AT+QCAINFO, cache the choice per modem
	// (RG650E answers the QMI one with INFO_UNAVAILABLE, so it settles on AT).
	// Stores self.cells.ca and calls cb().
	self._fetch_ca_info = function(cb) {
		let store = (ca) => { if (self.cells) self.cells.ca = ca ?? []; cb(); };

		backend.choose(self, '_ca_be', [
			{ name: 'qmi', probe: (ok) => self.nas
				? qmi_backend.get_ca(self.nas, (ca) => ok(ca != null))
				: ok(false) },
			{ name: 'at', probe: (ok) => ok(!!self.at) },
		], (be) => {
			if (be == 'qmi')
				return qmi_backend.get_ca(self.nas, (ca) => store(ca ?? []));
			if (be == 'at')
				return modem_common.telemetry_at(self).send('AT+QCAINFO', (e, r) =>
					store(e ? [] : atcmd.parse_qcainfo(r?.lines)));
			store([]);
		});
	};

	// settle the data-system mode (NSA/SA/LTE): refresh the QENG serving detail
	// (Quectel AT states NSA/SA directly + NR band/bandwidth/signal), then pick
	// the mode source — prefer DSD (native, precise), else that QENG NR line,
	// else the coarse NAS radio_ifs. Cached per modem; stores self.dsd_status.
	// Register for the DSD data-system change indication so LTE ↔ 5G-NSA ↔ 5G-SA
	// transitions update self.dsd_status live instead of only at the next
	// telemetry poll. Only meaningful when DSD is the active mode source (it is
	// whenever self.dsd exists — see the _dsd_be probe order below). Failure to
	// register is non-fatal: the poll in _determine_data_mode still runs.
	self._arm_data_mode_ind = function() {
		if (!self.dsd || self._dsd_ind_armed)
			return;
		self._dsd_ind_armed = true;

		self.dsd.on('SYSTEM_STATUS_IND', (data) => {
			let m = qmi_backend.data_mode_from_systems(data?.available_systems);
			if (m == null)
				return;
			m.source = 'dsd';
			let was = self.dsd_status?.mode;
			self.dsd_status = m;
			if (m.mode != was)
				log('info', sprintf('data-system changed: %s', m.mode ?? 'none'));
		});

		self.dsd.request('SYSTEM_STATUS_CHANGE', { register: 1 }, (e) => {
			if (e)
				log('debug', 'dsd system-status indication register failed (poll still active)');
		}, { no_recovery: true });
	};

	self._determine_data_mode = function(cb) {
		let set_mode = () => {
			backend.choose(self, '_dsd_be', [
				{ name: 'dsd', probe: (ok) => self.dsd
					? qmi_backend.get_data_mode(self.dsd, (m) => ok(m != null))
					: ok(false) },
				{ name: 'at',  probe: (ok) => ok(self.cells?.serving?.lte != null ||
				                                  self.cells?.serving?.nr != null) },
				{ name: 'nas', probe: (ok) => ok(!!self.reg?.radio_ifs) },
			], (be) => {
				let tag = (s) => { if (s) s.source = be; return s; };

				if (be == 'dsd')
					return qmi_backend.get_data_mode(self.dsd, (m) => {
						self.dsd_status = tag(m);
						cb();
					});
				if (be == 'at')
					self.dsd_status = tag(modem_common.dsd_from_serving(self.cells?.serving));
				else if (be == 'nas')
					self.dsd_status = tag(modem_common.dsd_from_radio(self.reg?.radio_ifs));
				cb();
			});
		};

		if (!self.at || !self.cells || !modem_common.qeng_ok(self))
			return set_mode();

		self.at.send('AT+QENG="servingcell"', (e, r) => {
			if (!e && self.cells)
				self.cells.serving = atcmd.parse_qeng_servingcell(r?.lines);
			set_mode();
		});
	};

	// called by the daemon whenever modem_signal / modem_cells is queried
	self.watch = () => telem_watch.watch();

	self._start_telemetry = function() {
		if (telemetry_timer)
			return;

		let interval = +(self.config.stats_interval ?? 60) * 1000;

		if (interval <= 0)
			return;

		// first sample soon after registration (the old handler dumped the
		// cell neighbourhood right at connect time), then at the interval
		let first = min(interval, 5000);

		let tick;

		tick = () => {
			// modem may have been torn down while a request was in flight
			if (!self.nas)
				return;

			self.nas.request('GET_CELL_LOCATION_INFO', {}, (err, data) => {
				if (!err)
					store_cells(data);
				else if (err.error != 'cancelled')
					log('warn', sprintf('telemetry: cell location query failed: %J', err));

				// modem temperature + active access-tech (IoT/RedCap) over the AT
				// side channel (best-effort, slow loop) — then log the full
				// telemetry line and reschedule
				modem_common.collect_temperature(self, () =>
				    modem_common.probe_iot_rat(self, () => {
					if (!err)
						self._log_telemetry();

					if (self.nas)
						telemetry_timer = uloop.timer(interval, tick);
				}));
			});
		};

		telemetry_timer = uloop.timer(first, tick);
	};

	self._log_telemetry = function() {
		log('notice', sprintf('telemetry: %s', modem_common.format_telemetry(self)));
		emit('telemetry', { cells: self.cells, signal: self.signal, reg: self.reg });
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
