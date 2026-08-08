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
import * as context_common from './context_common.uc';
import * as ncm from './modem_ncm.uc';

export function create(opts)
{
	let self = {
		name: opts.name,
		modem: opts.modem,
		config: opts.config ?? {},
		state: 'IDLE',
		settings: null,
		// PDP context id: '#N' apn selects modem context N as-is; else the
		// configured profile, else the mux id, else 1 (parity with context.uc)
		cid: null,
	};

	let deps = opts.deps ?? {};
	let log = deps.log ?? ((l, m) => warn(sprintf('%s: context %s: %s\n', l, self.name, m)));
	let up_cb = null;
	let activated = false;   // our dial bound the netdev — down() must unbind it

	// zero-rx watchdog + bearer-liveness poll (parity with the QMI/MBIM
	// contexts): while CONNECTED, sample the vendor byte counters and netdev
	// status; a stalled rx byte count trips 'zero_rx', a lost netdev binding
	// tears the session down as 'disconnected'.
	let stats_timer = null;
	let stats_interval = opts.timing?.stats_interval ?? 60000;
	let rx_watch = context_common.rx_stall_watch({
		limit_ms: () => context_common.zero_rx_limit_ms(self.modem.config, opts.timing),
		interval_ms: stats_interval,
	});

	// stats controls forward-declared BEFORE the scaffolding arrow that
	// captures stop_stats (ucode resolves lexical refs only for bindings
	// already declared at definition time)
	let start_stats, stop_stats, sample_stats;

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
			// (parity with context.uc / context_mbim.uc)
			let pushed = rdp.ipv4.prefix;
			let prefix = 32;

			if (self.config.use_pushed_prefix && pushed != null)
				prefix = pushed;
			else if (pushed != null && pushed != 32)
				log('warn', sprintf('network pushed ipv4 prefix /%d, forcing /32', pushed));

			out.ipv4 = {
				addr: rdp.ipv4.addr, prefix: prefix, pushed_prefix: pushed,
				gateway: rdp.ipv4.gateway,
				dns: rdp.ipv4.dns ?? [],
				mtu: rdp.ipv4.mtu,
			};
		}

		if (rdp.ipv6?.addr && rdp.ipv6.addr != '::') {
			out.ipv6 = {
				addr: rdp.ipv6.addr, plen: rdp.ipv6.plen,
				gateway: rdp.ipv6.gateway,
				dns: rdp.ipv6.dns ?? [],
				mtu: rdp.ipv6.mtu,
			};
		}

		out.mtu = out.ipv4?.mtu ?? out.ipv6?.mtu;

		return out;
	};

	// --- zero-rx watchdog / liveness ---------------------------------------


	start_stats = () => {
		rx_watch.reset();
		self.connected_since = time();
		stats_timer = uloop.timer(0, sample_stats);   // first sample immediately
	};

	stop_stats = () => {
		if (stats_timer) {
			stats_timer.cancel();
			stats_timer = null;
		}
	};

	sample_stats = () => {
		if (self.state != 'CONNECTED' || !self.modem.at)
			return;   // torn down — let the timer lapse

		let vendor = self.modem.vendor;
		let dial = self.modem.dial;

		// bearer liveness: the resolved dial's netdev-status query. state 0 while
		// we think we are connected means the network/modem dropped the binding.
		let after_status = () => {
			if (self.state != 'CONNECTED')
				return;

			if (!vendor.stats) {
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

						if (stats_timer) stats_timer.set(stats_interval);
					});
					return;
				}

				if (stats_timer) stats_timer.set(stats_interval);
				return;
			}

			self.modem.at.send(vendor.stats, (err, res) => {
				if (self.state != 'CONNECTED')
					return;

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
				}

				if (stats_timer)
					stats_timer.set(stats_interval);
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

				self.modem.at.send(sprintf('AT+CGCONTRDP=%d', self.cid), (e2, res) => {
					if (self.state != 'ACTIVATING')
						return;

					if (e2)
						return self._fail({ stage: 'ip_config', err: e2 });

					let rdp = ncm.parse_cgcontrdp(res?.lines);
					self.settings = build_settings(rdp);

					if (!self.settings.ipv4 && !self.settings.ipv6)
						return self._fail({ stage: 'ip_config', err: 'no address assigned' });

					if (self.settings.ipv4)
						log('notice', sprintf('ipv4 config: %s/%d gw %s dns [%s] mtu %J',
							self.settings.ipv4.addr, self.settings.ipv4.prefix,
							self.settings.ipv4.gateway ?? '-', join(' ', self.settings.ipv4.dns),
							self.settings.ipv4.mtu));

					if (self.settings.ipv6)
						log('notice', sprintf('ipv6 config: %s/%d gw %s dns [%s]',
							self.settings.ipv6.addr, self.settings.ipv6.plen,
							self.settings.ipv6.gateway ?? '-', join(' ', self.settings.ipv6.dns)));

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
		log('err', sprintf('context failed: %J', err));

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

	self.modem_event = function(event, data) {
		switch (event) {
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
				? (time() - self.connected_since) : null,
		};
	};

	self.modem.attach_context(self);

	return self;
};
