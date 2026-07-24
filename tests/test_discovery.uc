// wwand tests — control-type detection (discovery.uc) + the daemon's PPP-only
// mode-switch decision.
//
// discovery is exercised against a faked sysfs (lib/fakefx.uc extended with
// readlink/lsdir/access) covering every control type:
//   qmi/mbim  — a cdc-wdm control device, classified by its bound driver
//   ncm       — a cdc_ncm datapath netdev with NO cdc-wdm (AT-controlled)
//   ppp       — only a serial port (mode-switch candidate)
//   re-detect — a ppp-only USB device that, after a mode switch, re-enumerates
//               with a cdc-wdm -> resolve_control now reports qmi
// Plus a daemon-level check that a ppp-only modem triggers exactly one usbnet
// mode switch and builds no modem object (there is no PPP dialer).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as fakefx from './lib/fakefx.uc';
import * as mockhub from './lib/mockhub.uc';
import * as discovery from 'wwand/discovery.uc';
import * as config from 'wwand/config.uc';
import * as daemon_mod from 'wwand/daemon.uc';

// --- 1. cdc-wdm QMI ---------------------------------------------------------

let qmi_fx = fakefx.create({
	present: { '/dev/cdc-wdm0': true },
	links: { '/sys/class/usbmisc/cdc-wdm0/device/driver': '/sys/bus/usb/drivers/qmi_wwan' },
	dirs: { '/sys/class/usbmisc/cdc-wdm0/device/net': [ 'wwan0' ] },
});

let c1 = discovery.resolve_control({ device: '/dev/cdc-wdm0', tty: null }, qmi_fx);
eq(c1.protocol, 'qmi', 'cdc-wdm qmi_wwan -> qmi');
eq(c1.device, '/dev/cdc-wdm0', 'qmi: control device');
eq(c1.netdev, 'wwan0', 'qmi: netdev from device/net');

// --- 1b. `option device` holding a NETDEV name (network-native migration form) -
// a `device` that is not a /dev control node is resolved as a netdev, so a bare
// `option device 'wwan0'` (what the migration writes) binds the modem.
let dev_netdev_fx = fakefx.create({
	present: { '/sys/class/net/wwan0/device/usbmisc/cdc-wdm0': true },
	links: { '/sys/class/usbmisc/cdc-wdm0/device/driver': '/sys/bus/usb/drivers/qmi_wwan' },
	dirs: { '/sys/class/usbmisc/cdc-wdm0/device/net': [ 'wwan0' ] },
});
let cdn = discovery.resolve_control({ device: 'wwan0', tty: null }, dev_netdev_fx);
eq(cdn?.device, '/dev/cdc-wdm0', 'device=wwan0 (netdev name) resolves to the cdc-wdm');
eq(cdn?.protocol, 'qmi', 'device=netdev-name classified by driver');
eq(cdn?.netdev, 'wwan0', 'device=netdev-name: netdev derived');
// a muxed name strips its mN suffix to the parent netdev
let cdm = discovery.resolve_control({ device: 'wwan0m1', tty: null }, dev_netdev_fx);
eq(cdm?.device, '/dev/cdc-wdm0', 'device=wwan0m1 strips mux suffix -> parent netdev resolves');

// a control node is only an ABSOLUTE /dev path: a bare netdev name that happens
// to pass fx.access (cwd-dependent on real HW) must NOT be opened as a device —
// it still resolves via the netdev. (Regression: on an MBIM box access('wwan0')
// was true, so the daemon tried to open "wwan0" and the modem went ABSENT.)
let dev_access_fx = fakefx.create({
	present: {
		'wwan0': true,   // access('wwan0') is true here
		'/sys/class/net/wwan0/device/usbmisc/cdc-wdm0': true,
	},
	links: { '/sys/class/usbmisc/cdc-wdm0/device/driver': '/sys/bus/usb/drivers/cdc_mbim' },
	dirs: { '/sys/class/usbmisc/cdc-wdm0/device/net': [ 'wwan0' ] },
});
eq(discovery.resolve_modem_device({ device: 'wwan0' }, dev_access_fx), '/dev/cdc-wdm0',
	'device=wwan0 resolves via netdev even when access(wwan0) is true');

