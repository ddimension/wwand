// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand-qlog — on-demand Qualcomm diag capture via Quectel QLog.
//
// Shipped as the optional wwand-qlog package; `wwandctl qlog` require()s it and
// reports "wwand-qlog package not installed" when it is absent. Exportless plain
// script (like esim_bridge.uc / the datapath plugins): require() cannot compile
// ES modules, and a CLI that must run without this package cannot `import` it.
//
// SCOPE, deliberately small: wwand contributes the management around the tool —
// which port, which filter profile, is one already running, how do I stop it —
// and nothing else. QLog's own storage options are passed through VERBATIM;
// there is no stdout relay, no ring buffer and no auto-arming. The point of the
// exercise is that a multi-gigabyte QMDL must not land on router flash, and
// QLog already solves that with its TCP / TFTP / FTP sinks.
//
// Everything QLog-side asserted here was read off the bundled source of
// QLog_Linux_Android_V1.5.8 (the version repository/qlog/Makefile builds; the
// files are ISO-8859 encoded, `grep -a`). Anchors are given per rule below.
// NONE of it has been exercised on hardware by this author — see
// docs/reference.md, "QLog diag capture".

'use strict';

import * as fs from 'fs';

// /usr/sbin/QLog and /usr/share/qlog/conf/*.cfg are where repository/qlog/Makefile
// (Package/qlog/install) puts them.
const QLOG_BIN = '/usr/sbin/QLog';
const PROFILE_DIR = '/usr/share/qlog/conf';
// same runtime dir the eSIM bridge uses; tmpfs, so nothing lands on flash
const RUN_DIR = '/tmp/wwand';

// --- effects -----------------------------------------------------------------

// every side effect goes through this so the whole module is host-testable
function default_fx()
{
	return {
		read: (path) => {
			let f = fs.open(path, 'r');

			if (!f)
				return null;

			let d = f.read('all');
			f.close();

			return d;
		},
		write: (path, data) => {
			let f = fs.open(path, 'w');

			if (!f)
				return false;

			f.write(data);
			f.close();

			return true;
		},
		exists: (path) => fs.access(path) == true,
		glob: (pat) => fs.glob(pat),
		unlink: (path) => fs.unlink(path),
		// popen: read the stdout of a /bin/sh command (used once, to learn the
		// pid of the backgrounded QLog)
		popen: (cmd) => {
			let p = fs.popen(cmd, 'r');

			if (!p)
				return null;

			let out = p.read('all');
			p.close();

			return out;
		},
		run: (argv) => system(argv),
		now: () => time(),
	};
}

// --- QLog's own acceptance rules, mirrored ------------------------------------

// Which -p values QLog can actually route. main.c:1180-1226 (V1.5.8) dispatches
// on the PREFIX of the argument:
//   /dev/mhi*    -> the vendor pcie_mhi MHI diag node, USB scan skipped
//   /dev/sdiag*  -> Unisoc
//   /dev/ttyUSB*, /dev/ttyACM*, /sys/bus/usb/...  -> matched against the USB scan
// Anything else falls through to ql_find_quectel_modules() (usb_linux.c:233),
// a USB-only enumeration; on a PCIe modem it returns 0 and main.c:1218 loops
// "No Quectel Modules found" every 2 s, forever. So a mainline kernel-wwan node
// (/dev/wwan0qcdm0 — the name mhi_wwan_ctrl gives the MHI DIAG channel,
// wwan_core.c:321 .devsuf, 6.18.41) is NOT usable, and saying so beats starting
// a capture that can never produce a byte.
function port_supported(port)
{
	for (let p in [ '/dev/mhi', '/dev/sdiag', '/dev/ttyUSB', '/dev/ttyACM', '/sys/bus/usb/' ])
		if (substr(port ?? '', 0, length(p)) == p)
			return true;

	return false;
}

