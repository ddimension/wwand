// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — daemon core: owns modems and contexts, applies configuration,
// dispatches ubus ops. Transport/sysfs/ubus access is injected (opts.deps) so
// the core runs host-side against mocks.

'use strict';

import * as uloop from 'uloop';
import * as apndb from 'wwand.apndb';
import * as netsel_ops from 'wwand.netsel_ops';
import * as simops from 'wwand.simops';
import * as hwops from 'wwand.hwops';
import * as nlmod from 'wwand.netlink';
import * as reconnect from 'wwand.reconnect';
import * as ctx_settings from 'wwand.ctx_settings';

// backends load lazily; a missing package returns null (cached failure) so
// start_modem reports it clearly instead of crashing. Lazy also so a QMI-only
// install never loads MBIM's ~1.4k lines/schema. require() cannot load ES
// modules directly (`export` is a syntax error in plain scripts) — the *_lazy
// names are exportless wrapper scripts.
let lazy_backend = (mod) => {
	let m = null, failed = false;

	return () => {
		if (failed)
			return null;

		if (m == null) {
			try {
				m = require(mod);
			}
			catch (e) {
				failed = true;
				m = null;
			}
		}

		return m;
	};
};

// datapath plugins: a modem whose `option mux` names something other than a
// built-in (auto/raw_ip/rmnet/qmimux/vlan) pulls in `wwand.datapath_<name>`,
// which RETURNS its implementation for the daemon to thread down to netlink
// (never a registry — see the comment there). Same shape as the control
// backends above: cached, and a missing package is a control_note rather than
// a crash. The name is restricted before it reaches
// require() — it comes from uci and ends up as a module path.
let dp_plugins = {};

let load_datapath = (name) => {
	if (!match(name ?? '', /^[a-z][a-z0-9_]*$/))
		return null;

	if (!exists(dp_plugins, name)) {
		try {
			// the plain script RETURNS its implementation — it cannot register
			// itself anywhere, see the plugin comment in netlink.uc
			dp_plugins[name] = require('wwand.datapath_' + name);
		}
		catch (e) {
			dp_plugins[name] = null;
		}
	}

	return dp_plugins[name];
};

let load_qmi = lazy_backend('wwand.qmi_lazy');
let load_mbim = lazy_backend('wwand.mbim_lazy');
// NCM support (cdc_ncm / cdc_ether, AT-controlled) is a separate package (wwand-ncm)
let load_ncm = lazy_backend('wwand.ncm_lazy');
// optional eSIM module (wwand-esim); absent => feature reports esim_not_installed
let load_esim = lazy_backend('wwand.esim');

// "registered" across backends: QMI stores the numeric NAS value, MBIM/NCM
// store 1/0 — never compare against a string. Radio list is the strongest
// signal (a modem camped on a RAT is registered whatever the field says).
function is_registered(reg)
{
	let radio_ifs = reg?.radio_ifs;

	if (type(radio_ifs) == 'array' && length(radio_ifs) > 0)
		return true;

	return reg?.registration == 1 || reg?.registration == 'registered';
}

