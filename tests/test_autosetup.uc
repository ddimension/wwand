// wwand tests — zero-config autosetup boot-time sweep (daemon.autosetup_scan).
//
// The hotplug 'add' that triggers autosetup phase 1 is LOST when the modem
// enumerated before the daemon was on the bus (slow cold boot: kmods bind the
// netdev tens of seconds before procd starts wwand — the Cudy LT300 case).
// autosetup_scan replays what is already present at startup through the same
// hotplug path; autosetup_create re-checks the live uci, so a configured box
// is never touched.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as daemon_mod from 'wwand/daemon.uc';

function mk(present, created, opts)
{
	return daemon_mod.create({ deps: {
		log: (lvl, msg) => null,
		autosetup_create: (dev) => { push(created, dev); return opts?.create_result ?? true; },
		list_present: () => present,
	} });
}

// (1) NCM netdev present on an unconfigured box -> replayed as hotplug add,
// successful create reloads the config
let created = [];
let d = mk([ { kind: 'ncm', netdev: 'usb0', protocol: 'ncm' } ], created);
let reloads = 0;
d.reload = () => reloads++;
d.autosetup_scan();
eq(created, [ 'usb0' ], 'scan: ncm netdev replayed into autosetup_create');
eq(reloads, 1, 'scan: successful create triggers a config reload');

// (2) cdc-wdm control device -> replayed as the hotplug BASENAME ('cdc-wdm0'),
// not the /dev path (autosetup_create re-prefixes /dev/ itself)
created = [];
d = mk([ { kind: 'cdc-wdm', device: '/dev/cdc-wdm0', protocol: 'qmi' } ], created);
d.autosetup_scan();
eq(created, [ 'cdc-wdm0' ], 'scan: cdc-wdm replayed as basename');

// (3) one-shot: only the first candidate is replayed
created = [];
d = mk([ { kind: 'cdc-wdm', device: '/dev/cdc-wdm0' },
         { kind: 'ncm', netdev: 'usb0' } ], created);
d.autosetup_scan();
eq(created, [ 'cdc-wdm0' ], 'scan: first candidate only');

// (4) configured box (modems exist) -> untouched
created = [];
d = mk([ { kind: 'ncm', netdev: 'usb0' } ], created);
d.modems.wwmodem0 = { cfg: {} };
d.autosetup_scan();
eq(created, [], 'scan: skipped when modems are configured');

// (5) gated by wwand_globals autosetup
created = [];
d = mk([ { kind: 'ncm', netdev: 'usb0' } ], created);
d.autosetup = false;
d.autosetup_scan();
eq(created, [], 'scan: gated by the autosetup global');

// (6) nothing present -> nothing created
created = [];
d = mk([], created);
d.autosetup_scan();
eq(created, [], 'scan: empty box, no candidates, no-op');

// (7) an entry without a usable devname (defensive) is skipped in favour of
// the next candidate
created = [];
d = mk([ { kind: 'ncm' /* no netdev */ },
         { kind: 'ncm', netdev: 'usb1' } ], created);
d.autosetup_scan();
eq(created, [ 'usb1' ], 'scan: devname-less entry skipped');

done('test_autosetup');
