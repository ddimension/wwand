// SPDX-License-Identifier: GPL-2.0-only
//
// wwand — the GNSS reader: NMEA off the modem's own port, into wwand's ubus.
//
// An exportless plain script loaded with require(), like esim.uc: require()
// cannot compile ES modules (`export` is a syntax error there), and this ships
// in its own optional package. It returns its API object at the end.
//
// WHY THIS IS OURS NOW. It used to point ugps (OpenWrt base) at the port and
// read its `gps` ubus object back. That worked, and it cost more than it saved:
//
//   - ugps takes a STATIC tty out of /etc/config/gps (ugps.init: `uci get
//     gps.@gps[-1].tty`) while wwand's is discovered and can move between
//     boots. Two hundred lines here did nothing but write that file without
//     treading on an operator's own receiver.
//   - There is ONE `config gps` section and ONE `gps` ubus object, so on a
//     two-modem box only one modem could ever have a position — a limit with
//     no cause in the hardware.
//   - `exit(-1)` on tty EOF (nmea.c nmea_notify_cb): when the modem resets,
//     ugps dies and procd respawns it against a device that is not back yet.
//     wwand already waits for hotplug and knows when the port returns.
//   - It reports `$GP`/`$GN` only, has no GSV and no GSA, and hands every
//     field over as a string with the absent ones empty.
//
// The parts that were hard are already here: `wwand_io.open_tty` (the same
// call atcmd uses for an AT port), the line framing pattern, the port
// discovery in atport.uc, the lifecycle, and `deps.set_clock` — which has the
// better clock policy of the two, since it only ever steps a clock that is
// plainly unset and so never fights sysntpd.
//
// NO LOGGING FROM HERE, and that is not an oversight. require() gives the
// loaded script its OWN copies of its imports (docs/gotchas.md), so a
// `wwand.log` imported here is a second instance whose output target was never
// set — every line would go to stderr and procd would tag the lot as
// `daemon.err`, which is exactly what happened the first time this did log.
// Every entry point returns what it did; the caller, which is a real module,
// says so.

'use strict';

import * as uloop from 'uloop';
import * as nmea from 'wwand.nmea';

// A GNSS port is a plain serial line. 9600 is the NMEA 0183 rate every modem
// in this tree presents; ugps defaults to 4800, which is the 1983 one and
// wrong for all of them. On a USB CDC-ACM port the rate is ignored anyway.
const DEFAULT_BAUD = 9600;

// Longest line we will hold while waiting for its newline. A GSV sentence is
// ~100 bytes and the standard caps a sentence at 82, so anything past this is
// a port that is not speaking NMEA — binary from a modem left in a diagnostic
// mode, most often. Dropping the buffer beats growing it without bound.
const MAX_LINE = 1024;

