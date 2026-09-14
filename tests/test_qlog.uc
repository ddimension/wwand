// wwand tests — the wwand-qlog add-on (qlog.uc): diag capture management.
//
// Every expectation about QLog itself is taken from the bundled V1.5.8 source
// (repository/qlog/files/Quectel_QLog_Linux&Android_V1.5.8.zip), not from the
// module under test:
//   main.c:807      getopt string "p:s:n:m:f:D::qh"
//   main.c:800      args.logdir initialiser "qlog_files" (the flash trap)
//   main.c:738-793  parser_tcp / parser_tftp / parser_ftp  (how -s is read)
//   main.c:1180-1226  which -p prefixes are routed at all
//   main.c:707-712  SIGTERM/HUP/INT -> qlog_exit_requested (graceful stop)
//   usb_linux.c:259-268 + main.c:910-934  the USB scan's VID/PID allow-list
//   qlog.h:31-32    TFTP_F "tftp:" / FTP_F "ftp:"

'use strict';

import { eq, ok, done } from './lib/check.uc';

let qlog = require('wwand.qlog');

// --- a fake world -------------------------------------------------------------
// files{} doubles as the /proc/<pid>/cmdline store (NUL-separated, like the
// kernel's), popen answers a scripted pid, run() and write() are recorded.

function fake_fx(opts) {
	let self = {
		files: { ...(opts?.files ?? {}) },
		popen_out: opts?.popen_out,
		runs: [],
		writes: [],
		unlinked: [],
		popened: [],
		now_value: opts?.now ?? 1700000000,
	};

	self.read = (path) => self.files[path] ?? null;
	self.exists = (path) => self.files[path] != null;
	self.write = (path, data) => { push(self.writes, [ path, data ]); self.files[path] = data; return true; };
	self.unlink = (path) => { push(self.unlinked, path); delete self.files[path]; return true; };
	self.run = (argv) => { push(self.runs, argv); return 0; };
	self.popen = (cmd) => { push(self.popened, cmd); return self.popen_out; };
	self.now = () => self.now_value;

	// POSIX glob over the fake file set: '*' and '?' stop at '/', '[...]' is
	// passed to the regex engine as-is. Covers both patterns the module uses
	// ('<dir>/*.cfg' and '/proc/[0-9]*/cmdline') without special-casing either.
	self.glob = (pat) => {
		let re = '^', i = 0;

		while (i < length(pat)) {
			let c = substr(pat, i, 1);

			if (c == '*')      re += '[^/]*';
			else if (c == '?') re += '[^/]';
			else if (c == '[') {
				let j = index(pat, ']', i);
				re += substr(pat, i, j - i + 1);
				i = j;
			}
			else if (index('.^$+(){}|\\', c) >= 0) re += '\\' + c;
			else re += c;

			i++;
		}

		let rx = regexp(re + '$');
		let out = [];

		for (let path, _ in self.files)
			if (match(path, rx))
				push(out, path);

		return sort(out);
	};

	return self;
}

// the seven profiles repository/qlog/Makefile installs
const PROFILES = {
	'/usr/share/qlog/conf/T1-data-ota-dataservice.cfg': 'x',
	'/usr/share/qlog/conf/T2-registration-context-activation.cfg': 'x',
	'/usr/share/qlog/conf/T3-simple-data.cfg': 'x',
	'/usr/share/qlog/conf/T4-throughput.cfg': 'x',
	'/usr/share/qlog/conf/T5-common.cfg': 'x',
	'/usr/share/qlog/conf/T6-full-message.cfg': 'x',
	'/usr/share/qlog/conf/T7-v2x.cfg': 'x',
};

function cmdline(argv) {
	return join('\x00', argv) + '\x00';
}

// --- profiles -----------------------------------------------------------------

let pfx = fake_fx({ files: { ...PROFILES } });

eq(length(qlog.list_profiles(pfx)), 7, 'profiles: all seven installed profiles are listed');
eq(qlog.list_profiles(pfx)[1].tag, 'T2', 'profiles: the Tn tag is derived from the filename');

// the whole point of the tag: issue #24's case is registration / context
// activation, and nobody should have to type the full name
eq(qlog.resolve_profile(pfx, 'T2').path,
	'/usr/share/qlog/conf/T2-registration-context-activation.cfg',
	'profile: a bare T2 resolves');
eq(qlog.resolve_profile(pfx, 't2').path,
	'/usr/share/qlog/conf/T2-registration-context-activation.cfg',
	'profile: the tag is case-insensitive');
