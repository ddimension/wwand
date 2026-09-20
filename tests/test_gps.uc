// wwand — GPS glue (wwand-gps): the ugps config wwand writes, and the one it
// must never touch.
//
// The rule this pins is not the config format, it is OWNERSHIP. ugps reads the
// LAST `config gps` section (`uci get gps.@gps[-1].tty`, ugps.init), so writing
// one on a box that already has an operator's receiver would take it over
// silently. wwand manages exactly one section and only one it created itself.

'use strict';

import { eq, ok, done } from './lib/check.uc';

let gps = require('wwand.gps');

ok(type(gps) == 'object', 'gps: module loads via require()');

// a minimal uci cursor over an in-memory package
function cursor(sections) {
	let pkg = sections ?? [];
	let n = 0;

	return {
		_pkg: pkg,
		commits: 0,
		foreach: (p, t, fn) => {
			for (let s in pkg)
				if (s['.type'] == t)
					fn(s);
		},
		add: (p, t) => {
			let name = sprintf('cfg%d', ++n);
			push(pkg, { '.name': name, '.type': t });
			return name;
		},
		get: (p, sec, key) => {
			for (let s in pkg)
				if (s['.name'] == sec)
					return s[key];
			return null;
		},
		set: function(p, sec, key, val) {
			for (let s in pkg)
				if (s['.name'] == sec)
					s[key] = val;
		},
		commit: function(p) { this.commits++; return true; },
	};
}

// --- an empty box: wwand writes its own section and marks it ----------------
{
	let c = cursor([]);
	let r = gps.sync(c, '/dev/ttyUSB3', {});

	eq(r.changed, true, 'sync: an empty config is written');
	eq(c.get('gps', r.section, 'tty'), '/dev/ttyUSB3', 'sync: the tty is the discovered port');
	eq(c.get('gps', r.section, 'disabled'), '0', 'sync: ...and ugps is enabled');
	eq(c.get('gps', r.section, 'wwand'), '1', 'sync: the section is marked as ours');
	eq(c.get('gps', r.section, 'adjust_time'), '0',
		'sync: the clock is left to sysntpd unless asked');
	eq(c.commits, 1, 'sync: committed once');
}

// --- idempotent: an unchanged config writes nothing --------------------------
//
// Not a nicety. A commit fires procd's reload trigger, a reload restarts ugps,
// and a restarted ugps loses its fix — so an unchanged write costs a position.
{
	let c = cursor([]);
	gps.sync(c, '/dev/ttyUSB3', {});
	let after = c.commits;

	let r = gps.sync(c, '/dev/ttyUSB3', {});

	eq(r.changed, false, 'sync: the same port again changes nothing');
	eq(r.skipped, 'unchanged', 'sync: ...and says why');
	eq(c.commits, after, 'sync: no commit, so no reload, so no lost fix');
}

// --- the port moved: rewritten ----------------------------------------------
{
	let c = cursor([]);
	gps.sync(c, '/dev/ttyUSB3', {});
	let r = gps.sync(c, '/dev/ttyUSB1', {});

	eq(r.changed, true, 'sync: a moved port is written');
	eq(c.get('gps', r.section, 'tty'), '/dev/ttyUSB1', 'sync: ...to the new tty');
}

// --- no port: ugps is stopped, not left pointing at a device that is gone ----
{
	let c = cursor([]);
	let s = gps.sync(c, '/dev/ttyUSB3', {}).section;
	let r = gps.sync(c, null, {});

	eq(r.changed, true, 'sync: a vanished port is acted on');
	eq(c.get('gps', s, 'disabled'), '1', 'sync: ugps is disabled rather than left respawning');
}

// --- ugps SHIPS ITS OWN SECTION, and it is always the last one ---------------
//
// `files/gps.config` in the ugps package: tty 'ttyACM0', adjust_time '1',
// disabled '1'. So on a FRESH INSTALL the last section is always foreign, and a
// rule that stopped at "not ours" would refuse every box the package was ever
// installed on. Found by installing it properly on a second router rather than
// on one where the section had been cleared by hand (2026-09-20).
//
// A DISABLED section is not a receiver in service — ugps' own init returns early
// unless `disabled` is exactly '0' — so that one is adopted, marked, and the
// adoption is reported.
{
	let c = cursor([ { '.name': 'cfg01', '.type': 'gps',
	                   tty: 'ttyACM0', adjust_time: '1', disabled: '1' } ]);
	let r = gps.sync(c, '/dev/ttyUSB1', {});

	eq(r.changed, true, 'shipped default: the ugps default is adopted, not refused');
	eq(r.adopted, true, 'shipped default: ...and the adoption is reported');
	eq(r.section, 'cfg01', 'shipped default: the same section, not a second one');
	eq(length(c._pkg), 1, 'shipped default: nothing is appended beside it');
	eq(c.get('gps', 'cfg01', 'wwand'), '1', 'shipped default: it is marked as ours now');
	eq(c.get('gps', 'cfg01', 'tty'), '/dev/ttyUSB1', 'shipped default: pointed at the modem');
	eq(c.get('gps', 'cfg01', 'disabled'), '0', 'shipped default: ...and enabled');
	eq(c.get('gps', 'cfg01', 'adjust_time'), '0',
		'shipped default: the clock is handed back to sysntpd unless asked');
}

