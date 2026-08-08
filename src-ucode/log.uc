// wwand — logging. The primary sink is /dev/log (the syslog datagram socket),
// so each message carries its real severity (via the native wwand.io seam);
// when /dev/log is unreachable it falls back to stderr (procd forwards that to
// syslog too, but at one fixed priority). Target and level are overridable.

'use strict';

const LEVELS = { err: 3, warn: 4, notice: 5, info: 6, debug: 7 };
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
	let sev = LEVELS[level] ?? LEVELS.debug;

	if (sev > threshold)
		return;

	// strip control characters (e.g. the \x0b some modems prefix to the PLMN
	// name) so each entry stays on one clean line
	let body = replace(sprintf(fmt, ...args), /[[:cntrl:]]/g, '');

	// primary: /dev/log with the real priority. syslog_emit connects on demand
	// and reconnects once if logd restarted; a false return (no /dev/log) drops
	// through to stderr, so logd coming up late is picked up automatically.
	if (io && target != 'stderr' && io.syslog_emit(sev, body))
		return;

	warn(sprintf('%s: %s', level, body) + "\n");
};

export function err(fmt, ...args)    { log('err', fmt, ...args); };
export function warning(fmt, ...args){ log('warn', fmt, ...args); };
export function notice(fmt, ...args) { log('notice', fmt, ...args); };
export function info(fmt, ...args)   { log('info', fmt, ...args); };
export function debug(fmt, ...args)  { log('debug', fmt, ...args); };
