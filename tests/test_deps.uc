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
// exports NOSOURCEFILTER=1; dhcpv6.script:119 reads it, :138-144 acts on it),
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

	// BOTH defaults absent on an older section of ours. They are peers, filled
	// in one pass and committed once — the case that catches the two fills
	// being turned back into a short-circuiting chain, which the single-option
	// cases above cannot see. (Breaking the extendprefix fill made nothing go
	// red until this existed.)
	let u3b = fake_uci({
		wan:   { '.type': 'interface', proto: 'wwand', sourcefilter: '0' },
		wan_6: { '.type': 'interface', proto: 'dhcpv6', device: '@wan' },
	});
	let d3b = mkdeps(u3b, { conn: conn, netifd_cb: () => (() => null) });

	d3b.ensure_wan6('wan', 'ipv4v6');

	eq(u3b.state.wan_6?.extendprefix, '1',
		'wan6: an existing owned section gets the missing extendprefix');
	eq(u3b.state.wan_6?.sourcefilter, '0', 'wan6: ...and the missing sourcefilter too');
	eq(u3b.commits, 1, 'wan6: ...in one pass, committed once');

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

// --- retire_wan6: the counterpart, and the three ways it must not fire -------
//
// ensure_wan6 persists `<parent>_6` with `auto 1` and never deletes it, so an
// interface that later turns IPv4-only leaves netifd starting a DHCPv6 client
// on a link with no v6 — which reinstates the v6 resolver the v4-only path had
// just suppressed (ddimension/wwand#35, xsetiadi on an FM350-GL, 2026-09-22).
{
	let calls = [];
	let conn = { defer: (o, m, a, cb) => { push(calls, m + ':' + (a?.interface ?? '')); return cb ? cb() : null; } };
	// no array destructuring in ucode ("Expecting variable name") — the pair
	// comes back as an object
	let mk = (st) => {
		calls = [];
		let u = fake_uci(st);
		return { u: u, d: mkdeps(u, { conn: conn, netifd_cb: () => (() => null) }) };
	};
	let ours = () => ({
		wan: { '.type': 'interface', proto: 'wwand' },
		wan_6: { '.type': 'interface', proto: 'dhcpv6', device: '@wan', auto: '1' },
	});

	// the plain case
	let s1 = mk(ours());
	eq(s1.d.retire_wan6('wan'), true, 'retire: a running subinterface is parked');
	eq(s1.u.state.wan_6.auto, '0', 'retire: ...by policy');
	eq(s1.u.state.wan_6.wwand_parked, '1', 'retire: ...marked as ours to un-park');
	eq(s1.u.commits, 1, 'retire: one commit');
	ok(index(calls, 'down:wan_6') >= 0, 'retire: ...and taken down, not merely reconfigured');

	// AND AGAIN. `auto` is boot policy, not runtime state: a second pass must
	// stop writing and logging, but must still issue the down, because someone
	// may have run `ifup wan_6` by hand since.
	let commits_before = s1.u.commits;
	eq(s1.d.retire_wan6('wan'), false, 'retire: a second pass reports nothing new');
	eq(s1.u.commits, commits_before, 'retire: ...and writes nothing');
	ok(index(calls, 'down:wan_6') >= 0, 'retire: ...but still asks for the down');

	// the round trip — the bug that made the first version of this one-way
	let s2 = mk(ours());
	s2.d.retire_wan6('wan');
	s2.d.ensure_wan6('wan', 'ipv4v6');
	eq(s2.u.state.wan_6.auto, '1', 'retire: a v6-capable PDP un-parks the subinterface');
	eq(s2.u.state.wan_6.wwand_parked, null, 'retire: ...and drops the marker with it');

	// AN OPERATOR'S OWN `auto 0` IS NOT OURS TO UNDO. It never acquires the
	// marker, because retire_wan6 only marks what it switches off itself.
	let s3 = mk({
		wan: { '.type': 'interface', proto: 'wwand' },
		wan_6: { '.type': 'interface', proto: 'dhcpv6', device: '@wan', auto: '0' },
	});
	s3.d.retire_wan6('wan');
	eq(s3.u.state.wan_6.wwand_parked, null, 'retire: an operator-disabled section is not marked');
	s3.d.ensure_wan6('wan', 'ipv4v6');
	eq(s3.u.state.wan_6.auto, '0', 'retire: ...and a later v6 PDP leaves their decision alone');

	// shapes that are not ours
	let s4 = mk({
		wan: { '.type': 'interface', proto: 'wwand' },
		wan_6: { '.type': 'interface', proto: 'static', device: '@wan', auto: '1' },
	});
	eq(s4.d.retire_wan6('wan'), false, 'retire: a section that is not a dhcpv6 client is untouched');
	eq(s4.u.state.wan_6.auto, '1', 'retire: ...really untouched');

	let s5 = mk({
		wan: { '.type': 'interface', proto: 'wwand' },
		wan_6: { '.type': 'interface', proto: 'dhcpv6', device: 'eth9', auto: '1' },
	});
	eq(s5.d.retire_wan6('wan'), false, 'retire: a dhcpv6 client on someone else\'s device is untouched');

	let s6 = mk({ wan: { '.type': 'interface', proto: 'wwand' } });
	eq(s6.d.retire_wan6('wan'), false, 'retire: no subinterface, nothing to do');
	eq(s6.u.commits, 0, 'retire: ...and nothing written');

	// A foreign section is declined on EVERY connect, so the explanation for it
	// is stated once per observed shape — this runs in a reconnect loop, and the
	// default log threshold is `info` (log.uc:19), so an unguarded line would
	// flood a box that is already having a bad day. Raised by Codex review,
	// 2026-09-24.
	//
	// WHAT THIS ASSERTS IS NOT THE MEMO. There is no log-capture seam in
	// deps/log, so whether the line is emitted once or three times is not
	// observable from here — and pretending otherwise would be the shape this
	// tree explicitly rejects (tools/check-exports.py: a green test on something
	// it cannot reach). Removing the memo's reset leaves every check below
	// passing, which was verified rather than assumed.
	//
	// What it DOES assert is the property that matters for a memo introduced to
	// gate a log line: that it changed no behaviour. Declines stay declines
	// across repeats, the section stays untouched, a corrected section is still
	// parked by the same deps object, and one that stops being ours is declined
	// again. A memo that broke any of those would be a bug regardless of what it
	// printed.
	let s7 = mk({
		wan: { '.type': 'interface', proto: 'wwand' },
		wan_6: { '.type': 'interface', proto: 'dhcpv6', device: 'eth9', auto: '1' },
	});
	eq(s7.d.retire_wan6('wan'), false, 'retire-memo: a foreign section is declined');
	eq(s7.d.retire_wan6('wan'), false, 'retire-memo: ...and again, unchanged');
	eq(s7.d.retire_wan6('wan'), false, 'retire-memo: ...and again');
	eq(s7.u.state.wan_6.auto, '1', 'retire-memo: still untouched after three passes');
	eq(s7.u.commits, 0, 'retire-memo: and nothing written');

	// ...now the operator corrects the device to ours: the same deps object must
	// park it, not sit on a remembered refusal
	s7.u.state.wan_6.device = '@wan';
	eq(s7.d.retire_wan6('wan'), true,
		'retire-memo: a corrected section is still parked by the same deps object');
	eq(s7.u.state.wan_6.auto, '0', 'retire-memo: ...by policy');
	eq(s7.u.state.wan_6.wwand_parked, '1', 'retire-memo: ...and marked as ours');

	// and back the other way: it is ours no longer, so the refusal is fresh again
	s7.u.state.wan_6.device = 'eth9';
	eq(s7.d.retire_wan6('wan'), false, 'retire-memo: a section that stops being ours is declined again');
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

// --- one port, one reader ----------------------------------------------------
//
// Two `wwand_modem` sections can name the same tty: a stale `option tty`, a
// device that rebound, a copy-pasted section. Opening it twice does not give
// two streams — the kernel hands each read to whichever fd asks first, so BOTH
// readers get torn sentences and each modem is answered with a shredded
// version of the same receiver. Raised by Codex review, 2026-09-21.

(function() {
	let made = [], stopped = [];

	// a gps module stand-in: create() hands back something that remembers its
	// port and reports a start, which is all the rules below look at
	let fake_gps = {
		create: (o) => {
			let r = { path: o.path, running: false, opts: o,
			          start: function() { this.running = true; push(made, this.path); return true; },
			          stop: function() { this.running = false; push(stopped, this.path); },
			          snapshot: () => ({ running: true }) };
			return r;
		},
		status: (modem, snap) => ({ port: modem?.gps_tty, reading: snap != null }),
	};

	let d = depsmod.create({ conn: { defer: () => null }, gps: fake_gps, log: () => null });

	// two modems, DIFFERENT ports: both read
	eq(d.gps_start('m0', '/dev/ttyUSB1', {})?.started, true, 'gps port: the first modem reads');
	eq(d.gps_start('m1', '/dev/ttyUSB2', {})?.started, true, 'gps port: a second modem on its own port reads too');
	eq(made, [ '/dev/ttyUSB1', '/dev/ttyUSB2' ], 'gps port: two readers, two ports');

	// a THIRD modem naming a port that is already being read is refused, and
	// told whose it is
	let clash = d.gps_start('m2', '/dev/ttyUSB1', {});

	eq(clash?.started, false, 'gps port: the same tty is not opened twice');
	eq(clash?.error, 'port_in_use', 'gps port: ...and says why');
	eq(clash?.owner, 'm0', 'gps port: ...and whose it is');
	eq(length(made), 2, 'gps port: nothing was opened for it');

	// the SAME modem registering again on the SAME port changes nothing: a
	// re-open would drop a fix the receiver took minutes to acquire
	let again = d.gps_start('m0', '/dev/ttyUSB1', {});

	eq(again?.unchanged, true, 'gps port: a re-registering modem is left reading');
	eq(length(made), 2, 'gps port: ...and its port is not reopened');

	// the same modem on a DIFFERENT port: the old reader goes first
	stopped = [];
	eq(d.gps_start('m0', '/dev/ttyUSB9', {})?.started, true, 'gps port: a changed port starts a new reader');
	eq(stopped, [ '/dev/ttyUSB1' ], 'gps port: ...and the old one is stopped, not leaked');

	// ...which frees the old tty for the modem that was refused it
	eq(d.gps_start('m2', '/dev/ttyUSB1', {})?.started, true,
		'gps port: the freed tty can now be taken');

	// stopping releases the port for good
	stopped = [];
	eq(d.gps_stop('m2'), true, 'gps stop: a reader can be stopped');
	eq(stopped, [ '/dev/ttyUSB1' ], 'gps stop: ...and it really stops');
	eq(d.gps_snapshot('m2'), null, 'gps stop: ...and answers nothing afterwards');
})();

// THE RECEIVER'S CLOCK REACHES THE REAL set_clock, AND ITS REAL POLICY.
//
// This block used to inject `set_clock` as a property of the deps INPUT and
// assert the epoch arrived there. It did — and production never passed that
// property (main.uc builds deps without it), so `option gnss_set_time` was a
// silent no-op while the test was green. The injection proved the test's own
// wiring and nothing else. Now nothing is injected but the SYSTEM CALL and the
// CLOCK, so the path under test is the shipped one. Raised by Codex review,
// 2026-09-21.

(function() {
	let created = {}, ran = [], fake_now = 1789980000;   // 2026: a sane clock
	let fake_gps = {
		create: (o) => { created[o.path] = o;
		                 return { path: o.path, running: false, opts: o,
		                          start: () => true, stop: () => null, snapshot: () => ({}) }; },
		status: () => ({}),
	};

	let mk = () => depsmod.create({ conn: { defer: () => null }, gps: fake_gps, log: () => null,
	                                run: (cmd) => push(ran, cmd), now: () => fake_now });

	let d = mk();

	d.gps_start('m0', '/dev/ttyUSB1', { adjust_time: false });
	d.gps_start('m1', '/dev/ttyUSB2', { adjust_time: true });

	eq(created['/dev/ttyUSB1'].on_epoch, null,
		'gps clock: a modem that did not ask gets no epoch sink at all');
	eq(type(created['/dev/ttyUSB2'].on_epoch), 'function', 'gps clock: one that did gets one');

	// THE POLICY. The clock is already sane, so the receiver's time is ignored
	// — this is the whole difference from ugps' -a, which steps whenever it
	// differs by five seconds and so fights sysntpd on any NTP-synced box.
	created['/dev/ttyUSB2'].on_epoch(1789978872);
	eq(ran, [], 'gps clock: a clock that is already set is NOT stepped');

	// ...and on an RTC-less box that booted into 1970 it is
	fake_now = 100;
	created['/dev/ttyUSB2'].on_epoch(1789978872);
	eq(length(ran), 1, 'gps clock: a plainly unset clock IS stepped');
	ok(index(ran[0], 'date -u -s @1789978872') == 0,
		'gps clock: ...with the receiver\'s own epoch, in UTC');

	// the same function the daemon uses for NITZ, so both obey one policy
	ran = [];
	d.set_clock(1789978872, null);
	eq(length(ran), 1, 'gps clock: NITZ goes through the very same set_clock');
})();


// --- recovery_fx: the router-level executor must actually be wired -----------
// The vanished-modem escalation reboots through deps.recovery_fx, and deps never
// passed it on: the reboot rung logged "rebooting" and did nothing on every
// install, which kept an NR7101 without WAN for 37 hours (2026-09-25).
{
	let fx = { run: (argv) => argv };
	let d = mkdeps(fake_uci({}), { datapath_fx: fx });
	ok(d.recovery_fx === fx, 'recovery_fx: deps hands the daemon a command executor');
	eq(type(d.recovery_fx?.run), 'function', 'recovery_fx: ...one that can run a command');
}

done('test_deps');