// ...and once adopted it is simply ours: the second pass changes nothing.
{
	let c = cursor([ { '.name': 'cfg01', '.type': 'gps',
	                   tty: 'ttyACM0', adjust_time: '1', disabled: '1' } ]);
	gps.sync(c, '/dev/ttyUSB1', {});
	let r = gps.sync(c, '/dev/ttyUSB1', {});

	eq(r.changed, false, 'shipped default: the next pass is a no-op');
	eq(r.skipped, 'unchanged', 'shipped default: ...and says so');
}

// An adoption with NO port is not an adoption: there is nothing to point at, so
// the shipped default is left exactly as it was found.
{
	let c = cursor([ { '.name': 'cfg01', '.type': 'gps',
	                   tty: 'ttyACM0', adjust_time: '1', disabled: '1' } ]);
	let r = gps.sync(c, null, {});

	eq(r.changed, false, 'shipped default: no port, no adoption');
	eq(c.get('gps', 'cfg01', 'wwand'), null, 'shipped default: ...and no marker left behind');

	// ...and the section is still adoptable afterwards. That is the sequence a
	// real box walks: the modem comes up without `option gnss`, it is switched
	// on later, and the default must still be recognisable as untouched.
	let r2 = gps.sync(c, '/dev/ttyUSB1', {});

	eq(r2.adopted, true, 'shipped default: still adoptable after a no-port pass');
	eq(c.get('gps', 'cfg01', 'tty'), '/dev/ttyUSB1', 'shipped default: ...and then pointed');
}

// A SECTION THAT IS MERELY DISABLED IS NOT THE SHIPPED DEFAULT.
//
// "Disabled" is not evidence of ownership: an operator may have switched their
// own receiver off on purpose, and adopting that would overwrite their tty and
// stamp their section as ours. Only the package's UNTOUCHED default is adopted
// — the content is the test, not the flag. Raised by Codex review, 2026-09-20.
{
	let their = (extra) => {
		let sec = { '.name': 'theirs', '.type': 'gps',
		            tty: 'ttyACM0', adjust_time: '1', disabled: '1', ...(extra ?? {}) };
		let c = cursor([ sec ]);
		return { r: gps.sync(c, '/dev/ttyUSB1', {}), c: c };
	};

	// their own receiver, switched off
	let a = their({ tty: '/dev/ttyS1' });
	eq(a.r.skipped, 'foreign_config', 'not-default: another tty is theirs, disabled or not');
	eq(a.c.get('gps', 'theirs', 'tty'), '/dev/ttyS1', 'not-default: ...and is not touched');

	// the default with one option changed
	eq(their({ adjust_time: '0' }).r.skipped, 'foreign_config',
		'not-default: a cleared adjust_time means somebody has been here');

	// the default with an option ADDED
	eq(their({ baudrate: '9600' }).r.skipped, 'foreign_config',
		'not-default: an added option means the same');

	// ...and a section carrying only some of the three is not it either
	{
		let c = cursor([ { '.name': 'part', '.type': 'gps', tty: 'ttyACM0', disabled: '1' } ]);
		eq(gps.sync(c, '/dev/ttyUSB1', {}).skipped, 'foreign_config',
			'not-default: two of the three options is not the shipped default');
	}
}

// --- AN OPERATOR'S OWN SECTION IS NOT OURS -----------------------------------
//
// ugps reads the LAST section, so adding one would take over their receiver.
// Nothing is written, and the refusal names itself.
{
	let c = cursor([ { '.name': 'theirs', '.type': 'gps', tty: '/dev/ttyS1', disabled: '0' } ]);
	let r = gps.sync(c, '/dev/ttyUSB3', {});

	eq(r.changed, false, 'foreign: an operator section is left alone');
	eq(r.skipped, 'foreign_config', 'foreign: ...and the refusal says why');
	eq(length(c._pkg), 1, 'foreign: no section was added beside it');
	eq(c.get('gps', 'theirs', 'tty'), '/dev/ttyS1', 'foreign: their tty is untouched');
}

