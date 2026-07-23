// wwand — helpers shared by the QMI (modem.uc) and MBIM (modem_mbim.uc) modem
// state machines, so both backends (and future ones) reuse the same plumbing
// instead of duplicating it. Everything here is protocol-neutral: it operates
// on the modem `self` object through the small contract both backends share
// (self.device, self.config, self.info, self.at, self.at_tty).

'use strict';

import * as uloop from 'uloop';
import * as atcmd from './atcmd.uc';
import * as netlink from './netlink.uc';

// open_at(self, o): best-effort AT side-channel bring-up. Discovers the AT tty,
// opens it, runs model-init + configured at_init + cell-lock commands, wires the
// M9200B serial-drain quirk, then calls o.next(). Leaves self.at/self.at_tty set
// (or unset when there is no usable AT port — always non-fatal). This is the
// single copy of what both modems' step_at used to implement independently; the
// MBIM copy previously skipped model-init + the drain quirk, so folding them here
// also brings MBIM to parity.
//
// o = {
//   at_opts?:        { fx?, open_transport? }  (test injection; else real deps)
//   log:             (level, msg) => …
//   drain_interval?: ms for the M9200B drain tick (default 60000)
//   set_drain_timer: (timer) => …  stores the drain timer where the modem's
//                                  teardown already cancels it
//   next:            () => …  continue the init chain
//   reopen_next?:    () => …  continuation when self.at is already open
//                             (defaults to next)
// }
// dsd_from_serving(serving): derive the data-system mode from an AT QENG
// serving-cell detail (Quectel states NSA/SA directly). Returns { mode, lte, nr }
// or null. Shared by the QMI and MBIM data-mode resolvers.
export function dsd_from_serving(serving)
{
	let lte = serving?.lte != null;
	let nr  = serving?.nr != null;
	let mode = nr ? (serving.nr.mode ?? (lte ? 'NSA' : 'SA')) : (lte ? 'LTE' : null);

	return mode ? { mode: mode, lte: lte, nr: nr } : null;
}

// dsd_from_radio(radio_ifs): derive a coarse mode from NAS radio interfaces
// (last-resort fallback; can't see NSA — an NSA anchor reports LTE only here).
// radio_ifs: 8=LTE, 12=5GNR. Returns { mode, lte, nr } or null.
export function dsd_from_radio(radio_ifs)
{
	let lte = false, nr = false;

	for (let r in (radio_ifs ?? []))
		if (r == 8) lte = true;
		else if (r == 12) nr = true;

	let mode = nr ? (lte ? 'NSA' : 'SA') : (lte ? 'LTE' : null);

	return mode ? { mode: mode, lte: lte, nr: nr } : null;
}

// watch_driver(o): the adaptive "fast telemetry" cadence shared by the QMI and
// MBIM modem state machines. While a consumer polls (modem_signal/modem_cells
// over ubus), it runs o.refresh at most once per min_interval, NON-OVERLAPPING
// (the next cycle is scheduled only after the previous refresh finishes, so the
// cadence stretches under modem load), and decays back to idle `decay` ms after
// the last poll. This was copied verbatim into both modems ("Mirrors modem.uc")
// differing only in the liveness predicate and the refresh body.
//
//   o.alive   () => bool   — control channel up (self.nas != null / self.mbim)
//   o.ready   () => bool   — self.state == 'READY'
//   o.refresh (done) => …  — run one refresh cycle; call done() EXACTLY ONCE
//                            when it finishes or bails (e.g. the channel
//                            vanished mid-cycle). done() reschedules the next
//                            cycle iff still watched and alive, else goes idle —
//                            so a bail with !alive() stops the loop, exactly as
//                            the old inline `fast_running = false` did.
//   o.min_interval?  ms (default 1000) — never poll faster than this
//   o.decay?         ms (default 6000) — idle-out delay after the last watch()
//
// Returns { watch(), stop() }: watch() is what the daemon calls on each
// modem_signal/modem_cells poll; stop() is called from teardown.
export function watch_driver(o)
{
	let min_interval = o.min_interval ?? 1000;
	let decay = o.decay ?? 6000;

	let decay_timer = null, fast_timer = null;
	let active = false, running = false;

	// mutually-referencing arrows -> forward-declare (ucode TDZ trap)
	let tick, finish;

	// the reschedule/finish handler handed to o.refresh.
	finish = () => {
		if (active && o.alive())
			fast_timer = uloop.timer(min_interval, tick);
		else
			running = false;
	};

	tick = () => {
		fast_timer = null;

		if (!active || !o.ready() || !o.alive()) {
			running = false;
			return;
		}

		running = true;
		o.refresh(finish);
	};

	return {
		watch: function() {
			active = true;

			if (decay_timer)
				decay_timer.cancel();

			decay_timer = uloop.timer(decay, () => {
				active = false;
				decay_timer = null;
			});

			// kick an immediate refresh so the first poll already returns fresh data
			if (!running && o.ready() && o.alive())
				tick();
		},

		stop: function() {
			if (decay_timer) { decay_timer.cancel(); decay_timer = null; }
			if (fast_timer)  { fast_timer.cancel();  fast_timer = null; }
			active = running = false;
		},
	};
}

