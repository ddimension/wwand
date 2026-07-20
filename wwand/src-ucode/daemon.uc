// wwand — daemon core: owns modems and contexts, applies configuration,
// dispatches ubus-level operations. Transport/sysfs/ubus access is injected
// so the whole core runs host-side against mocks.
//
// opts.deps = {
//   transport_open,               // for modem.uc
//   log,                          // (level, msg)
//   emit_event,                   // (type, data) -> ubus event broadcast
//   resolve_modem_device,         // (modem_cfg) -> '/dev/cdc-wdmX' | null
//   resolve_netdev,               // (modem_cfg, device) -> 'wwan0' | null
// }

'use strict';

import * as uloop from 'uloop';
import * as modem_mod from './modem.uc';
import * as context_mod from './context.uc';

const UP_GUARD_MS = 150000;

export function create(opts)
{
	let deps = opts?.deps ?? {};
	let log = deps.log ?? ((level, msg) => warn(sprintf('%s: %s\n', level, msg)));

	let self = {
		modems: {},    // name -> { cfg, modem, device, netdev }
		contexts: {},  // name -> { cfg, ctx, pending_up[] }
		timing: opts?.timing,
	};

	let emit = (type, data) => {
		if (deps.emit_event)
			deps.emit_event(type, data);
	};

	// --- modem/context wiring ----------------------------------------------

	let on_modem_event = (modem, event, data) => {
		switch (event) {
		case 'registered':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });

			// nudge netifd: interfaces whose earlier setup attempts failed
			// (boot race) stay down until something triggers them again
			if (deps.kick_interface) {
				for (let name, entry in self.contexts) {
					if (entry.cfg.modem == modem.id && entry.cfg.interface &&
					    entry.ctx && entry.ctx.state == 'IDLE') {
						log('info', sprintf('kicking interface %s after modem ready', entry.cfg.interface));
						deps.kick_interface(entry.cfg.interface);
					}
				}
			}

			break;

		case 'deregistered':
		case 'removed':
		case 'sim_blocked':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			break;
		}
	};

	let on_context_event = (name, ctx, event, data) => {
		let entry = self.contexts[name];

		switch (event) {
		case 'up':
			// a working data connection resets the recovery ladder
			ctx.modem.note_connect_success();
			emit('wwand.context', { context: name, interface: entry?.cfg?.interface, event: event });
			break;

		case 'error':
			// failed activation climbs the recovery ladder (old connecttries)
			ctx.modem.note_connect_failure();
			emit('wwand.context', { context: name, interface: entry?.cfg?.interface, event: event });
			break;

		case 'zero_rx':
			log('err', sprintf('context %s: zero-rx watchdog tripped', name));
			ctx.modem.trip_zero_rx();
			break;

		case 'down':
		case 'suspend':
			emit('wwand.context', {
				context: name,
				interface: entry?.cfg?.interface,
				event: event,
				...(event == 'down' ? { reason: data?.reason } : {}),
			});
			break;

		case 'modem_ready':
			// flush queued activation requests
			if (entry && length(entry.pending_up)) {
				let pend = entry.pending_up;
				entry.pending_up = [];

				for (let p in pend)
					self.context_up(name, p);
			}

			break;
		}
	};

	let start_modem = (name, cfg, muxinfo) => {
		let device = cfg.device;

		if (!device && deps.resolve_modem_device)
			device = deps.resolve_modem_device(cfg);

		let entry = {
			cfg: cfg,
			device: device,
			netdev: cfg.netdev,
			muxinfo: muxinfo,
			modem: null,
		};

		self.modems[name] = entry;

		if (!device) {
			log('warn', sprintf('modem %s: device not present yet, waiting for hotplug', name));
			return;
		}

		if (!entry.netdev && deps.resolve_netdev)
			entry.netdev = deps.resolve_netdev(cfg, device);

		let ep_id = cfg.ep_id;

		if (ep_id == null && deps.resolve_ep_id)
			ep_id = deps.resolve_ep_id(cfg, device, entry.netdev);

		entry.modem = modem_mod.create({
			id: name,
			device: device,
			config: cfg,
			timing: self.timing,
			datapath: {
				netdev: entry.netdev,
				ep_id: ep_id,
				mux: cfg.mux,
				dgram_size: cfg.dl_datagram_max_size,
				mux_links: muxinfo?.list ?? [],
				fx: deps.datapath_fx,
			},
			recovery: {
				fx: deps.recovery_fx,
				state_dir: opts?.state_dir,
				reboot_delay: opts?.reboot_delay,
			},
			at: {
				fx: deps.datapath_fx,
				open_transport: deps.at_open_transport,
			},
			deps: {
				transport_open: deps.transport_open,
				log: (level, msg) => log(level, sprintf('modem %s: %s', name, msg)),
				on_event: on_modem_event,
			},
		});

		entry.modem.start();
	};

	let start_context = (name, cfg) => {
		let mentry = self.modems[cfg.modem];

		if (!mentry?.modem) {
			log('warn', sprintf('context %s: modem %s not started', name, cfg.modem));
			self.contexts[name] = { cfg: cfg, ctx: null, pending_up: [] };
			return;
		}

		let entry = { cfg: cfg, ctx: null, pending_up: [] };

		entry.ctx = context_mod.create({
			name: name,
			modem: mentry.modem,
			config: cfg,
			timing: opts?.ctx_timing,
			deps: {
				log: (level, msg) => log(level, sprintf('context %s: %s', name, msg)),
				on_event: (ctx, event, data) => on_context_event(name, ctx, event, data),
			},
		});

		self.contexts[name] = entry;
	};

	// --- public API --------------------------------------------------------

	self.apply_config = function(parsed) {
		// v1 reload semantics: tear down everything, then rebuild
		self.shutdown();

		// aggregate mux requirements per modem before starting them
		let mux_by_modem = {};

		for (let name, cfg in parsed.contexts) {
			if (cfg.mux_id > 0) {
				let mi = mux_by_modem[cfg.modem] = mux_by_modem[cfg.modem] ?? { list: [] };

				push(mi.list, { id: cfg.mux_id, name: cfg.mux_link, mtu: cfg.mtu });
			}
		}

		for (let name, cfg in parsed.modems)
			start_modem(name, cfg, mux_by_modem[name]);

		for (let name, cfg in parsed.contexts)
			start_context(name, cfg);
	};

	self.resolve_context = function(ref) {
		if (self.contexts[ref])
			return ref;

		for (let name, entry in self.contexts)
			if (entry.cfg.interface == ref)
				return name;

		return null;
	};

	self.context_up = function(ref, cb) {
		let name = self.resolve_context(ref);
		let entry = name ? self.contexts[name] : null;

		if (!entry?.ctx)
			return cb({ error: 'no_such_context', ref: ref });

		let modem = entry.ctx.modem;

		if (modem.state == 'SIM_BLOCKED')
			return cb({ error: 'sim_blocked' });

		if (entry.ctx.state == 'CONNECTED')
			return cb(null, self._up_result(name, entry));

		if (modem.state != 'READY') {
			// queue until the modem reports ready; guard against waiting forever
			log('info', sprintf('context %s: modem not ready (%s), queueing activation',
				name, modem.state));

			let fired = false;
			let guarded = (err, res) => {
				if (fired)
					return;

				fired = true;
				cb(err, res);
			};

			push(entry.pending_up, guarded);

			uloop.timer(UP_GUARD_MS, () => {
				// drop from queue if still pending
				entry.pending_up = filter(entry.pending_up, (p) => p != guarded);
				guarded({ error: 'timeout', modem_state: modem.state });
			});

			return;
		}

		entry.ctx.up((err, settings) => {
			if (err)
				return cb(err);

			cb(null, self._up_result(name, entry));
		});
	};

	// apply the effective MTU on the l3 link (old use_pushed_mtu semantics,
	// moved out of the shell shim so it runs natively via rtnl)
	let apply_mtu = (name, entry, netdev) => {
		let fx = deps.datapath_fx;

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

		log('info', sprintf('context %s: applying MTU %d on %s', name, mtu, netdev));

		if (!fx.link_set(netdev, { mtu: mtu }))
			log('warn', sprintf('context %s: setting MTU %d on %s failed%s', name, mtu, netdev,
				fx.last_error ? sprintf(': %s', fx.last_error) : ''));

		let v6mtu = sprintf('/proc/sys/net/ipv6/conf/%s/mtu', netdev);

		if (fx.exists(v6mtu) && !fx.write(v6mtu, sprintf('%d', mtu)))
			log('warn', sprintf('context %s: setting IPv6 MTU on %s failed', name, netdev));
	};

	// make sure IPv6 is enabled on the l3 link before netifd configures it
	// (old behavior: sysctl net.ipv6.conf.$dev.disable_ipv6=0)
	let enable_ipv6 = (name, entry, netdev) => {
		let fx = deps.datapath_fx;

		if (!fx || !netdev || !entry.ctx.settings?.ipv6)
			return;

		let path = sprintf('/proc/sys/net/ipv6/conf/%s/disable_ipv6', netdev);

		if (fx.exists(path) && trim(fx.read(path) ?? '') != '0' && !fx.write(path, '0'))
			log('warn', sprintf('context %s: enabling IPv6 on %s failed', name, netdev));
	};

	self._up_result = function(name, entry) {
		let mentry = self.modems[entry.cfg.modem];
		let netdev = mentry?.netdev;

		// muxed contexts use their mux child link (configured name or the
		// default parent+mN scheme)
		if (entry.cfg.mux_id > 0 && netdev)
			netdev = entry.cfg.mux_link ?? sprintf('%sm%d', netdev, entry.cfg.mux_id);

		apply_mtu(name, entry, netdev);
		enable_ipv6(name, entry, netdev);

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
		};
	};

	self.context_down = function(ref, cb) {
		let name = self.resolve_context(ref);
		let entry = name ? self.contexts[name] : null;

		if (!entry?.ctx)
			return cb({ error: 'no_such_context', ref: ref });

		entry.ctx.down(() => cb(null, {}));
	};

	self.context_status = function(ref) {
		let name = self.resolve_context(ref);
		let entry = name ? self.contexts[name] : null;

		if (!entry?.ctx)
			return { error: 'no_such_context', ref: ref };

		return entry.ctx.status();
	};

	self.status = function() {
		let modems = {};

		for (let name, entry in self.modems) {
			modems[name] = {
				device: entry.device,
				netdev: entry.netdev,
				state: entry.modem?.state ?? 'UNRESOLVED',
				model: entry.modem?.info?.model,
				revision: entry.modem?.info?.revision,
				imei: entry.modem?.info?.imei,
				at_tty: entry.modem?.at_tty,
				registration: entry.modem?.reg,
				qmi_errors: entry.modem?.counters?.qmi_errors,
				attempts: entry.modem?.counters?.attempts,
			};
		}

		let contexts = {};

		for (let name, entry in self.contexts) {
			contexts[name] = {
				interface: entry.cfg.interface,
				modem: entry.cfg.modem,
				mux_id: entry.cfg.mux_id,
				state: entry.ctx?.state ?? 'UNBOUND',
			};
		}

		return { modems: modems, contexts: contexts };
	};

	self.modem_signal = function(ref) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return { error: 'no_such_modem', ref: ref };

		return entry.modem.signal ?? {};
	};

	self.modem_cells = function(ref) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return { error: 'no_such_modem', ref: ref };

		return {
			registration: entry.modem.reg,
			signal: entry.modem.signal,
			cells: entry.modem.cells,
		};
	};

	self.modem_location = function(ref) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return { error: 'no_such_modem', ref: ref };

		if (!entry.modem.loc)
			return { error: 'location_disabled' };

		return entry.modem.location ?? { error: 'no_fix' };
	};

	self.modem_at = function(ref, command, cb, timeout) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return cb({ error: 'no_such_modem', ref: ref });

		if (!entry.modem.at)
			return cb({ error: 'no_at_port' });

		if (type(command) != 'string' || substr(uc(command), 0, 2) != 'AT')
			return cb({ error: 'invalid_command' });

		entry.modem.at.send(command, cb, { timeout: timeout });
	};

	self.modem_set_protocol = function(ref, target, cb) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return cb({ error: 'no_such_modem', ref: ref });

		entry.modem.switch_protocol(target, cb);
	};

	self.hotplug = function(action, devname) {
		log('info', sprintf('hotplug %s %s', action, devname));

		if (action == 'add') {
			// try to start modems that could not be resolved before (e.g.
			// wwand started before USB enumeration finished at boot)
			for (let name, entry in self.modems) {
				if (entry.modem)
					continue;

				start_modem(name, entry.cfg, entry.muxinfo);
			}

			// bind contexts that had no running modem at config time
			for (let name, entry in self.contexts)
				if (!entry.ctx)
					start_context(name, entry.cfg);
		}
		else if (action == 'remove') {
			for (let name, entry in self.modems) {
				if (entry.device && index(entry.device, devname) >= 0 && entry.modem) {
					entry.modem.stop();
					entry.modem = null;
					entry.device = entry.cfg.device;   // reset to configured value
				}
			}
		}
	};

	self.shutdown = function() {
		for (let name, entry in self.contexts)
			if (entry.ctx && entry.ctx.state != 'IDLE')
				entry.ctx.down(() => null);

		for (let name, entry in self.modems)
			if (entry.modem)
				entry.modem.stop();

		self.modems = {};
		self.contexts = {};
	};

	return self;
}