// Which modems QLog's USB scan recognises at all: usb_linux.c:259-268 plus
// drv_is_asr()/drv_is_unisoc() (main.c:910-934), V1.5.8. The scan is a fixed
// VID/PID allow-list, so a modem outside it makes QLog loop "No Quectel Modules
// found" exactly like an unroutable port does — the composition does not matter.
//
// Only consulted for USB ports: the /dev/mhi and /dev/sdiag branches synthesise
// their own device entry and never run the scan (main.c:1180-1210).
function usbid_supported(usbid)
{
	let m = match(lc(trim(usbid ?? '')), /^([0-9a-f]{4}):([0-9a-f]{4})/);

	if (!m)
		return null;   // unknown — not the same thing as unsupported

	let vid = hex('0x' + m[1]), pid = hex('0x' + m[2]);

	// Qualcomm reference VIDs for old Quectel sticks (UC15/UC20/EC20/sdx12)
	if (vid == 0x05c6)
		return pid == 0x9003 || pid == 0x9090 || pid == 0x9215 || pid == 0x90db;

	if (vid == 0x3763)
		return pid == 0x3c93;

	if (vid == 0x3c93)
		return pid == 0xffff;

	// Unisoc RG500U AP dump
	if (vid == 0x1782)
		return pid == 0x4d00;

	// Quectel: 0x0xxx = Qualcomm ("mdm"), 0x0900 = Unisoc, 0x6xxx = ASR
	if (vid == 0x2c7c)
		return (pid & 0xf000) == 0x0000 || (pid & 0xf000) == 0x6000;

	return false;
}

// How QLog reads -s. parser_tcp/parser_tftp/parser_ftp, main.c:738-793 (V1.5.8);
// TFTP_F/FTP_F are "tftp:"/"ftp:" (qlog.h:31-32). Purely informational — we pass
// the value through untouched — but it is what lets the CLI warn that a plain
// directory writes the QMDL to local storage, which is the thing the whole
// feature exists to avoid.
function sink_kind(s)
{
	s = sprintf('%s', s ?? '');

	if (substr(s, 0, 5) == 'tftp:')
		return 'tftp';

	if (substr(s, 0, 4) == 'ftp:')
		return 'ftp';

	// main.c:742: str[0] == '9' && atoi(str) >= 9000
	if (substr(s, 0, 1) == '9' && +s >= 9000)
		return 'tcp-server';

	// main.c:747: contains both ':' and '.'
	if (index(s, ':') >= 0 && index(s, '.') >= 0)
		return 'tcp-client';

	return 'dir';
}

// --- filter profiles ----------------------------------------------------------

// The profiles repository/qlog/Makefile installs, renamed there from the
// CJK-bearing names in the vendor zip:
//   T1-data-ota-dataservice  T2-registration-context-activation  T3-simple-data
//   T4-throughput  T5-common  T6-full-message  T7-v2x
// Listed from the filesystem, never from a table here: the Makefile owns the
// names and a table would rot the first time one is added.
function list_profiles(fx)
{
	let out = [];

	for (let path in sort(fx.glob(PROFILE_DIR + '/*.cfg') ?? [])) {
		let file = substr(path, rindex(path, '/') + 1);
		let m = match(file, /^([Tt][0-9]+)[-.]/);

		push(out, {
			tag: m ? uc(m[1]) : null,
			name: substr(file, 0, length(file) - 4),
			path: path,
		});
	}

	return out;
}

// Accept a bare tag ('T2', 't2'), the profile name with or without .cfg, or any
// path. A path is taken as given (the operator named it — the same rule
// atcmd.find_tty applies to an explicit AT port), only checked for existence.
// Returns { path } or { error, detail }.
function resolve_profile(fx, spec)
{
	spec = sprintf('%s', spec ?? '');

	if (!length(spec))
		return { path: null };   // QLog's built-in default filter (main.c:866)

	if (index(spec, '/') >= 0) {
		if (!fx.exists(spec))
			return { error: 'no_profile', detail: sprintf('no such filter config: %s', spec) };

		return { path: spec };
	}

	let want = lc(spec);
	let want_base = (substr(want, -4) == '.cfg') ? substr(want, 0, length(want) - 4) : want;
	let avail = list_profiles(fx);

	for (let p in avail)
		if (lc(p.tag ?? '') == want_base || lc(p.name) == want_base)
			return { path: p.path };

	let names = [];

	for (let p in avail)
		push(names, p.tag ? sprintf('%s (%s)', p.tag, p.name) : p.name);

	return { error: 'no_profile', detail: length(names)
		? sprintf('unknown filter profile %s — installed: %s', spec, join(', ', names))
		: sprintf('unknown filter profile %s — no profiles in %s (qlog package installed?)',
			spec, PROFILE_DIR) };
}

// --- argument handling --------------------------------------------------------

