// wwand tests — the startup banner's two inputs.
//
// The point of the banner is that a log answers, without anyone asking the
// operator: which build is this, what can it drive, what did it load. So the
// cases that matter are the ones where the honest answer is "I don't know" or
// "nothing" — those are exactly the boxes whose logs get posted.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as version from 'wwand/version.uc';

// --- reading the package database -------------------------------------------

const APK = 'P:base-files\nV:1.2-r1\n\nP:wwand\nV:2026.08.30~199a2f8a-r53\n' +
	'A:aarch64_cortex-a53\n\nP:wwand-qmi\nV:2026.08.30~199a2f8a-r53\n\n' +
	'P:wwandering-unrelated\nV:9\n\nP:kmod-rmnet\nV:6.6-r1\n';

let apk = version.installed('wwand', { read: (p) =>
	(p == '/lib/apk/db/installed') ? APK : null });

eq(apk['wwand'], '2026.08.30~199a2f8a-r53', 'apk: the base package version');
eq(apk['wwand-qmi'], '2026.08.30~199a2f8a-r53', 'apk: a backend package version');
eq(apk['kmod-rmnet'], null, 'apk: packages outside the prefix are skipped');
// the prefix is a prefix, not a word — say so, because it decides what the
// banner reports and "wwandering" is the kind of thing that shows up later
eq(apk['wwandering-unrelated'], '9', 'apk: the prefix matches by prefix, as asked');

const OPKG = 'Package: wwand\nVersion: 1.2.3-4\nStatus: install user installed\n\n' +
	'Package: luci\nVersion: 7\n';

let opkg = version.installed('wwand', { read: (p) =>
	(p == '/usr/lib/opkg/status') ? OPKG : null });

eq(opkg['wwand'], '1.2.3-4', 'opkg: the older status format is read too');
eq(opkg['luci'], null, 'opkg: and filtered the same way');

// no database at all — a source checkout, a container, an image built without a
// package manager. Must be an empty answer, not a crash.
eq(length(keys(version.installed('wwand', { read: () => null }))), 0,
	'no db: an empty answer, not a failure');

// --- the banner --------------------------------------------------------------

let b1 = version.banner({ wwand: '2026.08.30~199a2f8a-r53', 'wwand-qmi': '2026.08.30~199a2f8a-r53' },
	[ 'qmi' ], [ 'rmnet', 'rmnet_nss' ]);

ok(index(b1, 'wwand 2026.08.30~199a2f8a-r53') == 0, 'banner: opens with the version');
ok(index(b1, 'backends: qmi') > 0, 'banner: names the backends');
ok(index(b1, 'qmi (2026') < 0, 'banner: a backend at the base version is not repeated');
ok(index(b1, 'datapath: rmnet, rmnet_nss') > 0, 'banner: names the datapaths');

// a backend at a DIFFERENT release than the base is a real and confusing state
// (it has happened here: base r49 with backends at r28), so it gets said
let b2 = version.banner({ wwand: 'A-r49', 'wwand-qmi': 'A-r28' }, [ 'qmi' ], []);
ok(index(b2, 'qmi (A-r28)') > 0, 'banner: a backend at another version is called out');

// files dropped over an installed package: no database entry for what is
// actually running, so do not borrow a version that describes other files
let b3 = version.banner({}, [ 'qmi' ], []);
ok(index(b3, 'unpackaged') > 0, 'banner: an unpackaged tree says so rather than guessing');

// the base package alone drives nothing — the single most useful thing the
// banner can say on a box whose modem never comes up
let b4 = version.banner({ wwand: 'A-r1' }, [ ], []);
ok(index(b4, 'NONE') > 0, 'banner: no backend installed is stated, not implied');
ok(index(b4, 'wwand-qmi') > 0, 'banner: ...and it says what to install');

done('test_version');