// telemetry_at(self): the AT engine a telemetry poll should run over. On first
// use it opens the modem's dedicated 'at2' channel (if it has one); every later
// call returns the already-open engine. When there is no second port — or it
// fails to open — it returns the control channel (self.at), so callers can treat
// the result exactly like self.at (null only when the modem has no AT at all).
// This makes the second tty lazy: QMI/MBIM that never hit the AT fallback never
// open it, while NCM opens it on its first telemetry tick.
export function telemetry_at(self)
{
	if (self._at2_open) {
		let open = self._at2_open;
		self._at2_open = null;      // one-shot: never retry a failed open per poll
		open();                     // sets self.at_telemetry on success
	}

	return self.at_telemetry;
}

// close_at(self): tear down both AT engines opened by open_at (the control
// channel and, when distinct, the dedicated telemetry channel). Idempotent.
export function close_at(self)
{
	if (self.at_telemetry && self.at_telemetry != self.at)
		self.at_telemetry.close();

	if (self.at)
		self.at.close();

	self.at = null;
	self.at_telemetry = null;
	self.at_tty = null;
	self.at_telemetry_tty = null;
	self._at2_open = null;
}

export function open_at(self, o)
{
	let log = o.log;

	if (self.at)
		return (o.reopen_next ?? o.next)();

	let fxi = o.at_opts?.fx ?? netlink.default_fx((level, msg) => log(level, msg));
	let ch = atcmd.find_at_channels(fxi, self.device, self.config.tty, o.base_override);
	let tty = ch.primary;

	if (!tty) {
		log('info', 'no AT port found');
		return o.next();
	}

	let open_transport = o.at_opts?.open_transport ?? atcmd.open_transport;
	let tr = open_transport(tty, 115200, (level, msg) => log(level, msg));

	if (!tr) {
		log('warn', sprintf('cannot open AT port %s', tty));
		return o.next();
	}

	self.at = atcmd.create(tr, { log: (level, msg) => log(level, sprintf('at: %s', msg)) });
	self.at_tty = tty;
	log('notice', sprintf('AT port: %s', tty));

	// dedicated telemetry channel: when the modem exposes a second AT port
	// ('at2'), telemetry polls (QENG/QCAINFO/…) run over a separate engine so
	// they don't serialize behind control/dial/user commands on the primary.
	// Opened LAZILY on the first telemetry poll (see telemetry_at) rather than
	// eagerly here: QMI/MBIM only ever touch AT as a rare fallback (e.g. QCAINFO
	// when QMI CA is unavailable), so eagerly opening a second tty on every such
	// modem wasted an fd; NCM polls telemetry over AT from the first tick, so
	// there it opens on that first poll. Until (or unless) it opens, telemetry
	// falls back to the control channel.
	self.at_telemetry = self.at;
	self.at_telemetry_tty = tty;

	// stash a one-shot opener; telemetry_at() runs it on first use. Null when the
	// modem has no distinct second AT port (telemetry then stays on control).
	self._at2_open = (ch.telemetry && ch.telemetry != tty)
		? () => {
			let tr2 = open_transport(ch.telemetry, 115200, (level, msg) => log(level, msg));

			if (!tr2) {
				log('warn', sprintf('cannot open AT telemetry channel %s (using control channel)', ch.telemetry));
				return;
			}

			self.at_telemetry = atcmd.create(tr2, { log: (level, msg) => log(level, sprintf('at2: %s', msg)) });
			self.at_telemetry_tty = ch.telemetry;
			log('notice', sprintf('AT telemetry channel: %s', ch.telemetry));
		}
		: null;

	// model quirks + configured at_init list, then cell locks
	let cmds = [
		...atcmd.model_init_commands(self.info?.model),
		...(self.config.at_init ?? []),
		...atcmd.cell_lock_commands(self.config),
	];

	// M9200B: periodically drain stale serial output (old empty_serial_buffers
	// quirk that used to run from the QMI watchdog loop)
	if (index(self.info?.revision ?? '', 'M9200B') >= 0) {
		let interval = o.drain_interval ?? 60000;
		let tick;

		tick = () => {
			self.at.drain();
			o.set_drain_timer(uloop.timer(interval, tick));
		};

		o.set_drain_timer(uloop.timer(interval, tick));
		log('notice', 'M9200B detected, enabling serial drain');
	}

	if (!length(cmds))
		return o.next();

	self.at.run_sequence(cmds, o.next);
}
