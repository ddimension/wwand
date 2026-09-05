// wwand tests — the E1820 hotplug binder's two guards.
//
// This script writes to qmi_wwan's `new_id`, and usb_store_new_id() appends a
// dynid without checking for a duplicate (drivers/usb/core/driver.c, 6.18.41:
// kzalloc + list_add_tail, no lookup). So "runs more often than intended" is
// not cosmetic here — it grows a kernel list on every plug event, forever.
//
// Both guards had already been wrong once each, silently, which is why they are
// tested against a sysfs miniature rather than by reading them:
//   - the unbound check was written against /sys/bus/usb/devices/$DEVPATH-ish,
//     a shape that directory never contains, so it matched nothing and the
//     binder ran every time;
//   - there was no device/interface check at all, and usb_uevent() emits
//     PRODUCT for interfaces too (same file), so one plug fired the body once
//     per interface on top of once for the device.
//
// The layout below is faithful to the two properties the guards depend on,
// both HW-checked on a MikroTik Chateau 5G (2026-09-05):
//   - /sys/bus/usb/devices holds FLAT kobject names (`3-1`, `3-1:1.1`), never a
//     $DEVPATH-shaped path;
//   - an interface directory is a CHILD of its device's directory
//     (.../usb3/3-1/3-1:1.1), not a sibling of it.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import { popen, access } from 'fs';

function sh(cmd)
{
	let p = popen(cmd + ' 2>&1', 'r');
	let out = p ? p.read('all') : null;

	if (p)
		p.close();

	return trim(out ?? '');
}

const DEV = '/devices/platform/xhci/usb1/1-1';
const IF1 = DEV + '/1-1:1.1';

let root = sh('mktemp -d');

ok(length(root) > 0, 'fixture: a temp root');

// the miniature, plus the script with its /sys rewritten onto it
sh(sprintf('mkdir -p %s/sys%s %s/sys/bus/usb/devices %s/sys/bus/usb/drivers/qmi_wwan',
	root, IF1, root, root));
sh(sprintf('ln -sf %s/sys%s %s/sys/bus/usb/devices/1-1', root, DEV, root));
sh(sprintf('ln -sf %s/sys%s %s/sys/bus/usb/devices/1-1:1.1', root, IF1, root));
sh(sprintf("sed 's#/sys#%s/sys#g' ../files/wwand.hotplug.e1820 > %s/script.sh", root, root));

// --- the path shapes, stated as checks ---------------------------------------
//
// These are the claims the guard rests on. If a future kernel moves the
// interface or flattens the device tree, THESE fail first and say why, instead
// of the behaviour checks below failing with no explanation.

ok(!access(sprintf('%s/sys/bus/usb/devices%s:1.1', root, DEV)),
	'shape: /sys/bus/usb/devices never holds a $DEVPATH-shaped name (the old bug)');
ok(!access(sprintf('%s/sys%s:1.1', root, DEV)),
	'shape: the interface is not a SIBLING of the device either');
ok(access(sprintf('%s/sys%s/1-1:1.1', root, DEV)),
	'shape: it is a CHILD of the device directory — what the guard must use');

// --- the behaviour -----------------------------------------------------------

const NEW_ID = '/sys/bus/usb/drivers/qmi_wwan/new_id';

// true when the binder ran, i.e. something reached new_id
function fires(action, product, devtype, bound)
{
	sh(sprintf('rm -f %s/sys%s/driver', root, IF1));

	if (bound)
		sh(sprintf('ln -sf %s/sys/bus/usb/drivers/qmi_wwan %s/sys%s/driver', root, root, IF1));

	sh(sprintf(': > %s%s', root, NEW_ID));
	sh(sprintf('ACTION=%s PRODUCT=%s DEVTYPE=%s DEVPATH=%s sh %s/script.sh',
		action, product, devtype, DEV, root));

	return length(sh(sprintf('cat %s%s', root, NEW_ID))) > 0;
}

const E1820 = '12d1/14ac/102';

ok(fires('add', E1820, 'usb_device', false),
	'binds when the E1820 appears with interface 1 unbound — the whole point');

// the reason the device gate exists: PRODUCT is on the interface events too, so
// without it one plug wrote new_id once per interface as well
ok(!fires('add', E1820, 'usb_interface', false),
	'interface events are ignored (PRODUCT is exported on those too)');

// the reason the unbound check exists: re-binding an already-bound interface is
// pointless work, and each attempt leaves another dynid behind
ok(!fires('add', E1820, 'usb_device', true),
	'no second bind once interface 1 already has a driver');

ok(!fires('add', '2c7c/0122/515', 'usb_device', false),
	'another vendor is left alone');
ok(!fires('remove', E1820, 'usb_device', false),
	'only `add` binds');

sh(sprintf('rm -rf %s', root));

done('test_hotplug_e1820');
