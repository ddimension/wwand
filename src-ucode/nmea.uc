// SPDX-License-Identifier: GPL-2.0-only
//
// wwand — NMEA 0183 parsing.
//
// PURE. No I/O, no logging, no clock: every entry point takes what it needs and
// returns what it found, so the whole file is testable from the host against
// recorded sentences. The reader that feeds it lives in gps.uc.
//
// Written because ugps (OpenWrt base, 9a351d41, 2025-10-03) parses less than a
// modem offers, and the parts it drops are the ones that answer "why is there
// no fix":
//
//   - it takes `$GP` and `$GN` only (nmea.c nmea_process), so a Galileo,
//     GLONASS or BeiDou talker is discarded;
//   - it has no GSV, so there is no such thing as a satellite in VIEW — its
//     "satellites" is GGA field 7, the count in USE;
//   - it has no GSA, so no fix type (2D/3D) and no PDOP/VDOP;
//   - it reports every field as a STRING, absent ones as the empty string.
//
// This accepts any talker, keeps numbers as numbers and absent as null, and
// aggregates the satellites in view per constellation.

'use strict';

// How long a completed GSV cycle stays evidence. A receiver repeats its set
// every second or two, so thirty seconds is a dozen missed rounds — long
// enough that a busy port does not blink the count, short enough that a band
// which stopped reporting leaves.
const GSV_TTL = 30;

// the same, for the per-constellation GSA modes
const GSA_TTL = 30;

// A field that is present but empty is ABSENT, not zero — `+""` is 0 in ucode
// and an unset HDOP would read as a perfect one. NaN is caught the same way:
// `+"abc"` is NaN, and NaN != NaN.
function num(s) {
	if (s == null || length(s) == 0)
		return null;

	let v = +s;

	return (v != v) ? null : v;
};

// Round to a stated number of decimals, half away from zero. `f` MUST be a
// double or ucode does integer division and returns the whole part.
//
// This is about NOT CLAIMING PRECISION THAT IS NOT THERE, and nothing else. It
// does not tidy the JSON: libubox prints every double with %.17g
// (blobmsg_json.c:275, libubox 2026.07.08~7677b7a4), so 0.8 comes out as
// 0.80000000000000004 whatever we do — 0.8 has no exact binary form and
// rounding returns the same double. Consumers that parse the JSON (LuCI, jq,
// python) read it back as 0.8 and print 0.8; only a human reading raw `ubus
// call` output sees the tail.
function round_to(v, f) {
	return (v == null) ? null : int(v * f + ((v < 0) ? -0.5 : 0.5)) / f;
};

// ddmm.mmmm (or dddmm.mmmm) plus a hemisphere -> signed degrees. The degrees
// are the whole hundreds, the rest is minutes; that is the format, not a
// rounding choice.
function coord(v, hem) {
	let raw = num(v);

	// The checksum proves the line ARRIVED intact. It says nothing about the
	// line meaning anything, and a receiver in a strange state emits
	// well-formed nonsense — so the hemisphere must be one of the four, the
	// minutes must be minutes, and the result must be on the planet.
	if (raw == null || (hem != 'N' && hem != 'S' && hem != 'E' && hem != 'W'))
		return null;

	let deg = int(raw / 100), min = raw - int(raw / 100) * 100;

	if (min < 0 || min >= 60)
		return null;

	let out = deg + min / 60.0;
	let lat = (hem == 'N' || hem == 'S');

	// RANGE FIRST, THEN ROUND — the right order, though at eight decimals it
	// is belt and braces rather than load-bearing, and saying so is the point.
	// Rounding first can pull a coordinate just outside the world back in:
	// 9000.000001 is 90.0000000167 degrees, which at SEVEN decimals rounds to
	// exactly 90 and passes a check it should have failed. At eight it rounds
	// to 90.00000002 and is still refused, and the wire cannot express a
	// smaller excess — six decimal minutes are 1.67e-8 degrees. So no sentence
	// this parser can receive reaches the hazard, which is why the test below
	// pins the refusal and not the ordering. Raised by Codex review,
	// 2026-09-21.
	if (out < 0 || out > (lat ? 90 : 180))
		return null;

	// EIGHT decimals, which is about 1.1 mm — just finer than the wire. These
	// receivers send six decimal MINUTES, and a minute is 1/60 of a degree, so
	// the last digit on the wire is 1.67e-8 degrees, roughly 1.9 mm. Seven
	// decimals would have thrown some of that away; the division's own
	// fourteen would be a claim about nanometres. (It does not tidy the JSON
	// either way — see round_to.)
	out = round_to(out, 100000000.0);

	return (hem == 'S' || hem == 'W') ? -out : out;
};

