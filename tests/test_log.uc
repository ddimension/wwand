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
	'log.notice("ctrl-\\x0bscrubbed");';

let testdir = fs.dirname(sourcepath());
let cmd = sprintf(`%s -L '%s/*.uc' -e '%s' 2>&1`, ucode, testdir, script);
let out = fs.popen(cmd)?.read('all') ?? '';
let lines = filter(split(out, '\n'), (l) => length(l));

eq(lines, [
	'info: default-info',
	'err: errlevel-err',
	'debug: now-debug',
	'notice: ctrl-scrubbed',
], 'log: threshold defaults, set_level, prefix + control-char scrub');

ok(index(out, '\x0b') < 0, 'log: control character stripped from output');

done('test_log');
