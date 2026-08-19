// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
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

import * as qmi_backend from 'wwand.qmi_backend';
import * as context_common from 'wwand.context_common';
import * as context_monitor_qmi from 'wwand.context_monitor_qmi';
import * as wdsmod from 'wwand.codec.schema.wds';
import { ENDPOINT_TYPE_HSUSB } from 'wwand.codec.schema.wda';
import * as callend from 'wwand.callend';

// START_NETWORK can legitimately take a long time (network attach + bearer
// setup on a congested cell); only then declare the activation dead.
const START_NETWORK_TIMEOUT_MS = 120000;

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

const netmask_to_prefix = context_common.netmask_to_prefix;


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
		channel_rate: null, // { tx_rate, rx_rate, max_tx_rate, max_rx_rate } bits/sec
		bearer: null,       // RAT carrying data ('LTE' / '5G NR' / 'LTE + 5G'), pushed by the WDS event report
		dormancy: null,     // 1 = dormant (idle), 2 = active — from the WDS event report
	};


	let deps = opts.deps ?? {};
	let log = deps.log ?? ((level, msg) => warn(sprintf('%s: interface %s: %s\n', level, self.name, msg)));

	// log an assigned family IP config at 'notice' only the FIRST time (at
	// connect — you want to see what the link came up with); every re-log drops
	// to 'debug'. A modem re-pushes settings every few minutes, and an IPv6
	// privacy address rotates its host bits each time (same /64, gw, dns) — a
	// real "change" that is nonetheless routine noise, so it must not stay at
	// notice. netifd still gets the update via the idempotent renew; this is
	// purely the human log line.
	let log_family_config = (fam, msg) => {
		log(fam._logsig == null ? 'notice' : 'debug', msg);
		fam._logsig = msg;
	};

	let up_cb = null;
	// bumped by every up(); guards the async activation flow against late
	// replies after an attempt was aborted (registration lost mid-attempt)
	let up_gen = 0;

	// wire-op steps forward-declared BEFORE the monitor/scaffolding arrows
	// that capture them (ucode resolves lexical refs only for bindings
	// already declared at definition time)
	let prepare, check_pdp_type, activate_family, fetch_settings, release_family;
	let mon;   // context_monitor_qmi handle (stats sampler + settings refresh)

	// shared emit/set_state/fail_finish (context_common.ctx_scaffolding)
	let sc = context_common.ctx_scaffolding(self, {
		deps: deps, log: log, stop_stats: () => mon.stop(),
	});
	let emit = sc.emit, set_state = sc.set_state;

	// while-CONNECTED monitoring — extracted to context_monitor_qmi.uc:
	// packet-stats sampler (zero-rx watchdog, netdev fallback, channel rates)
	// and the live settings refresh (event-driven + slow poll)
	mon = context_monitor_qmi.install(self, {
		log: log, emit: emit, timing: opts.timing,
		fetch: (family, done) => fetch_settings(family, done),
	});

	let wanted_families = () => {
		let pdp = self.config.pdp_type ?? 'ipv4v6';
		let fams = [];

		if (pdp == 'ipv4' || pdp == 'ipv4v6')
			push(fams, 4);

		if (pdp == 'ipv6' || pdp == 'ipv4v6')
			push(fams, 6);

		return fams;
	};

	// per-SIM override (wwand_sim by ICCID) wins over the interface value;
	// shared resolver, see context_common.conn_cfg. Attach profile still
	// falls back to the modem-provisioned APN below.
	let cfg = (field) => context_common.conn_cfg(self, field);

	let resolve_profile = () => {
		let apn = cfg('apn');

		// '#N': use modem profile N as-is
		if (apn != null && substr(apn, 0, 1) == '#')
			return { index: +substr(apn, 1), modify: false };

		let index = +(self.config.profile ?? 0);

		if (!index)
			index = +(self.config.mux_id ?? 0) || 1;

		return { index: index, modify: (apn != null && apn != '') };
	};

	// --- PREPARING ---------------------------------------------------------

	prepare = (profile, done) => {
		let wds = self.modem.wds_cfg;

		if (!profile.modify)
			return check_pdp_type(profile, done);

		let base = {
			profile: { type: wdsmod.PROFILE_TYPE_3GPP, index: profile.index },
			profile_name: 'default',
			apn: cfg('apn'),
			apn_disabled: 0,
		};

		if (cfg('auth') != null)
			base.auth = AUTH_MAP[cfg('auth')] ?? wdsmod.AUTH_BOTH;
		else if (cfg('username') && cfg('password'))
			base.auth = wdsmod.AUTH_BOTH;   // preserved default

		if (cfg('username'))
			base.username = cfg('username');

		if (cfg('password'))
			base.password = cfg('password');

		let do_write = () => wds.request('MODIFY_PROFILE', base, (err) => {
			if (err)
				log('warn', sprintf('profile modify failed: %J', err));

			// preserved: retry including roaming_disallowed=no, ignore result
			wds.request('MODIFY_PROFILE', { ...base, roaming_disallowed: 0 },
				(e2) => check_pdp_type(profile, done));
		});

		// idempotency guard: skip both NV writes when the profile already
		// matches. Credentials cannot be read back — configured username/
		// password always write.
		if (base.username != null || base.password != null)
			return do_write();

		wds.request('GET_PROFILE_SETTINGS', {
			profile: { type: wdsmod.PROFILE_TYPE_3GPP, index: profile.index },
		}, (gerr, curp) => {
			let same = !gerr && curp &&
				lc(curp.apn ?? '') == lc(base.apn ?? '') &&
				(curp.apn_disabled ?? 0) == 0 &&
				(curp.roaming_disallowed ?? 0) == 0 &&
				(base.auth == null || curp.auth == base.auth);

			if (same) {
				log('debug', sprintf('profile %d unchanged (apn/auth/roaming) — skipping modify',
					profile.index));
				return check_pdp_type(profile, done, curp);
			}

			do_write();
		});
	};

	check_pdp_type = (profile, done, pre) => {
		let wds = self.modem.wds_cfg;
		let want = PDP_MAP[self.config.pdp_type ?? 'ipv4v6'];

		let evaluate = (err, data) => {
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
		};

		// reuse the profile data the guard in prepare() already fetched
		if (pre)
			return evaluate(null, pre);

		wds.request('GET_PROFILE_SETTINGS', {
			profile: { type: wdsmod.PROFILE_TYPE_3GPP, index: profile.index },
		}, evaluate);
	};

	// Program the LTE attach profile (profile <index>, normally 1) from this
	// context's config so the modem's *autonomous* attach uses the right APN and
	// IP family. The modem attaches before wwand activates its data session, so a
	// stale attach profile (e.g. IPv4-only where the subscription needs IPv4v6)
	// gets the whole attach rejected (EMM #33 "service option not subscribed")
	// and we never reach activation. Called at modem init, before REGISTERING;
	// invokes done(changed) so the caller re-attaches when it changed. The data
	// path still re-applies the same settings via prepare/check_pdp_type at
	// activation time — this only fixes the *attach* that happens earlier.
	self.ensure_attach_profile = function(index, done) {
		let wds = self.modem.wds_cfg;
		let apn = cfg('apn');

		// '#N' means "use modem profile N as-is" — never rewrite it
		if (!wds || !index || (apn != null && substr(apn, 0, 1) == '#'))
			return done(false);

		let want_pdp = PDP_MAP[self.config.pdp_type ?? 'ipv4v6'];
		let prof = { type: wdsmod.PROFILE_TYPE_3GPP, index: index };

		wds.request('GET_PROFILE_SETTINGS', { profile: prof }, (err, data) => {
			if (err) {
				log('warn', sprintf('attach profile %d read failed: %J', index, err));
				return done(false);
			}

			// Unset/empty config APN = use the SIM/modem-provisioned one (carrier
			// pre-provisions the attach profile via MBN). So READ + LOG it and let
			// the modem attach with it, rather than writing a blank APN (too blunt).
			// ('#N' handled above; IP family still enforced below.)
			let card_apn = data.apn ?? '';
			let configured = (apn != null && apn != '');

			self.effective_apn = configured ? apn : card_apn;

			if (!configured)
				log('notice', sprintf('attach profile %d: no config APN — using SIM/modem-provisioned APN %s (pdp %J, auth %J%s)',
					index, card_apn == '' ? '(network default)' : sprintf('%J', card_apn),
					data.pdp_type, data.auth,
					data.username ? sprintf(', user %J', data.username) : ''));

			// only rewrite the APN when the config sets one that differs; an empty
			// config never touches the provisioned APN
			let need_apn = configured && (card_apn != apn);
			let need_pdp = (want_pdp != null && data.pdp_type != want_pdp);

			if (!need_apn && !need_pdp) {
				log('debug', sprintf('attach profile %d up to date (apn %J pdp %J)',
					index, data.apn, data.pdp_type));
				return done(false);
			}

			let mod = { profile: prof };

			if (need_apn) {
				mod.apn = apn;
				mod.apn_disabled = 0;
			}

			if (want_pdp != null)
				mod.pdp_type = want_pdp;

			log('notice', sprintf('attach profile %d: apn %J, pdp %J->%J',
				index, need_apn ? apn : card_apn, data.pdp_type, want_pdp));

			wds.request('MODIFY_PROFILE', mod, (e2) => {
				if (e2)
					log('warn', sprintf('attach profile %d modify failed: %J', index, e2));

				done(!e2);
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

			// WDS event report: bearer + dormancy pushed live (not polled).
			// Both families report the same modem-wide bearer (last-writer-wins).
			// Only current tx/rx is carried (no max), so the channel_rate poll stays.
			client.on('EVENT_REPORT_IND', (data) => {
				if (data.current_bearer?.rat_mask != null) {
					let b = qmi_backend.bearer_label(data.current_bearer.rat_mask);
					if (b)
						self.bearer = b;
				}
				if (data.dormancy != null)
					self.dormancy = data.dormancy;
				// keep the live tx/rx fresh between channel-rate polls (max preserved)
				if (data.channel_rates) {
					self.channel_rate ??= {};
					self.channel_rate.tx_rate = data.channel_rates.tx_rate;
					self.channel_rate.rx_rate = data.channel_rates.rx_rate;
				}
			});

			client.request('SET_EVENT_REPORT',
				{ current_data_bearer: 1, dormancy: 1 }, (e) => null, { no_recovery: true });

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
					endpoint: { type: dp.ep_type ?? ENDPOINT_TYPE_HSUSB, iface: dp.ep_id },
					mux_id: mux_id,
					client_type: 1,   // QMI_WDS_CLIENT_TYPE_TETHERED
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
					start_args.apn = cfg('apn');

					if (cfg('auth') != null)
						start_args.auth = AUTH_MAP[cfg('auth')] ?? wdsmod.AUTH_BOTH;

					if (cfg('username')) {
						start_args.username = cfg('username');
						start_args.password = cfg('password');
					}
				}

				log('notice', sprintf('starting ipv%d: apn \'%s\', profile %d',
					family, cfg('apn') ?? '(profile default)', profile.index));

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
				}, { timeout: START_NETWORK_TIMEOUT_MS });
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
				// (shared rule in context_common)
				let pushed_prefix = netmask_to_prefix(data.netmask);
				let prefix = context_common.v4_prefix(self.config, pushed_prefix, log);

				fam.settings = {
					addr: data.ipv4,
					netmask: data.netmask,
					prefix: prefix,
					pushed_prefix: pushed_prefix,
					gateway: data.gateway,
					dns: filter([ data.dns1, data.dns2 ], (d) => d != null),
					mtu: data.mtu,
				};

				log_family_config(fam, sprintf('ipv4 config: %s/%d gw %s dns [%s] mtu %J',
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

				log_family_config(fam, sprintf('ipv6 config: %s/%d gw %s dns [%s] mtu %J',
					fam.settings.addr, fam.settings.plen, fam.settings.gateway,
					join(' ', fam.settings.dns), fam.settings.mtu));
			}

			done(null);
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

		qmi_backend.stop_network(fam.client, fam.pdh, (err, second) => {
			log(err ? 'warn' : 'notice',
				sprintf('stopped ipv%d connection, pdh %d%s', family, fam.pdh,
					err ? sprintf(' (failed: %J)', err) : (second ? ' (2nd attempt)' : '')));
			release();
		});
	};

	// --- public API --------------------------------------------------------

	// stale-PDP reclaim (QMI internal cause 241, "interface in use, config
	// match"): a call nobody owns holds our profile — some carrier firmwares
	// (e.g. the Zyxel RG502Q) auto-activate their PDP profiles at boot, which
	// blocks START_NETWORK forever. Deactivating the PDP context on our
	// profile index over AT frees it; the caller then retries the family ONCE.
	let is_stale_pdp = (err) =>
		err?.stage == 'start_network' &&
		err.verbose?.type == callend.VERBOSE_TYPE_INTERNAL &&
		err.verbose?.reason == callend.INTERNAL_PDP_IN_USE &&
		self.modem.at != null;

	let reclaim_stale_pdp = (profile, on_done) => {
		log('warn', sprintf(
			'profile %d is in use on the modem, deactivating stale PDP context',
			profile.index));

		self.modem.at.send(sprintf('AT+CGACT=0,%d', profile.index), (aerr) => {
			if (aerr)
				log('warn', sprintf('AT+CGACT=0,%d failed: %J', profile.index, aerr));

			on_done();
		}, { timeout: 15000 });
	};

	self.up = function(cb) {
		if (self.state != 'IDLE')
			return cb({ error: 'busy', state: self.state });

		if (self.modem.state != 'READY')
			return cb({ error: 'modem_not_ready', modem_state: self.modem.state });

		up_cb = cb;

		let gen = ++up_gen;
		let profile = resolve_profile();
		let fams = wanted_families();

		set_state('PREPARING');

		prepare(profile, () => {
			if (gen != up_gen || self.state != 'PREPARING')
				return;   // attempt aborted while preparing — drop the late reply

			set_state('ACTIVATING');

			let idx = 0;
			let got_any = false;
			let reclaimed = {};
			let next, finish;

			next = () => {
				if (idx >= length(fams))
					return finish();

				let family = fams[idx++];

				activate_family(family, profile, (err) => {
					if (gen != up_gen || self.state != 'ACTIVATING')
						return;   // attempt aborted — drop the late reply

					if (err) {
						release_family(family);

						// stale-PDP reclaim (see is_stale_pdp above), once per family
						if (is_stale_pdp(err) && !reclaimed[family]) {
							reclaimed[family] = true;
							return reclaim_stale_pdp(profile, () => {
								if (gen != up_gen || self.state != 'ACTIVATING')
									return;   // attempt aborted while deactivating

								idx--;
								next();
							});
						}

						// preserved: v4 fatal, v6 degrades
						if (family == 4 || !got_any && idx >= length(fams))
							return self._fail(err);

						let cdesc = callend.describe(err?.call_end_reason, err?.verbose, err?.ext_error);
						log('warn', sprintf('ipv%d activation failed, continuing: %s%J', family,
							cdesc?.text ? sprintf('%s (%s%s) ', cdesc.text,
								cdesc.type_name ? cdesc.type_name + ' ' : '', cdesc.code) : '',
							err));
						return next();
					}

					got_any = true;

					fetch_settings(family, (serr) => {
						if (gen != up_gen || self.state != 'ACTIVATING')
							return;   // attempt aborted — drop the late reply

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
				mon.start();
				mon.schedule();
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

		mon.stop();
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

		// the shim only relays a top-level `error` string to netifd's log —
		// without it every failure shows up as "connection failed: unknown"
		if (err != null && err.error == null)
			err.error = desc?.text ?? sprintf('%s failed', err.stage ?? 'activation');

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
			log('err', sprintf('bring-up failed: %J', err));

		mon.stop();

		let cb = up_cb;
		up_cb = null;

		release_family(4, () => {
			release_family(6, () => sc.fail_finish(err, cb));
		});
	};

	self._connection_lost = function(family, data) {
		if (self.state != 'CONNECTED')
			return;

		// decode the WDS call-end cause: prefer the verbose reason (TLV 0x11,
		// the actionable 3GPP/IPv6/PPP detail) over the coarse code (0x10).
		let cause = callend.describe(data.call_end_reason, data.verbose_call_end);
		log('warn', sprintf('ipv%d connection lost: %s', family,
			cause ? cause.text : sprintf('call-end reason %d', data.call_end_reason ?? 0)));
		mon.stop();
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
			mon.refresh();
			break;

		case 'lost':
			// device gone: no QMI cleanup possible
			mon.stop();

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

			// an in-flight activation cannot succeed without registration and
			// its failure would climb the recovery ladder — abort it. The
			// daemon requeues the request until the modem re-registers.
			if (self.state == 'PREPARING' || self.state == 'ACTIVATING') {
				log('info', 'aborting activation until registration returns');

				let cb = up_cb;
				up_cb = null;

				set_state('IDLE');
				self.settings = null;

				release_family(4, () => {
					release_family(6, () => {
						if (cb)
							cb({ error: 'suspended' });
					});
				});
			}

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
			uptime: (self.state == 'CONNECTED' && self.connected_since) ? (context_common.mono() - self.connected_since) : null,
			stats: (self.state == 'CONNECTED') ? self.stats : null,
			channel_rate: (self.state == 'CONNECTED') ? self.channel_rate : null,
			bearer: (self.state == 'CONNECTED') ? self.bearer : null,
			dormancy: (self.state == 'CONNECTED') ? self.dormancy : null,
			families: map(keys(self.families), (k) => ({
				family: +k,
				cid: self.families[k].client?.cid,
				pdh: self.families[k].pdh,
			})),
		};
	};

	self.modem.attach_context(self);

	return self;
};
