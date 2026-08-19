#!/usr/bin/env ucode
// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwandctl — human-friendly CLI for the wwand daemon.
//
// Thin front-end over `ubus call wwand ...`: no JSON to type, readable output,
// modem auto-selection when only one is managed. Run `wwandctl help`.

'use strict';

import * as libubus from 'ubus';

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

function fmt_plmn(reg)
{
	let p = reg?.plmn;

	if (!p)
		return '-';

	return sprintf('%s (%d/%02d)', trim(p.description ?? '?'), p.mcc, p.mnc);
}

function fmt_sig(sig)
{
	let parts = [];
	// -32768 & friends are "not measured" sentinels, never real dBm
	let ok = (v) => v != null && v > -140;

	if (ok(sig?.nr5g?.rsrp))
		push(parts, sprintf('NR rsrp %d dBm snr %.1f dB', sig.nr5g.rsrp, (sig.nr5g.snr ?? 0) / 10.0));

	if (ok(sig?.lte?.rsrp))
		push(parts, sprintf('LTE rsrp %d dBm rsrq %d dB', sig.lte.rsrp, sig.lte.rsrq ?? 0));
	else if (ok(sig?.lte?.rssi))
		push(parts, sprintf('LTE rssi %d dBm', sig.lte.rssi));

	if (ok(sig?.wcdma?.rssi))
		push(parts, sprintf('WCDMA rssi %d dBm', sig.wcdma.rssi));

	if (!length(parts) && ok(sig?.rsrp))
		push(parts, sprintf('rsrp %d dBm', sig.rsrp));

	if (!length(parts) && ok(sig?.rssi))
		push(parts, sprintf('rssi %d dBm', sig.rssi));

	return length(parts) ? join(', ', parts) : '-';
}

function reg_text(m)
{
	let r = m.registration;

	if (m.state == 'SIM_BLOCKED')
		return sprintf('SIM blocked: %s%s', m.sim_block?.reason ?? '?',
			m.sim_block?.retries != null ? sprintf(' (%d retries left)', m.sim_block.retries) : '');

	if (r?.registration == 1 || (type(r?.radio_ifs) == 'array' && length(r.radio_ifs)))
		return sprintf('%s%s%s', fmt_plmn(r), r.roaming ? ', roaming' : '',
			m.rat ? sprintf(', %s', m.rat) : '');

	return m.registration_detail?.reject_text
		? sprintf('not registered: %s', m.registration_detail.reject_text)
		: 'not registered';
}

