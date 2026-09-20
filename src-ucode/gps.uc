// SPDX-License-Identifier: GPL-2.0-only
//
// wwand — GPS glue: point ugps at the modem's NMEA port.
//
// An exportless plain script loaded with require(), like esim.uc: require()
// cannot compile ES modules (`export` is a syntax error there), and this ships
// in its own optional package. It returns its API object at the end.
//
// The three pieces this joins already existed and had nothing between them:
//
//   - wwand FINDS the NMEA port. `atport.uc`'s role table identifies it during
//     enumeration and it lands on the modem as `gps_tty` (also reported as
//     `gps_port` in `wwand status`).
//   - wwand STARTS the receiver. `option gnss` runs the vendor AT command
//     (`modem_common.start_gnss`) — QMI's LOC service is documented as broken
//     on Quectel (docs/backend-interface.md), and the thing that works is AT,
//     which only wwand has the port for.
//   - ugps READS the port: it parses NMEA, optionally sets the clock, and
//     publishes a `gps` ubus object. It is in OpenWrt base and needs no
//     modem knowledge at all.
//
// What was missing is that ugps takes a STATIC tty out of /etc/config/gps
// (`ugps.init`: `uci get gps.@gps[-1].tty`) while wwand's is discovered, and
// can move between boots or when a modem is replaced. So this writes it.
//
// GOOD CITIZEN, the same rule the rest of the tree follows. wwand manages
// exactly one `config gps` section and only one it created itself, marked with
// `option wwand '1'`. An operator's own section — a hat GPS on a serial port,
// a second receiver — is never touched, never reordered, and never disabled.
// Without that marker this would be a config writer with an opinion about
// somebody else's hardware.

// NO LOGGING FROM HERE, and that is not an oversight. require() gives the
// loaded script its OWN copies of its imports (docs/gotchas.md), so a
// `wwand.log` imported here is a second instance whose output target was never
// set — every line would go to stderr and procd would tag the lot as
// `daemon.err`, which is exactly what happened the first time this did log.
// `sync()` returns what it did; the caller, which is a real module, says so.

'use strict';

const PKG = 'gps';

// THE LAST SECTION IS THE ONLY ONE THAT MATTERS. ugps reads
// `uci get gps.@gps[-1].tty` (its init), so a section that is not last is one
// ugps never looks at — writing it and reporting success would be a change
// that cannot take effect.
//
// Returns { name, mine } for the last `config gps`, or null when there is none.
function last_section(cursor)
{
	let found = null;

	cursor.foreach(PKG, 'gps', (s) => {
		found = { name: s['.name'], mine: (s.wwand == '1' || s.wwand == 1) };
	});

	return found;
};

// Point ugps at `port`, or (port == null) stop it pointing anywhere.
//
// Idempotent by read-before-write, like every other setter in this tree: an
// unchanged config writes nothing and triggers no reload, because a reload
// restarts ugps and a restarted ugps loses its fix.
//
// Returns { changed, section, skipped } — `skipped` names why nothing was done.
function sync(cursor, port, opts)
{
	let last = last_section(cursor);

	// Somebody else's section is what ugps reads. Leave it entirely alone —
	// appending ours would take their receiver over, and editing theirs is not
	// ours to do. That covers both shapes: only theirs, and OURS FOLLOWED BY
	// THEIRS, which the first version of this treated as ours to update while
	// ugps went on reading theirs — a change reported as successful that could
	// not take effect. Raised by Codex review, 2026-09-20.
	if (last != null && !last.mine)
		return { changed: false, section: null, skipped: 'foreign_config' };

	let mine = last?.name;

	if (mine == null) {
		if (port == null)
			return { changed: false, section: null, skipped: 'nothing_to_do' };

		mine = cursor.add(PKG, 'gps');

		if (mine == null)
			return { changed: false, section: null, skipped: 'add_failed' };

		cursor.set(PKG, mine, 'wwand', '1');
	}

	let want = {
		tty: port,
		disabled: (port == null) ? '1' : '0',
		// ugps can step the clock from NMEA. OFF by default and deliberately:
		// this box already has sysntpd, and two things setting the clock is one
		// more than any box needs. `adjust_time` turns it on for the RTC-less
		// installs where the modem is the only time source there is.
		adjust_time: (opts?.adjust_time ?? false) ? '1' : '0',
	};

	if (opts?.baudrate != null)
		want.baudrate = sprintf('%d', opts.baudrate);

	let changed = false;

	for (let k, v in want) {
		if (v == null)
			continue;

		let cur = cursor.get(PKG, mine, k);

		if (sprintf('%s', cur ?? '') == sprintf('%s', v))
			continue;

		cursor.set(PKG, mine, k, v);
		changed = true;
	}

	if (!changed)
		return { changed: false, section: mine, skipped: 'unchanged' };

	if (!cursor.commit(PKG))
		return { changed: false, section: mine, skipped: 'commit_failed' };

	return { changed: true, section: mine, port: port };
};

// What wwand knows about this modem's GNSS, merged with what ugps reports.
//
// ugps' answer is passed through AS IT COMES rather than being re-keyed into a
// vocabulary of our own: it is another daemon's schema, this side has no
// business freezing it, and a key it gains is then simply there. `fix` is the
// one thing added, because "is there a position" is the question every caller
// starts with and `signal` alone does not answer it on an empty reply.
function status(modem, ugps_info)
{
	let info = (type(ugps_info) == 'object') ? ugps_info : null;

	// ugps ANSWERS IN STRINGS, and uses an EMPTY one for a field it has no
	// value for — `"elevation": ""`, `"satellites": ""` (measured on the
	// GL-X3000, 2026-09-20). So "present" is not "not null": a fix keyed off
	// `latitude != null` would call an empty string a position.
	let val = (k) => {
		let v = info?.[k];

		return (v == null || sprintf('%s', v) == '') ? null : v;
	};

	let has_fix = (val('latitude') != null) && (val('longitude') != null);

	return {
		port: modem?.gps_tty ?? null,
		// the receiver, as against the reader: `option gnss` is what turns the
		// modem's GNSS on, and a port with nothing sending on it looks exactly
		// like a port nobody is reading.
		receiver: (modem?.config?.gnss ?? false),
		receiver_started: (modem?.gnss_started ?? false),
		// ugps is a separate process; absent means it is not running or has
		// never answered, which is a different thing from "no fix".
		reader: (info != null),
		fix: has_fix,
		...(info ?? {}),
	};
};

return {
	sync: sync,
	status: status,
	last_section: last_section,
};