// --- 1e. stable USB-iSerial anchor (option serial) --------------------------
// A pinned iSerial resolves the modem's cdc-wdm via its USB device parent,
// independent of the /dev index or netdev name (the RG650E reports '99efe861').
let serial_fx = fakefx.create({
	present: { '/sys/class/usbmisc/cdc-wdm0': true },
	links: { '/sys/class/usbmisc/cdc-wdm0/device': '../../../3-1:1.4',
	         '/sys/class/usbmisc/cdc-wdm0/device/driver': '/sys/bus/usb/drivers/qmi_wwan' },
	files: { '/sys/bus/usb/devices/3-1/serial': '99efe861\n' },
	dirs: { '/sys/class/usbmisc/cdc-wdm0/device/net': [ 'wwan0' ] },
});
eq(discovery.device_for_serial('99efe861', serial_fx), '/dev/cdc-wdm0',
	'serial: iSerial resolves the cdc-wdm device');
eq(discovery.resolve_modem_device({ serial: '99efe861' }, serial_fx), '/dev/cdc-wdm0',
	'serial: resolve_modem_device binds by iSerial alone');
let cser = discovery.resolve_control({ serial: '99efe861', tty: null }, serial_fx);
eq(cser?.protocol, 'qmi', 'serial: control type still auto-detected (qmi)');
eq(cser?.device, '/dev/cdc-wdm0', 'serial: resolve_control device via serial');
eq(discovery.device_for_serial('deadbeef', serial_fx), null,
	'serial: unknown iSerial does not match');
// serial precedence: a stale /dev index in `device` is overridden by the serial
eq(discovery.resolve_modem_device({ serial: '99efe861', device: '/dev/cdc-wdm9' }, serial_fx),
	'/dev/cdc-wdm0', 'serial: pinned iSerial overrides a stale device index');

// --- 1f. ambiguous serial -> null (falls back to a topological anchor) ------
let dup_fx = fakefx.create({
	present: { '/sys/class/usbmisc/cdc-wdm0': true, '/sys/class/usbmisc/cdc-wdm1': true },
	links: { '/sys/class/usbmisc/cdc-wdm0/device': '../../../3-1:1.4',
	         '/sys/class/usbmisc/cdc-wdm1/device': '../../../4-1:1.4' },
	files: { '/sys/bus/usb/devices/3-1/serial': 'SAME\n',
	         '/sys/bus/usb/devices/4-1/serial': 'SAME\n' },
});
eq(discovery.device_for_serial('SAME', dup_fx), null,
	'serial: same iSerial on two USB devices is ambiguous -> null');
// several cdc-wdm on ONE modem (e.g. qmi+mbim) is NOT ambiguous -> still binds
let multi_fx = fakefx.create({
	present: { '/sys/class/usbmisc/cdc-wdm0': true, '/sys/class/usbmisc/cdc-wdm1': true },
	links: { '/sys/class/usbmisc/cdc-wdm0/device': '../../../3-1:1.4',
	         '/sys/class/usbmisc/cdc-wdm1/device': '../../../3-1:1.6' },
	files: { '/sys/bus/usb/devices/3-1/serial': 'UNIQUE\n' },
});
ok(discovery.device_for_serial('UNIQUE', multi_fx) != null,
	'serial: two cdc-wdm on one modem still bind (grouped by USB device)');

// --- 2. cdc-wdm MBIM --------------------------------------------------------

let mbim_fx = fakefx.create({
	present: { '/dev/cdc-wdm0': true },
	links: { '/sys/class/usbmisc/cdc-wdm0/device/driver': '/sys/bus/usb/drivers/cdc_mbim' },
	dirs: { '/sys/class/usbmisc/cdc-wdm0/device/net': [ 'wwan0' ] },
});

let c2 = discovery.resolve_control({ device: '/dev/cdc-wdm0', tty: null }, mbim_fx);
eq(c2.protocol, 'mbim', 'cdc-wdm cdc_mbim -> mbim');
eq(c2.device, '/dev/cdc-wdm0', 'mbim: control device');

// config protocol pin overrides auto-detection (device still resolved)
let c2p = discovery.resolve_control({ device: '/dev/cdc-wdm0', protocol: 'qmi', tty: null }, mbim_fx);
eq(c2p.protocol, 'qmi', 'protocol pin overrides driver classification');