export function create(opts)
{
	let deps = opts?.deps ?? {};
	let log = deps.log ?? ((level, msg) => warn(sprintf('%s: %s\n', level, msg)));

	// backend module loaders (overridable for tests)
	let load_qmi_fn = deps.load_qmi ?? load_qmi;
	let load_mbim_fn = deps.load_mbim ?? load_mbim;
	let load_ncm_fn = deps.load_ncm ?? load_ncm;
	let load_datapath_fn = deps.load_datapath ?? load_datapath;

	// Installed datapath plugins, by name. Scanned ONCE: the module directory
	// is globbed for datapath_*.uc and each is require()d — which is what lets
	// a plugin be chosen under `option mux 'auto'` at all. Without a scan the
	// daemon could only load what a config already named, so an accelerated
	// datapath (rmnet_nss on ipq807x) could never introduce itself on a
	// zero-config box, which is precisely where it has to. Whether one is USED
	// is still its own probe()'s answer; this only finds them.
	let installed_dp = null;

	let list_datapaths = () => {
		if (installed_dp != null)
			return installed_dp;

		installed_dp = {};

		let dir = deps.ucode_dir ?? '/usr/share/ucode/wwand';
		let fx = deps.datapath_fx;
		let found = (type(fx?.glob) == 'function') ? (fx.glob(dir + '/datapath_*.uc') ?? []) : [];

		// name order: the tie-break when two plugins claim the same device is
		// decided in select_backend, and it must not depend on glob order
		let names = [];

		for (let path in found) {
			let m = match(path, /datapath_([a-z][a-z0-9_]*)\.uc$/);

			if (m)
				push(names, m[1]);
		}

		sort(names);

		for (let n in names) {
			let impl = load_datapath_fn(n);

			if (nlmod.valid_plugin(impl))
				installed_dp[n] = impl;
			else
				log('warn', sprintf('datapath plugin %s: not usable (no links()), ignored', n));
		}

		if (length(installed_dp))
			log('info', sprintf('datapath plugins installed: %s', join(', ', keys(installed_dp))));

		return installed_dp;
	};

	// the catalog a UI needs for `option mux`: what netlink implements plus the
	// add-ons found on this box. A plugin describes itself through the same
	// optional fields the datapath contract already has (`proto`, `description`).
	let datapath_catalog = () => {
		let out = nlmod.datapath_catalog();

		for (let n, impl in list_datapaths())
			push(out, {
				name: n,
				kind: 'plugin',
				// same defaulting as the selection uses, from the one place that
				// defines it — a UI that offered a datapath the daemon then
				// refuses would be worse than no list at all
				proto: nlmod.datapath_protos(impl),
				description: impl.description ?? sprintf('add-on datapath %s', n),
			});

		return out;
	};

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

	// reconnect engine (activate/pending-up queue, capped-backoff retry, the
	// transient-loss hold timer) — extracted to reconnect.uc; bound as locals
	// so the call sites below read unchanged. Also installs set_hold_max_ms.
	reconnect.install(self, {
		log: log,
		timing: opts?.timing,
		down_interface: deps.down_interface,
	});

	let activate = self._activate;
	let clear_reconnect = self._clear_reconnect;
	let retry_activate = self._retry_activate;
	let enter_reconnecting = self._enter_reconnecting;

	// forward-declared: ucode closures capture only already-declared vars, and
	// these self-reference (the TDZ trap — see CLAUDE.md ucode gotchas)
	let derive_netdev;
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

		// self-heal a fragile `device '/dev/cdc-wdmX'` node binding into a stable
		// USB `path` now that this modem has registered on that node (so the path
		// recorded is always the working modem's — see learn_modem_path). Prevents
		// the two-modem reboot-shuffle where the section wakes up on the wrong node.
		if ((self.write_device ?? true) && deps.learn_modem_path && modem.device)
			deps.learn_modem_path(modem.id, modem.device);

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
			    !entry.ctx || entry.ctx.state != 'IDLE')
				continue;

			// re-establish wanted contexts; ALSO re-arm one we involuntarily gave
			// up on after a reconnect-hold blackhole (reconnect_on_register, set by
			// context_down) now that the modem is registered again. An operator
			// ifdown leaves wanted=false WITHOUT that marker, so it stays down.
			if (!entry.wanted) {
				if (!entry.reconnect_on_register)
					continue;
				entry.reconnect_on_register = false;
				entry.wanted = true;
				log('notice', sprintf('interface %s: service returned, reconnecting after earlier give-up',
					entry.cfg.interface));
			}

			// capture per iteration: the netifd status probe is async, so the
			// adopt-vs-kick decision runs later in the callback.
			let cname = name, centry = entry;

			let decide = (st) => {
				if (st?.up) {
					log('info', sprintf('adopting live interface %s after modem ready', centry.cfg.interface));
					retry_activate(cname);
				}
				else if (st?.autostart === false && !centry._our_down) {
					// The operator ran `ifdown`. netifd's RUNTIME autostart flag is
					// the only durable record of that: `wanted` lives in this
					// process's memory, and every interface-bound context is rebuilt
					// with wanted=true on start/reload — which is how a wwand restart
					// used to resurrect an interface somebody had deliberately taken
					// down (reproduced on the Cudy LT300, 2026-08-23: ifdown, then
					// restart, and the link came back by itself).
					//
					// It is NOT enough on its own, though, and the `_our_down` guard
					// above is why. netifd's ubus `down` runs interface_set_down(),
					// which does `iface->autostart = false` — so OUR OWN downs leave
					// exactly the same trace as an operator's. A modem that went
					// SIM_BLOCKED (wrong PIN, say) and then came back therefore found
					// its interface marked "administratively down" by the very down
					// wwand had issued, and sat there until someone ran ifup by hand.
					// Field-reported on an EG060K-EA: PIN entered, modem registered,
					// context never activated. The earlier claim here that autostart
					// "is cleared by ifdown and NOTHING else" was simply wrong.
					//
					// Device presence still lives in `available`, not here: measured
					// during a modem repower, a vanished device reads up=false,
					// available=false, autostart=TRUE, so this cannot swallow the
					// reconnect after a modem reset.
					if (centry.wanted) {
						centry.wanted = false;
						log('notice', sprintf('interface %s is administratively down (ifdown), leaving it alone',
							centry.cfg.interface));
					}
				}
				else if ((centry.cfg.auto ?? true) && deps.kick_interface) {
					// our own down is being undone here; the kick re-arms
					// netifd's autostart, so the marker has served its purpose
					if (centry._our_down) {
						log('info', sprintf('interface %s was taken down by wwand, bringing it back up',
							centry.cfg.interface));
						centry._our_down = false;
					}

					// IDLE context while netifd holds the interface 'pending' = an
					// ORPHANED setup (e.g. a wwand restart mid-setup). 'up' no-ops on a
					// pending interface, so 'down' first, then the kick re-runs setup.
					if (st?.pending && deps.down_interface) {
						log('info', sprintf('interface %s stuck pending, resetting before setup', centry.cfg.interface));
						// mark the down as our own so context_down doesn't read it as
						// operator intent (clearing `wanted`) or kill the activation below
						centry._reset_pending = true;
						deps.down_interface(centry.cfg.interface);
					}

					// cdc_mbim/cdc_ncm: the data link's carrier follows the session,
					// and netifd won't run proto setup until the link is up — so connect
					// first, then kick (the 'up' event kicks once connected via
					// _kick_after_connect). QMI's mux link is stable, so kick it directly.
					let cf_proto = self.modems[modem.id]?.protocol;

					if (cf_proto == 'mbim' || cf_proto == 'ncm') {
						log('info', sprintf('connecting %s first (%s), then netifd', centry.cfg.interface, cf_proto));
						centry._kick_after_connect = true;
						retry_activate(cname);
					}
					else {
						log('info', sprintf('kicking interface %s after modem ready', centry.cfg.interface));
						deps.kick_interface(centry.cfg.interface);
					}
				}
				else {
					// 'auto 0' and not up: leave it dormant until an explicit ifup
					log('debug', sprintf('interface %s is down and auto=0, not kicking', centry.cfg.interface));
				}
			};

			if (deps.iface_status)
				deps.iface_status(centry.cfg.interface, decide);
			else
				decide(null);
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

				// A SIM block is not a decision, it is a condition — and it can
				// end: the PIN gets entered, the card gets reseated. Re-arm the
				// context so a later `registered` picks it up again, the same
				// marker a reconnect-hold give-up uses. Without it the context
				// was parked for good and only a manual ifup revived it (field
				// report on an EG060K-EA: PIN entered, modem registered, nothing
				// happened).
				entry.reconnect_on_register = true;

				// ...and remember that WE took the interface down. netifd's ubus
				// `down` clears autostart, which the ready path otherwise reads
				// as an operator ifdown.
				entry._our_down = true;

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

		// eSIM surface known (the modem finished its eSIM probes): with the
		// eUICC active, the APDU window right after bring-up is the natural
		// moment to read eid + profiles once — best-effort, no error surface;
		// the manual ubus ops re-probe per call and stay the on-demand path
		case 'esim_ready':
			if (!self.modem_esim || !modem.slot_status || modem._esim_refreshed)
				return;

			modem._esim_refreshed = true;   // once per modem object lifetime

			uloop.timer(3000, () => {
				// no READY gate: on an empty eUICC the modem never reaches
				// READY (registration cannot succeed) — the APDU window is
				// independent of the registration state. Any failure clears
				// the latch so the next esim_ready (re-enumeration, slot
				// switch) retries instead of staying empty forever.
				if (!modem.at) {
					modem._esim_refreshed = false;
					return;
				}

				modem.slot_status((err, slots) => {
					// the active eUICC's own physical slot (SUB2 on the FM350
					// dual-SIM module) — never a hardcoded slot 1
					let eslot = filter(slots ?? [], (s) => s.is_euicc && s.active)[0];

					if (err || !eslot) {
						modem._esim_refreshed = false;
						return;
					}

					self.modem_esim(modem.id, 'eid', { slot: eslot.physical }, (e2, r2) => {
						if (e2) {
							modem._esim_refreshed = false;
							return;
						}

						self.modem_esim(modem.id, 'profiles', { slot: eslot.physical }, (e3, r3) => {
							if (e3) {
								modem._esim_refreshed = false;
								return;
							}

							modem.esim_info = {
								eid: r2?.eid ?? null,
								profiles: r3?.profiles ?? [],
							};
							log('info', sprintf('modem %s: eSIM surface read (eid %s, %d profile(s))',
								modem.id, modem.esim_info.eid ?? '?', length(modem.esim_info.profiles)));
						});
					});
				});
			});
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
	// The daemon (no per-interface monitor) keeps each context up; the
	// reconnect/hold machinery lives in reconnect.uc (installed above).

	// how long to wait for a mode-switched PPP-only modem to re-enumerate before
	// flagging it stuck (the switch is once-guarded, so without this a reset that
	// never re-enumerates would leave the modem unmanaged forever).
	let modeswitch_liveness_ms = opts?.timing?.modeswitch_liveness_ms ?? 60000;

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

	let on_context_event = (name, ctx, event, data) => {
		let entry = self.contexts[name];

		// idempotent renew: re-pushing the same addresses to netifd only churns it
		// and its address-dependent consumers (odhcpd RAs, firewall reloads, host
		// routes). Async-probe netifd's live v4/v6 and skip the renew when the link
		// is up and both addresses already match what the session holds. `force`
		// (a real IP change / relink) and any doubt (no probe, probe fails) fall
		// through to the renew, so this can only ever SKIP a genuine no-op.
		let renew_iface = (force) => {
			let do_renew = () => {
				if (deps.renew_interface && entry?.cfg?.interface)
					deps.renew_interface(entry.cfg.interface);
			};

			if (force || !deps.iface_status || !entry?.cfg?.interface)
				return do_renew();

			let first_addr = (arr) =>
				(type(arr) == 'array' && length(arr)) ? arr[0]?.address : null;
			let same = (a, b) => (a ?? '') == (b ?? '');

			deps.iface_status(entry.cfg.interface, (st) => {
				if (st?.up &&
				    same(first_addr(st['ipv4-address']), ctx.settings?.ipv4?.addr) &&
				    same(first_addr(st['ipv6-address']), ctx.settings?.ipv6?.addr)) {
					log('info', sprintf('interface %s: v4/v6 unchanged (%s|%s), skipping renew',
						entry.cfg.interface, ctx.settings?.ipv4?.addr ?? '',
						ctx.settings?.ipv6?.addr ?? ''));
					return;
				}
				do_renew();
			});
		};

		switch (event) {
		case 'up':
			// a working data connection resets the recovery ladder
			ctx.modem.note_connect_success();
			clear_reconnect(name);
			emit('wwand.context', { context: name, interface: entry?.cfg?.interface, event: event });

			// RNDIS v6 model: the modem's v6 arrives via RA on the parent netdev.
			// A dhcpv6 subinterface on the parent's device (@<parent>, auto:1)
			// lets netifd run the v6 client (address/route/DNS/PD) natively —
			// runtime-only (netifd ubus add_dynamic, nothing in uci), and netifd
			// manages its lifecycle on its own; a matching user section wins.
			if (deps.ensure_wan6 && ctx.modem?.datapath?.backend == 'rndis_host' &&
			    entry?.cfg?.interface && ctx.config?.pdp_type != 'ipv4') {
				log('info', sprintf('interface %s: ensuring the dynamic dhcpv6 subinterface (RNDIS v6 model)',
					entry.cfg.interface));
				// the pdp type rides along for the log only — this gate has
				// already established that the context is v6-capable
				deps.ensure_wan6(entry.cfg.interface, ctx.config?.pdp_type);
			}

			// detect an address change vs the last applied settings. When the IP
			// changed AND the interface opted into hard_reconnect_on_ip_change, ask
			// the proto shim for a netifd link down->up (one-shot `relink`) instead
			// of the plain in-place renew, so dependent tunnels/xfrm re-follow the
			// new local address (netifd drops an in-place address update for
			// resolved host dependencies — see docs/architecture.md). Default off.
			if (entry) {
				let cur_ip = sprintf('%s|%s', ctx.settings?.ipv4?.addr ?? '',
					ctx.settings?.ipv6?.addr ?? '');
				let changed = (entry._applied_ip != null && entry._applied_ip != cur_ip);

				entry._applied_ip = cur_ip;

				if (changed && entry.cfg?.hard_reconnect_on_ip_change) {
					entry._relink_once = true;
					log('notice', sprintf('interface %s: IP changed (%s) — hard reconnect (link down->up) so dependent tunnels/xfrm follow',
						entry.cfg?.interface, cur_ip));
				}
			}

			// push settings to netifd in place (never a teardown). A no-op during
			// initial setup (not yet IFS_UP); re-applies config after reconnect/
			// adoption — but skipped when the address is unchanged (renew_iface).
			// A pending relink (IP changed + hard_reconnect_on_ip_change) always
			// renews so the shim runs its link down->up.
			renew_iface(entry?._relink_once);

			// connect-first backends (MBIM/NCM): the session/link came up before
			// netifd ran proto setup — kick netifd now so it runs setup and
			// adopts the live session.
			if (entry?._kick_after_connect) {
				entry._kick_after_connect = false;

				if (deps.kick_interface && entry.cfg.interface) {
					let kentry = entry, kiface = entry.cfg.interface;

					let do_kick = () => {
						log('info', sprintf('kicking interface %s to adopt the connected session', kiface));
						deps.kick_interface(kiface);
					};

					// re-check: the connect takes seconds, and an ifdown landing in
					// that window must not be undone by the kick that follows it
					if (deps.iface_status)
						deps.iface_status(kiface, (st) => {
							if (st?.autostart === false) {
								kentry.wanted = false;
								log('notice', sprintf('interface %s went administratively down while connecting, not kicking it up',
									kiface));
								return;
							}

							do_kick();
						});
					else
						do_kick();
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
			// A modem-level AT reattach (netsel_ops) bounces the contexts itself
			// — don't race its bounce with enter_reconnecting.
			if (entry?.wanted && !ctx?.modem?._reattaching)
				enter_reconnecting(name);
			break;

		case 'settings':
			// modem pushed new IP settings — renew the interface in place (no
			// teardown); netifd re-reads context_settings. Idempotent: skipped when
			// the pushed addresses actually match what netifd already has.
			renew_iface(false);
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

		// unhook from the modem's context list — else the dead ctx is retained
		// and keeps receiving notify_contexts events (leak + latent misbehavior)
		if (entry.ctx?.modem?.detach_context)
			entry.ctx.modem.detach_context(entry.ctx);

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

	// is this device claimed by a foreign interface? Checked against BOTH the
	// configured name and the resolved one: `option device wwan0` and the
	// /dev/cdc-wdm0 it resolves to are the same hardware, and a foreign section
	// may name either.
	let blocked_by = (...devs) => {
		for (let d in devs)
			if (d != null && d != '' && self.blocked?.[d])
				return { device: d, ...self.blocked[d] };

		return null;
	};

	// A path-shaped claim (uqmi/umbim `devpath`, wwan.sh `bus`) names the same
	// hardware without naming the device node, so it has to be compared on the
	// sysfs path. deps.hw_path does the resolving — daemon.uc stays free of fs
	// and discovery imports.
	let blocked_by_path = (cfg, control) => {
		if (!length(keys(self.blocked_paths ?? {})) || !deps.hw_path)
			return null;

		let mine = deps.hw_path.modem(cfg, control);

		if (!mine)
			return null;

		for (let raw, o in self.blocked_paths) {
			let theirs = deps.hw_path.claim(raw);

			if (theirs && deps.hw_path.same(mine, theirs))
				return { device: sprintf('%s=%s', o.opt, raw), path: theirs, ...o };
		}

		return null;
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

		// refuse to bind a device another stack owns, rather than contending for
		// it. Surfaced as control_note so status()/LuCI show WHY the modem is
		// idle instead of it looking merely absent.
		let claim = blocked_by(cfg.device, cfg.ctldevice, control?.device, control?.netdev)
			?? blocked_by_path(cfg, control);

		if (claim) {
			log('warn', sprintf('modem %s: device %s is owned by interface %s (proto %s) — ignoring this modem',
				name, claim.device, claim.interface, claim.proto));

			self.modems[name] = {
				cfg: cfg, device: null, netdev: null, muxinfo: muxinfo,
				l3_name: l3name ?? null, modem: null, protocol: null,
				control_note: sprintf('device %s is owned by interface %s (proto %s)',
					claim.device, claim.interface, claim.proto),
				_sig: self.modems[name]?._sig,
			};

			return;
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

		// A PCIe/MHI modem must not be allowed to runtime-suspend: on the
		// hardware seen so far the resume kills the endpoint outright and no
		// software reset gets it back. Do it here, the moment the control
		// device is known present — a later suspend is unrecoverable, and the
		// one that killed the modem hit while it sat idle in SIM_BLOCKED.
		nlmod.pin_runtime_pm(nlmod.default_fx((level, msg) => log(level, msg)), device);

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

		// same for the datapath: `option mux` may name an add-on backend, which
		// has to be loaded BEFORE the modem starts its datapath bring-up.
		// Canonical spelling from here on — the name doubles as a module name
		// (`wwand.datapath_<mux>`), so a legacy `none` or a typed `raw-ip` must
		// not reach require() as written.
		let mux = nlmod.canon_mux(cfg.mux) ?? 'auto';

		// the datapath candidates handed to netlink.select_backend: exactly the
		// one named by `option mux`, or — under 'auto' — every installed plugin,
		// each of which decides for itself via probe() whether this box is its
		// hardware. QMI and MBIM both go through it (their built-ins are entries
		// in that same interface); NCM's cdc_ncm/cdc_ether datapath has no mux
		// to choose, so it is left out.
		let dp_plugins = null;

		if (proto != 'ncm') {
			if (!nlmod.builtin_mux(mux)) {
				let impl = load_datapath_fn(mux);

				if (!nlmod.valid_plugin(impl)) {
					log('err', sprintf('modem %s: mux backend %J needs the wwand-datapath-%s package, which is not installed (or does not provide a datapath)',
						name, mux, mux));
					entry.control_note = sprintf('wwand-datapath-%s package not installed', mux);
					return;
				}

				dp_plugins = { [mux]: impl };
			}
			else if (mux == 'auto')
				dp_plugins = list_datapaths();
		}

		let datapath =
			(proto == 'mbim') ? { netdev: entry.netdev, mux: mux, plugins: dp_plugins,
			                      mux_links: muxinfo?.list ?? [], fx: deps.datapath_fx } :
			(proto == 'ncm')  ? { netdev: entry.netdev, fx: deps.datapath_fx } :
			                    { netdev: entry.netdev, ep_id: ep_id, ep_type: ep_type, mux: mux,
			                      plugins: dp_plugins,
			                      dgram_size: cfg.dl_datagram_max_size,
			                      qmap_version: cfg.qmap_version,
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
	// last-logged blocklist, so the notice repeats only when the set changes
	let blocked_sig = null;

	self.apply_config = function(parsed) {
		// l3-device learn-back switch; read before the no-op short-circuit so a
		// globals-only edit still updates it
		self.write_device = parsed.globals?.write_device ?? true;

		// zero-config autosetup gate (default on; wwand_globals option autosetup)
		self.autosetup = parsed.globals?.autosetup ?? true;

		// Device blocklist: every device a non-wwand interface names belongs to
		// that stack. Logged when the set CHANGES (not on every reload trigger —
		// netifd fires those for unrelated edits), so the reason a modem is being
		// left alone is in the log without repeating forever.
		self.blocked = parsed.blocked ?? {};
		self.blocked_paths = parsed.blocked_paths ?? {};

		let bsig = sprintf('%J', [ self.blocked, self.blocked_paths ]);

		if (bsig != blocked_sig) {
			blocked_sig = bsig;

			let items = [];

			for (let dev, o in self.blocked)
				push(items, sprintf('%s (interface %s, proto %s)', dev, o.interface, o.proto));

			for (let raw, o in self.blocked_paths)
				push(items, sprintf('%s=%s (interface %s, proto %s)', o.opt, raw, o.interface, o.proto));

			if (length(items))
				log('notice', sprintf('device blocklist: %s — owned by a non-wwand interface, wwand will not touch %s',
					join(', ', sort(items)), length(items) > 1 ? 'them' : 'it'));
		}

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
					registered: is_registered(reg),
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
		// same bound as check_modem: refs are section/interface names
		if (type(ref) != 'string' || length(ref) == 0 || length(ref) > 64)
			return null;

		if (self.contexts[ref])
			return ref;

		for (let name, entry in self.contexts)
			if (entry.cfg.interface == ref)
				return name;

		return null;
	};

	// context settings assembly (live config re-read, MTU/IPv6 link side effects,
	// the proto-shim settings payload) — extracted to ctx_settings.uc; bound as
	// locals so the call sites below read unchanged.
	ctx_settings.install(self, {
		log: log,
		read_config: deps.read_config,
		datapath_fx: deps.datapath_fx,
	});

	let refresh_context_cfg = self._refresh_context_cfg;
	let apply_mtu = self._apply_mtu;
	let enable_ipv6 = self._enable_ipv6;
	let settings_result = self._settings_result;

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

		// our own give-up after a reconnect-hold blackhole (reconnect.uc set
		// _holdexpiry before downing): tear the interface down now, but stay
		// re-armable — a later `registered` reconnects it (modem_registered),
		// unlike an operator ifdown below which is meant to stay down.
		if (entry._holdexpiry) {
			entry._holdexpiry = false;
			entry.wanted = false;
			entry.reconnect_on_register = true;
			clear_reconnect(name);
			return entry.ctx.down(() => cb(null, {}));
		}

		// netifd tore the interface down (admin/config) → no longer wanted; stop
		// reconnect and clear any stale re-arm marker (operator intent wins).
		entry.wanted = false;
		entry.reconnect_on_register = false;
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
				manufacturer: entry.modem?.info?.manufacturer,
				model: entry.modem?.info?.model,
				revision: entry.modem?.info?.revision,
				// firmware version, backend-neutral: MBIM device caps firmware_info,
				// else the QMI DMS / AT CGMR revision
				firmware: entry.modem?.info?.firmware ?? entry.modem?.info?.revision,
				imei: entry.modem?.info?.imei,
				imsi: entry.modem?.info?.imsi,
				iccid: entry.modem?.info?.iccid,
				msisdn: entry.modem?.info?.msisdn,
				usb: entry.modem?.info?.usb,
				identity_mismatch: entry.modem?.identity_mismatch,   // {expected,found} if the pinned IMEI didn't match
				at_tty: entry.modem?.at_tty,
				// at2 released for external tools
				at2_released: entry.modem?.at2_released,
				// can this model's control protocol be switched (QMI <-> MBIM)?
				// The AT recipe is per-model and hardware-unverified ones are
				// deliberately not offered, so a UI must gate on this rather
				// than on "the modem currently speaks QMI or MBIM" — which is
				// true of nearly every modem and says nothing about switching.
				proto_switch: entry.modem?.protocol_switch_supported?.() ?? false,
				// cell/freq lock read-back (Quectel QNWLOCK / MeiG ^CELLLOCK), null if none
				locks: entry.modem?.locks,
				registration: entry.modem?.reg,
				registration_detail: entry.modem?.reg_detail,
				// current fine access technology (NB-IoT/LTE-M/5G-SA/… identified
				// over AT where QMI/MBIM can't) and a best-effort capability
				// summary { rats, iot_modes, ntn }
				rat: entry.modem?.rat_label,
				caps: entry.modem?.caps,
				config_warnings: entry.modem?.config_warnings,
				// FCC-lock probe (Fibocom GTFCCEFFSTATUS?): 0/1/2, null = not probed
				fcc_lock: entry.modem?.fcc_lock,
				// eSIM surface from the bring-up refresh (eUICC active only)
				esim: entry.modem?.esim_info ?? null,
				// the datapath that actually came up (rmnet/qmimux/vlan/raw_ip
				// or a plugin name) — with 'auto' able to land on a plugin,
				// "which one won" must be visible without reading the log
				datapath: entry.modem?.datapath?.backend,
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
		         globals: {
		             hold_max_ms: self._hold_max_ms(),
		             // Datapaths selectable via `option mux` on THIS box: the
		             // pseudo-modes and built-ins netlink knows, plus every
		             // installed add-on package — so a UI offers what is
		             // actually there instead of a hardcoded list that goes
		             // stale. Each entry carries the control protocols it
		             // applies to, since offering an MBIM modem a qmi_wwan mux
		             // is offering a config that cannot work.
		             datapaths: datapath_catalog(),
		         } };
	};

	// resolve a modem ref for a cb-style ubus method: returns the entry, or reports
	// via cb and returns null. A modem being waited on (detached, not yet
	// re-enumerated) reports modem_waiting, not a misleading no_such_modem.
	let check_modem = (ref, cb) => {
		// refs are uci section names used as hash keys — bound them so an
		// oversized or non-string bus value is rejected outright
		if (type(ref) != 'string' || length(ref) == 0 || length(ref) > 64) {
			cb({ error: 'no_such_modem', ref: null });
			return null;
		}

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

	// SIM/SMS/eSIM/APDU + hardware reset/repower ops live in their own modules
	// (same install pattern); the daemon keeps lifecycle, config and status.
	simops.install(self, { log: log, check_modem: check_modem, load_esim: load_esim });
	hwops.install(self, { log: log, check_modem: check_modem, board: deps.board,
	                      board_gpio_ok: board_gpio_ok });

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
				registered: is_registered(entry.modem?.reg),
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

	// datapath / muxing status: the config the daemon applied at datapath setup
	// (backend, negotiated WDA aggregation, urb size, endpoint, mux channels)
	// plus live aggregation statistics derived from the netdev counters.
	self.modem_datapath = function(ref) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return { error: 'no_such_modem', ref: ref };

		let dp = entry.modem.datapath;

		if (!dp)
			return { error: 'no_datapath' };

		let parent = dp.parent ?? dp.netdev;

		// live mux child L3 devices: the rmnet/qmimux children get renamed to
		// their context's stable wwandN name after setup, so dp.mux_devs (the
		// pre-rename wwan0mN) is stale — collect the current names from the
		// muxed contexts bound to this modem instead.
		let children = [];
		let chan = [];

		for (let cname, centry in self.contexts) {
			if (centry.cfg.modem != ref || !(centry.cfg.mux_id > 0))
				continue;

			// the live L3 device (same resolution status uses for l3_device):
			// the rmnet child renamed to its stable wwandN name
			let l3 = derive_netdev(centry);

			if (!l3)
				continue;

			push(children, l3);
			push(chan, { mux_id: centry.cfg.mux_id, netdev: l3,
			             interface: centry.cfg.interface });
		}

		let out = {
			backend: dp.backend,
			protocol: entry.modem.protocol,
			parent: parent,
			v5: dp.v5,
			urb_size: dp.urb_size,
			ep_id: dp.ep_id,
			ep_type: dp.ep_type,
			wda: dp.wda,            // negotiated QMAP aggregation maxima (QMI)
			ul_agg: dp.ul_agg,      // host-side uplink coalesce config (QMI)
			channels: chan,         // live mux channels (id -> l3 device)
		};

		// whatever the datapath itself wants shown: the generic block above knows
		// QMAP and NTB, and nothing about a vendor datapath's own view of the
		// link. Absent for every datapath that contributes none.
		let extra = nlmod.datapath_status(deps.datapath_fx, dp.backend, parent,
			list_datapaths());
		if (extra)
			out.extra = extra;

		// MBIM/NCM aggregate via NTB (cdc_ncm framing) instead of QMAP — surface
		// the NTB parameters from sysfs so muxing/aggregation is observable there
		// too. Absent (null) on a QMI qmi_wwan parent.
		let ntb = nlmod.cdc_ncm_params(null, parent);
		if (ntb)
			out.ntb = ntb;

		// live counters + aggregation ratio. The parent-vs-children packet ratio
		// only MEASURES aggregation for QMAP backends, where the parent counts
		// aggregated USB frames and the children the demuxed IP packets. On
		// MBIM/NCM the cdc_ncm layer deaggregates the NTB below the netdev, so
		// parent and children both count IP packets and the ratio is always ~1 —
		// drop it there (the NTB block is the aggregation indicator); keep the
		// raw counters, which are useful on every backend (on NCM there are no
		// children at all — the parent counters alone are the byte counters).
		if (parent) {
			out.stats = nlmod.datapath_stats(null, parent, children ?? []);

			// the parent-vs-children packet ratio only MEASURES aggregation
			// where QMAP rides the parent. Asked of the datapath rather than
			// matched against a list of names, which a datapath added later
			// (the vendor NSS one) would have fallen out of.
			if (!nlmod.datapath_caps(dp.backend, list_datapaths()).qmap) {
				delete out.stats.rx_aggregation;
				delete out.stats.tx_aggregation;
			}
		}

		return out;
	};

	self.modem_location = function(ref) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return { error: 'no_such_modem', ref: ref };

		if (!entry.modem.loc) {
			// distinguish "not configured" from "configured but the backend
			// cannot do it" — 'location_disabled' on an MBIM/NCM modem WITH
			// `option location` set was misleading
			if (entry.cfg?.location && entry.modem.protocol != 'qmi')
				return { error: 'unsupported_on_backend' };

			return { error: 'location_disabled' };
		}

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
			// the installed datapaths go with it: autosetup decides from them
			// whether the interface it creates carries a QMAP mux channel
			if ((self.autosetup ?? true) && !length(keys(self.modems)) &&
			    deps.autosetup_create && deps.autosetup_create(devname, list_datapaths())) {
				log('notice', sprintf('autosetup: modem %s appeared without any configuration — created wwmodem_auto + interface wwan0 (wan zone)', devname));

				if (self.reload)
					self.reload();

				// ...and tell NETIFD too, not just ourselves. The sections were
				// written straight into uci, so until netifd re-reads it the
				// interface simply does not exist for it — every kick/down on
				// wwan0 came back NOT_FOUND (ubus status 4), seen on a virgin
				// BPi-R4. Phase 2 (autosetup_fill) had this all along.
				if (deps.network_reload)
					deps.network_reload();
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
			// hotplug devnames are basenames: 'cdc-wdm0' (usbmisc) / 'wwan0qmi0'
			// (wwan framework, PCIe/MHI) — both have a control device; 'usb0' (net)
			// for NCM which has only a datapath netdev.
			let dev = (p.kind == 'ncm')
				? p.netdev : replace(p.device ?? '', /^.*\//, '');

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
