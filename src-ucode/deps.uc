// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — the dependency object the daemon is constructed with.
//
// Everything the daemon needs from the outside world and refuses to reach for
// itself: opening a transport, logging, re-reading uci, driving netifd over
// ubus, and the handful of writers that put learnt facts BACK into the user's
// config. It lived inside main.uc's run_daemon(), 470 lines deep in a function
// that also builds the ubus connection and enters the uloop — so nothing here
// was reachable from a test, including the uci writers, which are the only code
// in the tree that edits a user's /etc/config/network on its own initiative.
//
// The seam turned out to be small: these closures capture six values from
// run_daemon and never call back into the daemon object. They are parameters
// now, and `cursor` among them — the eleven inline libuci.cursor() calls were
// what made the writers untestable, more than the nesting did.
//
//   o = { conn, datapath_fx, netifd_cb, autosetup_mux_id, cursor, read_config }
//
// `netdev` and `proto` are NOT among them, though a first cut passed both: they
// occur here only as PROPERTY names (`s.proto`, `control?.netdev`), while the
// identifiers of those names are locals of autosetup_mux_id over in main.uc.
// Reading that off a grep instead of off the scope produced a daemon that died
// at start-up with "access to undeclared variable netdev" — caught on hardware,
// because no test in this tree reaches main.uc's wiring. That gap is what this
// split exists to start closing.
//
// `cursor` is a FACTORY, not a cursor: the original called o.cursor() at
// each site and let it go out of scope, and a long-lived cursor caches, which
// would change when a writer sees another writer's commit.

'use strict';

import * as board from 'wwand.board';
import * as config from 'wwand.config';
import * as discovery from 'wwand.discovery';
import * as logmod from 'wwand.log';
import * as modeswitch from 'wwand.modeswitch';
import * as netlink from 'wwand.netlink';
import * as transport from 'wwand.transport';

