// wwand tests — generated AT port table sanity.

'use strict';

import { eq, ok, done } from './lib/check.uc';
const atport = require('wwand.atport');

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
