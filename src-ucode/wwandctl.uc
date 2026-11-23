#!/usr/bin/env ucode
// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwandctl — human-friendly CLI for the wwand daemon.
//
// Thin front-end over `ubus call wwand ...`: no JSON to type, readable output,
// modem auto-selection when only one is managed. Run `wwandctl help`.

'use strict';

import { fmt_plmn, fmt_sig, fmt_locks, reg_text, packet_service_text,
	collectd_lines, collectd_interval, recovery_text, radio_text, select_args, euicc_text,
	raw_num, qmi_service_id, qmi_raw_payload, qmi_raw_text, mbim_raw_text,
	sms_slots, sms_delete_args } from 'wwand.wwandctl_fmt';

import * as libubus from 'ubus';
import * as fs from 'fs';

let conn = null;

function die(msg)
{
	warn(sprintf('wwandctl: %s\n', msg));
	exit(1);
}

function call(method, args)
{
	let res = conn.call('wwand', method, args ?? {});

	if (res == null)
		die(sprintf('ubus call wwand %s failed: %s (is wwand running?)',
			method, conn.error() ?? 'no reply'));

	return res;
}

// LuCI-facing methods reply { ok: bool, ... }; surface failures uniformly
function call_ok(method, args)
{
	let res = call(method, args);

	if (res.ok === false)
		die(sprintf('%s failed: %s%s', method, res.error ?? 'unknown error',
			res.detail ? sprintf(' (%J)', res.detail) : ''));

	return res;
}

function status()
{
	return call('status', {});
}

// resolve the modem argument: explicit name, else the single managed modem.
// Commands taking values after an optional modem call this with the first
// argument — if it names a modem it is consumed, else the default applies.
// an optional package's command (see the dispatch at the end), or null
function ctl_plugin(name)
{
	try {
		let m = require(sprintf('wwand.ctl.%s', name));

		return (type(m?.run) == 'function') ? m : null;
	}
	catch (e) {
		return null;
	}
}

// the help lines of every such command installed
function ctl_plugin_help()
{
	let out = [];

	for (let f in sort(fs.lsdir('/usr/share/ucode/wwand/ctl') ?? [])) {
		let m = match(f, /^([a-z0-9_]+)\.uc$/);
		let p = m ? ctl_plugin(m[1]) : null;

		for (let l in (p?.help ?? []))
			push(out, l);
	}

	return out;
}

function resolve_modem(st, name)
{
	if (name != null && st.modems[name])
		return { modem: name, consumed: true };

	let names = keys(st.modems);

	if (length(names) == 1)
		return { modem: names[0], consumed: false };

	if (name != null && length(names) > 1)
		die(sprintf('unknown modem %J — managed: %s', name, join(', ', names)));

	die(length(names) ? sprintf('more than one modem — specify one of: %s', join(', ', names))
	                  : 'no modem managed');
}

