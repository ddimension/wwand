// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — per-PDP-context state machine for NCM (cdc_ncm / cdc_ether, AT-driven).
//
// A context maps to a PDP context id on the AT channel and the single cdc_ncm
// netdev. up() programs the context + auth (CGDCONT + vendor auth), issues the
// vendor "dial" that binds the netdev to the bearer (Quectel: AT+QNETDEVCTL=1,
// <cid>,1), reads the assigned IP with AT+CGCONTRDP=<cid> and produces the SAME
// neutral settings object as the QMI/MBIM contexts so the netifd shim and ubus
// stay protocol-neutral.
//
// The netdev carrier does NOT follow the bearer on cdc_ncm (as on cdc_mbim), so
// — like context_mbim — liveness is an AT poll: the vendor netdev-status query
// (QNETDEVCTL?) detects a dropped bearer, byte counters (QGDCNT) feed the
// zero-rx watchdog.
//
// IP-source note: stock ncm.sh brings the address up via a DHCP sub-interface;
// wwand instead reports a STATIC config from AT+CGCONTRDP so the datapath stays
// uniform with QMI/MBIM (VRF/PD dependencies preserved). The proto shim adds the
// v4 default route with NO gateway on the /32 p2p link, so a modem-internal
// CGCONTRDP gateway is harmless. A modem that does not populate CGCONTRDP must
// switch to the DHCP path (proto shim 'dhcp' sub-interface) — see the README.

'use strict';

import * as uloop from 'uloop';
import * as context_common from 'wwand.context_common';
import * as ncm from 'wwand.modem_ncm';
import * as netlink from 'wwand.netlink';

