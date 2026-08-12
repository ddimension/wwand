// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — context settings assembly (extracted from the daemon.uc factory):
// the live config re-read plus the netifd-facing settings/link-side-effect
// helpers consumed by _up_result / context_settings / context_up.
//
// install(self, o) attaches (underscored — the daemon binds them to locals so
// its call sites read unchanged):
//   _refresh_context_cfg   re-read connection params from disk on every up
//   _apply_mtu             effective MTU on the l3 link (use_pushed_mtu, rtnl)
//   _enable_ipv6           clear disable_ipv6 on the l3 link before netifd
//   _settings_result       the settings payload the proto shim consumes
// o = { log, read_config, datapath_fx } — modem/context state stays on self.

'use strict';

// connection params re-read from disk on every up (structural changes still go
// through the reload trigger). entry.cfg is the object the context reads live,
// so updating it in place makes the next activation use the fresh values.
const CTX_LIVE_FIELDS = [ 'apn', 'pdp_type', 'auth', 'username', 'password',
                          'profile', 'mtu', 'use_pushed_mtu' ];

export function install(self, o)
{
	let log = o.log;
	let read_config = o.read_config;
	let datapath_fx = o.datapath_fx;

	self._refresh_context_cfg = function(name, entry) {
		if (!read_config)
			return;

		let parsed = read_config();
		let fresh = parsed?.contexts?.[name];

		if (!fresh)
			return;

		let changed = [];

		for (let f in CTX_LIVE_FIELDS)
			if (sprintf('%J', entry.cfg[f]) != sprintf('%J', fresh[f])) {
				entry.cfg[f] = fresh[f];
				push(changed, f);
			}

		if (length(changed))
			log('info', sprintf('interface %s: refreshed config from disk (%s)',
				name, join(', ', changed)));
	};

	// apply the effective MTU on the l3 link (use_pushed_mtu semantics, native rtnl)
	self._apply_mtu = function(name, entry, netdev) {
		let fx = datapath_fx;

		if (!fx || !netdev)
			return;

		let pushed = entry.ctx.settings?.mtu;
		let mtu = null;

		if (entry.cfg.use_pushed_mtu && pushed != null && pushed > 1280)
			mtu = pushed;
		else if (entry.cfg.mtu != null && entry.cfg.mtu > 575)
			mtu = entry.cfg.mtu;

		if (mtu == null)
			return;

		log('info', sprintf('interface %s: applying MTU %d on %s', name, mtu, netdev));

		if (!fx.link_set(netdev, { mtu: mtu }))
			log('warn', sprintf('interface %s: setting MTU %d on %s failed%s', name, mtu, netdev,
				fx.last_error ? sprintf(': %s', fx.last_error) : ''));

		let v6mtu = sprintf('/proc/sys/net/ipv6/conf/%s/mtu', netdev);

		if (fx.exists(v6mtu) && !fx.write(v6mtu, sprintf('%d', mtu)))
			log('warn', sprintf('interface %s: setting IPv6 MTU on %s failed', name, netdev));
	};

	// enable IPv6 on the l3 link before netifd configures it (disable_ipv6=0)
	self._enable_ipv6 = function(name, entry, netdev) {
		let fx = datapath_fx;

		if (!fx || !netdev || !entry.ctx.settings?.ipv6)
			return;

		let path = sprintf('/proc/sys/net/ipv6/conf/%s/disable_ipv6', netdev);

		if (fx.exists(path) && trim(fx.read(path) ?? '') != '0' && !fx.write(path, '0'))
			log('warn', sprintf('interface %s: enabling IPv6 on %s failed', name, netdev));
	};

	// the settings payload the proto shim consumes (context_up / renew).
	// `relink` is a one-shot flag: when set, the renew handler does a netifd link
	// down->up instead of an in-place update (hard_reconnect_on_ip_change).
	self._settings_result = function(name, entry, netdev) {
		let relink = entry._relink_once ? 1 : 0;
		entry._relink_once = false;

		return {
			up: true,
			context: name,
			interface: entry.cfg.interface,
			netdev: netdev,
			mtu: entry.cfg.mtu ?? entry.ctx.settings?.mtu,
			pushed_mtu: entry.ctx.settings?.mtu,
			use_pushed_mtu: entry.cfg.use_pushed_mtu,
			ipv4: entry.ctx.settings?.ipv4,
			ipv6: entry.ctx.settings?.ipv6,
			relink: relink,
		};
	};

};