eq(qlog.resolve_profile(pfx, 'T5-common').path, '/usr/share/qlog/conf/T5-common.cfg',
	'profile: the full name resolves');
eq(qlog.resolve_profile(pfx, 'T5-common.cfg').path, '/usr/share/qlog/conf/T5-common.cfg',
	'profile: ...with or without the .cfg suffix');
eq(qlog.resolve_profile(pfx, '').path, null,
	'profile: none given -> QLog default filter, not an error');

// an explicit path is the operator's call (the rule atcmd.find_tty applies to an
// explicit AT port) — only checked for existence
let cust = fake_fx({ files: { ...PROFILES, '/tmp/mine.cfg': 'x' } });
eq(qlog.resolve_profile(cust, '/tmp/mine.cfg').path, '/tmp/mine.cfg', 'profile: an explicit path is taken as given');
eq(qlog.resolve_profile(cust, '/tmp/nope.cfg').error, 'no_profile', 'profile: ...but must exist');

let bad = qlog.resolve_profile(pfx, 'T9');
eq(bad.error, 'no_profile', 'profile: an unknown tag is refused');
ok(index(bad.detail, 'T2 (T2-registration-context-activation)') >= 0,
	'profile: the refusal lists what IS installed');
ok(index(qlog.resolve_profile(fake_fx(), 'T2').detail, 'qlog package installed') >= 0,
	'profile: no profiles at all points at the missing qlog package');

// --- what QLog will and will not take -----------------------------------------

ok(qlog.port_supported('/dev/ttyUSB0'), 'port: ttyUSB is routed (main.c:1226)');
ok(qlog.port_supported('/dev/ttyACM1'), 'port: ttyACM is routed');
ok(qlog.port_supported('/dev/mhi_DIAG'), 'port: the vendor pcie_mhi node is routed (main.c:1180)');
ok(qlog.port_supported('/dev/sdiag_nr'), 'port: the Unisoc node is routed (main.c:1197)');
ok(qlog.port_supported('/sys/bus/usb/devices/1-1'), 'port: a usb device path is routed');
// the one that matters: mainline mhi_wwan_ctrl names the DIAG channel
// /dev/wwan0qcdm0 (wwan_core.c:321 .devsuf, 6.18.41) and QLog 1.5.8 has no
// branch for it — it falls into the USB-only scan and loops forever
eq(qlog.port_supported('/dev/wwan0qcdm0'), false, 'port: a kernel-wwan qcdm node is NOT routed');

ok(qlog.usbid_supported('2c7c:0122 RG650E-EU'), 'usbid: Quectel 0x0xxx (Qualcomm) is scanned');
ok(qlog.usbid_supported('2c7c:0306'), 'usbid: EG06 is scanned');
ok(qlog.usbid_supported('2c7c:6005'), 'usbid: Quectel 0x6xxx is scanned as ASR (main.c:910)');
ok(qlog.usbid_supported('2c7c:0900'), 'usbid: Quectel 0x0900 is scanned as Unisoc (main.c:924)');
ok(qlog.usbid_supported('05c6:9215'), 'usbid: the old EC20 reference id is scanned');
eq(qlog.usbid_supported('05c6:1234'), false, 'usbid: an unlisted Qualcomm id is not');
eq(qlog.usbid_supported('2dee:4d57'), false, 'usbid: MeiG SLM770A is not covered by QLog');
eq(qlog.usbid_supported('0e8d:7127'), false, 'usbid: Fibocom FM350-GL (MediaTek) is not covered by QLog');
eq(qlog.usbid_supported('nonsense'), null, 'usbid: unparseable is unknown, not unsupported');

eq(qlog.sink_kind('9000'), 'tcp-server', 'sink: "9000" is the TCP server mode (main.c:742)');
eq(qlog.sink_kind('192.168.1.5:9000'), 'tcp-client', 'sink: IP:port is the TCP client mode');
eq(qlog.sink_kind('tftp:10.0.0.1'), 'tftp', 'sink: tftp: prefix');
eq(qlog.sink_kind('ftp:10.0.0.1-user:a-pass:b'), 'ftp', 'sink: ftp: prefix');
eq(qlog.sink_kind('/mnt/usb/logs'), 'dir', 'sink: a plain path is local storage');
eq(qlog.sink_kind('8999'), 'dir', 'sink: a port below 9000 is not the TCP server mode');

// --- argument split -----------------------------------------------------------

