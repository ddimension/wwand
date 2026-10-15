// SPDX-License-Identifier: GPL-2.0-only
//
// wwand — the GNSS reader: NMEA off the modem's own port, into wwand's ubus.
//
// An exportless plain script loaded with require(), like esim.uc: require()
// cannot compile ES modules (`export` is a syntax error there), and this ships
// in its own optional package. It returns its API object at the end.
//
// WHY THIS IS OURS AND NOT ugps. Pointing ugps (OpenWrt base) at the port and
// reading its `gps` ubus object back works, and it costs more than it saves:
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
import * as locmod from 'wwand.codec.schema.loc';

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
//   o.path       the tty — or, with o.feed, only the name the reader reports
//   o.feed       true: no port at all; the lines arrive through push() (QMI
//                LOC's NMEA indications, loc_session below). start() and
//                stop() then only switch the reader on and off
//   o.baud       default 9600
//   o.open       injectable opener for tests; must return { fileno, read, close }
//   o.watch      injectable fd watcher; must return { delete }
//   o.last_error injectable errno source; taken from wwand_io only when the
//                real opener is used, since an injected `o.open` deliberately
//                keeps the native module out of the host tests
//   o.now        injectable clock (seconds); defaults to CLOCK_MONOTONIC
//   o.on_epoch   called with a unix epoch whenever the receiver reports one
//   o.on_gone    called with the errno string when a read FAILS. Not on a
//                zero-byte read: with VMIN=0 that is an idle port, and the two
//                are indistinguishable at this level (see the read loop)
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
		lines: 0, sentences: 0, unparsed: 0, ignored: 0,
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
	// instant. context_common.uc:122 does the same for the same reason.
	let mono = o.now ?? (() => clock(true)[0]);

	let feed_line = (line, now) => {
		if (length(line) == 0)
			return;

		self.lines++;

		let t = parser.feed(line, now);

		// valid NMEA this does not read (a proprietary $PQXFI/$PSTIS, a GNS
		// from a multi-constellation engine) is counted apart: `unparsed` is
		// what tells a port carrying something that is not NMEA at all
		if (t === false) {
			self.ignored++;
			return;
		}

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
	//
	// THE LIMIT IS ON THE UNFINISHED TAIL, not on the buffer: one read can
	// carry a whole second of sentences, and a multi-constellation receiver
	// sends more than MAX_LINE of them at once. Checked before the split, such
	// a read lost its first sentence every second as "unparsed" — an RG502Q
	// sending GPS + GLONASS + Galileo, 2026-10-04.
	let consume = (chunk, now) => {
		buffer += chunk;

		let idx;

		while ((idx = index(buffer, '\n')) >= 0) {
			feed_line(trim(substr(buffer, 0, idx)), now);
			buffer = substr(buffer, idx + 1);
		}

		// no newline in MAX_LINE bytes: not a sentence, whatever it is
		if (length(buffer) > MAX_LINE) {
			buffer = '';
			self.unparsed++;
		}
	};

	self.start = function() {
		if (self.running)
			return true;

		if (o.feed) {
			self.error = null;
			self.running = true;
			buffer = '';
			return true;
		}

		let open = o.open, last_error = o.last_error;

		if (!open) {
			// deferred: wwand_io is a native module and the host tests do not
			// load it — they inject `o.open` instead
			let qmit = require('wwand_io');

			open = (path, baud) => qmit.open_tty(path, baud);
			last_error = last_error ?? (() => qmit.last_error());
		}

		self._last_error = last_error;

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
		// device, with `self.running` true again to wave it through.
		let h = handle, gen = ++generation;

		uhandle = watch(h.fileno(), () => {
			if (!self.running || gen != generation)
				return;

			while (true) {
				let chunk = h.read();

				// null = nothing more to read right now
				if (chunk === null)
					break;

				// false = read() returned 0 OR failed. Those are NOT the same
				// thing on this kind of port, and treating them alike tore the
				// reader down within milliseconds of starting it:
				//
				// wwand_io.open_tty sets VMIN=0 VTIME=0 (io/src/wwand-io.c:31),
				// so a tty with nothing to say returns 0 bytes IMMEDIATELY —
				// that is the configuration, not an end of file. qmit_read maps
				// both 0 and a hard error to `false` (wwand-io.c:371), and only
				// the error path sets errno, which it clears before every read.
				// So the errno is what tells them apart: none means idle, and a
				// real one means the device is gone. atcmd never had to make
				// the distinction because it treats null and false alike.
				//
				// Found on hardware (NR7101/RG502Q, 2026-09-21): the host tests
				// could not, because their fake port only ever returned `false`
				// to mean EOF — which encoded the wrong assumption.
				//
				// A port that vanishes without an errno is still noticed: the
				// daemon owns the modem's lifecycle and releases the reader on
				// hotplug removal. ugps calls exit(-1) here instead and lets
				// procd respawn it against a device that may not be back.
				if (chunk === false) {
					let why = self._last_error ? self._last_error() : null;

					if (why == null || length(why) == 0)
						break;   // nothing to read right now

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

		if (o.feed)
			return;

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
		source: o.feed ? 'qmi_loc' : 'nmea_port',
		running: self.running,
		error: self.error,
		lines: self.lines,
		sentences: self.sentences,
		unparsed: self.unparsed,
		ignored: self.ignored,
	});

	return self;
};

// loc_session(o) -> session: NMEA over QMI LOC, for a modem without an NMEA
// port of its own.
//
//   o.modem    the modem object; only its extra_client/extra_release are used
//              — the plugin contract both backends carry (modem.uc, natively;
//              modem_mbim.uc, over the QMI-over-MBIM passthrough)
//   o.on_line  called with each NMEA sentence, CR/LF stripped
//   o.on_state called with (event, detail) for the caller to log: 'started',
//              or 'failed' with { stage, err } — this script does not log
//              (see the top of the file)
//
// THE SESSION IS ENDED BEFORE ITS CLIENT GOES, by the modem: the client's
// `before_release` sends LOC STOP ahead of the RELEASE_CID, on teardown and on
// stop() alike. RELEASE_CID only drops the client; the engine kept reporting
// every second, and an EG25-G's QMI side hung three times in one afternoon
// right after such teardowns (EG25GGBR07A08M2G, 2026-10-01).
//
// Over the MBIM passthrough, whether the modem forwards LOC indications at all
// is the firmware's choice (NAS sends none there on the EG06, qmi_over_mbim.uc
// :143-151). A session that starts and never delivers a line shows up as
// `sentences: 0` in the status, which is the honest answer.
const LOC_SESSION_ID = 1;

function loc_session(o) {
	let self = { state: 'idle', error: null, client: null, indications: 0 };
	let gen = 0;

	let fail = (g, stage, err) => {
		if (g != gen)
			return;

		self.state = 'failed';
		self.error = { stage: stage, err: err };

		let c = self.client;

		self.client = null;

		if (c && !c.destroyed)
			o.modem.extra_release(c);

		if (o.on_state)
			o.on_state('failed', self.error);
	};

	self.start = function() {
		if (self.state == 'starting' || self.alive())
			return false;

		if (type(o.modem?.extra_client) != 'function') {
			fail(++gen, 'client', { error: 'unsupported', detail: 'no QMI on this modem' });
			return false;
		}

		let g = ++gen;

		self.state = 'starting';
		self.error = null;

		o.modem.extra_client(locmod.default, (err, c) => {
			// stopped (or restarted) while the allocation was out: the client
			// is nobody's, give it back
			if (g != gen) {
				if (c)
					o.modem.extra_release(c);

				return;
			}

			if (err)
				return fail(g, 'client', err);

			self.client = c;

			c.before_release = (cl) =>
				cl.request('STOP', { session_id: LOC_SESSION_ID }, () => null, { no_recovery: true });

			c.on('NMEA_IND', (d) => {
				if (g != gen)
					return;

				self.indications++;

				for (let line in split(d?.nmea ?? '', /\r?\n/)) {
					line = trim(line);

					if (length(line))
						o.on_line(line);
				}
			});

			c.request('REGISTER_EVENTS', { mask: locmod.EVENT_NMEA }, (e2) => {
				if (e2)
					return fail(g, 'register_events', e2);

				// every sentence type, so GSV comes for each constellation the
				// engine tracks (loc.uc NMEA_TYPES_ALL). Best effort: a firmware
				// that does not know the message keeps its own default set
				c.request('SET_NMEA_TYPES', { types: locmod.NMEA_TYPES_ALL },
					() => null, { no_recovery: true });

				c.request('START', {
					session_id: LOC_SESSION_ID,
					// periodic, not the single fix an absent TLV means
					fix_recurrence: locmod.FIX_RECURRENCE_PERIODIC,
					intermediate_reports: 1,
					min_interval_ms: 1000,
				}, (e3) => {
					if (e3)
						return fail(g, 'start', e3);

					if (g != gen)
						return;

					self.state = 'running';

					if (o.on_state)
						o.on_state('started', null);
				}, { no_recovery: true });
			}, { no_recovery: true });
		});

		return true;
	};

	// the modem's teardown takes the client with it (and says goodbye through
	// before_release); a destroyed client means the next modem needs a new one
	self.alive = () => self.state == 'starting' ||
	                   (self.state == 'running' && self.client != null && !self.client.destroyed);

	self.stop = function() {
		gen++;

		let c = self.client;

		self.client = null;
		self.state = 'idle';

		if (c && !c.destroyed)
			o.modem.extra_release(c);
	};

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

return { create, loc_session, status, DEFAULT_BAUD };