export function create(o)
{
	let conn = o.conn;
	let datapath_fx = o.datapath_fx;
	let netifd_cb = o.netifd_cb;
	let autosetup_mux_id = o.autosetup_mux_id;
	let load_config = o.read_config;

	return {
		transport_open: transport.open,
		log: (level, msg) => logmod.log(level, '%s', msg),
		// re-parse uci on demand (context_up refreshes params on every up)
		read_config: load_config,
		emit_event: (type, data) => conn.event(type, data),
		datapath_fx: datapath_fx,
		// board profile: modem power/reset GPIOs + status LEDs (no-op on an
		// unknown board). Recovery power-cycles/resets the modem through it.
		board: board.create({ log: (level, msg) => logmod.log(level, '%s', msg) }),
		resolve_modem_device: discovery.resolve_modem_device,
		// enumerate physically-present control devices for the LuCI picker
		list_present: () => discovery.list_present(),
		// learn-back: record a discovered IMEI onto its wwand_modem section so a
		// loose config self-stabilises. Best-effort; never blocks bring-up.
		learn_identity: (section, info) => {
			if (!info?.imei)
				return;
			let cursor = o.cursor();
			if (cursor.get('network', section) == null)
				return;   // not a real section (e.g. a compat_* synthesized modem)
			if (cursor.get('network', section, 'imei') == info.imei)
				return;   // already recorded
			cursor.set('network', section, 'imei', info.imei);
			if (info.serial && !cursor.get('network', section, 'serial'))
				cursor.set('network', section, 'serial', info.serial);
			cursor.commit('network');
			logmod.log('notice', 'learn_identity: recorded IMEI %s on modem %s', info.imei, section);
		},
		// learn-back: replace a fragile `device '/dev/cdc-wdmX'` node artifact on a
		// wwand_modem with its STABLE USB path (`option path`). The cdc-wdm number
		// shuffles across USB enumeration order / reboots, so a two-modem box can
		// wake up with the section pointing at the wrong modem (HW-seen on the
		// GL-X3000: RM520N + an E392 stick). Fires from modem_registered, i.e. only
		// once THIS modem has actually registered on that node — so it always
		// records the working modem's path and can never lock in a wrong/flapping
		// one, and it converts the binding while the node is still correct (before
		// a reboot can shuffle it). Only ever touches a cdc-wdm node artifact;
		// netdev / imei / serial / existing path bindings are left untouched.
		learn_modem_path: (section, control_device) => {
			if (!control_device || substr(control_device, 0, 12) != '/dev/cdc-wdm')
				return;   // only USB cdc-wdm control nodes have a resolvable sysfs path
			let cursor = o.cursor();
			let cur_dev = cursor.get('network', section, 'device');
			if (!cur_dev || substr(cur_dev, 0, 12) != '/dev/cdc-wdm')
				return;   // no cdc-wdm node artifact to fix (or a compat modem)
			let spath = discovery.sysfs_path_of('/sys/class/usbmisc/' +
				substr(control_device, 5) + '/device');
			if (!spath)
				return;
			cursor.set('network', section, 'path', spath);
			cursor.delete('network', section, 'device');
			cursor.commit('network');
			logmod.log('notice', 'learn_path: modem %s rebound to stable USB path %s (dropped cdc-wdm node artifact)',
				section, spath);
		},
		// A protocol switch just made `option protocol` wrong. Clearing it
		// is the point (see daemon.modem_set_protocol): a pin that
		// contradicts the recognised driver disarms hardware recovery for
		// that modem, persistently. Only ever REMOVES, and only when the pin
		// disagrees with what was just switched to.
		clear_protocol_pin: (section, target) => {
			if (!section || !target)
				return;

			let cursor = o.cursor();
			let pin = cursor.get('network', section, 'protocol');

			if (pin == null || pin == '' || pin == target)
				return;   // nothing pinned, or it already names the new one

			cursor.delete('network', section, 'protocol');
			cursor.commit('network');
			logmod.log('notice', 'modem %s: switched to %s — cleared the stale `option protocol %s` (a pin the driver contradicts disarms hardware recovery)',
				section, target, pin);
		},
		// learn-back: record the resolved l3 device name on the interface as
		// `option device` (one stable handle for VRF/firewall/LuCI). Idempotent;
		// NEVER overwrites a user value. commit() only (no netifd reload → no bounce).
		learn_device: (iface_section, l3name) => {
			if (!iface_section || !l3name)
				return;
			let cursor = o.cursor();
			if (cursor.get('network', iface_section) == null)
				return;   // not a real section
			let cur = cursor.get('network', iface_section, 'device');
			if (cur == l3name)
				return;   // already recorded
			if (cur != null && cur != '')
				return;   // user sovereignty: never clobber an explicit device
			cursor.set('network', iface_section, 'device', l3name);
			cursor.commit('network');
			logmod.log('notice', 'learn_device: recorded l3 device %s on interface %s',
				l3name, iface_section);
		},
		// autosetup phase 1: create initial config for the first modem on an
		// unconfigured box (wwmodem_auto + interface wwan0, wan zone). Returns
		// true when written. `plugins` is the daemon's installed-datapath map,
		// needed to answer the mux question below.
		autosetup_create: (devname, plugins) => {
			let cursor = o.cursor();

			// re-check emptiness against LIVE config (a manual edit may be newer)
			let occupied = false;
			cursor.foreach('network', 'wwand_modem', () => { occupied = true; return false; });
			cursor.foreach('network', 'interface', (s) => {
				// any existing mobile-WAN interface — wwand's own or a stock
				// qmi/mbim/ncm one (uqmi / umbim / comgt-ncm) — means the box is
				// already configured, so never auto-grab a control device the
				// stock stack owns (device-ownership coexistence).
				if (s.proto == 'wwand' || s.proto == 'qmi' ||
				    s.proto == 'mbim' || s.proto == 'ncm') {
					occupied = true;
					return false;
				}
			});

			if (occupied || cursor.get('network', 'wwan0') != null)
				return false;

			// A kernel-`wwan` modem offers several control ports and the
			// hotplug that fires first is an accident of attach order, not
			// a choice — so ask for the best sibling on the same device
			// (qmi over mbim) instead of taking what arrived.
			devname = discovery.preferred_wwan_port(devname);

			// Both families are bare kernel names in the hotplug event and
			// both live under /dev. Only cdc-wdm used to be prefixed, so a
			// wwan port was written to uci as `wwan0mbim0` and the daemon
			// then reported "control device not present" for a node that
			// was sitting right there (BPi-R4, MHI).
			let dev = (substr(devname ?? '', 0, 1) == '/') ? devname
				: (match(devname ?? '', /^(cdc-wdm|wwan[0-9]+(qmi|mbim))/)
					? '/dev/' + devname : devname);

			// device blocklist: even on an otherwise unconfigured box, a
			// non-wwand interface may already name this exact device (the
			// proto check above only catches the cellular ones — a
			// `proto dhcp` on wwan0 from a comgt-ncm setup would slip past).
			// Never auto-claim hardware someone else points at.
			let owner = null;

			cursor.foreach('network', 'interface', (s) => {
				if (s.proto == 'wwand' ||
				    (s.disabled != null && s.disabled != '0' && s.disabled != ''))
					return;

				for (let opt in [ 'device', 'ifname', 'ctldevice' ])
					if (s[opt] == dev || s[opt] == devname) {
						owner = { interface: s['.name'], proto: s.proto ?? '?' };
						return false;
					}
			});

			if (owner) {
				logmod.log('notice', 'autosetup: %s is owned by interface %s (proto %s) — not claiming it',
					dev, owner.interface, owner.proto);
				return false;
			}

			// bind by the sysfs path (stable across USB enumeration order); device
			// name is only the fallback when the path can't be resolved
			let clink = (substr(devname ?? '', 0, 7) == 'cdc-wdm')
				? '/sys/class/usbmisc/' + devname + '/device'
				: '/sys/class/net/' + devname + '/device';
			let spath = discovery.sysfs_path_of(clink);

			cursor.set('network', 'wwmodem_auto', 'wwand_modem');
			if (spath)
				cursor.set('network', 'wwmodem_auto', 'path', spath);
			else
				cursor.set('network', 'wwmodem_auto', 'device', dev);
			cursor.set('network', 'wwan0', 'interface');
			cursor.set('network', 'wwan0', 'proto', 'wwand');
			// stable L3 name: datapath netdev renamed to wwand0 (matches the parser)
			cursor.set('network', 'wwan0', 'device', 'wwand0');
			cursor.set('network', 'wwan0', 'modem', 'wwmodem_auto');
			cursor.set('network', 'wwan0', 'autosetup', '1');

			// QMI gets a mux channel when this modem can actually carry one.
			// Muxing is the better datapath on QMI (a QMAP channel is what an
			// accelerated datapath attaches to, and a second APN later needs
			// no re-plumbing), but only where it works — so the question is
			// asked per MODEM, against this device's own netdev, not once per
			// box: qmimux reads that netdev's `add_mux` node and an add-on
			// answers with its own probe. MBIM and NCM keep their defaults:
			// MBIM sessions need no channel and NCM has no mux at all.
			let mux_id = autosetup_mux_id(dev, plugins);

			if (mux_id != null) {
				cursor.set('network', 'wwan0', 'mux_id', sprintf('%s', mux_id));
				logmod.log('notice', 'autosetup: %s can mux on the host side (mux_id %s) — the datapath settles it against the modem\'s own WDA answer and runs unmuxed if it says no',
					dev, mux_id);
			}

			cursor.commit('network');

			// join the default wan firewall zone
			let fw = o.cursor();
			let zone = null;

			fw.foreach('firewall', 'zone', (s) => {
				if (s.name == 'wan') {
					zone = s['.name'];
					return false;
				}
			});

			if (zone) {
				let nets = fw.get('firewall', zone, 'network');

				nets = (type(nets) == 'array') ? [ ...nets ]
					: ((nets != null && nets != '') ? [ nets ] : []);

				if (!('wwan0' in nets)) {
					push(nets, 'wwan0');
					fw.set('firewall', zone, 'network', nets);
					fw.commit('firewall');
				}
			}

			return true;
		},
		// autosetup phase 2: copy ICCID/IMSI-matched APN defaults onto the
		// autosetup interface and clear the marker — one-shot, never clobbers
		// operator values.
		autosetup_fill: (iface_section, vals) => {
			let cursor = o.cursor();

			if (cursor.get('network', iface_section) == null)
				return false;

			if (cursor.get('network', iface_section, 'autosetup') != '1')
				return false;   // marker gone: the operator took over

			let cur_apn = cursor.get('network', iface_section, 'apn');

			if (cur_apn != null && cur_apn != '')
				return false;   // operator set an APN — leave everything alone

			cursor.set('network', iface_section, 'apn', vals.apn);

			if (vals.pdp_type)
				cursor.set('network', iface_section, 'pdp_type', vals.pdp_type);

			if (vals.auth)
				cursor.set('network', iface_section, 'auth', vals.auth);

			if (vals.username)
				cursor.set('network', iface_section, 'username', vals.username);

			if (vals.password)
				cursor.set('network', iface_section, 'password', vals.password);

			cursor.delete('network', iface_section, 'autosetup');
			cursor.commit('network');
			return true;
		},
		// RNDIS v6 model (see docs/reference.md "RNDIS IPv6"): the modem's
		// v6 arrives via RA on the parent netdev; a dhcpv6 subinterface
		// <parent>_6 on @<parent> lets netifd run the v6 client natively.
		// Persisted (LuCI-visible, never deleted, auto 1, parent's zone
		// as `option zone`), then committed and brought up with a
		// `network reload` + down/up — the same sequence /sbin/ifup runs.
		// The commit is the load-bearing step: netifd re-reads uci on
		// reload, so the section must be on disk first. A user-defined
		// section (device/ifname @<parent> + proto dhcpv6) wins: nothing
		// is written, and the up targets THAT section's name.
		ensure_wan6: (parent, pdp_type) => {
			let name = parent + '_6';
			let want = '@' + parent;

			// RFC 7278 on an IPv6-ONLY APN. A mobile network hands out a
			// single /64 on the WAN link and delegates no prefix, so
			// odhcp6c has nothing to give the LAN and clients get no
			// address at all. `extendprefix` is what makes it share that
			// /64 (dhcpv6.script: mask 64 + no PREFIXES + EXTENDPREFIX ->
			// proto_add_ipv6_prefix). The `proto wwand` path already does
			// the equivalent itself in the shim; this is the subinterface,
			// which is the only place the ipv6-only RNDIS/NCM model has an
			// address at all — there the modem's RA is the whole story.
			//
			// Set for EVERY v6-capable PDP, ipv4v6 included — and reaching
			// this function already means the context is one (the daemon
			// gates on pdp_type != 'ipv4').
			//
			// What makes RFC 7278 necessary is IPv6 WITHOUT a delegated
			// prefix, and nothing else. Whether IPv4 is also present does
			// not enter into it: a dual-stack PDP is handed the same single
			// /64 with no delegation, so its LAN clients get no IPv6 either
			// — the working IPv4 merely hides the symptom. (The
			// IPv4-unavailable case is a different problem with a different
			// answer, RFC 6877 / 464XLAT, which lives in the modem or the
			// network, not here.) Keying the option on ipv6-only was
			// therefore wrong on its own terms, and doubly so because
			// pdp_type defaults to ipv4v6 — an interface that never spelled
			// it out never qualified.
			let want_extend = true;

			// logmod, not bare log — there is no `log` in this scope (the
			// deps arrows live outside daemon.create's opts); a bare call
			// here threw "Reference error: access to undeclared variable
			// log" on every RNDIS v6 connect (sponsor field report,
			// 2026-08-30)
			logmod.log('info', 'dhcpv6 subinterface %s: extendprefix=1 (RFC 7278, pdp %s)',
				name, pdp_type ?? 'v6-capable');

			// the parent's firewall zone (read-only lookup): carried as
			// `option zone`, so fw4 joins the subif to that zone and
			// tracks its IP updates. The zone IDENTIFIER is the zone's
			// NAME (option name) — NOT the uci section name, which is
			// an anonymous cfgXXXXXX on most boxes.
			let zone = null;
			let fw = o.cursor();
			fw.foreach('firewall', 'zone', (s) => {
				let nets = fw.get('firewall', s['.name'], 'network');

				// both spellings: `list network 'wan'` and the classic
				// space-separated `option network 'wan wan6'`
				nets = (type(nets) == 'array') ? [ ...nets ]
					: ((nets != null && nets != '') ? split(nets, /[ \t]+/) : []);

				if (parent in nets) {
					zone = s.name ?? s['.name'];
					return false;
				}
			});

			// a matching section already exists (user-defined OR our own) —
			// netifd manages it, nothing to write. Both spellings of the
			// device reference count (ifname is the legacy uci option,
			// device the modern one).
			let have = false, have_name = null;
			let cursor = o.cursor();
			cursor.foreach('network', 'interface', (s) => {
				if ((s.device == want || s.ifname == want) &&
				    (s.proto == 'dhcpv6' || s.proto == 'dhcpv6c')) {
					have = true;
					have_name = s['.name'];
					return false;
				}
			});

			// ONE description of the subinterface. There used to be a
			// second one — the add_dynamic payload — assembled separately
			// from the same intent, and that is exactly how they came
			// apart: extendprefix reached the saved section and never the
			// running instance, so the config on disk and the interface
			// actually doing the work disagreed. There is now only the
			// section, and netifd builds the interface from it.
			let opts = { proto: 'dhcpv6', device: want, auto: '1' };

			if (zone)
				opts.zone = zone;

			if (want_extend)
				opts.extendprefix = '1';

			if (!have) {
				cursor.set('network', name, 'interface');

				for (let k, v in opts)
					cursor.set('network', name, k, v);

				cursor.commit('network');
			}
			else if (want_extend && have_name == name &&
			         cursor.get('network', have_name, 'extendprefix') == null) {
				// OUR OWN section from an earlier connect, predating this
				// default: fill it in. That is the case that matters in the
				// field — the subinterface already exists, so the creation
				// branch above never runs again.
				//
				// Gated on the name being ours (`<parent>_6`). A section a
				// user wrote themselves is left completely alone, which is
				// the promise made in docs/reference.md; and an explicit
				// `extendprefix 0` is an operator decision, so only an
				// ABSENT option is ever filled in.
				logmod.log('notice', 'interface %s: IPv6 without a delegated prefix — defaulting extendprefix=1 (RFC 7278)',
					have_name);
				cursor.set('network', have_name, 'extendprefix', '1');
				cursor.commit('network');
			}

			// A committed section plus a reload IS the interface — which is
			// why nothing dynamic is created here any more. netifd re-reads
			// uci on `network reload`, so the commit above is the load-
			// bearing step; /sbin/ifup does exactly this (reload, then
			// down+up) and it is the sequence an operator would run by hand.
			//
			// down/up rather than a bare up, for two reasons: netifd's `up`
			// returns early on an interface that is already up (verified
			// live — the subinterface kept its uptime across the call), and
			// switching the APN between families changes nothing in uci, so
			// netifd never re-evaluates the section on its own and odhcp6c
			// keeps its old state. Field-seen on the FM350-GL, where only a
			// REBOOT used to bring v6 back. `down` also clears autostart, so
			// the `up` MUST follow it — hence the chain.
			//
			// The target is the section that actually exists: a user's may
			// carry our device alias under a different name.
			let target = have ? have_name : name;

			logmod.log('info', sprintf('dhcpv6 subinterface %s: reload + down/up for the v6-capable context',
				target));

			conn.defer('network', 'reload', {}, () =>
				conn.defer('network.interface', 'down', { interface: target }, () =>
					conn.defer('network.interface', 'up', { interface: target },
						netifd_cb('up ' + target))));

			return true;
		},

		network_reload: () => conn.defer('network', 'reload', {}, netifd_cb('reload')),
		// apply operator-pushed NITZ time ONLY when the clock is clearly unset
		// (RTC-less router before NTP), so we never fight sysntpd. Threshold: any
		// clock before 2021 is unset. busybox date sets UTC; RTC left to the OS.
		set_clock: (epoch, tz_min) => {
			if (!epoch || time() >= 1609459200)   // 2021-01-01: clock already sane
				return;
			system(sprintf('date -u -s @%d >/dev/null 2>&1', epoch));
			logmod.log('notice', 'set system clock from NITZ: %d utc', epoch);
		},
		resolve_netdev: discovery.resolve_netdev,
		resolve_protocol: discovery.protocol_of,
		// how this modem is controlled (qmi/mbim/ncm/ppp), incl. NCM (no cdc-wdm)
		resolve_control: discovery.resolve_control,
		// hardware-path comparison for the device blocklist: a foreign
		// `devpath`/`bus` claim names the same modem without naming its
		// device node, so the block has to be decided on the sysfs path.
		hw_path: {
			claim: (raw) => discovery.claim_path(raw),
			same: (a, b) => discovery.same_hw_path(a, b),
			// an explicit `option path` is authoritative; otherwise resolve
			// from whichever node the modem actually got bound to
			modem: (cfg, control) => {
				if (cfg?.usb_path != null && cfg.usb_path != '')
					return cfg.usb_path;

				let dev = control?.device ?? cfg?.device;
				let nd = control?.netdev ?? cfg?.netdev;
				let m = dev ? match(dev, /^\/dev\/(cdc-wdm[0-9]+)$/) : null;

				if (m)
					return discovery.sysfs_path_of(sprintf('/sys/class/usbmisc/%s/device', m[1]));

				if (nd)
					return discovery.sysfs_path_of(sprintf('/sys/class/net/%s/device', nd));

				return null;
			},
		},
		// one-time usbnet mode switch for a PPP-only modem (serial port only)
		modeswitch: (o, cb) => modeswitch.attempt(o, cb),
		resolve_ep_id: (cfg, device, netdev) =>
			netdev ? netlink.ep_iface_number(netdev) : null,
		resolve_ep_type: (cfg, device, netdev) =>
			netdev ? netlink.ep_type_number(netdev) : null,
		kick_interface: (interface) =>
			conn.defer('network.interface', 'up', { interface: interface }, netifd_cb('up ' + interface)),
		renew_interface: (interface) =>
			conn.defer('network.interface', 'renew', { interface: interface }, netifd_cb('renew ' + interface)),
		down_interface: (interface) =>
			conn.defer('network.interface', 'down', { interface: interface }, netifd_cb('down ' + interface)),
		// async status probe (adopt-in-place vs kick): cb(status|null). Must
		// not block — see netifd_cb above.
		iface_status: (interface, cb) =>
			conn.defer('network.interface', 'status', { interface: interface },
				(ret, reply) => cb(ret == 0 ? reply : null)),
	};
};