// hhmmss(.sss) -> { hour, min, sec }, or null
function hms(s) {
	if (s == null || length(s) < 6)
		return null;

	let h = num(substr(s, 0, 2)), m = num(substr(s, 2, 2)), sec = num(substr(s, 4, 2));

	if (h == null || m == null || sec == null)
		return null;

	// timegm NORMALISES out-of-range fields rather than refusing them, so an
	// hour of 47 would silently become the next day. Refuse it here instead.
	// (60 is allowed for a leap second.)
	if (h > 23 || m > 59 || sec > 60 || h < 0 || m < 0 || sec < 0)
		return null;

	return { hour: h, min: m, sec: sec };
};

// A calendar day that timegm would otherwise roll over into the next month.
// Checking `d <= 31` is not enough: 31 April and 29 February in a common year
// both pass it and both become the first of the following month, silently and
// with a plausible-looking epoch. Raised by Codex review, 2026-09-21.
const MONTH_DAYS = [ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 ];

function ymd_ok(y, mo, d) {
	if (y == null || mo == null || d == null || mo < 1 || mo > 12 || d < 1)
		return false;

	let max = MONTH_DAYS[mo - 1];

	// Gregorian: every fourth year, except centuries, except every fourth of those
	if (mo == 2 && (y % 4) == 0 && ((y % 100) != 0 || (y % 400) == 0))
		max = 29;

	return d <= max;
};

// One sentence -> { talker, type, f: [fields] }, or null when it is not NMEA
// or the checksum does not match. The checksum is the XOR of everything
// between '$' and '*'; a sentence without one is refused rather than trusted,
// because a truncated line is exactly what a half-read buffer produces.
export function parse_sentence(line) {
	let s = trim(line ?? '');

	if (length(s) < 9 || substr(s, 0, 1) != '$')
		return null;

	let star = index(s, '*');

	if (star < 1 || length(s) < star + 3)
		return null;

	let body = substr(s, 1, star - 1);
	let want = hex(substr(s, star + 1, 2));
	let have = 0;

	for (let i = 0; i < length(body); i++)
		have ^= ord(body, i);

	if (want == null || have != want)
		return null;

	let head = split(body, ',')[0];

	// proprietary sentences ($PQXFI, $PSTMVER, ...) carry no talker
	if (length(head) != 5)
		return null;

	let f = split(body, ',');

	shift(f);

	return { talker: substr(head, 0, 2), type: substr(head, 2, 3), f };
};

