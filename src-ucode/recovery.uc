// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — recovery ladder with persisted counters.
//
// Two inputs, thresholds preserved from the old proto handler:
// - connection attempts (old 'connecttries'):
//     < 8              plain retry (backoff handled by the caller)
//     == 8             DMS operating-mode low_power -> online cycle
//     == 16            DMS offline -> reset (modem reboot)
//     == 24            board repower / reset-GPIO pulse (skipped if absent)
//     > failreboot     system reboot (default 100)
//   The hardware rungs (opmode cycle / modem reset / repower) fire on their
//   thresholds INDEPENDENT of failreboot. `failreboot == 0` disables ONLY the
//   final reboot rung: the cheaper hardware recovery still runs and the ladder
//   then keeps retrying forever, so the router stays up for logging/debugging
//   (forum request: keep a headless GPIO-reset recovery without ever rebooting).
// - protocol request errors (old 'qmi_errors'): reset on any success, ceiling
//   `proto_error_limit` (default 25) -> system reboot, but ALSO gated by
//   failreboot (<=0 never reboots). Protocol-neutral: QMI and MBIM both feed it.
//
// Counters persist to <state_dir>/<id>.json (tmpfs): they survive daemon
// restarts and are intentionally cleared by a reboot — the ladder's last
// rung. Persistence and command execution go through an injectable fx
// object (read/write/run) so everything is host-testable.

'use strict';

import * as uloop from 'uloop';

const PROTO_ERROR_LIMIT = 25;
const DEFAULT_STATE_DIR = '/tmp/wwand/state';
const REBOOT_DELAY_MS = 10000;

// escalation rungs, in ascending order of attempt count. Each fires exactly
// once per outage (tracked by the persisted `rung` index) the first time the
// attempt counter reaches its threshold — a THRESHOLD CROSSING, not an exact
// `== n` match. Exact matches were fragile: two callers can increment the
// shared counter in one failed cycle (the modem step-chain fail() and the
// daemon on a context-activation error), so a jump from 7 to 9 would sail past
// `== 8` and silently skip opmode_cycle; likewise a daemon restart mid-outage
// that restored e.g. attempts=9 would never re-hit `== 8`. Crossing + a
// persisted fired-index is robust to both.
const RUNGS = [
	{ at: 8,  action: 'opmode_cycle' },
	{ at: 16, action: 'modem_reset' },
	{ at: 24, action: 'usb_repower' },  // board repower / reset-GPIO pulse
];

// how many rungs a given attempt count has already passed (used only to default
// the fired-rung index when restoring a legacy state file that predates `rung`).
function rungs_reached(n)
{
	let k = 0;

	for (let r in RUNGS)
		if (n >= r.at)
			k++;

	return k;
}