// The CLI owns everything BEFORE the first -s and QLog owns everything from it
// on. One rule, no per-option knowledge of QLog's getopt string ("p:s:n:m:f:D::qh",
// main.c:807) on our side, so -n/-m/-D/-q and whatever a later QLog adds keep
// working without a wwand release. -s itself is required: without it QLog writes
// to the relative directory "qlog_files" (args.logdir initialiser, main.c:800) —
// i.e. onto flash, next to wherever the CLI happened to run.
function split_args(args)
{
	args ??= [];

	for (let i = 0; i < length(args); i++) {
		// getopt takes the value either detached ("-s 9000") or attached
		// ("-s9000"); both are the boundary
		if (args[i] == '-s')
			return { own: slice(args, 0, i), tail: slice(args, i), sink: args[i + 1] };

		if (substr(args[i], 0, 2) == '-s' && length(args[i]) > 2)
			return { own: slice(args, 0, i), tail: slice(args, i), sink: substr(args[i], 2) };
	}

	return { own: args, tail: null, sink: null };
}

// single-quote for /bin/sh
function shq(s)
{
	return "'" + replace(sprintf('%s', s ?? ''), /'/g, "'\\''") + "'";
}

function build_argv(port, profile, tail)
{
	let argv = [ QLOG_BIN, '-p', port ];

	if (length(profile ?? ''))
		push(argv, '-f', profile);

	for (let a in (tail ?? []))
		push(argv, a);

	return argv;
}

// --- capture bookkeeping ------------------------------------------------------

// one capture per modem, keyed by the modem section name
function safe_name(modem)
{
	return replace(sprintf('%s', modem ?? 'modem'), /[^A-Za-z0-9_.-]/g, '_');
}

function state_file(modem)
{
	return sprintf('%s/qlog-%s.json', RUN_DIR, safe_name(modem));
}

function log_file(modem)
{
	return sprintf('%s/qlog-%s.log', RUN_DIR, safe_name(modem));
}

// argv of a live process, or null. /proc/<pid>/cmdline is NUL-separated and
// reports 0 bytes in stat(2), so it is read whole and split rather than sized.
function proc_argv(fx, pid)
{
	if (!(+pid > 0))
		return null;

	let raw = fx.read(sprintf('/proc/%d/cmdline', +pid));

	if (!length(raw ?? ''))
		return null;

	let parts = split(raw, '\x00');

	// the trailing NUL leaves an empty last element
	while (length(parts) && parts[length(parts) - 1] == '')
		pop(parts);

	return length(parts) ? parts : null;
}

// Is this argv a QLog capture? Not argv[0] alone: a real QLog exec puts the
// binary there, but a wrapper (a shell script named QLog, an strace/valgrind
// run, busybox' sh in a container image) shifts it along — verified on the host
// with a stand-in /tmp/fakeq/QLog, where argv came back as
// [ "/bin/sh", "/tmp/fakeq/QLog", "-p", ... ] and an argv[0]-only test found
// nothing. So: ANY element whose basename is exactly `QLog`, AND a `-p` option,
// which every capture has and an incidental `grep QLog` does not.
function is_qlog_argv(argv)
{
	let named = false, ported = false;

	for (let a in (argv ?? [])) {
		let s = sprintf('%s', a);

		if (substr(s, rindex(s, '/') + 1) == 'QLog')
			named = true;

		if (s == '-p' || substr(s, 0, 2) == '-p' && length(s) > 2)
			ported = true;
	}

	return named && ported;
}

// the -p value of a QLog argv, or null
function argv_port(argv)
{
	for (let i = 0; i < length(argv ?? []); i++) {
		if (argv[i] == '-p')
			return argv[i + 1];

		// getopt also takes the value attached ("-p/dev/ttyUSB0")
		if (substr(argv[i], 0, 2) == '-p' && length(argv[i]) > 2)
			return substr(argv[i], 2);
	}

	return null;
}

// Every live QLog on this box, optionally narrowed to one diag port. This is the
// reconciliation the pid file alone cannot give: a CLI that was killed between
// spawning QLog and writing its state leaves an UNTRACKED capture, and an
// untracked capture that nothing can find is exactly the "runs forever" failure.
// `stop` and `status` both go through here, so such a process is still listed
// and still killable, and `start` still refuses to put a second QLog on the same
// port.
function scan_captures(fx, port)
{
	let out = [];

	for (let path in sort(fx.glob('/proc/[0-9]*/cmdline') ?? [])) {
		let m = match(path, /^\/proc\/([0-9]+)\//);

		if (!m)
			continue;

		let pid = +m[1];
		let argv = proc_argv(fx, pid);

		if (!is_qlog_argv(argv))
			continue;

		let p = argv_port(argv);

		if (port != null && p != port)
			continue;

		push(out, { pid: pid, port: p, argv: argv });
	}

	return out;
}

// The state file is flat `key=value` lines, not JSON, on purpose: ucode's json()
// RAISES on malformed input (docs/gotchas territory — esim_bridge.uc parses lpac's
// output with match() for the same reason), and a truncated state file after an
// unclean shutdown is a plausible tmpfs accident that must not take the CLI down.
// No value here can contain a newline (a pid, a device node, a sink string).
function write_state(fx, modem, st)
{
	let lines = [];

	for (let k, v in st)
		push(lines, sprintf('%s=%s', k, replace(sprintf('%s', v ?? ''), /\n/g, ' ')));

	return fx.write(state_file(modem), join('\n', sort(lines)) + '\n');
}

function read_state(fx, modem)
{
	let raw = fx.read(state_file(modem));

	if (!length(raw ?? ''))
		return null;

	let st = {};

	for (let line in split(trim(sprintf('%s', raw)), '\n')) {
		let i = index(line, '=');

		if (i > 0)
			st[substr(line, 0, i)] = substr(line, i + 1);
	}

	if (!length(st.pid ?? ''))
		return null;

	st.pid = +st.pid;
	st.started = length(st.started ?? '') ? +st.started : null;

	return st;
}

// What is capturing for this modem right now: the tracked pid if it is still a
// live QLog, else whatever /proc says is on that port.
//   { running, pid, port, profile, sink, started, tracked }
function capture_status(fx, modem, port)
{
	let st = read_state(fx, modem);

	if (st != null) {
		let argv = proc_argv(fx, st.pid);

		if (is_qlog_argv(argv) && argv_port(argv) == st.port)
			return { running: true, tracked: true, ...st };
	}

	let found = port ? scan_captures(fx, port) : [];

	if (length(found))
		return { running: true, tracked: false, pid: found[0].pid, port: found[0].port,
			profile: null, sink: null, started: null };

	return { running: false, tracked: false, pid: null, port: port ?? null,
		profile: st?.profile ?? null, sink: st?.sink ?? null, started: null,
		stale: st != null };
}

// --- operations ---------------------------------------------------------------

// start(fx, o) — o = { modem, port, port_explicit, profile, tail }
// Returns { ok: true, pid, argv, port, profile, sink, logfile, warnings[] }
// or { error, detail }.
function start(fx, o)
{
	let warnings = [];

	if (!fx.exists(QLOG_BIN))
		return { error: 'no_binary',
			detail: sprintf('%s not found — install the qlog package', QLOG_BIN) };

	if (!length(o.port ?? ''))
		return { error: 'no_port',
			detail: 'no diag port for this modem — set `option diag_port` on the '
			      + 'wwand_modem section, or pass --port /dev/ttyUSBn' };

	// An auto-resolved port QLog cannot route is a refusal; an explicitly named
	// one is a warning. Same principle as atcmd.find_tty: the operator named it,
	// and a firmware/QLog we do not know about is their call, not ours.
	if (!port_supported(o.port)) {
		let why = sprintf('QLog 1.5.8 does not accept %s (main.c:1180-1226 routes only '
			+ '/dev/mhi*, /dev/sdiag*, /dev/ttyUSB*, /dev/ttyACM*, /sys/bus/usb/...); '
			+ 'it would loop "No Quectel Modules found"', o.port);

		if (!o.port_explicit)
			return { error: 'port_unsupported', detail: why };

		push(warnings, why);
	}

	// the USB scan's allow-list only applies on the USB branches
	if (substr(o.port, 0, 8) == '/dev/tty') {
		let sup = usbid_supported(o.usbid);

		if (sup === false)
			push(warnings, sprintf('USB id %s is not in QLog 1.5.8\'s scan list '
				+ '(usb_linux.c:259-268, main.c:910-934) — it will most likely report '
				+ '"No Quectel Modules found"', o.usbid));
	}

	// -s is REQUIRED. Without it QLog writes into the relative directory
	// "qlog_files" (args.logdir initialiser, main.c:800) — on a router, flash,
	// next to wherever the CLI happened to run, which is the exact failure the
	// whole feature exists to avoid.
	let sink = o.sink;

	if (!length(sink ?? ''))
		return { error: 'no_sink',
			detail: 'missing -s <sink>. QLog defaults to the relative directory '
			      + '"qlog_files" (main.c:800), which on a router means flash — '
			      + 'name a sink: a mounted path, "9000" (TCP server), "IP:9000", '
			      + '"tftp:IP" or "ftp:IP-user:xxx-pass:xxx"' };

	let cur = capture_status(fx, o.modem, o.port);

	if (cur.running)
		return { error: 'busy', detail: sprintf('a QLog capture is already running on %s (pid %d%s) '
			+ '— stop it first', cur.port, cur.pid, cur.tracked ? '' : ', untracked') };

	if (sink_kind(sink) == 'dir')
		push(warnings, sprintf('sink %s is a local directory — a QMDL grows by tens of MB per '
			+ 'minute; prefer a TCP/TFTP/FTP sink or a mounted USB stick', sink));

	let argv = build_argv(o.port, o.profile, o.tail);
	let logf = log_file(o.modem);

	// Backgrounded inside the shell, with all three fds redirected, so the
	// capture survives the CLI exiting and nothing is left holding a pipe that
	// would SIGPIPE QLog on its next message. POSIX requires a non-interactive
	// shell to set SIGINT/SIGQUIT to ignore in an asynchronous list, so a Ctrl-C
	// landing on the CLI mid-start does not take the capture with it.
	// `echo $!` is the only way back to the pid: the shell exits immediately and
	// waitpid on IT would report the shell, not QLog.
	let quoted = [];

	for (let a in argv)
		push(quoted, shq(a));

	let out = fx.popen(sprintf('mkdir -p %s; %s >%s 2>&1 </dev/null & echo $!',
		shq(RUN_DIR), join(' ', quoted), shq(logf)));

	let pid = +trim(sprintf('%s', out ?? ''));

	if (!(pid > 0))
		return { error: 'spawn', detail: 'could not start QLog (no pid from the shell)' };

	let state = {
		pid: pid,
		port: o.port,
		profile: o.profile ?? '',
		sink: sink,
		started: fx.now(),
		command: join(' ', quoted),
		logfile: logf,
	};

	// written before anything else can interrupt us, so the window in which a
	// capture exists untracked is a single popen wide (and scan_captures closes
	// even that)
	write_state(fx, o.modem, state);

	return { ok: true, warnings: warnings, argv: argv, ...state };
}

// stop(fx, o) — o = { modem, port }. SIGTERM first: QLog installs a handler for
// TERM/HUP/INT that sets qlog_exit_requested (main.c:707-712) and unwinds the
// filter/QDSS state on the modem, so killing it outright leaves the module
// logging. SIGKILL only after the grace period.
function stop(fx, o)
{
	let cur = capture_status(fx, o.modem, o.port);

	if (!cur.running) {
		if (cur.stale)
			fx.unlink(state_file(o.modem));

		return { error: 'not_running',
			detail: sprintf('no QLog capture running for %s', o.modem) };
	}

	// one spawn for the whole term-wait-kill dance; ucode has no sleep and the
	// CLI has no uloop.
	//
	// WHOLE SECONDS. `sleep 0.5` is a GNU coreutils extension; busybox ash — which
	// is every OpenWrt router — answers "sleep: invalid number '0.5'" and returns
	// immediately, so the grace period did not exist: the loop spun through its
	// twenty iterations in microseconds and SIGKILLed a QLog that had been given
	// no time to unwind the modem's filter state. It printed the complaint twenty
	// times over while doing it. (HW-observed on an NR7101, 2026-09-12.)
	//
	// Ten seconds of grace, checked once a second, same ceiling as before.
	fx.run([ '/bin/sh', '-c', sprintf(
		'kill -TERM %d 2>/dev/null; i=0; while [ $i -lt 10 ]; do kill -0 %d 2>/dev/null || exit 0; '
		+ 'sleep 1; i=$((i+1)); done; kill -KILL %d 2>/dev/null',
		cur.pid, cur.pid, cur.pid) ]);

	fx.unlink(state_file(o.modem));

	let left = proc_argv(fx, cur.pid);

	return { ok: true, pid: cur.pid, port: cur.port, tracked: cur.tracked,
		killed: is_qlog_argv(left) };
}

// status(fx, o) — o = { modem, port, log_lines? }
function status(fx, o)
{
	let cur = capture_status(fx, o.modem, o.port);
	let logf = log_file(o.modem);
	let tail = null;

	if (fx.exists(logf)) {
		let raw = sprintf('%s', fx.read(logf) ?? '');
		let lines = split(trim(raw), '\n');
		let n = o.log_lines ?? 10;

		tail = (length(lines) > n) ? slice(lines, length(lines) - n) : lines;
	}

	return { ...cur, logfile: fx.exists(logf) ? logf : null, log: tail };
}

return {
	QLOG_BIN, PROFILE_DIR, RUN_DIR,
	default_fx,
	port_supported, usbid_supported, sink_kind,
	list_profiles, resolve_profile,
	split_args, build_argv, shq,
	state_file, log_file, proc_argv, is_qlog_argv, argv_port, scan_captures,
	read_state, write_state, capture_status,
	start, stop, status,
};
