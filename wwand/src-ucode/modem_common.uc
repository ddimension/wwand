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
export function open_at(self, o)
{
	let log = o.log;

	if (self.at)
		return (o.reopen_next ?? o.next)();

	let fxi = o.at_opts?.fx ?? netlink.default_fx((level, msg) => log(level, msg));
	let tty = atcmd.find_tty(fxi, self.device, self.config.tty);

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
