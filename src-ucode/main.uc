#!/usr/bin/env ucode
// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI connection manager daemon for OpenWrt.
//
// Usage:
//   wwand                      run as daemon
//   wwand --probe <cdc-wdm>    smoke test: CTL sync, service versions,
//                             DMS model/revision/IMEI, then exit.
//
// Logging goes to /dev/log with real syslog priorities when available, else to
// stderr. Override with:
//   --log-level err|warn|notice|info|debug   (over the uci log_level)
//   --log-target auto|syslog|stderr          (auto = syslog, else stderr)
//   --stderr / --syslog                      (shorthands for --log-target)

'use strict';

import * as uloop from 'uloop';
import * as fs from 'fs';
import * as libubus from 'ubus';
import * as libuci from 'uci';
import * as transport from 'wwand.transport';
import * as wio from 'wwand_io';
import * as client from 'wwand.client';
import * as logmod from 'wwand.log';
import * as config from 'wwand.config';
import * as daemon_mod from 'wwand.daemon';
import * as depsmod from 'wwand.deps';
import * as ubus_api from 'wwand.ubus';
import * as discovery from 'wwand.discovery';
import * as versionmod from 'wwand.version';
import * as modeswitch from 'wwand.modeswitch';
import * as netlink from 'wwand.netlink';
import * as board from 'wwand.board';
import ctl_schema from 'wwand.codec.schema.ctl';
import dms_schema from 'wwand.codec.schema.dms';

// CLI logging overrides (precedence over uci, sticky across reloads). Declared
// at module scope so run_daemon()/daemon.reload — defined above the arg parser —
// can read them (ucode does not hoist a later `let` into an earlier function).
let cli_log_level = null;
let cli_log_target = null;

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

	// CTL sync with retry. SYNC releases stale client ids on the modem — skip it
	// (--no-sync) when probing a device another connection manager is using.
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

	// logging: primary sink is /dev/log with real syslog priorities (native seam
	// in wwand_io), falling back to stderr. CLI --log-level/--log-target override
	// the uci log_level and stick across reloads.
	logmod.open(wio, {
		level: cli_log_level ?? parsed.globals.log_level,
		target: cli_log_target ?? 'auto',
	});

	// Startup banner, before anything can go wrong with the config. Three
	// questions a log has to answer without anyone asking the operator: which
	// build is this, what can it drive, and what did it actually load.
	//
	// The version comes from the package database rather than a constant in this
	// tree — the package version is assembled from the source date, the commit
	// and PKG_RELEASE, so a constant here would be a second truth that starts
	// lying the first time somebody forgets to bump it. Files dropped over an
	// installed package say so instead of borrowing its version.
	//
	// Backend availability is a FILE check, not a require(): probing by loading
	// would defeat the lazy loading the whole package split exists for. The
	// modules actually loaded announce themselves later, when a modem asks.
	let have_be = filter([ 'qmi', 'mbim', 'ncm' ],
		(b) => fs.access(sprintf('/usr/share/ucode/wwand/%s_lazy.uc', b)) == true);

	logmod.notice('%s', versionmod.banner(versionmod.installed('wwand'), have_be, []));

	for (let w in parsed.warnings)
		logmod.warning('config: %s', w);

	// netifd ubus calls MUST be asynchronous: ucode's conn.call() blocks the
	// single uloop until netifd replies (up to its 30s timeout), and while the
	// daemon is parked in a call it cannot answer its own ubus (status) — the
	// "no status during a network scan / reconnect" freeze. conn.defer() runs
	// the call through uloop and fires cb(ret, reply) on completion; the runtime
	// keeps the deferred alive until then, so the handle need not be retained.
	let netifd_cb = (what) => (ret, reply) => {
		if (ret != 0)
			logmod.log('warn', 'netifd %s: ubus status %d', what, ret);
	};

	// one effects object for every datapath question: the daemon's setup and the
	// autosetup probe below must see the same sysfs.
	let datapath_fx = netlink.default_fx((level, msg) => logmod.log(level, '%s', msg));

	// Autosetup: the mux channel the interface it creates should carry, or null
	// for none (plain raw-IP parent, the previous behaviour).
	//
	// Asked per MODEM, not per box. rmnet is a global kernel module, but
	// qmimux's probe reads THIS netdev's own `add_mux` node and an add-on
	// answers with its own probe against this device — so on a two-modem box the
	// answer can legitimately differ, and the netdev is resolved from the
	// control device rather than assumed.
	let autosetup_mux_id = (dev, plugins) => {
		let proto = discovery.protocol_of(dev);

		// resolving the netdev is only meaningful for the protocol that can mux;
		// a missing one (enumeration race) leaves the interface unmuxed rather
		// than writing a channel nothing can carry. The modem still comes up.
		let netdev = (proto == 'qmi') ? discovery.netdev_for_device(dev) : null;

		return netlink.mux_available(datapath_fx, netdev, proto, plugins) ? 1 : null;
	};

	let daemon = daemon_mod.create({
		// operational timing from global config (re-read live on reload)
		timing: { hold_max_ms: (parsed.globals.hold_max ?? 90) * 1000,
		          failed_min_gap: parsed.globals.failed_min_gap ?? 30 },
		deps: depsmod.create({
			conn: conn, datapath_fx: datapath_fx, netifd_cb: netifd_cb,
			autosetup_mux_id: autosetup_mux_id,
			read_config: load_config,
			// a fresh cursor per call, as the inline libuci.cursor() sites were
			cursor: () => libuci.cursor(),
		}),
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

		// a CLI --log-level override wins over the uci value across reloads
		logmod.set_level(cli_log_level ?? p.globals.log_level);

		for (let w in p.warnings)
			logmod.warning('config: %s', w);

		// operational globals that change without a destructive rebuild take
		// effect here (log_level above; hold_max via the daemon setter).
		daemon.set_hold_max_ms((p.globals.hold_max ?? 90) * 1000);
		daemon.apply_config(p);
	};

	// user-triggered migration (the LuCI modem list; parity with the migrate CLI):
	// convert the selected legacy proto qmi/mbim/ncm interfaces to the network-
	// native model in place (proto -> wwand + a linked wwand_modem), reusing the
	// tested config.migrate_plan engine. apply=false returns only the planned uci
	// changes (preview); an empty interface list migrates everything migratable.
	daemon.migrate = (interfaces, apply) => {
		let cursor = libuci.cursor();
		let net = cursor.get_all('network') ?? {};

		// scope to the selected interfaces by dropping the OTHER not-yet-migrated
		// legacy interfaces from the dump, so migrate_plan ignores them — this
		// keeps the engine's per-modem dedup intact for the selected set instead of
		// post-filtering its (interface + shared-modem) change list.
		if (type(interfaces) == 'array' && length(interfaces)) {
			let want = {};

			for (let i in interfaces)
				want[i] = true;

			let scoped = {};

			for (let name, s in net) {
				let legacy = (s['.type'] == 'interface' && s.modem == null &&
				              (s.proto == 'qmi' || s.proto == 'mbim' ||
				               s.proto == 'ncm' || s.proto == 'modemmanager'));

				if (legacy && !want[name])
					continue;

				scoped[name] = s;
			}

			net = scoped;
		}

		let changes = config.migrate_plan({ network: net }, {
			// anchor modems on the stable sysfs path, not the /dev node
			resolve_path: discovery.path_of_device,
		});

		if (!apply)
			return { changes: changes };

		// apply — same uci ops as files/wwand-migrate --apply
		for (let c in changes) {
			if (c[0] == 'add')
				cursor.set('network', c[2], c[4]);        // create typed section
			else if (c[0] == 'set')
				cursor.set('network', c[2], c[3], c[4]);
			else if (c[0] == 'add_list') {
				let cur = cursor.get('network', c[2], c[3]) ?? [];

				if (type(cur) != 'array')
					cur = (cur != null) ? [ cur ] : [];

				push(cur, c[4]);
				cursor.set('network', c[2], c[3], cur);
			}
			else if (c[0] == 'delete')
				cursor.delete('network', c[2], c[3]);
		}

		cursor.commit('network');

		// netifd re-reads the interfaces (now proto wwand) and the daemon re-reads
		// its config so it starts managing them
		conn.call('network', 'reload', {});
		daemon.reload();

		return { ok: true, applied: length(changes) };
	};

	daemon.apply_config(parsed);

	if (!ubus_api.publish(conn, daemon, (level, msg) => logmod.log(level, '%s', msg))) {
		warn("wwand: failed to publish ubus object\n");
		exit(1);
	}

	// autosetup: catch a modem that enumerated BEFORE the daemon (cold-boot race)
	daemon.autosetup_scan();

	logmod.notice('wwand started, %d modem(s), %d context(s)',
		length(keys(daemon.modems)), length(keys(daemon.contexts)));

	uloop.run();
	// non-destructive: keep contexts + netifd interfaces up across a restart
	// (no-proto-task → WAN stays up; the fresh daemon adopts the live session).
	// A config reload uses the destructive shutdown() via apply_config instead.
	daemon.stop_local();
	uloop.done();
}

