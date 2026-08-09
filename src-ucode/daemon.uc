// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — daemon core: owns modems and contexts, applies configuration,
// dispatches ubus ops. Transport/sysfs/ubus access is injected (opts.deps) so
// the core runs host-side against mocks.

'use strict';

import * as uloop from 'uloop';
import * as fs from 'fs';
import * as sim from './sim.uc';
import * as sms from './sms.uc';
import * as atcmd from './atcmd.uc';
import * as quirks from './modem_quirks.uc';
import * as apndb from './apndb.uc';
import * as netsel_ops from './netsel_ops.uc';

const UP_GUARD_MS = 150000;


// backends load lazily; a missing package returns null (cached) so start_modem
// reports it clearly instead of crashing.
let qmi_mods = null, qmi_unavailable = false;
function load_qmi() {
	if (qmi_unavailable)
		return null;

	if (qmi_mods == null) {
		try {
			qmi_mods = require('wwand.qmi_lazy');
		}
		catch (e) {
			qmi_unavailable = true;
			return null;
		}
	}

	return qmi_mods;
}

// lazy so a QMI-only install never loads MBIM's ~1.4k lines/schema.
let mbim_mods = null, mbim_unavailable = false;
function load_mbim() {
	// require() cannot load ES modules directly (`export` is a syntax error
	// in plain scripts) — go through the exportless mbim_lazy wrapper
	if (mbim_unavailable)
		return null;

	if (mbim_mods == null) {
		try {
			mbim_mods = require('wwand.mbim_lazy');
		}
		catch (e) {
			mbim_unavailable = true;
			return null;
		}
	}

	return mbim_mods;
}

// NCM support (cdc_ncm / cdc_ether, AT-controlled) is a separate package
// (wwand-ncm), loaded lazily the same way.
let ncm_mods = null, ncm_unavailable = false;
function load_ncm() {
	if (ncm_unavailable)
		return null;

	if (ncm_mods == null) {
		try {
			ncm_mods = require('wwand.ncm_lazy');
		}
		catch (e) {
			ncm_unavailable = true;
			return null;
		}
	}

	return ncm_mods;
}

