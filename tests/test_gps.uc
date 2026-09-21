// wwand — the GNSS reader (wwand-gps).
//
// nmea.uc is pinned separately against recorded sentences; this is about
// everything AROUND the parser: framing a byte stream into lines, what happens
// when the port goes away, and what `modem_gps` answers when there is no fix
// to report. Those are the parts that used to be ugps's problem, and the two
// that ugps gets wrong:
//
//   - it calls exit(-1) on tty EOF (nmea.c nmea_notify_cb, 9a351d41), so a
//     modem reset kills it and procd respawns it against a device that is not
//     back yet;
//   - it has no idea which port belongs to which modem, because it takes one
//     static tty out of /etc/config/gps.

'use strict';

import { eq, ok, done } from './lib/check.uc';

let gps = require('wwand.gps');

ok(type(gps) == 'object', 'gps: module loads via require()');

// A fake port. `chunks` are handed out one read() at a time; `false` is EOF,
// which is what wwand_io.read() returns when the device is gone.
function fake_port(chunks) {
	let q = [ ...chunks ];

	return {
		closed: false,
		fileno: () => 7,
		read: () => length(q) ? shift(q) : null,
		close: function() { this.closed = true; },
	};
}

// A fake watcher that hands the callback back so a test can drive it.
function fake_watch(box) {
	return (fd, cb) => {
		box.fd = fd;
		box.cb = cb;
		box.deleted = false;

		return { delete: () => { box.deleted = true; } };
	};
}

// --- framing ----------------------------------------------------------------
//
// A sentence that straddles two reads arrives as a head with no newline and a
// tail that starts mid-word. Treating each read as a unit drops both halves,
// and on a 1 Hz receiver that is most of them.

let framed = gps.create({ path: '/dev/null' });

framed.push('$GPGGA,082112.00,5208.613543,N,00857.', 100);
eq(framed.snapshot(100).latitude, null, 'framing: half a sentence is not a position');

framed.push('854813,E,1,08,0.5,102.9,M,47.0,M,,*60\r\n', 100);

let fr = framed.snapshot(100);

ok(fr.latitude > 52.14355 && fr.latitude < 52.14356,
   'framing: ...and the other half completes it');
eq(fr.sentences, 1, 'framing: counted once, not twice');

// several sentences in one read, and a CR that must not reach the parser
framed.push('$GPGSA,A,3,03,04,06,07,09,11,19,31,,,,,0.8,0.5,0.6,1*21\r\n' +
            '$GPRMC,082112.00,A,5208.613543,N,00857.854813,E,0.021,,210926,,,A,V*0F\r\n', 101);

let fr2 = framed.snapshot(101);

eq(fr2.sentences, 3, 'framing: two more sentences out of one read');
eq(fr2.fix, '3d', 'framing: ...and they were parsed, not just counted');
eq(fr2.unparsed, 0, 'framing: a trailing CR is trimmed, not fed to the checksum');

// blank lines between sentences are ordinary on these ports
framed.push('\r\n\r\n', 102);
eq(framed.snapshot(102).unparsed, 0, 'framing: an empty line is not an unparsed sentence');

// A port that is not speaking NMEA must not grow the buffer without bound —
// a modem left in a diagnostic mode sends binary with no newline in it.
let flood = gps.create({ path: '/dev/null' });

for (let i = 0; i < 40; i++)
	flood.push('0123456789012345678901234567890123456789012345678901234567890123', 200);

ok(flood.snapshot(200).unparsed > 0, 'framing: a line with no end is dropped, not accumulated');

// ...and the reader recovers on the next newline rather than staying wedged
flood.push('\n$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60\n', 201);
ok(flood.snapshot(201).latitude != null, 'framing: ...and the next whole sentence still lands');

// --- the port going away -----------------------------------------------------

(function() {
	let box = {}, gone = [];
	let port = fake_port([ '$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60\n',
	                       false ]);

	let r = gps.create({
		path: '/dev/ttyUSB1',
		open: () => port,
		watch: fake_watch(box),
		on_gone: (why) => push(gone, why),
	});

	eq(r.start(), true, 'eof: the reader starts');
	eq(r.running, true, 'eof: ...and says so');
	eq(box.fd, 7, 'eof: watching the port\'s own fd');

	box.cb();   // drains the sentence, then hits EOF

	eq(length(gone), 1, 'eof: the caller is TOLD the port ended — ugps calls exit(-1) here');
	eq(r.running, false, 'eof: the reader stopped itself');

	// the position read before the EOF is still there: the daemon decides what
	// to do about a vanished modem, and blanking the panel is not this one's call
	ok(r.snapshot(300).latitude != null, 'eof: what was read before it stays readable');
	eq(r.snapshot(300).reading ?? r.running, false, 'eof: but it is no longer reading');
})();

// a port that will not open is a reported failure, not a throw
(function() {
	let r = gps.create({ path: '/dev/nope', open: () => null, watch: fake_watch({}) });

	eq(r.start(), false, 'open: a port that will not open returns false');
	eq(r.running, false, 'open: ...and does not pretend to run');
	ok(r.error != null, 'open: with a reason');
})();

// starting twice is not two readers on one port
(function() {
	let opens = 0, box = {};
	let r = gps.create({ path: '/dev/ttyUSB1', watch: fake_watch(box),
	                     open: () => { opens++; return fake_port([]); } });

	r.start();
	r.start();
	eq(opens, 1, 'start: starting an already-running reader opens nothing twice');
})();