let sp = qlog.split_args([ '-f', 'T2', '-s', '9000', '-n', '5', '-q' ]);
eq(sp.own, [ '-f', 'T2' ], 'split: everything before -s is ours');
eq(sp.tail, [ '-s', '9000', '-n', '5', '-q' ], 'split: everything from -s on is QLog\'s, verbatim');
eq(sp.sink, '9000', 'split: the sink value is picked out for validation');

let spa = qlog.split_args([ '-s9000', '-m', '64' ]);
eq(spa.tail, [ '-s9000', '-m', '64' ], 'split: an attached -s value is still the boundary');
eq(spa.sink, '9000', 'split: ...and its sink is read');

eq(qlog.split_args([ '-f', 'T2' ]).tail, null, 'split: no -s at all -> no tail');

eq(qlog.build_argv('/dev/ttyUSB0', '/usr/share/qlog/conf/T2-x.cfg', [ '-s', '9000' ]),
	[ '/usr/sbin/QLog', '-p', '/dev/ttyUSB0', '-f', '/usr/share/qlog/conf/T2-x.cfg', '-s', '9000' ],
	'argv: -p and -f are ours, the tail follows untouched');
eq(qlog.build_argv('/dev/ttyUSB0', null, [ '-s', '.' ]),
	[ '/usr/sbin/QLog', '-p', '/dev/ttyUSB0', '-s', '.' ],
	'argv: no profile -> no -f (QLog uses its default filter)');

eq(qlog.shq("a'b"), "'a'\\''b'", 'shq: a quote in a sink string cannot escape the shell');

// --- /proc reconciliation -----------------------------------------------------

const QARGV = [ '/usr/sbin/QLog', '-p', '/dev/ttyUSB0', '-s', '9000' ];

let procfx = fake_fx({ files: {
	'/proc/101/cmdline': cmdline(QARGV),
	'/proc/102/cmdline': cmdline([ '/usr/sbin/QLog', '-p', '/dev/ttyUSB4', '-s', '.' ]),
	'/proc/103/cmdline': cmdline([ '/usr/sbin/wwand' ]),
} });

eq(qlog.argv_port(qlog.proc_argv(procfx, 101)), '/dev/ttyUSB0', 'proc: the -p value is read back off /proc');
ok(qlog.is_qlog_argv(qlog.proc_argv(procfx, 101)), 'proc: a QLog argv is recognised');
ok(!qlog.is_qlog_argv(qlog.proc_argv(procfx, 103)), 'proc: the daemon is not mistaken for one');
eq(qlog.proc_argv(procfx, 999), null, 'proc: a dead pid has no argv');

// a WRAPPED QLog (a shell script by that name, an strace run) puts the binary
// at argv[1], not argv[0] — host-verified with a stand-in /tmp/fakeq/QLog,
// where an argv[0]-only test found nothing at all
ok(qlog.is_qlog_argv([ '/bin/sh', '/usr/local/bin/QLog', '-p', '/dev/ttyUSB0', '-s', '.' ]),
	'proc: a wrapped QLog is still recognised');
// ...but a process that merely MENTIONS QLog is not one
ok(!qlog.is_qlog_argv([ '/bin/grep', 'QLog', '/var/log/messages' ]),
	'proc: a grep for QLog is not a capture (no -p)');
eq(qlog.argv_port([ '/usr/sbin/QLog', '-p/dev/ttyUSB2', '-s', '.' ]), '/dev/ttyUSB2',
	'proc: an attached -p value is read too');

eq(length(qlog.scan_captures(procfx)), 2, 'scan: both live QLogs are found');
eq(qlog.scan_captures(procfx, '/dev/ttyUSB4')[0].pid, 102, 'scan: ...and can be narrowed to one diag port');
eq(length(qlog.scan_captures(procfx, '/dev/ttyUSB9')), 0, 'scan: a port nobody captures on is empty');

// --- state file ---------------------------------------------------------------

let stfx = fake_fx();
qlog.write_state(stfx, 'wwmodem0', { pid: 101, port: '/dev/ttyUSB0', sink: '9000', started: 42 });
let back = qlog.read_state(stfx, 'wwmodem0');
eq(back.pid, 101, 'state: the pid round-trips as a number');
eq(back.port, '/dev/ttyUSB0', 'state: and the port as a string');
eq(qlog.state_file('wan/../etc'), '/tmp/wwand/qlog-wan_.._etc.json',
	'state: a modem name can never escape the run dir');

// a truncated state file must not take the CLI down. ucode's json() RAISES on
// malformed input, which is why this is key=value and not JSON.
let junkfx = fake_fx({ files: { '/tmp/wwand/qlog-m.json': 'pi' } });
eq(qlog.read_state(junkfx, 'm'), null, 'state: a truncated file reads as "no state", not an exception');

