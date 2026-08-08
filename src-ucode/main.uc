#!/usr/bin/env ucode
// wwand — QMI connection manager daemon for OpenWrt.
//
// Usage:
//   wwand                      run as daemon
//   wwand --probe <cdc-wdm>    smoke test: CTL sync, service versions,
//                             DMS model/revision/IMEI, then exit.

'use strict';

import * as uloop from 'uloop';
import * as fs from 'fs';
import * as libubus from 'ubus';
import * as libuci from 'uci';
import * as transport from 'wwand.transport';
import * as client from 'wwand.client';
import * as logmod from 'wwand.log';
import * as config from 'wwand.config';
import * as daemon_mod from 'wwand.daemon';
import * as ubus_api from 'wwand.ubus';
import * as discovery from 'wwand.discovery';
import * as modeswitch from 'wwand.modeswitch';
import * as netlink from 'wwand.netlink';
import * as board from 'wwand.board';
import ctl_schema from 'wwand.codec.schema.ctl';
import dms_schema from 'wwand.codec.schema.dms';

const SERVICE_NAMES = {
	'0': 'ctl', '1': 'wds', '2': 'dms', '3': 'nas', '4': 'qos', '5': 'wms',
	'6': 'pds', '9': 'voice', '10': 'cat2', '11': 'uim', '12': 'pbm',
	'16': 'loc', '17': 'sar', '26': 'wda', '226': 'oma',
};

let exit_code = 0;

function fail(fmt, ...args)
{
	warn(sprintf(fmt + "\n", ...args));
	exit_code = 1;
	uloop.end();
}

function probe(dev, nosync)
{
	uloop.init();

	let hub = transport.open(dev, {
		on_gone: (h) => fail('%s: device disappeared', dev),
	});

	if (!hub) {
		warn(sprintf("%s: cannot open device\n", dev));
		exit(1);
	}

	let ctl = client.create(hub, ctl_schema, 0, null);
	let dms = null;
	let dms_cid = null;

	let finish, step_ids, step_revision, step_model, step_alloc, step_version, step_sync;

	finish = () => {
		// give the CID back before exiting; result is best-effort
		if (dms_cid != null) {
			ctl.request('RELEASE_CID',
				{ release: { service: dms_schema.service, cid: dms_cid } },
				(err) => uloop.end(), { timeout: 3000 });
			dms_cid = null;
		}
		else {
			uloop.end();
		}
	};

	step_ids = () => {
		dms.request('GET_IDS', {}, (err, data) => {
			if (!err) {
				if (data.imei) printf("IMEI:      %s\n", data.imei);
				if (data.meid) printf("MEID:      %s\n", data.meid);
			}

			finish();
		});
	};

	step_revision = () => {
		dms.request('GET_REVISION', {}, (err, data) => {
			if (!err)
				printf("Revision:  %s\n", data.revision);

			step_ids();
		});
	};

	step_model = () => {
		dms.request('GET_MODEL', {}, (err, data) => {
			if (err)
				return fail('DMS GET_MODEL failed: %J', err);

			printf("Model:     %s\n", data.model);
			step_revision();
		});
	};

	step_alloc = () => {
		ctl.request('ALLOCATE_CID', { service: dms_schema.service }, (err, data) => {
			if (err || !data.allocation)
				return fail('CTL ALLOCATE_CID(dms) failed: %J', err);

			dms_cid = data.allocation.cid;
			printf("DMS cid:   %d\n", dms_cid);
			dms = client.create(hub, dms_schema, dms_cid, null);
			step_model();
		});
	};

	step_version = () => {
		ctl.request('GET_VERSION_INFO', {}, (err, data) => {
			if (err)
				return fail('CTL GET_VERSION_INFO failed: %J', err);

			let names = [];

			for (let svc in (data.services ?? []))
				push(names, sprintf('%s(%d.%d)',
					SERVICE_NAMES[sprintf('%d', svc.service)] ?? sprintf('%d', svc.service),
					svc.major, svc.minor));

			printf("Services:  %s\n", join(' ', names));
			step_alloc();
		});
	};

	// CTL sync with retry, replaces the old `uqmi --get-versions` x10 probe.
	// SYNC releases stale client ids on the modem — skip it (--no-sync) when
	// probing a device another connection manager is actively using.
	step_sync = (tries) => {
		ctl.request('SYNC', {}, (err) => {
			if (err) {
				if (tries < 10) {
					warn(sprintf("CTL SYNC failed (%s), retry %d/10\n", err.error, tries + 1));
					uloop.timer(1000, () => step_sync(tries + 1));
					return;
				}

				return fail('CTL SYNC failed after 10 tries');
			}

			printf("Device:    %s (CTL sync ok)\n", dev);
			step_version();
		}, { timeout: 3000 });
	};

	if (nosync) {
		printf("Device:    %s (sync skipped)\n", dev);
		step_version();
	}
	else {
		step_sync(0);
	}
	uloop.run();
	hub.close();
	uloop.done();
	exit(exit_code);
}