// A RESTART MUST NOT LEAVE THE OLD WATCHER READING THE NEW PORT.
//
// stop() defers deleting the uloop handle, because deleting it from inside its
// own callback frees something uloop still holds (harmless on 64-bit, SIGSEGV
// on MIPS32 — atcmd.uc says the same). So between a stop() and that timer, a
// start() can already have opened a NEW port, and a callback that read the
// reader's current handle would be the OLD watcher reading the NEW device with
// `running` true again to wave it through. Raised by Codex review, 2026-09-21.
(function() {
	let box1 = {}, box2 = {}, which = 0;
	let old_port = fake_port([ '$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60\n' ]);
	let new_port = fake_port([ '$GPGGA,082112.00,4812.000000,N,01133.000000,E,1,04,0.9,520.0,M,47.0,M,,*62' + '\n' ]);

	let r = gps.create({
		path: '/dev/ttyUSB1',
		open: () => (++which == 1) ? old_port : new_port,
		watch: (fd, cb) => {
			let box = (which == 1) ? box1 : box2;
			box.cb = cb;
			return { delete: () => { box.deleted = true; } };
		},
	});

	r.start();
	r.stop();
	r.start();            // the deferred delete of watcher 1 has NOT run yet

	eq(which, 2, 'restart: the second start opened a second port');

	// watcher ONE fires now. It must do nothing at all — not read, not parse,
	// and above all not read the port that belongs to watcher two.
	box1.cb();

	eq(r.snapshot(100).sentences, 0,
		'restart: the retired watcher reads nothing — not even the new port');

	// watcher TWO is the live one
	box2.cb();
	eq(r.snapshot(100).sentences, 1, 'restart: ...and the live watcher does read');
	ok(r.snapshot(100).latitude > 48 && r.snapshot(100).latitude < 49,
		'restart: the position is the NEW port\'s, which is the point');
})();

// --- the clock ---------------------------------------------------------------
//
// The receiver's time is HANDED UP, never applied here: deps.set_clock only
// steps a clock that is plainly unset, so it cannot fight sysntpd. ugps' -a
// steps whenever it differs by five seconds, which on an NTP-synced box is a
// tug of war.

(function() {
	let epochs = [];
	let r = gps.create({ path: '/dev/null', on_epoch: (e) => push(epochs, e) });

	r.push('$GPRMC,082112.00,A,5208.613543,N,00857.854813,E,0.021,,210926,,,A,V*0F\n', 400);
	r.push('$GPRMC,082112.00,A,5208.613543,N,00857.854813,E,0.021,,210926,,,A,V*0F\n', 401);

	eq(epochs, [ 1789978872 ], 'clock: the epoch is handed up ONCE, not once per sentence');
})();

// --- the stamps must survive the clock this feature itself moves --------------
//
// `option gnss_set_time` hands the receiver's time to deps.set_clock, and a
// router with no RTC steps from 1970 to now the moment the first RMC lands.
// Every stamp the parser keeps is used for a DIFFERENCE, so on the wall clock
// that step would have reported an age of fifty-six years and expired every
// satellite in view at the same instant. Found while reviewing the clock path,
// 2026-09-21.
//
// WHAT THIS PINS, exactly: that the reader ages on the clock IT was given and
// on no other. A wall-clock jump cannot be staged here — the point is that the
// reader never reads the wall clock, which the absence of `time()` in gps.uc
// is the rest of the evidence for.
(function() {
	let t = 5000;
	let r = gps.create({ path: '/dev/null', now: () => t });

	r.push('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60\n');
	r.push('$GPGSV,1,1,02,01,10,100,40,02,20,110,41,1*66\n');

	eq(r.snapshot().age, 0, 'clock step: fresh fix, no age');
	eq(r.snapshot().satellites_in_view, 2, 'clock step: two satellites in view');

	// three seconds pass on the MONOTONIC clock — which is what the reader
	// uses, so a wall-clock jump of any size in between changes nothing here
	t += 3;

	eq(r.snapshot().age, 3, 'clock step: the age counts monotonic seconds');
	eq(r.snapshot().satellites_in_view, 2, 'clock step: ...and the satellites stay');

	// ...and the TTL still works on that clock
	t += 40;
	eq(r.snapshot().satellites_in_view, null, 'clock step: a stale GSV cycle still expires');
})();

// --- what modem_gps answers --------------------------------------------------

let m = { id: 'wwmodem0', gps_tty: '/dev/ttyUSB1', gnss_started: true, config: { gnss: true } };

// no reader: the three ways that happens are different answers
eq(gps.status(m, null).reason, 'reader_not_running',
   'status: configured, has a port, nothing reading — say which');
eq(gps.status({ ...m, gps_tty: null }, null).reason, 'no_gps_port',
   'status: no NMEA port at all is a different answer');
eq(gps.status({ ...m, config: { gnss: false } }, null).reason, 'gnss_not_enabled',
   'status: ...and so is a receiver nobody asked for');
eq(gps.status(m, null).reading, false, 'status: and none of them is "reading"');

// with a reader, the modem's own half travels with the fix
(function() {
	let r = gps.create({ path: '/dev/ttyUSB1' });

	r.push('$GPGGA,082112.00,5208.613543,N,00857.854813,E,1,08,0.5,102.9,M,47.0,M,,*60\n', 500);

	let st = gps.status(m, r.snapshot(500));

	eq(st.modem, 'wwmodem0', 'status: the answer names the modem it is about');
	eq(st.port, '/dev/ttyUSB1', 'status: and the port it came off');
	eq(st.receiver_started, true, 'status: and whether wwand started the receiver at all');
	ok(st.latitude != null, 'status: the fix travels with it');
	eq(st.satellites_used, 8, 'status: ...including what ugps reported as a string');
})();

done('test_gps');
