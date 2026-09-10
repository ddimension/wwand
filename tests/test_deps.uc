// wwand tests — the dependency object the daemon is built with (deps.uc).
//
// These are the only functions in the tree that edit a user's
// /etc/config/network on the daemon's own initiative, and until deps.uc was
// split out of main.uc nothing could reach them: they sat 470 lines inside a
// function that also opens the ubus connection and enters the uloop, and each
// made its own libuci.cursor(). The cursor is injected now, so the rules they
// enforce — above all "never clobber what the user wrote" — can be pinned.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as depsmod from 'wwand/deps.uc';

// a uci stand-in: section -> { option: value }, plus a commit counter so a
// silent write and a written-and-committed one can be told apart
function fake_uci(state) {
	let self = { state: state ?? {}, commits: 0 };

	self.cursor = () => ({
		get: (pkg, section, option) => {
			let s = self.state[section];

			if (s == null)
				return null;

			return (option == null) ? s : (s[option] ?? null);
		},
		set: (pkg, section, option, value) => {
			self.state[section] = self.state[section] ?? {};
			self.state[section][option] = value;
		},
		delete: (pkg, section, option) => {
			if (self.state[section] != null)
				delete self.state[section][option];
		},
		commit: () => { self.commits++; },
	});

	return self;
}

function mkdeps(u, extra) {
	return depsmod.create({
		conn: null, datapath_fx: null, netdev: null, proto: null,
		netifd_cb: () => null, autosetup_mux_id: () => null,
		read_config: () => ({}),
		cursor: u.cursor,
		...(extra ?? {}),
	});
}

// --- learn_identity: record what the modem told us, once --------------------
{
	let u = fake_uci({ m0: {} });
	let d = mkdeps(u);

	d.learn_identity('m0', { imei: '350000000000000', serial: 'abc123' });
	eq(u.state.m0.imei, '350000000000000', 'learn_identity: imei recorded');
	eq(u.state.m0.serial, 'abc123', 'learn_identity: serial recorded alongside');
	eq(u.commits, 1, 'learn_identity: committed once');

	// idempotent — a re-learn on every boot would rewrite flash for nothing
	d.learn_identity('m0', { imei: '350000000000000', serial: 'abc123' });
	eq(u.commits, 1, 'learn_identity: an unchanged imei writes nothing');

	// a serial already on record is not overwritten
	u.state.m0.serial = 'user-set';
	d.learn_identity('m0', { imei: '350000000000001', serial: 'other' });
	eq(u.state.m0.serial, 'user-set', 'learn_identity: an existing serial stands');

	// a section that does not exist is a synthesized compat modem, not a target
	let u2 = fake_uci({});
	mkdeps(u2).learn_identity('ghost', { imei: '350000000000000' });
	eq(u2.commits, 0, 'learn_identity: no section, no write');

	// nothing to learn
	let u3 = fake_uci({ m0: {} });
	mkdeps(u3).learn_identity('m0', {});
	eq(u3.commits, 0, 'learn_identity: no imei, no write');
}

// --- learn_device: user sovereignty -----------------------------------------
{
	let u = fake_uci({ wan: {} });
	let d = mkdeps(u);

	d.learn_device('wan', 'wwand0');
	eq(u.state.wan.device, 'wwand0', 'learn_device: recorded when absent');

	// THE rule of this function: an explicit device is the user's, and a daemon
	// that overwrites it takes the interface away from them
	u.state.wan.device = 'wwan-user';
	u.commits = 0;
	d.learn_device('wan', 'wwand0');
	eq(u.state.wan.device, 'wwan-user', 'learn_device: never clobbers an explicit device');
	eq(u.commits, 0, 'learn_device: ...and writes nothing at all');

	// unchanged -> no churn
	let u2 = fake_uci({ wan: { device: 'wwand0' } });
	mkdeps(u2).learn_device('wan', 'wwand0');
	eq(u2.commits, 0, 'learn_device: an unchanged device writes nothing');

	let u3 = fake_uci({});
	mkdeps(u3).learn_device('ghost', 'wwand0');
	eq(u3.commits, 0, 'learn_device: no section, no write');
}

// --- clear_protocol_pin: only a CONTRADICTING pin goes ----------------------
//
// A pin the driver contradicts disarms hardware recovery for that modem, so a
// successful firmware switch has to drop it — but only then, and only when it
// names something else.
{
	let u = fake_uci({ m0: { protocol: 'qmi' } });
	mkdeps(u).clear_protocol_pin('m0', 'mbim');
	eq(u.state.m0.protocol, null, 'clear_pin: a pin naming the OLD protocol is dropped');
	eq(u.commits, 1, 'clear_pin: committed');

	let u2 = fake_uci({ m0: { protocol: 'mbim' } });
	mkdeps(u2).clear_protocol_pin('m0', 'mbim');
	eq(u2.state.m0.protocol, 'mbim', 'clear_pin: a pin that already agrees is left alone');
	eq(u2.commits, 0, 'clear_pin: ...and nothing is written');

	let u3 = fake_uci({ m0: {} });
	mkdeps(u3).clear_protocol_pin('m0', 'mbim');
	eq(u3.commits, 0, 'clear_pin: no pin, nothing to clear');

	let u4 = fake_uci({ m0: { protocol: 'qmi' } });
	mkdeps(u4).clear_protocol_pin(null, 'mbim');
	eq(u4.commits, 0, 'clear_pin: no section named, no write');
}

// --- learn_modem_path: only a cdc-wdm artifact is replaced ------------------
{
	// a modem already anchored by path has no node artifact to fix
	let u = fake_uci({ m0: { path: '1-1.2' } });
	mkdeps(u).learn_modem_path('m0', '/dev/cdc-wdm0');
	eq(u.commits, 0, 'learn_path: nothing to fix when device is not a cdc-wdm node');

	// a non-USB control node has no resolvable sysfs path
	let u2 = fake_uci({ m0: { device: '/dev/cdc-wdm0' } });
	mkdeps(u2).learn_modem_path('m0', '/dev/wwan0mbim0');
	eq(u2.commits, 0, 'learn_path: a non cdc-wdm control node is left alone');
}

done('test_deps');
