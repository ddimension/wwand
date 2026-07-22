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
import * as fs from 'fs';
import * as modem_mod from './modem.uc';
import * as context_mod from './context.uc';
import * as sim from './sim.uc';

const UP_GUARD_MS = 150000;

// MBIM support is loaded lazily — a QMI-only install (the common case) never
// touches its ~1.4k lines or schema, trimming resident memory.
let mbim_mods = null;
function load_mbim() {
	// require() cannot load ES modules directly (`export` is a syntax error
	// in plain scripts) — go through the exportless mbim_lazy wrapper
	if (mbim_mods == null)
		mbim_mods = require('wwand.mbim_lazy');

	return mbim_mods;
}

// optional eSIM module (wwand-esim package): an exportless plain script so
// require() can load it; absent file => feature reports esim_not_installed
let esim_mod = null;
function load_esim() {
	if (esim_mod == null) {
		try {
			esim_mod = require('wwand.esim');
		}
		catch (e) {
			esim_mod = false;
		}
	}

	return esim_mod;
}

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

	// forward-declared: ucode closures capture only already-declared vars, and
	// these self-reference (the TDZ trap — see CLAUDE.md ucode gotchas)
	let clear_reconnect, retry_activate, enter_reconnecting, activate;

	let on_modem_event = (modem, event, data) => {
		switch (event) {
		case 'registered':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });

			// (re)establish interface-bound contexts sitting IDLE. Decide per
			// interface by its netifd state so the two paths never race on
			// ctx.up(): an interface still UP (survived a wwand restart, or a
			// permanent-down that the modem now recovered from is handled by the
			// down/up path) is ADOPTED in place (activate → 'up' → renew); an
			// interface that is DOWN is kicked so netifd re-runs setup.
			for (let name, entry in self.contexts) {
				if (entry.cfg.modem != modem.id || !entry.cfg.interface ||
				    !entry.ctx || entry.ctx.state != 'IDLE' || !entry.wanted)
					continue;

				let st = deps.iface_status ? deps.iface_status(entry.cfg.interface) : null;

				if (st?.up) {
					log('info', sprintf('adopting live interface %s after modem ready', entry.cfg.interface));
					retry_activate(name);
				}
				else if (deps.kick_interface) {
					log('info', sprintf('kicking interface %s after modem ready', entry.cfg.interface));
					deps.kick_interface(entry.cfg.interface);
				}
			}

			break;

		case 'sim_blocked':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			// terminal until operator action — down the interfaces (no hold)
			for (let name, entry in self.contexts) {
				if (entry.cfg.modem == modem.id && entry.cfg.interface) {
					clear_reconnect(name);
					if (deps.down_interface)
						deps.down_interface(entry.cfg.interface);
				}
			}
			break;

		case 'deregistered':
		case 'removed':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			break;
		}
	};

	// --- context lifecycle ------------------------------------------------
	// The daemon (not a per-interface monitor process) keeps each interface-
	// bound context up. A TRANSIENT loss keeps the netifd interface up and
	// reconnects the modem session in place (renew, no teardown → PD/VRF
	// dependencies preserved); only a PERMANENT loss or the bounded hold timeout
	// drives the interface down (accepting the flush). netifd runs the proto with
	// no-proto-task, so there is no monitor and no teardown-on-blip.
	let hold_max_ms = opts?.timing?.hold_max_ms ?? 90000;

	// forward-declared: retry_activate self-references (reschedule) and
	// enter_reconnecting references it — avoids the ucode TDZ trap.
	// bring context `name` up, cb(err, up_result). Shared by context_up (ubus,
	// replies to netifd) — queues on pending_up until the modem is READY.
	activate = (name, cb) => {
		let entry = self.contexts[name];

		if (!entry?.ctx)
			return cb({ error: 'no_such_context', ref: name });

		let modem = entry.ctx.modem;

		if (modem.state == 'SIM_BLOCKED')
			return cb({ error: 'sim_blocked' });

		if (entry.ctx.state == 'CONNECTED')
			return cb(null, self._up_result(name, entry));

		if (modem.state != 'READY') {
			log('info', sprintf('context %s: modem not ready (%s), queueing activation',
				name, modem.state));

			let fired = false;
			let guarded = (err, res) => { if (fired) return; fired = true; cb(err, res); };

			push(entry.pending_up, guarded);

			uloop.timer(UP_GUARD_MS, () => {
				entry.pending_up = filter(entry.pending_up, (p) => p != guarded);
				guarded({ error: 'timeout', modem_state: modem.state });
			});

			return;
		}

		entry.ctx.up((err) => {
			// registration was lost mid-attempt: the context aborted without
			// climbing the recovery ladder — requeue until the modem is READY
			// again (keeps netifd's setup long-poll open instead of failing)
			if (err?.error == 'suspended')
				return activate(name, cb);

			cb(err, err ? null : self._up_result(name, entry));
		});
	};

	clear_reconnect = (name) => {
		let entry = self.contexts[name];

		if (!entry)
			return;

		if (entry.retry_timer) { entry.retry_timer.cancel(); entry.retry_timer = null; }
		if (entry.hold_timer)  { entry.hold_timer.cancel();  entry.hold_timer = null; }
		entry.retry_n = 0;
	};

	// internal reconnect attempt with capped backoff; self-schedules until the
	// context reaches CONNECTED (the 'up' event then clears reconnect state and
	// renews netifd in place) or enter_reconnecting's hold timer gives up. Does
	// NOT use pending_up — it is the daemon's own supervisor loop.
	retry_activate = (name) => {
		let entry = self.contexts[name];

		if (!entry?.ctx || !entry.wanted || entry.ctx.state == 'CONNECTED')
			return;

		let modem = entry.ctx.modem;

		if (modem.state == 'SIM_BLOCKED')
			return;   // permanent; handled by the sim_blocked path (down)

		let schedule = () => {
			entry.retry_n = (entry.retry_n ?? 0) + 1;
			let delay = min(entry.retry_n * (opts?.timing?.backoff_min ?? 2000),
			                opts?.timing?.backoff_max ?? 30000);
			entry.retry_timer = uloop.timer(delay, () => {
				entry.retry_timer = null;
				retry_activate(name);
			});
		};

		if (modem.state != 'READY' || entry.ctx.state != 'IDLE')
			return schedule();   // wait for recovery / an in-flight attempt

		entry.ctx.up((err) => {
			if (err && entry.wanted && entry.ctx?.state != 'CONNECTED')
				schedule();
			// success is handled by the 'up' event (clear_reconnect + renew)
		});
	};

	// a transient loss: keep the interface up and reconnect in place; bound the
	// blackhole with a hold timer that downs the interface if we never recover.
	enter_reconnecting = (name) => {
		let entry = self.contexts[name];

		if (!entry?.ctx || !entry.wanted || entry.hold_timer)
			return;   // not wanted, or already reconnecting

		entry.hold_timer = uloop.timer(hold_max_ms, () => {
			entry.hold_timer = null;

			if (entry.ctx?.state != 'CONNECTED') {
				log('warn', sprintf('context %s: reconnect hold expired, downing %s',
					name, entry.cfg.interface));
				clear_reconnect(name);

				if (deps.down_interface && entry.cfg.interface)
					deps.down_interface(entry.cfg.interface);
			}
		});

		retry_activate(name);
	};

	let on_context_event = (name, ctx, event, data) => {
		let entry = self.contexts[name];

		switch (event) {
		case 'up':
			// a working data connection resets the recovery ladder
			ctx.modem.note_connect_success();
			clear_reconnect(name);
			emit('wwand.context', { context: name, interface: entry?.cfg?.interface, event: event });
			// push settings to netifd in place. During the initial netifd setup
			// the interface is not yet IFS_UP so this renew is a no-op (setup's
			// own proto_send_update applies); after a reconnect/adoption it is
			// what re-applies the config — never a teardown.
			if (deps.renew_interface && entry?.cfg?.interface)
				deps.renew_interface(entry.cfg.interface);
			break;

		case 'error':
			// failed activation climbs the recovery ladder (old connecttries) —
			// but not when the modem lost registration mid-attempt: no service
			// is not a modem fault the ladder could fix
			if (ctx.modem.state == 'READY')
				ctx.modem.note_connect_failure();
			emit('wwand.context', { context: name, interface: entry?.cfg?.interface, event: event });
			if (entry?.wanted)
				enter_reconnecting(name);
			break;

		case 'zero_rx':
			log('err', sprintf('context %s: zero-rx watchdog tripped', name));
			ctx.modem.trip_zero_rx();
			if (entry?.wanted)
				enter_reconnecting(name);
			break;

		case 'down':
		case 'suspend':
			emit('wwand.context', {
				context: name,
				interface: entry?.cfg?.interface,
				event: event,
				...(event == 'down' ? { reason: data?.reason } : {}),
			});
			// Hold the interface up and reconnect in place. 'down/admin' comes
			// from our own context_down, which already cleared `wanted`, so this
			// no-ops there. All other drops (disconnected, modem_lost, suspend)
			// are transient → reconnect; the hold timer bounds the blackhole.
			if (entry?.wanted)
				enter_reconnecting(name);
			break;

		case 'settings':
			// the modem pushed new IP settings while connected — ask netifd to
			// renew the interface in place (no teardown). netifd re-runs the
			// proto renew handler, which re-reads context_settings.
			if (deps.renew_interface && entry?.cfg?.interface)
				deps.renew_interface(entry.cfg.interface);
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

		// the bound driver selects QMI vs MBIM (config 'protocol' can pin it)
		let proto = cfg.protocol;

		if (proto == null || proto == 'auto')
			proto = (deps.resolve_protocol ? deps.resolve_protocol(device) : null) ?? 'qmi';

		entry.protocol = proto;

		let ep_id = cfg.ep_id;

		if (ep_id == null && deps.resolve_ep_id)
			ep_id = deps.resolve_ep_id(cfg, device, entry.netdev);

		let common = {
			id: name,
			device: device,
			config: cfg,
			timing: self.timing,
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
		};

		if (proto == 'mbim') {
			entry.modem = load_mbim().modem.create({
				...common,
				datapath: {
					netdev: entry.netdev,
					mux_links: muxinfo?.list ?? [],
					fx: deps.datapath_fx,
				},
			});
		}
		else {
			entry.modem = modem_mod.create({
				...common,
				datapath: {
					netdev: entry.netdev,
					ep_id: ep_id,
					mux: cfg.mux,
					dgram_size: cfg.dl_datagram_max_size,
					mux_links: muxinfo?.list ?? [],
					fx: deps.datapath_fx,
				},
			});
		}

		entry.modem.start();
	};

	let start_context = (name, cfg) => {
		let mentry = self.modems[cfg.modem];

		// interface-bound contexts default to wanted=true so the daemon
		// (re)establishes them on modem-ready without waiting for netifd — this
		// is what adopts a session that survived a wwand restart.
		let base = { cfg: cfg, ctx: null, pending_up: [], wanted: (cfg.interface != null),
		             retry_timer: null, hold_timer: null, retry_n: 0 };

		if (!mentry?.modem) {
			log('warn', sprintf('context %s: modem %s not started', name, cfg.modem));
			self.contexts[name] = base;
			return;
		}

		let entry = base;
		let factory = (mentry.protocol == 'mbim') ? load_mbim().context : context_mod;

		entry.ctx = factory.create({
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

	let config_sig = null;

	self.apply_config = function(parsed) {
		// unchanged modem/context config is a no-op: the reload trigger also
		// fires for unrelated /etc/config/network edits (LAN etc.), and the
		// v1 reload semantics below are destructive (WAN bounce)
		let sig = sprintf('%J', { m: parsed.modems, c: parsed.contexts });

		if (sig == config_sig)
			return;

		config_sig = sig;

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

		// netifd asked us to be up → mark the desired state so the daemon keeps
		// it up (reconnects in place) until an explicit context_down.
		entry.wanted = true;
		activate(name, cb);
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

	// l3 device netdev for a context: parent netdev, MBIM VLAN sub-device or
	// QMAP mux child depending on protocol/mux config.
	let derive_netdev = (entry) => {
		let mentry = self.modems[entry.cfg.modem];
		let netdev = mentry?.netdev;

		if (mentry?.protocol == 'mbim') {
			// MBIM sessions: session 0 is the parent netdev, sessions > 0 are
			// VLAN sub-devices tagged with the session id — named after the
			// context's mux_link so netifd's device binding matches
			if (entry.cfg.mux_id > 0 && netdev)
				netdev = entry.cfg.mux_link ?? sprintf('%s.%d', netdev, entry.cfg.mux_id);
		}
		else if (entry.cfg.mux_id > 0 && netdev) {
			// QMAP muxed contexts use their mux child link
			netdev = entry.cfg.mux_link ?? sprintf('%sm%d', netdev, entry.cfg.mux_id);
		}

		return netdev;
	};

	// the settings payload the proto shim consumes (context_up / renew).
	let settings_result = (name, entry, netdev) => ({
		up: true,
		context: name,
		interface: entry.cfg.interface,
		netdev: netdev,
		mtu: entry.cfg.mtu ?? entry.ctx.settings?.mtu,
		pushed_mtu: entry.ctx.settings?.mtu,
		use_pushed_mtu: entry.cfg.use_pushed_mtu,
		ipv4: entry.ctx.settings?.ipv4,
		ipv6: entry.ctx.settings?.ipv6,
	});

	self._up_result = function(name, entry) {
		let netdev = derive_netdev(entry);

		apply_mtu(name, entry, netdev);
		enable_ipv6(name, entry, netdev);

		return settings_result(name, entry, netdev);
	};

	// read-only current settings for the netifd renew path: same shape as
	// _up_result but without the MTU/IPv6 side effects and without touching
	// the modem. Returns { up: false } unless the context is connected.
	self.context_settings = function(ref) {
		let name = self.resolve_context(ref);
		let entry = name ? self.contexts[name] : null;

		if (!entry?.ctx || entry.ctx.state != 'CONNECTED')
			return { up: false };

		return settings_result(name, entry, derive_netdev(entry));
	};

	self.context_down = function(ref, cb) {
		let name = self.resolve_context(ref);
		let entry = name ? self.contexts[name] : null;

		if (!entry?.ctx)
			return cb({ error: 'no_such_context', ref: ref });

		// netifd tore the interface down (admin/config or our own down drive) →
		// we no longer want it up; stop the reconnect loop.
		entry.wanted = false;
		clear_reconnect(name);
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
				last_error: entry.ctx?.last_error,
			};
		}

		return { modems: modems, contexts: contexts };
	};

	// band mask <-> band-number-list conversion. Done daemon-side on purpose:
	// u64 masks lose precision in LuCI's JS numbers (> 2^53), band lists
	// survive JSON. Bit n-1 across the mask words = band n; bit 63 of a word
	// is skipped (no such band exists, and 1<<63 goes negative in int64).
	let mask_to_bands = (masks) => {
		let out = [];

		for (let w = 0; w < length(masks); w++) {
			let m = masks[w] ?? 0;

			for (let b = 0; b < 63; b++)
				if (m & (1 << b))
					push(out, w * 64 + b + 1);
		}

		return out;
	};

	let bands_to_masks = (bands, words) => {
		let masks = [];

		for (let i = 0; i < words; i++)
			push(masks, 0);

		for (let n in bands) {
			let bit = +n - 1;
			let w = int(bit / 64);

			if (bit >= 0 && w < words && (bit % 64) < 63)
				masks[w] |= (1 << (bit % 64));
		}

		return masks;
	};

	// current NAS system-selection preferences (settings editor, read path)
	// resolve a modem ref for a cb-style ubus method: returns the entry, or
	// reports no_such_modem via cb and returns null (caller returns on null)
	let check_modem = (ref, cb) => {
		let entry = self.modems[ref];

		if (entry?.modem)
			return entry;

		cb({ error: 'no_such_modem', ref: ref });

		return null;
	};

	self.modem_get_settings = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let nas = entry.modem.nas;

		if (!nas)
			return cb({ error: 'no_nas_client' });

		nas.request('GET_SYSTEM_SELECTION_PREFERENCE', {}, (err, data) => {
			if (err)
				return cb({ error: 'qmi', detail: err });

			delete data._result;

			let e = data.ext_lte_band;

			data.lte_bands = mask_to_bands(e
				? [ e.mask_low, e.mask_mid_low, e.mask_mid_high, e.mask_high ]
				: [ data.lte_band_preference ?? 0 ]);

			for (let key in [ 'nr5g_sa_band', 'nr5g_nsa_band' ]) {
				let s = data[key];

				data[key + 's'] = s ? mask_to_bands([ s.m0, s.m1, s.m2, s.m3,
				                                      s.m4, s.m5, s.m6, s.m7 ]) : [];
			}

			cb(null, data);
		});
	};

	// physical SIM slots: list (status page) and switch (guarded; the modem
	// re-initializes the SIM stack after a switch, recovery handles the rest)
	self.modem_sim_slots = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		sim.slot_status(entry.modem, (err, slots) =>
			cb(err ? { error: 'qmi', detail: err } : null, err ? null : { slots: slots }));
	};

	self.modem_sim_switch_slot = function(ref, physical, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (!(physical > 0))
			return cb({ error: 'invalid_slot' });

		sim.switch_slot(entry.modem, physical, (err) => {
			if (err)
				return cb({ error: 'qmi', detail: err });

			// a different slot may hold a different eUICC (removable eUICCs) —
			// drop the cached eSIM/APDU backends so they are re-probed
			delete entry.modem._esim_be;
			delete entry.modem._apdu_be;

			log('notice', sprintf('modem %s: switched to SIM slot %d', ref, physical));
			cb(null, { slot: physical });
		});
	};

	// raw APDU channel (eSIM foundation; also used by the lpac glue).
	// op: 'open' {slot, aid} -> {channel, select_response}
	//     'send' {slot, channel, apdu} -> {response}
	//     'close' {slot, channel} -> {}
	self.modem_apdu = function(ref, op, params, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let slot = +(params?.slot ?? 1);

		switch (op) {
		case 'open':
			return sim.apdu_open(entry.modem, slot, params?.aid ?? '', (err, res) =>
				cb(err ? { error: 'qmi', detail: err } : null, res));

		case 'send':
			return sim.apdu_send(entry.modem, slot, +(params?.channel ?? 0), params?.apdu ?? '',
				(err, res) => cb(err ? { error: 'qmi', detail: err } : null,
				                 err ? null : { response: res }));

		case 'close':
			return sim.apdu_close(entry.modem, slot, +(params?.channel ?? 0), (err) =>
				cb(err ? { error: 'qmi', detail: err } : null, err ? null : {}));

		default:
			return cb({ error: 'invalid_op', op: op });
		}
	};

	// eSIM profile management (optional wwand-esim package). op:
	// 'profiles' | 'eid' | 'enable' | 'disable' | 'delete' (iccid required
	// for the latter three). slot defaults to the active physical slot? No —
	// explicit slot, default 1.
	// Drive a host-side lpac eSIM op (download / chip / notif-list /
	// notif-process) INLINE: spawn lpac (LPAC_APDU=stdio), drain its JSON APDU
	// requests non-blocking via uloop, answer each straight from sim.apdu_* (no
	// ubus, no jsonfilter); lpac does the SM-DP+ HTTPS. Progress + lpac stderr
	// go to esim_logf (streamed by download_status, mirrored to the wwand log).
	let esim_logf = '/tmp/wwand/esim-download.log';
	let esim_lpac = '/usr/lib/lpac';

	let esim_lpac_run = (ref, slot, op, code, conf, on_done) => {
		let entry = self.modems[ref];

		if (fs.access(esim_lpac) != true)
			return false;   // wwand-lpac not installed — caller reports it

		let cmd;
		switch (op) {
		case 'download':      cmd = sprintf("profile download -a '%s'%s", code ?? '',
		                                    length(conf ?? '') ? sprintf(" -c '%s'", conf) : ''); break;
		case 'notif-list':    cmd = 'notification list'; break;
		case 'notif-process': cmd = 'notification process -a'; break;
		default:              cmd = 'chip info';
		}

		let tr = fs.open(esim_logf, 'w'); if (tr) tr.close();   // truncate the log
		let logf = fs.open(esim_logf, 'a');

		// native spawn gives a non-blocking stdout + writable stdin; the shell
		// only sets the env and appends lpac's stderr to the log
		let qmit = require('wwand_io');
		let h = qmit.spawn([ '/bin/sh', '-c',
			sprintf("mkdir -p /tmp/wwand; exec env LPAC_APDU=stdio LPAC_HTTP=curl %s %s 2>>%s",
				esim_lpac, cmd, esim_logf) ]);

		if (!h) { if (logf) logf.close(); return null; }

		log('notice', sprintf('modem %s: esim[%s]: lpac stdio (inline bridge)', ref, op));

		let chan = 0, uh = null, buf = '';

		let logline = (s) => {
			if (logf) { logf.write(s + '\n'); logf.flush(); }
			log('notice', sprintf('modem %s: esim[%s]: %s', ref, op, s));
		};
		let send = (ecode, data) =>
			h.write(sprintf('{"type":"apdu","payload":{"ecode":%d,"data":"%s"}}\n', ecode, data ?? ''));
		let field = (s, re) => { let m = match(s, re); return m ? m[1] : null; };

		let finish;   // forward-declare (ucode TDZ on self-referencing arrows)
		finish = () => {
			if (uh) { uh.delete(); uh = null; }
			let ec = h.close();   // reaps the child, returns its exit status
			if (logf) { logf.close(); logf = null; }
			on_done(ec == 0 ? null : { error: 'lpac', code: ec }, trim(fs.readfile(esim_logf) ?? ''));
		};

		// stdout carries only the protocol's JSON objects; fields are pulled with
		// match() as ucode's json() throws uncatchably. APDU ops dispatch async
		// (their reply is written when the modem answers); progress/lpa just log.
		let handle_line = (s) => {
			if (substr(s, 0, 1) != '{') { if (length(s)) logline(s); return; }

			let mtype = field(s, /"type": *"([a-z]+)"/);
			if (mtype == 'apdu') {
				let func = field(s, /"func": *"([a-z_]+)"/);
				let param = field(s, /"param": *"([0-9A-Fa-f]*)"/) ?? '';
				switch (func) {
				case 'connect':
				case 'disconnect':
					send(0, ''); break;
				case 'logic_channel_open':
					sim.apdu_open(entry.modem, slot, param, (err, res) => {
						chan = res?.channel ?? 0;
						send(err ? -1 : chan, '');
					}); break;
				case 'transmit':
					// apdu_send yields the response hex directly (modem_apdu is
					// what wraps it as {response}); use it as-is
					sim.apdu_send(entry.modem, slot, chan, param, (err, res) =>
						send(err ? -1 : 0, err ? '' : (res ?? ''))); break;
				case 'logic_channel_close':
					sim.apdu_close(entry.modem, slot, chan, () => send(0, '')); break;
				default:
					send(-1, '');
				}
			} else if (mtype == 'progress')
				logline('progress: ' + (field(s, /"message": *"([^"]*)"/) ?? 'step'));
			else if (mtype == 'lpa') {
				logline(sprintf('result: code=%s %s',
					field(s, /"code": *(-?[0-9]+)/) ?? '?',
					field(s, /"message": *"([^"]*)"/) ?? ''));
				let d = field(s, /"data": *"([^"]*)"/);
				if (d) logline('data: ' + d);
			}
		};

		// h.read() is non-blocking (edge-triggered fd): drain all available
		// bytes, then process every complete line
		uh = uloop.handle(h.fileno(), () => {
			while (true) {
				let chunk = h.read();
				if (chunk === false) return finish();   // EOF: lpac exited
				if (chunk === null) break;               // no more data right now
				buf += chunk;
			}

			let nl;
			while ((nl = index(buf, '\n')) >= 0) {
				let s = trim(substr(buf, 0, nl));
				buf = substr(buf, nl + 1);
				if (length(s)) handle_line(s);
			}
		}, uloop.ULOOP_READ);

		return h;
	};

	// host-side download via lpac (stdio bridge over wwand's APDU channel).
	// On success the eUICC queues an install notification that MUST be delivered
	// to the SM-DP+ (ES9+) to confirm the install — with auto_notify (default)
	// we chain notif-process right away; disable it only for testing.
	let esim_download_lpac = (ref, slot, code, conf, cb, auto_notify) => {
		self._esim_dl = { state: 'running', via: 'lpac', logf: esim_logf, phase: 'download' };

		let finish = (state, extra) => {
			self._esim_dl = { state, via: 'lpac', ...extra };
			log('notice', sprintf('modem %s: eSIM download %s%s', ref, state,
				extra?.notified != null ? sprintf(' (ack %s)', extra.notified ? 'sent' : 'skipped') : ''));
		};

		let p = esim_lpac_run(ref, slot, 'download', code, conf, (err, out) => {
			// the bridge exits 0 even when the SM-DP+ refuses; the real verdict
			// is lpac's own result line
			let ok = !err && match(out ?? '', /result:[^\n]*code=0/);

			if (!ok)
				return finish('failed', { code: err?.code ?? -1, log: out, phase: 'download' });

			if (!auto_notify)
				return finish('done', { code: 0, log: out, phase: 'download', notified: false });

			// standard install acknowledgement to the operator
			self._esim_dl = { state: 'running', via: 'lpac', logf: esim_logf, phase: 'notify', log: out };
			let np = esim_lpac_run(ref, slot, 'notif-process', '', '', (nerr, nout) => {
				finish('done', { code: 0, phase: 'notify', notified: !nerr,
				                 log: trim((out ?? '') + '\n' + (nout ?? '')) });
			});
			if (!np)
				finish('done', { code: 0, log: out, phase: 'download', notified: false });
		});

		if (!p) {
			self._esim_dl = { state: 'failed', via: 'lpac', code: -1 };
			return cb({ error: 'esim_not_installed' });
		}

		cb(null, { started: true, via: 'lpac' });
	};

	self.modem_esim = function(ref, op, params, cb) {
		let esim = load_esim();

		if (!esim)
			return cb({ error: 'esim_not_installed' });

		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let slot = +(params?.slot ?? 1);
		let iccid = params?.iccid ?? '';
		let done = (err, res) => cb(err ? { error: 'esim', detail: err } : null, res);

		switch (op) {
		case 'backend':
			return esim.backend(entry.modem, slot, (be) => cb(null, { backend: be }));

		case 'download': {
			if (self._esim_dl?.state == 'running')
				return cb({ error: 'busy' });

			let code = params?.activation_code ?? '';

			if (!length(code))
				return cb({ error: 'missing_argument' });

			// shell-safe: activation codes are LPA:1$host$token style
			if (!match(code, /^[A-Za-z0-9$:._+-]+$/) ||
			    (params?.confirmation_code != null &&
			     !match(params.confirmation_code, /^[A-Za-z0-9._-]*$/)))
				return cb({ error: 'invalid_argument' });

			// standard: acknowledge the install to the operator afterwards;
			// callers pass auto_notify=false only for testing
			let auto_notify = params?.auto_notify ?? true;

			// pick the path by backend: AT modems download internally
			// (AT+QESIM, no host data), QMI modems use the host-side lpac glue
			return esim.backend(entry.modem, slot, (be) => {
				if (be == 'at') {
					self._esim_dl = { state: 'running', via: 'modem' };
					esim.download_at(entry.modem, code, params?.confirmation_code, (err, res) => {
						self._esim_dl = err
							? { state: 'failed', via: 'modem', error: err.error, ret: err.ret }
							: { state: 'done', via: 'modem', ret: res?.ret };
						log('notice', sprintf('modem %s: eSIM AT download %s', ref, self._esim_dl.state));
					});

					return cb(null, { started: true, via: 'modem' });
				}

				esim_download_lpac(ref, slot, code, params?.confirmation_code, cb, auto_notify);
			});
		}

		case 'download_status': {
			let st = self._esim_dl ?? { state: 'idle' };

			// stream the live lpac output while a run is in progress
			if (st.state == 'running' && st.logf && deps.datapath_fx?.read)
				st = { ...st, log: trim(deps.datapath_fx.read(st.logf) ?? '') };

			return cb(null, st);
		}

		// pending eUICC notifications: after any profile op the eUICC queues
		// notifications that must be delivered to the SM-DP+ (ES9+) to confirm
		// the operation — 'notifications' lists them, 'notify' sends them.
		case 'notifications':
			if (!esim_lpac_run(ref, slot, 'notif-list', '', '', (err, out) =>
				cb(err ? { error: 'lpac', ...err } : null, { ok: !err, log: out })))
				return cb({ error: 'esim_not_installed' });
			return;

		case 'notify':
			if (self._esim_dl?.state == 'running')
				return cb({ error: 'busy' });

			self._esim_dl = { state: 'running', via: 'notify', logf: esim_logf };

			if (!esim_lpac_run(ref, slot, 'notif-process', '', '', (err, out) => {
				self._esim_dl = { state: err ? 'failed' : 'done', via: 'notify',
				                  code: err?.code ?? 0, log: out };
				log('notice', sprintf('modem %s: eSIM notifications %s', ref, self._esim_dl.state));
			}))
				return cb({ error: 'esim_not_installed' });
			return cb(null, { started: true, via: 'notify' });

		case 'profiles': return esim.profiles(entry.modem, slot, done);
		case 'eid':      return esim.get_eid(entry.modem, slot, done);
		case 'enable':
			if (!length(iccid)) return cb({ error: 'missing_argument' });
			return esim.enable(entry.modem, slot, iccid, (err, res) => {
				if (!err)
					log('notice', sprintf('modem %s: eSIM profile %s enabled', ref, iccid));
				done(err, res);
			});
		case 'disable':
			if (!length(iccid)) return cb({ error: 'missing_argument' });
			return esim.disable(entry.modem, slot, iccid, done);
		case 'delete':
			if (!length(iccid)) return cb({ error: 'missing_argument' });
			return esim.del(entry.modem, slot, iccid, done);
		default:
			return cb({ error: 'invalid_op', op: op });
		}
	};

	// SIM PLMN selector lists (settings editor; user list is editable on SIMs
	// that carry EF 6F60 — absent lists read as null)
	self.modem_plmn_lists = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (!entry.modem.uim)
			return cb({ error: 'no_uim_client' });

		sim.read_plmn_lists(entry.modem, (lists) => cb(null, lists));
	};

	// settable NAS preferences (settings editor, write path). Whitelist with
	// expected blobmsg types — anything else is rejected before it reaches
	// the modem.
	const SETTABLE_PREFS = {
		mode_preference: 'int', band_preference: 'int',
		roaming_preference: 'int', lte_band_preference: 'int',
		usage_preference: 'int',
		ext_lte_band: 'object', nr5g_sa_band: 'object', nr5g_nsa_band: 'object',
	};

	self.modem_set_settings = function(ref, settings, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let nas = entry.modem.nas;

		if (!nas)
			return cb({ error: 'no_nas_client' });

		// band-number lists (LuCI-safe) are converted to masks here
		settings = { ...(settings ?? {}) };

		if (type(settings.lte_bands) == 'array') {
			let m = bands_to_masks(settings.lte_bands, 4);

			settings.lte_band_preference = m[0];
			settings.ext_lte_band = { mask_low: m[0], mask_mid_low: m[1],
			                          mask_mid_high: m[2], mask_high: m[3] };
			delete settings.lte_bands;
		}

		for (let key in [ 'nr5g_sa_bands', 'nr5g_nsa_bands' ]) {
			if (type(settings[key]) != 'array')
				continue;

			let m = bands_to_masks(settings[key], 8);

			settings[substr(key, 0, length(key) - 1)] = {
				m0: m[0], m1: m[1], m2: m[2], m3: m[3],
				m4: m[4], m5: m[5], m6: m[6], m7: m[7],
			};
			delete settings[key];
		}

		let args = {};

		for (let key, val in settings) {
			if (SETTABLE_PREFS[key] != type(val))
				return cb({ error: 'invalid_setting', key: key });

			args[key] = val;
		}

		if (!length(keys(args)))
			return cb({ error: 'missing_argument' });

		args.change_duration = 1;   // permanent (0 would revert on power cycle)

		nas.request('SET_SYSTEM_SELECTION_PREFERENCE', args, (err) => {
			if (err)
				return cb({ error: 'qmi', detail: err });

			log('notice', sprintf('modem %s: system selection preference set: %s',
				ref, join(' ', filter(keys(args), (k) => k != 'change_duration'))));
			cb(null, { applied: filter(keys(args), (k) => k != 'change_duration') });
		});
	};

	self.modem_signal = function(ref) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return { error: 'no_such_modem', ref: ref };

		// keep the fast refresh loop warm while a consumer is polling
		if (entry.modem.watch)
			entry.modem.watch();

		return entry.modem.signal ?? {};
	};

	self.modem_cells = function(ref) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return { error: 'no_such_modem', ref: ref };

		if (entry.modem.watch)
			entry.modem.watch();

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
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (!entry.modem.at)
			return cb({ error: 'no_at_port' });

		if (type(command) != 'string' || substr(uc(command), 0, 2) != 'AT')
			return cb({ error: 'invalid_command' });

		entry.modem.at.send(command, cb, { timeout: timeout });
	};

	self.modem_set_protocol = function(ref, target, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

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

					// detach this modem's contexts: their ctx objects are bound
					// to the dead modem and queued activations would wait on it
					// forever (protocol switch / USB replug / usb_repower). The
					// next 'add' rebuilds them against the fresh modem object.
					for (let cname, centry in self.contexts) {
						if (centry.cfg.modem != name || !centry.ctx)
							continue;

						clear_reconnect(cname);

						for (let p in centry.pending_up)
							p({ error: 'modem_removed' });

						centry.pending_up = [];
						centry.ctx = null;
					}
				}
			}
		}
	};

	// Destructive teardown for config reload/removal: bring every context down
	// (STOP_NETWORK) and stop the modems, then drop all state.
	self.shutdown = function() {
		for (let name, entry in self.contexts) {
			clear_reconnect(name);

			if (entry.ctx && entry.ctx.state != 'IDLE')
				entry.ctx.down(() => null);
		}

		for (let name, entry in self.modems)
			if (entry.modem)
				entry.modem.stop();

		self.modems = {};
		self.contexts = {};
	};

	// Non-destructive stop for a plain daemon exit/restart: do NOT bring
	// connected contexts down (the modem's PDP session and the netifd interface
	// survive) and do NOT drive interfaces down. With no-proto-task the WAN
	// stays up and traffic keeps flowing across the restart; the fresh daemon
	// adopts the live session on modem-ready. Just cancel our own timers.
	self.stop_local = function() {
		for (let name in keys(self.contexts))
			clear_reconnect(name);
	};

	return self;
}