function cmd_status(args)
{
	let st = status();

	for (let name, m in st.modems) {
		// the MS extension version rides with the protocol because it changes
		// what "mbim" means on the wire: the v1 Base Stations Info carries no
		// NR arrays at all. Someone pasting this into an issue should not have
		// to be asked for it separately (ddimension/wwand#30, 2026-09-23).
		printf('MODEM %s  (%s %s, %s%s, %s)\n', name,
			m.manufacturer ?? '?', m.model ?? '?', m.protocol ?? '?',
			m.mbimex ? sprintf(' MBIMEx %s', m.mbimex) : '', m.device ?? '?');
		printf('  state       %s%s\n', m.state,
			m.control_note ? sprintf('  [%s]', m.control_note) : '');
		printf('  SIM         %simsi %s  iccid %s\n', m.sim_name ? sprintf('"%s"  ', m.sim_name) : '',
			m.imsi ?? '-', m.iccid ?? '-');

		let radio = radio_text(m);

		if (radio)
			printf('  radio       %s\n', radio);

		// what optional packages report about this modem (a remote SIM, say)
		for (let r in (m.plugins ?? []))
			printf('  %-11s %s%s\n', r.label, r.text,
				(r.level == 'error') ? '  [error]' : (r.level == 'warn') ? '  [!]' : '');
		printf('  network     %s%s\n', reg_text(m),
			m.detached ? '  [detached by the operator — wwandctl attach]' : '');

		let rec = recovery_text(m.recovery);

		if (rec)
			printf('  recovery    %s\n', rec);

		if (m.state == 'READY') {
			let sig = call('modem_signal', { modem: name });

			if (sig && sig.ok !== false)
				printf('  signal      %s\n', fmt_sig(sig));
		}

		// MBIMEx only, and absent on every other backend — so the row simply is
		// not there rather than printing a placeholder. The tracking area comes
		// from the ATTACH, which is not always the cell's: a modem that moved
		// without re-attaching shows the difference.
		let ps_line = packet_service_text(m.packet_service, m.registration?.plmn);

		if (ps_line)
			printf('  5g          %s\n', ps_line);

		// the cell's 5G NSA offer and what the modem makes of it; the held line
		// only when something keeps an LTE link off it
		if (m.nr5g) {
			let yn = (v) => (v == null) ? '?' : (v ? 'yes' : 'no');
			printf('  nr5g        anchor %s · EN-DC %s · DCNR restricted %s · off: %s\n',
				yn(m.nr5g.nsa_available), (m.nr5g.endc_enabled == null) ? '?' : (m.nr5g.endc_enabled ? 'on' : 'off'),
				yn(m.nr5g.dcnr_restricted), m.nr5g.disabled ?? '?');

			if (m.nr5g.blocker)
				printf('  nr5g held   %s\n', m.nr5g.blocker);
		}

		if (m.temperature?.celsius != null)
			printf('  temp        %d °C\n', m.temperature.celsius);

		// what the modem decided to do about it. `mitigated` counts only
		// radio-affecting devices — an environmental one (the modem noting it is
		// cold, a battery limit) is listed but is not throttling.
		if (m.thermal?.mitigated)
			printf('  thermal     THROTTLING at level %d (%s)\n', m.thermal.level ?? 0,
				join(', ', map(filter(m.thermal.active ?? [], (d) => d.rf),
					(d) => sprintf('%s %d/%d', d.label ?? d.id, d.level, d.max))));
		else if (length(filter(m.thermal?.active ?? [], (d) => !d.rf)))
			printf('  thermal     %s (not throttling)\n',
				join(', ', map(filter(m.thermal.active, (d) => !d.rf),
					(d) => sprintf('%s %d/%d', d.label ?? d.id, d.level, d.max))));

		// what the CARD last said about itself
		if (m.sim_busy)
			printf('  sim         busy — reads will fail until it clears\n');

		if (m.sim_note)
			printf('  sim_note    %s\n', m.sim_note);

		let eut = euicc_text(m.euicc);

		if (eut)
			printf('  euicc       %s\n', eut);

		if (m.fcc_lock != null && m.fcc_lock != 0)
			printf('  fcc_lock    mode %d (radio locked — fcc_auth may unlock)\n', m.fcc_lock);

		if (m.apdu_backend)
			printf('  apdu        %s\n', m.apdu_backend);

		// the datapath that actually came up, with the QMAP header version it
		// negotiated. `status` carries only the backend name, and the version is
		// exactly the thing you come looking for when aggregation misbehaves.
		if (m.datapath) {
			let dp = call('modem_datapath', { modem: name });

			// and what was ASKED for, when it is not what came up. `auto →
			// untagged` is the common one and the one worth seeing: it says the
			// modem is carrying its session on the bare parent with no 802.1q
			// tag, which is a performance fact, not a fallback.
			let want = dp?.configured;

			printf('  datapath    %s%s%s\n',
				(want != null && want != m.datapath)
					? sprintf('%s → %s', want, m.datapath) : m.datapath,
				(dp?.qmap_version != null) ? sprintf(' · QMAP v%d', dp.qmap_version) : '',
				(dp?.urb_size != null) ? sprintf(' · urb %d', dp.urb_size) : '');
		}

		if (m.esim?.eid)
			printf('  esim        eid %s (%d profile%s)\n', m.esim.eid,
				length(m.esim.profiles ?? []), length(m.esim.profiles ?? []) == 1 ? '' : 's');

		let locks = fmt_locks(m.locks);

		if (locks)
			printf('  locks       %s\n', locks);
	}

	for (let name, c in st.contexts) {
		printf('INTERFACE %s  (netdev %s)\n', c.interface ?? name, c.l3_device ?? '-');
		printf('  state       %s%s\n', c.state,
			c.last_error ? sprintf('  [last error: %s %s]',
				c.last_error.stage ?? '', c.last_error.text ?? c.last_error.code ?? '') : '');

		// the modem holds the APN back after network rejections: no dial
		// until this runs out, and none of it counts toward recovery
		if (c.throttle)
			printf('  throttled   APN "%s" held back by the modem%s\n', c.throttle.apn ?? '',
				(c.throttle.seconds_left != null) ? sprintf(', %d s left', c.throttle.seconds_left) : '');

		// option iccid: the card it needs, and where its switch stands
		if (c.sim)
			printf('  sim         card %s%s%s\n', c.sim.want ?? '?',
				c.sim.state ? sprintf('  [%s]', c.sim.state) : '',
				c.sim.reason ? sprintf('  %s', c.sim.reason) : '');

		let s = (c.state == 'CONNECTED')
			? call('context_settings', { context: name })?.settings : null;

		if (s?.ipv4)
			printf('  ipv4        %s/%d  gw %s  dns %s\n', s.ipv4.addr, s.ipv4.prefix ?? 32,
				s.ipv4.gateway ?? '-', join(' ', s.ipv4.dns ?? []));

		if (s?.ipv6) {
			if (s.ipv6.unmanaged)
				printf('  ipv6        unmanaged (RA/SLAAC on the netdev, dhcpv6 subinterface)\n');
			else
				printf('  ipv6        %s/%d  gw %s\n', s.ipv6.addr, s.ipv6.plen ?? 64, s.ipv6.gateway ?? '-');
		}

		if (c.state == 'CONNECTED') {
			let cs = call('context_status', { context: name });
			let st = cs?.stats;

			if (st && (st.rx_bytes != null || st.tx_bytes != null))
				printf('  data        down %d bytes  up %d bytes\n',
					st.rx_bytes ?? 0, st.tx_bytes ?? 0);
		}
	}

	if (!length(keys(st.modems)))
		printf('no modems managed\n');

	if (st.board?.id)
		printf('BOARD       %s%s\n', st.board.id,
			st.board.has_power ? ' (power/reset capable)' : '');
}

function cmd_modems()
{
	let st = status();

	for (let name, m in st.modems)
		printf('%-16s %-10s %-6s %-24s %s\n', name, m.state, m.protocol ?? '?',
			m.model ?? '?', reg_text(m));
}

function dump(obj, indent)
{
	// readable key: value dump for the diagnostic commands
	for (let k, v in obj) {
		if (v == null || k == 'ok' || substr(k, 0, 1) == '_')
			continue;

		if (type(v) == 'object' || type(v) == 'array')
			printf('%s%-18s %J\n', indent, k, v);
		else
			printf('%s%-18s %s\n', indent, k, v);
	}
}

function cmd_puk(st, args)
{
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	if (length(rest) != 2)
		die('usage: wwandctl puk [modem] <puk> <new-pin>');

	printf('WARNING: a wrong PUK consumes one of ~10 attempts; 0 left destroys the SIM.\n');

	let res = call_ok('modem_sim_puk', { modem: r.modem, puk: rest[0], new_pin: rest[1] });

	printf('SIM unblocked via %s. New PIN set.\n', res.via ?? '?');
	pin_config_note(res.config);
}

// what happened to the configured PIN after a PIN operation (simops keep_pin)
function pin_config_note(c)
{
	if (c == null)
		return;

	if (c.updated)
		printf('the configured PIN on %s was updated\n', c.section);
	else if (c.reason == 'configured_pin_differs' || c.reason == 'changed')
		printf('NOTE: %s configures a different PIN; it was left as it is\n', c.section ?? '?');
	else if (c.reason == 'none_configured')
		printf('NOTE: no PIN is configured; set one (uci set network.%s.pincode=...) if the card asks for it at start\n',
			c.section ?? '?');
	else if (c.reason != 'unchanged')
		printf('NOTE: the configured PIN was not updated (%s)\n', c.reason ?? '?');
}

