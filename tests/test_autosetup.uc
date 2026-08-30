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

let netifd_reloads = 0;

let created_plugins = null;

function mk(present, created, opts)
{
	return daemon_mod.create({ deps: {
		log: (lvl, msg) => null,
		autosetup_create: (dev, plugins) => {
			push(created, dev);
			created_plugins = plugins;
			return opts?.create_result ?? true;
		},
		list_present: () => present,
		network_reload: () => netifd_reloads++,
		...(opts?.deps ?? {}),
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
// netifd has to be told as well: the sections went straight into uci, so until
// it re-reads them `network.interface.wwan0` does not exist for it (NOT_FOUND
// on every kick — a virgin BPi-R4 sat there with a created-but-unknown iface).
eq(netifd_reloads, 1, 'scan: successful create also reloads netifd');

// (2) cdc-wdm control device -> replayed as the hotplug BASENAME ('cdc-wdm0'),
// not the /dev path (autosetup_create re-prefixes /dev/ itself)
created = [];
d = mk([ { kind: 'cdc-wdm', device: '/dev/cdc-wdm0', protocol: 'qmi' } ], created);
d.autosetup_scan();
eq(created, [ 'cdc-wdm0' ], 'scan: cdc-wdm replayed as basename');

// autosetup decides whether the interface it creates carries a mux channel, and
// it can only do that if the daemon hands it the datapaths installed on THIS
// box — the daemon is the side that scans for them.
created = [];
d = mk([ { kind: 'cdc-wdm', device: '/dev/cdc-wdm0', protocol: 'qmi' } ], created, {
	deps: {
		datapath_fx: { glob: () => [ '/usr/share/ucode/wwand/datapath_vendorx.uc' ] },
		load_datapath: (n) => (n == 'vendorx') ? { links: () => [] } : null,
	},
});
d.autosetup_scan();
ok(created_plugins != null && created_plugins.vendorx != null,
	'scan: the installed datapaths are handed to autosetup_create');

// `datapath_<name>.uc` is the ADD-ON namespace: only a real plugin may answer
// this glob. Our own QMI bring-up used to sit there as datapath_qmi.uc and was
// offered as a plugin on every start; it is modem_datapath_qmi.uc now, so the
// glob no longer sees it at all.
created = [];
d = mk([ { kind: 'cdc-wdm', device: '/dev/cdc-wdm0', protocol: 'qmi' } ], created, {
	deps: {
		datapath_fx: { glob: () => [ '/usr/share/ucode/wwand/modem_datapath_qmi.uc',
		                             '/usr/share/ucode/wwand/datapath_vendorx.uc' ] },
		load_datapath: (n) => (n == 'vendorx') ? { links: () => [] } : null,
	},
});
d.autosetup_scan();
eq(keys(created_plugins ?? {}), [ 'vendorx' ],
	'scan: an internal module outside the add-on namespace is not scanned');

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

// (6) no create -> netifd is left alone
netifd_reloads = 0;
created = [];
d = mk([ { kind: 'ncm', netdev: 'usb0' } ], created, { create_result: false });
d.autosetup_scan();
eq(created, [ 'usb0' ], 'scan: candidate offered');
eq(netifd_reloads, 0, 'scan: a declined create does not reload netifd');

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
