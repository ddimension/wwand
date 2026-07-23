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
import * as netlink from 'wwand.netlink';
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
		// operational timing from the global config (applied at start; a
		// hold_max change takes effect on wwand restart)
		timing: { hold_max_ms: (parsed.globals.hold_max ?? 90) * 1000 },
		deps: {
			transport_open: transport.open,
			log: (level, msg) => logmod.log(level, '%s', msg),
			// re-parse uci on demand (context_up refreshes connection params
			// from disk on every up, like netifd re-reads its config)
			read_config: load_config,
			emit_event: (type, data) => conn.event(type, data),
			datapath_fx: netlink.default_fx((level, msg) => logmod.log(level, '%s', msg)),
			resolve_modem_device: discovery.resolve_modem_device,
			resolve_netdev: discovery.resolve_netdev,
			resolve_protocol: discovery.protocol_of,
			resolve_ep_id: (cfg, device, netdev) =>
				netdev ? netlink.ep_iface_number(netdev) : null,
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

		daemon.apply_config(p);
	};

	daemon.apply_config(parsed);

	if (!ubus_api.publish(conn, daemon, (level, msg) => logmod.log(level, '%s', msg))) {
		warn("wwand: failed to publish ubus object\n");
		exit(1);
	}

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
