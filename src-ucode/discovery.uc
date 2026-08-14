// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
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

import { glob, readlink, lsdir, access, open, realpath } from 'fs';
import * as atcmd from './atcmd.uc';

// datapath drivers that mean "no rich control protocol — driven over AT"
const NCM_DRIVERS = { cdc_ncm: true, cdc_ether: true, rndis_host: true };

// fs-backed effects; tests inject a fake object with the same method shape.
export function default_fx()
{
	return {
		glob:     (...p) => glob(...p),
		readlink: (p) => readlink(p),
		realpath: (p) => realpath(p),
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
};

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
};

// map a kernel wwan-framework control port (wwan0qmi0 / wwan0mbim0) to its
// control protocol via /sys/class/wwan/<name>/type. 'qmi' | 'mbim' | null.
function wwan_port_protocol(name, fx)
{
	let type = uc(trim(sprintf('%s', fx.read(sprintf('/sys/class/wwan/%s/type', name)) ?? '')));

	return (type == 'QMI') ? 'qmi' : (type == 'MBIM') ? 'mbim' : null;
}

// control protocol of a modem control DEVICE, or null if unknown.
export function protocol_of(device, fx)
{
	fx = fx ?? default_fx();

	// kernel wwan-framework control node (PCIe/MHI, some USB): the bound driver
	// is mhi-pci-generic / wwan, NOT qmi_wwan/cdc_mbim, so the protocol lives in
	// the port type file, not the driver. (Without this an MBIM-only MHI modem
	// like the RM520N on PCIe wrongly falls through to the qmi default and the
	// daemon runs QMI CTL SYNC against an MBIM port -> sync timeout.)
	let base = basename(sprintf('%s', device ?? ''));

	if (substr(base, 0, 4) == 'wwan') {
		let p = wwan_port_protocol(base, fx);

		if (p)
			return p;
	}

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
};

// bound driver of a datapath netdev (basename of /sys/class/net/<n>/device/driver)
export function netdev_driver(netdev, fx)
{
	fx = fx ?? default_fx();

	if (!netdev)
		return null;

	let drv = fx.readlink(sprintf('/sys/class/net/%s/device/driver', netdev));

	return drv ? basename(drv) : null;
};

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
};

// '/dev/cdc-wdm0' -> 'wwan0'
export function netdev_for_device(device, fx)
{
	fx = fx ?? default_fx();

	let name = basename(device);

	// USB cdc-wdm: the datapath netdev is a sibling under the same USB interface
	let nets = fx.lsdir(sprintf('/sys/class/usbmisc/%s/device/net', name));

	if (length(nets ?? []))
		return nets[0];

	// kernel wwan-framework control node (PCIe/MHI): the data netdev sits under
	// the SAME wwan device as the control port — e.g. wwan0mbim0 and the wwan0
	// netdev both resolve to .../mhiN/wwan/wwan0. Match the netdev whose device
	// path equals the control port's. (HW-confirmed on a T99W175/DELL X55 on
	// mhi-pci-generic: without this the MBIM datapath had no netdev and netifd
	// failed to claim the interface -> DEVICE_CLAIM_FAILED.)
	if (substr(name, 0, 4) == 'wwan') {
		let devdir = fx.realpath(sprintf('/sys/class/wwan/%s/device', name));

		if (devdir)
			for (let path in (fx.glob('/sys/class/net/*') ?? [])) {
				let nd = basename(path);

				if (fx.realpath(sprintf('/sys/class/net/%s/device', nd)) == devdir)
					return nd;
			}
	}

	return null;
};

// 'wwan0' -> '/dev/cdc-wdm0'
export function device_for_netdev(netdev, fx)
{
	fx = fx ?? default_fx();

	let paths = fx.glob(sprintf('/sys/class/net/%s/device/usbmisc/cdc-wdm*', netdev),
	                    sprintf('/sys/class/net/%s/lower_*/device/usbmisc/cdc-wdm*', netdev));

	if (!length(paths ?? []))
		return null;

	return sprintf('/dev/%s', basename(paths[0]));
};

