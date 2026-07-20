// wwand — logging. Writes to stderr; procd forwards that to syslog.

'use strict';

const LEVELS = { err: 3, warn: 4, notice: 5, info: 6, debug: 7 };

let threshold = LEVELS.info;

export function set_level(name)
{
	threshold = LEVELS[name] ?? LEVELS.info;
}

export function log(level, fmt, ...args)
{
	if ((LEVELS[level] ?? 7) > threshold)
		return;

	warn(sprintf('%s: ' + fmt + "\n", level, ...args));
}

export function err(fmt, ...args)    { log('err', fmt, ...args); }
export function warning(fmt, ...args){ log('warn', fmt, ...args); }
export function notice(fmt, ...args) { log('notice', fmt, ...args); }
export function info(fmt, ...args)   { log('info', fmt, ...args); }
export function debug(fmt, ...args)  { log('debug', fmt, ...args); }
