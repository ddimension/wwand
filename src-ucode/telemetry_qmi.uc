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
import * as tlv from 'wwand.codec.tlv';
import * as backend from 'wwand.backend';
import * as qmi_backend from 'wwand.qmi_backend';
import * as modem_common from 'wwand.modem_common';
import * as atcmd from 'wwand.atcmd';


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

	// forward-declared: refresh_fast calls it from the signal-fallback path
	let strength_signal;

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
			// A cancellation is the client being destroyed, not a modem that
			// rejects the message. Falling through would submit the fallback on
			// the client mid-destruction — and that one's failure submits an AT
			// command after it.
			else if (serr?.error == 'cancelled')
				return done();
			else if (serr)
				// NAS 1.0 fallback: old stacks reject GET_SIGNAL_INFO
				// ("Invalid QMI command") but answer GET_SIGNAL_STRENGTH
				// (0x0020, the 1.0-era message — HW-observed on the E1820).
				// Fire-and-forget; on failure the CSQ floor read supplies the
				// rssi baseline. All three are OPTIONAL reads — they must not
				// feed the recovery counter on a modem that rejects them by
				// design.
				self.nas.request('GET_SIGNAL_STRENGTH', {}, (s2err, s2data) => {
					if (!s2err && tlv.has_payload(s2data)) {
						let s = strength_signal(s2data);

						if (s)
							self.signal = { ...(self.signal ?? {}), ...s };
						else
							// answered, but no entry we can map (e.g. a
							// GSM-only stack whose rssi row is not LTE) —
							// the CSQ floor still fills the generic rssi
							modem_common.telemetry_at(self).send('AT+CSQ', (aerr, ares) =>
								modem_common.sig_csq_floor(self,
									aerr ? null : modem_common.parse_csq(ares?.lines)));
					}
					else if (s2err)
						modem_common.telemetry_at(self).send('AT+CSQ', (aerr, ares) =>
							modem_common.sig_csq_floor(self,
								aerr ? null : modem_common.parse_csq(ares?.lines)));
				}, { no_recovery: true });

			if (!self.nas)
				return done();

			self.nas.request('GET_CELL_LOCATION_INFO', {}, (cerr, cdata) => {
				if (!cerr && tlv.has_payload(cdata))
					store_cells(cdata);

				let after = () => {
					// emit with cells when there are any, or with a per-RAT
					// signal alone when the modem has no cell environment at all
					// (old stacks) — the signal is what a watcher can still show
					if (self.cells || self.signal?.lte != null || self.signal?.nr5g != null)
						emit('telemetry', { cells: self.cells, signal: self.signal, reg: self.reg });

					done();
				};

				// per-carrier CA info, then the data-system mode (NSA/SA/LTE) —
				// both only while watched (LuCI open). Extracted into named
				// methods to keep this poll pyramid shallow. A modem without a
				// cell environment (old stacks reject the location query
				// permanently) skips the cell-derived steps but still resolves
				// the data-system mode from the NAS radio_ifs fallback.
				if (!self.cells)
					return self.reg ? self._determine_data_mode(after) : after();

				self._fetch_ca_info(() => self._determine_data_mode(() => {
					// vendor-neutral serving band/bandwidth from the CA-info PCC —
					// after data-mode so a Quectel AT+QENG serving (exact) wins;
					// fills for every other modem that has no QENG.
					modem_common.serving_from_ca(self);
					// EARFCN/NR-ARFCN -> band gap-fill (only fills when a vendor
					// source left band unset; QENG/CA-info always win).
					modem_common.fill_serving_band(self);
					modem_common.fetch_nr_neighbours(self, after);
				}));
			}, { no_recovery: true });
		}, { no_recovery: true });
	};

	// GET_SIGNAL_STRENGTH (NAS 0x0020) entries -> the SIGNAL_INFO shape,
	// so status renders identically. The RSSI u8 is the NEGATIVE dBm value
	// (128 = -128 dBm, the no-signal floor — qmicli-verified on the E1820).
	// RSRQ/SNR/RSRP are signed dBm/0.1 dB like the modern message carries.
	// Non-LTE rows map onto the gsm_rssi / wcdma fields so a 2G/3G-camped
	// modem (the E1820 on GSM) still reports its signal.
	strength_signal = (sdata) => {
		let lte = null, gsm = null, wcdma = null;

		for (let e in (sdata?.rssi_list ?? [])) {
			if (e.radio_if == 8)
				lte = { rssi: (e.rssi != null && e.rssi <= 128) ? -e.rssi : null,
				        rsrq: null, rsrp: null, snr: null };
			else if (e.radio_if == 4)
				gsm = (e.rssi != null && e.rssi <= 128) ? -e.rssi : null;
			else if (e.radio_if == 5)
				wcdma = { rssi: (e.rssi != null && e.rssi <= 128) ? -e.rssi : null,
				          ecio: null };
		}

		if (sdata?.rsrq?.radio_if == 8) {
			lte ??= { rssi: null, rsrq: null, rsrp: null, snr: null };
			lte.rsrq = sdata.rsrq.rsrq;
		}

		if (sdata?.lte_snr != null) {
			lte ??= { rssi: null, rsrq: null, rsrp: null, snr: null };
			lte.snr = sdata.lte_snr;
		}

		if (sdata?.lte_rsrp != null) {
			lte ??= { rssi: null, rsrq: null, rsrp: null, snr: null };
			lte.rsrp = sdata.lte_rsrp;
		}

		let out = {};

		if (lte) out.lte = lte;
		if (gsm != null) out.gsm_rssi = gsm;
		if (wcdma) out.wcdma = wcdma;

		return length(keys(out)) ? out : null;
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
				// The client is being destroyed. Everything below submits more
				// work — an AT CSQ floor read, a temperature read, an IoT-RAT
				// probe — and then re-arms this timer, all on the way down.
				// Nothing here is worth doing for a modem that is going away.
				if (err?.error == 'cancelled')
					return;

				if (!err)
					store_cells(data);
				else
					log('warn', sprintf('telemetry: cell location query failed: %J', err));

				// a modem whose QMI signal message never answers (old stacks)
				// still gets an rssi floor per tick — the slow loop is the one
				// place status updates even when nobody watches
				if (self.signal?.lte == null && self.signal?.nr5g == null)
					modem_common.telemetry_at(self).send('AT+CSQ', (aerr, ares) =>
						modem_common.sig_csq_floor(self,
							aerr ? null : modem_common.parse_csq(ares?.lines)));

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
			}, { no_recovery: true });
		};

		telemetry_timer = uloop.timer(first, tick);
	};

	self._log_telemetry = function() {
		log('debug', sprintf('telemetry: %s', modem_common.format_telemetry(self)));
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
