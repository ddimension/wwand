// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — daemon core: owns modems and contexts, applies configuration,
// dispatches ubus ops. Transport/sysfs/ubus access is injected (opts.deps) so
// the core runs host-side against mocks.

'use strict';

import * as uloop from 'uloop';
import * as apndb from 'wwand.apndb';
import * as modem_quirks from 'wwand.modem_quirks';
import * as discovery from 'wwand.discovery';
import * as netsel_ops from 'wwand.netsel_ops';
import * as simops from 'wwand.simops';
import * as simmod from 'wwand.sim';
import * as hwops from 'wwand.hwops';
import * as plugins from 'wwand.plugins';
import * as siminventory from 'wwand.siminventory';
import * as cfgmod from 'wwand.config';
import * as nlmod from 'wwand.netlink';
import * as reconnect from 'wwand.reconnect';
import * as recoverymod from 'wwand.recovery';
import * as ctx_settings from 'wwand.ctx_settings';
import * as context_common from 'wwand.context_common';
import * as modem_common from 'wwand.modem_common';
// module scope: the lazy backend loaders live outside create(), so they cannot
// use its injected `log` dep and go to the shared sink directly
import * as logmod from 'wwand.log';

// The agreed MS extension version as text. Both halves of the u16, the way
// mbim_client's own open-time log line writes it (mbim_client.uc:203-205) —
// only x.0 generations are defined today, but reading the number the way its
// owner does is cheaper than being right about that forever.
function mbimex_text(v)
{
	return v ? sprintf('%d.%d', (v >> 8) & 0xff, v & 0xff) : null;
}

