// wwand tests — generated AT port table sanity.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as atcmd from 'wwand/atcmd.uc';
const atport = require('wwand.atport');

// --- dual AT channel discovery (find_at_channels) ---------------------------
// a modem with a role-tagged 'at2' port yields a dedicated telemetry channel;
// one without (only 'at') reuses the control channel.

function fake_fx(vidpid, ttys) {
	return {
		read: (p) => {
			if (index(p, 'board_name') >= 0) return '';
			if (index(p, 'idVendor') >= 0) return substr(vidpid, 0, 4);
			if (index(p, 'idProduct') >= 0) return substr(vidpid, 5);
			if (index(p, 'bInterfaceNumber') >= 0) {
				for (let t in ttys)
					if (index(p, sprintf(':1.%d/', t.ifn)) >= 0)
						return sprintf('%02x', t.ifn);
				return null;
			}
			return null;
		},
		glob: (pat) => map(ttys, (t) => sprintf('/sys/dev/2-1:1.%d/%s', t.ifn, t.tty)),
	};
}

// RG650E (2c7c:0122 -> {2:at, 3:at2}, via LOCAL_PORTS): ttyUSB2 control, ttyUSB3 telemetry
let ch = atcmd.find_at_channels(fake_fx('2c7c:0122', [ {ifn:2, tty:'ttyUSB2'}, {ifn:3, tty:'ttyUSB3'} ]),
                                '/dev/cdc-wdm0', null, null);
eq(ch.primary, '/dev/ttyUSB2', 'dual-at: primary = the at port');
eq(ch.telemetry, '/dev/ttyUSB3', 'dual-at: dedicated telemetry channel = the at2 port');

// EG06 (2c7c:0306 -> {1:gps, 2:at}, no at2): single channel
let ch2 = atcmd.find_at_channels(fake_fx('2c7c:0306', [ {ifn:1, tty:'ttyUSB1'}, {ifn:2, tty:'ttyUSB2'} ]),
                                 '/dev/cdc-wdm0', null, null);
eq(ch2.primary, '/dev/ttyUSB2', 'single-at: primary = the at port');
eq(ch2.telemetry, null, 'single-at: no dedicated telemetry channel (falls back to control)');

// known devices we care about
eq(atport['2c7c:0306']['2'], 'at', 'EG06 AT port on interface 2');
eq(atport['2c7c:0306']['1'], 'gps', 'EG06 GPS port on interface 1');
eq(atport['2c7c:0800']['2'], 'at', 'RG500Q/RG502Q AT port on interface 2');

// table hygiene: keys and roles well-formed
let devices = 0, entries = 0, bad = 0;
const ROLES = { at: true, at2: true, ppp: true, gps: true };

for (let id, ports in atport) {
	devices++;

	if (!match(id, /^[0-9a-f]{4}:[0-9a-f]{4}$/))
		bad++;

	for (let ifn, role in ports) {
		entries++;

		if (!match(ifn, /^[0-9]+$/) || !ROLES[role])
			bad++;
	}
}

ok(devices > 200, sprintf('table has %d devices', devices));
ok(entries > 400, sprintf('table has %d port entries', entries));
eq(bad, 0, 'all ids, interface numbers and roles well-formed');

// nearly every device offers an AT-capable port; a handful only carry a
// GPS tag in the parseable rule format (their AT ports use other udev
// patterns) — those fall back to the heuristic finder at runtime
let no_at = 0;

for (let id, ports in atport) {
	let has = false;

	for (let ifn, role in ports)
		if (role == 'at' || role == 'at2' || role == 'ppp')
			has = true;

	if (!has)
		no_at++;
}

ok(no_at <= 5, sprintf('only %d devices without AT-capable port entry', no_at));

done('test_atport');
