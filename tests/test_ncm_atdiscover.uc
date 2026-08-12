// wwand tests — NCM AT-port discovery anchored on the datapath netdev.
//
// Regression coverage for the Cudy LT300/SLM770A cold-boot race: discovery
// builds NCM modems with device = null (there is no control node) and pins
// cfg.tty at resolve time. On a cold boot the serial interfaces bind only
// AFTER the first resolve (runtime new_id write, late kmodloader), so cfg.tty
// stays null — and the old open_at anchored tty discovery on self.device,
// which is null, so EVERY retry failed with no_at_port even once ttyUSB0-3
// existed (7 attempts in a row on the LT300). The fix anchors the serial bind
// and the tty discovery on the datapath netdev's USB parent.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as fakefx from './lib/fakefx.uc';
import * as modem_ncm from 'wwand/modem_ncm.uc';

uloop.init();

const GLOB = '/sys/class/net/usb0/device/../*/tty*';

// MeiG SLM770A ECM composition on the netdev's USB parent — NO ttys yet
let fx = fakefx.create({
	files: {
		'/sys/class/net/usb0/device/../idVendor': '2dee\n',
		'/sys/class/net/usb0/device/../idProduct': '4d58\n',
		'/sys/class/net/usb0/device/../1-1:1.3/bInterfaceNumber': '03\n',
		'/sys/class/net/usb0/device/../1-1:1.4/bInterfaceNumber': '04\n',
	},
	present: { '/sys/bus/usb-serial/drivers/option1/new_id': true },
	globs: {},
});

// scripted AT transport: everything answers OK (we only care about discovery)
let opened = [];

function open_transport(tty, baud, log) {
	push(opened, tty);

	let self = { data_cb: null, closed: false };

	self.write = (data) => {
		uloop.timer(0, () => {
			if (!self.closed && self.data_cb)
				self.data_cb("OK\r\n");
		});
		return length(data);
	};
	self.on_data = (cb) => { self.data_cb = cb; };
	self.drain = () => null;
	self.close = () => { self.closed = true; };

	return self;
}

let events = [], finished = false, guard = null, poll = null, modem = null;
let seen_tty = null;   // captured before stop() (teardown clears self.at_tty)

function finish() {
	if (finished)
		return;
	finished = true;
	seen_tty = modem.at_tty;
	if (guard) guard.cancel();
	if (poll) poll.cancel();
	modem.stop();
	uloop.timer(1, () => uloop.end());
}

modem = modem_ncm.create({
	id: 'm_lt300', device: null,                       // discovery: NCM has no control node
	datapath: { netdev: 'usb0', fx: fx },
	config: {},                                        // cfg.tty NOT pinned (boot race)
	timing: { settle: 1, reg_timeout: 500, reg_poll: 5, backoff_min: 1, backoff_max: 5, at_drain: 1 },
	at: { fx: fx, open_transport: open_transport },
	deps: {
		log: () => null,
		on_event: (m, event, data) => {
			push(events, { event: event, data: data });

			// attempt 1 failed (no ttys yet) -> the serial interfaces bind now
			// (as the runtime new_id probe does on real HW)
			if (event == 'error' && fx.globs[GLOB] == null)
				fx.globs[GLOB] = [
					'/sys/class/net/usb0/device/../1-1:1.3/ttyUSB1',
					'/sys/class/net/usb0/device/../1-1:1.4/ttyUSB2',
				];
		},
	},
});

guard = uloop.timer(3000, () => { ok(false, 'timed out before the retry found the AT port'); finish(); });

poll = uloop.interval(5, () => {
	if (modem.at_tty != null)
		finish();
});

modem.start();
uloop.run();

// attempt 1: no ttys -> new_id written (netdev anchor), retriable no_at_port
let first = filter(events, (e) => e.event == 'error')[0];
eq(first?.data?.err?.error, 'no_at_port', 'attempt 1 fails retriable while the ttys are absent');
ok(first?.data?.err?.device == 'usb0', 'no_at_port error names the netdev anchor');
ok(length(filter(fx.actions, (a) => index(a, 'new_id') >= 0)) >= 1,
	'serial new_id bind ran off the datapath netdev (device is null)');

// retry: ttys present -> discovery finds the role-tagged AT port from scratch
eq(seen_tty, '/dev/ttyUSB2', 'retry discovers the SLM770A AT port (if4) via the netdev anchor');
eq(opened[0], '/dev/ttyUSB2', 'transport opened on the discovered tty');
eq(length(filter(events, (e) => e.event == 'error')), 1, 'exactly one failed attempt');

done('test_ncm_atdiscover');