// OURS FOLLOWED BY THEIRS IS ALSO THEIRS. The operator added a section after
// wwand had written one — and ugps reads the LAST, so updating ours would be a
// change reported as successful that ugps never looks at. Refused, like any
// other config that is not ours to drive. (This case read the other way round
// until a review asked what ugps actually reads.)
{
	let c = cursor([
		{ '.name': 'mine', '.type': 'gps', tty: '/dev/ttyUSB3', disabled: '0', wwand: '1' },
		{ '.name': 'theirs', '.type': 'gps', tty: '/dev/ttyS1', disabled: '0' },
	]);
	let r = gps.sync(c, '/dev/ttyUSB1', {});

	eq(r.changed, false, 'mixed: a foreign LAST section wins, even past one of ours');
	eq(r.skipped, 'foreign_config', 'mixed: ...and the refusal says why');
	eq(c.get('gps', 'mine', 'tty'), '/dev/ttyUSB3', 'mixed: ours is left as it was');
	eq(c.get('gps', 'theirs', 'tty'), '/dev/ttyS1', 'mixed: theirs is untouched');
}

// ...and THEIRS FOLLOWED BY OURS is ours: ugps reads the last one, which is the
// section wwand created, so driving it changes what ugps does.
{
	let c = cursor([
		{ '.name': 'theirs', '.type': 'gps', tty: '/dev/ttyS1', disabled: '0' },
		{ '.name': 'mine', '.type': 'gps', tty: '/dev/ttyUSB3', disabled: '0', wwand: '1' },
	]);
	let r = gps.sync(c, '/dev/ttyUSB1', {});

	eq(r.changed, true, 'mixed: our own LAST section is ours to update');
	eq(r.section, 'mine', 'mixed: ...and it is the one we marked');
	eq(c.get('gps', 'theirs', 'tty'), '/dev/ttyS1', 'mixed: theirs is still untouched');
}

// --- the clock option --------------------------------------------------------
{
	let c = cursor([]);
	let r = gps.sync(c, '/dev/ttyUSB3', { adjust_time: true, baudrate: 115200 });

	eq(c.get('gps', r.section, 'adjust_time'), '1', 'sync: adjust_time when asked');
	eq(c.get('gps', r.section, 'baudrate'), '115200', 'sync: and a baudrate when given');
}

// --- status: two halves of one answer ----------------------------------------
//
// ugps' reply is passed through as it comes — it is another daemon's schema and
// this side has no business freezing it. `fix` is the one thing added, because
// "is there a position" is the question every caller starts with.
{
	let m = { gps_tty: '/dev/ttyUSB3', gnss_started: true, config: { gnss: true } };

	let s = gps.status(m, { latitude: 52.5, longitude: 13.4, satellites: 9, signal: true });

	eq(s.port, '/dev/ttyUSB3', 'status: the port wwand found');
	eq(s.receiver, true, 'status: the receiver was asked for');
	eq(s.receiver_started, true, 'status: ...and started');
	eq(s.reader, true, 'status: ugps answered');
	eq(s.fix, true, 'status: and there is a position');
	eq(s.satellites, 9, 'status: ugps keys are passed through, not re-keyed');

	// no ugps at all is a different thing from no fix, and must read that way
	let n = gps.status(m, null);
	eq(n.reader, false, 'status: ugps not running is reported as such');
	eq(n.fix, false, 'status: ...and that is not a fix');
	eq(n.port, '/dev/ttyUSB3', 'status: wwand\'s own half still answers');

	// ugps running with no fix: signal false, no coordinates
	let f = gps.status(m, { signal: false });
	eq(f.reader, true, 'status: ugps running with no fix is still running');
	eq(f.fix, false, 'status: ...and has no position');

	// UGPS ANSWERS IN STRINGS, and uses an EMPTY one for a field it has no
	// value for — `"elevation": ""`, `"satellites": ""` (measured on a
	// GL-X3000, 2026-09-20). A fix keyed off `latitude != null` would call an
	// empty string a position, and every consumer downstream would agree.
	let blank = gps.status(m, { latitude: '', longitude: '', elevation: '', signal: true });
	eq(blank.fix, false, 'status: an empty latitude is not a position');

	// ...and the strings that ARE there are a fix
	let str = gps.status(m, { latitude: '52.035816', longitude: '8.549176',
	                          elevation: '', satellites: '', age: 6 });
	eq(str.fix, true, 'status: coordinates as strings are still coordinates');
	eq(str.latitude, '52.035816',
		'status: ...and are passed through as ugps sent them, not re-typed');

	// a receiver nobody asked for
	let off = gps.status({ gps_tty: '/dev/ttyUSB3', config: {} }, null);
	eq(off.receiver, false, 'status: `option gnss` unset reads as no receiver');
}

done('test_gps');
