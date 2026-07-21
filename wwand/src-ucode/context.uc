// wwand — per-PDP-context state machine.
//
// IDLE -> PREPARING -> ACTIVATING -> CONNECTED (MONITORING) -> IDLE
//
// Each context owns up to two fresh WDS clients (IPv4/IPv6, like the old
// cid_4/cid_6 split). Preserved behaviors:
// - fresh WDS CID per attempt, never reused (stale-CID hangs)
// - IPv4 failure is fatal, IPv6 failure degrades to v4-only
// - profile modify retried with roaming_disallowed=no, errors ignored
// - pdp-type written to the modem profile only when it differs
// - apn '#N' selects modem profile N untouched
// - double stop-network attempt on teardown
//
// opts = {
//   name, modem,
//   config: { apn, pdp_type ('ipv4'|'ipv6'|'ipv4v6'), auth, username,
//             password, profile, mux_id, mtu, use_pushed_mtu },
//   deps: { log, on_event (ctx, event, data) },
// }

'use strict';

import * as uloop from 'uloop';
import * as wdsmod from './codec/schema/wds.uc';
import { ENDPOINT_TYPE_HSUSB } from './codec/schema/wda.uc';
import * as callend from './callend.uc';

const wds_schema = wdsmod.default;

const AUTH_MAP = {
	none: wdsmod.AUTH_NONE,
	pap:  wdsmod.AUTH_PAP,
	chap: wdsmod.AUTH_CHAP,
	both: wdsmod.AUTH_BOTH,
};

const PDP_MAP = {
	ipv4:   wdsmod.PDP_TYPE_IPV4,
	ipv6:   wdsmod.PDP_TYPE_IPV6,
	ipv4v6: wdsmod.PDP_TYPE_IPV4V6,
};

const NETMASK_BITS = {
	'255': 8, '254': 7, '252': 6, '248': 5,
	'240': 4, '224': 3, '192': 2, '128': 1, '0': 0,
};

export function netmask_to_prefix(netmask)
{
	if (netmask == null)
		return null;

	let bits = 0;

	for (let octet in split(netmask, '.')) {
		let b = NETMASK_BITS[octet];

		if (b == null)
			return null;

		bits += b;
	}

	return bits;
}

