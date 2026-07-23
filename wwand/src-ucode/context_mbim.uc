// wwand — per-PDP-context state machine for MBIM.
//
// A context maps to an MBIM session on the shared control channel. Session 0
// is the untagged parent netdev (wwan0); sessions > 0 use a VLAN sub-device
// (wwan0.N) created on the cdc_mbim netdev, which tags egress and matches the
// session id. The session id is taken from the context's mux_id so existing
// configuration carries over.
//
// up() produces the same settings object as the QMI context (ipv4{addr,
// prefix,gateway,dns[]}, ipv6{...}, mtu) so the netifd shim and ubus stay
// protocol-neutral.

'use strict';

import * as uloop from 'uloop';
import * as bc from './codec/mbim-schema/basic_connect.uc';

const AUTH_MAP = {
	none: bc.AUTH_NONE, pap: bc.AUTH_PAP,
	chap: bc.AUTH_CHAP, both: bc.AUTH_CHAP,
};

const IP_TYPE_MAP = {
	ipv4: bc.IP_TYPE_IPV4, ipv6: bc.IP_TYPE_IPV6, ipv4v6: bc.IP_TYPE_IPV4V6,
};

export function create(opts)
{
	let self = {
		name: opts.name,
		modem: opts.modem,
		config: opts.config ?? {},
		state: 'IDLE',
		settings: null,
		session_id: +(opts.config?.mux_id ?? 0),
	};

	let deps = opts.deps ?? {};
	let log = deps.log ?? ((l, m) => warn(sprintf('%s: context %s: %s\n', l, self.name, m)));
	let up_cb = null;
	// true once our CONNECT activated the session — the modem then holds it, so a
	// failure/retry path must DEACTIVATE first or the next CONNECT hits MBIM
	// status 13 (max activated contexts).
	let activated = false;

	// zero-rx watchdog (parity with the QMI context): sample MBIM
	// PACKET_STATISTICS while CONNECTED; if received packets stall for
	// zero_rx_timeout, emit 'zero_rx' so the daemon usb-repowers the modem.
	// cdc_mbim's carrier does not reflect a silent bearer stall, so this is the
	// only backstop for a wedged-but-"connected" data path.
	let stats_timer = null;
	let stats_interval = opts.timing?.stats_interval ?? 60000;
	let rx_last_total = -1;
	let rx_stalled_ms = 0;

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

	let netmask_to_prefix = (p) => p;   // MBIM already gives the prefix length

	let build_settings = (cfg) => {
		let out = { ipv4: null, ipv6: null, mtu: null };

		if (cfg.ipv4_available && length(cfg.ipv4_addresses ?? [])) {
			let a = cfg.ipv4_addresses[0];
			let prefix = self.config.use_pushed_prefix ? a.prefix : 32;

			if (!self.config.use_pushed_prefix && a.prefix != 32)
				log('warn', sprintf('network pushed ipv4 prefix /%d, forcing /32', a.prefix));

			out.ipv4 = {
				addr: a.address, prefix: prefix, pushed_prefix: a.prefix,
				gateway: cfg.ipv4_gateway,
				dns: cfg.ipv4_dns ?? [],
				mtu: cfg.ipv4_mtu,
			};
		}

		if (cfg.ipv6_available && length(cfg.ipv6_addresses ?? [])) {
			let a = cfg.ipv6_addresses[0];

			out.ipv6 = {
				addr: a.address, plen: a.prefix,
				gateway: cfg.ipv6_gateway,
				dns: cfg.ipv6_dns ?? [],
				mtu: cfg.ipv6_mtu,
			};
		}

		out.mtu = out.ipv4?.mtu ?? out.ipv6?.mtu;

		return out;
	};

	let zero_rx_limit_ms = () => {
		if (opts.timing?.zero_rx_ms != null)
			return opts.timing.zero_rx_ms;

		let secs = +(self.modem.config?.zero_rx_timeout ?? 21600);

		return (secs > 0) ? secs * 1000 : 0;
	};

	let start_stats, stop_stats, sample_stats;

	start_stats = () => {
		rx_last_total = -1;
		rx_stalled_ms = 0;
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
		if (self.state != 'CONNECTED' || !self.modem.mbim)
			return;   // torn down (control channel gone) — let the timer lapse

		// device-wide counters (MBIM PACKET_STATISTICS has no session id); for
		// the common single-session setup that is exactly this context's traffic
		self.modem.command('PACKET_STATISTICS', 'query', {}, (err, d) => {
			if (self.state != 'CONNECTED')
				return;

			if (!err && d != null) {
				self.stats = {
					tx_bytes: d.out_octets, rx_bytes: d.in_octets,
					tx_packets: d.out_packets, rx_packets: d.in_packets,
					tx_errors: d.out_errors, rx_errors: d.in_errors,
					tx_dropped: d.out_discards, rx_dropped: d.in_discards,
				};

				if (zero_rx_limit_ms() > 0) {
					let total = +(d.in_packets ?? 0);

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
			}

			if (stats_timer)
				stats_timer.set(stats_interval);
		});
	};

	// best-effort DEACTIVATE of this session (shared by admin down + failure
	// cleanup). ip_type DEFAULT / empty strings per the MBIM deactivate form.
	let deactivate = (cb) => {
		self.modem.command('CONNECT', 'set', {
			session_id: self.session_id,
			activation_command: bc.ACTIVATION_CMD_DEACTIVATE,
			access_string: '', user_name: '', password: '',
			compression: 0, auth_protocol: bc.AUTH_NONE,
			ip_type: bc.IP_TYPE_DEFAULT,
			context_type: bc.CONTEXT_TYPE_INTERNET,
		}, (err) => { if (cb) cb(err); }, { timeout: 30000 });
	};

	self.up = function(cb) {
		if (self.state != 'IDLE')
			return cb({ error: 'busy', state: self.state });

		if (self.modem.state != 'READY')
			return cb({ error: 'modem_not_ready', modem_state: self.modem.state });

		up_cb = cb;
		activated = false;
		set_state('ACTIVATING');

		// empty APN = network default: MBIM CONNECT with a blank access string
		// lets the network assign the default PDN (no blank APN written anywhere)
		let profile = self.config.apn ?? '';
		let ip_type = IP_TYPE_MAP[self.config.pdp_type ?? 'ipv4v6'];

		let args = {
			session_id: self.session_id,
			activation_command: bc.ACTIVATION_CMD_ACTIVATE,
			access_string: profile,
			user_name: self.config.username ?? '',
			password: self.config.password ?? '',
			compression: 0,
			auth_protocol: AUTH_MAP[self.config.auth] ?? bc.AUTH_NONE,
			ip_type: ip_type,
			context_type: bc.CONTEXT_TYPE_INTERNET,
		};

		log('notice', sprintf('connecting session %d: apn %s, ip-type %d',
			self.session_id, profile == '' ? '(network default)' : sprintf('\'%s\'', profile), ip_type));

		self.modem.command('CONNECT', 'set', args, (err, data) => {
			if (err)
				return self._fail({ stage: 'connect', err: err });

			if (data.activation_state != bc.ACTIVATION_ACTIVATED &&
			    data.activation_state != bc.ACTIVATION_ACTIVATING)
				return self._fail({ stage: 'connect', activation_state: data.activation_state,
				                    nw_error: data.nw_error });

			// the modem now holds the session — any later failure must deactivate
			activated = true;

			// query the assigned IP configuration
			self.modem.command('IP_CONFIGURATION', 'query',
				{ session_id: self.session_id }, (e2, cfg) => {
				if (e2)
					return self._fail({ stage: 'ip_config', err: e2 });

				self.settings = build_settings(cfg);

				if (!self.settings.ipv4 && !self.settings.ipv6)
					return self._fail({ stage: 'ip_config', err: 'no address assigned' });

				if (self.settings.ipv4)
					log('notice', sprintf('ipv4 config: %s/%d gw %s dns [%s] mtu %J',
						self.settings.ipv4.addr, self.settings.ipv4.prefix,
						self.settings.ipv4.gateway, join(' ', self.settings.ipv4.dns),
						self.settings.ipv4.mtu));

				if (self.settings.ipv6)
					log('notice', sprintf('ipv6 config: %s/%d gw %s dns [%s]',
						self.settings.ipv6.addr, self.settings.ipv6.plen,
						self.settings.ipv6.gateway, join(' ', self.settings.ipv6.dns)));

				set_state('CONNECTED');
				start_stats();
				emit('up', self.settings);

				let cb2 = up_cb;
				up_cb = null;

				if (cb2)
					cb2(null, self.settings);
			});
		}, { timeout: 60000 });
	};

	self.down = function(cb) {
		let was = self.state;

		stop_stats();
		set_state('IDLE');
		self.settings = null;
		activated = false;

		if (was == 'IDLE' || !self.modem.mbim)
			return cb ? cb(null) : null;

		deactivate((err) => {
			log('notice', sprintf('session %d deactivated', self.session_id));
			emit('down', { reason: 'admin' });

			if (cb)
				cb(null);
		});
	};

	self._fail = function(err) {
		log('err', sprintf('context failed: %J', err));

		let cb = up_cb;
		up_cb = null;

		let finish = () => {
			stop_stats();
			set_state('IDLE');
			self.settings = null;
			emit('error', err);

			if (cb)
				cb(err);
		};

		// if our CONNECT already activated the session the modem still holds it;
		// deactivate first so the daemon's retry doesn't hit MBIM status 13.
		if (activated && self.modem.mbim) {
			activated = false;
			log('notice', sprintf('deactivating session %d after failed activation',
				self.session_id));
			deactivate((e) => finish());
		}
		else {
			finish();
		}
	};

	// Unsolicited MBIM_CID_CONNECT indication for this session: the network
	// (de)activated the data context. This is the MBIM analogue of QMI's
	// PACKET_SERVICE_STATUS_IND (context.uc _connection_lost) — the primary
	// signal that a *live* data session dropped. It matters because on cdc_mbim
	// the netdev carrier does NOT follow the session (a radio/bearer loss leaves
	// wwan0 carrier up), so netifd never notices; without this we stay
	// stale-CONNECTED. Emitting 'down'/'disconnected' routes into the same
	// daemon reconnect-in-place path QMI uses.
	self.connect_indication = function(data) {
		let active = (data.activation_state == bc.ACTIVATION_ACTIVATED ||
		              data.activation_state == bc.ACTIVATION_ACTIVATING);

		if (self.state != 'CONNECTED' || active)
			return;

		log('warn', sprintf('session %d deactivated by network (state %J, nw_error %J)',
			self.session_id, data.activation_state, data.nw_error));

		activated = false;   // the network already tore it down
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
			activated = false;   // device/registration gone — nothing to deactivate
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
			protocol: 'mbim',
			session_id: self.session_id,
			settings: self.settings,
			stats: (self.state == 'CONNECTED') ? self.stats : null,
			uptime: (self.state == 'CONNECTED' && self.connected_since)
				? (time() - self.connected_since) : null,
		};
	};

	self.modem.attach_context(self);

	return self;
}
