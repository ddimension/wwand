// wwand — sysfs device discovery + control-type detection (target-side).
//
// A modem is matched by one of: explicit cdc control-device path, parent
// netdev name, or stable USB path. From there we decide HOW the modem is
// controlled:
//
//   qmi   — a cdc-wdm control device bound to qmi_wwan
//   mbim  — a cdc-wdm control device bound to cdc_mbim
//   ncm   — NO cdc-wdm; a cdc_ncm/cdc_ether/rndis_host datapath netdev driven
//           over an AT tty (the AT port is the control channel)
//   ppp   — NO cdc-wdm and NO data netdev; only serial/ACM ports. Such a modem
//           has to be mode-switched to a richer usbnet mode before wwand can
//           manage it (daemon.uc drives that one-time switch).
//
// Everything here is host-testable: sysfs access goes through an injected `fx`
// (glob/readlink/lsdir/access/read); default_fx() wraps the real fs module.

'use strict';

import { glob, readlink, lsdir, access, open } from 'fs';
import * as atcmd from './atcmd.uc';

// datapath drivers that mean "no rich control protocol — driven over AT"
const NCM_DRIVERS = { cdc_ncm: true, cdc_ether: true, rndis_host: true };

// fs-backed effects; tests inject a fake object with the same method shape.
export function default_fx()
{
	return {
		glob:     (...p) => glob(...p),
		readlink: (p) => readlink(p),
		lsdir:    (p) => lsdir(p),
		access:   (p) => access(p) == true,
		read:     (p) => {
			let f = open(p, 'r');

			if (!f)
				return null;

			let data = f.read('all');
			f.close();

			return data;
		},
	};
}

function basename(p)
{
	return (p != null) ? substr(p, rindex(p, '/') + 1) : null;
}

// bound driver of a cdc-wdm control device (accepts a bare name or /dev/... path)
export function driver_of(cdc_name, fx)
{
	fx = fx ?? default_fx();

	let name = basename(cdc_name);
	let drv = fx.readlink(sprintf('/sys/class/usbmisc/%s/device/driver', name));

	return drv ? basename(drv) : null;
}

// control protocol implied by a cdc-wdm's bound driver, or null if unknown
export function protocol_of(device, fx)
{
	let drv = driver_of(device, fx);

	if (drv == 'qmi_wwan')
		return 'qmi';

	if (drv == 'cdc_mbim')
		return 'mbim';

	// cdc_ncm / cdc_ether: no rich control protocol — driven over AT (NCM).
	// rndis_host is the RNDIS variant of the same AT-controlled datapath.
	if (NCM_DRIVERS[drv])
		return 'ncm';

	return null;
}

// bound driver of a datapath netdev (basename of /sys/class/net/<n>/device/driver)
export function netdev_driver(netdev, fx)
{
	fx = fx ?? default_fx();

	if (!netdev)
		return null;

	let drv = fx.readlink(sprintf('/sys/class/net/%s/device/driver', netdev));

	return drv ? basename(drv) : null;
}

// control classification by NETDEV driver — this is how an NCM modem (which has
// no cdc-wdm) is recognised. qmi_wwan/cdc_mbim netdevs still resolve their
// control through the cdc-wdm (protocol_of); only the NCM drivers are terminal.
export function control_of_netdev(netdev, fx)
{
	let drv = netdev_driver(netdev, fx);

	if (drv == 'qmi_wwan')
		return 'qmi';

	if (drv == 'cdc_mbim')
		return 'mbim';

	if (NCM_DRIVERS[drv])
		return 'ncm';

	return null;
}

// '/dev/cdc-wdm0' -> 'wwan0'
export function netdev_for_device(device, fx)
{
	fx = fx ?? default_fx();

	let name = basename(device);
	let nets = fx.lsdir(sprintf('/sys/class/usbmisc/%s/device/net', name));

	return length(nets ?? []) ? nets[0] : null;
}

// 'wwan0' -> '/dev/cdc-wdm0'
export function device_for_netdev(netdev, fx)
{
	fx = fx ?? default_fx();

	let paths = fx.glob(sprintf('/sys/class/net/%s/device/usbmisc/cdc-wdm*', netdev),
	                    sprintf('/sys/class/net/%s/lower_*/device/usbmisc/cdc-wdm*', netdev));

	if (!length(paths ?? []))
		return null;

	return sprintf('/dev/%s', basename(paths[0]));
}

// '1-1.2' (usb path) -> '/dev/cdc-wdmX' | null
export function device_for_usb_path(usb_path, fx)
{
	fx = fx ?? default_fx();

	for (let path in (fx.glob('/sys/class/usbmisc/cdc-wdm*') ?? [])) {
		let name = basename(path);
		let dev = fx.readlink(sprintf('/sys/class/usbmisc/%s/device', name));

		if (dev == null)
			continue;

		// devpath looks like ../../../1-1.2:1.4 — match the usb device part.
		// return the cdc-wdm regardless of driver (qmi_wwan or cdc_mbim); the
		// mode is determined later when the device is opened/probed
		if (index(dev, sprintf('/%s:', usb_path)) >= 0 || index(dev, sprintf('/%s/', usb_path)) >= 0)
			return sprintf('/dev/%s', name);
	}

	return null;
}