export function create(opts)
{
	let fx = opts.fx;
	let log = opts.log ?? ((level, msg) => warn(sprintf('%s: %s\n', level, msg)));

	let self = {
		id: opts.id,
		failreboot: +(opts.failreboot ?? 100),
		proto_error_limit: +(opts.proto_error_limit ?? PROTO_ERROR_LIMIT),
		// `proto_ok` is STICKY, unlike proto_errors: it records that at least one
		// request has ever completed on this control channel with the protocol
		// currently selected. Everything physical is gated on it — see the
		// comment at the hardware rungs below. `proto_name` exists only to clear
		// it again when the selected protocol changes.
		counters: { attempts: 0, proto_errors: 0, rung: 0, proto_hw: 0,
		            proto_ok: 0, proto_name: null },
		rebooting: false,
	};

	let state_file = sprintf('%s/%s.json', opts.state_dir ?? DEFAULT_STATE_DIR, opts.id);

	self.load = function() {
		let data = fx?.read ? fx.read(state_file) : null;

		if (data == null)
			return;

		// we write this file ourselves; extract via match() because ucode's
		// json() throws uncatchably on corrupt input
		let att = match(data, /"attempts": *([0-9]+)/);
		// accept the legacy 'qmi_errors' key from state files written before the
		// counter was renamed to the protocol-neutral 'proto_errors'
		let perr = match(data, /"proto_errors": *([0-9]+)/) ?? match(data, /"qmi_errors": *([0-9]+)/);
		// `rung` (fired-rung index) may be absent in legacy state files; default
		// it from the restored attempt count so a restart mid-outage does not
		// re-run rungs that already fired (attempts>=24 -> all three done).
		let rung = match(data, /"rung": *([0-9]+)/);
		let phw = match(data, /"proto_hw": *([0-9]+)/);

		if (att || perr) {
			self.counters.attempts = att ? +att[1] : 0;
			self.counters.proto_errors = perr ? +perr[1] : 0;
			self.counters.proto_hw = phw ? +phw[1] : 0;

			let pok = match(data, /"proto_ok": *([0-9]+)/);
			let pnm = match(data, /"proto_name": *"([a-z0-9_]*)"/);

			self.counters.proto_ok = pok ? +pok[1] : 0;
			self.counters.proto_name = pnm ? pnm[1] : null;
			self.counters.rung = rung ? +rung[1] : rungs_reached(self.counters.attempts);
			log('notice', sprintf('restored recovery state: attempts %d, proto_errors %d, rung %d',
				self.counters.attempts, self.counters.proto_errors, self.counters.rung));
		}
	};

	self.persist = function() {
		if (!fx?.write)
			return;

		if (!fx.write(state_file, sprintf('%J', self.counters)))
			log('warn', sprintf('failed to persist recovery state to %s%s', state_file,
				fx.last_error ? sprintf(': %s', fx.last_error) : ''));
	};

	// record a failed connection cycle, return the ladder action:
	// 'retry' | 'opmode_cycle' | 'modem_reset' | 'usb_repower' | 'reboot'
	self.on_attempt = function() {
		self.counters.attempts++;

		let n = self.counters.attempts;

		log('info', sprintf('connection attempt %d failed', n));

		// NOTHING PHYSICAL until the modem has answered us at least once with the
		// protocol we chose. A misdetected control device fails every attempt
		// exactly like a wedged one, and the ladder used to escalate through
		// opmode cycle, modem reset and board power-cycle against hardware that
		// was never broken — reported from the field on 2026-08-30, where a
		// huawei_cdc_ncm modem classified as QMI was power-cycled for it. If we
		// have never completed one request, the errors are evidence about our own
		// detection, not about the modem.
		//
		// This guard sits ABOVE the whole ladder, reboot included, and returns
		// before any of it. It used to wrap only the rung branch, which left two
		// ways to reach the reboot unarmed — both of them the migration case this
		// gate exists for: a legacy state file whose restored attempt count puts
		// `rung` at the end of the ladder (rungs_reached), and a protocol change
		// on a modem that had already climbed all three rungs. In either the rung
		// branch is skipped for being exhausted, not for being unarmed, and
		// execution fell through to the reboot.
		if (!self.counters.proto_ok) {
			// once per threshold we would have acted on, so the operator sees it
			// at the same points the ladder would have escalated
			if ((self.counters.rung < length(RUNGS) && n == RUNGS[self.counters.rung].at) ||
			    (self.failreboot > 0 && n == self.failreboot + 1))
				log('warn', sprintf('%d failed attempts and the %s control channel has never answered — not touching the hardware; check `option protocol` and the driver',
					n, self.counters.proto_name ?? 'modem'));

			self.persist();
			return 'retry';
		}

		// Fire the next not-yet-fired hardware rung once we've reached its
		// threshold. One rung per call (escalate step by step), in order — a
		// jump past a threshold does not fire several rungs at once, and never
		// skips one. These run INDEPENDENT of failreboot: disabling the reboot
		// must not disable the cheaper hardware recovery below it.
		if (self.counters.rung < length(RUNGS) && n >= RUNGS[self.counters.rung].at) {
			let action = RUNGS[self.counters.rung].action;
			self.counters.rung++;
			self.persist();
			return action;
		}

		// Reboot is the final rung, gated by failreboot: <=0 disables ONLY the
		// reboot and the ladder retries forever (router stays up for
		// logging/debugging); >0 reboots once the count passes it.
		if (self.failreboot > 0 && n > self.failreboot) {
			self.persist();
			return 'reboot';
		}

		self.persist();
		return 'retry';
	};

	// Called whenever the daemon settles on a control protocol. A change means
	// the previous "it answered once" says nothing about the new choice, so the
	// permission to touch hardware is withdrawn until the new protocol proves
	// itself. This is what makes a corrected misdetection safe.
	self.note_protocol = function(name) {
		if (self.counters.proto_name == name)
			return;

		self.counters.proto_name = name;
		self.counters.proto_ok = 0;
		self.persist();
	};

	self.on_connect_success = function() {
		if (self.counters.attempts != 0 || self.counters.rung != 0) {
			self.counters.attempts = 0;
			self.counters.rung = 0;
			self.persist();
		}
	};

	// per-request error bookkeeping; returns 'reboot' when the ceiling hits.
	// persist only at milestones, not on every error — during a sustained
	// outage this fires per QMI request; a restart loses at most a few counts
	self.on_proto_error = function() {
		self.counters.proto_errors++;
		let n = self.counters.proto_errors;

		if (n % 5 == 0) {
			log('warn', sprintf('protocol error counter at %d', n));
			self.persist();
		}

		// A wedged control channel (repeated SYNC / request timeouts) never
		// completes a connection *attempt*, so the attempt-ladder's reset /
		// repower rungs (on_attempt) never fire — the proto-error counter is the
		// ONLY thing that climbs. Give the modem a hardware reset (reset-GPIO
		// pulse / power-cycle, via usb_repower) ONCE when the count first crosses
		// the limit, BEFORE a router reboot: a reboot does not power-cycle a
		// self-powered modem, so a wedge only a modem reset clears would otherwise
		// reboot-loop (observed on the NR7101). Independent of failreboot — the
		// cheaper hardware recovery must run even when reboots are disabled.
		// Same gate as the attempt ladder, and this is the path the field report
		// actually took: a control channel that never answered produces nothing
		// BUT protocol errors, so this counter is the only one that climbs.
		if (n > self.proto_error_limit && !self.counters.proto_ok) {
			if (n == self.proto_error_limit + 1)
				log('warn', sprintf('%d protocol errors and the %s control channel has never answered — refusing the hardware reset; this looks like the wrong protocol, not broken hardware',
					n, self.counters.proto_name ?? 'modem'));

			return 'retry';
		}

		if (n > self.proto_error_limit && !self.counters.proto_hw) {
			self.counters.proto_hw = 1;
			self.persist();
			return 'usb_repower';
		}

		// Reboot only after the hardware reset has been tried and errors persist a
		// further full window. Same gate as the attempt ladder: never reboot when
		// failreboot<=0 — a headless install keeps retrying instead of cycling.
		if (n > self.proto_error_limit * 2 && self.counters.proto_ok) {
			self.persist();
			return (self.failreboot > 0) ? 'reboot' : 'retry';
		}

		return 'retry';
	};

	// "the modem answered us in the protocol we chose" — the ONLY thing the
	// hardware gate needs, and deliberately weaker than a successful request.
	// A modem that decodes our request and replies with a service error has
	// answered; so has one that returns a command-done with a failure status.
	// Arming on success alone would leave a modem that talks to us perfectly
	// well but refuses everything we ask (locked SIM, unsupported message set)
	// permanently unable to reach the recovery it may genuinely need. Sticky,
	// and it must NOT touch the error counters — those measure something else,
	// and resetting them here would defeat the proto-error ladder entirely.
	self.note_answer = function() {
		if (self.counters.proto_ok)
			return;

		self.counters.proto_ok = 1;
		log('info', sprintf('%s control channel answered — hardware recovery armed',
			self.counters.proto_name ?? 'modem'));
		self.persist();
	};

	self.on_proto_success = function() {
		let first = !self.counters.proto_ok;

		if (first)
			log('info', sprintf('%s control channel answered — hardware recovery armed',
				self.counters.proto_name ?? 'modem'));

		if (first || self.counters.proto_errors != 0 || self.counters.proto_hw != 0) {
			self.counters.proto_errors = 0;
			self.counters.proto_hw = 0;
			self.counters.proto_ok = 1;
			self.persist();
		}
	};

	// hardware repower rung. Preferred: a board-provided callback (opts.repower)
	// that power-cycles the modem's USB power GPIO — or, if the modem has a
	// `reset_gpio`, pulses that instead (decided by the caller). It fully
	// replaces the old external `usb-repower` tool; the fx.run fallback stays
	// only for hosts that still ship such a tool and have no board profile.
	self.usb_repower = function() {
		if (opts.repower) {
			log('err', 'recovery: triggering modem repower (board)');
			return opts.repower() ? true : false;
		}

		log('err', 'recovery: triggering usb-repower');

		let rc = fx?.run ? fx.run([ 'usb-repower' ]) : -1;

		if (rc != 0)
			log('warn', sprintf('usb-repower unavailable or failed (rc %d)', rc));

		return rc == 0;
	};

	self.reboot = function(reason) {
		if (self.rebooting)
			return;

		self.rebooting = true;
		log('err', sprintf('recovery: rebooting system (%s) in %ds',
			reason, (opts.reboot_delay ?? REBOOT_DELAY_MS) / 1000));

		// deferred so logs get flushed and ubus consumers see the state
		uloop.timer(opts.reboot_delay ?? REBOOT_DELAY_MS, () => {
			if (fx?.run)
				fx.run([ 'reboot' ]);
		});
	};

	return self;
};