// create(o) -> reader
//
//   o.path       the tty (required)
//   o.baud       default 9600
//   o.open       injectable opener for tests; must return { fileno, read, close }
//   o.watch      injectable fd watcher; must return { delete }
//   o.now        injectable clock (seconds); defaults to CLOCK_MONOTONIC
//   o.on_epoch   called with a unix epoch whenever the receiver reports one
//   o.on_gone    called with a reason string when the port ends (EOF/error)
//
// `open` and `watch` are injected together by the tests: the EOF path is the
// one worth pinning and it lives inside the watcher's callback, so a test that
// cannot drive that callback cannot reach it.
//
// The reader NEVER exits the process and never restarts itself: the port going
// away is the modem's lifecycle, which the daemon owns.
function create(o) {
	let self = {
		path: o.path,
		running: false,
		error: null,
		// counters, because "no position" has several causes and they are
		// worth telling apart in a status page
		lines: 0, sentences: 0, unparsed: 0,
	};

	let parser = nmea.create();
	let handle = null, uhandle = null, buffer = '', generation = 0;

	// MONOTONIC, and that is not a detail. Every stamp the parser keeps is used
	// for a DIFFERENCE — how old the fix is, how long since a GSV cycle — and
	// the wall clock can jump underneath them. It can jump because of THIS
	// FEATURE: `option gnss_set_time` hands the receiver's own time to
	// deps.set_clock, and a router with no RTC steps from 1970 to now the
	// moment the first RMC lands. On the wall clock that would report an age
	// of fifty-six years and expire every satellite in view at the same
	// instant. context_common.uc:86 does the same for the same reason.
	let mono = o.now ?? (() => clock(true)[0]);

	let feed_line = (line, now) => {
		if (length(line) == 0)
			return;

		self.lines++;

		let t = parser.feed(line, now);

		if (t == null) {
			self.unparsed++;
			return;
		}

		self.sentences++;

		// the receiver's own clock, handed up for whoever is allowed to use it
		if (o.on_epoch && parser.epoch != null && parser.epoch != self._said_epoch) {
			self._said_epoch = parser.epoch;
			o.on_epoch(parser.epoch);
		}
	};

	// ONE buffer for the whole byte stream, for the reason atcmd.uc gives at
	// its own: a sentence that straddles two reads arrives as a head with no
	// newline and a tail that starts mid-word, and treating each read as a unit
	// silently drops both halves.
	let consume = (chunk, now) => {
		buffer += chunk;

		if (length(buffer) > MAX_LINE) {
			// keep the tail: whatever follows the next newline is still usable
			let nl = index(buffer, '\n');

			buffer = (nl >= 0) ? substr(buffer, nl + 1) : '';
			self.unparsed++;
		}

		let idx;

		while ((idx = index(buffer, '\n')) >= 0) {
			feed_line(trim(substr(buffer, 0, idx)), now);
			buffer = substr(buffer, idx + 1);
		}
	};

	self.start = function() {
		if (self.running)
			return true;

		let open = o.open;

		if (!open) {
			// deferred: wwand_io is a native module and the host tests do not
			// load it — they inject `o.open` instead
			let qmit = require('wwand_io');

			open = (path, baud) => qmit.open_tty(path, baud);
			self._last_error = () => qmit.last_error();
		}

		handle = open(self.path, o.baud ?? DEFAULT_BAUD);

		if (!handle) {
			self.error = self._last_error ? self._last_error() : 'open failed';

			return false;
		}

		self.error = null;
		self.running = true;
		buffer = '';

		let watch = o.watch ?? ((fd, cb) => uloop.handle(fd, cb, uloop.ULOOP_READ));

		// THE CALLBACK OWNS ITS OWN HANDLE AND ITS OWN GENERATION. stop()
		// defers deleting the uloop handle (deleting it from inside its own
		// callback frees something uloop still holds — harmless on 64-bit,
		// SIGSEGV on MIPS32, see atcmd.uc), so between a stop() and that timer
		// a start() can already have opened a NEW port. A callback that read
		// the outer `handle` would then be the OLD watcher reading the NEW
		// device, with `self.running` true again to wave it through. Raised by
		// Codex review, 2026-09-21.
		let h = handle, gen = ++generation;

		uhandle = watch(h.fileno(), () => {
			if (!self.running || gen != generation)
				return;

			while (true) {
				let chunk = h.read();

				// null = nothing more to read right now
				if (chunk === null)
					break;

				// false = EOF or a hard error: the port is GONE. ugps calls
				// exit(-1) here and lets procd respawn it against a device
				// that may not be back; the daemon owns that decision, so this
				// only says so and stops.
				if (chunk === false) {
					let why = self._last_error ? self._last_error() : 'eof';

					self.stop();
					self.error = why;

					if (o.on_gone)
						o.on_gone(why);

					return;
				}

				consume(chunk, mono());
			}
		});

		return true;
	};

	self.stop = function() {
		if (!self.running)
			return;

		self.running = false;
		generation++;   // retire this watcher: a pending callback is not ours

		// Deferred for the reason atcmd.uc gives: stop() is reachable from
		// inside this handle's own uloop callback, and deleting the handle
		// there frees something uloop is still using. Harmless on 64-bit,
		// SIGSEGV on MIPS32.
		let uh = uhandle, h = handle;

		uhandle = null;
		handle = null;

		uloop.timer(0, () => {
			if (uh) uh.delete();
			if (h) h.close();
		});
	};

	// for tests and for a caller that has bytes from somewhere else
	// same stamping as the read path: a caller that does not supply a clock
	// gets the monotonic one, not a null stamp
	self.push = (chunk, now) => consume(chunk, now ?? mono());

	self.snapshot = (now) => ({
		...parser.snapshot(now ?? mono()),
		port: self.path,
		running: self.running,
		error: self.error,
		lines: self.lines,
		sentences: self.sentences,
		unparsed: self.unparsed,
	});

	return self;
};

// The `modem_gps` reply. Built here so the shape is in one place and the
// daemon does not have to know what a fix looks like.
//
// `snap` is null when there is no reader for this modem — the modem has no
// GNSS port, `option gnss` is off, or the port could not be opened. Those are
// different answers and each says which.
function status(modem, snap) {
	let out = {
		modem: modem?.id,
		port: modem?.gps_tty ?? null,
		// wwand started the receiver itself (AT+QGPS=1 and friends); without
		// that a port can be open and silent forever
		receiver_started: modem?.gnss_started ?? null,
		configured: modem?.config?.gnss ?? false,
	};

	if (!snap)
		return { ...out, reading: false,
		         reason: (out.port == null) ? 'no_gps_port'
		                 : (!out.configured ? 'gnss_not_enabled' : 'reader_not_running') };

	return { ...out, reading: snap.running, ...snap };
};

return { create, status, DEFAULT_BAUD };