function cmd_status(args)
{
	let st = status();

	for (let name, m in st.modems) {
		printf('MODEM %s  (%s %s, %s, %s)\n', name,
			m.manufacturer ?? '?', m.model ?? '?', m.protocol ?? '?', m.device ?? '?');
		printf('  state       %s%s\n', m.state,
			m.control_note ? sprintf('  [%s]', m.control_note) : '');
		printf('  SIM         imsi %s  iccid %s\n', m.imsi ?? '-', m.iccid ?? '-');
		printf('  network     %s\n', reg_text(m));

		if (m.state == 'READY') {
			let sig = call('modem_signal', { modem: name });

			if (sig && sig.ok !== false)
				printf('  signal      %s\n', fmt_sig(sig));
		}

		if (m.temperature?.celsius != null)
			printf('  temp        %d °C\n', m.temperature.celsius);

		if (m.fcc_lock != null && m.fcc_lock != 0)
			printf('  fcc_lock    mode %d (radio locked — fcc_auth may unlock)\n', m.fcc_lock);

		if (m.apdu_backend)
			printf('  apdu        %s\n', m.apdu_backend);

		if (m.esim?.eid)
			printf('  esim        eid %s (%d profile%s)\n', m.esim.eid,
				length(m.esim.profiles ?? []), length(m.esim.profiles ?? []) == 1 ? '' : 's');

		if (m.locks) {
			let ls = [];

			for (let k, v in m.locks)
				if (v != null && v !== false)
					push(ls, sprintf('%s=%J', k, v));

			if (length(ls))
				printf('  locks       %s\n', join(' ', ls));
		}
	}

	for (let name, c in st.contexts) {
		printf('INTERFACE %s  (netdev %s)\n', c.interface ?? name, c.l3_device ?? '-');
		printf('  state       %s%s\n', c.state,
			c.last_error ? sprintf('  [last error: %s %s]',
				c.last_error.stage ?? '', c.last_error.text ?? c.last_error.code ?? '') : '');

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
	printf('NOTE: update the configured pincode (uci set network.%s.pincode=...) to the new PIN.\n',
		r.modem);
}

function cmd_sms(st, args)
{
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;
	let storage = (rest[0] == 'ME' || rest[0] == 'SM') ? rest[0] : 'SM';

	let res = call_ok('modem_sms_list', { modem: r.modem, storage: storage });

	for (let m in (res.messages ?? []))
		printf('[%3d] %s  %s\n      %s\n', m.index, m.timestamp ?? '-', m.sender ?? '?',
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
		die('usage: wwandctl esim [modem] <eid|backend|profiles|enable|disable|delete|download|download-status|notifications|notify> [...]');

	switch (op) {
	case 'eid':
	case 'backend': {
		let res = call_ok('modem_esim', { modem: r.modem, op: op, slot: +(rest[1] ?? 1) });
		printf('%s\n', (op == 'eid') ? (res.eid ?? '?') : (res.backend ?? '?'));
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
		let res = call_ok('modem_esim', { modem: r.modem, op: op });
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
  slots [modem]          SIM slot status (ICCID, eUICC, CPIN, service, active)
  plmn [modem]           PLMN selector lists (user/nas/operator/home/fplmn)
  settings [modem]       NAS settings / band prefs (settings editor data)
  probe                  detected modems (managed + present, for stable binding)
  location [modem]       last location fix

Connection
  up <interface>         connect (like ifup, via the daemon)
  down <interface>       disconnect
  reattach [modem]       network detach/re-attach (no full reset)
  scan [modem]           visible-operator scan (takes up to ~90 s)
  select [modem] auto    automatic network selection
  select [modem] <mcc> <mnc>   manual PLMN selection

SIM
  pin [modem] [pin]      manual PIN release past the low-retry safety block
  pin-lock [modem] <pin>     enable the SIM PIN query
  pin-unlock [modem] <pin>   disable the SIM PIN query
  puk [modem] <puk> <new-pin>  unblock a PUK-locked SIM and set a NEW PIN
  slot [modem] <n>       switch the active physical SIM slot

SMS
  sms [modem] [SM|ME]    list stored messages
  sms-send [modem] <number> <text...>   send an SMS
  sms-delete [modem] <index>

eSIM (needs the wwand-esim package)
  esim [modem] profiles                  list installed profiles
  esim [modem] eid                      read the eUICC EID
  esim [modem] backend                  which APDU transport serves the eUICC
  esim [modem] enable|disable|delete <iccid>
  esim [modem] download <activation_code> [confirmation_code] [--no-notify]
  esim [modem] download-status          poll a running download
  esim [modem] notifications | notify   pending eUICC notifications (ES9+)

Maintenance
  reset [modem]          modem reset (GPIO if configured, else backend soft reset)
  repower [modem]        hardware repower (reset-GPIO pulse / board power-cycle)
  protocol [modem] qmi|mbim   switch the control protocol (the modem resets)
  plmn-set [modem] <user|nas|fplmn> <mccmnc>[+gsm,+utran,...] ...
  plmn-restore [modem]   re-apply the configured PLMN list ("restore now")
  at [modem] <command>   raw AT command on the modem's AT port
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
	exit(0);
}

conn = libubus.connect();

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

switch (cmd) {
case 'status':   cmd_status(args); break;
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
	break;
}

case 'slot': {
	let st = status();
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	if (!(+rest[0] > 0))
		die('usage: wwandctl slot [modem] <n>');

	let res = call_ok('modem_sim_switch_slot', { modem: r.modem, slot: +rest[0] });
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
		call_ok('modem_set_network_selection',
			{ modem: r.modem, mode: 'manual', mcc: rest[0], mnc: rest[1] });
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
	let r = resolve_modem(st, args[0]);
	let rest = r.consumed ? slice(args, 1) : args;

	if (!length(rest[0] ?? ''))
		die(sprintf('usage: wwandctl %s [modem] <pin>', cmd));

	let res = call_ok('modem_sim_pin_lock',
		{ modem: r.modem, pin: rest[0], enable: (cmd == 'pin-lock') });
	printf('SIM PIN query %s%s\n', (cmd == 'pin-lock') ? 'enabled' : 'disabled',
		res.already ? ' (was already)' : '');
	break;
}

case 'puk':
	cmd_puk(status(), args);
	break;

case 'sms':
	cmd_sms(status(), args);
	break;

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

	if (rest[0] == null)
		die('usage: wwandctl sms-delete [modem] <index>');

	call_ok('modem_sms_delete', { modem: r.modem, index: +rest[0] });
	printf('message %d deleted\n', +rest[0]);
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

default:
	die(sprintf('unknown command %J — see `wwandctl help`', cmd));
}