// optional eSIM module (wwand-esim); absent => feature reports esim_not_installed
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

	// backend module loaders (overridable for tests)
	let load_qmi_fn = deps.load_qmi ?? load_qmi;
	let load_mbim_fn = deps.load_mbim ?? load_mbim;
	let load_ncm_fn = deps.load_ncm ?? load_ncm;

	// resolve a control protocol to its backend module + a human package name
	let backend_for = (proto) =>
		(proto == 'mbim') ? { be: load_mbim_fn(), pkg: 'wwand-mbim' } :
		(proto == 'ncm')  ? { be: load_ncm_fn(),  pkg: 'wwand-ncm' } :
		                    { be: load_qmi_fn(),  pkg: 'wwand-qmi' };

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
	let clear_reconnect, retry_activate, enter_reconnecting, activate, derive_netdev;
	let detach_modem;   // forward-declared: used by modem_removed above its definition
	let maybe_autosetup_fill;

	// --- modem event handlers ---------------------------------------------

	// modem reached service: write back l3 device names, run autosetup APN
	// fill, (re)establish this modem's IDLE interface-bound contexts.
	let modem_registered = (modem, data) => {
		// write the resolved l3 device name onto each interface as `option device`
		// (one explicit handle for VRF/firewall/LuCI). Idempotent; never clobbers a
		// user value. Gated by wwand_globals.write_device.
		if ((self.write_device ?? true) && deps.learn_device) {
			for (let cname, centry in self.contexts) {
				if (centry.cfg.modem != modem.id || !centry.cfg.interface)
					continue;

				let l3 = derive_netdev(centry);
				if (l3)
					deps.learn_device(centry.cfg.interface, l3);
			}
		}

		// autosetup phase 2 (one-shot): now the SIM is read, match ICCID/IMSI
		// against the APN table and copy values into uci (config is then the
		// source of truth). No match -> keep empty APN (SIM-provisioned attach).
		maybe_autosetup_fill(modem);

		// (re)establish IDLE interface-bound contexts. Decide per interface by
		// its netifd state so the two paths never race on ctx.up(): an interface
		// still UP is ADOPTED in place (activate → 'up' → renew); a DOWN one is
		// kicked so netifd re-runs setup.
		for (let name, entry in self.contexts) {
			if (entry.cfg.modem != modem.id || !entry.cfg.interface ||
			    !entry.ctx || entry.ctx.state != 'IDLE' || !entry.wanted)
				continue;

			let st = deps.iface_status ? deps.iface_status(entry.cfg.interface) : null;

			if (st?.up) {
				log('info', sprintf('adopting live interface %s after modem ready', entry.cfg.interface));
				retry_activate(name);
			}
			else if ((entry.cfg.auto ?? true) && deps.kick_interface) {
				// IDLE context while netifd holds the interface 'pending' = an
				// ORPHANED setup (e.g. a wwand restart mid-setup). 'up' no-ops on a
				// pending interface, so 'down' first, then the kick re-runs setup.
				if (st?.pending && deps.down_interface) {
					log('info', sprintf('interface %s stuck pending, resetting before setup', entry.cfg.interface));
					// mark the down as our own so context_down doesn't read it as
					// operator intent (clearing `wanted`) or kill the activation below
					entry._reset_pending = true;
					deps.down_interface(entry.cfg.interface);
				}

				// cdc_mbim/cdc_ncm: the data link's carrier follows the session,
				// and netifd won't run proto setup until the link is up — so connect
				// first, then kick (the 'up' event kicks once connected via
				// _kick_after_connect). QMI's mux link is stable, so kick it directly.
				let cf_proto = self.modems[modem.id]?.protocol;

				if (cf_proto == 'mbim' || cf_proto == 'ncm') {
					log('info', sprintf('connecting %s first (%s), then netifd', entry.cfg.interface, cf_proto));
					entry._kick_after_connect = true;
					retry_activate(name);
				}
				else {
					log('info', sprintf('kicking interface %s after modem ready', entry.cfg.interface));
					deps.kick_interface(entry.cfg.interface);
				}
			}
			else {
				// 'auto 0' and not up: leave it dormant until an explicit ifup
				log('debug', sprintf('interface %s is down and auto=0, not kicking', entry.cfg.interface));
			}
		}
	};

	// modem 'removed' (transport-level device gone): detach and enter the
	// boot-style waiting state. Presence is re-checked by the periodic tick —
	// NOT only by hotplug — because the 'add' may never fire.
	let modem_removed = (modem) => {
		let entry = self.modems[modem.id];

		if (!entry || entry.modem != modem)
			return;

		detach_modem(modem.id, entry);
		entry.control_note = 'waiting for modem (device vanished)';
		entry.waiting_since = time();
		entry._waiting_logged = time();
	};

	let modem_sim_blocked = (modem) => {
		for (let name, entry in self.contexts) {
			if (entry.cfg.modem == modem.id && entry.cfg.interface) {
				clear_reconnect(name);
				entry.wanted = false;
				if (deps.down_interface)
					deps.down_interface(entry.cfg.interface);
			}
		}
	};

	// learn-back: a config with no pinned IMEI records the discovered one so a
	// fresh install self-stabilises. Gated by auto_correct_config; only for a
	// real wwand_modem section (a synthesized compat modem has none to write).
	let modem_identity = (modem, data) => {
		if (deps.learn_identity && self.modems[modem.id] &&
		    !self.modems[modem.id].cfg?.imei &&
		    self.modems[modem.id].cfg?.auto_correct_config)
			deps.learn_identity(modem.id, data ?? {});
	};

	let modem_identity_mismatch = (modem, data) => {
		if (self.modems[modem.id])
			self.modems[modem.id].control_note = sprintf(
				'identity mismatch: configured IMEI %s, modem reports %s',
				data?.expected ?? '?', data?.found ?? '?');
	};

	let on_modem_event = (modem, event, data) => {
		// clear the one-shot manual-PIN-release flags so a later cycle never reuses them
		if (event == 'registered' || event == 'sim_blocked') {
			modem.pin_force = false;
			modem._pin_override = null;
		}

		// remember the SIM-block detail (reason + remaining PIN attempts) so
		// status()/LuCI can offer a manual release for the low-retry case
		if (event == 'sim_blocked')
			modem.sim_block = data ?? {};
		else if (event == 'registered')
			modem.sim_block = null;

		// mirror lifecycle events onto the bus for listeners
		switch (event) {
		case 'registered':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			return modem_registered(modem, data);

		case 'sim_blocked':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			return modem_sim_blocked(modem);

		case 'deregistered':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			return;

		// control transport reported the device gone (modem_common _device_gone):
		// detach and wait; the periodic tick re-checks presence, so the modem
		// recovers even when NO hotplug 'add' fires. HW-seen with a provider-side
		// (GDSP) SIM reset on the Huawei E392: the read fails while the device
		// stays on the bus, and the modem used to stay ABSENT until a reboot.
		case 'removed':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			return modem_removed(modem);

		// stable-identity gate (modem_common.check_identity): 'identity' fires
		// once the IMEI is known; 'identity_mismatch' = the pinned IMEI didn't
		// match this modem and bring-up halted.
		case 'identity':
			modem_identity(modem, data);
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			return;

		case 'identity_mismatch':
			modem_identity_mismatch(modem, data);
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			return;
		}
	};

	// --- context lifecycle ------------------------------------------------
	// The daemon (no per-interface monitor) keeps each context up. A TRANSIENT
	// loss keeps the netifd interface up and reconnects the session in place
	// (renew, no teardown → PD/VRF preserved); a PERMANENT loss or the hold
	// timeout drives the interface down. netifd runs the proto no-proto-task.
	let hold_max_ms = opts?.timing?.hold_max_ms ?? 90000;

	// how long to wait for a mode-switched PPP-only modem to re-enumerate before
	// flagging it stuck (the switch is once-guarded, so without this a reset that
	// never re-enumerates would leave the modem unmanaged forever).
	let modeswitch_liveness_ms = opts?.timing?.modeswitch_liveness_ms ?? 60000;

	// re-read the reconnect-hold ceiling live on reload; applied on the next
	// reconnect. Kept out of apply_config so a create-time timing override is
	// never clobbered by the config default.
	self.set_hold_max_ms = function(ms) {
		if (ms > 0)
			hold_max_ms = ms;
	};

	// autosetup phase 2: copy ICCID/IMSI-matched APN defaults into uci — once
	// per interface per boot, only for autosetup-created interfaces.
	let autosetup_done = {};

	maybe_autosetup_fill = (modem) => {
		if (!(self.autosetup ?? true))
			return;

		for (let name, entry in self.contexts) {
			if (entry.cfg.modem != modem.id || !entry.cfg.autosetup ||
			    !entry.cfg.interface || autosetup_done[name])
				continue;

			autosetup_done[name] = true;

			let info = self.modems[modem.id]?.modem?.info ?? {};
			let vals = apndb.lookup(info.iccid, info.imsi);

			if (!vals) {
				log('info', sprintf('autosetup: no APN-table match for %s (iccid %s, imsi %s) — keeping the SIM-provisioned attach',
					name, info.iccid ?? '?', info.imsi ?? '?'));
				continue;
			}

			if (!deps.autosetup_fill)
				continue;

			if (deps.autosetup_fill(entry.cfg.interface, vals)) {
				log('notice', sprintf('autosetup: %s defaults written to %s (apn %s) — reloading',
					vals.note ?? 'APN-table', entry.cfg.interface, vals.apn));

				// re-read config, then let netifd re-run proto setup
				if (self.reload)
					self.reload();

				if (deps.network_reload)
					deps.network_reload();
			}
		}
	};

	// forward-declared (retry_activate self-references, enter_reconnecting
	// references it) — avoids the ucode TDZ trap.
	// bring context `name` up; queues on pending_up until the modem is READY.
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
			log('info', sprintf('interface %s: modem not ready (%s), queueing activation',
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
			// registration lost mid-attempt: requeue until READY again (keeps
			// netifd's setup long-poll open instead of failing)
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

	// internal reconnect with capped backoff; self-schedules until CONNECTED or
	// enter_reconnecting's hold timer gives up. Daemon's own supervisor loop
	// (does NOT use pending_up).
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

	// transient loss: keep the interface up and reconnect in place; a hold timer
	// bounds the blackhole and downs the interface if we never recover.
	enter_reconnecting = (name) => {
		let entry = self.contexts[name];

		if (!entry?.ctx || !entry.wanted || entry.hold_timer)
			return;   // not wanted, or already reconnecting

		entry.hold_timer = uloop.timer(hold_max_ms, () => {
			entry.hold_timer = null;

			if (entry.ctx?.state != 'CONNECTED') {
				log('warn', sprintf('interface %s: reconnect hold expired, downing %s',
					name, entry.cfg.interface));
				clear_reconnect(name);

				// clear `wanted` now (not only when context_down later fires) so a
				// `registered` in the gap can't re-kick the interface we're tearing down.
				entry.wanted = false;

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
			// push settings to netifd in place (never a teardown). A no-op during
			// initial setup (not yet IFS_UP); re-applies config after reconnect/adoption.
			if (deps.renew_interface && entry?.cfg?.interface)
				deps.renew_interface(entry.cfg.interface);

			// MBIM connect-first: the session/link came up before netifd ran proto
			// setup — kick netifd now so it runs setup and adopts the live session.
			if (entry?._kick_after_connect) {
				entry._kick_after_connect = false;

				if (deps.kick_interface && entry.cfg.interface) {
					log('info', sprintf('kicking interface %s to adopt the connected mbim session', entry.cfg.interface));
					deps.kick_interface(entry.cfg.interface);
				}
			}
			break;

		case 'error':
			// failed activation climbs the recovery ladder — but not when the modem
			// lost registration mid-attempt: no service isn't a fault the ladder fixes
			if (ctx.modem.state == 'READY')
				ctx.modem.note_connect_failure();
			emit('wwand.context', { context: name, interface: entry?.cfg?.interface, event: event });
			if (entry?.wanted)
				enter_reconnecting(name);
			break;

		case 'zero_rx':
			log('err', sprintf('interface %s: zero-rx watchdog tripped', name));
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
			// Hold the interface up and reconnect in place. 'down/admin' from our
			// own context_down already cleared `wanted` (no-op here); all other
			// drops are transient → reconnect, bounded by the hold timer.
			if (entry?.wanted)
				enter_reconnecting(name);
			break;

		case 'settings':
			// modem pushed new IP settings — renew the interface in place (no
			// teardown); netifd re-reads context_settings.
			if (deps.renew_interface && entry?.cfg?.interface)
				deps.renew_interface(entry.cfg.interface);
			break;

		case 'modem_ready':
			if (entry && length(entry.pending_up)) {
				let pend = entry.pending_up;
				entry.pending_up = [];

				for (let p in pend)
					self.context_up(name, p);
			}

			break;
		}
	};

	// a PPP-only modem (serial port only) is mode-switched ONCE to a richer
	// usbnet mode, then left for hotplug to rebuild on re-enumeration (no modem
	// object built — no PPP dialer). Per-modem guard so it never loops.
	let modeswitch_tried = {};

	let try_modeswitch = (name, entry, tty) => {
		log('warn', sprintf('modem %s: only a serial port present (ppp), no rich control interface', name));

		if (modeswitch_tried[name]) {
			log('info', sprintf('modem %s: usbnet mode switch already attempted, waiting for re-enumeration', name));
			return;
		}

		modeswitch_tried[name] = true;

		if (!deps.modeswitch) {
			log('warn', sprintf('modem %s: no mode-switch backend, leaving unmanaged', name));
			return;
		}

		if (!tty) {
			log('warn', sprintf('modem %s: no AT port to mode-switch on, leaving unmanaged', name));
			return;
		}

		log('notice', sprintf('modem %s: attempting one-time usbnet mode switch on %s', name, tty));

		deps.modeswitch({
			tty: tty,
			log: (l, m) => log(l, sprintf('modem %s: modeswitch: %s', name, m)),
		}, (err, res) => {
			if (err) {
				log('warn', sprintf('modem %s: usbnet mode switch failed: %J', name, err));
				return;
			}

			if (res?.switched) {
				log('notice', sprintf('modem %s: usbnet mode switch applied (%s), modem re-enumerating', name, res.target ?? '?'));

				// liveness: the reset is fire-and-forget, so a switch that never
				// re-enumerates would leave this modem stuck (once-guarded, no
				// hotplug). Arm a timeout to flag it in status; cancelled when
				// start_modem builds a real modem here.
				if (entry.modeswitch_liveness)
					entry.modeswitch_liveness.cancel();

				entry.modeswitch_liveness = uloop.timer(modeswitch_liveness_ms, () => {
					entry.modeswitch_liveness = null;

					if (!entry.modem) {
						log('err', sprintf('modem %s: usbnet mode switch did not re-enumerate within %ds; modem unmanaged (check hardware / recipe)',
							name, modeswitch_liveness_ms / 1000));
						entry.control_note = 'mode-switch did not re-enumerate';
					}
				});
			}
			else {
				log('notice', sprintf('modem %s: already in a rich usbnet mode, nothing to switch', name));
			}
			// re-enumeration fires hotplug('add') → rebuilt under the new driver.
		});
	};

	// board power/reset lines are only safe when they unambiguously belong to
	// the one managed modem: on a multi-modem box the board GPIOs drive the
	// built-in modem (power_cycle may cut a shared rail), so pulsing them for a
	// USB-stick modem resets the wrong hardware. Per-modem `reset_gpio` is the
	// multi-modem answer.
	let board_gpio_ok = () => length(keys(self.modems)) <= 1;

	// detach a dead modem: drop the modem object, reset device/netdev to their
	// configured values, unbind this modem's contexts (their ctx is bound to the
	// dead modem; queued activations would wait forever). The next rebuild builds
	// fresh modem + context objects.
	detach_modem = (name, entry) => {
		entry.modem.stop();
		entry.modem = null;
		entry.device = entry.cfg.device;   // reset to configured value
		entry.netdev = entry.cfg.netdev;

		for (let cname, centry in self.contexts) {
			if (centry.cfg.modem != name || !centry.ctx)
				continue;

			clear_reconnect(cname);

			for (let p in centry.pending_up)
				p({ error: 'modem_removed' });

			centry.pending_up = [];
			centry.ctx = null;
		}
	};

	// Idempotent-reload teardown of a SINGLE context: cancel its reconnect, fail
	// pending waiters, down it if up, and drop it from the map. (detach_modem
	// above keeps the entry as a "modem gone" placeholder; this removes it fully.)
	let stop_context = (name) => {
		let entry = self.contexts[name];

		if (!entry)
			return;

		clear_reconnect(name);

		for (let p in entry.pending_up)
			p({ error: 'reload' });

		if (entry.ctx && entry.ctx.state != 'IDLE')
			entry.ctx.down(() => null);

		delete self.contexts[name];
	};

	// Idempotent-reload teardown of a SINGLE modem: stop its contexts, cancel a
	// pending mode-switch watchdog, stop the backend, and drop it from the map.
	let stop_modem = (name) => {
		let entry = self.modems[name];

		if (!entry)
			return;

		for (let cname in keys(self.contexts))
			if (self.contexts[cname].cfg.modem == name)
				stop_context(cname);

		if (entry.modeswitch_liveness)
			entry.modeswitch_liveness.cancel();

		if (entry.modem)
			entry.modem.stop();

		delete self.modems[name];
	};

	// stable L3 names (non-mux datapath): rename the kernel netdev to the
	// context's l3_name so multi-modem boxes keep deterministic names regardless
	// of USB enumeration order. Mux children are created under their own name
	// (the raw parent keeps its kernel name). A name conflict is an ERROR (no rename).
	let rename_l3 = (name, entry) => {
		let fx = deps.datapath_fx;

		if (!fx?.link_set || !entry.netdev)
			return;

		// entry.l3_name: assigned in apply_config from the modem's non-mux
		// context (false when a muxed context owns the naming)
		let want = entry.l3_name;

		if (!want || want == entry.netdev)
			return;

		if (fx.exists(sprintf('/sys/class/net/%s', want)))
			return log('err', sprintf('modem %s: cannot rename netdev %s to %s: name already in use — keeping %s',
				name, entry.netdev, want, entry.netdev));

		if (!fx.link_set(entry.netdev, { rename: want }))
			return log('err', sprintf('modem %s: renaming netdev %s to %s failed (device busy?) — keeping %s',
				name, entry.netdev, want, entry.netdev));

		log('notice', sprintf('modem %s: netdev %s renamed to %s (stable L3 device name)',
			name, entry.netdev, want));
		entry.netdev = want;
	};

	let start_modem = (name, cfg, muxinfo, l3name) => {
		// decide how this modem is controlled (qmi/mbim/ncm/ppp). resolve_control
		// classifies EVERY modem, incl. NCM modems with no cdc-wdm.
		let control = deps.resolve_control ? deps.resolve_control(cfg) : null;

		// legacy dep path (resolve_modem_device/resolve_protocol instead of
		// resolve_control): synthesize a control record. ONLY when resolve_control
		// isn't injected — otherwise its null is authoritative ("device not present
		// yet") and we must NOT fall back to raw cfg.device (a netdev name isn't an
		// openable control node); the modem must WAIT for hotplug.
		if (!control && !deps.resolve_control) {
			let device = cfg.device;

			if (!device && deps.resolve_modem_device)
				device = deps.resolve_modem_device(cfg);

			if (device) {
				let proto = cfg.protocol;

				if (proto == null || proto == 'auto')
					proto = (deps.resolve_protocol ? deps.resolve_protocol(device) : null) ?? 'qmi';

				control = { protocol: proto, device: device, netdev: cfg.netdev, tty: cfg.tty };
			}
		}

		let entry = {
			cfg: cfg,
			device: control?.device ?? cfg.device,
			netdev: control?.netdev ?? cfg.netdev,
			muxinfo: muxinfo,
			l3_name: l3name ?? null,   // stable L3 target (false: mux owns naming)
			modem: null,
			protocol: control?.protocol,
			// carry the last-applied reload signature across internal rebuilds
			// (hotplug re-add, waiting-modem retry) — they don't change the config
			_sig: self.modems[name]?._sig,
		};

		self.modems[name] = entry;

		// presence gate: NCM needs a datapath netdev, PPP needs a serial port,
		// QMI/MBIM need a cdc-wdm control device.
		let present = control && (
			control.protocol == 'ncm' ? control.netdev != null :
			control.protocol == 'ppp' ? control.tty != null :
			control.device != null);

		if (!present) {
			log('warn', sprintf('modem %s: control interface not present yet, waiting for hotplug', name));
			// surface the wait to status()/netifd; the periodic tick re-logs it every 30s.
			entry.control_note = 'waiting for modem (control device not present)';
			entry.waiting_since = entry.waiting_since ?? time();
			return;
		}

		// PPP-only: mode-switch and wait for re-enumeration; do not build a modem.
		if (control.protocol == 'ppp')
			return try_modeswitch(name, entry, control.tty);

		// a rich control interface means any prior mode switch re-enumerated —
		// cancel its liveness watchdog and clear the note.
		if (entry.modeswitch_liveness) {
			entry.modeswitch_liveness.cancel();
			entry.modeswitch_liveness = null;
		}
		entry.control_note = null;

		let device = entry.device;
		let proto = control.protocol ?? 'qmi';

		entry.protocol = proto;

		// pin the discovery-resolved tty so AT-driven backends (NCM) and the AT
		// side channel use it (from the netdev's USB parent for NCM).
		if (control.tty && !cfg.tty)
			cfg.tty = control.tty;

		if (!entry.netdev && deps.resolve_netdev)
			entry.netdev = deps.resolve_netdev(cfg, device);

		rename_l3(name, entry);

		let ep_id = cfg.ep_id;

		if (ep_id == null && deps.resolve_ep_id)
			ep_id = deps.resolve_ep_id(cfg, device, entry.netdev);

		let ep_type = cfg.ep_type;

		if (ep_type == null && deps.resolve_ep_type)
			ep_type = deps.resolve_ep_type(cfg, device, entry.netdev);

		let common = {
			id: name,
			device: device,
			config: cfg,
			timing: self.timing,
			recovery: {
				fx: deps.recovery_fx,
				state_dir: opts?.state_dir,
				reboot_delay: opts?.reboot_delay,
				// hardware repower rung: a modem `reset_gpio` (or single-modem board
				// default) pulses RESET without cutting power; else power-cycle the USB
				// power GPIO. Board fallbacks gated by board_gpio_ok (multi-modem would
				// hit the wrong hardware). No-op when nothing safe is available.
				repower: deps.board ? (() => {
					let rg = cfg.reset_gpio ?? (board_gpio_ok() ? deps.board.profile?.reset_gpio : null);
					let off = cfg.repower_time ? +cfg.repower_time * 1000 : null;
					if (rg)
						return deps.board.reset_pulse(rg, off);
					return board_gpio_ok() ? deps.board.power_cycle(off) : false;
				}) : null,
			},
			at: {
				fx: deps.datapath_fx,
				open_transport: deps.at_open_transport,
			},
			deps: {
				transport_open: deps.transport_open,
				log: (level, msg) => log(level, sprintf('modem %s: %s', name, msg)),
				on_event: on_modem_event,
				set_clock: deps.set_clock,
			},
		};

		// backend ships as its own package; when the one this modem needs isn't
		// installed, report it in status and leave the modem unmanaged (no crash).
		let chosen = backend_for(proto);

		if (!chosen.be) {
			log('err', sprintf('modem %s: %s control requires the %s package, which is not installed',
				name, proto, chosen.pkg));
			entry.control_note = sprintf('%s package not installed', chosen.pkg);
			return;
		}

		let be = chosen.be;

		let datapath =
			(proto == 'mbim') ? { netdev: entry.netdev, mux_links: muxinfo?.list ?? [], fx: deps.datapath_fx } :
			(proto == 'ncm')  ? { netdev: entry.netdev, fx: deps.datapath_fx } :
			                    { netdev: entry.netdev, ep_id: ep_id, ep_type: ep_type, mux: cfg.mux,
			                      dgram_size: cfg.dl_datagram_max_size,
			                      mux_links: muxinfo?.list ?? [], fx: deps.datapath_fx };

		entry.modem = be.modem.create({ ...common, datapath: datapath });
		entry.modem.start();
	};

	let start_context = (name, cfg) => {
		let mentry = self.modems[cfg.modem];

		// interface-bound contexts default wanted=true so the daemon (re)establishes
		// them on modem-ready without waiting for netifd — adopts a session that
		// survived a wwand restart.
		let base = { cfg: cfg, ctx: null, pending_up: [], wanted: (cfg.interface != null),
		             retry_timer: null, hold_timer: null, retry_n: 0,
		             // preserve the last-applied reload signature across internal
		             // re-binds (hotplug) — the config itself is unchanged there
		             _sig: self.contexts[name]?._sig };

		if (!mentry?.modem) {
			log('warn', sprintf('interface %s: modem %s not started', name, cfg.modem));
			self.contexts[name] = base;
			return;
		}

		let entry = base;
		// modem exists (guarded), so its backend package is installed; reach the
		// matching context factory via the same lazy loader.
		let factory = backend_for(mentry.protocol).be.context;

		entry.ctx = factory.create({
			name: name,
			modem: mentry.modem,
			config: cfg,
			timing: opts?.ctx_timing,
			deps: {
				log: (level, msg) => log(level, sprintf('interface %s: %s', name, msg)),
				on_event: (ctx, event, data) => on_context_event(name, ctx, event, data),
			},
		});

		self.contexts[name] = entry;
	};

	// --- public API --------------------------------------------------------

	let config_sig = null;

	self.apply_config = function(parsed) {
		// l3-device learn-back switch; read before the no-op short-circuit so a
		// globals-only edit still updates it
		self.write_device = parsed.globals?.write_device ?? true;

		// zero-config autosetup gate (default on; wwand_globals option autosetup)
		self.autosetup = parsed.globals?.autosetup ?? true;

		// unchanged whole config is a no-op: the reload trigger also fires for
		// unrelated network edits, so skip the diff entirely when nothing changed.
		let sig = sprintf('%J', { m: parsed.modems, c: parsed.contexts });

		if (sig == config_sig)
			return;

		config_sig = sig;

		// aggregate mux requirements + stable L3 name per modem (drives start_modem
		// AND the per-modem signature: a modem's mux set depends on its contexts)
		let mux_by_modem = {};
		let l3_by_modem = {};

		for (let name, cfg in parsed.contexts) {
			if (cfg.mux_id > 0) {
				let mi = mux_by_modem[cfg.modem] = mux_by_modem[cfg.modem] ?? { list: [] };

				push(mi.list, { id: cfg.mux_id, name: cfg.mux_link, mtu: cfg.mtu });

				// mux children are claimed under their own names — the raw
				// parent keeps its kernel name (false = never rename)
				l3_by_modem[cfg.modem] = false;
			}
			else if (cfg.modem && l3_by_modem[cfg.modem] == null) {
				l3_by_modem[cfg.modem] = cfg.l3_name;
			}
		}

		// Idempotent reload: bounce only what actually changed. A modem's signature
		// folds in its mux set + stable L3 name (both derived from its contexts), so
		// adding/removing a mux channel counts as a modem change; a context's own
		// signature is just its cfg. Unchanged modems and unchanged contexts keep
		// running untouched — the whole point (no WAN bounce on an unrelated edit,
		// and a single modem's edit never disturbs the others or their siblings).
		let modem_sig = (mn) => sprintf('%J',
			{ cfg: parsed.modems[mn], mux: mux_by_modem[mn], l3: l3_by_modem[mn] });
		let ctx_sig = (cn) => sprintf('%J', parsed.contexts[cn]);

		// 1) stop modems that are gone or changed (cascades to their contexts). A
		//    changed modem must rebuild its datapath, so its contexts bounce with it.
		for (let mn in keys(self.modems))
			if (!parsed.modems[mn] || self.modems[mn]._sig != modem_sig(mn))
				stop_modem(mn);

		// 2) stop contexts that are gone or changed on a still-running modem (their
		//    modem stays up; only this one context re-applies — APN/auth/mtu/etc.).
		//    Contexts of the modems stopped above are already gone.
		for (let cn in keys(self.contexts))
			if (!parsed.contexts[cn] || self.contexts[cn]._sig != ctx_sig(cn))
				stop_context(cn);

		// 3) (re)start whatever is now missing — new sections and the ones just
		//    stopped. Untouched modems/contexts are already present and skipped.
		for (let name, cfg in parsed.modems)
			if (!self.modems[name])
				start_modem(name, cfg, mux_by_modem[name], l3_by_modem[name]);

		for (let name, cfg in parsed.contexts)
			if (!self.contexts[name])
				start_context(name, cfg);

		// 4) stamp the applied signatures for the next reload's diff (idempotent for
		//    the ones that kept running: same config -> same signature).
		for (let mn in keys(self.modems))
			self.modems[mn]._sig = modem_sig(mn);

		for (let cn in keys(self.contexts))
			self.contexts[cn]._sig = ctx_sig(cn);

		// board bring-up + periodic status tick (once): drives panel LEDs from the
		// primary modem's reg+signal and re-logs a waited-on modem every 30 s.
		if (!self._tick_started) {
			self._tick_started = true;
			deps.board?.init();

			let led_state = (entry) => {
				let m = entry?.modem, reg = m?.reg;
				let radio_ifs = reg?.radio_ifs;
				let on_rat = (type(radio_ifs) == 'array' && length(radio_ifs) > 0);
				return {
					present: !!m && m.state != 'ABSENT',
					// "registered" across backends: on a RAT, or reg value in any form
					registered: on_rat || reg?.registration == 'registered' ||
					            reg?.registration == 1,
					radio: on_rat ? radio_ifs[0] : null,
					roaming: reg?.roaming ?? false,
					bars: deps.board ? deps.board.bars(m?.signal) : 0,
				};
			};

			let tick;
			tick = () => {
				let now = time();

				// waiting modems: periodically re-check presence and rebuild via
				// start_modem — recovers modems whose hotplug 'add' never fired.
				// While still absent, start_modem re-logs the wait.
				for (let name, entry in self.modems)
					if (!entry.modem && entry.control_note &&
					    (now - (entry._waiting_logged ?? 0)) >= (self.timing?.waiting_retry ?? 30)) {
						start_modem(name, entry.cfg, entry.muxinfo, entry.l3_name);

						if (self.modems[name])
							self.modems[name]._waiting_logged = now;

						// rebind contexts that lost their modem (mirrors hotplug add)
						if (self.modems[name]?.modem)
							for (let cname, centry in self.contexts)
								if (!centry.ctx)
									start_context(cname, centry.cfg);
					}

				if (deps.board) {
					let first = null;
					for (let n, e in self.modems) { first = e; break; }
					deps.board.leds(led_state(first));
				}

				self._tick_timer = uloop.timer(10000, tick);
			};

			tick();
		}
	};

	self.resolve_context = function(ref) {
		if (self.contexts[ref])
			return ref;

		for (let name, entry in self.contexts)
			if (entry.cfg.interface == ref)
				return name;

		return null;
	};

	// connection params re-read from disk on every up (structural changes still go
	// through the reload trigger). entry.cfg is the object the context reads live,
	// so updating it in place makes the next activation use the fresh values.
	const CTX_LIVE_FIELDS = [ 'apn', 'pdp_type', 'auth', 'username', 'password',
	                          'profile', 'mtu', 'use_pushed_mtu' ];

	let refresh_context_cfg = (name, entry) => {
		if (!deps.read_config)
			return;

		let parsed = deps.read_config();
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

	self.context_up = function(ref, cb) {
		let name = self.resolve_context(ref);
		let entry = name ? self.contexts[name] : null;

		if (!entry)
			return cb({ error: 'no_such_context', ref: ref });

		// context configured but its modem isn't present yet (control device not
		// enumerated) — report distinctly so netifd/LuCI show "waiting for modem".
		if (!entry.ctx)
			return cb({ error: 'modem_absent', ref: ref, modem: entry.cfg?.modem });

		// re-read connection params from disk on every up (like netifd)
		refresh_context_cfg(name, entry);

		// netifd asked us up → mark wanted so the daemon keeps it up until context_down.
		entry.wanted = true;
		activate(name, cb);
	};

	// apply the effective MTU on the l3 link (use_pushed_mtu semantics, native rtnl)
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

		log('info', sprintf('interface %s: applying MTU %d on %s', name, mtu, netdev));

		if (!fx.link_set(netdev, { mtu: mtu }))
			log('warn', sprintf('interface %s: setting MTU %d on %s failed%s', name, mtu, netdev,
				fx.last_error ? sprintf(': %s', fx.last_error) : ''));

		let v6mtu = sprintf('/proc/sys/net/ipv6/conf/%s/mtu', netdev);

		if (fx.exists(v6mtu) && !fx.write(v6mtu, sprintf('%d', mtu)))
			log('warn', sprintf('interface %s: setting IPv6 MTU on %s failed', name, netdev));
	};

	// enable IPv6 on the l3 link before netifd configures it (disable_ipv6=0)
	let enable_ipv6 = (name, entry, netdev) => {
		let fx = deps.datapath_fx;

		if (!fx || !netdev || !entry.ctx.settings?.ipv6)
			return;

		let path = sprintf('/proc/sys/net/ipv6/conf/%s/disable_ipv6', netdev);

		if (fx.exists(path) && trim(fx.read(path) ?? '') != '0' && !fx.write(path, '0'))
			log('warn', sprintf('interface %s: enabling IPv6 on %s failed', name, netdev));
	};

	// l3 netdev for a context: parent netdev, MBIM VLAN sub-device or QMAP mux
	// child per protocol/mux. Forward-declared (line ~143) so on_modem_event's
	// learn_device path can reference it without the ucode TDZ trap.
	derive_netdev = (entry) => {
		let mentry = self.modems[entry.cfg.modem];
		let netdev = mentry?.netdev;

		if (mentry?.protocol == 'mbim') {
			// MBIM: session 0 is the parent netdev, sessions > 0 are VLAN sub-devices
			// named after the context's mux_link so netifd's device binding matches
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

	// read-only settings for the netifd renew path: like _up_result but no MTU/IPv6
	// side effects, no modem touch. { up: false } unless connected.
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

		// our own stuck-pending reset (registered handler): self-inflicted teardown,
		// not operator intent — keep `wanted` and restart the aborted activation once
		// the teardown settles (its up() callback never fires, so nothing else does).
		if (entry._reset_pending) {
			entry._reset_pending = false;

			return entry.ctx.down(() => {
				cb(null, {});
				retry_activate(name);
			});
		}

		// netifd tore the interface down (admin/config) → no longer wanted; stop reconnect.
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
				protocol: entry.protocol,
				state: entry.modem?.state ?? 'UNRESOLVED',
				control_note: entry.control_note,
				apdu_backend: entry.modem?._apdu_be,   // mbim | qmi | at (once probed)
				pin1: entry.modem?.pin1,
				sim_block: entry.modem?.sim_block,  // { reason, retries } when SIM_BLOCKED
				model: entry.modem?.info?.model,
				revision: entry.modem?.info?.revision,
				imei: entry.modem?.info?.imei,
				imsi: entry.modem?.info?.imsi,
				iccid: entry.modem?.info?.iccid,
				msisdn: entry.modem?.info?.msisdn,
				usb: entry.modem?.info?.usb,
				identity_mismatch: entry.modem?.identity_mismatch,   // {expected,found} if the pinned IMEI didn't match
				at_tty: entry.modem?.at_tty,
				// at2 released for external tools
				at2_released: entry.modem?.at2_released,
				// cell/freq lock read-back (Quectel QNWLOCK / MeiG ^CELLLOCK), null if none
				locks: entry.modem?.locks,
				registration: entry.modem?.reg,
				registration_detail: entry.modem?.reg_detail,
				config_warnings: entry.modem?.config_warnings,
				proto_errors: entry.modem?.counters?.proto_errors,
				qmi_errors: entry.modem?.counters?.proto_errors,   // deprecated alias

				attempts: entry.modem?.counters?.attempts,
			};
		}

		let contexts = {};

		for (let name, entry in self.contexts) {
			contexts[name] = {
				interface: entry.cfg.interface,
				modem: entry.cfg.modem,
				mux_id: entry.cfg.mux_id,
				l3_device: derive_netdev(entry),
				state: entry.ctx?.state ?? 'UNBOUND',
				last_error: entry.ctx?.last_error,
			};
		}

		// board profile info for LuCI: detected id, whether wwand can power-cycle the
		// modem, and the board's default modem reset GPIO.
		let board = deps.board ? {
			id: deps.board.id,
			has_power: deps.board.has_power,
			reset_gpio: deps.board.profile?.reset_gpio,
		} : null;

		return { modems: modems, contexts: contexts,
		         board: board,
		         globals: { hold_max_ms: hold_max_ms } };
	};

	// resolve a modem ref for a cb-style ubus method: returns the entry, or reports
	// via cb and returns null. A modem being waited on (detached, not yet
	// re-enumerated) reports modem_waiting, not a misleading no_such_modem.
	let check_modem = (ref, cb) => {
		let entry = self.modems[ref];

		if (entry?.modem)
			return entry;

		if (entry)
			cb({ error: 'modem_waiting', ref: ref, note: entry.control_note });
		else
			cb({ error: 'no_such_modem', ref: ref });

		return null;
	};

	// registered PLMN in a protocol-neutral shape { mcc?, mnc?, name? }, or null.
	let reg_plmn = (m) => {
		let p = m?.reg?.plmn;

		if (!p)
			return null;

		return { mcc: p.mcc ?? null, mnc: p.mnc ?? null, name: p.description ?? null };
	};

	// settings / network-selection / operator-scan ubus ops — extracted to netsel_ops.uc
	netsel_ops.install(self, { log: log, check_modem: check_modem, reg_plmn: reg_plmn });

	// generic modem reset: dedicated reset GPIO first (per-modem `reset_gpio` or the
	// board default), then backend soft reset (QMI DMS offline->reset, MBIM
	// passthrough-DMS/AT, NCM AT+CFUN=1,1).
	self.modem_reset = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let rg = entry.cfg?.reset_gpio ??
			(board_gpio_ok() ? deps.board?.profile?.reset_gpio : null);

		if (rg && deps.board) {
			let off = entry.cfg?.repower_time ? +entry.cfg.repower_time * 1000 : null;

			log('warn', sprintf('modem %s: admin-requested modem reset (GPIO %s pulse)', ref, rg));

			if (deps.board.reset_pulse(rg, off))
				return cb(null, { ok: true, resetting: true, action: 'gpio', gpio: rg });

			// GPIO configured but unusable -> fall through to the backend reset
			log('warn', sprintf('modem %s: reset GPIO %s unavailable, trying backend reset', ref, rg));
		}

		if (type(entry.modem.reset) != 'function')
			return cb({ error: 'unsupported_on_backend' });

		log('warn', sprintf('modem %s: admin-requested modem reset (backend)', ref));
		entry.modem.reset((err, res) =>
			cb(err, err ? null : { ...res, action: 'backend' }));
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

	// enumerate modems for the LuCI stable-binding picker: managed modems (live
	// IMEI/model) + every control device present in sysfs (iSerial read pre-open).
	// No modem is opened here.
	self.modem_probe = function(cb) {
		let present = deps.list_present ? deps.list_present() : [];
		let managed = [];

		for (let name, entry in self.modems)
			push(managed, {
				id: name,
				configured_serial: entry.cfg?.serial,
				configured_imei: entry.cfg?.imei,
				imei: entry.modem?.info?.imei,
				model: entry.modem?.info?.model,
				device: entry.device,
				netdev: entry.netdev,
				registered: entry.modem?.reg?.registration == 'registered',
				identity_mismatch: entry.modem?.identity_mismatch,
			});

		// enrich each present device with the IMEI/model of the managed modem on
		// the same control node, so the picker can offer both anchors
		for (let p in present)
			for (let m in managed)
				if ((p.device && p.device == m.device) || (p.netdev && p.netdev == m.netdev)) {
					p.imei = m.imei;
					p.model = m.model;
					p.managed_by = m.id;
					break;
				}

		cb(null, { managed: managed, present: present });
	};

	self.modem_sim_switch_slot = function(ref, physical, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (!(physical > 0))
			return cb({ error: 'invalid_slot' });

		sim.switch_slot(entry.modem, physical, (err, res) => {
			if (err)
				return cb({ error: 'qmi', detail: err });

			// idempotency guard: slot already active — nothing switched, keep caches
			if (res?.unchanged) {
				log('info', sprintf('modem %s: SIM slot %d already active — not switching', ref, physical));
				return cb(null, { slot: physical, unchanged: true });
			}

			// a different slot may hold a different eUICC — drop the cached
			// eSIM/APDU backends so they are re-probed
			delete entry.modem._esim_be;
			delete entry.modem._apdu_be;

			log('notice', sprintf('modem %s: switched to SIM slot %d', ref, physical));
			cb(null, { slot: physical });
		});
	};

	self.modem_sim_pin_lock = function(ref, pin, enable, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (!length(pin ?? ''))
			return cb({ error: 'missing_pin' });

		sim.set_pin_lock(entry.modem, enable, pin, (err, res) => {
			if (!err)
				log('notice', sprintf('modem %s: SIM PIN query %s', ref, enable ? 'enabled' : 'disabled'));
			cb(err, res);
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

	// SMS list/read/delete. `storage` 'SM' (SIM) or 'ME' (modem). Backend-neutral
	// (sms.uc dispatches QMI-WMS / MBIM / AT); unsupported_on_backend when none.
	self.modem_sms_list = function(ref, storage, cb) {
		let entry = check_modem(ref, cb);
		if (entry)
			sms.sms_list(entry.modem, storage ?? 'SM', cb);
	};

	self.modem_sms_read = function(ref, storage, index, cb) {
		let entry = check_modem(ref, cb);
		if (entry)
			sms.sms_read(entry.modem, storage ?? 'SM', +index, cb);
	};

	self.modem_sms_delete = function(ref, storage, index, cb) {
		let entry = check_modem(ref, cb);
		if (entry)
			sms.sms_delete(entry.modem, storage ?? 'SM', +index, cb);
	};

	// eSIM download/notification bridge (optional wwand-esim, esim_bridge.uc); lazy.
	let esim_bridge = null;
	let load_esim_bridge = () => {
		if (esim_bridge === false)
			return null;

		if (!esim_bridge) {
			let esim = load_esim();
			let mod = null;

			if (esim) {
				try { mod = require('wwand.esim_bridge'); }
				catch (e) { mod = null; }
			}

			if (!mod) {
				esim_bridge = false;
				return null;
			}

			esim_bridge = mod.create({
				esim: esim,
				log: log,
				modem_of: (ref) => self.modems[ref],
			});
		}

		return esim_bridge;
	};

	self.modem_esim = function(ref, op, params, cb) {
		let br = load_esim_bridge();

		if (!br)
			return cb({ error: 'esim_not_installed' });

		return br.modem_esim(ref, op, params, cb);
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

	// manual hardware repower (ubus modem_repower): reset-GPIO pulse when one
	// applies, else board power-cycle — both gated for multi-modem boxes.
	self.repower_modem = function(ref) {
		if (!deps.board)
			return { error: 'no_board_profile' };

		let cfg = (ref && self.modems[ref]) ? self.modems[ref].cfg : null;

		if (!cfg)
			for (let n, e in self.modems) { cfg = e.cfg; break; }

		// board defaults only when they unambiguously target this modem (see
		// board_gpio_ok): per-modem reset_gpio is the multi-modem path.
		let rg = cfg?.reset_gpio ?? (board_gpio_ok() ? deps.board.profile?.reset_gpio : null);
		let off = cfg?.repower_time ? +cfg.repower_time * 1000 : null;

		if (rg)
			return deps.board.reset_pulse(rg, off) ?
				{ ok: true, action: 'reset', gpio: rg } : { error: 'reset_gpio_unavailable' };

		if (!board_gpio_ok())
			return { error: 'multi_modem_needs_reset_gpio' };

		return deps.board.power_cycle(off) ?
			{ ok: true, action: 'power_cycle' } : { error: 'no_power_control' };
	};

	// manual PIN release: enter the PIN past the low-retry safety block (with <=1
	// attempt left the daemon refuses to auto-enter, to avoid burning the last try
	// into a PUK lock). Optional `pin` overrides the configured one. The one-shot
	// pin_force/_pin_override flags clear on the next registered/sim_blocked event.
	self.sim_pin_verify = function(ref, pin, cb) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return cb({ error: 'no_such_modem', ref: ref });

		entry.modem.pin_force = true;

		if (pin != null && pin != '')
			entry.modem._pin_override = pin;

		log('warn', sprintf('modem %s: manual PIN release requested (entering PIN past the low-retry guard)', ref));

		entry.modem.stop();
		entry.modem.start();

		cb(null, { ok: true });
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
			registration_detail: entry.modem.reg_detail,
			signal: entry.modem.signal,
			cells: entry.modem.cells,
			dsd: entry.modem.dsd_status,
			temperature: entry.modem.temperature,
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
			// autosetup phase 1: a modem appears while NOTHING wwand-related is
			// configured -> create wwmodem_auto + interface wwan0 (wan zone) and
			// reload. Gated by autosetup; autosetup_create re-checks live uci.
			if ((self.autosetup ?? true) && !length(keys(self.modems)) &&
			    deps.autosetup_create && deps.autosetup_create(devname)) {
				log('notice', sprintf('autosetup: modem %s appeared without any configuration — created wwmodem_auto + interface wwan0 (wan zone)', devname));

				if (self.reload)
					self.reload();
			}

			// start modems that couldn't be resolved before (boot enumeration race)
			for (let name, entry in self.modems) {
				if (entry.modem)
					continue;

				start_modem(name, entry.cfg, entry.muxinfo, entry.l3_name);
			}

			// bind contexts that had no running modem at config time
			for (let name, entry in self.contexts)
				if (!entry.ctx)
					start_context(name, entry.cfg);

			// a modem with datapath but no AT port yet (NCM: serial ports can appear
			// long after the netdev) sits in ABSENT backoff — a tty arrival is the cue
			// to retry now. start() is state-guarded, so this no-ops elsewhere.
			for (let name, entry in self.modems) {
				if (entry.modem && !entry.modem.at && entry.modem.state == 'ABSENT')
					entry.modem.start();
			}
		}
		else if (action == 'remove') {
			for (let name, entry in self.modems) {
				// match by cdc-wdm control device OR by datapath netdev (NCM has no
				// control device). Basename-EXACT, not substring: substring would make
				// removing `cdc-wdm1` also match `/dev/cdc-wdm10` and stop the wrong one.
				let parts = entry.device ? split(entry.device, '/') : null;
				let base = parts ? parts[length(parts) - 1] : null;
				let hit = (base && base == devname) ||
				          (entry.netdev && entry.netdev == devname);

				if (hit && entry.modem)
					detach_modem(name, entry);
			}
		}
	};

	// autosetup boot sweep: on a slow cold boot the modem enumerates BEFORE the
	// daemon is on the bus, so the hotplug 'add' that would trigger phase 1 is lost
	// and never re-fires. Replay the first present candidate through hotplug once at
	// startup. autosetup_create re-checks live uci, so this never touches a configured box.
	self.autosetup_scan = function() {
		if (!(self.autosetup ?? true) || length(keys(self.modems)) ||
		    !deps.autosetup_create || !deps.list_present)
			return;

		for (let p in deps.list_present()) {
			// hotplug devnames are basenames: 'cdc-wdm0' (usbmisc) / 'usb0' (net)
			let dev = (p.kind == 'cdc-wdm')
				? replace(p.device ?? '', /^.*\//, '') : p.netdev;

			if (dev != null && dev != '') {
				self.hotplug('add', dev);
				return;
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

		for (let name, entry in self.modems) {
			if (entry.modeswitch_liveness)
				entry.modeswitch_liveness.cancel();

			if (entry.modem)
				entry.modem.stop();
		}

		self.modems = {};
		self.contexts = {};
	};

	// Non-destructive stop for a plain exit/restart: do NOT down contexts or
	// interfaces. With no-proto-task the WAN stays up across the restart and the
	// fresh daemon adopts the live session on modem-ready. Just cancel our timers.
	self.stop_local = function() {
		for (let name in keys(self.contexts))
			clear_reconnect(name);
	};

	return self;
};
