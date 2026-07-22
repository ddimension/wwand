// wwand — logging. Writes to stderr; procd forwards that to syslog.

'use strict';

const LEVELS = { err: 3, warn: 4, notice: 5, info: 6, debug: 7 };

let threshold = LEVELS.info;

export function set_level(name)
{
	threshold = LEVELS[name] ?? LEVELS.info;
}

export function valid_level(name)
{
	return exists(LEVELS, name);
}

export function log(level, fmt, ...args)
{
	if ((LEVELS[level] ?? 7) > threshold)
		return;

	// strip control characters (e.g. the \x0b some modems prefix to the PLMN
	// name) so each entry stays on one clean line in syslog
	let msg = replace(sprintf('%s: ' + fmt, level, ...args), /[[:cntrl:]]/g, '');

	warn(msg + "\n");
}

export function err(fmt, ...args)    { log('err', fmt, ...args); }
export function warning(fmt, ...args){ log('warn', fmt, ...args); }
export function notice(fmt, ...args) { log('notice', fmt, ...args); }
export function info(fmt, ...args)   { log('info', fmt, ...args); }
export function debug(fmt, ...args)  { log('debug', fmt, ...args); }