// cdc-wdm interface basename -> its USB device id ('3-1', '1-1.2', …) or null.
// The `device` symlink of a cdc-wdm points at the USB *interface* (…/3-1:1.4);
// the parent USB device (…/3-1) carries the iSerial. Strip the ':<cfg>.<if>'.
export function usb_device_of(name, fx)
{
	fx = fx ?? default_fx();

	let dev = fx.readlink(sprintf('/sys/class/usbmisc/%s/device', name));

	if (dev == null)
		return null;

	let m = match(basename(dev), /^([0-9]+-[0-9.]+):/);

	return m ? m[1] : null;
};

// wireless-style stable device path (same convention as `wifi-device option
// path`): the modem's physical device path relative to /sys/devices — anchored
// at the controller, valid across enumeration order and across USB/PCIe/MHI.
// `class_link` is a /sys/class/.../device link; for a USB function the resolved
// INTERFACE dir (…/3-1:1.4) has its trailing interface component dropped so the
// path names the USB *device* (…/usb3/3-1). null when unresolvable.
export function sysfs_path_of(class_link, fx)
{
	fx = fx ?? default_fx();

	let real = fx.realpath ? fx.realpath(class_link) : null;

	if (real == null)
		return null;

	let p = replace(real, /^\/sys\/devices\//, '');

	if (p == real)
		return null;

	let parts = split(p, '/');

	if (match(parts[-1], /^[0-9]+-[0-9.]+:[0-9.]+$/))
		p = join('/', slice(parts, 0, length(parts) - 1));

	return p;
};

// does the candidate's full sysfs path (relative to /sys/devices) fall under
// the configured wireless-style path? Exact device dir or any parent (a user
// may pin just the controller/port prefix).
function full_path_matches(cfg_path, cand_path)
{
	if (cand_path == null)
		return false;

	return cand_path == cfg_path ||
	       substr(cand_path, 0, length(cfg_path) + 1) == cfg_path + '/';
};

// USB device id ('3-1') -> its iSerial string (trimmed) or null.
export function usb_serial_of(usbid, fx)
{
	fx = fx ?? default_fx();

	if (!usbid)
		return null;

	let s = fx.read(sprintf('/sys/bus/usb/devices/%s/serial', usbid));

	return (s != null) ? trim(s) : null;
};

// USB iSerial -> '/dev/cdc-wdmX' | null. Matches ONLY when exactly one physical
// USB device carries that serial (several cdc-wdm nodes on the *same* modem are
// fine — grouped by USB device); an empty/duplicated serial across two modems is
// ambiguous and returns null so the caller falls back to a topological anchor.
export function device_for_serial(serial, fx)
{
	fx = fx ?? default_fx();

	if (serial == null || serial == '')
		return null;

	let byusb = {};   // usbid -> first matching /dev/cdc-wdmX

	for (let path in (fx.glob('/sys/class/usbmisc/cdc-wdm*') ?? [])) {
		let name = basename(path);
		let usbid = usb_device_of(name, fx);

		if (usbid == null || usb_serial_of(usbid, fx) != serial)
			continue;

		if (byusb[usbid] == null)
			byusb[usbid] = sprintf('/dev/%s', name);
	}

	let ids = keys(byusb);

	return (length(ids) == 1) ? byusb[ids[0]] : null;
};

// kernel `wwan` framework control ports (PCIe/MHI, and some USB modems): the
// class dir holds one device per port — wwanXqmiN / wwanXmbimN / wwanXatN — with
// the char device at /dev/<name> and the port type in the `type` file
// ("QMI"/"MBIM"/"AT"/"QCDM"/…). Returns the QMI/MBIM CONTROL ports only (AT is
// resolved separately by atcmd.find_mhi_at). [ { name, protocol } ].
function wwan_control_ports(fx)
{
	let out = [];

	for (let path in (fx.glob('/sys/class/wwan/*') ?? [])) {
		let name = basename(path);
		let proto = wwan_port_protocol(name, fx);

		if (proto)
			push(out, { name: name, protocol: proto });
	}

	return out;
}

// enumerate the modem control devices physically present now — cdc-wdm nodes
// (qmi/mbim), wwan-framework control ports (PCIe/MHI) and NCM datapath netdevs —
// each with USB id and iSerial read pre-open from sysfs. Powers the LuCI
// "detected modems" picker. IMEI is NOT read here (needs opening the modem); the
// daemon fills it in for managed modems.
export function list_present(fx)
{
	fx = fx ?? default_fx();

	let out = [];

	for (let path in (fx.glob('/sys/class/usbmisc/cdc-wdm*') ?? [])) {
		let name = basename(path);
		let usbid = usb_device_of(name, fx);

		push(out, {
			kind: 'cdc-wdm',
			device: sprintf('/dev/%s', name),
			protocol: protocol_of(sprintf('/dev/%s', name), fx),
			usb_path: usbid,
			path: sysfs_path_of(sprintf('/sys/class/usbmisc/%s/device', name), fx),
			serial: usb_serial_of(usbid, fx),
		});
	}

	// PCIe/MHI (and some USB) modems expose QMI/MBIM over the kernel wwan
	// framework instead of a cdc-wdm node. No pre-open iSerial for MHI/PCIe —
	// identity is read after opening the modem (the post-open gate).
	for (let p in wwan_control_ports(fx)) {
		push(out, {
			kind: 'wwan',
			device: sprintf('/dev/%s', p.name),
			protocol: p.protocol,
			path: sysfs_path_of(sprintf('/sys/class/wwan/%s/device', p.name), fx),
			serial: null,
		});
	}

	for (let path in (fx.glob('/sys/class/net/*') ?? [])) {
		let netdev = basename(path);

		if (!NCM_DRIVERS[netdev_driver(netdev, fx)])
			continue;

		let dev = fx.readlink(sprintf('/sys/class/net/%s/device', netdev));
		let m = dev ? match(basename(dev), /^([0-9]+-[0-9.]+):/) : null;
		let usbid = m ? m[1] : null;

		push(out, {
			kind: 'ncm',
			netdev: netdev,
			protocol: 'ncm',
			usb_path: usbid,
			path: sysfs_path_of(sprintf('/sys/class/net/%s/device', netdev), fx),
			serial: usb_serial_of(usbid, fx),
		});
	}

	return out;
};

// IMEI digits that identify a device (TAC+serial, 14) — drops the check digit /
// IMEISV software-version. Local to discovery so this layer keeps no upward
// dependency on modem_common (which has the same helper for the post-open gate).
function imei14(s)
{
	return substr(replace(sprintf('%s', s ?? ''), /[^0-9]/g, ''), 0, 14);
}

// Some modems publish their IMEI AS the USB iSerial → `option imei` can match
// PRE-OPEN like `serial`. Matches only when a present modem's iSerial normalises
// to the same 14 IMEI digits, both full 14 (so a short vendor serial or the dummy
// '0123456789ABCDEF' never false-hits). Others fall through to the post-open gate.
export function device_for_imei(imei, fx)
{
	fx = fx ?? default_fx();

	let want = imei14(imei);

	if (length(want) < 14)
		return null;

	let byusb = {};

	for (let path in (fx.glob('/sys/class/usbmisc/cdc-wdm*') ?? [])) {
		let name = basename(path);
		let usbid = usb_device_of(name, fx);

		if (usbid == null || imei14(usb_serial_of(usbid, fx)) != want)
			continue;

		if (byusb[usbid] == null)
			byusb[usbid] = sprintf('/dev/%s', name);
	}

	let ids = keys(byusb);

	return (length(ids) == 1) ? byusb[ids[0]] : null;
};

// NCM counterpart of device_for_imei (IMEI published as the iSerial), matched on
// the datapath netdev's USB parent.
export function ncm_netdev_for_imei(imei, fx)
{
	fx = fx ?? default_fx();

	let want = imei14(imei);

	if (length(want) < 14)
		return null;

	let byusb = {};

	for (let path in (fx.glob('/sys/class/net/*') ?? [])) {
		let netdev = basename(path);

		if (!NCM_DRIVERS[netdev_driver(netdev, fx)])
			continue;

		let dev = fx.readlink(sprintf('/sys/class/net/%s/device', netdev));
		let m = dev ? match(basename(dev), /^([0-9]+-[0-9.]+):/) : null;
		let usbid = m ? m[1] : null;

		if (usbid == null || imei14(usb_serial_of(usbid, fx)) != want)
			continue;

		if (byusb[usbid] == null)
			byusb[usbid] = netdev;
	}

	let ids = keys(byusb);

	return (length(ids) == 1) ? byusb[ids[0]] : null;
};

// path -> '/dev/cdc-wdmX' | null. Accepts BOTH forms: the bare USB id
// ('1-1.2', legacy) and the wireless-style full sysfs path
// ('platform/…/usb3/3-1', works for PCIe/MHI too — recognized by a '/').
export function device_for_usb_path(usb_path, fx)
{
	fx = fx ?? default_fx();

	let full = index(usb_path, '/') >= 0;

	for (let path in (fx.glob('/sys/class/usbmisc/cdc-wdm*') ?? [])) {
		let name = basename(path);
		let link = sprintf('/sys/class/usbmisc/%s/device', name);

		if (full) {
			if (full_path_matches(usb_path, sysfs_path_of(link, fx)))
				return sprintf('/dev/%s', name);

			continue;
		}

		let dev = fx.readlink(link);

		if (dev == null)
			continue;

		// devpath looks like ../../../1-1.2:1.4 — match the usb device part.
		// return the cdc-wdm regardless of driver (qmi_wwan or cdc_mbim); the
		// mode is determined later when the device is opened/probed
		if (index(dev, sprintf('/%s:', usb_path)) >= 0 || index(dev, sprintf('/%s/', usb_path)) >= 0)
			return sprintf('/dev/%s', name);
	}

	// PCIe/MHI (and some USB): the wwan-framework control node. MHI uses the full
	// sysfs-path form; the bare-id form is matched too for USB wwan modems.
	for (let p in wwan_control_ports(fx)) {
		let link = sprintf('/sys/class/wwan/%s/device', p.name);

		if (full) {
			if (full_path_matches(usb_path, sysfs_path_of(link, fx)))
				return sprintf('/dev/%s', p.name);

			continue;
		}

		let dev = fx.readlink(link);

		if (dev != null &&
		    (index(dev, sprintf('/%s:', usb_path)) >= 0 || index(dev, sprintf('/%s/', usb_path)) >= 0))
			return sprintf('/dev/%s', p.name);
	}

	return null;
};

// scan the interfaces of a USB device for a cdc_ncm/cdc_ether/rndis datapath
// netdev (an NCM modem exposes no cdc-wdm, so this is the only way to find it
// from a usb_path). '1-1.2' -> 'wwan0' | null
export function ncm_netdev_for_usb_path(usb_path, fx)
{
	fx = fx ?? default_fx();

	let full = index(usb_path, '/') >= 0;

	for (let path in (fx.glob('/sys/class/net/*') ?? [])) {
		let netdev = basename(path);

		if (!NCM_DRIVERS[netdev_driver(netdev, fx)])
			continue;

		let link = sprintf('/sys/class/net/%s/device', netdev);

		if (full) {
			if (full_path_matches(usb_path, sysfs_path_of(link, fx)))
				return netdev;

			continue;
		}

		let dev = fx.readlink(link);

		if (dev == null)
			continue;

		if (index(dev, sprintf('/%s:', usb_path)) >= 0 || index(dev, sprintf('/%s/', usb_path)) >= 0)
			return netdev;
	}

	return null;
};

// USB iSerial -> an NCM datapath netdev (no cdc-wdm), matched on the netdev's
// USB parent. Unique physical match only, like device_for_serial.
export function ncm_netdev_for_serial(serial, fx)
{
	fx = fx ?? default_fx();

	if (serial == null || serial == '')
		return null;

	let byusb = {};

	for (let path in (fx.glob('/sys/class/net/*') ?? [])) {
		let netdev = basename(path);

		if (!NCM_DRIVERS[netdev_driver(netdev, fx)])
			continue;

		let dev = fx.readlink(sprintf('/sys/class/net/%s/device', netdev));

		if (dev == null)
			continue;

		let m = match(basename(dev), /^([0-9]+-[0-9.]+):/);
		let usbid = m ? m[1] : null;

		if (usbid == null || usb_serial_of(usbid, fx) != serial)
			continue;

		if (byusb[usbid] == null)
			byusb[usbid] = netdev;
	}

	let ids = keys(byusb);

	return (length(ids) == 1) ? byusb[ids[0]] : null;
};

// the AT port on the same USB device as an NCM datapath netdev. Reuses the
// atcmd port table/heuristic against the netdev's USB parent (device/..).
export function tty_for_netdev(fx, netdev, override)
{
	if (override != null && override != '')
		return override;

	if (!netdev)
		return null;

	return atcmd.find_tty(fx, null, null, sprintf('/sys/class/net/%s/device/..', netdev));
};

// the AT/serial port on a bare USB device (PPP-only: no netdev to anchor to)
export function tty_for_usb_path(fx, usb_path, override)
{
	if (override != null && override != '')
		return override;

	if (!usb_path)
		return null;

	// full wireless-style path vs bare USB id (see device_for_usb_path)
	let base = (index(usb_path, '/') >= 0)
		? sprintf('/sys/devices/%s', usb_path)
		: sprintf('/sys/bus/usb/devices/%s', usb_path);

	return atcmd.find_tty(fx, null, null, base);
};

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
};

