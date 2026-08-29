// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — logging. The primary sink is /dev/log (the syslog datagram socket),
// so each message carries its real severity (via the native wwand.io seam);
// when /dev/log is unreachable it falls back to stderr (procd forwards that to
// syslog too, but at one fixed priority). Target and level are overridable.

'use strict';

// 'error'/'warning' are accepted as aliases of the syslog names: they are what
// one types by reflex, and a level the table does not know used to be demoted
// to debug — which SILENTLY hid the message at the default threshold. That bit
// exactly once, on an AT-command refusal that was supposed to be loud.
const LEVELS = { err: 3, error: 3, warn: 4, warning: 4, notice: 5, info: 6, debug: 7 };
// severity -> canonical name (numeric object keys must be quoted in ucode)
const NAMES = { '3': 'err', '4': 'warn', '5': 'notice', '6': 'info', '7': 'debug' };
const LOG_DAEMON = 3;   // syslog facility

let threshold = LEVELS.info;
let target = 'auto';    // 'auto' (syslog, else stderr) | 'syslog' | 'stderr'
let io = null;          // native seam (wwand.io), when it provides syslog_*

export function set_level(name)
{
	threshold = LEVELS[name] ?? LEVELS.info;
};

export function valid_level(name)
{
	return exists(LEVELS, name);
};

// Wire the native module + initial level/target once at startup. Kept optional:
// host tests and an older wwand_io.so without the seam simply log to stderr.
// Returns whether /dev/log was reachable at open time (informational).
export function open(iomod, opts)
{
	io = (iomod && type(iomod.syslog_open) == 'function') ? iomod : null;

	if (opts?.level)
		set_level(opts.level);

	if (opts?.target)
		target = opts.target;

	if (io && target != 'stderr')
		return io.syslog_open('wwand', LOG_DAEMON);

	return false;
};

export function set_target(name)
{
	if (name != 'auto' && name != 'syslog' && name != 'stderr')
		return false;

	target = name;

	if (io && target != 'stderr')
		io.syslog_open('wwand', LOG_DAEMON);

	return true;
};

export function log(level, fmt, ...args)
{
	// an unknown level is a caller mistake, so keep the message VISIBLE rather
	// than demote it to debug: whoever wrote the call meant it to be logged
	let sev = LEVELS[level] ?? LEVELS.notice;

	if (sev > threshold)
		return;

	// the stderr prefix is the CANONICAL name for that severity, not what the
	// caller typed: 'error' and 'err' must not produce two spellings of the
	// same line, and 'chatty:' would be a prefix nothing greps for
	let tag = NAMES[sprintf('%d', sev)] ?? 'notice';

	// Control characters must not reach syslog raw — one entry has to stay one
	// line (e.g. the \x0b some modems prefix to the PLMN name). CR and LF are
	// ESCAPED rather than dropped, though: a modem that separates two URCs with
	// a bare CR used to produce one seamless log line with no hint that two
	// lines had been merged, which makes a framing bug unreadable in exactly
	// the log you would use to find it. Everything else is still dropped.
	let body = replace(sprintf(fmt, ...args), /\r/g, '\\r');
	body = replace(body, /\n/g, '\\n');
	body = replace(body, /[[:cntrl:]]/g, '');

	// primary: /dev/log with the real priority. syslog_emit connects on demand
	// and reconnects once if logd restarted; a false return (no /dev/log) drops
	// through to stderr, so logd coming up late is picked up automatically.
	if (io && target != 'stderr' && io.syslog_emit(sev, body))
		return;

	warn(sprintf('%s: %s', tag, body) + "\n");
};

export function err(fmt, ...args)    { log('err', fmt, ...args); };
export function warning(fmt, ...args){ log('warn', fmt, ...args); };
export function notice(fmt, ...args) { log('notice', fmt, ...args); };
export function info(fmt, ...args)   { log('info', fmt, ...args); };
export function debug(fmt, ...args)  { log('debug', fmt, ...args); };