// --- entry point ------------------------------------------------------------

// Parsed before dispatch so both --probe and the daemon honour the overrides
// (cli_log_level / cli_log_target are declared at module scope near the top).
function parse_log_args()
{
	let rest = [];

	for (let i = 0; i < length(ARGV); i++) {
		let a = ARGV[i];

		if (a == '--log-level' && ARGV[i + 1] != null)
			cli_log_level = ARGV[++i];
		else if (substr(a, 0, 12) == '--log-level=')
			cli_log_level = substr(a, 12);
		else if (a == '--log-target' && ARGV[i + 1] != null)
			cli_log_target = ARGV[++i];
		else if (substr(a, 0, 13) == '--log-target=')
			cli_log_target = substr(a, 13);
		else if (a == '--stderr')
			cli_log_target = 'stderr';
		else if (a == '--syslog')
			cli_log_target = 'syslog';
		else
			push(rest, a);
	}

	if (cli_log_level != null && !logmod.valid_level(cli_log_level)) {
		warn(sprintf("wwand: invalid --log-level '%s' (err|warn|notice|info|debug)\n",
			cli_log_level));
		exit(1);
	}

	if (cli_log_target != null &&
	    cli_log_target != 'auto' && cli_log_target != 'syslog' && cli_log_target != 'stderr') {
		warn(sprintf("wwand: invalid --log-target '%s' (auto|syslog|stderr)\n",
			cli_log_target));
		exit(1);
	}

	return rest;
}

let args = parse_log_args();

if (args[0] == '--probe' && args[1]) {
	probe(args[1], index(args, '--no-sync') >= 0);
}
else if (args[0] == null) {
	run_daemon();
}
else {
	warn("Usage: wwand [--probe /dev/cdc-wdmX [--no-sync]]\n" +
	     "             [--log-level err|warn|notice|info|debug]\n" +
	     "             [--log-target auto|syslog|stderr] [--stderr] [--syslog]\n");
	exit(1);
}