// resolve a modem config to its cdc-wdm control device (null for NCM/PPP modems,
// which have none — the caller falls back to the netdev/tty).
export function resolve_modem_device(cfg, fx)
{
	fx = fx ?? default_fx();

	// stable identity first: a pinned USB iSerial follows the modem across
	// re-enumeration and port changes. Unique physical match only; an absent or
	// ambiguous serial falls through to the topological anchors below.
	if (cfg.serial) {
		let dev = device_for_serial(cfg.serial, fx);

		if (dev)
			return dev;
	}

	// a pinned IMEI is normally verified post-open, but modems that publish their
	// IMEI as the iSerial can be matched pre-open here too — same effect as serial.
	if (cfg.imei) {
		let dev = device_for_imei(cfg.imei, fx);

		if (dev)
			return dev;
	}

	// a control node is ALWAYS an absolute /dev path — only then does an existing
	// `device` resolve to itself. (Guarding on the leading '/' matters: a bare
	// netdev name like 'wwan0' can spuriously pass fx.access depending on the
	// daemon's cwd, which would make the daemon try to open "wwan0" as a device.)
	if (cfg.device && substr(cfg.device, 0, 1) == '/' && fx.access(cfg.device))
		return cfg.device;

	// a `device` that is NOT an absolute /dev node is a netdev name
	// (wwan0 / wwan0mN) — resolve it like `netdev`, so `option device 'wwan0'`
	// works (mirrors how the compat layer reads an interface `device`). The
	// parent netdev carries the cdc-wdm, so strip any mux suffix first.
	if (cfg.device && substr(cfg.device, 0, 1) != '/') {
		let base = match(cfg.device, /^(wwan[0-9]+)(m[0-9]+)?$/);
		let dev = device_for_netdev(base ? base[1] : cfg.device, fx);

		if (dev)
			return dev;
	}

	if (cfg.netdev)
		return device_for_netdev(cfg.netdev, fx);

	if (cfg.usb_path)
		return device_for_usb_path(cfg.usb_path, fx);

	return null;
};

export function resolve_netdev(cfg, device, fx)
{
	if (cfg.netdev)
		return cfg.netdev;

	return device ? netdev_for_device(device, fx) : null;
};

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

	if (cfg.serial)
		netdev = ncm_netdev_for_serial(cfg.serial, fx);

	if (!netdev && cfg.imei)
		netdev = ncm_netdev_for_imei(cfg.imei, fx);

	if (!netdev && cfg.netdev && NCM_DRIVERS[netdev_driver(cfg.netdev, fx)])
		netdev = cfg.netdev;

	// the migrated network model stores a netdev-name in the modem `device`
	// (there is no /dev control node for NCM) — accept it here too, so a modem
	// whose `serial` anchor got lost (e.g. a config rewrite) still resolves
	if (!netdev && cfg.device && NCM_DRIVERS[netdev_driver(cfg.device, fx)])
		netdev = cfg.device;

	if (!netdev && cfg.usb_path)
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
};
