// wwand tests — log.uc: level threshold, level validation and the
// control-character scrub. Output goes to stderr, so the emitting side runs
// in a child ucode and the parent asserts on the captured lines.
'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as fs from 'fs';
import * as logmod from 'wwand/log.uc';

// --- valid_level -------------------------------------------------------------

ok(logmod.valid_level('debug'), 'valid_level: debug');
ok(logmod.valid_level('err'), 'valid_level: err');
ok(logmod.valid_level('error'), 'valid_level: error accepted as an err alias');
ok(!logmod.valid_level('chatty'), 'valid_level: unknown rejected');
ok(!logmod.valid_level(null), 'valid_level: null rejected');

// --- threshold + scrub (child process, stderr captured) ----------------------

let ucode = getenv('HOME') + '/.local/bin/ucode';

if (!fs.access(ucode, 'x'))
	ucode = 'ucode';

let script = 'import * as log from "wwand/log.uc"; ' +
	'log.log("info", "default-info"); ' +
	'log.log("debug", "default-debug-suppressed"); ' +
	'log.set_level("err"); ' +
	'log.log("warn", "errlevel-warn-suppressed"); ' +
	'log.err("errlevel-err"); ' +
	'log.set_level("debug"); ' +
	'log.debug("now-debug"); ' +
	'log.notice("ctrl-\\x0bscrubbed"); ' +
	// a URC pair the modem separated with a bare CR: the merge must stay
	// VISIBLE (one log line, but the boundary spelled out) instead of reading
	// like one seamless line
	'log.notice("+CEREG: 1\\r1,\\"88ce\\""); ' +
	// a level the table does not know must stay VISIBLE. It used to fall back
	// to debug, which hid it at the default threshold — how an AT-command
	// refusal logged as 'error' (not a syslog name) never reached the log.
	'log.set_level("info"); ' +
	'log.log("error", "alias-error-visible"); ' +
	'log.log("chatty", "unknown-level-still-visible");';

let testdir = fs.dirname(sourcepath());
let cmd = sprintf(`%s -L '%s/*.uc' -e '%s' 2>&1`, ucode, testdir, script);
let out = fs.popen(cmd)?.read('all') ?? '';
let lines = filter(split(out, '\n'), (l) => length(l));

eq(lines, [
	'info: default-info',
	'err: errlevel-err',
	'debug: now-debug',
	'notice: ctrl-scrubbed',
	'notice: +CEREG: 1\\r1,"88ce"',
	'err: alias-error-visible',
	'notice: unknown-level-still-visible',
], 'log: threshold defaults, set_level, prefix + control-char scrub');

ok(index(out, '\x0b') < 0, 'log: control character stripped from output');
ok(index(out, "+CEREG: 1\\r1") >= 0, 'log: an embedded CR is escaped, not silently dropped');
ok(length(filter(split(out, '\n'), (l) => index(l, '+CEREG') >= 0)) == 1,
	'log: escaping keeps the entry on ONE syslog line');

// --- syslog seam: priority mapping via an injected fake io (in-process) -------
// emit succeeds, so nothing hits stderr; assert the exact (severity, body) the
// seam receives — real numeric severities, and NO "level:" text prefix.
let emitted = [];
let fake_io = {
	syslog_open: (ident, fac) => true,
	syslog_emit: (sev, msg) => { push(emitted, sprintf('%d|%s', sev, msg)); return true; },
};

ok(logmod.open(fake_io, { level: 'debug', target: 'auto' }) == true,
	'open: reports /dev/log available from the seam');

logmod.log('err', 'e');
logmod.log('warn', 'w');
logmod.log('notice', 'n');
logmod.log('info', 'i %d', 6);
logmod.log('debug', 'd');

eq(emitted, [ '3|e', '4|w', '5|n', '6|i 6', '7|d' ],
	'syslog: severities 3..7 mapped, body without level prefix, args formatted');

// an io lacking the seam (older .so) is ignored -> not "available"
ok(logmod.open({}, { target: 'auto' }) == false, 'open: no seam -> not available');

// --- syslog seam: routing / fallback / target (child, merged std streams) -----
let script2 =
	'import * as log from "wwand/log.uc";' +
	'let io={syslog_open:function(){return true;},' +
	'syslog_emit:function(s,m){if(m=="viastderr")return false;print("SYS "+s+" "+m+"\\n");return true;}};' +
	'log.open(io,{level:"debug",target:"auto"});' +
	'log.notice("hello");' +           /* seam, severity 5 */
	'log.err("viastderr");' +          /* emit false -> stderr fallback */
	'log.set_target("stderr");' +
	'log.info("forced");';             /* target stderr -> bypass seam */

let cmd2 = sprintf(`%s -L '%s/*.uc' -e '%s' 2>&1`, ucode, testdir, script2);
let out2 = fs.popen(cmd2)?.read('all') ?? '';

ok(index(out2, 'SYS 5 hello') >= 0, 'syslog child: notice emitted via seam at severity 5');
ok(index(out2, 'err: viastderr') >= 0, 'syslog child: emit-false falls back to stderr');
ok(index(out2, 'info: forced') >= 0, 'syslog child: target stderr bypasses the seam');
ok(index(out2, 'SYS 6 forced') < 0, 'syslog child: forced-stderr not sent to the seam');

done('test_log');
