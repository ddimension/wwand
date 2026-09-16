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

			// libuci's THREE-argument form creates a section of that type
			// (`cursor.set('network', 'wan_6', 'interface')`). Modelling it as
			// an option named `interface` made a freshly created section
			// invisible to the next foreach — so a second ensure_wan6() looked
			// like a first one, and a test could not see a spurious re-create.
			if (value == null)
				self.state[section]['.type'] = option;
			else
				self.state[section][option] = value;
		},
		delete: (pkg, section, option) => {
			if (self.state[section] != null)
				delete self.state[section][option];
		},
		commit: () => { self.commits++; },
		// ensure_wan6 walks firewall zones and network interfaces
		foreach: (pkg, stype, fn) => {
			for (let k, v in self.state) {
				if ((v['.type'] ?? '') != stype)
					continue;

				if (fn({ ...v, '.name': k }) === false)
					return;
			}
		},
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

// --- ensure_wan6: `sourcefilter 0` must reach the subinterface too -----------
//
// On this model the v6 default route does not come from the shim at all — it
// comes from the modem's RA through odhcp6c on the `<parent>_6` subinterface.
// odhcp6c source-restricts those routes unless told otherwise (dhcpv6.sh:207
// exports NOSOURCEFILTER=1, dhcpv6.script:119 then adds them without a source),
// and wwand read the option in the shim and stopped there. So the option could
// look applied on the parent while doing nothing for the half that installs the
// default route on this model. uqmi hands it down (qmi.sh:478).
{
	let conn = { defer: (o, m, a, cb) => (cb ? cb() : null) };

	// fresh subinterface: the option is part of the section it creates
	let u = fake_uci({ wan: { '.type': 'interface', proto: 'wwand', sourcefilter: '0' } });
	let d = mkdeps(u, { conn: conn, netifd_cb: () => (() => null) });

	d.ensure_wan6('wan', 'ipv4v6');

	eq(u.state.wan_6?.sourcefilter, '0', 'wan6: sourcefilter 0 is inherited onto a new subinterface');
	eq(u.state.wan_6?.extendprefix, '1', 'wan6: ...alongside extendprefix, which it must not displace');
	eq(u.commits, 1, 'wan6: creating the subinterface commits once');

	// AND ONLY ONCE. Without this the whole branch could commit unconditionally
	// and every assertion above would still pass — a write to a user's
	// /etc/config/network on every context up, invisible to the tests.
	d.ensure_wan6('wan', 'ipv4v6');

	eq(u.commits, 1, 'wan6: a second connect finds the section complete and writes nothing');

	// parent does NOT set it -> nothing is written, odhcp6c keeps its default
	let u2 = fake_uci({ wan: { '.type': 'interface', proto: 'wwand' } });
	let d2 = mkdeps(u2, { conn: conn, netifd_cb: () => (() => null) });

	d2.ensure_wan6('wan', 'ipv4v6');

	eq(u2.state.wan_6?.sourcefilter, null, 'wan6: an unset parent option is not invented');
	eq(u2.commits, 1, 'wan6: ...and the section itself is still created, once');

	// OUR OWN subinterface from an earlier connect: the option is filled in
	let u3 = fake_uci({
		wan:   { '.type': 'interface', proto: 'wwand', sourcefilter: '0' },
		wan_6: { '.type': 'interface', proto: 'dhcpv6', device: '@wan', extendprefix: '1' },
	});
	let d3 = mkdeps(u3, { conn: conn, netifd_cb: () => (() => null) });

	d3.ensure_wan6('wan', 'ipv4v6');

	eq(u3.state.wan_6?.sourcefilter, '0', 'wan6: an existing subinterface of ours is filled in');
	eq(u3.commits, 1, 'wan6: filling in one absent option commits once');

	// ...but an EXPLICIT value there is the operator's, and is never overwritten
	let u4 = fake_uci({
		wan:   { '.type': 'interface', proto: 'wwand', sourcefilter: '0' },
		wan_6: { '.type': 'interface', proto: 'dhcpv6', device: '@wan',
		         extendprefix: '1', sourcefilter: '1' },
	});
	let d4 = mkdeps(u4, { conn: conn, netifd_cb: () => (() => null) });

	d4.ensure_wan6('wan', 'ipv4v6');

	eq(u4.state.wan_6?.sourcefilter, '1', 'wan6: an operator value on the subinterface stands');
	eq(u4.commits, 0, 'wan6: ...and nothing is written at all');

	// a section the USER wrote under their own name is left completely alone
	let u5 = fake_uci({
		wan:  { '.type': 'interface', proto: 'wwand', sourcefilter: '0' },
		mine: { '.type': 'interface', proto: 'dhcpv6', device: '@wan' },
	});
	let d5 = mkdeps(u5, { conn: conn, netifd_cb: () => (() => null) });

	d5.ensure_wan6('wan', 'ipv4v6');

	eq(u5.state.mine?.sourcefilter, null, 'wan6: a user-named subinterface is never edited');
	eq(u5.state.wan_6, null, 'wan6: ...and no second one is created beside it');
	eq(u5.commits, 0, 'wan6: ...and nothing is committed on its behalf');

	// BOTH LIBUCI SPELLINGS OF FALSE, AND NOTHING ELSE. netifd converts this
	// option with libuci, which takes exactly "false"/"0" and REJECTS anything
	// else — a rejected value is dropped and never reaches the shim at all
	// (uci/blob.c:34-40, uci 2025.12.02). So `no`/`off`/`disabled`/`FALSE` do
	// not disable the filter on the parent either, and must not disable it here:
	// honouring them would recreate the split this inheritance exists to close.
	for (let sp in [ '0', 'false' ]) {
		let ux = fake_uci({ wan: { '.type': 'interface', proto: 'wwand', sourcefilter: sp } });
		let dx = mkdeps(ux, { conn: conn, netifd_cb: () => (() => null) });

		dx.ensure_wan6('wan', 'ipv4v6');
		eq(ux.state.wan_6?.sourcefilter, '0',
			sprintf('wan6: `%s` is a spelling libuci accepts, so it is inherited', sp));
	}

	for (let sp in [ 'no', 'off', 'disabled', 'FALSE', '' ]) {
		let ux = fake_uci({ wan: { '.type': 'interface', proto: 'wwand', sourcefilter: sp } });
		let dx = mkdeps(ux, { conn: conn, netifd_cb: () => (() => null) });

		dx.ensure_wan6('wan', 'ipv4v6');
		eq(ux.state.wan_6?.sourcefilter, null,
			sprintf('wan6: `%s` does not disable it on the parent either, so not here', sp));
	}
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