// --- 3. NCM netdev (no cdc-wdm) ---------------------------------------------

let ncm_fx = fakefx.create({
	present: {
		// AT port sibling on the netdev's USB parent
		'/sys/class/net/wwan0/device/../3-1:1.3/ttyUSB2': true,
	},
	files: {
		'/sys/class/net/wwan0/device/../3-1:1.3/bInterfaceNumber': '03',
	},
	links: {
		'/sys/class/net/wwan0/device/driver': '/sys/bus/usb/drivers/cdc_ncm',
	},
});

let c3 = discovery.resolve_control({ netdev: 'wwan0', tty: null }, ncm_fx);
eq(c3.protocol, 'ncm', 'cdc_ncm netdev -> ncm');
eq(c3.device, null, 'ncm: no cdc-wdm control device');
eq(c3.netdev, 'wwan0', 'ncm: datapath netdev');
eq(c3.tty, '/dev/ttyUSB2', 'ncm: AT tty resolved from the netdev USB parent');

// netdev_driver + control_of_netdev directly
eq(discovery.netdev_driver('wwan0', ncm_fx), 'cdc_ncm', 'netdev_driver reads net/<n>/device/driver');
eq(discovery.control_of_netdev('wwan0', ncm_fx), 'ncm', 'control_of_netdev classifies cdc_ncm as ncm');

// NCM discovered from a usb_path (scan the USB device's interfaces)
let ncm_fx2 = fakefx.create({
	present: { '/sys/class/net/wwan0': true },
	links: {
		'/sys/class/net/wwan0/device/driver': '/sys/bus/usb/drivers/cdc_ether',
		'/sys/class/net/wwan0/device': '../../../3-1:1.2',
	},
});
let c3b = discovery.resolve_control({ usb_path: '3-1', tty: '/dev/ttyUSB1' }, ncm_fx2);
eq(c3b.protocol, 'ncm', 'usb_path scan finds cdc_ether netdev -> ncm');
eq(c3b.netdev, 'wwan0', 'ncm-by-usbpath: netdev');
eq(c3b.tty, '/dev/ttyUSB1', 'ncm-by-usbpath: tty override honored');

// --- 4. PPP-only (serial ports only) + re-detect after mode switch ----------

let ppp_fx = fakefx.create({
	present: {
		'/sys/bus/usb/devices/3-1/3-1:1.0/ttyUSB0': true,
	},
});

let c4 = discovery.resolve_control({ usb_path: '3-1', tty: null }, ppp_fx);
eq(c4.protocol, 'ppp', 'only serial ports -> ppp (mode-switch candidate)');
eq(c4.device, null, 'ppp: no control device');
eq(c4.netdev, null, 'ppp: no datapath netdev');
eq(c4.tty, '/dev/ttyUSB0', 'ppp: serial port found from usb_path');

// simulate the mode switch: a cdc-wdm now enumerates on the same USB device
ppp_fx.present['/sys/class/usbmisc/cdc-wdm0'] = true;
ppp_fx.present['/dev/cdc-wdm0'] = true;
ppp_fx.links['/sys/class/usbmisc/cdc-wdm0/device'] = '../../../3-1:1.4';
ppp_fx.links['/sys/class/usbmisc/cdc-wdm0/device/driver'] = '/sys/bus/usb/drivers/qmi_wwan';
ppp_fx.dirs['/sys/class/usbmisc/cdc-wdm0/device/net'] = [ 'wwan0' ];

let c4b = discovery.resolve_control({ usb_path: '3-1', tty: null }, ppp_fx);
eq(c4b.protocol, 'qmi', 're-detect: ppp modem re-enumerated as qmi after mode switch');
eq(c4b.device, '/dev/cdc-wdm0', 're-detect: control device now present');
eq(c4b.netdev, 'wwan0', 're-detect: netdev now present');

// nothing present at all -> null (wait for hotplug)
eq(discovery.resolve_control({ usb_path: '9-9', tty: null }, fakefx.create({})), null,
	'nothing present -> null');

// --- 5. list_devices enumerates cdc-wdm AND NCM netdevs ---------------------