// --- capture_status -----------------------------------------------------------

let live = fake_fx({ files: {
	'/proc/101/cmdline': cmdline(QARGV),
	'/tmp/wwand/qlog-m.json': "pid=101\nport=/dev/ttyUSB0\nprofile=\nsink=9000\nstarted=42\n",
} });
let cs = qlog.capture_status(live, 'm', '/dev/ttyUSB0');
ok(cs.running && cs.tracked, 'status: a live tracked capture is reported as such');
eq(cs.sink, '9000', 'status: with the sink it was started with');

// pid reuse: the state file points at a pid that is now something else
let reused = fake_fx({ files: {
	'/proc/101/cmdline': cmdline([ '/usr/sbin/dnsmasq' ]),
	'/tmp/wwand/qlog-m.json': "pid=101\nport=/dev/ttyUSB0\nsink=9000\n",
} });
eq(qlog.capture_status(reused, 'm', '/dev/ttyUSB0').running, false,
	'status: a recycled pid is not mistaken for the capture');

// the case the pid file alone cannot cover: a CLI killed between spawning QLog
// and writing its state leaves an UNTRACKED capture. /proc still finds it, which
// is what keeps it from running forever.
let orphan = fake_fx({ files: { '/proc/777/cmdline': cmdline(QARGV) } });
let ocs = qlog.capture_status(orphan, 'm', '/dev/ttyUSB0');
ok(ocs.running && !ocs.tracked, 'status: an untracked QLog on this port is still found');
eq(ocs.pid, 777, 'status: ...with its pid');

// --- start --------------------------------------------------------------------

function startfx(extra) {
	return fake_fx({ files: { '/usr/sbin/QLog': 'bin', ...PROFILES, ...(extra ?? {}) },
	                 popen_out: "4242\n" });
}

const OK_START = { modem: 'm', port: '/dev/ttyUSB0', usbid: '2c7c:0122 RG650E-EU',
                   profile: '/usr/share/qlog/conf/T2-registration-context-activation.cfg',
                   tail: [ '-s', '9000', '-n', '5' ], sink: '9000' };

let sfx = startfx();
let res = qlog.start(sfx, OK_START);
eq(res.ok, true, 'start: a well-formed request starts');
eq(res.pid, 4242, 'start: the pid comes back from the shell (echo $!)');
ok(index(sfx.popened[0], "'/usr/sbin/QLog' '-p' '/dev/ttyUSB0' '-f' ") == 0 ||
   index(sfx.popened[0], "'/usr/sbin/QLog' '-p' '/dev/ttyUSB0' '-f' ") > 0,
	'start: QLog is invoked with the resolved port and profile');
ok(index(sfx.popened[0], "'-s' '9000' '-n' '5'") >= 0, 'start: the tail is passed through verbatim');
// detached on purpose: all three fds redirected, so nothing is left holding a
// pipe that would SIGPIPE QLog once the CLI exits
ok(index(sfx.popened[0], '</dev/null') >= 0 && index(sfx.popened[0], '2>&1') >= 0,
	'start: the child gets its own stdio, not the CLI\'s pipe');
ok(index(sfx.popened[0], '& echo $!') >= 0, 'start: it is backgrounded and its pid echoed');
eq(sfx.writes[0][0], '/tmp/wwand/qlog-m.json', 'start: the state file is written immediately');
eq(length(res.warnings), 0, 'start: a TCP sink on a supported modem warns about nothing');

// refusals
eq(qlog.start(fake_fx(), OK_START).error, 'no_binary', 'start: no QLog binary -> refuse, named');
eq(qlog.start(startfx(), { ...OK_START, port: null }).error, 'no_port', 'start: no diag port -> refuse');
ok(index(qlog.start(startfx(), { ...OK_START, port: null }).detail, '--port') >= 0,
	'start: ...and the refusal names the way out');
let nosink = qlog.start(startfx(), { ...OK_START, tail: null, sink: null });
eq(nosink.error, 'no_sink', 'start: no -s -> refuse (QLog would write "qlog_files" onto flash)');
ok(index(nosink.detail, 'qlog_files') >= 0, 'start: ...and the refusal says where it WOULD have written');
eq(qlog.start(startfx(), { ...OK_START, tail: [ '-s' ], sink: null }).error, 'no_sink',
	'start: a bare -s with no value is refused too');