function cmd_sms(st, args)
{
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;
	let storage = (rest[0] == 'ME' || rest[0] == 'SM') ? rest[0] : 'SM';

	let res = call_ok('modem_sms_list', { modem: r.modem, storage: storage });

	for (let m in (res.messages ?? []))
		printf('[%3s] %s  %s%s\n      %s\n', sms_slots(m), m.timestamp ?? '-', m.sender ?? '?',
			m.incomplete ? sprintf('  (%d of %d parts)', length(m.indexes ?? []), m.parts ?? 0) : '',
			m.text ?? '');

	if (!length(res.messages ?? []))
		printf('no messages in %s\n', storage);
}

// eSIM management (needs the wwand-esim package on the device): mirror the
// LuCI panel for headless boxes. slot is optional (defaults to 1 in the
// daemon; on dual-SIM modules address the eUICC's physical slot).
function cmd_esim(st, args)
{
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;
	let op = rest[0];

	if (op == null)
		die('usage: wwandctl esim [modem] <eid|info|backend|profiles|enable|disable|delete|download|download-status|notifications|notify|discovery> [...]');

	switch (op) {
	case 'eid':
	case 'backend': {
		let res = call_ok('modem_esim', { modem: r.modem, op: op, slot: +(rest[1] ?? 1) });
		printf('%s\n', (op == 'eid') ? (res.eid ?? '?') : (res.backend ?? '?'));
		break;
	}

	// what the card itself says it is (GetEUICCInfo2) and whether it is an
	// SGP.32 IoT eUICC; `--json` for the whole answer
	case 'info': {
		let json_out = index(rest, '--json') >= 0;
		let pos = filter(slice(rest, 1), (a) => a != '--json');
		let res = call_ok('modem_esim_info', { modem: r.modem, slot: +(pos[0] ?? 1) });

		if (json_out) {
			printf('%.J\n', res);
			break;
		}

		let line = (k, v) => (v != null && v != '') ? printf('%-22s %s\n', k, v) : null;
		let list = (v) => length(v ?? []) ? join(', ', v) : null;

		line('eid', res.eid);
		line('sgp.22 version (svn)', res.svn);
		line('highest svn', res.highest_svn);
		line('sgp.32 (IoT eUICC)', (res.sgp32 == null) ? sprintf('unknown (%s)', res.sgp32_error ?? '?')
			: res.sgp32 ? sprintf('yes%s', (res.eim_count != null) ? sprintf(', %d eIM(s) configured', res.eim_count) : '') : 'no');
		line('category', res.category);
		line('profile package', res.profile_version);
		line('firmware', res.firmware);
		line('free memory', (res.free_nvm != null) ? sprintf('%d B non-volatile, %d B volatile', res.free_nvm, res.free_vm ?? 0) : null);
		line('rsp capability', list(res.rsp_capability));
		line('uicc capability', list(res.uicc_capability));
		line('forbidden ppr', list(res.forbidden_ppr));
		line('globalplatform', res.globalplatform_version);
		line('ts 102 241', res.ts102241_version);
		line('protection profile', res.pp_version);
		line('sas accreditation', trim(res.sas_accreditation ?? ''));
		line('platform label', res.platform_label);
		line('ci keys (verify)', list(res.ci_pkid_verification));
		break;
	}

	case 'profiles': {
		let res = call_ok('modem_esim', { modem: r.modem, op: op, slot: +(rest[1] ?? 1) });

		for (let p in (res.profiles ?? []))
			printf('%-22s %-9s %s%s\n', p.iccid ?? '?', p.state ?? '?',
				p.provider ? sprintf('provider %s ', p.provider) : '',
				p.name ? sprintf('"%s"', p.name) : '');

		if (!length(res.profiles ?? []))
			printf('no profiles installed\n');
		break;
	}

	case 'enable':
	case 'disable':
	case 'delete': {
		if (!length(rest[1] ?? ''))
			die(sprintf('usage: wwandctl esim [modem] %s <iccid>', op));

		let res = call_ok('modem_esim', { modem: r.modem, op: op, slot: +(rest[2] ?? 1), iccid: rest[1] });
		printf('profile %s%s\n', op, res.applied ? sprintf(' (%s applied)', res.applied) : '');
		break;
	}

	case 'download': {
		let code = rest[1];
		let conf = null, auto_notify = true;

		for (let i = 2; rest[i] != null; i++) {
			if (rest[i] == '--no-notify') { auto_notify = false; continue; }
			if (conf != null)
				die('usage: wwandctl esim [modem] download <activation_code> [confirmation_code] [--no-notify]');
			conf = rest[i];
		}

		if (!length(code ?? ''))
			die('usage: wwandctl esim [modem] download <activation_code> [confirmation_code] [--no-notify]');

		let res = call_ok('modem_esim', { modem: r.modem, op: op, activation_code: code,
			confirmation_code: conf ?? '', auto_notify: auto_notify });
		printf('download started (%s)\n', res.via ?? '?');
		break;
	}

	case 'download-status': {
		// the bridge's op is spelled with an underscore (esim_bridge.uc
		// download_status); the CLI keeps the hyphen of its other commands
		let res = call_ok('modem_esim', { modem: r.modem, op: 'download_status' });
		printf('state: %s%s\n', res.state ?? '?', res.via ? sprintf(' via %s', res.via) : '');
		if (length(res.log ?? ''))
			printf('%s\n', res.log);
		break;
	}

	case 'notifications': {
		let res = call_ok('modem_esim', { modem: r.modem, op: op, slot: +(rest[1] ?? 1) });
		printf('%s\n', length(res.log ?? '') ? res.log : '(none)');
		break;
	}

	// discovery [smds]: SM-DS events for this card's EID
	case 'discovery': {
		let args = { modem: r.modem, op: op };

		if (length(rest[1] ?? ''))
			args.smds = rest[1];

		let res = call_ok('modem_esim', args);

		if (!length(res.servers ?? []))
			printf('no profile waiting for this EID\n');

		for (let srv in res.servers ?? [])
			printf('%s   (wwandctl esim download \'LPA:1$%s$\')\n', srv, srv);
		break;
	}

	case 'notify': {
		call_ok('modem_esim', { modem: r.modem, op: op });
		printf('notification process started\n');
		break;
	}

	default:
		die(sprintf('unknown esim op %J — see `wwandctl help`', op));
	}
}