// --- daemon mode -------------------------------------------------------------

function load_config()
{
	let cursor = libuci.cursor();

	return config.parse({
		wwand: cursor.get_all('wwand'),
		network: cursor.get_all('network'),
	});
}

function run_daemon()
{
	uloop.init();

	// recovery counters live here (tmpfs, cleared by the reboot rung)
	fs.mkdir('/tmp/wwand');
	fs.mkdir('/tmp/wwand/state');

	let conn = libubus.connect(getenv('WWAND_UBUS_SOCKET'));

	if (!conn) {
		warn("wwand: failed to connect to ubus\n");
		exit(1);
	}

	let parsed = load_config();

	logmod.set_level(parsed.globals.log_level);

	for (let w in parsed.warnings)
		logmod.warning('config: %s', w);

	let daemon = daemon_mod.create({
		// operational timing from the global config (also re-read live on reload
		// in daemon.apply_config, so a hold_max edit takes effect without restart)
		timing: { hold_max_ms: (parsed.globals.hold_max ?? 90) * 1000 },
		deps: {
			transport_open: transport.open,
			log: (level, msg) => logmod.log(level, '%s', msg),
			// re-parse uci on demand (context_up refreshes connection params
			// from disk on every up, like netifd re-reads its config)
			read_config: load_config,
			emit_event: (type, data) => conn.event(type, data),
			datapath_fx: netlink.default_fx((level, msg) => logmod.log(level, '%s', msg)),
			// board profile: modem power/reset GPIOs + status LEDs (no-op on an
			// unknown board). Recovery power-cycles/resets the modem through it.
			board: board.create({ log: (level, msg) => logmod.log(level, '%s', msg) }),
			resolve_modem_device: discovery.resolve_modem_device,
			// enumerate physically-present control devices for the LuCI picker
			list_present: () => discovery.list_present(),
			// learn-back: record a discovered IMEI onto its wwand_modem section so
			// a loose config self-stabilises (daemon gates this on auto_correct_config
			// and a real section). Best-effort; never blocks bring-up.
			learn_identity: (section, info) => {
				if (!info?.imei)
					return;
				let cursor = libuci.cursor();
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
			// learn-back: record the resolved l3 device name on the interface section
			// as `option device`, so VRF `list ports` / firewall / LuCI have one
			// explicit, stable handle. Idempotent; NEVER overwrites a user-set value
			// (device-name sovereignty). Best-effort; only commit() (no netifd reload
			// -> no connection bounce), mirroring learn_identity. Gated in the daemon
			// by wwand_globals.write_device (default on).
			learn_device: (iface_section, l3name) => {
				if (!iface_section || !l3name)
					return;
				let cursor = libuci.cursor();
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
			// zero-config autosetup phase 1: create the initial config for the
			// first modem that appears while nothing wwand-related exists —
			// named sections wwmodem_auto + interface wwan0, joined to the
			// default wan firewall zone. Returns true when config was written.
			autosetup_create: (devname) => {
				let cursor = libuci.cursor();

				// re-check emptiness against the LIVE config (a manual edit
				// could be newer than the daemon's parsed view)
				let occupied = false;
				cursor.foreach('network', 'wwand_modem', () => { occupied = true; return false; });
				cursor.foreach('network', 'interface', (s) => {
					if (s.proto == 'wwand' || s.proto == 'qmi') {
						occupied = true;
						return false;
					}
				});

				if (occupied || cursor.get('network', 'wwan0') != null)
					return false;

				let dev = (substr(devname ?? '', 0, 7) == 'cdc-wdm')
					? '/dev/' + devname : devname;

				// bind by the wireless-style sysfs path (stable across USB
				// enumeration order, ready for PCIe/MHI); the device name is
				// only the fallback when the path cannot be resolved
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
				// stable L3 name: the datapath netdev is renamed to wwand0
				// (matches the auto-assignment the parser would make)
				cursor.set('network', 'wwan0', 'device', 'wwand0');
				cursor.set('network', 'wwan0', 'modem', 'wwmodem_auto');
				cursor.set('network', 'wwan0', 'autosetup', '1');
				cursor.commit('network');

				// join the default wan firewall zone
				let fw = libuci.cursor();
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
			// autosetup phase 2: copy the ICCID/IMSI-matched APN defaults onto
			// the autosetup-created interface section and clear the marker —
			// one-shot, never clobbers values the operator set meanwhile.
			autosetup_fill: (iface_section, vals) => {
				let cursor = libuci.cursor();

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
			network_reload: () => conn.call('network', 'reload', {}),
			// apply an operator-pushed NITZ time — but ONLY when the system clock
			// is clearly unset (an RTC-less router booted before NTP synced), so we
			// never fight sysntpd once it has taken over. Conservative threshold:
			// any clock before 2021 is treated as unset. Best-effort; busybox
			// `date -u -s @<epoch>` sets UTC; hwclock/RTC is left to the OS.
			set_clock: (epoch, tz_min) => {
				if (!epoch || time() >= 1609459200)   // 2021-01-01: clock already sane
					return;
				system(sprintf('date -u -s @%d >/dev/null 2>&1', epoch));
				logmod.log('notice', 'set system clock from NITZ: %d utc', epoch);
			},
			resolve_netdev: discovery.resolve_netdev,
			resolve_protocol: discovery.protocol_of,
			// the "how is this modem controlled" decision (qmi/mbim/ncm/ppp),
			// including NCM modems that have no cdc-wdm control device
			resolve_control: discovery.resolve_control,
			// one-time usbnet mode switch for a PPP-only modem (serial port only)
			modeswitch: (o, cb) => modeswitch.attempt(o, cb),
			resolve_ep_id: (cfg, device, netdev) =>
				netdev ? netlink.ep_iface_number(netdev) : null,
			resolve_ep_type: (cfg, device, netdev) =>
				netdev ? netlink.ep_type_number(netdev) : null,
			kick_interface: (interface) =>
				conn.call('network.interface', 'up', { interface: interface }),
			renew_interface: (interface) =>
				conn.call('network.interface', 'renew', { interface: interface }),
			down_interface: (interface) =>
				conn.call('network.interface', 'down', { interface: interface }),
			// synchronous status probe used to decide adopt-in-place vs kick
			iface_status: (interface) =>
				conn.call('network.interface', 'status', { interface: interface }),
		},
	});

	// runtime log-level override (ubus set_log_level); a reload re-applies
	// the configured level from uci
	daemon.set_log_level = (level) => {
		if (!logmod.valid_level(level))
			return false;

		logmod.set_level(level);
		return true;
	};

	daemon.reload = () => {
		let p = load_config();

		logmod.set_level(p.globals.log_level);

		for (let w in p.warnings)
			logmod.warning('config: %s', w);

		// operational globals that change without a destructive rebuild take
		// effect here (log_level above; hold_max via the daemon setter).
		daemon.set_hold_max_ms((p.globals.hold_max ?? 90) * 1000);
		daemon.apply_config(p);
	};

	daemon.apply_config(parsed);

	if (!ubus_api.publish(conn, daemon, (level, msg) => logmod.log(level, '%s', msg))) {
		warn("wwand: failed to publish ubus object\n");
		exit(1);
	}

	// zero-config autosetup: catch a modem that enumerated BEFORE the daemon
	// was on the bus (its hotplug 'add' went nowhere — the cold-boot race)
	daemon.autosetup_scan();

	logmod.notice('wwand started, %d modem(s), %d context(s)',
		length(keys(daemon.modems)), length(keys(daemon.contexts)));

	uloop.run();
	// non-destructive: keep contexts + netifd interfaces up across a restart
	// (no-proto-task means the WAN stays up and traffic keeps flowing; the fresh
	// daemon adopts the live session). A config reload uses the destructive
	// shutdown() via apply_config instead.
	daemon.stop_local();
	uloop.done();
}

// --- entry point ------------------------------------------------------------

if (ARGV[0] == '--probe' && ARGV[1]) {
	probe(ARGV[1], index(ARGV, '--no-sync') >= 0);
}
else if (ARGV[0] == null) {
	run_daemon();
}
else {
	warn("Usage: wwand [--probe /dev/cdc-wdmX [--no-sync]]\n");
	exit(1);
}
