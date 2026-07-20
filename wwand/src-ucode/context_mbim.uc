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
	let stats_timer = null;

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

	self.up = function(cb) {
		if (self.state != 'IDLE')
			return cb({ error: 'busy', state: self.state });

		if (self.modem.state != 'READY')
			return cb({ error: 'modem_not_ready', modem_state: self.modem.state });

		up_cb = cb;
		set_state('ACTIVATING');

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

		log('notice', sprintf('connecting session %d: apn \'%s\', ip-type %d',
			self.session_id, profile, ip_type));

		self.modem.command('CONNECT', 'set', args, (err, data) => {
			if (err)
				return self._fail({ stage: 'connect', err: err });

			if (data.activation_state != bc.ACTIVATION_ACTIVATED &&
			    data.activation_state != bc.ACTIVATION_ACTIVATING)
				return self._fail({ stage: 'connect', activation_state: data.activation_state,
				                    nw_error: data.nw_error });

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

		set_state('IDLE');
		self.settings = null;

		if (was == 'IDLE' || !self.modem.mbim)
			return cb ? cb(null) : null;

		self.modem.command('CONNECT', 'set', {
			session_id: self.session_id,
			activation_command: bc.ACTIVATION_CMD_DEACTIVATE,
			access_string: '', user_name: '', password: '',
			compression: 0, auth_protocol: bc.AUTH_NONE,
			ip_type: bc.IP_TYPE_DEFAULT,
			context_type: bc.CONTEXT_TYPE_INTERNET,
		}, (err) => {
			log('notice', sprintf('session %d deactivated', self.session_id));
			emit('down', { reason: 'admin' });

			if (cb)
				cb(null);
		}, { timeout: 30000 });
	};

	self._fail = function(err) {
		log('err', sprintf('context failed: %J', err));

		let cb = up_cb;
		up_cb = null;

		set_state('IDLE');
		self.settings = null;
		emit('error', err);

		if (cb)
			cb(err);
	};

	self.modem_event = function(event, data) {
		switch (event) {
		case 'ready':
			emit('modem_ready', {});
			break;

		case 'lost':
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
		};
	};

	self.modem.attach_context(self);

	return self;
}
