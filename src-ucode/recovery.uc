// wwand — recovery ladder with persisted counters.
//
// Two inputs, thresholds preserved from the old proto handler:
// - connection attempts (old 'connecttries'):
//     < 8              plain retry (backoff handled by the caller)
//     == 8             DMS operating-mode low_power -> online cycle
//     == 16            DMS offline -> reset (modem reboot)
//     == 24            usb-repower (external tool, skipped if absent)
//     > failreboot     system reboot (default 100)
//   failreboot == 0 disables the whole ladder (old gate: failreboot > 0).
// - protocol request errors (old 'qmi_errors'): reset on any success,
//   ceiling 25 -> system reboot. Protocol-neutral: QMI and MBIM both feed it.
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

export function create(opts)
{
	let fx = opts.fx;
	let log = opts.log ?? ((level, msg) => warn(sprintf('%s: %s\n', level, msg)));

	let self = {
		id: opts.id,
		failreboot: +(opts.failreboot ?? 100),
		counters: { attempts: 0, proto_errors: 0 },
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

		if (att || perr) {
			self.counters.attempts = att ? +att[1] : 0;
			self.counters.proto_errors = perr ? +perr[1] : 0;
			log('notice', sprintf('restored recovery state: attempts %d, proto_errors %d',
				self.counters.attempts, self.counters.proto_errors));
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
		self.persist();

		let n = self.counters.attempts;

		log('info', sprintf('connection attempt %d failed', n));

		if (self.failreboot <= 0)
			return 'retry';

		if (n > self.failreboot)
			return 'reboot';

		if (n == 8)
			return 'opmode_cycle';

		if (n == 16)
			return 'modem_reset';

		if (n == 24)
			return 'usb_repower';

		return 'retry';
	};

	self.on_connect_success = function() {
		if (self.counters.attempts != 0) {
			self.counters.attempts = 0;
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

		if (n > PROTO_ERROR_LIMIT) {
			self.persist();
			return 'reboot';
		}

		return 'retry';
	};

	self.on_proto_success = function() {
		if (self.counters.proto_errors != 0) {
			self.counters.proto_errors = 0;
			self.persist();
		}
	};

	self.usb_repower = function() {
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
}