// scan the interfaces of a USB device for a cdc_ncm/cdc_ether/rndis datapath
// netdev (an NCM modem exposes no cdc-wdm, so this is the only way to find it
// from a usb_path). '1-1.2' -> 'wwan0' | null
export function ncm_netdev_for_usb_path(usb_path, fx)
{
	fx = fx ?? default_fx();

	for (let path in (fx.glob('/sys/class/net/*') ?? [])) {
		let netdev = basename(path);

		if (!NCM_DRIVERS[netdev_driver(netdev, fx)])
			continue;

		let dev = fx.readlink(sprintf('/sys/class/net/%s/device', netdev));

		if (dev == null)
			continue;

		if (index(dev, sprintf('/%s:', usb_path)) >= 0 || index(dev, sprintf('/%s/', usb_path)) >= 0)
			return netdev;
	}

	return null;
}

// the AT port on the same USB device as an NCM datapath netdev. Reuses the
// atcmd port table/heuristic against the netdev's USB parent (device/..).
export function tty_for_netdev(fx, netdev, override)
{
	if (override != null && override != '')
		return override;

	if (!netdev)
		return null;

	return atcmd.find_tty(fx, null, null, sprintf('/sys/class/net/%s/device/..', netdev));
}

// the AT/serial port on a bare USB device (PPP-only: no netdev to anchor to)
export function tty_for_usb_path(fx, usb_path, override)
{
	if (override != null && override != '')
		return override;

	if (!usb_path)
		return null;

	return atcmd.find_tty(fx, null, null, sprintf('/sys/bus/usb/devices/%s', usb_path));
}

// enumerate EVERY manageable modem on the host: cdc-wdm control devices AND
// NCM datapath netdevs (which have no cdc-wdm). Shapes:
//   { device: '/dev/cdc-wdmN', protocol: 'qmi'|'mbim' }
//   { netdev: 'wwanN', protocol: 'ncm', tty: '/dev/ttyUSBn'|null }
export function list_devices(fx)
{
	fx = fx ?? default_fx();

	let found = [];

	for (let path in (fx.glob('/sys/class/usbmisc/cdc-wdm*') ?? [])) {
		let name = basename(path);
		let proto = protocol_of(name, fx);

		if (proto)
			push(found, { device: sprintf('/dev/%s', name), protocol: proto });
	}

	// NCM modems: a cdc_ncm/cdc_ether/rndis_host netdev with no cdc-wdm. These
	// drivers never back a cdc-wdm, so there is no overlap with the list above.
	for (let path in (fx.glob('/sys/class/net/*') ?? [])) {
		let netdev = basename(path);

		if (!NCM_DRIVERS[netdev_driver(netdev, fx)])
			continue;

		push(found, {
			netdev: netdev,
			protocol: 'ncm',
			tty: tty_for_netdev(fx, netdev, null),
		});
	}

	return found;
}

// resolve a modem config to its cdc-wdm control device (null for NCM/PPP modems,
// which have none — the caller falls back to the netdev/tty).
export function resolve_modem_device(cfg, fx)
{
	fx = fx ?? default_fx();

	if (cfg.device && fx.access(cfg.device))
		return cfg.device;

	if (cfg.netdev)
		return device_for_netdev(cfg.netdev, fx);

	if (cfg.usb_path)
		return device_for_usb_path(cfg.usb_path, fx);

	return null;
}

export function resolve_netdev(cfg, device, fx)
{
	if (cfg.netdev)
		return cfg.netdev;

	return device ? netdev_for_device(device, fx) : null;
}

// The central "how is this modem controlled" decision. Returns
//   { protocol, device, netdev, tty }
// or null when nothing is present yet (wait for hotplug). An explicit config
// `protocol` pin overrides the auto-detected protocol (device/netdev/tty are
// still resolved). Decision order:
//   1. a cdc-wdm control device (cfg.device/netdev/usb_path) -> qmi|mbim by
//      driver; netdev = its net; tty resolved later from the device.
//   2. else a cdc_ncm/cdc_ether/rndis netdev (cfg.netdev, or scan the usb_path's
//      interfaces) -> ncm; device = null; tty = the AT port on the same USB dev.
//   3. else only a serial/ACM port -> ppp (mode-switch candidate).
//   4. else null.
export function resolve_control(cfg, fx)
{
	fx = fx ?? default_fx();

	let pin = (cfg.protocol != null && cfg.protocol != 'auto') ? cfg.protocol : null;

	// 1. cdc-wdm control device present?
	let device = resolve_modem_device(cfg, fx);

	if (device) {
		return {
			protocol: pin ?? protocol_of(device, fx) ?? 'qmi',
			device: device,
			netdev: resolve_netdev(cfg, device, fx),
			tty: cfg.tty,
		};
	}

	// 2. an NCM datapath netdev (no cdc-wdm)?
	let netdev = null;

	if (cfg.netdev && NCM_DRIVERS[netdev_driver(cfg.netdev, fx)])
		netdev = cfg.netdev;
	else if (cfg.usb_path)
		netdev = ncm_netdev_for_usb_path(cfg.usb_path, fx);

	if (netdev) {
		return {
			protocol: pin ?? 'ncm',
			device: null,
			netdev: netdev,
			tty: tty_for_netdev(fx, netdev, cfg.tty),
		};
	}

	// 3. only a serial/ACM port -> PPP (needs a usbnet mode switch first)
	let tty = cfg.tty ? cfg.tty : (cfg.usb_path ? tty_for_usb_path(fx, cfg.usb_path) : null);

	if (tty) {
		return {
			protocol: pin ?? 'ppp',
			device: null,
			netdev: null,
			tty: tty,
		};
	}

	// 4. nothing present yet
	return null;
}