// an AUTO-resolved port QLog cannot route is a refusal ...
let wwanres = qlog.start(startfx(), { ...OK_START, port: '/dev/wwan0qcdm0' });
eq(wwanres.error, 'port_unsupported', 'start: an auto-resolved kernel-wwan node is refused');
ok(index(wwanres.detail, 'No Quectel Modules found') >= 0, 'start: ...with what would happen instead');

// ... an EXPLICIT one is the operator's call, and only warns
let wwanexp = qlog.start(startfx(), { ...OK_START, port: '/dev/wwan0qcdm0', port_explicit: true });
eq(wwanexp.ok, true, 'start: --port overrides the refusal');
eq(length(wwanexp.warnings), 1, 'start: ...but says so');

// one capture per modem
let busyfx = startfx({ '/proc/101/cmdline': cmdline(QARGV) });
let busy = qlog.start(busyfx, OK_START);
eq(busy.error, 'busy', 'start: a second capture on the same port is refused');
ok(index(busy.detail, 'untracked') >= 0, 'start: ...even when the running one is untracked');

// warnings that are not refusals
let dirres = qlog.start(startfx(), { ...OK_START, tail: [ '-s', '/tmp/logs' ], sink: '/tmp/logs' });
eq(length(dirres.warnings), 1, 'start: a directory sink warns about local storage');
let meig = qlog.start(startfx(), { ...OK_START, usbid: '2dee:4d57' });
eq(length(meig.warnings), 1, 'start: a modem outside QLog\'s USB scan list warns');

// --- stop ---------------------------------------------------------------------

let stopfx = fake_fx({ files: {
	'/proc/101/cmdline': cmdline(QARGV),
	'/tmp/wwand/qlog-m.json': "pid=101\nport=/dev/ttyUSB0\nsink=9000\n",
} });
let st = qlog.stop(stopfx, { modem: 'm', port: '/dev/ttyUSB0' });
eq(st.ok, true, 'stop: a tracked capture stops');
// SIGTERM first: QLog's handler (main.c:707-712) unwinds the filter/QDSS state
// on the module. SIGKILL would leave the modem logging.
ok(index(stopfx.runs[0][2], 'kill -TERM 101') >= 0, 'stop: SIGTERM first, not SIGKILL');

// WHOLE SECONDS ONLY. `sleep 0.5` is a coreutils extension; busybox ash answers
// "sleep: invalid number '0.5'" and returns at once, so the grace period between
// SIGTERM and SIGKILL silently did not exist — the loop burned through every
// iteration in microseconds and killed a QLog that had had no chance to unwind
// the modem's filter state, printing the complaint once per turn while doing it.
// HW-observed on an NR7101 (busybox), 2026-09-12.
eq(match(stopfx.runs[0][2], /sleep ([0-9.]+)/)?.[1], '1',
	'stop: the grace sleep is whole seconds, not a coreutils fraction');
ok(index(stopfx.runs[0][2], 'kill -KILL 101') >= 0, 'stop: ...SIGKILL only after the grace period');
eq(stopfx.unlinked[0], '/tmp/wwand/qlog-m.json', 'stop: the state file is cleared');

// an untracked capture is stoppable too — this is what "does not run forever"
// actually rests on
let orphstop = fake_fx({ files: { '/proc/777/cmdline': cmdline(QARGV) } });
eq(qlog.stop(orphstop, { modem: 'm', port: '/dev/ttyUSB0' }).pid, 777,
	'stop: an untracked QLog on this port is killed as well');

// a stale state file (the capture died on its own) is cleaned up, not reported
let stalefx = fake_fx({ files: { '/tmp/wwand/qlog-m.json': "pid=101\nport=/dev/ttyUSB0\n" } });
eq(qlog.stop(stalefx, { modem: 'm', port: '/dev/ttyUSB0' }).error, 'not_running',
	'stop: nothing running -> said plainly');
eq(stalefx.unlinked[0], '/tmp/wwand/qlog-m.json', 'stop: ...and the stale state file is removed');

// --- status -------------------------------------------------------------------

let logfx = fake_fx({ files: {
	'/proc/101/cmdline': cmdline(QARGV),
	'/tmp/wwand/qlog-m.json': "pid=101\nport=/dev/ttyUSB0\nsink=9000\n",
	'/tmp/wwand/qlog-m.log': "a\nb\nc\nd\n",
} });
let stt = qlog.status(logfx, { modem: 'm', port: '/dev/ttyUSB0', log_lines: 2 });
eq(stt.log, [ 'c', 'd' ], 'status: the tail of QLog\'s own output is shown');
eq(stt.logfile, '/tmp/wwand/qlog-m.log', 'status: with the path to the whole of it');

done('test_qlog');