let list_fx = fakefx.create({
	present: {
		'/sys/class/usbmisc/cdc-wdm0': true,
		'/sys/class/net/wwan0': true,
		'/sys/class/net/eth0': true,
	},
	links: {
		'/sys/class/usbmisc/cdc-wdm0/device/driver': '/sys/bus/usb/drivers/qmi_wwan',
		'/sys/class/net/wwan0/device/driver': '/sys/bus/usb/drivers/cdc_ncm',
		'/sys/class/net/eth0/device/driver': '/sys/bus/pci/drivers/mvneta',
	},
});

let listed = discovery.list_devices(list_fx);
eq(length(listed), 2, 'list_devices: cdc-wdm + ncm netdev, eth0 filtered out');
eq(listed[0], { device: '/dev/cdc-wdm0', protocol: 'qmi' }, 'list_devices: cdc-wdm qmi entry');
eq(listed[1].netdev, 'wwan0', 'list_devices: ncm netdev entry');
eq(listed[1].protocol, 'ncm', 'list_devices: ncm protocol');

// --- 6. daemon: PPP-only modem -> one-time mode switch, no modem object ------

uloop.init();

let ms_calls = [];

let d = daemon_mod.create({
	deps: {
		log: (level, msg) => null,
		resolve_control: (cfg) => ({ protocol: 'ppp', device: null, netdev: null, tty: '/dev/ttyUSB2' }),
		modeswitch: (o, cb) => { push(ms_calls, o.tty); cb(null, { switched: true, target: 'qmi' }); },
	},
});

d.apply_config(config.parse({
	wwand: { m0: { '.type': 'modem', usb_path: '3-1' } },
}));

eq(ms_calls, [ '/dev/ttyUSB2' ], 'ppp-only modem triggers a usbnet mode switch');
ok(!d.modems.m0.modem, 'ppp-only: no modem object is built');

// idempotent: a hotplug re-scan must NOT switch again
d.hotplug('add', 'ttyUSB2');
eq(length(ms_calls), 1, 'usbnet mode switch attempted only once per modem');

// --- 7. daemon: a mode switch that never re-enumerates is flagged (liveness) --
// The reset is fire-and-forget and the switch is once-guarded, so without a
// liveness timeout a modem that never comes back would be silently unmanaged.

// stuck case: resolve_control stays ppp -> no modem is ever built
let stuck_proto = 'ppp';
let ds = daemon_mod.create({
	timing: { modeswitch_liveness_ms: 30 },
	deps: {
		log: (level, msg) => null,
		transport_open: mockhub.create({ handlers: {} }).transport_open,
		resolve_control: (cfg) => (stuck_proto == 'ppp')
			? { protocol: 'ppp', device: null, netdev: null, tty: '/dev/ttyUSB2' }
			: { protocol: 'qmi', device: '/dev/cdc-wdm0', netdev: 'wwan0', tty: null },
		resolve_netdev: (cfg, dev) => 'wwan0',
		modeswitch: (o, cb) => cb(null, { switched: true, target: 'qmi' }),
	},
});

ds.apply_config(config.parse({ wwand: { m0: { '.type': 'modem', usb_path: '3-1' } } }));
ok(ds.modems.m0.modeswitch_liveness != null, 'liveness: watchdog armed after the switch');
eq(ds.modems.m0.control_note, null, 'liveness: not flagged before the timeout');