export function create(opts)
{
	let self = {
		name: opts.name,
		modem: opts.modem,
		config: opts.config ?? {},
		state: 'IDLE',
		settings: null,
		last_error: null,  // { stage, text, code } from the last failure
		// PDP context id: '#N' apn selects modem context N as-is; else the
		// configured profile, else the mux id, else 1 (parity with context.uc)
		cid: null,
	};

	let deps = opts.deps ?? {};
	let log = deps.log ?? ((l, m) => warn(sprintf('%s: interface %s: %s\n', l, self.name, m)));
	let up_cb = null;
	let activated = false;   // our dial bound the netdev — down() must unbind it

	// zero-rx watchdog + bearer-liveness poll (parity with the QMI/MBIM
	// contexts): while CONNECTED, sample the vendor byte counters and netdev
	// status; a stalled rx byte count trips 'zero_rx', a lost netdev binding
	// tears the session down as 'disconnected'.
	let stats_timer = null;
	let stats_interval = opts.timing?.stats_interval ?? 60000;
	// the vendor byte-counter command, once the modem has refused it for good.
	// Unlike the C5GREG probe (a bare ERROR = "unknown command", latched on the
	// first refusal), a CME error can be a passing condition, so this needs a
	// run of them before giving up. The netdev counter takes over — it feeds the
	// same zero-rx watchdog, so nothing but a wasted round-trip is lost.
	let vendor_stats_refused = false;
	let vendor_stats_errors = 0;
	// pending ^DEND verification (see modem_event 'session_urc')
	let session_confirm_timer = null;
	let session_confirm_ms = opts.timing?.session_confirm_ms ?? 10000;
	let rx_watch = context_common.rx_stall_watch({
		limit_ms: () => context_common.zero_rx_limit_ms(self.modem.config, opts.timing),
		interval_ms: stats_interval,
	});

	// stats controls forward-declared BEFORE the scaffolding arrow that
	// captures stop_stats (ucode resolves lexical refs only for bindings
	// already declared at definition time)
	let start_stats, stop_stats, sample_stats, refresh_settings;
	let clear_session_confirm, confirm_session_gone;

	// shared emit/set_state/fail_finish (context_common.ctx_scaffolding)
	let sc = context_common.ctx_scaffolding(self, {
		deps: deps, log: log, stop_stats: () => stop_stats(),
	});
	let emit = sc.emit, set_state = sc.set_state;

	// effective connection config for a dial: carrier bundle (apn/auth/username/
	// password) resolved through the per-SIM override (context_common.conn_cfg,
	// wwand_sim wins over the interface); everything else straight from the config
	let eff_config = () => {
		let e = { ...self.config };

		for (let f in ['apn', 'auth', 'username', 'password']) {
			let v = context_common.conn_cfg(self, f);

			if (v != null)
				e[f] = v;
		}

		return e;
	};

	// resolve the PDP context id (mirrors context.uc resolve_profile)
	let resolve_cid = (ccfg) => {
		let apn = ccfg.apn;

		if (apn != null && substr(apn, 0, 1) == '#')
			return { index: +substr(apn, 1), pass_through: true };

		let index = +(ccfg.profile ?? 0);

		if (!index)
			index = +(self.config.mux_id ?? 0) || 1;

		return { index: index, pass_through: false };
	};

	let build_settings = (rdp) => {
		let out = { ipv4: null, ipv6: null, mtu: null };

		if (rdp.ipv4?.addr && rdp.ipv4.addr != '0.0.0.0') {
			// /32 point-to-point unless the pushed prefix is explicitly wanted
			// (parity with context.uc / context_mbim.uc — shared rule)
			let pushed = rdp.ipv4.prefix;
			let prefix = context_common.v4_prefix(self.config, pushed, log);

			out.ipv4 = {
				addr: rdp.ipv4.addr, prefix: prefix, pushed_prefix: pushed,
				gateway: rdp.ipv4.gateway,
				dns: rdp.ipv4.dns ?? [],
				mtu: rdp.ipv4.mtu,
			};
		}

		// a PDP-reported v6 must be a real HOST address to be pushed: global
		// unicast (2000::/3) or ULA (fc00::/7). Everything else is dropped —
		// the literal '::' (CGPADDR before the v6 assignment settles) AND the
		// NAT64/DNS64-embedded junk some networks misreport in the address
		// slot (field: ::9b3c:bbac:ae08:b741 pushed as /128 next to the real
		// RA GUA on ByteSIM). A dropped address falls back to the DNS-only /
		// unmanaged bucket below — the RA-provided host address is untouched.
		let valid_host_v6 = (a) => {
			let m = match(a ?? '', /^([0-9a-fA-F]{1,4}):/);

			if (!m)
				return false;

			let h = hex('0x' + m[1]);

			return (h & 0xE000) == 0x2000 || (h & 0xFE00) == 0xFC00;
		};

		let v6_addr = (rdp.ipv6?.addr && valid_host_v6(rdp.ipv6.addr)) ? rdp.ipv6.addr : null;

		if (rdp.ipv6 && (v6_addr || length(rdp.ipv6.dns ?? []))) {
			out.ipv6 = {
				addr: v6_addr, plen: rdp.ipv6.plen,
				gateway: rdp.ipv6.gateway,
				dns: rdp.ipv6.dns ?? [],
				mtu: rdp.ipv6.mtu,
			};

			// addr-less = the host v6 is NOT managed here (RNDIS v6 model:
			// RA/SLAAC on the netdev + the dhcpv6 subinterface) — mark it so
			// status renders "unmanaged" instead of null/0
			if (out.ipv6.addr == null)
				out.ipv6.unmanaged = true;
		}

		out.mtu = out.ipv4?.mtu ?? out.ipv6?.mtu;

		// no MTU from the modem (the FM350-GL's CGCONTRDP carries none): the
		// netdev's own MTU is what the datapath actually uses — surface it
		// instead of reporting an empty MTU
		if (out.mtu == null) {
			let nd = self.modem.datapath?.netdev;
			let fx = self.modem.datapath?.fx;

			if (nd && fx) {
				let m = fx.read(sprintf('/sys/class/net/%s/mtu', nd));

				if (m != null && +m > 0)
					out.mtu = +m;
			}
		}

		return out;
	};

	// --- zero-rx watchdog / liveness ---------------------------------------


	// --- v6 SLAAC re-solicit ------------------------------------------------
	//
	// The T700's internal router announces the host v6 via RA; after a PDP
	// re-establishment its v6 forwarding can go stale until the host sends a
	// fresh router solicitation (field-observed: v6 stopped answering until a
	// disable_ipv6 toggle re-triggered SLAAC). Toggle the sysctl once per
	// connect — cheap, idempotent, and the RA state then refreshes itself.
	// RNDIS-ONLY: the modem RA model only exists there. On cdc_ncm/cdc_ether
	// the v6 address is a pushed STATIC one — the 1s disable window would
	// flush it mid-update and nothing there re-solicits.
	let nudge_rs = () => {
		if (self.modem.datapath?.backend != 'rndis_host')
			return;

		let nd = self.modem.datapath?.netdev;
		let fx = self.modem.datapath?.fx;

		if (!nd || !fx)
			return;

		let path = sprintf('/proc/sys/net/ipv6/conf/%s/disable_ipv6', nd);

		if (!fx.exists(path))
			return;

		fx.write(path, '1');
		uloop.timer(1000, () => {
			// restore unconditionally: a teardown within the 1s window must
			// not leave v6 disabled on the netdev (the write is idempotent)
			fx.write(path, '0');
		});
	};

	start_stats = () => {
		rx_watch.reset();
		self.connected_since = context_common.mono();
		stats_timer = uloop.timer(0, sample_stats);   // first sample immediately
		nudge_rs();
	};

	stop_stats = () => {
		// every teardown path funnels through here, so a pending ^DEND
		// verification cannot outlive the session it was asking about
		clear_session_confirm();

		if (stats_timer) {
			stats_timer.cancel();
			stats_timer = null;
		}
	};

	// URC pokes (modem-side +CGEV notifications): the modem pushes the
	// session events unsolicited; DEACT runs the liveness probe immediately
	// (the probe's own result decides, not the URC), ACT re-reads the
	// settings (the network may have reassigned IPs on re-activation)
	self.liveness_poke = () => {
		if (self.state == 'CONNECTED')
			sample_stats();
	};

	self.settings_poke = () => {
		if (self.state == 'CONNECTED')
			refresh_settings();
	};

	// per-vendor ip_config hook (ncm_vendors): vendors whose CGCONTRDP does not
	// carry the assigned address (Fibocom T700 — empty local fields, CGPADDR
	// instead) supply their own reader. The default is the generic CGCONTRDP
	// path, byte-identical to the previous behavior.
	let read_rdp = (cb) => {
		if (self.modem.vendor?.ip_config)
			return self.modem.vendor.ip_config(self.modem, self.cid, self.config, cb);

		self.modem.at.send(sprintf('AT+CGCONTRDP=%d', self.cid), (err, res) => {
			if (err)
				return cb(err);

			cb(null, ncm.parse_cgcontrdp(res?.lines));
		}, { timeout: 15000 });
	};

	// live IP-settings refresh (QMI/MBIM parity): re-read the assigned IP on
	// the stats tick and, if the network pushed changed IP config, emit
	// 'settings' so the daemon renews the interface in place.
	refresh_settings = () => {
		if (self.state != 'CONNECTED' || !self.modem.at)
			return;

		read_rdp((err, rdp) => {
			if (err || self.state != 'CONNECTED')
				return;

			let next = build_settings(rdp);

			if (!next.ipv4 && !next.ipv6)
				return;   // transient/empty read — keep current settings

			if (sprintf('%J', next) == sprintf('%J', self.settings))
				return;

			log('debug', sprintf('cid %d: network pushed new IP settings, renewing', self.cid));
			self.settings = next;
			emit('settings', self.settings);
		});
	};

	sample_stats = () => {
		if (self.state != 'CONNECTED' || !self.modem.at)
			return;   // torn down — let the timer lapse

		refresh_settings();

		let vendor = self.modem.vendor;
		let dial = self.modem.dial;

		// bearer liveness: the resolved dial's netdev-status query. state 0 while
		// we think we are connected means the network/modem dropped the binding.
		//
		// netdev byte counters (the QMI/MBIM datapath_stats source): the
		// universal NCM counter — vendors without a stats AT command (fibocom:
		// none) still surface rx/tx on the status page / wwandctl and feed the
		// zero-rx watchdog from the netdev statistics.
		let sample_netdev = (done) => {
			let nd = self.modem.datapath?.netdev;

			if (!nd)
				return done();

			let st = netlink.datapath_stats(self.modem.datapath?.fx, nd, []);
			let p = st?.parent;

			if (p && (p.rx_bytes != null || p.tx_bytes != null)) {
				self.stats = {
					tx_bytes: p.tx_bytes ?? self.stats?.tx_bytes ?? 0,
					rx_bytes: p.rx_bytes ?? self.stats?.rx_bytes ?? 0,
				};

				if (p.rx_bytes != null) {
					let total = +p.rx_bytes;
					let stalled = rx_watch.feed(total);

					if (stalled != null) {
						log('err', sprintf('no rx bytes for %dms, tripping zero-rx recovery', stalled));
						stop_stats();
						emit('zero_rx', { stalled_ms: stalled, rx_total: total });
						return;
					}
				}
			}

			done();
		};

		let after_status = () => {
			if (self.state != 'CONNECTED')
				return;

			if (!vendor.stats || vendor_stats_refused) {
				// no byte counter AND no dial status query = zero liveness. Poll the
				// assigned address (AT+CGPADDR — every 3GPP modem answers); a clearly
				// empty reply for our cid is a dropped bearer. Conservative: an AT
				// error, an unparsable line, or any non-zero address keep the context up.
				if (!dial.status) {
					self.modem.at.send(sprintf('AT+CGPADDR=%d', self.cid), (err, res) => {
						if (self.state != 'CONNECTED')
							return;

						if (!err) {
							let seen = false, alive = false;

							for (let l in (res?.lines ?? [])) {
								let m = match(l, /\+CGPADDR:\s*([0-9]+),(.*)/);

								if (!m || +m[1] != self.cid)
									continue;

								seen = true;

								for (let a in split(m[2], ',')) {
									a = trim(replace(a, /"/g, ''));
									if (length(a) && a != '0.0.0.0' && a != '::')
										alive = true;
								}
							}

							if (seen && !alive)
								return self._connection_lost({ reason: 'no_address' });
						}

						sample_netdev(() => {
							if (stats_timer) stats_timer.set(stats_interval);
						});
					});
					return;
				}

				sample_netdev(() => {
					if (stats_timer) stats_timer.set(stats_interval);
				});
				return;
			}

			self.modem.at.send(vendor.stats, (err, res) => {
				if (self.state != 'CONNECTED')
					return;

				// count only a REFUSAL (ERROR / +CME / +CMS); a timeout or a
				// closed port says nothing about whether the modem knows the
				// command, and must not retire it
				if (err && (err.error == 'ERROR' || err.error == 'cme' || err.error == 'cms')) {
					if (++vendor_stats_errors >= 3) {
						vendor_stats_refused = true;
						log('notice', sprintf('%s refused %d times (%s%s) — falling back to the netdev byte counter',
							vendor.stats, vendor_stats_errors, err.error,
							err.code ? sprintf(' %s', err.code) : ''));
					}
				}
				else if (!err) {
					vendor_stats_errors = 0;
				}

				let s = err ? null : vendor.parse_stats(res?.lines);

				if (s) {
					self.stats = { tx_bytes: s.tx_bytes, rx_bytes: s.rx_bytes };

					let total = +(s.rx_bytes ?? 0);
					let stalled = rx_watch.feed(total);

					if (stalled != null) {
						log('err', sprintf('no rx bytes for %dms, tripping zero-rx recovery', stalled));
						stop_stats();
						emit('zero_rx', { stalled_ms: stalled, rx_total: total });
						return;
					}

					if (stats_timer)
						stats_timer.set(stats_interval);
					return;
				}

				// the vendor AT counter read/parse failed — the netdev counter
				// is the universal fallback (and the sole source where the
				// vendor defines no stats command at all)
				sample_netdev(() => {
					if (stats_timer) stats_timer.set(stats_interval);
				});
			});
		};

		if (dial.status)
			self.modem.at.send(dial.status, (err, res) => {
				if (self.state != 'CONNECTED')
					return;

				let st = err ? null : dial.status_state(res?.lines, self.cid);

				if (st === 0)
					return self._connection_lost({ reason: 'netdev_unbound' });

				after_status();
			});
		else
			after_status();
	};

	// --- public API --------------------------------------------------------

	self.up = function(cb) {
		if (self.state != 'IDLE')
			return cb({ error: 'busy', state: self.state });

		if (self.modem.state != 'READY' || !self.modem.at)
			return cb({ error: 'modem_not_ready', modem_state: self.modem.state });

		// NCM has ONE shared cdc_ncm/cdc_ether netdev — a second parallel
		// context would silently share it (no per-PDP mux like QMAP/MBIM
		// sessions). Reject the extra context with a clear error instead of
		// two interfaces fighting over the same netdev.
		let other = filter(self.modem.contexts,
			(c) => c != self && c.state != 'IDLE');

		if (length(other))
			return cb({ error: 'unsupported_multi_context',
			            detail: 'NCM modems support a single active context (one shared netdev)' });

		up_cb = cb;
		activated = false;

		let ccfg = eff_config();
		let prof = resolve_cid(ccfg);
		self.cid = prof.index;

		let vendor = self.modem.vendor;
		let dial = self.modem.dial;

		set_state('ACTIVATING');

		// 1. program the PDP context + auth (CGDCONT + vendor auth carrying
		//    username/password). Skipped for a '#N' pass-through apn.
		let setup = prof.pass_through ? [] : ncm.build_pdp_setup(vendor, self.cid, ccfg);

		log('notice', sprintf('connecting cid %d: apn %J, pdp-type %s%s',
			self.cid, ccfg.apn ?? '', ccfg.pdp_type ?? 'ipv4v6',
			(ccfg.apn == null || ccfg.apn == '') ? ' (network default)' : ''));

		// dial-time idempotency guard: when the PDP context already matches the
		// config (and no auth is configured — those cannot be read back), skip the
		// CGDCONT/auth NV writes. Saves NV wear and avoids upsetting firmwares that
		// dislike context rewrites while a bearer is being set up (MeiG ECMDUP).
		let run_setup = (cmds) => self.modem.at.run_sequence(cmds, () => {
			if (self.state != 'ACTIVATING')
				return;   // aborted (modem lost) while configuring

			// 3. read the assigned IP configuration (shared by the fresh-dial
			//    and the adopt-existing paths below)
			let read_ip_config = () => {
				activated = true;

				read_rdp((e2, rdp) => {
					if (self.state != 'ACTIVATING')
						return;

					if (e2)
						return self._fail({ stage: 'ip_config', err: e2 });

					self.settings = build_settings(rdp);

					// an ipv6-only PDP legitimately carries no static address
					// (host v6 = the modem's RA/SLAAC, host v4 = the separate
					// 464xlat package) — only a v4-capable PDP with empty
					// settings is an error
					if ((!self.settings.ipv4 && !self.settings.ipv6) &&
					    ccfg.pdp_type != 'ipv6')
						return self._fail({ stage: 'ip_config', err: 'no address assigned' });

					if (self.settings.ipv4)
						log('notice', sprintf('ipv4 config: %s/%d gw %s dns [%s] mtu %J',
							self.settings.ipv4.addr, self.settings.ipv4.prefix,
							self.settings.ipv4.gateway ?? '-', join(' ', self.settings.ipv4.dns),
							self.settings.ipv4.mtu));

					if (self.settings.ipv6?.addr)
						log('notice', sprintf('ipv6 config: %s/%d gw %s dns [%s]',
							self.settings.ipv6.addr, self.settings.ipv6.plen,
							self.settings.ipv6.gateway ?? '-', join(' ', self.settings.ipv6.dns)));
					else if (self.settings.ipv6)
						log('notice', sprintf('ipv6 dns: [%s] (ipv6-only PDP — host addressing via RA/SLAAC)',
							join(' ', self.settings.ipv6.dns)));

					if (!self.settings.ipv4 && !self.settings.ipv6)
						log('notice', 'ip config: none (ipv6-only PDP — host v6 via RA/SLAAC, host v4 via 464xlat)');

					self.last_error = null;   // a good connection clears the last failure
					set_state('CONNECTED');
					start_stats();
					emit('up', self.settings);

					let cb2 = up_cb;
					up_cb = null;

					if (cb2)
						cb2(null, self.settings);
				}, { timeout: 15000 });
			};

			// 2. dial: bind the cdc_ncm netdev to the bearer
			self.modem.at.send(dial.connect(self.cid, ccfg), (err) => {
				if (self.state != 'ACTIVATING')
					return;

				if (!err)
					return read_ip_config();

				// some modems auto-dial (or keep a previous bearer) and reject a
				// dial while it is up (MeiG ECMDUP returns bare ERROR) — probe the
				// dial status and adopt the live session instead of failing
				if (dial.status && dial.status_state) {
					return self.modem.at.send(dial.status, (serr, sres) => {
						if (self.state != 'ACTIVATING')
							return;

						let st = serr ? null : dial.status_state(sres?.lines, self.cid);

						if (st != 1)
							return self._fail({ stage: 'connect', err: err });

						log('notice', sprintf('cid %d already connected, adopting live session', self.cid));
						read_ip_config();
					});
				}

				self._fail({ stage: 'connect', err: err });
			}, { timeout: 60000 });
		});

		if (!length(setup) || ccfg.username || ccfg.password)
			return run_setup(setup);

		self.modem.at.send('AT+CGDCONT?', (gerr, gres) => {
			if (self.state != 'ACTIVATING')
				return;

			if (!gerr && ncm.pdp_setup_matches(self.cid, ccfg, gres?.lines)) {
				log('info', sprintf('cid %d already configured (pdp-type + apn match) — skipping context write',
					self.cid));
				return run_setup([]);
			}

			run_setup(setup);
		}, { timeout: 8000 });
	};

	// best-effort unbind of the netdev + deactivate the bearer
	let disconnect = (cb) => {
		self.modem.at.send(self.modem.dial.disconnect(self.cid, self.config), (err) => {
			// also deactivate the PDP context (CGACT) unless the vendor dial
			// already does (Quectel QNETDEVCTL=0 tears the bearer down)
			if (cb)
				cb(err);
		}, { timeout: 30000 });
	};

	self.down = function(cb) {
		let was = self.state;

		stop_stats();
		set_state('IDLE');
		self.settings = null;

		if (was == 'IDLE' || !self.modem.at || !activated) {
			activated = false;
			return cb ? cb(null) : null;
		}

		activated = false;

		disconnect(() => {
			log('notice', sprintf('cid %d disconnected', self.cid));
			emit('down', { reason: 'admin' });

			if (cb)
				cb(null);
		});
	};

	self._fail = function(err) {
		log('err', sprintf('bring-up failed: %J', err));

		// LuCI-visible failure reason (daemon status `last_error` — QMI parity;
		// stayed null on NCM before)
		self.last_error = {
			stage: err?.stage ?? 'activation',
			text:  err?.error ?? null,
			code:  err?.code ?? null,
		};

		let cb = up_cb;
		up_cb = null;

		let finish = () => sc.fail_finish(err, cb);

		// if our dial already bound the netdev, unbind before the daemon retries
		if (activated && self.modem.at) {
			activated = false;
			disconnect((e) => finish());
		}
		else {
			finish();
		}
	};

	// bearer dropped underneath us (netdev-status poll saw state 0). The MBIM
	// analogue of context_mbim.connect_indication — routes into the daemon's
	// reconnect-in-place path.
	self._connection_lost = function(data) {
		if (self.state != 'CONNECTED')
			return;

		log('warn', sprintf('cid %d bearer lost (%s)', self.cid, data?.reason));
		activated = false;
		stop_stats();
		set_state('IDLE');
		self.settings = null;
		emit('down', { reason: 'disconnected', data: data });
	};

	// The modem's own bearer notification (MeiG ^DCONN/^DEND) is a HINT, not a
	// verdict — the same rule the registration URCs follow: the probe stays the
	// authority. A ^DEND is verified by an actual dial-status query after a
	// grace period, because the SLM770A has been seen re-establishing the
	// bearer on its own five seconds later (2026-08-23: ^DEND 21:05:54,
	// ^DCONN 21:05:59). Tearing down on the notification alone would kill a
	// session that was about to heal; ignoring it altogether costs up to a full
	// stats interval (60 s) to notice a drop that is real.
	clear_session_confirm = () => {
		if (session_confirm_timer) {
			session_confirm_timer.cancel();
			session_confirm_timer = null;
		}
	};

	confirm_session_gone = () => {
		session_confirm_timer = null;

		let dial = self.modem?.dial;

		if (self.state != 'CONNECTED' || !dial?.status || !self.modem?.at)
			return;

		self.modem.at.send(dial.status, (err, res) => {
			if (self.state != 'CONNECTED')
				return;

			// An AT ERROR leaves the session alone — it says nothing about the
			// bearer. A successful query does, in two shapes: our cid listed as
			// down (=== 0), or NO ROW AT ALL (null). The second one is not an
			// unparsable answer, it is how the MeiG reports "no contexts" —
			// field-seen 2026-08-23: ^DEND at 21:51:13, and the verification's
			// AT+ECMDUP? came back completely empty, so an === 0 test did
			// nothing and the drop was only noticed 53 s later by the stats
			// poll. Accepting the empty answer is safe HERE and only here: we
			// arrive with the modem's own ^DEND already on the record, so two
			// independent signals agree before anything is torn down.
			if (err)
				return;

			let st = dial.status_state(res?.lines, self.cid);

			if (st === 0 || st == null) {
				log('warn', sprintf('modem reported the bearer down and the status probe agrees (%s)',
					(st === 0) ? 'cid down' : 'no context listed'));
				self._connection_lost({ reason: 'session_ended' });
			}
		});
	};

	self.modem_event = function(event, data) {
		switch (event) {
		case 'session_urc':
			// not ours (the modem announces every cid it dials)
			if (data?.cid != null && data.cid != self.cid)
				break;

			if (data?.up) {
				// the bearer is back before we even asked — drop the doubt
				clear_session_confirm();
				break;
			}

			if (self.state == 'CONNECTED' && self.modem?.dial?.status && !session_confirm_timer)
				session_confirm_timer = uloop.timer(session_confirm_ms, confirm_session_gone);

			break;

		case 'ready':
			emit('modem_ready', {});
			break;

		case 'lost':
			activated = false;
			stop_stats();

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
			// registration lost mid-attempt: abort an in-flight activation so
			// the daemon requeues it (parity with context.uc)
			if (self.state == 'ACTIVATING') {
				let cb = up_cb;
				up_cb = null;

				set_state('IDLE');
				self.settings = null;

				if (cb)
					cb({ error: 'suspended' });
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
			protocol: 'ncm',
			cid: self.cid,
			settings: self.settings,
			stats: (self.state == 'CONNECTED') ? self.stats : null,
			uptime: (self.state == 'CONNECTED' && self.connected_since)
				? (context_common.mono() - self.connected_since) : null,
		};
	};

	self.modem.attach_context(self);

	return self;
};