// backends load lazily; a missing package returns null (cached failure) so
// start_modem reports it clearly instead of crashing. Lazy also so a QMI-only
// install never loads MBIM's ~1.4k lines/schema. require() cannot load ES
// modules directly (`export` is a syntax error in plain scripts) — the *_lazy
// names are exportless wrapper scripts.
// `announce` fires ONCE, the first time the module actually reaches memory.
// Which backends are INSTALLED and which are LOADED are different questions: a
// box can carry all three packages and only ever load the one its modem needs,
// and a log that answers only the first cannot tell a missing package from a
// backend nothing asked for.
let lazy_backend = (mod, announce) => {
	let m = null, failed = false;

	return () => {
		if (failed)
			return null;

		if (m == null) {
			try {
				m = require(mod);

				if (announce)
					announce();
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

let loaded_note = (name) => () => logmod.log('notice', 'backend %s loaded', name);

let load_qmi = lazy_backend('wwand.qmi_lazy', loaded_note('qmi'));
let load_mbim = lazy_backend('wwand.mbim_lazy', loaded_note('mbim'));
// NCM support (cdc_ncm / cdc_ether, AT-controlled) is a separate package (wwand-ncm)
let load_ncm = lazy_backend('wwand.ncm_lazy', loaded_note('ncm'));
// optional eSIM module (wwand-esim); absent => feature reports esim_not_installed
let load_esim = lazy_backend('wwand.esim', loaded_note('esim'));

// What a wwand_sim DOES to the card in use: the fields the SIM step and the
// dial read. Its `name` is a label, and a rename — or a new section holding
// only a name — must not look like a change of settings, which re-programs
// the attach profile and re-dials (apply_config, apply_sim_change).
// plmn_list names the list and plmn_restore is what it resolves to: an edit to
// the list itself changes only the second, and must still be applied.
const SIM_EFFECT = [ 'pincode', 'apn', 'auth', 'username', 'password', 'pdp_type',
	'plmn_list', 'plmn_restore' ];

function sim_effect(s)
{
	return sprintf('%J', map(SIM_EFFECT, (k) => s?.[k] ?? null));
}

// The per-modem band allow-lists (config wwand_modem). Applied live and kept
// out of the restart signature — see apply_config.
const BAND_OPTS = [ 'band_lte', 'band_nr', 'band_umts' ];

function band_sig(cfg)
{
	return sprintf('%J', map(BAND_OPTS, (k) => cfg?.[k] ?? []));
}

// status' config_warnings, plus the two ways a configured band list can be
// dead: the modem has no band command wwand drives (a QMI/MBIM modem keeps
// its bands in its own NV, set through the settings editor), or the last
// apply failed. Said here because nothing else would — an ignored band
// list looks exactly like one the network happens to agree with.
function band_warnings(entry)
{
	let w = entry?.modem?.config_warnings;
	let m = entry?.modem;
	let configured = length(filter(BAND_OPTS, (k) => length(entry?.cfg?.[k] ?? [])));

	if (!configured || m?.info?.model == null)
		return w;

	// the NCM backend answers true/false/null (null: not identified yet);
	// QMI and MBIM have no such method — they keep bands in modem NV
	let own = type(m.bands_applicable) == 'function';
	let ok = own ? m.bands_applicable() : false;
	let note = null;

	if (ok == null)
		return w;

	if (!ok && !own)
		note = 'band_lte/band_nr/band_umts are applied only where the band command does not persist (Fibocom FM350/FM150, +GTACT); this modem keeps its bands itself — set them in Modem Tools';
	else if (!ok)
		note = sprintf('band_lte/band_nr/band_umts are not applied: wwand drives no band command on %s (only Fibocom FM350/FM150, +GTACT)',
			m.info.model);
	else if (m.band_apply_error)
		note = sprintf('configured band lists not applied: %s',
			m.band_apply_error.detail ?? m.band_apply_error.error ?? '?');

	if (!note)
		return w;

	return [ ...(w ?? []), { check: 'band_lists', severity: 'warn', message: note,
	                          expected: null, actual: null } ];
}

// QMI UIM Remote (UIMRMT, service 0x32): what a modem needs to run on a card
// that is not in its slot (wwand-rsim) — libqmi 1.38.0 qmi-enums.h
// QMI_SERVICE_UIMRMT = 0x32.
const QMI_SERVICE_UIM_REMOTE = sprintf('%d', 0x32);

// Can this modem run on a remote SIM? From the services the modem itself
// lists (CTL GET_VERSION_INFO): natively over QMI, or over the
// QMI-over-MBIM passthrough — never guessed from the model. Listed is not
// the same as switched on: a Quectel lists it with the EFS switch off, and
// `wwandctl rsim MODEM switch` reads that switch.
//   { supported: true, via: 'qmi' | 'mbim-passthrough' }
//   { supported: false, reason }   the modem cannot
//   { supported: null, reason }    not known yet (services not read, the
//                                  passthrough not set up)
//   null                           no modem object
function remote_sim_support(protocol, m)
{
	if (!m)
		return null;

	if (protocol == 'qmi') {
		if (type(m.services) != 'object')
			return { supported: null, reason: 'the modem\'s QMI services are not read yet' };

		return m.services[QMI_SERVICE_UIM_REMOTE]
			? { supported: true, via: 'qmi' }
			: { supported: false, reason: 'the modem offers no QMI UIM Remote service' };
	}

	if (protocol == 'mbim') {
		if (type(m.pt?.services) == 'object')
			return m.pt.services[QMI_SERVICE_UIM_REMOTE]
				? { supported: true, via: 'mbim-passthrough' }
				: { supported: false, reason: 'the QMI passthrough offers no UIM Remote service' };

		if (m._pt_failed)
			return { supported: false, reason: 'the modem has no QMI passthrough over MBIM' };

		return { supported: null, reason: 'the QMI passthrough is not set up yet' };
	}

	return { supported: false, reason: sprintf('no QMI on a %s modem', protocol ?? 'modem of unknown protocol') };
}

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

// Which escalation step a vanished modem has earned, or null. Pure: the caller
// records the rung and performs the action, the same split recovery.on_attempt()
// uses — a decision that is only reachable through a timer is a decision that
// cannot be tested.
//
//   'reset'  pulse the board's modem reset / power GPIO
//   'reboot' restart the router
//
// Only ever for a modem that WAS running (`entry.vanished`). A cold-boot wait
// must never reboot the router, and after a daemon restart we cannot know the
// modem was ever there — so the flag is deliberately not persisted.
export function vanish_action(entry, now, timing)
{
	if (!entry || entry.modem || !entry.vanished || !entry.waiting_since)
		return null;

	let gone = now - entry.waiting_since;
	let rung = entry._vanish_rung ?? 0;
	let t = timing ?? {};

	if (rung < 1 && gone >= (t.vanish_reset_after ?? 120))
		return 'reset';

	// The reboot gate is the ladder's own: `failreboot <= 0` disables ONLY the
	// reboot, so a headless box can log forever without restarting under itself.
	if (rung < 2 && gone >= (t.vanish_reboot_after ?? 900))
		return (+(entry.cfg?.failreboot ?? 100) > 0) ? 'reboot' : 'none';

	return null;
};

// The callback for one eUICC read (daemon probe_euicc), built out here so it
// closes over nothing but these four parameters. Built inline, the closure
// found the read's state object null when it ran (test_daemon, 2026-10-01).
// The cause was the call that issued the read, `(deps.card_euicc_info ??
// simmod.card_euicc_info)(…)`: a called parenthesized `??` with a member
// expression on the right misplaces the interpreter's stack and overwrites a
// neighbouring local (docs/gotchas.md, reproduced 2026-10-10). That call is
// two statements now; the helper stays, as it costs nothing.
function euicc_answer(fn, entry, m, st)
{
	return (info) => fn(entry, m, st, info);
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

		// `datapath_<name>.uc` is the ADD-ON namespace and nothing else may live
		// in it: this glob offers every `datapath_*.uc` as a plugin, so an
		// internal module named that way is tried as one and logs "plugin …: not
		// usable" on every start. An internal module gets an internal name
		// (`modem_datapath_qmi.uc`).
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

		// notice, not info: on a box whose datapath does not behave, the first
		// question is always which implementations were even available, and the
		// built-ins belong in that answer as much as the add-ons do
		log('notice', sprintf('datapath: built-in %s%s',
			join(', ', map(nlmod.datapath_catalog(), (d) => d.name)),
			length(installed_dp) ? sprintf('; add-ons %s', join(', ', keys(installed_dp)))
			                     : ' (no add-on datapath installed)'));

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
	// transient-loss hold timer) — lives in reconnect.uc; bound as locals
	// so the call sites below read unchanged. Also installs set_hold_max_ms.
	// forward-declared: reconnect.install() below is handed a reference to it
	// and the definition sits further down, where the rest of the marker lives.
	// A `let` referenced before its initialisation throws in ucode even from
	// inside a closure (see wwand/CLAUDE.md), so the binding has to exist here.
	let mark_our_down;

	reconnect.install(self, {
		log: log,
		timing: opts?.timing,
		down_interface: deps.down_interface,
		mark_our_down: (entry) => mark_our_down(entry),
	});

	let activate = self._activate;
	let clear_reconnect = self._clear_reconnect;
	let retry_activate = self._retry_activate;
	let enter_reconnecting = self._enter_reconnecting;

	// forward-declared: ucode closures capture only already-declared vars, and
	// these self-reference (the TDZ trap — see CLAUDE.md ucode gotchas)
	let derive_netdev;
	let start_modem, start_context;   // forward-declared: stop_modem restarts a retired modem
	let detach_modem;   // forward-declared: used by modem_removed above its definition
	let maybe_autosetup_fill;
	let note_unholdable;   // defined beside plugin_radio; the registered handler uses it

	// --- modem event handlers ---------------------------------------------

	// `_our_down` records that netifd's cleared `autostart` is OUR doing. netifd
	// runs interface_set_down() for every `down` and exposes no way to tell two
	// of them apart, so the marker is the only discriminator there is — and that
	// makes both of its edges load-bearing.
	//
	// BOUNDED, because an unbounded marker shadows the next genuine `ifdown`:
	// wwand downs an interface (a SIM block, a stuck-pending reset), the
	// operator later runs `ifdown` deliberately, and the modem's next
	// `registered` would read that as our own down and undo it.
	//
	// THE TTL IS THE WHOLE OF THE GUARANTEE, and it is worth being plain about
	// what that buys and what it costs. netifd records no author for a `down`,
	// so inside the window an operator's ifdown and ours are the same event and
	// wwand will undo the operator's — once; the kick that follows clears the
	// marker on evidence, so a repeated ifdown sticks. An earlier version of
	// this comment called the window "seconds", which reads like a bound and is
	// not one: the constant is 180 s, and the ddimension/wwand#35 case below
	// needed 115 s of it. The window has to outlive the modem outage that
	// prompted our down, and that is not a quantity this code gets to choose.
	// (found by audit, 2026-09-07; the cost stated 2026-09-20)
	//
	// Cleared on EVIDENCE, never on intent: kick_interface is fire-and-forget
	// (main.uc hands netifd's `up` to conn.defer and only logs the reply), so
	// clearing the marker when we ASK for the up threw away the one explanation
	// for autostart=false whenever that up did not land. It is cleared when a
	// later status actually shows the interface back — see decide().
	const OUR_DOWN_TTL = 180;

	// A SUBINTERFACE MUST NOT BE STARTED WHILE THE PARENT HAS NO LINK-LOCAL
	// ADDRESS. Applying new IPv4 settings to the parent takes the device's
	// fe80:: away for a fraction of a second, and ensure_wan6's down/up landed
	// inside that gap: odhcp6c came up on a device it could not open an LLA
	// socket on, its Router Solicitation went nowhere ("Failed to send RS
	// (Network unreachable)"), and the FIRST attempt was lost. Its retry
	// covers it on a network that answers, which is why this stayed invisible —
	// it costs a slow start, not the connection. Field-captured on an FM350-GL
	// where a profile switch changed the IPv4 address (ddimension/wwand#35,
	// 2026-09-19).
	//
	// scope 20 in /proc/net/if_inet6 is link-local; the columns are
	// addr ifindex prefixlen scope flags devname.
	// How long a netifd status probe may be outstanding before the next renew
	// stops waiting for it. Generous on purpose: this is not a request timeout
	// (nothing here can cancel the request), only the point at which an answer
	// that never came stops blocking the interface's renews.
	const PROBE_STALE_S = 30;

	// Upper bound on the radio cycle a dial timeout starts: low_power, the
	// settle wait, online — seconds normally. Only a backstop for a callback
	// that never comes; the reconnect it releases is idempotent.
	const REATTACH_GUARD_MS = 60000;

	const LLA_WAIT_MS = 250;
	const LLA_WAIT_TRIES = 12;      // ~3 s, then start anyway

	let has_lla = (netdev) => {
		// cannot tell -> never block on it
		if (!netdev || !deps.datapath_fx?.read)
			return true;

		for (let line in split(deps.datapath_fx.read('/proc/net/if_inet6') ?? '', '\n')) {
			let f = split(trim(line), /[ \t]+/);

			if (length(f) >= 6 && f[5] == netdev && f[3] == '20')
				return true;
		}

		return false;
	};

	// KEYED BY INTERFACE, NOT CARRIED ON THE ENTRY. The marker is evidence
	// about an interface, and the context entry lives SHORTER than the
	// interface. A config reload that cannot resolve an interface's modem
	// produces no entry for it at all (config.uc:939-942 warns "references
	// unknown modem" and skips it), so a marker on the entry would have nothing
	// to be carried over from. Re-adding the modem would then build a fresh
	// entry with no marker, the status poll would see netifd's cleared
	// autostart, and wwand would park an interface IT had taken down —
	// "administratively down (ifdown), leaving it alone", until someone runs
	// ifup.
	//
	// That is the tail of ddimension/wwand#35: the down was ours (13 failed
	// attempts, hold expiry) at 18:48:02, the "unknown modem" warning landed
	// at 18:47:49 between the two, and the first refusal at 18:49:57 is 115 s
	// later — well inside OUR_DOWN_TTL, so the TTL is not what lost it.
	self._our_downs = {};

	// modems whose sessions are being stopped before their backend goes
	// (stop_modem): name -> { start: the restart apply_config asked for }
	self._retiring = {};

	// modems that left QMAP and still owe the reset that clears it (rename_l3,
	// start_modem): name -> true until an init has taken the reset
	self._left_qmap = {};

	// THE INTERFACES WE GAVE UP ON, and reconnect when the modem registers
	// again (reconnect_on_register: a reconnect-hold give-up, a SIM block).
	// Also KEPT IN A FILE (tmpfs — a reboot re-arms netifd's autostart
	// anyway): the mark lived on the context entry only, so a daemon restart
	// inside such an outage — a package upgrade — lost it, and the interface
	// wwand had downed itself (autostart cleared) was read as an operator
	// ifdown and never came back (HW-seen on 245, 2026-09-27). Keyed by
	// interface for the reason _our_downs is.
	let giveups_file = deps.giveups_file ?? '/tmp/wwand/state/giveups.json';

	self._giveups = {};

	{
		let raw = deps.datapath_fx?.read ? deps.datapath_fx.read(giveups_file) : null;

		// written by us, but json() throws uncatchably on a torn file: take
		// the names out by pattern, as recovery.uc does
		for (let m in match(raw ?? '', /"[A-Za-z0-9_.-]+"/g) ?? [])
			self._giveups[substr(m[0], 1, length(m[0]) - 2)] = true;
	}

	// THE STATE FILES ARE REPLACED WHOLE, never rewritten in place: a later
	// start trusts what it reads there (admin_record_complete below), and an
	// in-place write truncates first — killed in between, or on a full
	// tmpfs, it left an empty record behind. write_atomic writes beside the
	// file and renames over it (netlink.uc default_fx); a writer without it
	// (a test double) falls back to write(). false when nothing was written.
	let write_state = (path, data) => {
		let fx = deps.datapath_fx;
		let ok = fx?.write_atomic ? fx.write_atomic(path, data)
		       : fx?.write ? fx.write(path, data) : null;

		if (ok === false)
			log('warn', sprintf('cannot write %s: %s', path, fx?.last_error ?? 'unknown error'));

		return !!ok;
	};

	let persist_giveups = () => write_state(giveups_file, sprintf('%J', keys(self._giveups)));

	let set_giveup = (entry, on) => {
		entry.reconnect_on_register = on;

		let iface = entry?.cfg?.interface;

		if (!iface || !!self._giveups[iface] == on)
			return;

		if (on)
			self._giveups[iface] = true;
		else
			delete self._giveups[iface];

		persist_giveups();
	};

	mark_our_down = (entry) => {
		let iface = entry?.cfg?.interface;

		if (iface)
			self._our_downs[iface] = time();
	};

	let clear_our_down = (entry) => {
		let iface = entry?.cfg?.interface;

		if (iface)
			delete self._our_downs[iface];
	};

	let our_down = (entry) => {
		let iface = entry?.cfg?.interface;
		let at = iface ? self._our_downs[iface] : null;

		if (at == null)
			return false;

		// prune on read: a marker past its TTL is not evidence, and leaving it
		// there would make it look like one to the next reader too
		if ((time() - at) >= OUR_DOWN_TTL) {
			delete self._our_downs[iface];

			return false;
		}

		return true;
	};

	// WHO CLEARED AUTOSTART. netifd has two ways to do it — an `ifdown`
	// (interface_set_down) and a handler's block_restart
	// (proto_ext_block_restart) — and its status tells neither apart
	// (interface.c:1367-1377, proto-ext.c:547-550, netifd 2026.07.08). Our
	// own downs carry the _our_downs marker, but that lives in this process:
	// a daemon restart in between (a package upgrade, a deploy) lost it, and
	// an interface the SHIM had blocked — sim_blocked while an eSIM profile
	// switch left the modem cardless for a moment — or that WE had reset was
	// read as an operator ifdown and stayed down (HW-seen on 245, 2026-09-27:
	// autostart false, errors [RADIO_HELD], "administratively down" at the
	// first registration after a restart).
	//
	// So the operator's down is recorded where it happens, not guessed at:
	// every ifdown of a wwand interface runs the shim's teardown, and
	// context_down's last branch is the operator's — or, with no daemon to
	// ask, the shim writes the record itself. Kept in a file for the reason
	// the give-ups are. THE RECORD IS THE ONLY EVIDENCE: a cleared autostart
	// without one is not the operator's. Reading it as one the moment no
	// `wwand` error explained it still parked interfaces wwand had downed
	// itself — the marker gone with the daemon that set it — until someone
	// ran ifup (HW-seen on the NR7101, 242, 2026-09-27: both interfaces of
	// the modem "administratively down" after a `wwand restart` whose old
	// daemon had crashed on the way out, no error on either, no ifdown by
	// anyone).
	//
	// An ifdown of an interface that was already down runs no teardown and
	// is not recorded: that one is brought up again at the next
	// registration. The price of trusting only the record, and the smaller
	// one — the other way wwand kept a link down that nobody had asked it to.
	//
	// ONLY A RECORD THAT CAN EXIST IS TRUSTED. The file is written by every
	// start, so its absence means this is the first start since boot — or
	// the first after an upgrade from a version that recorded nothing
	// (v1.6.8 and older), whose operator ifdowns have no record to show. For
	// that start the former guess stands: a cleared autostart with no
	// `wwand` error is the operator's (the Cudy LT300 reproduction of
	// 2026-08-23 — ifdown, then a restart, and the link came back by itself).
	// After a boot netifd has re-armed autostart anyway.
	//
	// WHAT THE GUESS DECIDES IS WRITTEN DOWN (operator_down), because the
	// file this start writes is trusted by the next one: an operator ifdown
	// found only by the guess would otherwise be undone by the second start
	// after an upgrade. And the untrusted start asks netifd about every
	// interface once, at its first apply_config (seed_admin_record), and
	// writes the file in its trusted form only when all have answered — a
	// guess waiting for a registration that never came before the next
	// restart would be lost the same way.
	//
	// A RECORD IS TRUSTED ONLY WHOLE: the daemon's own write, a JSON array
	// at its head (the shim appends bare names after it). An empty file, a
	// torn one, or one holding the shim's appends alone is read for its
	// names but not trusted. Trusted, its "nothing recorded" would bring
	// back every operator ifdown whose record went with the rest of the
	// file; untrusted, the worst it costs is the first-start guess once more.
	let admin_downs_file = deps.admin_downs_file ?? '/tmp/wwand/state/admin_downs.json';

	self._admin_downs = {};

	let admin_record_complete = (raw) =>
		type(raw) == 'string' && match(raw, /^[ \t\n]*\[[^\]]*\]/) != null;

	// The file's names into the in-memory record, ADDED and never replacing
	// it: the shim appends a name when its teardown cannot reach the daemon
	// (files/wwand-proto.sh proto_wwand_teardown), a daemon that is running
	// but slow or stopping included — and a daemon writing only its own set
	// over that dropped the operator's ifdown. Taken by pattern: json()
	// throws uncatchably on a torn file, and the shim's lines are no JSON.
	// Returns the raw file (null: none).
	let merge_admin_record = () => {
		let raw = deps.datapath_fx?.read ? deps.datapath_fx.read(admin_downs_file) : null;

		for (let m in match(raw ?? '', /"[A-Za-z0-9_.-]+"/g) ?? [])
			self._admin_downs[substr(m[0], 1, length(m[0]) - 2)] = true;

		return raw;
	};

	self._admin_record_trusted = admin_record_complete(merge_admin_record());

	// set while an untrusted start has not heard back from netifd about
	// every interface (seed_admin_record): the file is written without its
	// head until then, so a restart meanwhile is untrusted again
	self._admin_seed_pending = !self._admin_record_trusted;

	let persist_admin_downs = () => write_state(admin_downs_file, self._admin_seed_pending
		? join('', map(keys(self._admin_downs), (n) => sprintf('"%s"\n', n)))
		: sprintf('%J', keys(self._admin_downs)));

	// THE READ-MERGE-WRITE HOLDS THE SHIM'S LOCK. Re-reading before the write
	// is not enough on its own: a name the shim appends after the read and
	// before the rename goes to the file the rename replaces, and is lost.
	// The shim appends under the same flock (files/wwand-proto.sh
	// proto_wwand_teardown, `admin_downs.lock` beside the record); without
	// a lock (an fx that has none) this is the unlocked read-merge-write.
	let admin_lock_file = replace(admin_downs_file, /\.json$/, '') + '.lock';

	let admin_locked = (fn) => {
		let unlock = deps.datapath_fx?.lock ? deps.datapath_fx.lock(admin_lock_file) : null;

		try {
			merge_admin_record();
			fn();
		}
		catch (e) {
			log('warn', sprintf('admin_downs update failed: %s', e));
		}

		unlock?.();
	};

	// an interface named by a ubus caller, for the records keyed by interface
	// when there is no context entry for it; null for anything the state
	// files' name pattern would not read back
	let iface_ref = (ref) =>
		(type(ref) == 'string' && match(ref, /^[A-Za-z0-9_.-]{1,64}$/)) ? { cfg: { interface: ref } } : null;

	let set_admin_down = (entry, on) => {
		let iface = entry?.cfg?.interface;

		if (!iface)
			return;

		// re-read before the write (admin_locked): names the shim appended
		// since the last one must survive it
		admin_locked(() => {
			if (!!self._admin_downs[iface] == on)
				return;

			if (on)
				self._admin_downs[iface] = true;
			else
				delete self._admin_downs[iface];

			persist_admin_downs();
		});
	};

	// true when netifd's cleared autostart is the operator's and must be
	// left alone; false when it is ours or the shim's, and the interface is
	// to be brought back. `st` is a network.interface status reply. Every
	// caller leaves the interface down on true, so a true that only the
	// first-start guess gave is recorded here — the next start trusts the
	// record and has no guess left to make.
	// NETIFD CLAIMS THE DEVICE THROUGH A PARENT THAT IS GONE. A name that was a
	// mux child and is now the renamed parent itself (a datapath that went
	// from QMAP to raw-IP, a config that dropped its mux) keeps netifd's old
	// parent record, and every claim then fails: the interface sits down with
	// DEVICE_CLAIM_FAILED in its errors while the session behind it is fine
	// (LTE3301 apntest box, 2026-10-03; GL-X3000/RM520N, 2026-09-20). Only a
	// netifd restart or the device detour (deps.uc netifd_device_detour)
	// clears the record. The detour is taken on that evidence and nothing
	// else, at most once per DETOUR_MIN_S per interface — a claim that still
	// fails after it has another cause, and repeating it would only reload
	// netifd in a loop.
	const DETOUR_MIN_S = 300;

	let claim_failed = (st) =>
		length(filter(st?.errors ?? [], (e) => e?.code == 'DEVICE_CLAIM_FAILED')) > 0;

	// true when the detour was started (`then` runs once it is through)
	let heal_device_claim = (entry, then) => {
		let iface = entry?.cfg?.interface;

		if (!deps.netifd_device_detour || !iface)
			return false;

		let now = time();

		if (entry._detour_at != null && (now - entry._detour_at) < DETOUR_MIN_S)
			return false;

		entry._detour_at = now;
		log('notice', sprintf('interface %s: netifd cannot claim its device (DEVICE_CLAIM_FAILED — it still holds the parent of an earlier mux child) — re-creating netifd\'s record of it',
			iface));

		deps.netifd_device_detour(iface, (err) => {
			if (err) {
				log('warn', sprintf('interface %s: the netifd device detour failed (%J) — `/etc/init.d/network restart` clears the record',
					iface, err));
				return;
			}

			log('info', sprintf('interface %s: netifd re-created its device record', iface));

			if (then)
				then();
		});

		return true;
	};

	let operator_down = (entry, st) => {
		if (st?.autostart !== false || our_down(entry))
			return false;

		let iface = entry?.cfg?.interface;

		// the shim's append while this daemon runs (its teardown could not
		// reach us) is read now, not only at the next write
		if (!self._admin_downs[iface])
			merge_admin_record();

		if (self._admin_downs[iface])
			return true;

		if (self._admin_record_trusted)
			return false;

		// the first start since boot or since an upgrade: the former guess
		for (let e in st?.errors ?? [])
			if (e?.subsystem == 'wwand')
				return false;

		set_admin_down(entry, true);
		return true;
	};

	// The untrusted start's one look at every configured interface (see
	// WHAT THE GUESS DECIDES above): operator_down records what the guess
	// reads as the operator's, and the file gets its trusted head once every
	// interface has answered. Without a status source there is nothing to
	// guess from and the file is written at once.
	let seed_admin_record = (ifaces) => {
		if (!self._admin_seed_pending || self._admin_seeding)
			return;

		self._admin_seeding = true;

		let left = length(ifaces);
		let finish = () => admin_locked(() => {
			self._admin_seed_pending = false;
			persist_admin_downs();
		});

		if (!left || !deps.iface_status)
			return finish();

		for (let i in ifaces)
			deps.iface_status(i, (st) => {
				operator_down({ cfg: { interface: i } }, st);

				if (--left == 0)
					finish();
			});
	};

	// A CLEARED AUTOSTART WITHOUT A RECORD MAY BE ONE ON ITS WAY. netifd
	// clears autostart and starts the teardown in one step
	// (interface_set_down, interface.c:1373-1375, netifd 2026.07.08); the
	// shim's context_down — which writes the record — reaches us only once
	// its teardown script runs. A status probe answered in that gap reads an
	// ifdown as nobody's, and the kick that follows undoes it (the ifup
	// re-arms autostart during the teardown, interface.c:1340-1344, and the
	// setup after it clears the record). So before undoing such a down, ask
	// once more after a pause; only a second status that is still not the
	// operator's is ours to undo. alive(): the context is still the one the
	// caller probed for.
	//
	// FIVE SECONDS, because that gap is not always short: an ifdown that
	// lands while the shim's setup script still runs (it sleeps between
	// retries — RADIO_HELD, WAITING_MODEM) has netifd SIGTERM the script and
	// wait up to 1 s before the SIGKILL (proto-ext.c:780-788), then abort the
	// setup (proto-ext.c:162-170), and only then does the teardown script
	// start and reach context_down (netifd 2026.07.08~6088f7b3). A pause
	// shorter than that answers before the record exists and undoes the
	// ifdown after all.
	const UNRECORDED_CONFIRM_MS = 5000;

	let needs_confirm = (entry, st) =>
		st?.autostart === false && !our_down(entry) && !self._admin_downs[entry?.cfg?.interface];

	// ONE SECOND LOOK PER ENTRY AT A TIME, and cancellable. The three sites
	// that ask can all fire for one down (a registration, a settings event,
	// a connect-first up — settings events come in bursts), and each look
	// ends in a kick: one per event was as many kicks for one down. A look
	// already pending answers for all of them. Cancelled wherever the daemon
	// stops acting on the entry (stop_context, stop_local, shutdown): a
	// timer outliving it probes and kicks for a context a reload replaced,
	// or from a daemon that is on its way out.
	let cancel_confirm = (entry) => {
		if (!entry)
			return;

		entry._confirm_timer?.cancel();
		entry._confirm_timer = null;
		entry._confirm = null;
	};

	let confirm_then = (entry, alive, go) => {
		if (entry._confirm)
			return;

		let token = {};
		let ms = self.timing?.unrecorded_confirm_ms ?? UNRECORDED_CONFIRM_MS;

		entry._confirm = token;

		let again = () => {
			entry._confirm_timer = null;

			deps.iface_status(entry.cfg.interface, (st2) => {
				// cancelled while the probe was out
				if (entry._confirm !== token)
					return;

				entry._confirm = null;

				if (!alive())
					return;

				if (operator_down(entry, st2)) {
					if (entry.wanted) {
						entry.wanted = false;
						log('notice', sprintf('interface %s is administratively down (ifdown), leaving it alone',
							entry.cfg.interface));
					}
					return;
				}

				go(st2);
			});
		};

		if (ms > 0)
			entry._confirm_timer = uloop.timer(ms, again);
		else
			again();
	};
	// The SIM inventory (siminventory.uc): every card seen, by ICCID, and
	// where it is. Refreshed from the modems' state on every sim_inventory
	// call and every tick — in memory, no I/O — so it follows identity re-reads, slot
	// switches, eSIM changes and remote cards without hooks in each of them.
	let inventory = siminventory.create({});

	let inventory_refresh = () => {
		let keep = [];

		for (let name, entry in self.modems) {
			// a modem mid-restart has no reading: its cards stay as they were
			let srcs = siminventory.from_modem(name, entry?.modem,
				entry?.modem ? (self.plugins_card_source?.(name) ?? null) : null);

			for (let k, l in srcs) {
				push(keep, k);
				inventory.observe(k, entry?.modem ? l : null);
			}
		}

		// a modem that is no longer configured takes its cards along
		inventory.forget_except('modem:', keep);
	};

	// One card's label, by the same ICCID/IMSI matching the modem uses for its
	// active_sim (modem_common.match_sim_override) — so a section matched by
	// IMSI is named too, and with `modem` given, that modem's own list decides
	// (two modem-bound sections may name one card differently). A card with no
	// modem (a reader) is looked up in every list: config.uc hands an unbound
	// section to all of them.
	self.sim_name_of = (iccid, imsi, modem) => {
		if (modem != null)
			return modem_common.match_sim_override(self.modems?.[modem]?.cfg?.sims, iccid, imsi)?.name ?? null;

		for (let mn, e in self.modems) {
			let s = modem_common.match_sim_override(e?.cfg?.sims, iccid, imsi);

			if (s?.name)
				return s.name;
		}

		return null;
	};

	self.sim_inventory = function() {
		// an exception in a ubus handler ends the loop, as in the tick
		try { inventory_refresh(); }
		catch (e) { log('warn', sprintf('SIM inventory refresh failed (%s)', e)); }

		let cards = map(inventory.list(), (c) =>
			({ ...c, name: self.sim_name_of(c.iccid, c.imsi, c.modem) }));

		// `now` on the same clock as last_seen: a viewer's own clock may differ
		return { cards: cards, now: time() };
	};

	// modem reached service: write back l3 device names, run autosetup APN
	// fill, (re)establish this modem's IDLE interface-bound contexts.
	let modem_registered = (modem, data) => {
		// the slot list once per modem object, so the inventory knows the
		// cards in the slots that are not active before anyone opens the
		// status page (which reads it on its own after that)
		if (!modem._inventory_slots && self.modem_sim_slots) {
			modem._inventory_slots = true;
			self.modem_sim_slots(modem.id, () => null);
		}

		// OPEN THE NMEA PORT. wwand found it during enumeration (`gps_tty`)
		// and `option gnss` started the receiver; reading it is the last of
		// the three and the only one that used to be somebody else's job.
		// No port: the same NMEA over QMI LOC (wwand-gps, natively or over the
		// MBIM passthrough). The port wins where there is one — it needs no
		// QMI session, and LOC is the path that is broken on Quectel.
		if (modem.config?.gnss ?? false) {
			let gopts = { adjust_time: modem.config?.gnss_set_time ?? false };

			if (modem.gps_tty) {
				if (deps.gps_start)
					deps.gps_start(modem.id, modem.gps_tty, gopts);
			}
			else if (deps.gps_start_loc)
				deps.gps_start_loc(modem.id, modem, gopts);
		}

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
				set_giveup(entry, false);
				entry.wanted = true;
				log('notice', sprintf('interface %s: service returned, reconnecting after earlier give-up',
					entry.cfg.interface));

				// This marker is set from our OWN bookkeeping, not from netifd:
				// `reconnect_on_register` is only ever set by context_down for a
				// hold-expiry give-up, so reaching here PROVES the cleared
				// autostart below is the down we issued ourselves. Refreshing it
				// here is what lets the marker be time-bounded at all — a
				// blackhole can outlast any sane TTL, and without this the
				// give-up we just decided to undo would be read one line later as
				// an operator ifdown and left down forever.
				mark_our_down(entry);
			}

			// capture per iteration: the netifd status probe is async, so the
			// adopt-vs-kick decision runs later in the callback.
			let cname = name, centry = entry, cctx = entry.ctx;

			// declared first: the second look (confirm_then) calls it again
			let decide;

			decide = (st, confirmed) => {
				// Retired while the probe was out: a reload replaced or removed
				// the context (stop_context deletes the entry, build_context
				// makes a new one). Acting on the capture would kick an
				// interface the reload took away, or start the replacement on
				// a status read for its predecessor.
				if (self.contexts[cname] !== centry || centry.ctx !== cctx)
					return;

				// The interface is back up, or netifd has re-armed autostart:
				// whatever down we issued has been answered, so the marker has
				// done its job and must not outlive the state it describes. This
				// is the ONLY place it is cleared — on evidence from netifd, not
				// on our intent to kick (see the comment at mark_our_down).
				if (st && (st.up || st.autostart === true)) {
					clear_our_down(centry);
				}

				if (st?.up) {
					log('info', sprintf('adopting live interface %s after modem ready', centry.cfg.interface));
					retry_activate(cname);
				}
				else if (operator_down(centry, st)) {
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
				else if (!(centry.cfg.auto ?? true) && !our_down(centry) && !centry.reconnect_on_register) {
					// 'auto 0' and not up: dormant until an explicit ifup — and
					// not wanted meanwhile. A SIM change's down-and-reconnect
					// (modem_sim_refresh) and the low-power decision read
					// `wanted`, and neither may dial or hold the radio for an
					// interface nobody brought up.
					//
					// Not when the down is wwand's own (a give-up, a SIM block —
					// the re-arm above marks it): `auto 0` says nobody brings
					// the interface up at boot, and this one the operator HAD
					// brought up. Taken for dormant, wwand's own give-up would
					// keep it down until the next ifup.
					centry.wanted = false;
					log('debug', sprintf('interface %s is down and auto=0, not kicking', centry.cfg.interface));
				}
				else if (!confirmed && deps.iface_status && needs_confirm(centry, st)) {
					confirm_then(centry, () => self.contexts[cname] === centry && centry.ctx === cctx,
						(st2) => decide(st2, true));
				}
				else if (st?.pending && centry.ctx && centry.ctx.state != 'IDLE') {
					// netifd's setup is waiting on an activation that is already
					// running — the queued up that READY just released. Its
					// answer completes that setup; a reset here (down, kick)
					// only interrupted it and made netifd set up again, on every
					// plain bring-up after a modem reset (HW-seen on deborah-3,
					// MC7710, 2026-10-04). The loop above only takes IDLE
					// contexts, so a state other than IDLE here means the
					// activation started (or even finished) during this status
					// probe: nothing is orphaned, there is nothing to reset.
					log('debug', sprintf('interface %s: setup pending on a running activation (%s), not kicking',
						centry.cfg.interface, centry.ctx.state));
				}
				else if (claim_failed(st) && heal_device_claim(centry,
				         () => deps.kick_interface?.(centry.cfg.interface))) {
					// a kick would only fail the same claim again; the detour
					// kicks once netifd has a fresh device record
				}
				else if (deps.kick_interface) {
					// our own down is being undone here; the kick re-arms
					// netifd's autostart, so the marker has served its purpose
					if (our_down(centry))
						log('info', sprintf('interface %s was taken down by wwand, bringing it back up',
							centry.cfg.interface));

					// IDLE context while netifd holds the interface 'pending' = an
					// ORPHANED setup (e.g. a wwand restart mid-setup). 'up' no-ops on a
					// pending interface, so 'down' first, then the kick re-runs setup.
					// (A busy context never gets here: the branch above.)
					if (st?.pending && deps.down_interface) {
						log('info', sprintf('interface %s stuck pending, resetting before setup', centry.cfg.interface));
						// Two markers, because two different readers ask two different
						// questions about this down.
						//
						// `_reset_pending` is for context_down: keep `wanted` and
						// restart the aborted activation once the teardown settles.
						//
						// `_our_down` is for the status poll above, and it was
						// missing. netifd's `down` clears autostart whoever issued
						// it, so the next poll saw autostart=false with no marker it
						// recognised, read OUR OWN reset as an operator ifdown, and
						// cleared `wanted` — the interface then stayed down until
						// somebody ran ifup again. Reported from the field on an
						// IPQ807x board (2026-09-03): `ifup wan` while the modem was
						// still initialising, and it never came up.
						centry._reset_pending = true;
						mark_our_down(centry);
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
			};

			if (deps.iface_status)
				deps.iface_status(centry.cfg.interface, decide);
			else
				decide(null);
		}

	};

	// CLOSE THE PORT when the modem that owns it goes. Otherwise the reader
	// holds an fd on a device that is gone — or on whatever the kernel hands
	// that name to next — and no other modem can be given that tty, because
	// one port is only ever read once.
	let release_gps = (name) => {
		if (deps.gps_stop)
			deps.gps_stop(name);
	};

	// modem 'removed' (transport-level device gone): detach and enter the
	// boot-style waiting state. Presence is re-checked by the periodic tick —
	// NOT only by hotplug — because the 'add' may never fire.
	let modem_removed = (modem) => {
		let entry = self.modems[modem.id];

		if (!entry || entry.modem != modem)
			return;

		detach_modem(modem.id, entry);
		release_gps(modem.id);
		entry.control_note = 'waiting for modem (device vanished)';
		entry.waiting_since = time();
		entry._waiting_logged = time();
		// THIS is what separates a vanish from a cold boot, and the escalation in
		// the tick keys on it. Deliberately not persisted: after a daemon restart
		// we no longer know the modem was ever running, and a boot-time wait must
		// never reboot the router.
		entry.vanished = true;
		entry._vanish_rung = 0;
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
				set_giveup(entry, true);

				// ...and remember that WE took the interface down. netifd's ubus
				// `down` clears autostart, which the ready path otherwise reads
				// as an operator ifdown.
				mark_our_down(entry);

				if (deps.down_interface)
					deps.down_interface(entry.cfg.interface);
			}
		}
	};

	// Everything an internal rebuild MUST carry across. start_modem builds a
	// fresh entry on every hotplug re-add and on every 30 s waiting-modem
	// retry, so anything recorded about the CURRENT outage is erased unless it
	// is copied — and it is recorded precisely because the outage outlives one
	// interval.
	//
	// A function, not four lines repeated at each `self.modems[name] = {...}`:
	// there are THREE such sites (owned-by-another-stack, unknown-protocol, and
	// the normal one) and only the last one carried them. The two early returns
	// are reachable exactly when it hurts most — a device that re-appears after
	// the ladder pulsed reset spends a moment with its node present and no
	// driver bound yet, which is the `unknown` path, and that rebuild reset the
	// outage clock so the reboot rung could never be reached (found by audit,
	// 2026-09-07; the reboot rung is the one that recovered the NR7101).
	let carry_over = (name) => {
		let prev = self.modems[name];

		return {
			_sig: prev?._sig,
			_had_modem: prev?._had_modem,
			vanished: prev?.vanished,
			_vanish_rung: prev?._vanish_rung,
			waiting_since: prev?.waiting_since,
			// what the hardware told us last time (detach_modem). A rebuild
			// replaces the whole entry, so anything not listed here is
			// forgotten — and forgetting this one costs an NCM modem its
			// vendor recipe when it refuses to identify itself (wwand#32).
			_ident: prev?._ident,
			// the options an installed plugin reads (plugins.uc): stamped by
			// reload only, so a rebuild between reloads — every hotplug re-add
			// after a modem reset — must keep them, or the plugin sees the
			// modem as unconfigured (HW-found on 245, 2026-09-27: a remote SIM
			// session ended after the modem reset that allowed SIM Access)
			ext: prev?.ext,
			// when the serial-only reading started, so the settle window in
			// start_modem is a window and not a fresh countdown per rebuild
			_ppp_since: prev?._ppp_since,
		};
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

	// What the card's ISD-R says about itself (sim.card_euicc_info): SGP.32
	// or not, which IPA runs it. Kept on the modem ENTRY, read per modem
	// object — the eUICC is the same chip whichever profile it runs, and which
	// IPA is active is settled when the card starts. Reported in status()
	// (`euicc`) and used by modem_sim_refresh.
	//
	// A caller arriving while a read is in flight WAITS for it: answering it
	// at once from the not-yet-filled entry let a profile change that landed
	// mid-read go without its recovery hold. And an empty answer is not
	// final — a plain SIM gives one, but so does a transport being rebuilt —
	// so it is asked again, a minute apart, up to three times per modem
	// object; a plain SIM then stops being asked.
	let EUICC_TRIES = 3, EUICC_RETRY_S = 60;

	// What a finished read does. Reached through euicc_answer (module level,
	// below the imports): see the note there.
	let euicc_read = (entry, m, st, info) => {
		st.busy = false;

		if (entry.modem !== m || entry._euicc_st !== st)
			return;

		entry.euicc = info;
		st.done = (info != null);
		st.next_at = time() + EUICC_RETRY_S;

		if (info?.sgp32)
			log('notice', sprintf('modem %s: SGP.32 IoT eUICC (SGP.22 %s), %s', m.id, info.svn ?? '?',
				(info.ipa == 'ipae') ? 'its own IPA (IPAe) is in charge — ES10 from the router is refused by design'
				: (info.ipa == 'ipad') ? 'served by the device IPA (IPAd)' : 'IPA mode unknown'));

		let waiters = st.waiters;

		st.waiters = [];

		for (let w in waiters)
			w();
	};

	let probe_euicc = (entry, m, done) => {
		let st = (entry._euicc_for === m) ? entry._euicc_st : null;

		if (st?.done || (st && !st.busy && st.tries >= EUICC_TRIES))
			return done?.();

		if (st?.busy) {
			if (done)
				push(st.waiters, done);
			return;
		}

		if (st && time() < st.next_at && !done)
			return;

		if (!st) {
			st = { tries: 0, busy: false, done: false, next_at: 0, waiters: [] };
			entry._euicc_for = m;
			entry._euicc_st = st;
			entry.euicc = null;
		}

		st.busy = true;
		st.tries++;

		if (done)
			push(st.waiters, done);

		// two statements: a called `(a ?? b.c)(…)` misplaces the stack
		// (docs/gotchas.md) — this very call once nulled `st` (see euicc_answer)
		let read = deps.card_euicc_info ?? simmod.card_euicc_info;

		read(m, euicc_answer(euicc_read, entry, m, st));
	};

	// THE SUBSCRIPTION CHANGED UNDER A RUNNING CONNECTION. An eSIM profile
	// switch or a card swap leaves any established session on this modem
	// belonging to the PREVIOUS subscription — one the new card has no claim
	// to. (Not every wanted context holds one; asking each to drop what it has
	// is the point, see below.)
	// wwand knew it had happened and did nothing with the knowledge:
	// `sim_refresh` carries the new identity and nothing in the daemon
	// listened, so the data path stayed up carrying nothing until somebody
	// pressed Reconnect. Reported on a Fibocom after an eSIM enable (patrakov,
	// OpenWrt forum, 2026-09-22); the same shape is the tail of
	// ddimension/wwand#35.
	//
	// EVERY WANTED CONTEXT, WHATEVER STATE IT LOOKS LIKE. Two attempts at a
	// cleverer predicate were wrong, and both in the same way — the public
	// `state` does not answer "does this hold a bearer":
	//
	//   - CONNECTED is sufficient but not necessary. An MBIM attempt aborted
	//     while the modem was still answering sets `activated` from the late
	//     reply (context_mbim.uc:344-348), so an IDLE context can be holding a
	//     session that only down() will tear down.
	//   - ACTIVATING is not "no session yet" either: MBIM sets `activated`
	//     before it queries the IP configuration (context_mbim.uc:359-360), NCM
	//     before it reads its own (context_ncm.uc:742), and QMI can have
	//     activated families while settings are still being fetched.
	//
	// Each backend's down() already knows exactly what it holds. Asking it is
	// right; second-guessing it from outside leaks the very session this exists
	// to drop, because the public `state` does not answer "does this hold a
	// bearer".
	//
	// AND THE RECONNECT IS STARTED HERE, not inferred from the `down` event.
	// context_ncm.down() returns WITHOUT emitting it when the activation has
	// not set `activated` yet (context_ncm.uc:879-882) — so a mid-dial NCM
	// context would have gone IDLE with `wanted` still true and nothing
	// scheduled, wedged by the very handler meant to restart it. enter_
	// reconnecting returns on an armed hold timer, and every emitting backend
	// fires its event and this callback as consecutive synchronous statements
	// — no uloop timer can run between them — so the second call is a no-op
	// for them. (It is not idempotent in general: a retry scheduled with no
	// hold behind it would start a second chain. That is why schedule() now
	// cancels before it replaces — reconnect.uc.)
	//
	// What that path then does: holds the interface up, retries with a backoff
	// from the moment it starts, and bounds the wait at hold_max. Past that
	// bound it hands over to the registration path rather than retrying
	// forever — which recovers a modem that took a long time to come back, and
	// is NOT a guarantee that every outcome ends connected: an activation that
	// keeps failing after the modem has already registered can run the hold out
	// with no further `registered` to trigger on. Pre-existing shape of the
	// hold path, stated because this routes a new case into it. Dialling from here would be a second, unbounded copy of
	// a path that exists and is tested — and it is why the old comment in
	// esim_bridge (apply_sim_reset: "the data session comes back via the normal
	// transient-loss path") was right about the mechanism and wrong about
	// whether anything started it.
	//
	// COMPARED HERE rather than trusted from the event. modem_mbim filters its
	// own emit on a change (modem_mbim.uc:971-980) while the shared reapply
	// tail emits on every re-read (modem_common.uc:643-649); one comparison, in
	// the place that acts on it, cannot disagree with itself.
	let modem_sim_refresh = (modem, data) => {
		let entry = self.modems[modem.id];

		if (!entry)
			return;

		let now = sprintf('%s/%s', data?.iccid ?? '', data?.imsi ?? '');
		let prev = entry._sim_identity;
		let pp = split(prev ?? '/', '/');

		// A read that got the ICCID but not (yet) the IMSI says nothing new
		// about the subscription: the identity on record stays, so the IMSI
		// read later is compared with the one BEFORE — a card that changed
		// its IMSI behind the same ICCID (an IMSI-switching applet) is still
		// seen as a change (found by audit, 2026-09-27)
		if (prev != null && pp[0] == (data?.iccid ?? '') && (data?.imsi ?? '') == '')
			return;

		entry._sim_identity = now;

		// nothing to compare against yet — the first read of this modem, or a
		// rebuilt entry after a reload — and a re-read of the same card is not
		// a change. Both must stay silent: dropping a healthy session because
		// the identity was merely READ AGAIN is worse than the bug.
		if (prev == null || prev == now)
			return;

		// ...nor is the same card whose IMSI only now became readable: a card
		// change clears the IMSI and a slow card (a remote SIM) is read again
		// until it has one (simops card_changed) — "ICCID/" then "ICCID/IMSI"
		// dropped the session that had just come up on it
		if (pp[0] == (data?.iccid ?? '') && (pp[1] ?? '') == '')
			return;

		// A card whose OWN IPA (IPAe, SGP.32) switched the profile is now
		// watching the new one and rolls back by itself if it brings no
		// connectivity (HW-seen on an IoT eUICC behind an EG25-G, 2026-10-01:
		// back on the previous profile 64 min after a switch to one that got
		// no service): keep the recovery ladder from resetting it meanwhile
		// (recovery.uc hold_for_card). Only then — a plain SIM or an SGP.22
		// card has no rollback to protect, and with our own IPA (ipad) the
		// rollback is ours, so holding recovery back would only delay it.
		// Asked once per modem entry (probe_euicc): which IPA is
		// active is settled when the card starts, not per profile. 35 min by
		// default: a card's rollback timer plus the attempts around it.
		let m = entry.modem;
		let hold = () => m?.recovery?.hold_for_card?.(+(entry.cfg?.card_hold ?? 2100),
			sprintf('the card\'s own IPA changed the subscription (%s -> %s)', prev, now));

		if (entry.euicc?.ipa == 'ipae')
			hold();
		else if (m)
			probe_euicc(entry, m, () => {
				if (entry.euicc?.ipa == 'ipae')
					hold();
			});

		for (let name, centry in self.contexts) {
			// `wanted` is the one thing worth filtering on: a context nobody
			// asked for has nothing to re-establish, and enter_reconnecting
			// would refuse it anyway.
			if (centry.cfg?.modem != modem.id || !centry.ctx || !centry.wanted)
				continue;

			log('notice', sprintf('interface %s: the SIM changed under it — dropping the session so it re-dials on the new subscription',
				name));
			centry.ctx.down(() => enter_reconnecting(name));
		}
	};

	// A live edit of the override that matches the card in use: re-program
	// the attach profile (reapply_sim, which cycles the radio only when the
	// profile really changed), then re-dial the sessions still up, which were
	// dialled with the old values. Only on a modem past its init chain: one
	// that is still coming up reads the new list on its own.
	let apply_sim_change = (mn, m) => {
		log('notice', sprintf('modem %s: the SIM override of the card in use changed — applying it', mn));

		if (index([ 'ABSENT', 'INIT_TRANSPORT', 'INIT_SERVICES', 'INIT_DATAPATH' ], m.state) >= 0 ||
		    type(m.reapply_sim) != 'function')
			return;

		m.reapply_sim(() => {
			if (self.modems[mn]?.modem !== m)
				return;   // restarted or removed meanwhile

			for (let name, centry in self.contexts) {
				if (centry.cfg?.modem != mn || !centry.ctx || !centry.wanted ||
				    centry.ctx.state != 'CONNECTED')
					continue;

				log('notice', sprintf('interface %s: re-dialling with the changed SIM override', name));
				centry.ctx.down(() => enter_reconnecting(name));
			}
		});
	};

	let on_modem_event = (modem, event, data) => {
		// How often this modem object has gone ABSENT: a modem that really
		// reboots drops off the bus on the way (hwops.modem_reset asks this to
		// tell a reset that happened from one that was only acknowledged).
		if (event == 'state' && data?.state == 'ABSENT')
			modem._absent_count = (modem._absent_count ?? 0) + 1;

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
		case 'sessions_released':
			// a radio cycle stopped these sessions before it detached and held
			// our reconnect off meanwhile (modem_common with_sessions_released):
			// hand them to the reconnect now, which waits for READY
			for (let name, e in self.contexts)
				if (e?.wanted && index(data?.contexts ?? [], e.ctx) >= 0 &&
				    e.ctx.state == 'IDLE')
					enter_reconnecting(name);
			break;

		case 'registered': {
			// Registered while its card is lent to another modem: a modem
			// re-initialised meanwhile (a reset, a re-enumeration) comes up
			// online. Parked at once — one card, one registration — and held
			// as a plugin park, so the end of the lending wakes it (tick).
			let hold = self.plugins_radio_hold?.(modem.id);

			if (hold && modem.set_opmode) {
				log('warn', sprintf('modem %s: registered although %s — switching its radio off again', modem.id, hold));
				modem._plugin_held = true;
				modem.set_opmode('low_power', (e) => {
					if (e?.error == 'unsupported')
						note_unholdable(modem, modem.id, e.detail ?? 'unsupported');
					else if (e)
						log('warn', sprintf('modem %s: switching the radio off failed: %J', modem.id, e));
					else
						modem._hold_unsupported = null;
				});
				return;
			}

			// a modem with no radio switch at all registers regardless; its
			// interfaces are refused (context_up) and not adopted
			// (retry_activate) while the hold lasts
			if (hold)
				note_unholdable(modem, modem.id, 'its backend has no radio switch');

			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			return modem_registered(modem, data);
		}

		case 'sim_blocked':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			return modem_sim_blocked(modem);

		case 'deregistered':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			return;

		case 'sim_refresh':
			emit('wwand.modem', { modem: modem.id, event: event, ...(data ?? {}) });
			return modem_sim_refresh(modem, data);

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

			// ONE ATTEMPT, IN THE AUTOSETUP RUN ONLY. The table fills the APN of
			// the interface autosetup just created — whatever profile 1 held is
			// not consulted: the backends write the CONFIGURED APN into the
			// attach profile, an unset one as empty (context.uc
			// ensure_attach_profile), so a stale APN from the modem's previous
			// life is cleared either way (deborah-3, 2026-10-04). The marker is
			// cleared on the first card read with or without a match: after
			// that run the config alone decides, and a card that needs its own
			// APN (a Telekom hybrid card's nonbonding.hybrid, which the table's
			// consumer default breaks — Chateau, 2026-09-12) gets it configured.
			let vals = apndb.lookup(info.iccid, info.imsi);

			// a modem that cannot do IPv6 gets the carrier's IPv4 APN and says
			// so in the config, rather than a dual-stack entry it never dials
			if (vals && modem_quirks.for_model(info.model).ipv4_only)
				vals = { ...vals, apn: vals.apn_ipv4 ?? vals.apn, pdp_type: 'ipv4' };

			if (!deps.autosetup_fill)
				continue;

			if (!vals) {
				log('info', sprintf('autosetup: no APN-table match for %s (iccid %s, imsi %s) — the empty APN (network default) stays',
					name, info.iccid ?? '?', info.imsi ?? '?'));
				deps.autosetup_fill(entry.cfg.interface, null);   // the run is over: marker off
				continue;
			}

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

		// Ask netifd what it is holding, then decide. Two answers matter:
		//
		//  - it is NOT holding the interface at all (down, and not mid-setup):
		//    a renew is thrown away unread there — interface_renew() returns -1
		//    for IFS_DOWN/IFS_TEARDOWN before the proto handler sees it (netifd
		//    interface.c:1380-1386, 2026.07.08~6088f7b3) — so kick instead.
		//  - it is holding exactly what we pushed: skip, because re-pushing the
		//    same addresses only churns netifd and its address-dependent
		//    consumers (odhcpd RAs, firewall reloads, host routes).
		//
		// `force` (a real IP change / relink) skips the probe entirely, and any
		// doubt (no probe dep, probe fails) falls through to the renew — so the
		// skip can still only ever drop a genuine no-op.
		let renew_iface = (force) => {
			// Everything netifd is told in one update — addresses AND the routes
			// derived from them. The default route carries the gateway, and with
			// `sourcefilter` on (the default) it also carries the address prefix
			// as its source, so "the addresses are unchanged" is NOT on its own a
			// reason to skip the push.
			//
			// This mattered little while every reconnect also changed the
			// address; `option ip6ifaceid` makes the address STAY THE SAME across
			// reconnects by design, and the gateway still changes with each
			// session (observed on the RG650E: `…:1b9:8e02:68b7:f042` ->
			// `…:1c92:590d:8921:2d0e` between two sessions of the same bearer,
			// 2026-09-10). Comparing addresses alone would then skip the renew
			// and leave netifd with the previous session's nexthop and its
			// <gw>/128 host route — a default route pointing at an address that
			// is no longer there.
			// The WHOLE settings object, not a hand-picked subset: it is exactly
			// what context_settings hands the shim, so anything that can change
			// what netifd is told is in it — gateway, netmask/prefix, DNS, MTU.
			// Picking fields by hand would leave a DNS- or MTU-only refresh
			// looking identical here while netifd keeps the stale values, and
			// context_monitor_qmi already decides "did the settings change" the
			// same way (settings_sig, :226).
			let cur_sig = sprintf('%J', ctx.settings);

			let do_renew = () => {
				entry._applied_sig = cur_sig;

				if (deps.renew_interface && entry?.cfg?.interface)
					deps.renew_interface(entry.cfg.interface);
			};

			if (force || !deps.iface_status || !entry?.cfg?.interface)
				return do_renew();

			// SAMPLED NOW, not read in the callback. The `up` handler calls
			// renew_iface() and then clears `_kick_after_connect` on the very
			// next line — synchronously, long before this probe answers — so a
			// callback that reads the live flag always finds it false and kicks
			// on top of the kick that block is already arranging. The tests'
			// iface_status answers synchronously and cannot show this; the
			// shipped one is a deferred ubus call.
			let kick_pending = entry._kick_after_connect;

			// One probe in flight per context. Two settings events landing
			// together would otherwise both see the same down interface and
			// both kick, and clearing `_applied_sig` is not a latch — it is
			// cleared by the first callback, which the second has already
			// passed.
			//
			// The latch holds WHEN the probe went out, not just that it did.
			// A plain flag is cleared in the callback and nowhere else, so a
			// request that never answers — a wedged ubusd is the way that
			// happens — would silence every later renew for this context for
			// the life of the daemon. Nothing here can cancel that request, so
			// the latch expires instead.
			//
			// And the latch is the probe itself, not a mark that one exists:
			// once an expiry lets a second probe out, BOTH are live, and a
			// callback that cannot tell whether it is still the current one
			// would act on a superseded answer and clear the live probe's latch
			// on its way out — reintroducing exactly the double action the
			// latch is here to prevent, one step removed.
			if (entry._renew_probe && (time() - entry._renew_probe.at) < PROBE_STALE_S)
				return;

			let probe = { at: time() };

			entry._renew_probe = probe;

			// The connection this probe is asking about. A context can drop and
			// come back while the answer is in flight, and it comes back on the
			// same entry and the same ctx object (only a config reload builds a
			// new one) — so identity and state both still match, and a stale
			// answer would be acted on as if it described the live session.
			// That is not academic on a connect-first backend: the reconnect
			// arms `_kick_after_connect` and kicks by itself, and the old probe
			// carries a `kick_pending` sampled before any of it.
			let conn_seq = entry._conn_seq ?? 0;

			let first_addr = (arr) =>
				(type(arr) == 'array' && length(arr)) ? arr[0]?.address : null;
			let same = (a, b) => (a ?? '') == (b ?? '');

			// THE PREFIX, not the whole v6 address. This asks "does netifd still
			// hold what we pushed", and the host half is not part of that answer:
			// some firmware hands back different low 64 bits on every settings
			// read while prefix, gateway and DNS stay put (RG502Q — see
			// context_common.keep_stable_v6, which is why the MONITOR already
			// compares this way), and netifd may re-derive the identifier itself
			// from an interface token. Comparing the literal address made this
			// guard answer "changed" for an interface that had changed nothing,
			// which is the harmless direction — but it also means the guard was
			// never measuring what it claimed to.
			let v6_same = (a, b, plen) => {
				if ((a ?? '') == (b ?? ''))
					return true;

				if (a == null || b == null)
					return false;

				let pa = context_common.v6_prefix(a, plen);
				let pb = context_common.v6_prefix(b, plen);

				return (pa != null && pa == pb);
			};

			deps.iface_status(entry.cfg.interface, (st) => {
				// superseded: an expiry let a newer probe out, or a reconnect
				// dropped this one. Say nothing, and leave the live probe's
				// latch alone.
				if (entry._renew_probe !== probe)
					return;

				entry._renew_probe = null;

				// The probe is deferred, and a reload or an admin down can
				// retire this context while it is out: stop_context() downs the
				// context and deletes the entry, and build_context() replaces
				// it. Acting on what we captured would then kick an interface
				// that is being torn down, or push a retired context's
				// settings. Nothing below is worth doing for a context the
				// daemon has already moved on from.
				if (self.contexts[name] !== entry || entry.ctx !== ctx ||
				    ctx.state != 'CONNECTED' || (entry._conn_seq ?? 0) !== conn_seq)
					return;

				// NETIFD HAS THE INTERFACE DOWN, so there is nothing to renew
				// into: interface_renew() returns -1 without doing anything for
				// IFS_DOWN and IFS_TEARDOWN (netifd interface.c:1380-1386,
				// 2026.07.08~6088f7b3), and our renew is fire-and-forget, so the
				// failure is silent.
				//
				// A CONNECTED context behind a down interface is not a harmless
				// state to leave alone, and nothing else picks it up: the ready
				// path that kicks (see the `auto` branch above) needs a MODEM
				// transition, and a modem that was ready all along never makes
				// one. The way in is netifd's proto setup failing while the
				// context happened to be reconnecting — a netifd restart lands
				// there whenever it catches wwand mid-reconnect. (Measured on
				// the GL-X3000/RM520N, 2026-09-20: a netifd restart against a
				// CONNECTED context recovers by itself, because its setup calls
				// context_up and gets up=1 straight back. It is only the
				// unlucky window that sticks.)
				//
				// So kick instead of renewing — setup, not a session touch; the
				// modem never noticed any of this. The same two guards as the
				// ready path: an operator ifdown (autostart=false that is not
				// our own) is intent and stays, and `auto 0` waits for an ifup.
				// `pending` is netifd's IFS_SETUP (ubus.c:830, 2026.07.08~6088f7b3)
				// — the interface is coming up right now, so leave it to that.
				// `wanted` is deliberately NOT consulted: the daemon clears it
				// when it downs an interface itself, and a wwand-issued down
				// that is later undone is exactly one of the cases here (the
				// `our_down` branch below says so, and test_wan6 pins it).
				//
				// Not when `_kick_after_connect` is armed: the connect-first
				// backends (MBIM/NCM) kick a few lines further down as part of
				// the `up` handling, with the same guards, and two kicks for one
				// event is one more than netifd needs.
				if (st && !st.up && !st.pending && !kick_pending) {
					if (!(entry.cfg.auto ?? true))
						return log('debug', sprintf('interface %s is down and auto=0, not kicking it for the renew',
							entry.cfg.interface));

					if (operator_down(entry, st)) {
						if (entry.wanted) {
							entry.wanted = false;
							log('notice', sprintf('interface %s is administratively down (ifdown), leaving it alone',
								entry.cfg.interface));
						}
						return;
					}

					if (!deps.kick_interface)
						return;

					// the claim itself fails: kicking repeats it, the detour
					// clears what makes it fail and kicks afterwards
					if (claim_failed(st) &&
					    heal_device_claim(entry, () => deps.kick_interface(entry.cfg.interface)))
						return;

					let kick = () => {
						log('notice', sprintf('interface %s is down with a connected session, kicking it up instead of renewing',
							entry.cfg.interface));

						// the signature describes what was pushed to an interface
						// that no longer holds it; setup will push everything again
						entry._applied_sig = null;
						deps.kick_interface(entry.cfg.interface);
					};

					// a cleared autostart with no record yet: asked again
					// first (confirm_then), and left to netifd if it is
					// coming up by then
					if (needs_confirm(entry, st))
						return confirm_then(entry,
							() => self.contexts[name] === entry && entry.ctx === ctx &&
							      ctx.state == 'CONNECTED' && (entry._conn_seq ?? 0) === conn_seq,
							(st2) => (st2?.up || st2?.pending) ? null : kick());

					kick();
					return;
				}

				// anything but a byte-identical repeat of what we last pushed
				// goes through, whatever netifd's addresses say. This used to
				// short-circuit BEFORE the status probe, which cost nothing
				// then and hid the down case above: a changed settings push is
				// exactly when netifd is most likely not to be holding the
				// interface, and that push went out as a renew nobody received.
				// The probe is one deferred ubus call either way.
				if (entry._applied_sig != cur_sig)
					return do_renew();

				if (st?.up &&
				    same(first_addr(st['ipv4-address']), ctx.settings?.ipv4?.addr) &&
				    v6_same(first_addr(st['ipv6-address']), ctx.settings?.ipv6?.addr,
				            ctx.settings?.ipv6?.plen)) {
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
			// A NEW CONNECTION GENERATION. Anything still waiting on an answer
			// about the previous one has to drop it: the entry and the ctx are
			// the same objects across a reconnect, and the state is CONNECTED
			// again, so nothing else distinguishes the two.
			if (entry) {
				entry._conn_seq = (entry._conn_seq ?? 0) + 1;

				// and drop the probe in flight, which is asking about the
				// connection that just ended. Not merely stale — it is IN THE
				// WAY: the renew further down is how the new session's
				// addresses reach netifd, and the latch would make it return
				// without sending anything, leaving netifd on the previous
				// session's settings until the next refresh came round.
				entry._renew_probe = null;
			}

			// a working data connection resets the recovery ladder
			ctx.modem.note_connect_success();
			clear_reconnect(name);
			emit('wwand.context', { context: name, interface: entry?.cfg?.interface, event: event });

			// RNDIS v6 model: the modem's v6 arrives via RA on the parent netdev.
			// A dhcpv6 subinterface on the parent's device (@<parent>, auto:1)
			// lets netifd run the v6 client (address/route/DNS/PD) natively; a
			// matching user section wins. It is PERSISTED to uci, not dynamic:
			// ensure_wan6() writes the section and commits, because netifd
			// re-reads uci on reload and the section has to be on disk first.
			// This comment claimed the opposite ("runtime-only, nothing in
			// uci") until a user posted the `config interface 'wanb_6'` block
			// out of their own /etc/config/network (ddimension/wwand#11) —
			// two comments about one function, disagreeing, and the wrong one
			// was the one people read first.
			// Every AT-driven NCM datapath works this way, not just rndis_host:
			// the E3372H on huawei_cdc_ncm shows the same kernel_ra addresses on
			// the parent netdev (HW-observed 2026-08-30). is_at_driver() is the
			// same table the AT-channel detection uses.
			// the EFFECTIVE family, not the interface's: a card that says
			// ipv4 about itself must not get a dhcpv6 subinterface built for
			// it, and one that says ipv4v6 must get one even where the
			// interface never spelled a family out (ddimension/wwand#35).
			// ...and the other way round: an IPv4-only context must also RETIRE
			// a subinterface an earlier dual-stack connect left behind, or
			// netifd keeps starting it from uci (ddimension/wwand#35).
			if (deps.retire_wan6 && discovery.is_at_driver(ctx.modem?.datapath?.backend) &&
			    entry?.cfg?.interface && context_common.effective_pdp(ctx) == 'ipv4')
				deps.retire_wan6(entry.cfg.interface);

			if (deps.ensure_wan6 && discovery.is_at_driver(ctx.modem?.datapath?.backend) &&
			    entry?.cfg?.interface && context_common.effective_pdp(ctx) != 'ipv4') {
				log('info', sprintf('interface %s: ensuring the dynamic dhcpv6 subinterface (RNDIS v6 model)',
					entry.cfg.interface));

				// ...but wait for the parent's link-local first (see has_lla).
				let dev = ctx.modem?.datapath?.netdev;
				let iface = entry.cfg.interface;
				let want = context_common.effective_pdp(ctx);
				let mine = ctx;
				let tries = 0;
				let confirmed = false;
				let arm;

				// ONE CHAIN PER ENTRY. Repeated `up` events would otherwise
				// stack parallel waits, each eventually calling ensure_wan6 and
				// bouncing the subinterface again.
				if (entry._wan6_arming)
					return;

				entry._wan6_arming = true;

				arm = () => {
					// The context this belongs to is gone, or was replaced —
					// and the ENTRY check is the load-bearing half: stop_context
					// deletes the entry from self.contexts without clearing its
					// ctx (:1238) and shutdown replaces the whole map (:2894),
					// so a closure holding `entry` would still see
					// `entry.ctx == mine` and bounce a freshly created
					// subinterface.
					if (self.contexts[name] != entry || entry.ctx != mine) {
						entry._wan6_arming = false;
						return;
					}

					// AND THE FAMILY MUST STILL BE THE ONE THAT ARMED THIS.
					// The checks above ask whether the CONTEXT is still the
					// same one; they say nothing about what it is now carrying.
					// An interface switched to ipv4 between the arming and the
					// fire has already been retired by the branch above, and
					// this closure would put the subinterface straight back —
					// the same object, so nothing above notices.
					if (context_common.effective_pdp(mine) == 'ipv4') {
						entry._wan6_arming = false;
						return;
					}

					if (!has_lla(dev)) {
						// back to square one: the two readings have to be
						// CONSECUTIVE, or a flap between them proves nothing
						confirmed = false;

						if (++tries <= LLA_WAIT_TRIES)
							return uloop.timer(LLA_WAIT_MS, arm);

						// the budget is spent: start anyway, which is what the
						// warning says. STRAIGHT THROUGH, not via the
						// confirmation below — that branch asks for a second
						// sighting of an address that is demonstrably not
						// coming, and an earlier version of this fell into it
						// and rescheduled forever, warning every tick and never
						// clearing `_wan6_arming`. The confirmation is only
						// about an address that IS there.
						log('warn', sprintf('interface %s: no link-local on %s after %d ms — starting the v6 subinterface anyway',
							iface, dev ?? '?', LLA_WAIT_TRIES * LLA_WAIT_MS));
					}
					// CONFIRM, do not trust one reading. The address this waits
					// for is taken away for a fraction of a second by the very
					// renew_iface() below — so "present" sampled once, before
					// that renew has even been issued, is the original bug with
					// a narrower window rather than a fix. Require it on two
					// readings a tick apart, which brackets the gap the renew
					// opens.
					else if (!confirmed) {
						confirmed = true;

						return uloop.timer(LLA_WAIT_MS, arm);
					}

					entry._wan6_arming = false;

					// the pdp type rides along for the log only — this gate has
					// already established that the context is v6-capable
					deps.ensure_wan6(iface, want);
				};

				// DEFERRED, never synchronous. renew_iface() runs further down
				// in this same turn and is what disturbs the parent's
				// link-local; arming inline meant the LLA check ran BEFORE the
				// disturbance it exists to avoid.
				uloop.timer(LLA_WAIT_MS, arm);
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
					let kentry = entry, kiface = entry.cfg.interface, kctx = ctx;
					let kseq = entry._conn_seq ?? 0;

					let do_kick = () => {
						log('info', sprintf('kicking interface %s to adopt the connected session', kiface));
						deps.kick_interface(kiface);
					};

					// re-check: the connect takes seconds, and an ifdown landing in
					// that window must not be undone by the kick that follows it.
					//
					// `_our_down` has to be consulted here for the same reason the
					// ready path consults it: netifd's ubus `down` runs
					// interface_set_down(), which clears autostart no matter who
					// asked. On a connect-first backend the down that precedes this
					// connect is very often OUR OWN — the stuck-pending reset a few
					// lines above issues one and then immediately arms
					// `_kick_after_connect`, so this re-check ran against a flag wwand
					// itself had just cleared, read it as an operator ifdown, and left
					// the interface down with a CONNECTED session behind it. That is
					// exactly the divergence reported in ddimension/wwand#5 (EG18-EA
					// on a MikroTik Chateau, 2026-09-07): wwand CONNECTED, netifd
					// up=false/autostart=false, and only a manual `ifup` recovered it.
					if (deps.iface_status)
						deps.iface_status(kiface, (st) => {
							// retired while the probe was out (a reload): not
							// ours to kick any more — see decide() above
							if (self.contexts[name] !== kentry || kentry.ctx !== kctx)
								return;

							if (operator_down(kentry, st)) {
								kentry.wanted = false;
								log('notice', sprintf('interface %s went administratively down while connecting, not kicking it up',
									kiface));
								return;
							}

							// no record of the ifdown yet: asked again first —
							// and, as at the renew site, only a session that is
							// still this one is kicked for, and an interface
							// netifd is bringing up by then is left to it
							if (needs_confirm(kentry, st))
								return confirm_then(kentry,
									() => self.contexts[name] === kentry && kentry.ctx === kctx &&
									      kctx.state == 'CONNECTED' && (kentry._conn_seq ?? 0) === kseq,
									(st2) => (st2?.up || st2?.pending) ? null : do_kick());

							// our own down is being undone. The marker is NOT cleared
							// here: the kick is fire-and-forget, so an up that never
							// lands would leave autostart=false with nothing left to
							// explain it, and the next poll would read our own down as
							// operator intent. It is cleared once a status shows the
							// interface actually back.
							if (our_down(kentry))
								log('info', sprintf('interface %s was taken down by wwand, bringing it back up',
									kiface));

							do_kick();
						});
					else
						do_kick();
				}
			}
			break;

		case 'error':
			// failed activation climbs the recovery ladder — but not when the modem
			// lost registration mid-attempt: no service isn't a fault the ladder fixes.
			// Nor a dial that failed because the operator is detaching the modem
			// or a radio cycle runs (with_sessions_released): the modem still
			// reads READY then, and the failure is the one asked for
			// (HW-observed on the MeiG SLM770A, 2026-10-10).
			if (ctx.modem.state == 'READY' && !ctx.modem.detached && !ctx.modem._reattaching)
				ctx.modem.note_connect_failure();

			// A START_NETWORK the modem never ANSWERS (a timeout, not a refusal)
			// on a registered modem means its WDS side hangs. An MC7710
			// (SWI9200X_03.05.29) does exactly that after a STOP_NETWORK: every
			// later dial times out, not even a new WDS client is handed out, and
			// the ladder's radio cycle comes only at attempt 8 — ~16 min of
			// 120 s timeouts. One radio cycle (DMS low_power -> online) frees it
			// and the next dial connects in seconds (deborah-3, 2026-10-04). So
			// cycle at once, at most every 10 min per modem; a QMI error or a
			// network rejection keeps going the ladder's way.
			//
			// The reconnect waits for the cycle. Started beside it, the next
			// dial lands in the radio-off window, registration loss aborts it,
			// and every such abort is one more CID allocation in flight
			// (HW-observed, deborah-3 2026-10-04). `_reattaching` is the flag
			// the down/suspend handler already honours for netsel's AT reattach.
			let cycling = false;

			if (data?.stage == 'start_network' && data?.err?.error == 'timeout' &&
			    ctx.modem.state == 'READY' && !ctx.modem._reattaching &&
			    type(ctx.modem.reattach) == 'function') {
				let mentry = self.modems[entry?.cfg?.modem];
				let now = context_common.mono();

				if (mentry && (mentry._wds_bounce_at == null || now - mentry._wds_bounce_at >= 600)) {
					mentry._wds_bounce_at = now;
					log('notice', sprintf('interface %s: the modem did not answer the dial at all — cycling its radio once to free its data service',
						entry?.cfg?.interface ?? name));

					let m = ctx.modem;
					let settled = false;
					let guard;

					// One exit for the callback and the guard: a reattach whose
					// callback never comes (a teardown between its steps) must
					// not leave the flag set, or no down would reconnect again.
					let finish = (err) => {
						if (settled)
							return;

						settled = true;
						m._reattaching = false;
						guard?.cancel();

						if (err)
							log('warn', sprintf('interface %s: radio cycle failed: %J',
								entry?.cfg?.interface ?? name, err));

						let e = self.contexts[name];

						if (e?.wanted && e.ctx?.state == 'IDLE')
							enter_reconnecting(name);
					};

					m._reattaching = true;
					cycling = true;
					guard = uloop.timer(REATTACH_GUARD_MS, () => finish({ error: 'no answer from the radio cycle' }));
					// through netsel_ops: any other PDN this modem carries is
					// stopped before the radio goes off, not cut by the detach
					self.reattach_released(m, (err) => finish(err));
				}
			}
			emit('wwand.context', { context: name, interface: entry?.cfg?.interface, event: event });
			if (entry?.wanted && !cycling)
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
			// A modem-level reattach (netsel_ops) stops the sessions before
			// it detaches and hands them back afterwards — a reconnect started
			// here would dial into the detach.
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

	// How long a device we have already driven may present only a serial port
	// before that stops being "still enumerating" and becomes what it is. The
	// NR7101 that prompted this took seventeen seconds from reset pulse to an
	// answering QMI channel (ddimension/wwand#40, 2026-09-23); ninety is room
	// for a slower one without leaving a genuinely swapped serial stick
	// unserved for long.
	const PPP_SETTLE = 90;

	// a PPP-only modem (serial port only) is mode-switched ONCE to a richer
	// usbnet mode, then left for hotplug to rebuild on re-enumeration (no modem
	// object built — no PPP dialer). Per-modem guard so it never loops.
	let modeswitch_tried = {};

	// Every dead end of the mode switch lands on a PPP-only device, and wwand
	// does not drive PPP — by decision, not omission: it speaks QMI, MBIM and
	// NCM, and OpenWrt's own `proto 3g` already handles serial modems with
	// better auto-reconnect than wwand offers for them. Saying only "leaving
	// unmanaged" tells an operator nothing about what to do next, which is the
	// complaint that prompted this (hardware sponsor, 2026-09-09). One helper,
	// so the three exits cannot drift apart.
	let ppp_unsupported = (name, entry, why) => {
		log('err', sprintf('modem %s: %s — this looks like a PPP-only device, which wwand does not support; configure it with OpenWrt\'s `proto 3g` instead',
			name, why));

		if (entry)
			entry.control_note = sprintf('PPP-only device (%s) — unsupported; use `proto 3g`', why);
	};

	let try_modeswitch = (name, entry, tty) => {
		log('warn', sprintf('modem %s: only a serial port present (ppp), no rich control interface', name));

		if (modeswitch_tried[name]) {
			log('info', sprintf('modem %s: usbnet mode switch already attempted, waiting for re-enumeration', name));
			// WITH A NOTE, because the periodic re-check only looks at entries
			// that have one (the waiting-modems loop in the tick). Returning
			// bare left a rebuilt entry with control_note null, which quietly
			// dropped the device out of the retry it is waiting for.
			if (entry)
				entry.control_note = 'waiting for modem (mode switch attempted, re-enumeration pending)';
			return;
		}

		modeswitch_tried[name] = true;

		if (!deps.modeswitch)
			return ppp_unsupported(name, entry, 'no mode-switch backend installed');

		if (!tty)
			return ppp_unsupported(name, entry, 'no AT port to mode-switch on');

		log('notice', sprintf('modem %s: attempting one-time usbnet mode switch on %s', name, tty));

		deps.modeswitch({
			tty: tty,
			log: (l, m) => log(l, sprintf('modem %s: modeswitch: %s', name, m)),
		}, (err, res) => {
			if (err) {
				log('warn', sprintf('modem %s: usbnet mode switch failed: %J', name, err));
				return ppp_unsupported(name, entry,
					sprintf('the one-time usbnet mode switch failed (%J)', err));
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

	// hardware repower: a modem `reset_gpio` (or the single-modem board default)
	// pulses RESET without cutting power; else power-cycle the USB power GPIO.
	// Board fallbacks gated by board_gpio_ok (multi-modem would hit the wrong
	// hardware). No-op when nothing safe is available. Named rather than inlined
	// because the vanish escalation in the tick needs the SAME action the ladder
	// uses — two spellings of "reset this modem" is how they drift apart.
	//
	// Must stay BELOW board_gpio_ok: ucode does not hoist a `let`, and a closure
	// written above one compiles the name as a global lookup rather than a local
	// slot — so it fails at CALL time with "access to undeclared variable", not
	// at parse time. Found on hardware, because the host suite runs this path
	// with no board dep at all (NR7101, 2026-09-07).
	// WHICH named RESET line applies to this modem, or null when the hardware
	// action would be a power cycle (or nothing). Extracted rather than spelled
	// out twice because the recovery ladder now ASKS this question before it
	// takes its one unarmed action, and board_repower() then has to answer it
	// the same way — two copies of this precedence is two answers that drift,
	// and here the drift would be the ladder authorising a reset and the board
	// cutting power instead. hwops.repower_plan() states the same rule for the
	// operator-facing plan.
	let board_reset_line = (cfg) => {
		if (!deps.board)
			return null;

		let rg = cfg?.reset_gpio ?? (board_gpio_ok() ? deps.board.profile?.reset_gpio : null);

		// AN OPTION THAT IS PRESENT BUT EMPTY IS NOT A LINE. uci keeps
		// `option reset_gpio ''` as an empty string, which `??` passes straight
		// through while every consumer that ACTS on the value tests it for
		// truthiness — so the answer here would have been "there is a reset
		// line" and the action taken would have been a power cycle. That is the
		// precise divergence this function exists to make impossible, and it is
		// worst in the new caller: the ladder would have authorised its one
		// narrow exception on an unarmed modem and the board would have cut
		// power instead.
		return rg ? rg : null;
	};

	let board_repower = (cfg) => {
		if (!deps.board)
			return false;

		let rg = board_reset_line(cfg);
		let off = cfg?.repower_time ? +cfg.repower_time * 1000 : null;

		if (rg)
			return deps.board.reset_pulse(rg, off);

		return board_gpio_ok() ? deps.board.power_cycle(off) : false;
	};


	// detach a dead modem: drop the modem object, reset device/netdev to their
	// configured values, unbind this modem's contexts (their ctx is bound to the
	// dead modem; queued activations would wait forever). The next rebuild builds
	// fresh modem + context objects.
	detach_modem = (name, entry) => {
		// KEEP WHAT THE HARDWARE TOLD US. The object goes, the modem does not:
		// a slot switch re-enumerates the USB device and this entry is rebuilt
		// for the same bound device. On an NCM/AT modem the vendor recipe comes
		// from AT+CGMI/CGMM, and a firmware that refuses those for a few
		// seconds after re-enumeration would otherwise be `generic` for the
		// life of the new object — no vendor ip_config, no IPv4 (FM350-GL,
		// ddimension/wwand#32). Only a complete answer is worth remembering.
		// ...and only what THIS modem said. A carried-over identity written back
		// here would attach the old manufacturer to the new IMEI and outlive the
		// mistake.
		if ((entry.modem?.info?.manufacturer ?? '') != '' &&
		    !entry.modem.info.ident_carried)
			entry._ident = {
				manufacturer: entry.modem.info.manufacturer,
				model: entry.modem.info.model,
				imei: entry.modem.info.imei,
			};

		// TELL THE CONTEXTS FIRST, then stop the modem — the order _device_gone
		// uses (modem_common.uc:670). Dropping `centry.ctx` below only releases
		// the daemon's HANDLE: the context object itself lives on with its
		// monitor timers armed and its WDS clients alive, polling a hub that
		// entry.modem.stop() has just closed. One orphan per removal, and its
		// late events can arm a spurious reconnect-hold on the rebuilt entry.
		// `lost` is built for exactly this — it stops the monitor and destroys
		// the family clients without attempting QMI cleanup (context.uc:1196).
		for (let cname, centry in self.contexts) {
			if (centry.cfg.modem == name && centry.ctx)
				centry.ctx.modem_event('lost');
		}

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
	// `done` (optional) is called once the context's own teardown is through —
	// STOP_NETWORK answered and its clients released — or at once when it had
	// nothing to tear down.
	let stop_context = (name, done) => {
		let entry = self.contexts[name];

		if (!entry)
			return done ? done() : null;

		clear_reconnect(name);
		cancel_confirm(entry);

		for (let p in entry.pending_up)
			p({ error: 'reload' });

		if (entry.ctx && entry.ctx.state != 'IDLE')
			entry.ctx.down(() => done ? done() : null);
		else if (done)
			done();

		// unhook from the modem's context list — else the dead ctx is retained
		// and keeps receiving notify_contexts events (leak + latent misbehavior)
		if (entry.ctx?.modem?.detach_context)
			entry.ctx.modem.detach_context(entry.ctx);

		delete self.contexts[name];
	};

	// Idempotent-reload teardown of a SINGLE modem: stop its contexts, cancel a
	// pending mode-switch watchdog, stop the backend, and drop it from the map.
	//
	// THE BACKEND GOES AFTER ITS SESSIONS, not beside them. A context's down
	// sends STOP_NETWORK and then releases its WDS clients; the modem's stop
	// closes the control channel those travel on. Done in one breath, the
	// STOP was never answered (a timeout, then "send" on the closed hub) and
	// the session stayed in the modem: after a reload from a muxed to an
	// unmuxed datapath the new dial got no answer at all, radio cycle or not
	// (RG650E on 245, 2026-10-05). So the backend stops once every active
	// context reports its teardown done, or after RETIRE_MAX_MS whatever
	// happened — a modem that does not answer STOP must not hold the reload.
	// Meanwhile the modem is RETIRING: apply_config's restart of the same
	// modem waits for it (self._retiring), because the new backend would open
	// the device the old one still holds.
	const RETIRE_MAX_MS = 5000;

	let stop_modem = (name) => {
		let entry = self.modems[name];

		if (!entry)
			return;

		let ret = { start: null };
		let pending = 0, finished = false, timer = null;

		let finish = () => {
			if (finished)
				return;

			finished = true;

			if (timer)
				timer.cancel();

			if (entry.modem)
				entry.modem.stop();

			if (self._retiring[name] === ret)
				delete self._retiring[name];

			// the restart apply_config asked for while this one was retiring
			if (ret.start && !self.modems[name]) {
				start_modem(name, ...ret.start);

				// its contexts were built while it was absent: bind them now,
				// as the waiting-modem tick and hotplug add do
				if (self.modems[name]?.modem)
					for (let cname, centry in self.contexts)
						if (centry.cfg.modem == name && !centry.ctx)
							start_context(cname, centry.cfg);
			}
		};

		self._retiring[name] = ret;

		for (let cname in keys(self.contexts)) {
			let ce = self.contexts[cname];

			if (ce.cfg.modem != name)
				continue;

			if (ce.ctx && ce.ctx.state != 'IDLE') {
				pending++;
				stop_context(cname, () => {
					if (--pending <= 0)
						finish();
				});
			}
			else
				stop_context(cname);
		}

		// ...and close its NMEA port. Otherwise the reader holds an fd on a
		// device that is gone — or worse, on whatever the kernel hands that
		// name to next — and no other modem can be given that tty, because one
		// port is only ever read once.
		release_gps(name);

		if (entry.modeswitch_liveness)
			entry.modeswitch_liveness.cancel();

		delete self.modems[name];

		if (pending <= 0)
			finish();
		else if (!finished)
			timer = uloop.timer(RETIRE_MAX_MS, finish);
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

		if (fx.exists(sprintf('/sys/class/net/%s', want))) {
			// RECLAIM THE NAME FROM OUR OWN LEFTOVER CHILD, when we already
			// know there will not be one.
			//
			// An MBIM modem with a lone `auto` channel runs untagged (no
			// session, no vlan child) and that is settled here, before the
			// datapath runs — unlike QMI, where only the modem's WDA answer
			// settles it. Coming from a TAGGED config the child still holds the
			// stable name at this moment; setup() prunes it a second later, but
			// the rename has already been skipped and nothing retries it. The
			// parent then keeps a raw kernel name that depends on USB
			// enumeration order, which is the instability stable L3 names exist
			// to remove — and the next unchanged reload is a no-op, so it stays
			// that way. (HW-reproduced on the GL-X3000/RM520N, 2026-09-20:
			// tagged -> auto left the interface on `wwan1`.)
			//
			// THREE CONDITIONS, because deleting a network device on a name
			// match alone is not something to get wrong. Stacking on this
			// parent (`lower_<parent>`) says only that — an operator's own
			// macvlan or a hand-made VLAN on the same modem would satisfy it
			// just as well, and this code would have deleted it. So also:
			//
			//   - it is an 802.1q VLAN (`DEVTYPE=vlan` in the device's uevent;
			//     a macvlan reads `DEVTYPE=macvlan`), and
			//   - its VLAN id is the session id this modem's own config asked
			//     for, which is what the vlan datapath would have built.
			//
			// Together that is the device WE created and nothing else. Layout
			// verified on the GL-X3000/RM520N, 2026-09-20.
			let ours = () => {
				if (!fx.exists(sprintf('/sys/class/net/%s/lower_%s', want, entry.netdev)))
					return false;

				if (index(fx.read(sprintf('/sys/class/net/%s/uevent', want)) ?? '', 'DEVTYPE=vlan') < 0)
					return false;

				let vid = match(fx.read(sprintf('/proc/net/vlan/%s', want)) ?? '', /VID: *([0-9]+)/);
				let want_vid = entry.muxinfo?.list?.[0]?.id;

				return (vid != null && want_vid != null && +vid[1] == +want_vid);
			};

			if (entry.protocol == 'mbim' && entry.muxinfo?.demotable && fx.link_del &&
			    fx.read && ours()) {
				log('notice', sprintf('modem %s: %s is a leftover mux child of %s and this modem runs untagged — removing it to take the name',
					name, want, entry.netdev));
				fx.link_del(want);

				// ...and netifd will not take it until it is restarted. It
				// holds a device record for this name from when it WAS a vlan
				// child, and claiming it re-runs that record's setup against a
				// parent that no longer exists: interface_set_up() then reports
				// DEVICE_CLAIM_FAILED and the interface sits down with a
				// perfectly good session behind it (netifd interface.c:1349-1353,
				// 2026.07.08~6088f7b3). A `reload` does not clear the record; a
				// restart does, and so does the device detour the status paths
				// take when netifd reports exactly that (heal_device_claim) —
				// HW-confirmed on the GL-X3000/RM520N, 2026-09-20.
				log('notice', sprintf('modem %s: netifd still holds a device record for %s from when it was a mux child — should the claim fail, wwand re-creates that record (netifd device detour)',
					name, want));
			}
		}

		// THE SAME FOR A QMI MODEM WHOSE CONFIG NOW HAS NO CHANNEL AT ALL (a
		// mux_id that went from 1 to 0, a muxed sibling deleted): the old QMAP
		// child still holds the stable name, the datapath prunes it a second
		// later (netlink.uc prune_mux_children), and this rename has already
		// given up by then and is not retried — the parent kept its kernel
		// name and netifd reported NO_DEVICE for good (HW-seen on the NR7101,
		// 2026-10-04: mux_id 1 -> 0). Taken now, on the prune's own proof: a
		// device whose iflink is this parent's ifindex is its mux child
		// (rmnet_vnd_get_iflink returns real_dev's, rmnet_vnd.c:97-102, Linux
		// 6.18.41). Never with a channel configured — that child is wanted.
		if (entry.protocol == 'qmi' && !length(entry.muxinfo?.list ?? []) &&
		    !(entry.muxinfo?.demotable ?? false) && fx.link_del && fx.read &&
		    fx.exists(sprintf('/sys/class/net/%s', want))) {
			let idx = trim(fx.read(sprintf('/sys/class/net/%s/ifindex', entry.netdev)) ?? '');
			let link = trim(fx.read(sprintf('/sys/class/net/%s/iflink', want)) ?? '');

			if (length(idx) && link == idx) {
				log('notice', sprintf('modem %s: %s is a leftover mux child of %s and this modem runs without mux — removing it to take the name',
					name, want, entry.netdev));
				fx.link_del(want);

				// ...and the MODEM still carries the QMAP session it had: see
				// _left_qmap at the modem's creation below
				self._left_qmap[name] = true;
			}
		}

		if (fx.exists(sprintf('/sys/class/net/%s', want))) {
			// For a DEMOTABLE modem this is not a failure but the other of two
			// expected outcomes. The name is asked for up front in case the
			// auto channel turns out not to exist; when it does exist, the mux
			// CHILD takes that name and the parent keeping its kernel name is
			// exactly right. Reporting it at error level meant a perfectly
			// healthy muxed modem logged a daemon.err on every single start
			// (HW-observed on the NR7101, 2026-09-11).
			if (entry.muxinfo?.demotable)
				return log('info', sprintf('modem %s: %s is taken — the mux child has it, so netdev %s keeps its kernel name',
					name, want, entry.netdev));

			return log('err', sprintf('modem %s: cannot rename netdev %s to %s: name already in use — keeping %s',
				name, entry.netdev, want, entry.netdev));
		}

		if (!fx.link_set(entry.netdev, { rename: want }))
			return log('err', sprintf('modem %s: renaming netdev %s to %s failed (device busy?) — keeping %s',
				name, entry.netdev, want, entry.netdev));

		log('notice', sprintf('modem %s: netdev %s renamed to %s (stable L3 device name)',
			name, entry.netdev, want));

		// Keep the name the KERNEL gave it. A vendor QMAP driver names its
		// children after the parent ONCE, in its USB probe
		// (sprintf("%s_%d", real_dev->name, ...)), and that name never changes
		// afterwards — so after this rename the children still carry the old
		// stem and a datapath probing for `<new>_1` finds nothing, falls back
		// to raw_ip, and leaves a parent that is actually in QMAP framing with
		// no traffic. Field-found on an IPQ807x/RG500Q NSS board (2026-09-03).
		entry.netdev_kernel = entry.netdev;
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

	start_modem = (name, cfg, muxinfo, l3name) => {
		// decide how this modem is controlled (qmi/mbim/ncm/ppp). resolve_control
		// classifies EVERY modem, incl. NCM modems with no cdc-wdm.
		let control = deps.resolve_control ? deps.resolve_control(cfg) : null;

		// A QRTR modem (a Qualcomm SDX on PCIe/MHI, whose QMI lives on the QRTR bus
		// via qcom_mhi_qrtr — there is no cdc-wdm control node) is selected by the
		// sentinel control device "qrtr"; modem.uc opens the QMI-over-QRTR hub for
		// it. The socket can always be opened, so it says nothing about the modem:
		// PRESENT means its node serves DMS (discovery.qrtr_probe). Until then the
		// control record stays null and the modem takes the same waiting path as
		// a missing cdc-wdm, retried by the tick — there is no hotplug for QRTR.
		// The data netdev still comes from the interface (option device).
		if (cfg.device == 'qrtr') {
			let node = deps.qrtr_probe ? deps.qrtr_probe(cfg) : null;

			control = (node != null)
				? { protocol: 'qmi', device: 'qrtr', netdev: cfg.netdev, tty: null, qrtr_node: node }
				: null;
		}

		// legacy dep path (resolve_modem_device/resolve_protocol instead of
		// resolve_control): synthesize a control record. ONLY when resolve_control
		// isn't injected — otherwise its null is authoritative ("device not present
		// yet") and we must NOT fall back to raw cfg.device (a netdev name isn't an
		// openable control node); the modem must WAIT for hotplug.
		// (never for qrtr: its presence is the probe's answer above, and a
		// control record made up from the config would bypass it)
		if (!control && !deps.resolve_control && cfg.device != 'qrtr') {
			let device = cfg.device;

			if (!device && deps.resolve_modem_device)
				device = deps.resolve_modem_device(cfg);

			if (device) {
				let proto = cfg.protocol;

				// Fallback path, taken only when no resolve_control dep is wired
				// (production wires both — see main.uc). `unknown` means WE
				// LOOKED AND COULD NOT TELL, which is what refuses the modem
				// below; with no resolver at hand nobody looked, so the historic
				// qmi default stands rather than every modem being refused.
				let looked = false;

				if (proto == null || proto == 'auto') {
					if (deps.resolve_protocol) {
						proto = deps.resolve_protocol(device);
						looked = true;
					}
					else {
						proto = 'qmi';
					}
				}

				control = { protocol: proto, unknown: looked && proto == null,
				            device: device, netdev: cfg.netdev, tty: cfg.tty };
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
				...carry_over(name),
			};

			return;
		}

		// A control device we cannot identify must not be driven on a guess. It
		// stays visible with a note saying what was seen, exactly like a device
		// another stack owns — the modem is idle for a stated reason instead of
		// looking merely absent, and no backend is loaded, no request is sent
		// and no recovery rung can fire on errors we would have caused
		// ourselves. `option protocol 'qmi'|'mbim'|'ncm'` overrides it.
		if (control?.unknown && control.device) {
			let drv = control.driver;

			log('err', sprintf('modem %s: cannot identify the control protocol of %s (%s) — set `option protocol` to qmi, mbim or ncm, or report the driver so it can be added',
				name, control.device, drv ? sprintf('driver %s', drv) : 'no driver bound'));

			self.modems[name] = {
				cfg: cfg, device: control.device, netdev: control.netdev ?? null,
				muxinfo: muxinfo, l3_name: l3name ?? null, modem: null, protocol: null,
				control_note: sprintf('unknown control protocol on %s (%s) — set `option protocol`',
					control.device, drv ? sprintf('driver %s', drv) : 'no driver bound'),
				...carry_over(name),
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
			// the reload signature and the outage state — see carry_over()
			...carry_over(name),
		};

		self.modems[name] = entry;

		// presence gate: NCM needs a datapath netdev, PPP needs a serial port,
		// QMI/MBIM need a cdc-wdm control device.
		let present = control && (
			control.protocol == 'ncm' ? control.netdev != null :
			control.protocol == 'ppp' ? control.tty != null :
			control.device != null);

		if (!present) {
			// A modem we ONCE had is a vanish, whatever route it took to get
			// here. _device_gone() only fires when the transport notices the
			// disappearance by itself; when the device goes while requests are
			// in flight the modem instead fails, tears down and lands ABSENT,
			// and the periodic rebuild then arrives here — which used to look
			// exactly like a cold boot and escalated to nothing. Measured on an
			// NR7101 (2026-09-07) by pulling the modem's reset line under a live
			// session: the log showed the boot-style wait and no escalation.
			if (entry._had_modem && !entry.vanished) {
				entry.vanished = true;
				entry._vanish_rung = 0;
				entry.waiting_since = entry.waiting_since ?? time();
			}

			// the serial-only spell ended by the device leaving. NOT cleared
			// when it keeps presenting a serial port past the window — that
			// timestamp is what the window is made of, and resetting it on
			// every tick would mean waiting forever, which is the bound it
			// exists to provide. A spell ends when the device goes away or
			// comes back rich, and both clear it.
			delete entry._ppp_since;

			log('warn', sprintf('modem %s: control interface not present yet, waiting for hotplug', name));
			// surface the wait to status()/netifd; the periodic tick re-logs it every 30s.
			entry.control_note = entry.vanished
				? 'waiting for modem (device vanished)'
				: (cfg.device == 'qrtr')
					? 'waiting for modem (no QMI service on the QRTR bus)'
					: 'waiting for modem (control device not present)';
			entry.waiting_since = entry.waiting_since ?? time();
			return;
		}

		// PPP-only: mode-switch and wait for re-enumeration; do not build a modem.
		//
		// BUT NOT FOR A MODEM WE HAVE ALREADY DRIVEN. A device re-enumerating
		// after a reset passes through a state where only its serial port has
		// appeared, and reading that as a diagnosis produces a confident, wrong
		// one: wwand told an NR7101 owner his QMI modem "looks like a PPP-only
		// device, which wwand does not support" thirty-one seconds after
		// pulsing its reset GPIO, then found the QMI channel and came up
		// normally seventeen seconds later. It even tried to mode-switch on a
		// tty that did not exist yet — "cannot open /dev/ttyUSB2: No such file
		// or directory" — which is the same fact stated twice (evidence:
		// ddimension/wwand#40).
		//
		// `_had_modem` is exactly the distinction needed and is already kept
		// for the vanish escalation below: this control device was once ours,
		// so a serial-only reading is the device coming back, not what it is.
		// Waiting is what the next tick does anyway.
		// BOUNDED, because "we have driven this before" is about the config
		// entry and not about the hardware on the port: swap a QMI stick for a
		// serial-only one and the flag still says yes. Waiting forever would
		// then suppress the one-time mode switch that device needs. A device
		// that is still serial-only after PPP_SETTLE seconds is not
		// mid-enumeration — the NR7101 took seventeen — so the diagnosis is
		// allowed through.
		if (control.protocol == 'ppp' && entry._had_modem &&
		    (time() - (entry._ppp_since ?? time())) < PPP_SETTLE) {
			entry._ppp_since ??= time();
			// protocol-NEUTRAL: `entry.protocol` is this discovery's answer,
			// which is 'ppp' right now, and `_had_modem` carries no memory of
			// what it was. Saying "has spoken ppp before" would be the same
			// mistake one layer down.
			log('info', sprintf('modem %s: serial port only so far, but this one has been driven before — waiting for it to finish enumerating',
				name));
			entry.control_note = 'waiting for modem (still enumerating)';
			return;
		}

		if (control.protocol == 'ppp')
			return try_modeswitch(name, entry, control.tty);

		// the serial-only spell is over — start the settle window afresh if it
		// ever comes back
		delete entry._ppp_since;

		// a rich control interface means any prior mode switch re-enumerated —
		// cancel its liveness watchdog and clear the note.
		if (entry.modeswitch_liveness) {
			entry.modeswitch_liveness.cancel();
			entry.modeswitch_liveness = null;
		}
		entry.control_note = null;
		// the modem answered again: this outage is over, so the next one starts
		// at the bottom of the escalation rather than where this one stopped
		entry.vanished = false;
		entry._vanish_rung = 0;
		entry.waiting_since = null;

		let device = entry.device;
		// non-null by here: an unidentified device was refused above
		let proto = control.protocol ?? cfg.protocol;

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

		// A QRTR modem has no control node, so its endpoint can only come from
		// the data netdev (netlink.ep_iface_number: PCIe -> 4). When that does
		// not resolve either — no netdev configured yet — fall back to the
		// same PCIE/4 instead of sending no endpoint, which the modem refuses
		// with InvalidOperation (QMI error 70, RG520N, ddimension/wwand#46). A
		// config ep_type/ep_id still wins.
		if (cfg.device == 'qrtr') {
			if (ep_type == null) ep_type = 3;
			if (ep_id == null) ep_id = 4;
		}

		let common = {
			id: name,
			device: device,
			// the resolved control protocol (detected, or `option protocol`):
			// recovery persists it with the counters so a protocol change
			// invalidates `proven` on the next load (recovery.uc load()) — the
			// new protocol must re-earn the proof before any hardware rung may
			// fire. The switch_protocol rebuild goes through here too: the
			// modem object is recreated and re-detection picks the new protocol.
			protocol: proto,
			config: cfg,
			timing: self.timing,
			// non-null when `option protocol` overrode what the driver said, and
			// names the driver's reading. An AT-driven backend uses it to refuse
			// weak evidence: on a QMI/MBIM modem pinned to NCM the AT port
			// answers perfectly well and proves nothing (modem_ncm).
			//
			// Only NCM needs it, and the asymmetry is not an oversight. QMI and
			// MBIM take their evidence from a response FRAME carrying our
			// transaction id, which nothing but that protocol can produce — a
			// modem pinned to the wrong one of the two simply never answers, so
			// there is no false positive to guard against. AT is the generic
			// channel: nearly every modem has one, whatever it speaks.
			pinned_over: control?.pinned_over ?? null,
			recovery: {
				fx: deps.recovery_fx,
				state_dir: opts?.state_dir,
				reboot_delay: opts?.reboot_delay,
				// hardware repower rung: a modem `reset_gpio` (or single-modem board
				// default) pulses RESET without cutting power; else power-cycle the USB
				// power GPIO. Board fallbacks gated by board_gpio_ok (multi-modem would
				// hit the wrong hardware). No-op when nothing safe is available.
				repower: deps.board ? (() => board_repower(cfg)) : null,
				// the RESET line ASSIGNED TO THIS MODEM in its own section — the
				// ladder's one permitted action on a modem that has never
				// answered (recovery.uc, unarmed_reset_line). Not the board
				// default, even on a box with one modem: that one modem may be a
				// USB backup stick while the built-in modem is switched off, and
				// the board's line belongs to the built-in one. An automatic pulse
				// on a modem that never answered needs the operator to have said
				// which line is its own.
				reset_line: deps.board
					? (() => (cfg?.reset_gpio ? cfg.reset_gpio : null)) : null,
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

		// netdev_kernel: the pre-rename name, when rename_l3 changed it. A
		// datapath whose children were named by the driver after the ORIGINAL
		// parent needs it to find them at all (see rename_l3).
		// MBIM: AN `auto` CHANNEL ON ITS OWN ASKS FOR NO CHANNEL AT ALL.
		//
		// Untagged traffic on a cdc_mbim parent already IS IPS session 0
		// (cdc_mbim.c:262-270, Linux 6.18.41), so a lone auto context does not
		// need a session id — and taking one costs an 802.1q tag on every frame
		// in both directions, plus a sub-device to route through, for nothing.
		// The channel number only exists because the allocator counts from 1:
		// QMAP channel 0 is invalid, MBIM session 0 is not.
		//
		// `demotable` is the same predicate QMI uses for its own no-mux
		// fallback — ONE auto-allocated channel and nothing else. A pinned
		// `option mux_id` is the operator asking for a tagged session and keeps
		// it; a second context needs tags for both, since one untagged parent
		// carries one session.
		let mbim_links = (muxinfo?.demotable ?? false) ? [] : (muxinfo?.list ?? []);

		if ((muxinfo?.demotable ?? false) && proto == 'mbim')
			log('info', sprintf('modem %s: mux auto resolves to MBIM session 0 — untagged on the parent, no vlan child',
				name));

		let datapath =
			(proto == 'mbim') ? { netdev: entry.netdev, mux: mux, plugins: dp_plugins,
			                      netdev_kernel: entry.netdev_kernel,
			                      mux_links: mbim_links, fx: deps.datapath_fx } :
			(proto == 'ncm')  ? { netdev: entry.netdev, fx: deps.datapath_fx } :
			                    { netdev: entry.netdev, ep_id: ep_id, ep_type: ep_type, mux: mux,
			                      plugins: dp_plugins,
			                      netdev_kernel: entry.netdev_kernel,
			                      dgram_size: cfg.dl_datagram_max_size,
			                      qmap_version: cfg.qmap_version,
			                      mux_links: muxinfo?.list ?? [],
			                      // May this modem drop to an unmuxed parent when it
			                      // turns out it cannot carry QMAP? Only for a SINGLE
			                      // auto-allocated channel. A second context has
			                      // nowhere to go on a raw-IP parent — one parent
			                      // carries one session — so demoting there would
			                      // silently run interface A and leave B dead without
			                      // naming a reason. Two APNs on a modem that cannot
			                      // mux is a real configuration error and is reported
			                      // as one. A pinned channel among them withholds the
			                      // permission for the same reason: the modem needs
			                      // QMAP for that one regardless.
			                      //
			                      // QMI only, and not because MBIM was forgotten:
			                      // there is no capability question there. An MBIM
			                      // session id is available on every MBIM modem, so
			                      // `auto` on one is an ordinary channel with nothing
			                      // to fall back from.
			                      mux_auto: muxinfo?.demotable ?? false,
			                      fx: deps.datapath_fx };

		entry.modem = be.modem.create({ ...common, datapath: datapath,
		                                known_ident: entry._ident ?? null });

		// A MODEM THAT LEAVES QMAP AT RUNTIME IS RESET ONCE, early in its init.
		// Coming from a muxed config, an RG650E answered no raw-IP dial at all
		// — sessions stopped cleanly, aggregation explicitly DISABLED and
		// confirmed, pass_through off, the data port bound to mux 0, a radio
		// cycle: START_NETWORK still timed out every time. The same config
		// dialled at once after a reset (245, 2026-10-05). What survives in
		// the modem is not visible over QMI, so the reset is taken whenever
		// the leftover QMAP child proves the modem was muxed a moment ago.
		// Kept on the DAEMON, not on this entry, until an init has actually
		// taken it: the modem object built right after the rename can go
		// ABSENT before its init runs, and the next one is a new entry (HW:
		// 245, the first attempt never reached SYNC). One-shot from there:
		// after the reset the kernel name comes back without a child, and
		// nothing sets this again.
		if (self._left_qmap[name]) {
			entry.modem._pending_init_reset = 'the datapath left QMAP — a modem keeps its muxed data session state until it is reset';
			entry.modem.on_init_reset_taken = () => delete self._left_qmap[name];
		}
		// what optional packages add to the AT init sequence (plugins.uc
		// at_init), with the control protocol: a plugin can tell a Qualcomm
		// modem (QMI) from others without an identity of its own
		entry.modem.at_init_extra = (info) => self.plugins_at_init?.(name, { ...(info ?? {}), protocol: proto }) ?? [];
		// Why the radio must stay off, asked by the init chain before it
		// switches the radio on (plugins.uc radio_hold): a modem whose card is
		// lent, or that waits for a remote SIM, must not register even once —
		// on LTE a registration is an attach, the network sees the IMSI. Parked
		// at init as a plugin park, so the tick wakes it when the hold is gone.
		entry.modem.radio_hold = () => self.plugins_radio_hold?.(name) ?? null;
		// A setting the init sequence changed that only a modem reset makes
		// real (an EFS item is read at boot): reset once. Once per modem and
		// setting for the daemon's life — should the reset not make it stick,
		// the next start writes it again and this does NOT reset a second
		// time, so a modem that never keeps it cannot be reset in a loop.
		entry.modem.at_init_changed = (changed) => {
			self._init_resets ??= {};
			let key = (c) => name + '/' + (c.set ?? c.note ?? '');
			let want = filter(changed, (c) => c.reset && !self._init_resets[key(c)]);

			if (!length(want))
				return;

			for (let c in want)
				self._init_resets[key(c)] = true;

			log('notice', sprintf('modem %s: resetting it once so that the init setting%s take%s effect: %s', name,
				(length(want) > 1) ? 's' : '', (length(want) > 1) ? '' : 's', join('; ', map(want, (c) => c.note ?? '?'))));
			self.modem_reset?.(name, (e) => e ? log('warn', sprintf('modem %s: that reset failed: %J', name, e)) : null);
		};
		// remembered for the vanish escalation below: "this control device was
		// once ours" is the only thing separating a modem that fell out of the
		// machine from one that never showed up.
		entry._had_modem = true;
		entry.modem.start();
	};

	start_context = (name, cfg) => {
		let mentry = self.modems[cfg.modem];

		// interface-bound contexts default wanted=true so the daemon (re)establishes
		// them on modem-ready without waiting for netifd — adopts a session that
		// survived a wwand restart.
		let prev = self.contexts[name];

		// a give-up restored from the file (a daemon restart inside the
		// outage) starts NOT wanted: the modem's next `registered` then takes
		// the re-arm path, which marks the down as ours and kicks netifd —
		// started wanted, the ready path read the cleared autostart as an
		// operator ifdown and parked it for good
		let restored = !prev && cfg.interface != null && !!self._giveups[cfg.interface];

		let base = { cfg: cfg, ctx: null, pending_up: [], wanted: (cfg.interface != null) && !restored,
		             retry_timer: null, hold_timer: null, retry_n: 0,
		             // preserve the last-applied reload signature across internal
		             // re-binds (hotplug) — the config itself is unchanged there
		             _sig: prev?._sig,

		             // ...and everything that describes the CURRENT outage rather
		             // than the config. This entry is rebuilt whenever a modem
		             // vanishes and returns — detach_modem keeps the entry but
		             // clears ctx, and the 30 s retry then re-binds it — so a
		             // field not carried here is erased by an event that says
		             // nothing about it. The modem side learned this the hard way
		             // (see carry_over above).
		             //
		             // `_failed_at` is context_failed's rate limit, and it guards
		             // HARDWARE: losing it lets a recovery rung that re-enumerated
		             // the modem reset the very limit that would have slowed the
		             // next probe, so a looping prober climbs the ladder as fast
		             // as it can call.
		             //
		             // (`_our_down` is NOT carried here: it is keyed by
		             // INTERFACE — see mark_our_down — precisely because an
		             // entry can fail to exist across a reload, and then there
		             // is nothing to carry it from.)
		             _failed_at: prev?._failed_at,
		             // ...or, after a daemon restart, from the file
		             reconnect_on_register: prev?.reconnect_on_register ?? restored };

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
		// SWEEP THE OUR-DOWN MARKERS. They are keyed by interface, and prune-on-
		// read only reaches names something still asks about — an interface
		// renamed or deleted from the config leaves its key behind with nobody
		// left to prune it. Deliberately NOT cleared when a context goes away:
		// that is exactly the case the map exists for (an interface whose modem
		// stopped resolving loses its entry and must still be recognised when
		// it comes back). The clock is the right arbiter, and a reload is the
		// natural moment to apply it.
		let now = time();

		for (let iface, at in self._our_downs)
			if ((now - at) >= OUR_DOWN_TTL)
				delete self._our_downs[iface];

		// l3-device learn-back switch; read before the no-op short-circuit so a
		// globals-only edit still updates it
		self.write_device = parsed.globals?.write_device ?? true;

		// zero-config autosetup gate (default on; wwand_globals option autosetup)
		self.autosetup = parsed.globals?.autosetup ?? true;

		// context_failed's rate limit, live on reload. Read HERE and not through
		// a daemon.set_* the reload path has to remember (the way hold_max is
		// done), because the value that matters is the one an operator raises to
		// contain a prober stuck in a loop — a knob that needs a restart to take
		// effect is no use in exactly that moment.
		if (parsed.globals?.failed_min_gap != null)
			self.failed_min_gap = +parsed.globals.failed_min_gap;

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
				let mi = mux_by_modem[cfg.modem] = mux_by_modem[cfg.modem] ?? { list: [], auto: 0 };

				push(mi.list, { id: cfg.mux_id, name: cfg.mux_link, mtu: cfg.mtu });

				if (cfg.mux_auto ?? false) {
					mi.auto++;
					mi.l3_name = cfg.l3_name;
				}

				// mux children are claimed under their own names — the raw
				// parent keeps its kernel name (false = never rename)
				l3_by_modem[cfg.modem] = false;
			}
			else if (cfg.modem && l3_by_modem[cfg.modem] == null) {
				l3_by_modem[cfg.modem] = cfg.l3_name;
			}
		}

		// MAY THIS MODEM BE RUN UNMUXED AFTER ALL? One auto-allocated channel
		// and nothing else. A second context has nowhere to go on a raw-IP
		// parent (one parent carries one session), and a pinned channel beside
		// it needs QMAP regardless — in both cases a modem that cannot mux is a
		// configuration error to report, not a fallback to take.
		//
		// It decides the PARENT'S NAME as well as the datapath's permission,
		// and the two have to be one answer. A muxed modem deliberately leaves
		// the parent on its kernel name because the CHILD takes the stable
		// wwandN; if the channel then turns out not to exist, that reasoning is
		// void and the interface would sit on `wwan0` — so an interface's
		// device name would depend on which modem is plugged in, which is the
		// exact instability stable L3 names exist to remove.
		//
		// So a demotable modem is named as if unmuxed, and the muxed outcome is
		// handled where it already was: netlink.setup() finds the parent
		// occupying the child's name and moves it to a raw one first (the
		// Chateau's "config update bounced the datapath through a channel-less
		// snapshot" path — same displacement, now reached on purpose).
		for (let mname, mi in mux_by_modem) {
			mi.demotable = (mi.auto == length(mi.list)) && (length(mi.list) == 1);

			if (mi.demotable && mi.l3_name)
				l3_by_modem[mname] = mi.l3_name;
		}

		// Idempotent reload: bounce only what actually changed. A modem's signature
		// folds in its mux set + stable L3 name (both derived from its contexts), so
		// adding/removing a mux channel counts as a modem change; a context's own
		// signature is just its cfg. Unchanged modems and unchanged contexts keep
		// running untouched — the whole point (no WAN bounce on an unrelated edit,
		// and a single modem's edit never disturbs the others or their siblings).
		// A plugin's options (`ext`, plugins.uc) are left out: the plugin reads
		// them from entry.ext on every tick (step 4 refreshes it), and nothing
		// in the modem's own state depends on them — switching a plugin feature
		// on must not bounce the connection it may be going to run over.
		// ...and so are its SIM overrides (`sims`, the wwand_sim sections it
		// may match): adding one — by hand, or wwand-rsim keeping a lender's
		// settings — restarted every modem, dropping its connections and, on
		// an MBIM modem, the QMI passthrough a plugin was just asking for
		// (HW-seen on the GL-X3000, 2026-09-27). Step 4 hands the new list to
		// the running modem and re-matches its card against it; a modem held
		// at SIM_BLOCKED is still restarted (step 1), because the override may
		// carry the PIN it is waiting for and only the SIM step tries one.
		// ...and its band lists (BAND_OPTS): the band command changes them in
		// place for the cost of one re-registration, so a restart would drop
		// the connections for nothing — and the settings editor writes them to
		// uci on every band edit of a modem that does not keep them itself.
		let modem_sig = (mn) => {
			let cfg = { ...(parsed.modems[mn] ?? {}) };

			delete cfg.ext;
			delete cfg.sims;

			for (let k in BAND_OPTS)
				delete cfg[k];

			return sprintf('%J', { cfg: cfg, mux: mux_by_modem[mn], l3: l3_by_modem[mn] });
		};
		let ctx_sig = (cn) => sprintf('%J', parsed.contexts[cn]);

		// 1) stop modems that are gone or changed (cascades to their contexts). A
		//    changed modem must rebuild its datapath, so its contexts bounce with it.
		let sims_changed = (mn) =>
			sprintf('%J', self.modems[mn]?.cfg?.sims) != sprintf('%J', parsed.modems[mn]?.sims);

		for (let mn in keys(self.modems))
			if (!parsed.modems[mn] || self.modems[mn]._sig != modem_sig(mn) ||
			    (sims_changed(mn) && self.modems[mn].modem?.state == 'SIM_BLOCKED'))
				stop_modem(mn);

		// 2) stop contexts that are gone or changed on a still-running modem (their
		//    modem stays up; only this one context re-applies — APN/auth/mtu/etc.).
		//    Contexts of the modems stopped above are already gone.
		// The attach profile is the MODEM's, programmed at its init — a changed
		// APN, PDP type or login on a running modem's interface would only
		// take effect at the modem's next init, while the context dials with
		// the new values at once. So the modems whose interface changed one of
		// those re-program it (reapply_sim) once the context is back: a test
		// APN set in the config otherwise changed nothing until a restart
		// (deborah-3, 2026-10-04).
		const ATTACH_OPTS = [ 'apn', 'pdp_type', 'auth', 'username', 'password' ];
		let attach_touched = {};

		for (let cn in keys(self.contexts)) {
			let old = self.contexts[cn].cfg, nw = parsed.contexts[cn];

			if (nw && old && old.modem == nw.modem && self.modems[nw.modem]?.modem &&
			    length(filter(ATTACH_OPTS, (k) => (old[k] ?? '') != (nw[k] ?? ''))))
				attach_touched[nw.modem] = cn;
		}

		for (let cn in keys(self.contexts))
			if (!parsed.contexts[cn] || self.contexts[cn]._sig != ctx_sig(cn))
				stop_context(cn);

		// 3) (re)start whatever is now missing — new sections and the ones just
		//    stopped. Untouched modems/contexts are already present and skipped.
		// a modem still retiring (its sessions being stopped) restarts when it
		// is through — stop_modem's finish runs the latest request; one that
		// is gone from the config now is not restarted at all
		for (let name, ret in self._retiring)
			ret.start = parsed.modems[name]
				? [ parsed.modems[name], mux_by_modem[name], l3_by_modem[name] ] : null;

		for (let name, cfg in parsed.modems)
			if (!self.modems[name] && !self._retiring[name])
				start_modem(name, cfg, mux_by_modem[name], l3_by_modem[name]);

		for (let name, cfg in parsed.contexts)
			if (!self.contexts[name])
				start_context(name, cfg);

		for (let mn, cn in attach_touched) {
			let m = self.modems[mn]?.modem;

			// a modem still in its init chain programs it there anyway
			if (!m || type(m.reapply_sim) != 'function' ||
			    index([ 'REGISTERING', 'READY' ], m.state) < 0)
				continue;

			log('notice', sprintf('interface %s: APN, PDP type or login changed — re-programming the attach profile of modem %s', cn, mn));
			m.reapply_sim();
		}

		// 4) stamp the applied signatures for the next reload's diff (idempotent for
		//    the ones that kept running: same config -> same signature).
		for (let mn in keys(self.modems)) {
			self.modems[mn]._sig = modem_sig(mn);
			self.modems[mn].ext = parsed.modems[mn]?.ext ?? {};

			// the SIM overrides, live (left out of the signature above) — and
			// matched again. Handing over the list alone changed nothing the
			// modem acts on: the dial reads `active_sim`, which was matched at
			// the last card read, so a new override was ignored, an edited one
			// kept its old values and a deleted one stayed in force.
			// ctx_settings' own re-match cannot catch it either: it fires only
			// when the modem's list differs from disk, and this makes them
			// equal. Matched on the card's identity, not on the previous match,
			// which is null exactly when a new override matters most.
			let m = self.modems[mn].modem;
			let changed = sims_changed(mn);

			if (self.modems[mn].cfg)
				self.modems[mn].cfg.sims = parsed.modems[mn]?.sims;

			if (m?.config) {
				m.config.sims = parsed.modems[mn]?.sims;

				if (changed && (m.info?.iccid != null || m.info?.imsi != null)) {
					let before = sim_effect(m.active_sim);

					m.active_sim = modem_common.match_sim_override(m.config.sims,
						m.info.iccid, m.info.imsi);

					// What the card in use gets has changed (its APN, PDP type,
					// credentials — or it gained or lost an override): apply it
					// the way a card re-read does. The attach APN lives in the
					// modem's attach profile, programmed only by reapply_sim, and
					// a running session keeps what it dialled with — so without
					// both an edited APN did nothing until the next card event,
					// and a card whose attach was being rejected stayed rejected
					// (HW-seen on 245, 2026-09-27). Edits for other cards change
					// nothing here and touch nothing.
					if (sim_effect(m.active_sim) != before)
						apply_sim_change(mn, m);
					else
						log('info', sprintf('modem %s: SIM overrides changed — none for the card in use', mn));
				}
			}
		}

		// the band lists, live — applied by the running modem (left out of
		// the signature above). A modem started by this reload already has
		// them in its cfg, so only an edit to a running one gets here.
		for (let mn in keys(self.modems)) {
			let e = self.modems[mn];

			if (!e.cfg || !parsed.modems[mn] || band_sig(e.cfg) == band_sig(parsed.modems[mn]))
				continue;

			for (let k in BAND_OPTS) {
				e.cfg[k] = parsed.modems[mn][k];

				if (e.modem?.config)
					e.modem.config[k] = parsed.modems[mn][k];
			}

			e.modem?.apply_config_bands?.(() => null);
		}

		for (let cn in keys(self.contexts))
			self.contexts[cn]._sig = ctx_sig(cn);

		// an untrusted start: the guess, once, for every interface (see
		// seed_admin_record)
		{
			let ifaces = {};

			for (let cn, cfg in parsed.contexts)
				if (cfg.interface)
					ifaces[cfg.interface] = true;

			seed_admin_record(keys(ifaces));
		}

		// board bring-up + periodic status tick (once): drives panel LEDs from the
		// primary modem's reg+signal and re-logs a waited-on modem every 30 s.
		if (!self._tick_started) {
			self._tick_started = true;
			deps.board?.init();

			let led_state = (entry) => {
				let m = entry?.modem, reg = m?.reg;
				let radio_ifs = reg?.radio_ifs;
				let on_rat = (type(radio_ifs) == 'array' && length(radio_ifs) > 0);
				// on LTE right now, for an LTE-labelled panel LED: NAS radio
				// interface 8 where the backend has radio_ifs (QMI, MBIM over
				// the passthrough), else the RAT it named (rat_label, NCM's
				// reg.mode/tech). 5G NSA keeps its LTE anchor in radio_ifs.
				let rat_txt = lc(sprintf('%s', m?.rat_label ?? reg?.mode ?? reg?.tech ?? ''));
				let lte = (on_rat && index(radio_ifs, 8) >= 0) || (index(rat_txt, 'lte') >= 0);
				return {
					present: !!m && m.state != 'ABSENT',
					registered: is_registered(reg),
					radio: on_rat ? radio_ifs[0] : null,
					lte: lte,
					roaming: reg?.roaming ?? false,
					bars: deps.board ? deps.board.bars(m?.signal) : 0,
				};
			};

			// The one way the daemon itself restarts the router. Loud when it
			// cannot: the previous inline `deps.recovery_fx?.run?.(['reboot'])`
			// turned a missing executor into silence right after a log line
			// that said "rebooting", which is how a vanished modem kept a router
			// offline for 37 hours (see deps.uc, recovery_fx).
			let reboot_router = (why) => {
				let run = deps.recovery_fx?.run;

				if (type(run) != 'function') {
					log('err', sprintf('cannot reboot (%s): no command executor is wired (deps.recovery_fx)', why));
					return false;
				}

				uloop.timer(self.timing?.reboot_delay ?? 5000, () => run([ 'reboot' ]));
				return true;
			};
			self._reboot_router = reboot_router;

			let tick;
			tick = () => {
				let now = time();

				// A modem that WAS running and then vanished is not a boot race.
				// The hardware went away under us, and nothing on the wire will
				// bring it back — measured on a Zyxel NR7101 (2026-09-07): the
				// modem disconnected mid-operation and was still gone 13 hours
				// later, while wwand logged "waiting for hotplug" every 30 s and
				// touched nothing. The recovery ladder could not help, because it
				// hangs off the MODEM object that detach destroys and counts
				// CONNECTION attempts, of which there are none without a modem.
				//
				// So escalate on time instead, through the same two actions the
				// ladder's top rungs use. Both were measured on that board: the
				// reset GPIO does work (line high -> USB disconnect in under 5 s,
				// low -> re-enumeration in ~10 s), but it did NOT revive the modem
				// from that hung state — only a reboot did. Hence both rungs, in
				// that order; the cheap one first, and the expensive one still
				// reachable, which is the whole point.
				// once per modem object, as soon as its card has been read
				for (let name, entry in self.modems) {
					let m = entry.modem;

					if (m && index([ 'CONFIGURE_NET', 'REGISTERING', 'READY', 'SIM_BLOCKED' ], m.state) >= 0)
						probe_euicc(entry, m);
				}

				for (let name, entry in self.modems) {
					let act = vanish_action(entry, now, self.timing);

					if (!act)
						continue;

					let gone = now - entry.waiting_since;

					if (act == 'reset') {
						entry._vanish_rung = 1;

						// A MODEM THAT LEFT THE BUS NEEDS ITS POWER, NOT ITS RESET
						// LINE, where the board can switch the power. Measured on
						// an NR7101 (2026-09-25): neither a reset pulse, nor a warm
						// reboot, nor a USB port or xHCI reset brought a vanished
						// modem back; removing its supply did. So when the board
						// has a usable power line for THIS modem, the vanish step
						// cycles it. A per-modem `reset_gpio` is an explicit choice
						// and is honoured, and a multi-modem box never gets the
						// board's shared lines (board_gpio_ok). The recovery ladder
						// for a modem that is PRESENT but silent keeps the reset
						// pulse — there the pulse is what works (ddimension/wwand#40).
						let use_power = deps.board?.has_power && board_gpio_ok() && !entry.cfg?.reset_gpio;

						if (use_power) {
							log('warn', sprintf('modem %s: gone for %ds — power-cycling it through the board', name, gone));

							if (deps.board.power_cycle(entry.cfg?.repower_time ? +entry.cfg.repower_time * 1000 : null))
								continue;

							log('warn', sprintf('modem %s: the power cycle did not start — falling back to the reset line', name));
						}

						log('warn', sprintf('modem %s: gone for %ds — pulsing the board reset', name, gone));

						// Say WHICH of the two reasons it was. On a box with more
						// than one modem the board's own lines are refused
						// (board_gpio_ok) because they would hit the wrong
						// hardware — but status() still reports has_power: true
						// for the board, so "no usable GPIO" reads as a
						// contradiction and hides the remedy. Field-seen on the
						// sponsor's 3-modem WH3000 (2026-09-08), where an E182E
						// dropped off the bus with a USB -71 and the escalation
						// had nothing it was allowed to pulse.
						if (!board_repower(entry.cfg)) {
							if (!entry.cfg?.reset_gpio && !board_gpio_ok() && deps.board)
								log('warn', sprintf('modem %s: the board reset/power line is shared and this box has %d modems, so it would hit the wrong hardware — set `option reset_gpio` on this modem to allow a reset',
									name, length(keys(self.modems))));
							else
								log('warn', sprintf('modem %s: no usable reset or power GPIO for this board', name));
						}
					}
					else {
						entry._vanish_rung = 2;

						if (act == 'reboot') {
							log('err', sprintf('modem %s: gone for %ds and neither the reset nor the power cycle brought it back — rebooting', name, gone));
							reboot_router(sprintf('modem %s vanished', name));
						}
						else {
							log('warn', sprintf('modem %s: gone for %ds and neither the reset nor the power cycle brought it back; `option failreboot 0` keeps the router up', name, gone));
						}
					}
				}

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

				// optional plugins (plugins.uc): a no-op when none is installed
				self.plugins_tick?.();

				// a radio a plugin parked, which no plugin holds any more (it
				// stopped, failed, forgot): handed back as the plugin would
				for (let name, entry in self.modems)
					if (entry?.modem?._plugin_held && !self.plugins_radio_hold?.(name)) {
						log('notice', sprintf('modem %s: nothing holds its radio off any more — handing it back', name));
						self._plugin_radio(name, true, null);
					}

				// in memory only, but a surprise in a modem's state must not
				// end the daemon from inside its tick
				try { inventory_refresh(); }
				catch (e) { log('warn', sprintf('SIM inventory refresh failed (%s)', e)); }

				if (deps.board) {
					let first = null;
					for (let n, e in self.modems) { first = e; break; }
					deps.board.leds(led_state(first));
				}

				self._tick_timer = uloop.timer(10000, tick);
			};
			// a test seam: the tick is otherwise reachable only through a 10 s
			// timer, and a decision reachable only through a timer is one the
			// suite cannot check (see vanish_action above)
			self._tick = () => tick();

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
	// the proto-shim settings payload) — lives in ctx_settings.uc; bound as
	// locals so the call sites below read unchanged.
	ctx_settings.install(self, {
		log: log,
		read_config: deps.read_config,
		datapath_fx: deps.datapath_fx,
	});

	let refresh_context_cfg = self._refresh_context_cfg;
	let apply_mtu = self._apply_mtu;
	let apply_iface_id = self._apply_iface_id;
	let enable_ipv6 = self._enable_ipv6;
	let settings_result = self._settings_result;

	self.context_up = function(ref, cb) {
		let name = self.resolve_context(ref);
		let entry = name ? self.contexts[name] : null;

		// an up is the operator's intent whatever it is answered with: a
		// record kept past an up that failed (modem absent, a context not
		// built yet) would outlive the ifup that ended it. The same for our
		// own down: the up answers it, and a marker kept past it sent an
		// ifdown within its window — the modem still gone — down
		// context_down's our_down branch, unrecorded, and the interface came
		// back against the operator once the modem did.
		set_admin_down(entry ?? iface_ref(ref), false);
		clear_our_down(entry ?? iface_ref(ref));

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

		// A SIM that is not usable (yet) makes the shim BLOCK the interface:
		// on sim_blocked it sends proto_block_restart, which sets netifd's
		// autostart off (proto-ext.c:547-550, netifd 2026.07.08), and nothing
		// restarts it after that. During an eSIM profile switch or a card
		// change the modem is without a card for a moment, and a setup that
		// lands then — netifd's own restart included, which ended the give-up
		// the SIM block had set (the up just above) — left the interface down
		// for good once the new profile registered. The block is therefore
		// OURS: noted as a give-up, so the next `registered` re-arms the
		// interface and kicks it (modem_registered, which also marks the down
		// as ours then). NOT marked as our down here: wwand issued no down,
		// and the marker would send an operator's ifdown within its window
		// down context_down's `our_down` branch — no operator record, the
		// give-up kept, and the interface back up against them. The shim's
		// PIN_FAILED error is the evidence operator_down reads instead.
		// Only while this entry is still the context: an activation cannot be
		// cancelled, so its answer can land after a reload replaced the entry,
		// and a give-up written then would be persisted for an interface whose
		// new context never gave up — re-arming it after the next restart,
		// against whatever the operator did meanwhile.
		let actx = entry.ctx;
		let answer = (err, res) => {
			if (err?.error == 'sim_blocked' && self.contexts[name] === entry && entry.ctx === actx) {
				entry.wanted = false;
				set_giveup(entry, true);
				log('notice', sprintf('interface %s: the SIM is not usable yet — netifd holds it down; it comes back when the modem registers',
					entry.cfg.interface ?? name));
			}

			cb(err, res);
		};

		// ...an up (an operator's ifup, or our own kick landing) re-arms
		// netifd's autostart: whatever down we issued is answered, and a
		// give-up is over. Kept past it, the next ifdown within the marker's
		// window was read as OUR teardown and the give-up brought the
		// interface back against the operator (found by audit, 2026-09-27).
		clear_our_down(entry);
		set_giveup(entry, false);
		set_admin_down(entry, false);

		// Parked by `option lowpower` on the last context-down: the radio is off,
		// so activating now would dial into a modem that cannot register. Wake it
		// first. Parking without this is worse than never parking — the interface
		// would stay down until something else happened to power the radio.
		let m = self.modems[entry.cfg?.modem];

		// ...and none at all while the modem's card is in use by another
		// modem (a plugin lent it): its radio must stay off, parked or not —
		// a modem re-initialised meanwhile comes up online and unparked, and
		// a dial then registers one IMSI twice. Refused with the reason; the
		// shim retries slowly (radio_held). Said once per lending, not per try.
		let hold = self.plugins_radio_hold?.(entry.cfg.modem);

		if (hold) {
			if (entry._held_logged != hold)
				log('notice', sprintf('modem %s: not bringing %s up — %s', entry.cfg.modem, name, hold));
			entry._held_logged = hold;
			return cb({ error: 'radio_held', detail: hold });
		}

		entry._held_logged = null;

		// detached by the operator (netsel_ops modem_detach): an ifup does not
		// attach — unlike a parked radio, which it wakes — because the detach
		// was the operator's word on the whole modem and `modem_attach` is
		// theirs to give. Refused with the reason; the shim retries slowly.
		if (m?.modem?.detached)
			return cb({ error: 'detached', detail: sprintf('modem %s is detached from the network (wwandctl attach)', entry.cfg.modem) });

		if (m?.modem?.lowpower_parked && m.modem.set_opmode) {
			log('notice', sprintf('modem %s: waking the parked radio for %s',
				entry.cfg.modem, name));

			return m.modem.set_opmode('online', (err) => {
				// Failing to wake is worth saying, but not worth refusing the
				// bring-up over: the modem may already be online (someone else
				// woke it), and the activation below reports its own failure.
				if (err)
					log('warn', sprintf('modem %s: wake-up failed: %J',
						entry.cfg.modem, err));

				activate(name, answer);
			});
		}

		activate(name, answer);
	};

	// l3 netdev for a context: parent netdev, MBIM VLAN sub-device or QMAP mux
	// child per protocol/mux. Forward-declared (line ~143) so on_modem_event's
	// learn_device path can reference it without the ucode TDZ trap.
	derive_netdev = (entry) => {
		let mentry = self.modems[entry.cfg.modem];
		let netdev = mentry?.netdev;

		if (mentry?.protocol == 'mbim') {
			// MBIM: session 0 is the parent netdev, sessions > 0 are VLAN
			// sub-devices named after the context's mux_link so netifd's device
			// binding matches.
			//
			// The EFFECTIVE channel, like the QMI branch below — this read the
			// raw `cfg.mux_id` while status read the effective one, so the two
			// answered differently for the same interface. Harmless while MBIM
			// could not demote; a lone `auto` channel now resolves to session 0
			// (the untagged parent), and naming a vlan child that was never
			// built would hand netifd a device it can never bind.
			let eff = cfgmod.effective_mux_id(entry.cfg, mentry?.modem?.datapath);

			if (eff > 0 && netdev)
				netdev = entry.cfg.mux_link ?? sprintf('%s.%d', netdev, eff);
		}
		else {
			// QMAP muxed contexts use their mux child link — but an `auto`
			// channel on a modem that turned out to have no QMAP was never
			// built, and naming a child that does not exist would hand netifd
			// a device it can never bind. cfgmod.effective_mux_id() is the one
			// place that rule lives; context.uc asks it the same question
			// before binding WDS, and the two must not drift.
			let eff = cfgmod.effective_mux_id(entry.cfg, mentry?.modem?.datapath);

			if (eff > 0 && netdev)
				netdev = entry.cfg.mux_link ?? sprintf('%sm%d', netdev, eff);
		}

		return netdev;
	};

	self._up_result = function(name, entry) {
		let netdev = derive_netdev(entry);

		apply_mtu(name, entry, netdev);
		apply_iface_id(name, entry, netdev);
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

	// Declared HERE, before context_down uses it: a ucode `function` further
	// down is not hoisted into an enclosing function body, so the call failed
	// at RUN time with "undeclared variable" rather than at parse time.
	//
	// `option lowpower`: park the RADIO once nothing on this modem is up. For
	// battery and solar installs, where an idle modem still costs a couple of
	// watts holding a registration nobody is using.
	//
	// Only on an OPERATOR down, never on a transient loss — those keep the
	// interface up by design and are exactly when the radio must stay on. And
	// only when no OTHER context of the same modem still wants to be up: two
	// interfaces commonly share one modem, and putting the radio to sleep for
	// one of them would take the other down with it.
	//
	// Coming back is netifd's job: an ifup runs the normal bring-up, which sets
	// the operating mode online again.
	let maybe_lowpower = (entry) => {
		let mref = entry?.cfg?.modem;
		let m = mref ? self.modems[mref] : null;

		if (!m?.modem || !m.cfg?.lowpower || !m.modem.set_opmode)
			return;

		// Only a modem that is FINISHED coming up. The init chain sets the
		// operating mode online itself, so parking the radio from here while
		// that is still running is two writers on one setting — and which one
		// lands last is timing. A modem that is not READY is either on its way
		// there (it will be up in a moment and a later down parks it) or on its
		// way out (nothing to park).
		if (m.modem.state != 'READY')
			return;

		for (let n, e in self.contexts)
			if (e !== entry && e.cfg?.modem == mref && e.wanted)
				return;   // another interface on this modem still wants the radio

		log('notice', sprintf('modem %s: no context up and `option lowpower` is set — parking the radio',
			mref));

		m.modem.set_opmode('low_power', (err) => {
			if (err)
				log('warn', sprintf('modem %s: low-power failed: %J', mref, err));
		});
	};

	self.context_down = function(ref, cb) {
		let name = self.resolve_context(ref);
		let entry = name ? self.contexts[name] : null;

		// No context to take down — the modem is absent, or the interface's
		// modem is not configured — but this is still the operator's ifdown
		// (netifd tears a pending interface down through the shim as well,
		// proto-ext.c:162-170). Unrecorded, the shim's WAITING_MODEM error
		// that stays on the interface read as OUR block once the modem came,
		// and the interface was brought up against them.
		if (!entry?.ctx) {
			// ...unless it is the teardown of a down wwand issued itself (a
			// hold expiry, a SIM block) that reached us after the modem had
			// gone: recorded as the operator's, that interface would stay
			// down for good now that only the record makes an ifdown
			if (entry && our_down(entry))
				return cb({ error: 'no_such_context', ref: ref });

			if (entry) {
				entry.wanted = false;
				set_giveup(entry, false);
			}
			set_admin_down(entry ?? iface_ref(ref), true);
			return cb({ error: 'no_such_context', ref: ref });
		}

		// our own stuck-pending reset (registered handler): self-inflicted teardown,
		// not operator intent — keep `wanted` and restart the aborted activation once
		// the teardown settles (its up() callback never fires, so nothing else does).
		if (entry._reset_pending) {
			entry._reset_pending = false;

			// Our own reset of a setup netifd holds 'pending'. Meant for an
			// IDLE context (an orphaned setup); but the status answer that
			// decides it arrives asynchronously, and by then the queued
			// activation may already be dialling or connected. Stopping THAT
			// session throws away a working connection — and on some firmware
			// is not survivable: an MC7710 (SWI9200X_03.05.29) answered no
			// START_NETWORK after a stop followed at once by a new dial, until
			// the modem was reset (deborah-3, 2026-10-04). So a live session
			// stays; the `up` that follows takes it over through setup.
			if (entry.ctx.state != 'IDLE') {
				log('info', sprintf('interface %s: reset of a pending setup — keeping the %s session for the setup that follows',
					entry.cfg.interface, lc(entry.ctx.state)));
				return cb(null, {});
			}

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
			set_giveup(entry, true);
			clear_reconnect(name);
			return entry.ctx.down(() => cb(null, {}));
		}

		// ...and the teardown that follows a down WE issued (a SIM block):
		// netifd calls back through the proto shim with nothing to tell it
		// from an operator's, so the marker says it — the give-up stands
		if (our_down(entry)) {
			entry.wanted = false;
			clear_reconnect(name);
			return entry.ctx.down(() => {
				cb(null, {});
				maybe_lowpower(entry);
			});
		}

		// netifd tore the interface down (admin/config) → no longer wanted; stop
		// reconnect and clear any stale re-arm marker (operator intent wins).
		entry.wanted = false;
		set_giveup(entry, false);
		set_admin_down(entry, true);
		clear_reconnect(name);
		entry.ctx.down(() => {
			cb(null, {});
			maybe_lowpower(entry);
		});
	};


	// An external prober (watchcat's `option script`, an mwan3 hotplug, cron)
	// declaring this connection dead. L3 reachability is deliberately NOT
	// measured in here: with mwan3 or a policy rule steering, the source address
	// and the table are decided elsewhere and can change under the daemon, so a
	// probe it built itself would fail in the direction of FALSE ALARMS — tearing
	// down a working session because its own packet took the wrong path. That is
	// the expensive mistake; missing a dead session merely costs the next probe
	// (ddimension/wwand#13, and the reporter is who made that the deciding
	// argument).
	//
	// What the daemon has and no external tool can reach is the recovery ladder:
	// redial, opmode cycle, modem reset, board power-cycle / reset GPIO, reboot.
	// So the division is prober outside, rungs inside. `ifup` cannot express this
	// (on a no_proto_task interface the session is live and the interface already
	// up, so it changes nothing) and `context_down` says the opposite of what a
	// prober means — it records OPERATOR intent and parks the context.
	self.context_failed = function(ref, reason, cb) {
		let name = self.resolve_context(ref);
		let entry = name ? self.contexts[name] : null;

		if (!entry?.ctx)
			return cb({ error: 'no_such_context', ref: ref });

		// Rate limit, because this drives HARDWARE. A prober with a stuck loop
		// or a one-second cron would otherwise walk a healthy modem up to the
		// reboot rung in under a minute. The bound is per context and generous
		// next to any sane probe interval; a caller that trips it gets told so
		// rather than silently ignored.
		let now = time();
		let since = now - (entry._failed_at ?? 0);
		let min_gap = self.failed_min_gap ?? self.timing?.failed_min_gap ?? 30;

		if (entry._failed_at != null && since < min_gap)
			return cb(null, { throttled: true, retry_in: min_gap - since,
			                  interface: entry.cfg?.interface });

		entry._failed_at = now;

		log('warn', sprintf('interface %s: declared dead by %s — redialling and counting it against the recovery ladder',
			entry.cfg?.interface ?? name,
			(reason != null && reason != '') ? reason : 'an external monitor'));

		let modem = entry.ctx.modem;

		// ORDER MATTERS, and the obvious order is wrong. `ctx.down()` emits its
		// 'down' event BEFORE invoking the callback (context.uc, context_mbim.uc,
		// context_ncm.uc all do), and the daemon's own handler for that event
		// calls enter_reconnecting() for a context that is still `wanted` — which
		// this one deliberately is. Downing first therefore starts an activation
		// against the modem a moment before the ladder decides to opmode-cycle,
		// reset or power-cycle it: the redial races the recovery it asked for.
		//
		// So climb first. The rung is chosen (and executed) while the session is
		// still up, and the teardown that follows re-enters the reconnect path
		// with the modem's state already reflecting whatever the rung did —
		// retry_activate simply schedules until it is READY again.
		let redial = () => {
			if (entry.ctx.state == 'CONNECTED')
				return entry.ctx.down(() => null);

			// nothing to tear down; ask for the reconnect explicitly, since no
			// 'down' event will arrive to trigger it
			if (entry.wanted)
				enter_reconnecting(name);
		};

		if (!modem?.note_connect_failure) {
			redial();
			return cb(null, { interface: entry.cfg?.interface, action: null });
		}

		modem.note_connect_failure((action) => {
			redial();
			cb(null, { interface: entry.cfg?.interface, action: action ?? null });
		});
	};

	self.context_status = function(ref) {
		let name = self.resolve_context(ref);
		let entry = name ? self.contexts[name] : null;

		if (!entry?.ctx)
			return { error: 'no_such_context', ref: ref };

		return entry.ctx.status();
	};

	self.status = function() {
		// One place that turns the persisted counters into something readable.
		// `rung` is the FIRED index (how many rungs have gone off this outage),
		// which is what makes "next" meaningful — the ladder fires each rung
		// once per outage on a threshold crossing, so attempts alone cannot say
		// whether one is still pending.
		// monotonic, like the clock recovery.uc stamps outage_since with
		let due_in = (at) => { let d = at - clock(true)[0]; return (d > 0) ? d : 0; };

		let recovery_view = (name, entry) => {
			let c = entry.modem?.counters;

			if (!c)
				return null;

			let fired = +(c.rung ?? 0);
			let attempts = +(c.attempts ?? 0);
			let table = recoverymod.rungs(entry.cfg?.failreboot ?? 100);
			let next = null;

			for (let i = 0; i < length(table); i++)
				if (i >= fired) {
					next = { at: table[i].at, action: table[i].action,
					         in: (table[i].at > attempts) ? (table[i].at - attempts) : 0 };
					break;
				}

			return {
				attempts: attempts,
				fired: fired,
				// seconds the card-resetting rungs are still held back after a
				// subscription change (recovery.uc hold_for_card), null = none
				card_hold: entry.modem?.recovery?.card_hold_left?.() || null,
				// gated off until one exchange has succeeded in the selected
				// protocol — a misdetected modem must never be repowered
				armed: !!c.proto_ok,
				// ...with ONE exception, so "not armed" stops being the whole
				// truth on a board that exports the modem's own RESET line: the
				// ladder may pulse it once per outage (recovery.uc,
				// unarmed_reset_line). Reported as spent/available rather than
				// as a capability, because what an operator asks at this point
				// is whether anything is still going to happen by itself.
				// Only a modem with its OWN `reset_gpio` has it: the pulse never
				// takes the board default (see reset_line where the modem is
				// built), so reporting "available" from the board's line would
				// promise an action that is not going to happen. The same holds
				// for `unarmed_reset_after 0`, which switches it off.
				unarmed_reset: (c.proto_ok || !entry.cfg?.reset_gpio ||
				                +(entry.cfg?.unarmed_reset_after ?? 300) <= 0) ? null
					: (c.unarmed_reset ? 'spent' : 'available'),
				// why there is none on an unarmed modem, so the page does not
				// blame a missing GPIO for a pulse the operator switched off
				unarmed_reset_off: c.proto_ok ? null
					: !entry.cfg?.reset_gpio ? 'no_reset_gpio'
					: (+(entry.cfg?.unarmed_reset_after ?? 300) <= 0) ? 'disabled' : null,
				// with 'no_reset_gpio': the board's own reset line, if it has
				// one. The pulse deliberately does not take it — on a box with
				// a second modem it may be that one's — and "no reset GPIO"
				// alone read as "this board has none" to an NR7101 owner whose
				// explicit resets pulse exactly that line (#40). Through the
				// modem's own config, so it names exactly the line an explicit
				// reset would take: none for `reset_gpio ''`, none on a box
				// with more than one modem (board_gpio_ok).
				board_reset_gpio: (!c.proto_ok && !entry.cfg?.reset_gpio) ? board_reset_line(entry.cfg) : null,
				// seconds until that pulse is due (0 = on the next failed
				// attempt), null when it is not pending — the ladder counts time
				// since the outage began, so attempts cannot answer "when"
				unarmed_reset_in: (c.proto_ok || !entry.cfg?.reset_gpio || c.unarmed_reset ||
				                   !c.outage_since || +(entry.cfg?.unarmed_reset_after ?? 300) <= 0) ? null
					: due_in(c.outage_since + +(entry.cfg?.unarmed_reset_after ?? 300)),
				rungs: map(table, (r, i) => ({ at: r.at, action: r.action,
				                               fired: i < fired })),
				next: next,
				// what `usb_repower` would really do on THIS box for THIS modem
				hardware: self.repower_plan ? self.repower_plan(name) : null,
			};
		};

		let modems = {};

		for (let name, entry in self.modems) {
			modems[name] = {
				device: entry.device,
				netdev: entry.netdev,
				protocol: entry.protocol,
				state: entry.modem?.state ?? 'UNRESOLVED',
				// The daemon's own note first — "package not installed", "device
				// owned by interface X" — because those describe a modem that
				// is not running at all and there is then no backend to ask.
				// Otherwise whatever the BACKEND has to say, which is how a
				// hardware radio switch reaches status and LuCI: modem_mbim
				// sets it on the modem object, and that object is not this
				// entry. The two were never joined, so the note existed and
				// nobody could see it.
				control_note: entry.control_note ?? entry.modem?.control_note,
				// The radio's two switches, as the modem last reported them
				// (MBIM RADIO_STATE — hardware and software are separate, and
				// only the software one is ours to change). Absent on a backend
				// that does not report it, which is every non-MBIM one today.
				radio: entry.modem?.radio,
				// per-slot UICC state, keyed by slot index, as the modem last
				// said. Event-driven on MBIM; absent elsewhere.
				slot_state: entry.modem?.slot_state,
				apdu_backend: entry.modem?._apdu_be,   // mbim | qmi | at (once probed)
				pin1: entry.modem?.pin1,
				sim_block: entry.modem?.sim_block,  // { reason, retries } when SIM_BLOCKED
				// card-side diagnostics from the UIM indications: a busy card
				// (reads fail until it clears) and the last named card event
				// (session closed and why / internal recovery / activation)
				sim_busy: entry.modem?.sim_busy ?? false,
				sim_note: entry.modem?.sim_note ?? null,
				// Die/board temperature, read over the AT side channel. It lived
				// only on the `modem_cells` reply, and BOTH consumers reached for
				// it on the status object instead — so `wwandctl status` and the
				// LuCI temperature row have never rendered once. It belongs here:
				// it is a property of the modem, not of the serving cell, and it
				// now sits next to the mitigation state it wants to be read with.
				temperature: entry.modem?.temperature ?? null,
				// the modem's own thermal mitigation (QMI TMD): which parts of it
				// are holding back and how far. `mitigated` is the one-bit answer
				// to "is throughput down because the modem decided so".
				thermal: entry.modem?.thermal ? {
					mitigated: entry.modem.thermal.mitigated,
					level:     entry.modem.thermal.level ?? 0,
					// only the devices actually throttling, plus how many exist
					// in total — thirty "level 0" rows per poll help nobody
					active:    entry.modem.thermal.active ?? [],
					devices:   length(entry.modem.thermal.devices ?? []),
				} : null,
				// --- MBIMEx (v2/v3) additions, null on every other backend ---
				//
				// PUBLISHED, NOT ACTED ON. All of these are decoded from
				// messages the MBIM backend already exchanges; nothing decides
				// anything on them. A field the daemon reads and keeps to
				// itself is a shape this tree has been caught in before
				// (max_sessions sat parsed-and-hidden from the day the backend
				// was written), so they go out with the rest.
				//
				// packet_service: frequency range (FR1/FR2), data subclass —
				// the bitmask that separates 5G NSA from SA outright rather
				// than by inference — and the tracking area.
				packet_service: entry.modem?.packet_service ?? null,
				// attach_info: what the EPS attach used, and under v3 the 3GPP
				// cause when it was refused. Read on a registration timeout,
				// which is the case it exists to explain.
				attach_info: entry.modem?.attach_info ?? null,
				// carrier configuration (MBN) over MBIM rather than QMI PDC,
				// and the modem's last wake reason. Both v3-only and both
				// optional: a firmware without them leaves these null — the
				// RM520N-GL answers NotInitialized and NoDeviceSupport
				// respectively (measured 2026-09-20).
				modem_config: entry.modem?.modem_config ?? null,
				wake_reason: entry.modem?.wake_reason ?? null,
				manufacturer: entry.modem?.info?.manufacturer,
				model: entry.modem?.info?.model,
				revision: entry.modem?.info?.revision,
				// firmware version, backend-neutral: MBIM device caps firmware_info,
				// else the QMI DMS / AT CGMR revision
				firmware: entry.modem?.info?.firmware ?? entry.modem?.info?.revision,
				imei: entry.modem?.info?.imei,
				// MBIM ONLY: how many data sessions the modem declares (DEVICE_CAPS
				// MaxSessions; null on QMI and NCM, which have no such field).
				// Parsed since the backend was written and never surfaced —
				// which matters because the session a context activates is the
				// EFFECTIVE wire id (context_mbim's wire_session(), the mux
				// channel mapped through the datapath's map_ids), and a wire id
				// >= MaxSessions is a request the modem may refuse. Nothing in
				// the status told you the number to compare it against. Found
				// while debugging a refused CONNECT on an RM520N-GL (which
				// declares 15, so session 1 was never the problem), 2026-09-19.
				max_sessions: entry.modem?.info?.max_sessions,
				// WHICH MESSAGE LAYOUT EVERY MBIM DECODER IS USING, which is
				// what the negotiated MS extension version decides — the v1
				// Base Stations Info has no NR arrays at all and every pointer
				// after SystemType sits four bytes earlier, so the same CID
				// answers a different structure depending on this one number
				// (codec/mbim_schema/ms_basic_connect_ext.uc, decode_base_
				// stations_info). It was agreed once at open and written to a
				// single log line (mbim_client.uc:203-205), which is nowhere
				// when you are comparing wwand's reading against mbimcli's an
				// hour later — and mbimcli opens v1 unless it is given
				// --device-open-ms-mbimex-v3, so the two talk about different
				// messages and neither side can see that from the output.
				// Cost a round of ddimension/wwand#30 exactly that way,
				// 2026-09-23.
				//
				// NULL MEANS THE DECODERS ARE ON THE v1 LAYOUTS, and it covers
				// three cases the client cannot tell apart anyway: not an MBIM
				// modem, the handshake refused, and the handshake not answered
				// yet — mbim_client keeps 0 for all of the latter
				// (mbim_client.uc:228). `protocol` separates the first from
				// the other two, and the open-time log line says which of
				// those two it was. What null must NOT become is "1.0", which
				// would claim an extension version the modem agreed to.
				mbimex: mbimex_text(entry.modem?.mbim?.mbimex_version),
				imsi: entry.modem?.info?.imsi,
				iccid: entry.modem?.info?.iccid,
				// the card's label from its wwand_sim (`option name`), or null
				sim_name: entry.modem?.active_sim?.name ?? null,
				// the card's ISD-R about itself, once read (probe_euicc):
				// { sgp32, ipae_supported, svn, ipa: 'ipae' | 'ipad' | null }
				euicc: (entry._euicc_for === entry.modem) ? (entry.euicc ?? null) : null,
				msisdn: entry.modem?.info?.msisdn,
				usb: entry.modem?.info?.usb,
				identity_mismatch: entry.modem?.identity_mismatch,   // {expected,found} if the pinned IMEI didn't match
				at_tty: entry.modem?.at_tty,
				// at2 released for external tools
				at2_released: entry.modem?.at2_released,
				// the modem's NMEA port, reported for gpsd to be pointed at.
				// wwand never opens it and never links it — asking the daemon is
				// the interface, so a re-enumerated modem answers with its new tty
				gps_port: entry.modem?.gps_tty,
				// the modem's Qualcomm diagnostic (DM/DIAG) node, reported for
				// the optional wwand-qlog add-on to point QLog at. Same rule as
				// gps_port: wwand resolves it and never opens it, so a
				// re-enumerated modem answers with its new node. Null when no
				// 'qcdm' role is known for this USB id and no `option diag_port`
				// is set — `wwandctl qlog --port` is then the way in.
				diag_port: entry.modem?.diag_tty,
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
				config_warnings: band_warnings(entry),
				// FCC-lock probe (Fibocom GTFCCEFFSTATUS?): 0/1/2, null = not probed
				fcc_lock: entry.modem?.fcc_lock,
				// eSIM surface from the bring-up refresh (eUICC active only)
				esim: entry.modem?.esim_info ?? null,
				// a plugin that manages this card (plugins.uc esim_guard):
				// the eSIM UI offers no profile changes while it does
				esim_managed_by: self.esim_guard?.(name, 'enable')?.by,
				// the datapath that actually came up (rmnet/qmimux/vlan/raw_ip
				// or a plugin name) — with 'auto' able to land on a plugin,
				// "which one won" must be visible without reading the log
				datapath: entry.modem?.datapath?.backend,
				proto_errors: entry.modem?.counters?.proto_errors,
				qmi_errors: entry.modem?.counters?.proto_errors,   // deprecated alias
				// QMI client IDs wwand holds on the modem, per service
				// (modem.uc alloc/release) — the evidence when a small
				// client table runs full
				qmi_clients: entry.modem?.qmi_clients,

				attempts: entry.modem?.counters?.attempts,
				// false while the recovery hardware ladder (opmode/reset/repower/
				// reboot) is gated off: no protocol exchange has succeeded with
				// the current control protocol yet — a misdetected modem must
				// not be repowered
				// Two implementations of this invariant were developed in
				// parallel and met at this merge; the counter kept is
				// `proto_ok` (the reviewed one, with the gate above the whole
				// ladder and at the primitives), the PUBLIC name kept is
				// `proven` (the better name, and already what the status test
				// and any consumer expect). Coerced, because a status field
				// should be a bool rather than the 0/1 the state file carries.
				proven: !!entry.modem?.counters?.proto_ok,

				// THE LADDER, not just the counter. `attempts` alone told an
				// operator a number; what they need when a box is misbehaving
				// is which escalations have already fired, what comes next and
				// how far away it is — and, at the hardware rung, WHICH of the
				// two actions their box would actually take. A Chateau with two
				// modems and no per-modem reset_gpio cannot use the board
				// power-cycle at all (hwops.board_gpio_ok), and nothing said so
				// anywhere.
				recovery: recovery_view(name, entry),
				// rows optional packages report about this modem (plugins.uc
				// plugins_status); rendered generically by LuCI and wwandctl
				plugins: self.plugins_status ? self.plugins_status(name) : [],
				// why a plugin holds the radio off (plugins.uc radio_hold): its
				// card is lent to another modem, or its remote SIM is not in use
				// yet. Its interfaces fail with RADIO_HELD meanwhile, and the
				// status pages say why in one place, whichever plugin it is.
				radio_held: self.plugins_radio_hold?.(name) ?? null,
				// detached from the network by the operator (modem_detach),
				// until modem_attach; its interfaces fail with DETACHED
				detached: !!entry.modem?.detached,
				remote_sim: remote_sim_support(entry.protocol, entry.modem),
				// ...and when that hold cannot be honoured: the radio is on
				// although the line above says it is held (note_unholdable)
				radio_hold_error: (entry.modem?._hold_unsupported != null && self.plugins_radio_hold?.(name))
					? sprintf('cannot hold this modem (%s)', entry.modem._hold_unsupported) : null,
			};
		}

		let contexts = {};

		for (let name, entry in self.contexts) {
			contexts[name] = {
				interface: entry.cfg.interface,
				modem: entry.cfg.modem,
				// what is in force, so it cannot disagree with l3_device on
				// the next line (a demoted `auto` context reports 0 and the
				// parent, not channel 1 and a device that does not exist)
				mux_id: cfgmod.effective_mux_id(entry.cfg,
					self.modems[entry.cfg.modem]?.modem?.datapath),
				l3_device: derive_netdev(entry),
				state: entry.ctx?.state ?? 'UNBOUND',
				last_error: entry.ctx?.last_error,
				// WHAT THE MODEM HANDED US, which until now existed only in the
				// `ipv4 config:` line logged once at connect time. That line
				// rotates away, and two users then had no way to answer the
				// obvious question about their own box: the interface shows no
				// gateway — did the modem not give one, or did wwand decide not
				// to install it? (ddimension/wwand#41, leideno and liaohongxing,
				// 2026-09-24. I could not answer it from `status` either, on my
				// own test router, which is what settled that this belongs here.)
				//
				// Deliberately the ASSIGNED configuration and not the routes:
				// what netifd did with it is netifd's to report (`ifstatus`),
				// and duplicating that here would be a second answer that
				// drifts. This is the input to that decision.
				// type(), not truthiness: a member access on a SCALAR throws in
				// ucode ("left-hand side expression is not an array or object"),
				// and this runs inside a ubus method LuCI polls — a throw here
				// blanks the status page rather than one field. No writer puts a
				// scalar there today; the guard is one word and closes the class.
				ipv4: type(entry.ctx?.settings?.ipv4) == 'object' ? {
					addr:    entry.ctx.settings.ipv4.addr,
					prefix:  entry.ctx.settings.ipv4.prefix,
					gateway: entry.ctx.settings.ipv4.gateway,
					dns:     entry.ctx.settings.ipv4.dns,
					mtu:     entry.ctx.settings.ipv4.mtu,
				} : null,
				ipv6: type(entry.ctx?.settings?.ipv6) == 'object' ? {
					addr:    entry.ctx.settings.ipv6.addr,
					plen:    entry.ctx.settings.ipv6.plen,
					gateway: entry.ctx.settings.ipv6.gateway,
					dns:     entry.ctx.settings.ipv6.dns,
				} : null,
			};
		}

		// board profile info for LuCI: detected id, whether wwand has a PROFILE for
		// that id at all, whether it can power-cycle the modem, and the board's
		// default modem reset GPIO.
		//
		// `profile` is reported because the two negatives it separates need
		// different things from the reader. A board wwand knows, whose profile
		// carries no power line, is a board that cannot be repowered — nothing to
		// be done. A board wwand does NOT know reports exactly the same
		// has_power:false and reset_gpio:null while its pins may be right there,
		// unread: what that owner needs is a profile, not a shrug. Without this
		// flag the status page could only say the first thing, and said it about
		// a GL-X3000 that is simply not in the table (observed 2026-09-12).
		let board = deps.board ? {
			id: deps.board.id,
			profile: deps.board.profile != null,
			has_power: deps.board.has_power,
			reset_gpio: deps.board.profile?.reset_gpio,
		} : null;

		return { modems: modems, contexts: contexts,
		         board: board,
		         globals: {
		             hold_max_ms: self._hold_max_ms(),
		             // the level the PROCESS is logging at, which is not the
		             // configured one once ubus set_log_level has been used —
		             // and a control that sets it has to be able to read it
		             log_level: logmod.level(),
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

	// A band edit on a modem whose band command is not NV (settings result
	// `persistent: false`, Fibocom +GTACT) is kept in the modem's uci section,
	// where the bring-up re-applies it — the survival a QMI band edit gets
	// from the modem itself. An EMPTY list ("all bands") removes the option,
	// which is what leaves the RAT to the modem's own default after a power
	// cycle. The in-memory config is updated too, so the reload that follows
	// the commit sees nothing to apply.
	let persist_bands = (name, settings) => {
		let lists = {};
		let as_list = (l) => map(l, (b) => sprintf('%d', +b));

		if (type(settings?.lte_bands) == 'array')
			lists.band_lte = as_list(settings.lte_bands);

		let nr = settings?.nr5g_sa_bands ?? settings?.nr5g_nsa_bands;

		if (type(nr) == 'array')
			lists.band_nr = as_list(nr);

		if (type(settings?.umts_bands) == 'array')
			lists.band_umts = as_list(settings.umts_bands);

		if (!length(keys(lists)))
			return;

		if (!deps.record_bands?.(name, lists)) {
			log('warn', sprintf('modem %s: no wwand_modem section to keep the band lists in — the edit lasts until the modem power-cycles', name));
			return;
		}

		let e = self.modems[name];

		for (let k, v in lists) {
			if (e?.cfg)
				e.cfg[k] = v;

			if (e?.modem?.config)
				e.modem.config[k] = v;
		}

		// the modem runs what was just accepted: an earlier failed apply is
		// no longer the state to report
		if (e?.modem)
			e.modem.band_apply_error = null;
	};

	// settings / network-selection / operator-scan ubus ops — in netsel_ops.uc
	// The interfaces of modem `m` that wwand gave up on (reconnect_on_register:
	// an operator detach, reconnect.uc give_up) come back: re-armed and kicked
	// in netifd, whose setup then dials through context_up. Called by
	// netsel_ops modem_attach — an attach does not always cost a registration
	// (a modem still registered on a CS domain stays registered), so waiting
	// for the `registered` that re-arms them otherwise could wait forever.
	self.rearm_giveups = function(m) {
		for (let name, entry in self.contexts) {
			if (entry.ctx?.modem != m || entry.wanted || !entry.reconnect_on_register ||
			    entry.ctx.state != 'IDLE' || !entry.cfg.interface)
				continue;

			set_giveup(entry, false);
			entry.wanted = true;
			// the cleared autostart is our own down, not an operator's ifdown
			mark_our_down(entry);
			log('notice', sprintf('interface %s: modem attached, bringing it up', entry.cfg.interface));
			deps.kick_interface?.(entry.cfg.interface);
		}
	};

	netsel_ops.install(self, { log: log, check_modem: check_modem, reg_plmn: reg_plmn,
	                           persist_bands: persist_bands });

	// SIM/SMS/eSIM/APDU + hardware reset/repower ops live in their own modules
	// (same install pattern); the daemon keeps lifecycle, config and status.
	simops.install(self, { log: log, check_modem: check_modem, load_esim: load_esim });
	hwops.install(self, { log: log, check_modem: check_modem, board: deps.board,
	                      board_gpio_ok: board_gpio_ok,
	                      reset_fallback_ms: self.timing?.reset_fallback_ms,
	                      timer: deps.hw_timer });

	// A plugin parking a modem's radio (a card lent to another modem) or
	// handing it back. The DAEMON records the park, so the hand-back follows
	// the operator's policy and not the plugin's guess: with `option
	// lowpower` and no interface of the modem wanted up (one taken down while
	// the card was lent), the radio stays off as maybe_lowpower would leave
	// it. A radio already parked by the operator is simply left off.
	// A HOLD THIS MODEM CANNOT HONOUR says so, once per modem object: its
	// backend has no radio switch (NCM without an AT port, say), or it
	// refused one. Each park attempt answers `unsupported` all the same; the
	// log line is not repeated per attempt, and status() carries it
	// (radio_hold_error) so the pages say the radio is NOT off although a
	// plugin holds it. What still stands is refusing its interfaces
	// (context_up) and not dialling them (reconnect.uc retry_activate).
	note_unholdable = (m, ref, detail) => {
		if (m._hold_unsupported == null)
			log('warn', sprintf('modem %s: a plugin holds its radio off, but this modem cannot be switched off (%s) — it stays registered, its interfaces are refused',
				ref, detail));

		m._hold_unsupported = detail;
	};

	let radio_wanted = (ref) => {
		let e = self.modems[ref];

		if (!e?.cfg?.lowpower)
			return true;

		for (let n, c in self.contexts)
			if (c.cfg?.modem == ref && (c.wanted || c.reconnect_on_register))
				return true;

		return false;
	};

	let plugin_radio = (ref, on, cb) => {
		let e = self.modems[ref];
		let m = e?.modem;

		cb = cb ?? (() => null);

		if (!m?.set_opmode) {
			if (m && !on)
				note_unholdable(m, ref, 'its backend has no radio switch');

			return cb({ error: 'unsupported' });
		}

		if (!on) {
			m._plugin_held = true;

			if (m.lowpower_parked)
				return cb(null);

			return m.set_opmode('low_power', (err) => {
				if (err?.error == 'unsupported')
					note_unholdable(m, ref, err.detail ?? 'unsupported');
				else if (!err)
					m._hold_unsupported = null;

				cb(err);
			});
		}

		// A HAND-BACK IS NOT A WAKE WHILE ANOTHER HOLD STANDS. The radio is
		// off for every plugin that holds it, not for the one handing back:
		// a card lent to another modem coming back woke a modem that was
		// itself waiting for its remote SIM, and it registered on its own
		// card. Stays parked, and ours; the tick wakes it once nothing holds.
		let still = self.plugins_radio_hold?.(ref);

		if (still) {
			m._plugin_held = true;
			log('info', sprintf('modem %s: radio handed back, but it stays off — %s', ref, still));
			return cb({ error: 'radio_held', detail: still });
		}

		if (!m.lowpower_parked) {
			m._plugin_held = false;
			return cb(null);
		}

		// the operator's park from here on: `option lowpower` owns it
		if (!radio_wanted(ref)) {
			m._plugin_held = false;
			log('info', sprintf('modem %s: radio stays off — `option lowpower` and no interface wants it', ref));
			return cb(null, { kept_off: 'lowpower' });
		}

		// held until the wake has worked: a failed one stays ours, and the
		// tick tries again
		m.set_opmode('online', (err) => {
			if (!err)
				m._plugin_held = false;
			cb(err);
		});
	};
	self._plugin_radio = plugin_radio;

	// init settings that already cost a modem its one reset (at_init_changed)
	self._init_resets = {};

	// Optional plugins (plugins.uc). What they may use of the daemon is this
	// list and nothing else; resolved at call time, so the order of the
	// installs above does not matter.
	plugins.install(self, {
		log: log,
		plugins: deps.plugins,
		deps: {
			modem_of: (ref) => self.modems[ref],
			connection_token: (ref) => self.connection_token(ref),
			modem_reset: (ref, cb) => self.modem_reset(ref, cb),
			esim: () => load_esim(),
			esim_bridge: () => self.esim_bridge(),
			esim_refresh: (ref, eid, slot, cb) => self.esim_refresh(ref, eid, slot, cb),
			// an AT command on the modem's AT channel, whichever it is — a tty,
			// or AT carried inside MBIM where there is none (atcmd_mbim.uc);
			// cb(err, { lines }). The same path `ubus call wwand modem_at` takes.
			modem_at: (ref, command, cb, timeout) =>
				self.modem_at(ref, command, (e, r) => cb(e, r), timeout),
			// the modem's radio off (low power) or back on, the way `option
			// lowpower` parks it: the modem then treats the lost registration
			// as intended, not as a fault to recover from (modem.uc
			// set_opmode / lowpower_parked). For a modem that must not
			// register while another one uses its card. cb(err).
			modem_radio: (ref, on, cb) => plugin_radio(ref, on, cb),
			// the modem's physical SIM slots, read now (simops.uc
			// modem_sim_slots): cb(err, { slots, multisim })
			sim_slots: (ref, cb) => self.modem_sim_slots(ref, cb),
			// the card behind the modem changed: the same forget-and-re-read
			// a slot switch runs (simops.uc card_changed)
			sim_changed: (ref, why) => self.card_changed ? self.card_changed(ref, why) : false,
			// a QMI client of a schema the plugin brings, on the modem's own
			// channel and owned by the modem (modem.uc extra_client) — on an
			// MBIM modem over its QMI passthrough (modem_mbim.uc extra_client;
			// which indications it carries depends on the service). NCM has no
			// QMI at all and answers `unsupported`.
			qmi_client: (ref, schema, cb) => {
				let m = self.modems[ref]?.modem;

				if (!m)
					return cb({ error: 'no_modem' }, null);
				if (!m.extra_client)
					return cb({ error: 'unsupported' }, null);

				m.extra_client(schema, cb);
			},
			qmi_release: (ref, client, cb) => {
				let m = self.modems[ref]?.modem;

				if (m?.extra_release)
					return m.extra_release(client, cb);

				client?.destroy();
				if (cb)
					cb(null);
			},
			// a per-SIM section for the plugin (deps.uc sim_upsert); a write
			// is re-read at once, so the next dial of that card uses it
			sim_upsert: (iccid, fields, origin, opts) => {
				let r = deps.sim_upsert
					? deps.sim_upsert(iccid, fields, origin, opts)
					: { written: false, reason: 'unsupported' };

				if (r?.written && self.reload)
					self.reload();

				return r;
			},
		},
	});

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
				// The MANUFACTURER as the modem reports it over the control
				// channel, which is a different fact from the USB vendor id in
				// `present` and worth both: "Quectel" names who made it,
				// 2c7c:0125 names which one it is. Asked for on
				// ddimension/wwand#10, where the vendor landed on `present` and
				// `managed` was left with only the model.
				manufacturer: entry.modem?.info?.manufacturer,
				revision: entry.modem?.info?.revision,
				device: entry.device,
				netdev: entry.netdev,
				registered: is_registered(entry.modem?.reg),
				identity_mismatch: entry.modem?.identity_mismatch,
			});

		// enrich each present device with the IMEI/model of the managed modem on
		// the same control node, so the picker can offer both anchors
		// ...and the other way: a managed modem also gets the USB ids of the
		// control node it sits on, so a caller reading `managed` alone can still
		// tell two identical models apart.
		for (let m in managed)
			for (let p in present)
				if (p.device && m.device && p.device == m.device) {
					m.vendor_id = p.vendor_id ?? null;
					m.product_id = p.product_id ?? null;
					break;
				}

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
			// Also on `status`, which is where both in-tree consumers look and
			// where it belongs (it is a property of the modem, not of the
			// serving cell). Kept here as well rather than moved: this is the
			// documented location and an out-of-tree script may read it. Both
			// come from the same field, so they cannot drift.
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
			// the EFFECTIVE channel: a demoted `auto` context has no mux child,
			// and listing it here would report a channel that was never built —
			// worse, derive_netdev() then yields the PARENT, so the parent would
			// be counted among its own children and the aggregation ratio
			// (parent frames vs child packets) would be meaningless.
			if (centry.cfg.modem != ref ||
			    !(cfgmod.effective_mux_id(centry.cfg, entry.modem?.datapath) > 0))
				continue;

			// the live L3 device (same resolution status uses for l3_device):
			// the rmnet child renamed to its stable wwandN name
			let l3 = derive_netdev(centry);

			if (!l3)
				continue;

			push(children, l3);
			push(chan, { mux_id: cfgmod.effective_mux_id(centry.cfg, entry.modem?.datapath),
			             netdev: l3,
			             interface: centry.cfg.interface });
		}

		let out = {
			backend: dp.backend,
			// what `option mux` asked for, so a reader can see how `auto`
			// resolved. The two differ routinely and for good reasons — `auto`
			// picking a datapath, a selected backend with no channels to build
			// dropping to the plain parent — and the backend name alone cannot
			// say which of those happened, or that anything happened at all.
			configured: nlmod.canon_mux(entry.cfg?.mux) ?? 'auto',
			protocol: entry.modem.protocol,
			parent: parent,
			// the negotiated QMAP header version (1|4|5). `v5` stays for
			// compatibility, but on its own it cannot tell v1 from v4 — which
			// is exactly the question when aggregation looks wrong.
			qmap_version: dp.qmap_version,
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

	// The last GNSS fix, short form (`wwandctl location`). A view over the
	// wwand-gps reader — the same one modem_gps reports in full — whichever
	// source feeds it, NMEA port or QMI LOC. Cell location is not this: that
	// is telemetry (`cells`).
	self.modem_location = function(ref) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return { error: 'no_such_modem', ref: ref };

		if (!(entry.modem.config?.gnss ?? false))
			return { error: 'location_disabled' };

		if (!deps.gps_status || deps.gps_status(entry.modem, null) == null)
			return { error: 'package_not_installed', detail: 'wwand-gps is not installed' };

		let snap = deps.gps_snapshot ? deps.gps_snapshot(ref) : null;

		if (!snap?.valid || snap.latitude == null)
			return { error: 'no_fix' };

		return {
			latitude: snap.latitude,
			longitude: snap.longitude,
			altitude: snap.elevation,
			speed_kmh: snap.speed_kmh,
			course: snap.course,
			hdop: snap.hdop,
			satellites_used: snap.satellites_used,
			source: snap.source,
		};
	};

	// GNSS as this daemon sees it: the port and receiver state wwand knows,
	// and the fix its own reader has off that port. One process, one answer —
	// not two joined over a ubus call. A box without wwand-gps
	// installed still gets wwand's half plus the reason for the rest.
	self.modem_gps = function(ref, cb) {
		let entry = self.modems[ref];

		if (!entry?.modem)
			return cb({ error: 'no_such_modem', ref: ref });

		// Every modem answers for ITSELF now: its own reader, its own port, its
		// own receiver. There is no shared instance left to attribute, which is
		// what the arbitration this replaces existed to do.
		let out = deps.gps_status
			? deps.gps_status(entry.modem, deps.gps_snapshot ? deps.gps_snapshot(ref) : null)
			: null;

		if (out == null)
			return cb({ error: 'package_not_installed',
			            detail: 'wwand-gps is not installed' });

		cb(null, out);
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

		entry.modem.switch_protocol(target, (err, res) => {
			// A successful firmware switch invalidates a `option protocol` pin
			// that named the OLD protocol, and a pin contradicting the driver
			// wwand recognises is not inert: recovery.revoke_arming withdraws
			// the permission to touch hardware for that modem, persistently. So
			// the modem would come back on the new protocol with its reset and
			// power-cycle rungs silently disabled, and nothing saying why.
			//
			// CLEARED, not rewritten to the target. The option exists for a
			// control device wwand cannot classify ("leave on detect"), and the
			// reason this one was pinned — detection failing on the OLD
			// protocol — usually does not survive the switch. Writing the target
			// would leave a pin that outlives its cause and has to be cleaned up
			// by hand; clearing returns the modem to the recommended state, and
			// if detection is broken on the new protocol too the daemon says so
			// with the remedy ("cannot identify the control protocol ... set
			// `option protocol`"). A stated failure beats a silent one.
			//
			// Deliberately NOT gated on auto_correct_config: that gate is for
			// the daemon correcting config on its own initiative. This runs only
			// because an operator asked for the switch.
			if (!err && deps.clear_protocol_pin && entry.modem?.id)
				deps.clear_protocol_pin(entry.modem.id, target);

			cb(err, res);
		});
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

				// modem_removed, NOT detach_modem: the latter drops the object
				// but leaves control_note, waiting_since and `vanished` unset,
				// so the tick's re-check and the vanish escalation stay
				// disarmed and the modem is waited on passively forever. On
				// NCM this is the ONLY removal path (no on_gone is wired), so
				// there the recovery never fired at all.
				if (hit && entry.modem)
					modem_removed(entry.modem);
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
		self.cancel_reset_fallbacks?.();

		for (let name, entry in self.contexts) {
			clear_reconnect(name);
			cancel_confirm(entry);

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
		self.cancel_reset_fallbacks?.();

		// ...and no second look at an unrecorded down either: it ends in a
		// kick, and the next daemon makes its own
		for (let name, entry in self.contexts) {
			clear_reconnect(name);
			cancel_confirm(entry);
		}

		// the loop runs on for the plugins' hand-back (main.uc): nothing of
		// the daemon's own may act in it — a tick would run the plugins
		// again (re-lending what they just gave back), the vanish ladder,
		// modem starts
		self._tick_timer?.cancel();
		self._tick_timer = null;
	};

	return self;
};