uloop.timer(70, () => {
	eq(ds.modems.m0.control_note, 'mode-switch did not re-enumerate',
		'liveness: stuck switch flagged after the timeout');
	eq(ds.status().modems.m0.control_note, 'mode-switch did not re-enumerate',
		'liveness: status() surfaces the stuck note');

	// recovered case: a fresh modem re-enumerates as qmi before the timeout ->
	// start_modem cancels the watchdog and clears the note
	let recov_proto = 'ppp';
	let dr = daemon_mod.create({
		timing: { modeswitch_liveness_ms: 10000 },
		deps: {
			log: (level, msg) => null,
			transport_open: mockhub.create({ handlers: {} }).transport_open,
			resolve_control: (cfg) => (recov_proto == 'ppp')
				? { protocol: 'ppp', device: null, netdev: null, tty: '/dev/ttyUSB2' }
				: { protocol: 'qmi', device: '/dev/cdc-wdm0', netdev: 'wwan0', tty: null },
			resolve_netdev: (cfg, dev) => 'wwan0',
			modeswitch: (o, cb) => cb(null, { switched: true, target: 'qmi' }),
		},
	});

	dr.apply_config(config.parse({ wwand: { m0: { '.type': 'modem', usb_path: '3-1' } } }));
	ok(dr.modems.m0.modeswitch_liveness != null, 'liveness: armed on the recovered daemon too');

	// re-enumeration: resolve_control now reports qmi; hotplug rebuilds the modem
	recov_proto = 'qmi';
	dr.hotplug('add', 'cdc-wdm0');

	eq(dr.modems.m0.modeswitch_liveness, null, 'liveness: watchdog cancelled once a modem is built');
	eq(dr.modems.m0.control_note, null, 'liveness: note cleared on successful re-enumeration');
	ok(dr.modems.m0.modem != null, 'liveness: a real modem object was built after re-enumeration');

	dr.shutdown();
	ds.shutdown();

	// --- 8. a backend whose package is not installed is reported, not crashed --
	// MBIM/NCM ship as separate packages (wwand-mbim / wwand-ncm); load_mbim/
	// load_ncm return null when the package is absent. start_modem must flag it
	// (control_note, surfaced in status) and leave the modem unmanaged instead of
	// throwing on the require() failure.
	let dm = daemon_mod.create({
		deps: {
			log: (level, msg) => null,
			transport_open: mockhub.create({ handlers: {} }).transport_open,
			resolve_control: (cfg) => ({ protocol: 'mbim', device: '/dev/cdc-wdm0', netdev: 'wwan0', tty: null }),
			resolve_netdev: (cfg, dev) => 'wwan0',
			load_mbim: () => null,   // wwand-mbim not installed
		},
	});

	dm.apply_config(config.parse({
		wwand: { m0: { '.type': 'modem', device: '/dev/cdc-wdm0' } },
	}));

	ok(!dm.modems.m0.modem, 'missing-pkg: no modem built when wwand-mbim is absent');
	eq(dm.modems.m0.control_note, 'wwand-mbim package not installed',
		'missing-pkg: control_note flags the missing backend package');
	eq(dm.status().modems.m0.control_note, 'wwand-mbim package not installed',
		'missing-pkg: status() surfaces it');

	// an NCM modem with wwand-ncm absent is flagged the same way
	let dn = daemon_mod.create({
		deps: {
			log: (level, msg) => null,
			transport_open: mockhub.create({ handlers: {} }).transport_open,
			resolve_control: (cfg) => ({ protocol: 'ncm', device: null, netdev: 'wwan0', tty: '/dev/ttyUSB2' }),
			resolve_netdev: (cfg, dev) => 'wwan0',
			load_ncm: () => null,   // wwand-ncm not installed
		},
	});

	dn.apply_config(config.parse({ wwand: { m0: { '.type': 'modem', usb_path: '3-1' } } }));
	eq(dn.modems.m0.control_note, 'wwand-ncm package not installed',
		'missing-pkg: NCM backend absence flagged too');

	// QMI itself is a separate package now (wwand-qmi); its absence is flagged too
	let dq = daemon_mod.create({
		deps: {
			log: (level, msg) => null,
			transport_open: mockhub.create({ handlers: {} }).transport_open,
			resolve_control: (cfg) => ({ protocol: 'qmi', device: '/dev/cdc-wdm0', netdev: 'wwan0', tty: null }),
			resolve_netdev: (cfg, dev) => 'wwan0',
			load_qmi: () => null,   // wwand-qmi not installed
		},
	});

	dq.apply_config(config.parse({ wwand: { m0: { '.type': 'modem', device: '/dev/cdc-wdm0' } } }));
	ok(!dq.modems.m0.modem, 'missing-pkg: no modem built when wwand-qmi is absent');
	eq(dq.modems.m0.control_note, 'wwand-qmi package not installed',
		'missing-pkg: QMI backend absence flagged too');

	dm.shutdown();
	dn.shutdown();
	dq.shutdown();
	uloop.end();
});

uloop.run();

done('test_discovery');