const HELP = `wwandctl — control the wwand cellular connection manager

Usage: wwandctl [--json] <command> [modem] [args...]
  [modem] may be omitted when exactly one modem is managed.
  --json    machine mode: print the raw ubus reply of a read command as JSON
            (status/modems/signal/cells/datapath/slots/plmn/settings/probe/location)

Status
  status                 modem + interface overview
  modems                 one-line modem list
  signal [modem]         raw signal metrics
  cells [modem]          cells, registration detail, temperature
  datapath [modem]       datapath / mux / aggregation diagnostics
  collectd [modem...]    run as a collectd exec plugin: print PUTVAL lines until
                         orphaned. Interval from COLLECTD_INTERVAL, floored at
                         30 s (below that the modem never leaves 1 Hz telemetry)
  slots [modem]          SIM slot status (ICCID, eUICC, CPIN, service, active)
  carrier [modem]        carrier configuration (MBN): which one is active
  carrier [modem] list   every carrier config the modem holds
  carrier [modem] set <id>   select one (takes effect after a modem reset)
  carrier [modem] auto       let a Quectel pick its MBN by the SIM again (AutoSel)
  euicc [modem] [slot]   the MODEM's own eUICC profile read, without lpac —
                         for an M2M eUICC whose ES10 the card refuses. Many
                         modems answer "not supported"; lpac stays the tool.
  plmn [modem]           PLMN selector lists (user/nas/operator/home/fplmn)
  settings [modem]       NAS settings / band prefs (settings editor data)
  probe                  detected modems (managed + present, for stable binding)
  location [modem]       last location fix

Connection
  up <interface>         connect (like ifup, via the daemon)
  down <interface>       disconnect
  reattach [modem]       network detach/re-attach (no full reset)
  detach [modem]         stop the sessions and detach from the network;
                         stays detached until attach (or a modem reset)
  attach [modem]         attach to the network again; interfaces reconnect
  scan [modem]           visible-operator scan (takes up to ~90 s)
  select [modem] auto    automatic network selection
  select [modem] <mcc> <mnc>   manual PLMN selection

SIM
  pin [modem] [pin]      manual PIN release past the low-retry safety block
  pin-lock [modem] <pin> [--store]  enable the SIM PIN query
                             (--store: keep the PIN in the config)
  pin-unlock [modem] <pin>   disable the SIM PIN query
  pin-change [modem] <old> <new>  change the SIM PIN; the configured
                             PIN follows when it was the old one
  puk [modem] <puk> <new-pin>  unblock a PUK-locked SIM and set a NEW PIN
  slot [modem] <n> [--force]  switch the active physical SIM slot
                         (--force: also under an interface bound to the card in use)

SMS
  sms [modem] [SM|ME]    list stored messages
  sms-send [modem] <number> <text...>   send an SMS
  sms-delete [modem] [SM|ME] <index>[,<index>...]   delete the slots "sms" lists
  ussd [modem] <code|answer>  send a USSD code, or answer the network's question
  ussd-cancel [modem]        end the USSD session

eSIM (needs the wwand-esim package)
  esim [modem] profiles                  list installed profiles
  esim [modem] eid                      read the eUICC EID
  esim [modem] info [slot] [--json]     what the eUICC says it is: SGP.22 version, SGP.32, capabilities
  esim [modem] backend                  which APDU transport serves the eUICC
  esim [modem] enable|disable|delete <iccid>
  esim [modem] download <activation_code> [confirmation_code] [--no-notify]
  esim [modem] download-status          poll a running download
  esim [modem] notifications | notify   pending eUICC notifications (ES9+)
  esim [modem] discovery [smds]         profiles an operator queued for this EID (SM-DS)

Maintenance
  sims                   every SIM card seen: ICCID, where it is (modem/slot, eUICC profile, reader)
  reset [modem]          modem reset (its own reset first; the reset GPIO only as the fallback)
  repower [modem]        hardware repower (reset-GPIO pulse / board power-cycle)
  protocol [modem] qmi|mbim   switch the control protocol (the modem resets)
  plmn-set [modem] <user|nas|fplmn> <mccmnc>[+gsm,+utran,...] ...
  plmn-restore [modem]   re-apply the configured PLMN list ("restore now")
  at [modem] <command>   raw AT command on the modem's AT port
  qmi [modem] <service> <message> [TYPE=HEX ...]   one raw QMI request
                         (service by name or number, message id in hex or
                         decimal, each TLV as TYPE=HEX); prints the result
                         and the response TLVs. CTL is refused
  mbim [modem] query|set <service> <cid> [HEX]   one raw MBIM command
                         (service by name, e.g. basic_connect, or UUID);
                         prints the status and the InformationBuffer.
                         Both take --timeout <s> (default 10, max 120)
  migrate [apply]        plan (default) or apply config migration to proto wwand
  reload                 re-read UCI and apply the diff
  log-level <level>      err|warn|notice|info|debug (until next reload)
  help                   this text
`;

// --- main ---------------------------------------------------------------------

// ucode: ARGV holds the arguments after the script name. A leading --json puts
// the tool in machine mode: read commands print the raw ubus reply as JSON.
let argv = ARGV;
let json_mode = false;

if (argv[0] == '--json' || argv[0] == '-j') {
	json_mode = true;
	argv = slice(argv, 1);
}

let cmd = argv[0];
let args = slice(argv, 1);

if (cmd == null || cmd == 'help' || cmd == '-h' || cmd == '--help') {
	print(HELP);

	let more = ctl_plugin_help();

	if (length(more))
		printf('\nFrom installed packages\n%s\n', join('\n', map(more, (l) => '  ' + l)));

	exit(0);
}

// 180 s, not ubus' 30 s default: a reattach or attach over AT waits up to
// 60 s for the registration to return before it answers (netsel_ops
// wait_registered), and the redial follows
conn = libubus.connect(null, 180);

if (!conn)
	die('cannot connect to ubus');