// The accumulator. One per receiver; the caller owns it and injects `now`
// (seconds, monotonic or wall — only differences are used) so that ageing is
// asserted in tests rather than raced against a clock.
export function create() {
	let self = {
		// position
		latitude: null, longitude: null, elevation: null, geoid_separation: null,
		// movement
		speed_kmh: null, speed_knots: null, course: null,
		// quality
		valid: false, quality: null,
		hdop: null, pdop: null, vdop: null,
		satellites_used: null,
		// time the receiver itself reports
		epoch: null,
		// when we last took a POSITION off the wire
		position_ts: null,
		// satellites in view, per talker; _gsv holds the cycle being assembled
		sats: {},
		_gsv: {},
		_gsa: {},
	};

	// RMC and GLL both carry a validity flag; GGA carries a fix quality. Losing
	// validity must clear the fix but NOT the last position: a receiver that
	// drops to 'V' for a few seconds has not moved, and blanking the panel on
	// every blink is worse than showing an age.
	// Losing the fix clears the numbers that DESCRIBED it, and keeps the
	// position. Those are different things: a receiver that blinks has not
	// moved, so the last position plus an age is still the best answer there
	// is — but "eight satellites, HDOP 0.5" alongside "no fix" describes a
	// state that never existed, and it was reachable because each sentence
	// only ever updated its own fields. Raised by Codex review, 2026-09-21.
	let lose_fix = () => {
		self.valid = false;
		self.satellites_used = null;
		self.hdop = self.pdop = self.vdop = null;
		self._gsa = {};
		self.elevation = self.geoid_separation = null;
		self.speed_kmh = self.speed_knots = self.course = null;
	};

	let set_valid = (v) => {
		if (!v)
			return lose_fix();

		self.valid = true;
	};

	let handlers = {
		RMC: (f, now) => {
			set_valid(f[1] == 'A');

			if (!self.valid)
				return;

			let lat = coord(f[2], f[3]), lon = coord(f[4], f[5]);

			if (lat != null && lon != null) {
				self.latitude = lat;
				self.longitude = lon;
				self.position_ts = now;
			}

			self.speed_knots = num(f[6]);

			if (self.speed_knots != null)
				self.speed_kmh = round_to(self.speed_knots * 1.852, 10.0);

			let c = num(f[7]);

			if (c != null)
				self.course = c;

			// date is ddmmyy; the century is not on the wire. NMEA 0183 has no
			// answer for it, so 2000..2099 is the assumption, same as ugps
			// (nmea.c: tm_year += 100).
			let t = hms(f[0]), d = f[8];

			if (t != null && d != null && length(d) == 6) {
				let dd = num(substr(d, 0, 2)), mm = num(substr(d, 2, 2)), yy = num(substr(d, 4, 2));

				if (ymd_ok(yy, mm, dd))
					self.epoch = timegm({ year: 2000 + yy, mon: mm, mday: dd,
					                      hour: t.hour, min: t.min, sec: t.sec });
			}
		},

		GLL: (f, now) => {
			set_valid(f[5] == 'A');

			if (!self.valid)
				return;

			let lat = coord(f[0], f[1]), lon = coord(f[2], f[3]);

			if (lat != null && lon != null) {
				self.latitude = lat;
				self.longitude = lon;
				self.position_ts = now;
			}
		},

		GGA: (f, now) => {
			self.quality = num(f[5]);

			// quality 0 is "no fix" — the coordinates in that sentence are not
			// a position, they are the last one the receiver still remembers,
			// and neither are the counts beside them
			if (self.quality == null || self.quality == 0)
				return lose_fix();

			let lat = coord(f[1], f[2]), lon = coord(f[3], f[4]);

			if (lat != null && lon != null) {
				self.latitude = lat;
				self.longitude = lon;
				self.position_ts = now;
			}

			// quality 1 or better IS the receiver reporting a solution, and it
			// has to say so or a GSA-derived fix would sit beside valid:false
			self.valid = true;
			self.satellites_used = num(f[6]);
			self.hdop = num(f[7]);
			self.elevation = num(f[8]);
			self.geoid_separation = num(f[10]);
		},

		// ONE GSA PER CONSTELLATION IS NORMAL. A multi-GNSS receiver sends
		// $GPGSA, $GLGSA, $GAGSA…, and one of them saying mode 1 means THAT
		// constellation is not contributing — not that there is no fix. Taken
		// globally it tore down a perfectly good combined solution, and which
		// way it went depended on the order the sentences happened to arrive.
		// So each talker's mode is kept on its own and the reported fix is the
		// best of them; whether there is a fix AT ALL stays RMC/GLL/GGA's word,
		// which is where the receiver says it. Raised by Codex review,
		// 2026-09-21.
		GSA: (f, now, talker) => {
			self._gsa[talker] = { mode: num(f[1]), at: now,
			                      pdop: num(f[14]), hdop: num(f[15]), vdop: num(f[16]) };
		},

		VTG: (f) => {
			// NMEA 2.3 added an FAA mode as the last field; 'N' is "not valid"
			// and the numbers beside it are meaningless. Ignoring it let an
			// invalid VTG repopulate speed and course right after a lost fix
			// had cleared them. Raised by Codex review, 2026-09-21.
			if (f[8] == 'N')
				return;

			let c = num(f[0]);

			if (c != null)
				self.course = c;

			let kn = num(f[4]), kmh = num(f[6]);

			if (kn != null)
				self.speed_knots = kn;

			if (kmh != null)
				self.speed_kmh = kmh;
			else if (kn != null)
				self.speed_kmh = round_to(kn * 1.852, 10.0);
		},

		ZDA: (f) => {
			let t = hms(f[0]);
			let dd = num(f[1]), mm = num(f[2]), yy = num(f[3]);

			if (t != null && yy > 1980 && ymd_ok(yy, mm, dd))
				self.epoch = timegm({ year: yy, mon: mm, mday: dd,
				                      hour: t.hour, min: t.min, sec: t.sec });
		},

		// GSV comes in cycles: message 1..N, four satellites each, and the list
		// is only swapped in when the LAST message of a cycle lands, so a
		// half-received cycle never replaces a complete one.
		//
		// THE TALKER IS NOT THE KEY. NMEA 4.10 added a signal id as the last
		// field, and a receiver sends one cycle PER SIGNAL under the SAME
		// talker — the RG502Q in a NR7101 alternates `$GPGSV,3,n,11,...,1`
		// (L1, eleven satellites) with `$GPGSV,2,n,07,...,8` (a second band,
		// seven of the same ones), recorded 2026-09-21. Keyed by talker alone
		// the two cycles overwrite each other and the count reported was the
		// smaller one — which showed up as eight satellites USED and seven in
		// VIEW, an impossibility, and is how this was found.
		GSV: (f, now, talker) => {
			let total = num(f[0]), msg = num(f[1]);

			if (total == null || msg == null)
				return;

			// four fields per satellite after the three header fields; one
			// field left over is the 4.10 signal id, nothing left over means a
			// pre-4.10 sentence
			let rest = length(f) - 3;
			let sig = ((rest % 4) == 1) ? f[length(f) - 1] : '';
			let key = talker + ':' + sig;

			if (msg == 1)
				self._gsv[key] = [];

			let acc = self._gsv[key];

			if (acc == null)
				return;   // joined mid-cycle: wait for the next message 1

			let last = 3 + int(rest / 4) * 4;

			for (let i = 3; i + 3 < last + 1 && i + 3 < length(f); i += 4) {
				let prn = num(f[i]);

				if (prn == null)
					continue;

				push(acc, { talker, signal: (length(sig) ? sig : null), prn,
				            elevation: num(f[i + 1]), azimuth: num(f[i + 2]),
				            snr: num(f[i + 3]) });
			}

			if (msg >= total) {
				// STAMPED. A constellation or a signal band that stops being
				// reported — the receiver reconfigured, the band lost — would
				// otherwise stay in the count and in the SNR list for the life
				// of the daemon, while the comment beside the count claims it
				// is what is in the sky. Raised by Codex review, 2026-09-21.
				self.sats[key] = { at: now, list: acc };
				self._gsv[key] = null;
			}
		},
	};

	// One line in. Returns the sentence type it acted on, or null.
	self.feed = function(line, now) {
		let s = parse_sentence(line);

		if (!s)
			return null;

		let h = handlers[s.type];

		if (!h)
			return null;

		h(s.f, now, s.talker);

		return s.type;
	};

	// What a consumer sees. `age` is seconds since the last POSITION, not since
	// the last sentence: a receiver that keeps talking while it has lost the
	// sky would otherwise look current.
	// The fix, decided where everything needed to decide it is in scope.
	//
	// It is NOT kept as a field updated by whichever GSA arrived last. Two
	// things go wrong that way and both did: a GSA that stops arriving leaves
	// its verdict standing for ever, GSA_TTL or no GSA_TTL; and a GSA mode 3
	// landing AFTER the receiver has said the solution is gone reasserts a 3D
	// fix beside valid:false, which is the opposite of the rule this file
	// states. Raised by Codex review, 2026-09-21.
	let verdict = (now) => {
		let best = null;

		for (let k, v in self._gsa) {
			if (v == null || (now != null && v.at != null && (now - v.at) > GSA_TTL))
				continue;

			if (best == null || (v.mode ?? 0) > (best.mode ?? 0))
				best = v;
		}

		// whether there is a solution at all is RMC/GLL/GGA's word; GSA only
		// ever says how good it is
		if (!self.valid || best == null)
			return { fix: (best == null && self.valid) ? null : 'none', dop: null };

		// 1 = no fix, 2 = 2D, 3 = 3D (NMEA 0183). Reported as the words,
		// because '2' meaning 2D and quality '2' meaning DGPS in GGA are
		// different scales and were confusable as bare numbers.
		return { fix: (best.mode == 3) ? '3d' : ((best.mode == 2) ? '2d' : 'none'),
		         dop: (best.mode >= 2) ? best : null };
	};

	self.snapshot = function(now) {
		// COUNTED, not summed. The same satellite appears once per signal it is
		// heard on, so adding the per-cycle counts would report eleven GPS
		// satellites as eighteen. Distinct talker+prn is the number of
		// satellites in the sky, which is the number anyone means.
		let sats = [], distinct = {}, seen = false;

		for (let k, v in self.sats) {
			if (v == null)
				continue;

			// a cycle older than GSV_TTL is not evidence about now. A receiver
			// repeats its GSV set every second or two; several of those having
			// gone by without one means that band stopped reporting.
			if (now != null && v.at != null && (now - v.at) > GSV_TTL)
				continue;

			seen = true;

			for (let sat in (v.list ?? [])) {
				push(sats, sat);
				distinct[sat.talker + '/' + sat.prn] = true;
			}
		}

		let in_view = length(keys(distinct));
		let v = verdict(now);

		return {
			valid: self.valid,
			fix: v.fix,
			quality: self.quality,
			latitude: self.latitude,
			longitude: self.longitude,
			elevation: self.elevation,
			geoid_separation: self.geoid_separation,
			speed_kmh: self.speed_kmh,
			speed_knots: self.speed_knots,
			course: self.course,
			satellites_used: self.satellites_used,
			satellites_in_view: seen ? in_view : null,
			satellites: sats,
			// the DOPs of the solution that IS the fix, falling back to GGA's
			// HDOP — the only one GGA carries — when the winning GSA omits it
			hdop: v.dop?.hdop ?? (v.dop ? self.hdop : (self.valid ? self.hdop : null)),
			pdop: v.dop?.pdop ?? null,
			vdop: v.dop?.vdop ?? null,
			epoch: self.epoch,
			age: (self.position_ts != null && now != null) ? (now - self.position_ts) : null,
		};
	};

	return self;
};