export function create(opts)
{
	let self = {
		name: opts.name,
		modem: opts.modem,
		config: opts.config ?? {},

		state: 'IDLE',
		families: {},      // '4' | '6' -> { client, pdh, settings }
		settings: null,
		last_error: null,  // { stage, text, code, type, ... } from the last failure
		stats: null,       // cumulative data counters (bytes/packets/errors) since connect
		connected_since: null,
	};

	// packet-statistics request mask: all 10 flags (tx/rx packets ok, errors,
	// overflows, bytes, dropped) so one query feeds both the data-usage display
	// and the zero-rx watchdog.
	const STATS_MASK = 0x3FF;

	let deps = opts.deps ?? {};
	let log = deps.log ?? ((level, msg) => warn(sprintf('%s: context %s: %s\n', level, self.name, msg)));

	let up_cb = null;

	// zero-rx watchdog (preserved: packet statistics sampled every 60s; no
	// received packets for zero_rx_timeout -> usb-repower via the modem)
	let stats_timer = null;
	let stats_interval = opts.timing?.stats_interval ?? 60000;
	let rx_last_total = -1;
	let rx_stalled_ms = 0;

	// live settings refresh (stage B): while CONNECTED, re-query the modem's IP
	// config on serving-system changes (event-driven) plus a slow safety poll,
	// and emit 'settings' when it actually changed so the daemon asks netifd to
	// renew in place. Non-overlapping and rate-limited to bound modem load.
	let settings_timer = null;
	let refreshing = false;
	let refresh_cooldown = null;
	let refresh_settings, schedule_settings_poll;
	const REFRESH_MIN_MS = 10000;
	let settings_poll_ms = opts.timing?.settings_poll_ms ??
		((+(self.config?.settings_poll ?? 300)) * 1000);

	let emit = (event, data) => {
		if (deps.on_event)
			deps.on_event(self, event, data);
	};

	let set_state = (state) => {
		if (self.state == state)
			return;

		log('info', sprintf('state %s -> %s', self.state, state));
		self.state = state;
	};

	let wanted_families = () => {
		let pdp = self.config.pdp_type ?? 'ipv4v6';
		let fams = [];

		if (pdp == 'ipv4' || pdp == 'ipv4v6')
			push(fams, 4);

		if (pdp == 'ipv6' || pdp == 'ipv4v6')
			push(fams, 6);

		return fams;
	};

	let resolve_profile = () => {
		let apn = self.config.apn;

		// '#N': use modem profile N as-is
		if (apn != null && substr(apn, 0, 1) == '#')
			return { index: +substr(apn, 1), modify: false };

		let index = +(self.config.profile ?? 0);

		if (!index)
			index = +(self.config.mux_id ?? 0) || 1;

		return { index: index, modify: (apn != null && apn != '') };
	};

	// forward declarations: ucode resolves closure captures only for names
	// already declared at definition time
	let prepare, check_pdp_type, activate_family, fetch_settings, release_family;
	let start_stats, stop_stats, sample_stats;

	let zero_rx_limit_ms = () => {
		if (opts.timing?.zero_rx_ms != null)
			return opts.timing.zero_rx_ms;

		let secs = +(self.modem.config?.zero_rx_timeout ?? 21600);

		return (secs > 0) ? secs * 1000 : 0;
	};

	start_stats = () => {
		// run while connected regardless of the zero-rx setting: the sample
		// also feeds the data-usage counters shown on the status page.
		rx_last_total = -1;
		rx_stalled_ms = 0;
		self.connected_since = time();
		stats_timer = uloop.timer(stats_interval, sample_stats);
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

		for (let fam in fams) {
			fam.client.request('GET_PACKET_STATISTICS', { mask: STATS_MASK }, (err, data) => {
				if (err || data.rx_packets_ok == null) {
					valid = false;   // preserved: skip the check this round
				}
				else {
					// modem counters are per-call cumulative; sum across families
					agg.tx_bytes   += data.tx_bytes_ok ?? 0;
					agg.rx_bytes   += data.rx_bytes_ok ?? 0;
					agg.tx_packets += data.tx_packets_ok ?? 0;
					agg.rx_packets += data.rx_packets_ok ?? 0;
					agg.tx_errors  += data.tx_packets_error ?? 0;
					agg.rx_errors  += data.rx_packets_error ?? 0;
					agg.tx_dropped += data.tx_packets_dropped ?? 0;
					agg.rx_dropped += data.rx_packets_dropped ?? 0;
				}

				if (--pend > 0)
					return;

				if (valid)
					self.stats = agg;

				// zero-rx watchdog: only when configured (rx-packet stall)
				if (valid && zero_rx_limit_ms() > 0) {
					let total = agg.rx_packets;

					if (total > rx_last_total || rx_last_total < 0) {
						rx_last_total = total;
						rx_stalled_ms = 0;
					}
					else {
						rx_stalled_ms += stats_interval;

						if (rx_stalled_ms >= zero_rx_limit_ms()) {
							log('err', sprintf('no rx packets for %dms, tripping zero-rx recovery', rx_stalled_ms));
							stop_stats();
							emit('zero_rx', { stalled_ms: rx_stalled_ms, rx_total: total });
							return;
						}
					}
				}

				if (stats_timer)
					stats_timer.set(stats_interval);
			});
		}
	};

	// --- PREPARING ---------------------------------------------------------

	prepare = (profile, done) => {
		let wds = self.modem.wds_cfg;

		if (!profile.modify)
			return check_pdp_type(profile, done);

		let base = {
			profile: { type: wdsmod.PROFILE_TYPE_3GPP, index: profile.index },
			profile_name: 'default',
			apn: self.config.apn,
			apn_disabled: 0,
		};

		if (self.config.auth != null)
			base.auth = AUTH_MAP[self.config.auth] ?? wdsmod.AUTH_BOTH;
		else if (self.config.username && self.config.password)
			base.auth = wdsmod.AUTH_BOTH;   // preserved default

		if (self.config.username)
			base.username = self.config.username;

		if (self.config.password)
			base.password = self.config.password;

		wds.request('MODIFY_PROFILE', base, (err) => {
			if (err)
				log('warn', sprintf('profile modify failed: %J', err));

			// preserved: retry including roaming_disallowed=no, ignore result
			wds.request('MODIFY_PROFILE', { ...base, roaming_disallowed: 0 },
				(e2) => check_pdp_type(profile, done));
		});
	};

	check_pdp_type = (profile, done) => {
		let wds = self.modem.wds_cfg;
		let want = PDP_MAP[self.config.pdp_type ?? 'ipv4v6'];

		wds.request('GET_PROFILE_SETTINGS', {
			profile: { type: wdsmod.PROFILE_TYPE_3GPP, index: profile.index },
		}, (err, data) => {
			if (err) {
				log('warn', sprintf('get profile settings failed: %J', err));
				return done();
			}

			if (data.pdp_type == want) {
				log('debug', sprintf('profile pdp type %d unchanged', want));
				return done();
			}

			log('notice', sprintf('changing profile %d pdp type %J -> %d',
				profile.index, data.pdp_type, want));

			wds.request('MODIFY_PROFILE', {
				profile: { type: wdsmod.PROFILE_TYPE_3GPP, index: profile.index },
				pdp_type: want,
			}, (e2) => {
				if (e2)
					log('warn', sprintf('pdp type change failed: %J', e2));

				done();
			});
		});
	};

	// --- ACTIVATING --------------------------------------------------------

	activate_family = (family, profile, done) => {
		// fresh WDS CID per attempt (preserved)
		self.modem.alloc(wds_schema, (err, client) => {
			if (err)
				return done({ stage: 'alloc', err: err });

			let fam = { client: client, pdh: null, settings: null };
			self.families[sprintf('%d', family)] = fam;

			client.on('PACKET_SERVICE_STATUS_IND', (data) => {
				if (data.status?.status == wdsmod.CONN_DISCONNECTED)
					self._connection_lost(family, data);
			});

			let start_activation;

			// muxed context: bind this wds client to its QMAP channel first
			let mux_id = +(self.config.mux_id ?? 0);

			if (mux_id > 0) {
				let dp = self.modem.datapath;

				if (!dp || dp.backend == 'none')
					return done({ stage: 'mux', err: 'mux_unavailable' });

				if (dp.ep_id == null)
					return done({ stage: 'mux', err: 'endpoint_unknown' });

				let orig_start = () => start_activation();

				client.request('BIND_MUX_DATA_PORT', {
					endpoint: { type: ENDPOINT_TYPE_HSUSB, iface: dp.ep_id },
					mux_id: mux_id,
				}, (berr) => {
					if (berr)
						return done({ stage: 'bind_mux', err: berr });

					orig_start();
				});
			}

			start_activation = () => client.request('SET_IP_FAMILY', {
				preference: (family == 6) ? wdsmod.IP_FAMILY_IPV6 : wdsmod.IP_FAMILY_IPV4,
			}, (e2) => {
				if (e2)
					log('warn', sprintf('set ip family %d failed: %J', family, e2));

				// apn/auth also passed here (old behavior): several contexts
				// may share a profile index, the request TLVs take precedence
				let start_args = { profile_3gpp: profile.index };

				if (profile.modify) {
					start_args.apn = self.config.apn;

					if (self.config.auth != null)
						start_args.auth = AUTH_MAP[self.config.auth] ?? wdsmod.AUTH_BOTH;

					if (self.config.username) {
						start_args.username = self.config.username;
						start_args.password = self.config.password;
					}
				}

				log('notice', sprintf('starting ipv%d: apn \'%s\', profile %d',
					family, self.config.apn ?? '(profile default)', profile.index));

				client.request('START_NETWORK', start_args, (e3, d3) => {
					if (e3 || d3?.pdh == null) {
						return done({
							stage: 'start_network',
							err: e3,
							call_end_reason: d3?.call_end_reason,
							verbose: d3?.verbose_call_end,
							ext_error: d3?.ext_error,
						});
					}

					fam.pdh = d3.pdh;
					log('notice', sprintf('ipv%d up, pdh %d (cid %d)', family, fam.pdh, client.cid));
					done(null);
				}, { timeout: 120000 });
			});

			if (mux_id == 0)
				start_activation();
		});
	};

	fetch_settings = (family, done) => {
		let fam = self.families[sprintf('%d', family)];

		fam.client.request('GET_CURRENT_SETTINGS', {
			requested: wdsmod.REQ_SETTINGS_DEFAULT,
		}, (err, data) => {
			if (err)
				return done({ stage: 'settings', err: err });

			if (family == 4) {
				// always /32 point-to-point (old behavior) unless the pushed
				// prefix is explicitly requested via use_pushed_prefix
				let pushed_prefix = netmask_to_prefix(data.netmask);
				let prefix = 32;

				if (self.config.use_pushed_prefix && pushed_prefix != null)
					prefix = pushed_prefix;
				else if (pushed_prefix != null && pushed_prefix != 32)
					log('warn', sprintf('network pushed ipv4 prefix /%d, forcing /32 (option use_pushed_prefix keeps the pushed one)', pushed_prefix));

				fam.settings = {
					addr: data.ipv4,
					netmask: data.netmask,
					prefix: prefix,
					pushed_prefix: pushed_prefix,
					gateway: data.gateway,
					dns: filter([ data.dns1, data.dns2 ], (d) => d != null),
					mtu: data.mtu,
				};

				log('notice', sprintf('ipv4 config: %s/%d gw %s dns [%s] mtu %J',
					fam.settings.addr, fam.settings.prefix, fam.settings.gateway,
					join(' ', fam.settings.dns), fam.settings.mtu));
			}
			else {
				fam.settings = {
					addr: data.ipv6?.addr,
					plen: data.ipv6?.plen,
					gateway: data.ipv6_gateway?.addr,
					dns: filter([ data.ipv6_dns1, data.ipv6_dns2 ], (d) => d != null),
					mtu: data.mtu,
				};

				log('notice', sprintf('ipv6 config: %s/%d gw %s dns [%s] mtu %J',
					fam.settings.addr, fam.settings.plen, fam.settings.gateway,
					join(' ', fam.settings.dns), fam.settings.mtu));
			}

			done(null);
		});
	};

	// re-query GET_CURRENT_SETTINGS for the active families and, if anything
	// changed (addr/prefix/gateway/dns/mtu), rebuild self.settings and emit
	// 'settings'. fetch_settings overwrites fam.settings in place, so we
	// snapshot each family's serialized settings before and compare after.
	let settings_sig = (s) => (s != null) ? sprintf('%J', s) : '';

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

			fetch_settings(+key, (err) => {
				if (!err && settings_sig(self.families[key]?.settings) != before)
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

	release_family = (family, cb) => {
		let key = sprintf('%d', family);
		let fam = self.families[key];

		if (!fam)
			return cb ? cb() : null;

		delete self.families[key];

		let release = () => {
			log('notice', sprintf('released ipv%d wds client %d', family, fam.client.cid));
			self.modem.release(fam.client, () => cb ? cb() : null);
		};

		if (fam.pdh == null)
			return release();

		// preserved: double stop-network attempt
		fam.client.request('STOP_NETWORK', { pdh: fam.pdh }, (err) => {
			if (!err) {
				log('notice', sprintf('stopped ipv%d connection, pdh %d', family, fam.pdh));
				return release();
			}

			fam.client.request('STOP_NETWORK', { pdh: fam.pdh }, (e2) => {
				log(e2 ? 'warn' : 'notice',
					sprintf('stopped ipv%d connection, pdh %d%s', family, fam.pdh,
						e2 ? sprintf(' (failed: %J)', e2) : ' (2nd attempt)'));
				release();
			});
		}, { timeout: 10000 });
	};

	// --- public API --------------------------------------------------------

	self.up = function(cb) {
		if (self.state != 'IDLE')
			return cb({ error: 'busy', state: self.state });

		if (self.modem.state != 'READY')
			return cb({ error: 'modem_not_ready', modem_state: self.modem.state });

		up_cb = cb;

		let profile = resolve_profile();
		let fams = wanted_families();

		set_state('PREPARING');

		prepare(profile, () => {
			set_state('ACTIVATING');

			let idx = 0;
			let got_any = false;
			let next, finish;

			next = () => {
				if (idx >= length(fams))
					return finish();

				let family = fams[idx++];

				activate_family(family, profile, (err) => {
					if (err) {
						release_family(family);

						// preserved: v4 fatal, v6 degrades
						if (family == 4 || !got_any && idx >= length(fams))
							return self._fail(err);

						log('warn', sprintf('ipv%d activation failed, continuing: %J', family, err));
						return next();
					}

					got_any = true;

					fetch_settings(family, (serr) => {
						if (serr) {
							release_family(family);

							if (family == 4)
								return self._fail(serr);

							return next();
						}

						next();
					});
				});
			};

			finish = () => {
				if (!got_any)
					return self._fail({ stage: 'activate', err: 'no family connected' });

				self.settings = {
					ipv4: self.families['4']?.settings,
					ipv6: self.families['6']?.settings,
					mtu: self.families['4']?.settings?.mtu ?? self.families['6']?.settings?.mtu,
				};

				set_state('CONNECTED');
				self.last_error = null;   // a good connection clears the last failure
				start_stats();
				schedule_settings_poll();
				emit('up', self.settings);

				let cb2 = up_cb;
				up_cb = null;

				if (cb2)
					cb2(null, self.settings);
			};

			next();
		});
	};

	self.down = function(cb) {
		let was = self.state;

		stop_stats();
		set_state('IDLE');
		self.settings = null;

		release_family(4, () => {
			release_family(6, () => {
				if (was != 'IDLE')
					emit('down', { reason: 'admin' });

				if (cb)
					cb(null);
			});
		});
	};

	self._fail = function(err) {
		// derive a human-readable cause from the QMI call-end / verbose reason
		// (3GPP SM cause etc.) and retain it so the log and the status page can
		// explain *why* activation failed — bad password, forbidden APN, ...
		let desc = callend.describe(err?.call_end_reason, err?.verbose, err?.ext_error);

		self.last_error = {
			stage: err?.stage,
			text:  desc?.text,
			code:  desc?.code,
			type:  desc?.type_name,
			call_end_reason: err?.call_end_reason,
			ext_error: err?.ext_error,
		};

		if (desc?.text)
			log('err', sprintf('activation failed: %s (%s%s)', desc.text,
				desc.type_name ? desc.type_name + ' ' : '', desc.code));
		else
			log('err', sprintf('context failed: %J', err));

		stop_stats();

		let cb = up_cb;
		up_cb = null;

		release_family(4, () => {
			release_family(6, () => {
				set_state('IDLE');
				self.settings = null;
				emit('error', err);

				if (cb)
					cb(err);
			});
		});
	};

	self._connection_lost = function(family, data) {
		if (self.state != 'CONNECTED')
			return;

		log('warn', sprintf('ipv%d connection lost (reason %J)', family, data.call_end_reason));
		stop_stats();
		set_state('IDLE');
		self.settings = null;

		release_family(4, () => {
			release_family(6, () => {
				emit('down', { reason: 'disconnected', family: family, data: data });
			});
		});
	};

	self.modem_event = function(event, data) {
		switch (event) {
		case 'ready':
			emit('modem_ready', {});
			break;

		case 'serving_change':
			// the modem's serving system changed while we are connected — the
			// network may have pushed a new prefix/DNS/MTU; refresh in place
			refresh_settings();
			break;

		case 'lost':
			// device gone: no QMI cleanup possible
			stop_stats();

			for (let key in keys(self.families)) {
				let fam = self.families[key];
				delete self.families[key];
				fam.client.destroy();
			}

			if (self.state != 'IDLE') {
				set_state('IDLE');
				self.settings = null;
				emit('down', { reason: 'modem_lost' });
			}

			if (up_cb) {
				let cb = up_cb;
				up_cb = null;
				cb({ error: 'modem_lost' });
			}

			break;

		case 'suspend':
			log('warn', 'modem lost registration');
			emit('suspend', data);
			break;

		case 'sim_blocked':
			if (up_cb) {
				let cb = up_cb;
				up_cb = null;
				cb({ error: 'sim_blocked', detail: data });
			}

			break;
		}
	};

	self.status = function() {
		return {
			name: self.name,
			state: self.state,
			settings: self.settings,
			last_error: self.last_error,
			uptime: (self.state == 'CONNECTED' && self.connected_since) ? (time() - self.connected_since) : null,
			stats: (self.state == 'CONNECTED') ? self.stats : null,
			families: map(keys(self.families), (k) => ({
				family: +k,
				cid: self.families[k].client?.cid,
				pdh: self.families[k].pdh,
			})),
		};
	};

	self.modem.attach_context(self);

	return self;
}