// machine mode: emit the raw ubus reply of the matching read method as JSON
// (scripting / monitoring). Action commands stay human-only.
if (json_mode) {
	const JSON_READ = {
		status: 'status', modems: 'status',
		signal: 'modem_signal', cells: 'modem_cells', datapath: 'modem_datapath',
		slots: 'modem_sim_slots', plmn: 'modem_plmn_lists',
		settings: 'modem_get_settings', probe: 'modem_probe',
		location: 'modem_location',
	};

	let method = JSON_READ[cmd];

	if (!method)
		die(sprintf('--json supports only: %s', join(' ', sort(keys(JSON_READ)))));

	let cargs = {};

	if (method != 'status') {
		let r = resolve_modem(status(), args[0]);
		cargs.modem = r.modem;
	}

	printf('%J\n', call(method, cargs));
	exit(0);
}

// --- collectd exec feed ------------------------------------------------------
//
// Runs until orphaned, printing collectd PUTVAL lines. collectd's exec plugin
// does NOT poll us: it forks this once and reads stdout forever, so the cadence
// is ours to choose and `interval=` on each line is what RRD builds its files
// from. COLLECTD_INTERVAL arrives in the environment as collectd's suggestion.
//
// WHY THE FLOOR. `modem_signal` keeps wwand's adaptive fast-telemetry loop warm
// (daemon.uc calls modem.watch()); that loop polls the modem at 1 Hz and decays
// 6 s after the last request (modem_common.uc:1336, :1041). One sample therefore
// costs ~6 s of 1 Hz modem traffic, so the duty cycle is 6/interval: 10 % at
// 60 s, 20 % at 30 s, 60 % at 10 s — and at 6 s or below the loop NEVER decays
// and the modem is polled around the clock. A global `Interval 10` in
// collectd.conf would do that silently, so it is raised here and said once.
function cmd_collectd(argv)
{
	let want = getenv('COLLECTD_INTERVAL');
	let interval = collectd_interval(want);
	let host = getenv('COLLECTD_HOSTNAME') ?? 'localhost';

	if (interval != +(want ?? interval))
		warn(sprintf('wwandctl collectd: interval %s raised to %d s — below that the modem never leaves 1 Hz telemetry\n',
			want, interval));

	// Orphaned = collectd is gone; the exec plugin expects us to notice.
	//
	// An UNREADABLE /proc counts as orphaned. `match()` answers null there, and
	// treating that as "still parented" would leave the process running for
	// ever, polling the modem for a collectd that is no longer listening. The
	// cost of the opposite mistake is one restart — the exec plugin re-forks a
	// program that exits — so the fail-safe direction is to stop.
	let orphaned = () => {
		let st = fs.readfile('/proc/self/status');
		let m = (st != null) ? match(st, /PPid:[ \t]*([0-9]+)/) : null;

		return m ? (+m[1] == 1) : true;
	};

	while (!orphaned()) {
		// modem_telemetry, NOT status: it carries the same four per-modem
		// numbers this loop needs (state/temperature/attempts/proto_errors) and
		// none of the subscriber identifiers status() returns. That is what lets
		// the ubus ACL grant this loop read access at all — collectd's exec
		// plugin refuses to run as root, and an ACL cannot filter a result, so
		// reading status() as `nobody` would have put iccid/imsi/imei in reach
		// of every process running as that user (ddimension/wwand#14).
		// It does NOT wake the fast loop — only modem_signal and modem_cells do.
		let st = call('modem_telemetry', {});
		let names = length(argv) ? argv : sort(keys(st?.modems ?? {}));
		let out = [];

		for (let name in names) {
			let m = st?.modems?.[name];

			if (!m)
				continue;

			// modem_cells is fetched for the aggregation series. It wakes the
			// same fast loop modem_signal already woke on the line above, so it
			// costs one more request per interval and no extra wake-up — and
			// the cell read is on the daemon's slow loop, so most of those
			// requests are answered from what it already had.
			out = [ ...out, ...collectd_lines(host, name,
				call('modem_signal', { modem: name }), m, interval,
				call('modem_cells', { modem: name })?.cells) ];
		}

		for (let ctx, c in (st?.contexts ?? {}))
			push(out, sprintf('PUTVAL "%s/wwand-%s/gauge-connected" interval=%d N:%d',
				host, ctx, interval, (c.state == 'CONNECTED') ? 1 : 0));

		if (length(out))
			print(join('\n', out) + '\n');

		// MANDATORY. ucode block-buffers stdout on a pipe, and collectd reads a
		// pipe: without this the lines arrive in bursts, and since they carry
		// `N:` (= now) they are stamped when they are FLUSHED rather than when
		// they were sampled. Measured on the RG502Q — three lines printed 2 s
		// apart arrived at the same second (2026-09-11).
		fs.stdout.flush();

		sleep(interval * 1000);
	}
}

// `--timeout <s>` anywhere after the command, taken out of the list:
// the remaining arguments are positional
function raw_timeout_arg(list)
{
	let rest = [], ms = 0;

	for (let i = 0; i < length(list); i++) {
		if (list[i] != '--timeout') {
			push(rest, list[i]);
			continue;
		}

		let s = raw_num(list[++i]);

		if (s == null || s < 1 || s > 120)
			die('--timeout takes seconds, 1..120');

		ms = s * 1000;
	}

	return { rest: rest, timeout: ms };
}

