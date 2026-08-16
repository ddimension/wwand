// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — while-CONNECTED monitoring for the QMI context (extracted from
// the context.uc closure).
//
// install(self, o) owns the packet-statistics sampler (data-usage counters,
// channel rates with sentinel scrub, kernel-netdev fallback for
// QMAP-offloaded modems, the zero-rx watchdog feed) and the live IP-settings
// refresh (event-driven refresh + a slow safety poll, with IPv6
// interface-identifier stabilization). o = { log, emit, timing,
// fetch(family, done) } — fetch is the context's GET_CURRENT_SETTINGS step.
// Returns { start, stop, refresh, schedule }; state lands on the usual
// context fields (self.stats / self.channel_rate / self.settings +
// emit('settings'|'zero_rx')).

'use strict';

import * as uloop from 'uloop';
import * as fs from 'fs';
import * as tlv from 'wwand.codec.tlv';
import * as qmi_backend from 'wwand.qmi_backend';
import * as context_common from 'wwand.context_common';

export function install(self, o)
{
	let log = o.log, emit = o.emit;
	let fetch_settings = o.fetch;
	let start_stats, stop_stats, sample_stats;
	// (refresh_settings / schedule_settings_poll declared in the moved block)

	// zero-rx watchdog (preserved: packet statistics sampled every 60s; no
	// received packets for zero_rx_timeout -> usb-repower via the modem). The
	// stall accumulator + threshold live in context_common (shared with the
	// MBIM/NCM contexts); this context only feeds it its rx-packet total.
	let stats_timer = null;
	let stats_interval = o.timing?.stats_interval ?? 60000;
	let rx_watch = context_common.rx_stall_watch({
		limit_ms: () => context_common.zero_rx_limit_ms(self.modem.config, o.timing),
		interval_ms: stats_interval,
	});

	// live settings refresh (stage B): while CONNECTED, re-query the modem's IP
	// config on serving-system changes (event-driven) plus a slow safety poll,
	// and emit 'settings' when it actually changed so the daemon asks netifd to
	// renew in place. Non-overlapping and rate-limited to bound modem load.
	let settings_timer = null;
	let refreshing = false;
	let refresh_cooldown = null;
	let refresh_settings, schedule_settings_poll;
	const REFRESH_MIN_MS = 10000;
	let settings_poll_ms = o.timing?.settings_poll_ms ??
		((+(self.config?.settings_poll ?? 300)) * 1000);


	start_stats = () => {
		// run while connected regardless of the zero-rx setting: the sample
		// also feeds the data-usage counters + max channel rate shown on the
		// status page. Fire the first sample immediately (it re-arms itself at
		// stats_interval) so those values appear right after connect instead of
		// only after the first interval.
		rx_watch.reset();
		self.connected_since = context_common.mono();
		stats_timer = uloop.timer(0, sample_stats);
	};

	stop_stats = () => {
		if (stats_timer) {
			stats_timer.cancel();
			stats_timer = null;
		}
		if (settings_timer) {
			settings_timer.cancel();
			settings_timer = null;
		}
	};

	sample_stats = () => {
		let fams = values(self.families);
		let pend = length(fams);
		let valid = true;
		let agg = { tx_bytes: 0, rx_bytes: 0, tx_packets: 0, rx_packets: 0,
		            tx_errors: 0, rx_errors: 0, tx_dropped: 0, rx_dropped: 0 };

		if (!pend || self.state != 'CONNECTED')
			return;

		// max up/down bandwidth for the current radio link (same for every PDP
		// on this modem) — query once via the first WDS client. Several modems
		// report "not available" rates as the u32 sentinel (0xFFFFFFFF) —
		// treat those as 0 so the UI doesn't show 4.3 Gbit/s.
		qmi_backend.get_channel_rates(fams[0].client, (rates) => {
			if (rates) {
				let r = {};
				for (let k, v in rates)
					r[k] = tlv.is_unavailable(v, 'u32') ? 0 : v;
				self.channel_rate = r;
			}
		});

		// the RAT actually carrying THIS session's data (LTE / 5G NSA / SA). The
		// WDS EVENT_REPORT current-bearer indication (armed in activate_family)
		// pushes this live when the modem supports it, but not every modem does
		// (the RG650E stays silent), so the poll remains the baseline. When the
		// indication has already set a value this round it is simply refreshed.
		qmi_backend.get_bearer(fams[0].client, (b) => {
			if (b)
				self.bearer = b;
		});

		for (let fam in fams) {
			qmi_backend.get_packet_stats(fam.client, (data) => {
				if (data == null) {
					valid = false;   // preserved: skip the check this round
				}
				else {
					// modem counters are per-call cumulative; sum across families.
					// several modems return the u32 "not available" sentinel
					// (tlv.SENTINEL.u32) for the error/dropped counts — treat it as
					// 0 so the UI doesn't show ~4.29 billion errors
					let c = (v) => tlv.is_unavailable(v, 'u32') ? 0 : v;

					agg.tx_bytes   += c(data.tx_bytes_ok);
					agg.rx_bytes   += c(data.rx_bytes_ok);
					agg.tx_packets += c(data.tx_packets_ok);
					agg.rx_packets += c(data.rx_packets_ok);
					agg.tx_errors  += c(data.tx_packets_error);
					agg.rx_errors  += c(data.rx_packets_error);
					agg.tx_dropped += c(data.tx_packets_dropped);
					agg.rx_dropped += c(data.rx_packets_dropped);
				}

				if (--pend > 0)
					return;

				// QMAP/rmnet-offloaded modems (e.g. the RG650E) account the
				// accelerated datapath ONLY in the kernel netdev — the WDS
				// per-call counters stay 0 forever. Fall back to the context
				// netdev's kernel statistics so usage display and the zero-rx
				// watchdog see real numbers.
				if (valid && !agg.rx_packets && !agg.tx_packets) {
					let mux = +(self.config.mux_id ?? 0);
					let parent = self.modem.datapath?.netdev;
					let dev = (mux > 0)
						? (self.config.mux_link ?? (parent ? sprintf('%sm%d', parent, mux) : null))
						: parent;

					if (dev && fs.access('/sys/class/net/' + dev)) {
						let g = (f) => +(trim(fs.readfile(sprintf('/sys/class/net/%s/statistics/%s', dev, f)) ?? '') || 0);

						agg.tx_bytes   = g('tx_bytes');
						agg.rx_bytes   = g('rx_bytes');
						agg.tx_packets = g('tx_packets');
						agg.rx_packets = g('rx_packets');
						agg.tx_errors  = g('tx_errors');
						agg.rx_errors  = g('rx_errors');
						agg.tx_dropped = g('tx_dropped');
						agg.rx_dropped = g('rx_dropped');
						agg.source = 'netdev';
					}
				}

				if (valid)
					self.stats = agg;

				// zero-rx watchdog: rx-packet stall (no-op when disabled)
				if (valid) {
					let total = agg.rx_packets;
					let stalled = rx_watch.feed(total);

					if (stalled != null) {
						log('err', sprintf('no rx packets for %dms, tripping zero-rx recovery', stalled));
						stop_stats();
						emit('zero_rx', { stalled_ms: stalled, rx_total: total });
						return;
					}
				}

				if (stats_timer)
					stats_timer.set(stats_interval);
			});
		}
	};


	// re-query GET_CURRENT_SETTINGS for the active families and, if anything
	// changed (addr/prefix/gateway/dns/mtu), rebuild self.settings and emit
	// 'settings'. fetch_settings overwrites fam.settings in place, so we
	// snapshot each family's serialized settings before and compare after.
	let settings_sig = (s) => (s != null) ? sprintf('%J', s) : '';

	// the modem may re-randomize the IPv6 interface identifier on every
	// settings query while prefix/gateway/dns stay put (seen on the RG502Q):
	// adopting each variant would renumber the interface on every poll. Treat
	// a same-prefix address as unchanged and keep the one netifd configured.
	let keep_stable_v6 = (before, after) => {
		if (!before?.addr || !after?.addr || after.addr == before.addr ||
		    after.plen != before.plen)
			return after;

		let ab = iptoarr(after.addr), bb = iptoarr(before.addr);
		let n = int((after.plen ?? 64) / 8);

		if (!ab || !bb)
			return after;

		for (let i = 0; i < n; i++)
			if (ab[i] != bb[i])
				return after;

		return { ...after, addr: before.addr };
	};

	refresh_settings = () => {
		if (self.state != 'CONNECTED' || refreshing || refresh_cooldown)
			return;

		let list = filter(keys(self.families), (k) => self.families[k]?.pdh != null);

		if (!length(list))
			return;

		refreshing = true;
		refresh_cooldown = uloop.timer(REFRESH_MIN_MS, () => { refresh_cooldown = null; });

		let idx = 0, changed = false, step;

		step = () => {
			if (idx >= length(list)) {
				refreshing = false;

				if (changed && self.state == 'CONNECTED') {
					self.settings = {
						ipv4: self.families['4']?.settings,
						ipv6: self.families['6']?.settings,
						mtu: self.families['4']?.settings?.mtu ?? self.families['6']?.settings?.mtu,
					};

					log('notice', 'ip settings changed, requesting netifd renew');
					emit('settings', self.settings);
				}

				return;
			}

			let key = list[idx++];
			let before = settings_sig(self.families[key]?.settings);
			let before_obj = self.families[key]?.settings;

			fetch_settings(+key, (err) => {
				let fam = self.families[key];

				if (!err && fam && +key == 6)
					fam.settings = keep_stable_v6(before_obj, fam.settings);

				if (!err && settings_sig(fam?.settings) != before)
					changed = true;

				step();
			});
		};

		step();
	};

	// slow safety poll while CONNECTED (self-rescheduling; stops when the
	// context leaves CONNECTED). settings_poll <= 0 disables it.
	schedule_settings_poll = () => {
		if (settings_timer) {
			settings_timer.cancel();
			settings_timer = null;
		}

		if (settings_poll_ms <= 0 || self.state != 'CONNECTED')
			return;

		settings_timer = uloop.timer(settings_poll_ms, () => {
			settings_timer = null;

			if (self.state != 'CONNECTED')
				return;

			refresh_settings();
			schedule_settings_poll();
		});
	};


	return {
		start: () => start_stats(),
		stop: () => stop_stats(),
		refresh: () => refresh_settings(),
		schedule: () => schedule_settings_poll(),
	};
};
