// wwand — sysfs device discovery helpers (target-side).
//
// Modems are matched by one of: explicit cdc device path, parent netdev
// name, or stable USB path. The bound driver selects the control protocol:
// qmi_wwan -> QMI, cdc_mbim -> MBIM.

'use strict';

import { glob, readlink, lsdir, access } from 'fs';

export function driver_of(cdc_name)
{
	// accept either a bare name or a /dev/... path
	let name = substr(cdc_name, rindex(cdc_name, '/') + 1);
	let drv = readlink(sprintf('/sys/class/usbmisc/%s/device/driver', name));

	return drv ? substr(drv, rindex(drv, '/') + 1) : null;
}

// control protocol implied by the bound driver, or null if unknown
export function protocol_of(device)
{
	let drv = driver_of(device);

	if (drv == 'qmi_wwan')
		return 'qmi';

	if (drv == 'cdc_mbim')
		return 'mbim';

	return null;
}

// all cdc-wdm control devices with their protocol
export function list_devices()
{
	let found = [];

	for (let path in (glob('/sys/class/usbmisc/cdc-wdm*') ?? [])) {
		let name = substr(path, rindex(path, '/') + 1);
		let proto = protocol_of(name);

		if (proto)
			push(found, { device: sprintf('/dev/%s', name), protocol: proto });
	}

	return found;
}

// '/dev/cdc-wdm0' -> 'wwan0'
export function netdev_for_device(device)
{
	let name = substr(device, rindex(device, '/') + 1);
	let nets = lsdir(sprintf('/sys/class/usbmisc/%s/device/net', name));

	return length(nets ?? []) ? nets[0] : null;
}

// 'wwan0' -> '/dev/cdc-wdm0'
export function device_for_netdev(netdev)
{
	let paths = glob(sprintf('/sys/class/net/%s/device/usbmisc/cdc-wdm*', netdev),
	                 sprintf('/sys/class/net/%s/lower_*/device/usbmisc/cdc-wdm*', netdev));

	if (!length(paths ?? []))
		return null;

	return sprintf('/dev/%s', substr(paths[0], rindex(paths[0], '/') + 1));
}

// '1-1.2' (usb path) -> '/dev/cdc-wdmX'
export function device_for_usb_path(usb_path)
{
	for (let path in (glob('/sys/class/usbmisc/cdc-wdm*') ?? [])) {
		let name = substr(path, rindex(path, '/') + 1);
		let dev = readlink(sprintf('/sys/class/usbmisc/%s/device', name));

		if (dev == null)
			continue;

		// devpath looks like ../../../1-1.2:1.4 — match the usb device part
		if (index(dev, sprintf('/%s:', usb_path)) >= 0 || index(dev, sprintf('/%s/', usb_path)) >= 0) {
			if (driver_of(name) != 'cdc_mbim')
				return sprintf('/dev/%s', name);
		}
	}

	return null;
}

// resolve a modem config to its control device
export function resolve_modem_device(cfg)
{
	if (cfg.device && access(cfg.device))
		return cfg.device;

	if (cfg.netdev)
		return device_for_netdev(cfg.netdev);

	if (cfg.usb_path)
		return device_for_usb_path(cfg.usb_path);

	return null;
}

export function resolve_netdev(cfg, device)
{
	if (cfg.netdev)
		return cfg.netdev;

	return device ? netdev_for_device(device) : null;
}