switch (cmd) {
case 'status':   cmd_status(args); break;
case 'collectd': cmd_collectd(args); break;
case 'modems':   cmd_modems(); break;

case 'signal': {
	let r = resolve_modem(status(), args[0]);
	dump(call_ok('modem_signal', { modem: r.modem }), '  ');
	break;
}

case 'cells': {
	let r = resolve_modem(status(), args[0]);
	dump(call_ok('modem_cells', { modem: r.modem }), '  ');
	break;
}

case 'datapath': {
	let r = resolve_modem(status(), args[0]);
	dump(call_ok('modem_datapath', { modem: r.modem }), '  ');
	break;
}

case 'carrier': {
	let r = resolve_modem(status(), args[0]);
	let rest = r.consumed ? slice(args, 1) : args;
	let op = rest[0] ?? 'get';
	let res = call_ok('modem_carrier_config',
		{ modem: r.modem, op: op, id: rest[1] ?? '' });

	if (op == 'list') {
		for (let c in (res.configs ?? []))
			printf('%-24s %s%s\n', c.description ?? '(unnamed)', c.id,
				c.version != null ? sprintf('  v%d', c.version) : '');
	}
	else if (op == 'set') {
		printf('selected %s — %s\n', res.selected, res.note ?? 'applied');

		// a Quectel would otherwise pick its own MBN again at that reset
		if (res.autosel == 'off')
			printf('the modem\'s automatic MBN selection is off now (back on: wwandctl carrier auto)\n');
		else if (res.autosel_note)
			printf('note: %s — the modem may pick its own MBN again at the reset\n', res.autosel_note);
	}
	else if (op == 'auto') {
		printf('automatic MBN selection on — %s\n', res.note ?? 'from the next reset');
	}
	else {
		printf('active   %s\n', res.active ?? '(none)');

		// A pending selection means the radio is STILL RUNNING THE OLD ONE.
		// Saying only "active X" there would be true and misleading.
		if (res.pending)
			printf('pending  %s  (takes effect after a modem reset)\n', res.pending);
	}

	break;
}

case 'euicc': {
	let r = resolve_modem(status(), args[0]);
	let rest = r.consumed ? slice(args, 1) : args;
	let res = call_ok('modem_euicc_profiles',
		{ modem: r.modem, slot: +(rest[0] ?? 1) || 1 });

	for (let p in (res.profiles ?? []))
		printf('%d: %-10s %-22s %s%s\n', p.index, p.state,
			p.name ?? p.nickname ?? p.spn ?? '(unnamed)', p.iccid ?? '',
			p.policy?.delete_not_allowed ? '  [delete not allowed]' : '');

	break;
}

case 'slots': {
	let r = resolve_modem(status(), args[0]);
	let res = call_ok('modem_sim_slots', { modem: r.modem });

	for (let s in (res.slots ?? []))
		printf('slot %d: %-7s %s%s%s%s%s%s\n', s.physical, s.card,
			s.active ? '[active] ' : '',
			s.iccid ? sprintf('iccid %s ', s.iccid) : '',
			s.is_euicc ? sprintf('eUICC eid %s', s.eid ?? '?') : '',
			s.cpin ? sprintf(' cpin %s', s.cpin) : '',
			s.service ? sprintf(' service %s', s.service) : '',
			s.atr ? sprintf(' atr %s', s.atr) : '');

	// The multi-SIM shape, which the slot list alone does not tell you: two
	// slots is not two usable SIMs. `mode` is stated only when the counts are
	// exact (MBIM SYS_CAPS); over QMI the executor count is a lower bound, so
	// the most that can be said is a floor — printed with ">=" so it never
	// reads as a fact.
	let ms = res.multisim;

	if (ms) {
		let mode = ms.mode ? uc(ms.mode)
			: (ms.mode_min ? sprintf('>= %s', uc(ms.mode_min)) : 'unknown');

		printf('multi-sim: %d slot(s), %s%d executor(s), concurrency %s, %s (%s)\n',
			ms.slots, ms.exact ? '' : '>= ', ms.executors ?? 0,
			ms.concurrency != null ? sprintf('%d', ms.concurrency) : '?',
			mode, ms.exact ? ms.source : sprintf('%s, inferred', ms.source));
	}

	break;
}

case 'slot': {
	let st = status();
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	let force = index(rest, '--force') >= 0;

	rest = filter(rest, (a) => a != '--force');

	if (!(+rest[0] > 0))
		die('usage: wwandctl slot [modem] <n> [--force]');

	let res = call_ok('modem_sim_switch_slot', { modem: r.modem, slot: +rest[0], force: force });
	printf(res.unchanged ? 'slot %d already active\n' : 'switched to slot %d\n', +rest[0]);
	break;
}

case 'plmn': {
	let r = resolve_modem(status(), args[0]);
	let res = call_ok('modem_plmn_lists', { modem: r.modem });

	for (let list in [ 'user', 'nas', 'operator', 'home', 'fplmn' ]) {
		if (res[list] == null)
			continue;

		printf('%s:\n', list);

		for (let e in res[list])
			printf('  %s/%s%s\n', e.mcc, e.mnc, (list == 'fplmn') ? '' :
				sprintf('  [%s]', join(' ', filter([ e.gsm ? 'gsm' : null,
					e.utran ? 'utran' : null, e.eutran ? 'eutran' : null,
					e.ngran ? 'ngran' : null ], (x) => x != null))));
	}
	break;
}

case 'plmn-set': {
	let st = status();
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	if (index([ 'user', 'nas', 'fplmn' ], rest[0]) < 0 || !length(rest[1] ?? ''))
		die('usage: wwandctl plmn-set [modem] <user|nas|fplmn> <mccmnc>[+gsm,+utran,...] ...');

	let entries = [];

	for (let e in slice(rest, 1)) {
		let parts = split(e, '+');
		let mm = match(parts[0], /^([0-9]{3})([0-9]{2,3})$/);

		if (!mm)
			die(sprintf('bad mccmnc %J (want 5-6 digits)', parts[0]));

		let ent = { mcc: mm[1], mnc: mm[2] };

		for (let f in slice(parts, 1))
			if (index([ 'gsm', 'utran', 'eutran', 'ngran' ], f) >= 0)
				ent[f] = true;

		push(entries, ent);
	}

	call_ok('modem_plmn_set', { modem: r.modem, list_type: rest[0], entries: entries });
	printf('wrote %d record(s) to the %s list\n', length(entries), rest[0]);
	break;
}

case 'plmn-restore': {
	let r = resolve_modem(status(), args[0]);
	call_ok('modem_plmn_restore', { modem: r.modem });
	printf('configured list restored\n');
	break;
}

case 'protocol': {
	let st = status();
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	if (index([ 'qmi', 'mbim' ], rest[0]) < 0)
		die('usage: wwandctl protocol [modem] qmi|mbim');

	call_ok('modem_set_protocol', { modem: r.modem, protocol: rest[0] });
	printf('protocol switch to %s issued — the modem resets\n', rest[0]);
	break;
}

case 'settings': {
	let r = resolve_modem(status(), args[0]);
	dump(call_ok('modem_get_settings', { modem: r.modem }), '  ');
	break;
}

case 'location': {
	let r = resolve_modem(status(), args[0]);
	let res = call('modem_location', { modem: r.modem });

	if (res?.error)
		printf('no location (%s)\n', res.error);
	else
		dump(res ?? {}, '  ');
	break;
}

case 'probe': {
	let res = call_ok('modem_probe', {});

	printf('managed:\n');

	for (let m in (res.managed ?? []))
		printf('  %-10s %-18s %s\n', m.id ?? '?', m.model ?? '?', m.device ?? '?');

	printf('present (unconfigured):\n');

	for (let p in (res.present ?? []))
		printf('  %s\n', p.device ?? p);

	break;
}

case 'esim':
	cmd_esim(status(), args);
	break;

case 'reload':
	call_ok('reload', {});
	printf('config reloaded\n');
	break;

case 'up':
case 'down': {
	if (!length(args[0] ?? ''))
		die(sprintf('usage: wwandctl %s <interface>', cmd));

	let res = call((cmd == 'up') ? 'context_up' : 'context_down', { interface: args[0] });

	if (cmd == 'up' && !res.up)
		die(sprintf('up failed: %s', res.error ?? 'unknown'));

	printf('%s: %s\n', args[0], (cmd == 'up') ? 'connected' : 'disconnected');

	if (cmd == 'up' && res.ipv4)
		printf('  ipv4 %s\n', res.ipv4.addr);
	break;
}

case 'reattach': {
	let r = resolve_modem(status(), args[0]);
	let res = call_ok('modem_reattach', { modem: r.modem });
	printf('reattach done (via %s)\n', res.via ?? '?');
	break;
}

case 'detach':
case 'attach': {
	let r = resolve_modem(status(), args[0]);
	let res = call_ok('modem_' + cmd, { modem: r.modem });

	if (cmd == 'detach')
		printf('detached (via %s, %d session(s) stopped)\n', res.via ?? '?',
			res.contexts_released ?? 0);
	else
		printf('attached (via %s)%s\n', res.via ?? '?',
			res.unchanged ? ' — it already was' : '');
	break;
}

case 'scan': {
	let r = resolve_modem(status(), args[0]);
	printf('scanning (up to ~90 s)...\n');
	let res = call_ok('modem_scan', { modem: r.modem });

	for (let n in (res.networks ?? []))
		printf('  %s/%s  %-20s %-10s %s\n', n.mcc ?? '?', n.mnc ?? '?',
			n.description ?? n.name ?? '?', n.status ?? '', n.rat ?? n.act ?? '');
	break;
}

case 'select': {
	let st = status();
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	if (rest[0] == 'auto') {
		call_ok('modem_set_network_selection', { modem: r.modem, mode: 'auto' });
		printf('automatic network selection set\n');
	}
	else if (length(rest) == 2) {
		let args = select_args(r.modem, rest[0], rest[1]);

		if (!args)
			die('usage: wwandctl select [modem] auto | <mcc> <mnc>  (3-digit MCC, 2- or 3-digit MNC)');

		call_ok('modem_set_network_selection', args);
		printf('manual selection %s/%s set\n', rest[0], rest[1]);
	}
	else {
		die('usage: wwandctl select [modem] auto | <mcc> <mnc>');
	}
	break;
}

case 'pin': {
	let st = status();
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	call_ok('modem_sim_pin_verify', { modem: r.modem, pin: rest[0] ?? '' });
	printf('PIN release requested — the modem restarts its bring-up\n');
	break;
}

case 'pin-lock':
case 'pin-unlock': {
	let st = status();
	let store = ('--store' in args);
	let a = filter(args, (x) => x != '--store');
	let r = resolve_modem(st, a[0]);
	let rest = r.consumed ? slice(a, 1) : a;

	if (!length(rest[0] ?? ''))
		die(sprintf('usage: wwandctl %s [modem] <pin>%s', cmd, (cmd == 'pin-lock') ? ' [--store]' : ''));

	let res = call_ok('modem_sim_pin_lock',
		{ modem: r.modem, pin: rest[0], enable: (cmd == 'pin-lock'), store: store });
	printf('SIM PIN query %s%s\n', (cmd == 'pin-lock') ? 'enabled' : 'disabled',
		res.already ? ' (was already)' : '');
	pin_config_note(res.config);
	break;
}

case 'pin-change': {
	let st = status();
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	if (!length(rest[0] ?? '') || !length(rest[1] ?? ''))
		die('usage: wwandctl pin-change [modem] <old pin> <new pin>');

	let res = call_ok('modem_sim_pin_change',
		{ modem: r.modem, old_pin: rest[0], new_pin: rest[1] });
	printf('SIM PIN changed\n');
	pin_config_note(res.config);
	break;
}

case 'puk':
	cmd_puk(status(), args);
	break;

case 'sms':
	cmd_sms(status(), args);
	break;

case 'ussd':
case 'ussd-cancel': {
	let st = status();
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	if (cmd == 'ussd-cancel') {
		call_ok('modem_ussd', { modem: r.modem, op: 'cancel' });
		printf('USSD session ended\n');
		break;
	}

	if (!length(rest))
		die('usage: wwandctl ussd [modem] <code|answer>   e.g. wwandctl ussd "*100#"');

	let res = call_ok('modem_ussd', { modem: r.modem, op: 'send', text: join(' ', rest) });

	printf('%s\n', res.reply ?? '(no text)');

	if (res.action_required)
		printf('-- the network asks for a reply: wwandctl ussd <answer>, or ussd-cancel\n');
	break;
}

case 'sms-send': {
	let st = status();
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	if (length(rest) < 2)
		die('usage: wwandctl sms-send [modem] <number> <text...>');

	let number = rest[0];
	let text = join(' ', slice(rest, 1));
	let res = call_ok('modem_sms_send', { modem: r.modem, number: number, text: text });
	printf('sent (%d part%s)\n', res.parts ?? 1, (res.parts == 1) ? '' : 's');
	break;
}

case 'sms-delete': {
	let st = status();
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	let req = sms_delete_args(r.modem, rest);

	if (!req)
		die('usage: wwandctl sms-delete [modem] [SM|ME] <index>[,<index>...]');

	// a list reply says ok: false when any slot failed, next to what did go
	// (sms.sms_delete) — that is reported per slot, not as one error
	let res = call('modem_sms_delete', req);

	if (res.ok === false && type(res.failed) != 'array')
		die(sprintf('modem_sms_delete failed: %s', res.error ?? 'unknown error'));

	printf('%s: deleted %d of %d slot%s\n', req.storage, res.deleted ?? 0, res.requested ?? length(req.indices),
		(length(req.indices) == 1) ? '' : 's');

	for (let f in (res.failed ?? []))
		printf('  slot %d: %s%s\n', f.index, f.error?.error ?? sprintf('%J', f.error),
			f.error?.detail ? sprintf(' %J', f.error.detail) : '');

	if (length(res.failed ?? []))
		exit(1);
	break;
}

// every SIM card wwand has seen, by ICCID, and where it is (siminventory.uc)
case 'sims': {
	let inv = call_ok('sim_inventory', {});

	if (!length(inv?.cards ?? []))
		printf('no SIM card seen yet\n');

	for (let c in (inv?.cards ?? [])) {
		let where = c.reader ? sprintf('reader %s', c.reader)
			: c.modem ? sprintf('%s%s', c.modem, (c.slot != null) ? sprintf(' slot %d', c.slot) : '') : '?';
		let esim = c.eid ? sprintf(' · eUICC %s%s', c.eid,
			c.profile ? sprintf(' profile %s%s', c.profile.state ?? '?', c.profile.name ? sprintf(' "%s"', c.profile.name) : '') : '') : '';

		printf('%-21s %-22s %s%s%s%s\n', c.iccid, where,
			!c.present ? 'not present' : c.active ? 'active' : 'present',
			c.name ? sprintf(' · "%s"', c.name) : '',
			c.imsi ? sprintf(' · imsi %s', c.imsi) : '', esim);
	}
	break;
}

case 'reset': {
	let r = resolve_modem(status(), args[0]);
	let res = call_ok('modem_reset', { modem: r.modem });
	printf('modem reset issued (%s)\n', res.action ?? '?');
	break;
}

case 'repower': {
	let r = resolve_modem(status(), args[0]);
	let res = call('modem_repower', { modem: r.modem });

	if (res.ok === false || res.error)
		die(sprintf('repower failed: %s', res.error));

	printf('repower issued (%s)\n', res.action ?? '?');
	break;
}

case 'at': {
	let st = status();
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	if (!length(rest))
		die('usage: wwandctl at [modem] <command>');

	let res = call('modem_at', { modem: r.modem, command: join(' ', rest) });

	if (res.ok === false)
		die(sprintf('AT failed: %s%s', res.error ?? '?',
			res.code ? sprintf(' (code %s)', res.code) : ''));

	for (let l in (res.response ?? []))
		printf('%s\n', l);
	break;
}

case 'qmi': {
	// a modem may share a name with a service: the first word is taken as
	// the modem only when what follows still makes a request, and with a
	// single modem a line that is a request as it stands is read as one
	let st = status();
	let o = raw_timeout_arg(args);
	let bare = qmi_service_id(o.rest[0]) != null && raw_num(o.rest[1]) != null;
	let prefixed = length(o.rest) >= 3 &&
		qmi_service_id(o.rest[1]) != null && raw_num(o.rest[2]) != null;
	let named = (length(keys(st.modems)) > 1) ? (prefixed ? o.rest[0] : null)
		: ((prefixed && !bare) ? o.rest[0] : null);
	let r = resolve_modem(st, named);
	let a = r.consumed ? slice(o.rest, 1) : o.rest;

	if (length(a) < 2)
		die('usage: wwandctl qmi [modem] <service> <message> [TYPE=HEX ...] [--timeout s]');

	let svc = qmi_service_id(a[0]);
	let msg = raw_num(a[1]);
	let p = qmi_raw_payload(slice(a, 2));

	if (svc == null)
		die(sprintf('unknown QMI service %J — a name (nas, dms, uim, ...) or a number', a[0]));
	if (msg == null)
		die(sprintf('%J is not a message id (0x0024, 36)', a[1]));
	if (p.error)
		die(p.error);

	let res = call_ok('modem_qmi_raw', { modem: r.modem, service: svc, message: msg,
		payload: p.payload, timeout: o.timeout });

	printf('%s\n', qmi_raw_text(res));
	break;
}

case 'mbim': {
	// as for qmi: `query`/`set` decides whether a modem was named
	let st = status();
	let o = raw_timeout_arg(args);
	let named = (o.rest[1] == 'query' || o.rest[1] == 'set');
	let r = resolve_modem(st, named ? o.rest[0] : null);
	let a = r.consumed ? slice(o.rest, 1) : o.rest;

	if (length(a) < 3 || (a[0] != 'query' && a[0] != 'set'))
		die('usage: wwandctl mbim [modem] query|set <service> <cid> [HEX] [--timeout s]');

	let cid = raw_num(a[2]);
	let info = lc(replace(join('', slice(a, 3)), /[: ]/g, ''));

	// ubus carries an integer argument as int32 and refuses a larger one
	// before the daemon sees it, with an error that reads like a dead daemon
	if (cid == null || cid < 1 || cid > 0x7fffffff)
		die(sprintf('%J is not a command id (1..0x7fffffff)', a[2]));
	if (!match(info, /^([0-9a-f]{2})*$/))
		die('the InformationBuffer is not whole bytes of hex');

	let res = call_ok('modem_mbim_raw', { modem: r.modem, type: a[0], service: a[1], cid: cid,
		info: info, timeout: o.timeout });

	printf('%s\n', mbim_raw_text(res));
	break;
}

case 'migrate': {
	let apply = (args[0] == 'apply');
	let res = call('migrate', { apply: apply });

	if (res.error)
		die(sprintf('migrate: %s', res.error));

	printf('%J\n', res);

	if (!apply)
		printf('(plan only — run `wwandctl migrate apply` to convert)\n');
	break;
}

case 'log-level': {
	if (!length(args[0] ?? ''))
		die('usage: wwandctl log-level err|warn|notice|info|debug');

	let res = call('set_log_level', { level: args[0] });

	if (res.ok === false)
		die(sprintf('set_log_level: %s', res.error ?? '?'));

	printf('log level set to %s\n', args[0]);
	break;
}

default: {
	// A command an optional package adds: /usr/share/ucode/wwand/ctl/<cmd>.uc,
	// a plain script returning { run(ctx, args), help }. The core knows no
	// such command by name; ctx is what it may use of this program.
	let ext = match(cmd ?? '', /^[a-z0-9_]+$/) ? ctl_plugin(cmd) : null;

	if (!ext)
		die(sprintf('unknown command %J — see `wwandctl help`', cmd));

	ext.run({ call: call, call_ok: call_ok, status: status, resolve_modem: resolve_modem }, args);
	break;
}
}
