// wwand tests — daemon core + ubus API end-to-end against a private ubusd.
//
// Requires WWAND_TEST_UBUS_SOCK (run_tests.sh spawns a dedicated ubusd);
// skips cleanly when no ubusd is available.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as libubus from 'ubus';
import { access } from 'fs';
import * as mockhub from './lib/mockhub.uc';
import * as fakefx from './lib/fakefx.uc';
import * as config from 'wwand/config.uc';
import * as daemon_mod from 'wwand/daemon.uc';
import * as ubus_api from 'wwand/ubus.uc';

let sock = getenv('WWAND_TEST_UBUS_SOCK');

if (!sock || !access(sock)) {
	printf("test_daemon: SKIPPED (no ubusd available)\n");
	exit(0);
}

uloop.init();

const TIMING = {
	sync_retry: 1, settle: 1, sim_settle: 1, card_poll: 1,
	reg_timeout: 500,
	// reconnect backoff paced so only a few attempts fall inside the short hold
	// window below (avoids climbing the recovery ladder during the test)
	backoff_min: 40, backoff_max: 60,
	hold_max_ms: 120,   // short reconnect-hold window for the hold-fallback check
};

const V4_SETTINGS = {
	ipv4: '10.11.12.13', netmask: '255.255.255.248', gateway: '10.11.12.14',
	dns1: '9.9.9.9', dns2: '1.1.1.1', mtu: 1430, ip_family: 4,
};

// what netifd is pretending to have configured (see iface_status below)
let netifd_v4 = null;

function handlers()
{
	return {
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 60 },
			{ service: 2, major: 1, minor: 14 },
			{ service: 3, major: 1, minor: 25 },
		] },
		GET_MODEL: { model: 'RG502Q-EA' },
		GET_REVISION: { revision: 'R11' },
		GET_IDS: { imei: '860000000000001' },
		SET_OPERATING_MODE: {},
		GET_OPERATING_MODE: { mode: 0 },   // online (FCC verify pass-through)
		GET_PIN_STATUS: { pin1: { status: 3, verify_retries: 3, unblock_retries: 10 } },
		GET_MANUFACTURER: { manufacturer: 'Quectel' },
		GET_CAPABILITIES: { capabilities: { max_tx_rate: 262144, max_rx_rate: 4194304,
			data_service_cap: 1, sim_cap: 2, radio_ifs: [ 8 ] } },
		GET_MSISDN: { msisdn: '4915112345678' },
		GET_IMSI: { imsi: '262011234567890' },
		GET_ICCID: { iccid: '89490200001022832490' },
		REGISTER_INDICATIONS: {},
		SET_EVENT_REPORT: {},
		REFRESH_REGISTER_ALL: {},
		GET_SIGNAL_INFO: {},
		GET_CELL_LOCATION_INFO: {},
		GET_SERVING_SYSTEM: {
			serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
			                  selected_network: 1, radio_ifs: [ 8 ] },
			current_plmn: { mcc: 262, mnc: 1, description: 'Testnet' },
		},
		MODIFY_PROFILE: {},
		GET_PROFILE_SETTINGS: { pdp_type: 0, apn: 'web' },
		SET_IP_FAMILY: {},
		// succeeds for the initial connect and the first transient-drop
		// reconnect; fails afterwards so the second drop exercises the
		// bounded-hold fallback (interface eventually driven down).
		START_NETWORK: (args, meta) =>
			(meta.count <= 2) ? { pdh: 4242 } : { __error: 0x0001 },
		// activation returns the base settings; a later refresh (triggered by
		// a serving-system change) returns a changed address -> renew
		// count 1 = the base settings; 2 = a changed address (drives the renew
		// test); 3+ = the SAME address with a DIFFERENT GATEWAY, which is the
		// shape `option ip6ifaceid` makes normal — the address is pinned, the
		// session's nexthop still moves.
		// count 1 = base; 2 = a changed address; 3 = the SAME address with a
		// DIFFERENT GATEWAY (the shape ip6ifaceid makes normal); 4+ = same
		// address AND same gateway, only the DNS moved — netifd would keep the
		// stale resolver if the renew decision looked at addresses alone.
		GET_CURRENT_SETTINGS: (args, meta) =>
			(meta.count <= 1) ? V4_SETTINGS
			                  : { ...V4_SETTINGS, ipv4: '10.11.12.99',
			                      gateway: (meta.count <= 2) ? '10.11.12.14' : '10.11.12.200',
			                      dns1: (meta.count <= 3) ? '9.9.9.9' : '8.8.4.4' },
		STOP_NETWORK: {},
		// the stats sample now fires immediately on connect
		GET_PACKET_STATISTICS: { tx_packets_ok: 0, rx_packets_ok: 0 },
		// bearer tech carrying the session (rat_mask bit 5 = LTE, matching
		// radio_ifs:[8]). Without this handler the context bring-up (get_bearer)
		// died inside the uloop callback and unwound uloop.run() before any
		// deferred ubus reply fired — which is why only the 3 pre-run checks
		// ever executed.
		GET_CURRENT_DATA_BEARER_TECHNOLOGY: {
			current: { network_type: 8, rat_mask: (1 << 5), so_mask: 0 },
		},
		GET_SYSTEM_SELECTION_PREFERENCE: {
			mode_preference: 0x18, roaming_preference: 0xFF,
			lte_band_preference: 524420, usage_preference: 1,
		},
		SET_SYSTEM_SELECTION_PREFERENCE: {},
		GET_CHANNEL_RATES: { rates: { tx_rate: 0, rx_rate: 0, max_tx_rate: 0, max_rx_rate: 0 } },
	};
}

let conn_srv = libubus.connect(sock);
let conn_cli = libubus.connect(sock);

ok(conn_srv != null && conn_cli != null, 'ubus connections established');

let events = [];
let iface_up = false;
// netifd's runtime autostart flag: cleared by `ifdown` and by nothing else (a
// vanished device reads up=false/available=false but autostart=TRUE)
let iface_autostart = true;
let mock = mockhub.create({ handlers: handlers() });
let dpfx = fakefx.create();

let daemon = daemon_mod.create({
	timing: TIMING,
	deps: {
		transport_open: mock.transport_open,
		log: (level, msg) => null,
		emit_event: (type, data) => push(events, { type: type, data: data }),
		kick_interface: (iface) => push(events, { type: 'kick', data: iface }),
		renew_interface: (iface) => push(events, { type: 'renew', data: iface }),
		down_interface: (iface) => push(events, { type: 'down', data: iface }),
		// async: false -> kick, true -> adopt. The address list matters for the
		// idempotence guard in renew_iface: without it every comparison differs
		// and the skip branch is never reached, so a test of that branch would
		// prove nothing. `netifd_v4` is what netifd is pretending to hold.
		iface_status: (iface, cb) => cb({ up: iface_up, autostart: iface_autostart,
			'ipv4-address': netifd_v4 ? [ { address: netifd_v4 } ] : [] }),
		datapath_fx: dpfx,
		// context_up re-reads config from disk on every up: return a version
		// with a changed apn so the refresh path is exercised
		read_config: () => config.parse({
			network: {
				m0: { '.type': 'wwand_modem', device: '/dev/mock0' },
				wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'web2', pdp_type: 'ipv4' },
			},
		}),
		resolve_modem_device: (cfg) => cfg.device,
		resolve_netdev: (cfg, device) => 'wwan0',
		learn_device: (iface, l3) => push(events, { type: 'learn_device', data: { iface: iface, l3: l3 } }),
		learn_modem_path: (section, dev) => push(events, { type: 'learn_modem_path', data: { section: section, dev: dev } }),
	},
});

let parsed = config.parse({
	network: {
		m0: { '.type': 'wwand_modem', device: '/dev/mock0' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'web', pdp_type: 'ipv4' },
	},
});

eq(length(parsed.warnings), 0, 'test config parses clean');

daemon.apply_config(parsed);
ok(ubus_api.publish(conn_srv, daemon, null) != null, 'wwand object published');

let guard = uloop.timer(5000, () => {
	ok(false, 'daemon test timed out');
	uloop.end();
});

// completion sentinel: set true only by the innermost callback. If a future
// missing mock handler makes context bring-up die() inside a uloop callback,
// the exception unwinds uloop.run() before the guard fires and before the
// deferred chain finishes — which would silently drop the check count while
// still reporting "0 failures". Asserting this after the loop turns any such
// silent unwind into a visible failure.
let completed = false;

// context_up is called while the modem is still initializing — this
// exercises the queued-until-ready path.
conn_cli.defer('wwand', 'context_up', { interface: 'wan' }, (code, reply) => {
	eq(code, 0, 'context_up: status ok');
	eq(reply.up, true, 'context_up: reports up');
	eq(reply.context, 'wan', 'context_up: context name');
	eq(reply.interface, 'wan', 'context_up: interface');
	eq(reply.netdev, 'wwand0', 'context_up: netdev (renamed stable L3 name)');
	eq(reply.ipv4.addr, '10.11.12.13', 'context_up: v4 addr');
	eq(reply.ipv4.dns, [ '9.9.9.9', '1.1.1.1' ], 'context_up: v4 dns');
	eq(reply.ipv6, null, 'context_up: no v6 for ipv4 context');
	eq(reply.pushed_mtu, 1430, 'context_up: pushed mtu');
	eq(daemon.contexts.wan.cfg.apn, 'web2', 'context_up: apn refreshed from disk on up');
	ok(dpfx.action_index('link_set wwand0 mtu 1430') >= 0, 'context_up: mtu applied via rtnl layer');

	// A deferred method whose backend answers SYNCHRONOUSLY (argument
	// validation: no such modem) — over the real bus, not a fake request. The
	// reply then happens inside the handler call itself, which is the ordering
	// ubus.defer() has to get right; a request left incomplete here would
	// surface as a ubus timeout rather than this reply.
	conn_cli.defer('wwand', 'modem_reset', { modem: 'nosuch' }, (c1, r1) => {
		eq(c1, 0, 'sync reply: request completes over real ubus');
		eq(r1?.ok, false, 'sync reply: error envelope');
		eq(r1?.error, 'no_such_modem', 'sync reply: validation error passed through');
	});

	// modem_telemetry is the UNPRIVILEGED read: the four numbers the collectd
	// feed needs, and none of the subscriber identifiers status() carries. A
	// ubus ACL cannot filter a result, so anything that leaks in here is
	// readable by `nobody` on every box that installs the shipped ACL
	// (ddimension/wwand#14).
	// modem_esim_profiles is the READ-ONLY twin of modem_esim's `profiles` op.
	// The property that matters is that `op` is not a parameter, so no caller
	// can turn a read-granted method into a delete — rpcd grants a METHOD and
	// cannot look at arguments (openwrt/luci#8917).
	conn_cli.defer('wwand', 'modem_esim_profiles', { modem: 'm0' }, (ce, re) => {
		eq(ce, 0, 'esim-read: the method exists and routes');
		// the esim bridge is reached and reports the missing transport, which is
		// what proves this is wired to the same implementation modem_esim uses
		eq(re?.error, 'esim', 'esim-read: reaches the esim bridge');
		eq(re?.detail?.error, 'no_esim_backend', 'esim-read: ...and it ran the read op');

		// A caller must not be able to smuggle a write op past the argument
		// policy — and the ICCID is deliberately INVALID so the two routes are
		// distinguishable: `delete` rejects it with invalid_argument before it
		// ever reaches a backend, while the hard-coded `profiles` gets as far as
		// no_esim_backend. A valid ICCID would let both end in the same error
		// and prove nothing.
		conn_cli.defer('wwand', 'modem_esim_profiles',
			{ modem: 'm0', op: 'delete', iccid: 'not-an-iccid' }, (cw, rw) => {
			ok(cw != 0 || (rw?.error == 'esim' && rw?.detail?.error == 'no_esim_backend'),
				'esim-read: an op argument is refused or ignored, never honoured');
		});
	});

	conn_cli.defer('wwand', 'modem_telemetry', {}, (ct, tl) => {
		eq(ct, 0, 'telemetry: ok');
		eq(tl.modems.m0.state, 'READY', 'telemetry: carries the state collectd graphs');
		eq(tl.modems.m0.attempts != null, true, 'telemetry: ...and the attempt counter');
		eq(tl.modems.m0.proto_errors != null, true, 'telemetry: ...and the protocol errors');

		// the collectd feed graphs `gauge-connected` per interface out of this —
		// it used to read status() for that, and when this method replaced the
		// call the contexts were not carried over, so the series was silently
		// never emitted. State ONLY: the status context also carries addresses
		// and the interface name, which an unprivileged reader has no business
		// getting from here.
		// `?.` on purpose: a plain tl.contexts.wan THROWS when the field is
		// missing, which aborts the rest of this callback — the suite then
		// reports fewer checks and zero failures, and the counterproof looks
		// like the fix was unnecessary. Ask the question so it can be answered
		// with "no".
		eq(tl?.contexts?.wan, { state: 'CONNECTED' }, 'telemetry: carries the context state');
		eq(length(keys(tl?.contexts?.wan ?? {})), 1, 'telemetry: ...and nothing else about it');

		for (let k in [ 'iccid', 'imsi', 'imei', 'msisdn', 'model', 'serial' ])
			eq(tl.modems.m0[k], null, sprintf('telemetry: no %s — an ACL cannot filter a result', k));

		// and it can be narrowed to one modem
		conn_cli.defer('wwand', 'modem_telemetry', { modem: 'nosuch' }, (cn, tn) => {
			eq(cn, 0, 'telemetry: a filter for an unknown modem is not an error');
			eq(length(keys(tn.modems ?? {})), 0, 'telemetry: ...it just selects nothing');
			eq(length(keys(tn.contexts ?? {})), 0, 'telemetry: ...including its contexts');
		});
	});

	conn_cli.defer('wwand', 'status', {}, (c2, st) => {
		eq(c2, 0, 'status: ok');
		eq(st.modems.m0.state, 'READY', 'status: modem READY');
		eq(st.modems.m0.model, 'RG502Q-EA', 'status: model');
		// the protocol-switch capability must be a MODEL property, not "the
		// modem currently speaks QMI/MBIM" — a UI that gates on the latter
		// offers the switch on hardware whose recipe does not exist
		eq(st.modems.m0.proto_switch, true, 'status: proto_switch true for a known recipe (RG502Q)');
		eq(st.contexts.wan.state, 'CONNECTED', 'status: context CONNECTED');
		eq(st.contexts.wan.interface, 'wan', 'status: interface mapping');
		// the recovery hardware ladder is armed only after a successful
		// exchange with the current protocol (recovery proven gate)
		eq(st.modems.m0.proven, true, 'status: recovery gate proven after connect');

		// In-place model: a settings change and a transient drop NEVER tear the
		// interface down — the daemon reconnects/renews in place. Only an admin
		// context_down (or a permanent loss) drives network.interface down.
		conn_cli.defer('wwand', 'context_settings', { interface: 'wan' }, (cs, rs) => {
			eq(cs, 0, 'context_settings: ok');
			eq(rs.up, true, 'context_settings: up while connected');
			eq(rs.ipv4.addr, '10.11.12.13', 'context_settings: v4 addr');

			let renews0 = length(filter(events, (e) => e.type == 'renew' && e.data == 'wan'));

			// netifd has finished proto setup by now, so it reports the
			// interface UP — up=false with pending=false is what it reports for
			// an interface it is NOT holding, and the renew decision reads that
			// as "kick it, a renew would go nowhere" (netifd ubus.c:829-830,
			// 2026.07.08~6088f7b3). Leaving the fixture at its pre-connect
			// default made the three renew checks below assert against a state
			// netifd never reports at this point.
			iface_up = true;

			// (1) settings change -> in-place renew (no teardown)
			mock.indicate(3, 0xff, 'SERVING_SYSTEM_IND', {
				serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
				                  selected_network: 1, radio_ifs: [ 8 ] },
				current_plmn: { mcc: 262, mnc: 1, description: 'Testnet' },
			});

			uloop.timer(80, () => {
				ok(length(filter(events, (e) => e.type == 'renew' && e.data == 'wan')) > renews0,
					'settings change -> in-place renew');

				// (1b) SAME address, NEW gateway -> must still renew.
				//
				// netifd now holds exactly the address the session has, so the
				// address comparison alone says "nothing to do". But everything
				// netifd gets goes out in ONE update, and the default route in it
				// carries the gateway (and, with sourcefilter on, the address
				// prefix as its source). Skipping here would leave netifd with the
				// previous session's nexthop and its <gw>/128 host route.
				//
				// Rare while every reconnect also changed the address; `option
				// ip6ifaceid` pins the address on purpose and makes this the
				// normal case.
				// the guard only reaches its skip branch when netifd reports the
				// interface UP and holding the same address — both have to be
				// true here or this proves nothing
				netifd_v4 = '10.11.12.99';
				iface_up = true;
				// NOTE this stays true through (2) below, which therefore also
				// runs through the guard's skip branch for the first time — the
				// transient-drop reconnect comes back on the same address, so it
				// is the same situation and the assertion there gets stricter
				// rather than different. Reset in the inner timer.

				let renews_gw = length(filter(events, (e) => e.type == 'renew' && e.data == 'wan'));

				mock.indicate(3, 0xff, 'SERVING_SYSTEM_IND', {
					serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
					                  selected_network: 1, radio_ifs: [ 8 ] },
					current_plmn: { mcc: 262, mnc: 1, description: 'Testnet' },
				});

				uloop.timer(80, () => {
					ok(length(filter(events, (e) => e.type == 'renew' && e.data == 'wan')) > renews_gw,
						'same address but a new gateway -> still renewed');

					// (1c) address AND gateway identical, only the DNS moved.
					// Everything netifd is told rides in one update, so a
					// resolver change has to reach it too — picking a few fields
					// to compare would leave netifd on the old server forever.
					let renews_dns = length(filter(events, (e) => e.type == 'renew' && e.data == 'wan'));

					mock.indicate(3, 0xff, 'SERVING_SYSTEM_IND', {
						serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
						                  selected_network: 1, radio_ifs: [ 8 ] },
						current_plmn: { mcc: 262, mnc: 1, description: 'Testnet' },
					});

					uloop.timer(80, () => {
						ok(length(filter(events, (e) => e.type == 'renew' && e.data == 'wan')) > renews_dns,
							'same address and gateway, changed DNS -> still renewed');

						iface_up = false;
						netifd_v4 = null;
					});
				});

				// (2) transient drop: must NOT down the interface; the daemon
				// reconnects the session and renews again — all in place.
				let downs0  = length(filter(events, (e) => e.type == 'down'));
				let renews1 = length(filter(events, (e) => e.type == 'renew' && e.data == 'wan'));
				mock.indicate(1, 0xff, 'PACKET_SERVICE_STATUS_IND', {
					status: { status: 1, reconfigure: 0 }, call_end_reason: 2, ip_family: 4,
				});

				uloop.timer(150, () => {
					eq(length(filter(events, (e) => e.type == 'down')), downs0,
						'transient drop: interface NOT downed');
					ok(length(filter(events, (e) => e.type == 'renew' && e.data == 'wan')) > renews1,
						'transient drop: reconnected + renewed in place');

					conn_cli.defer('wwand', 'context_status', { interface: 'wan' }, (c4, r4) => {
						eq(r4.state, 'CONNECTED', 'context reconnected after transient drop');

						// (3) hold-fallback: another drop, but reconnection now fails
						// (START_NETWORK errors) — after the bounded hold the daemon
						// gives up and drives the interface down.
						// nothing has marked this interface yet, so the marker asserted
						// after the give-up below can only have come from the hold
						// expiry itself. Raised by Codex review, 2026-09-19.
						eq(daemon._our_downs.wan, null,
							'hold expiry: no our-down marker before the give-up');

						let downs1 = length(filter(events, (e) => e.type == 'down' && e.data == 'wan'));
						mock.indicate(1, 0xff, 'PACKET_SERVICE_STATUS_IND', {
							status: { status: 1, reconfigure: 0 }, call_end_reason: 2, ip_family: 4,
						});

						uloop.timer(320, () => {
							ok(length(filter(events, (e) => e.type == 'down' && e.data == 'wan')) > downs1,
								'reconnect hold expired -> interface downed (bounded blackhole)');

							// wanted is cleared at the daemon-driven down, not only when
							// netifd later calls context_down — so a `registered` in the
							// gap cannot re-kick the interface being torn down.
							eq(daemon.contexts.wan.wanted, false,
								'hold expiry cleared wanted immediately (no re-kick race)');

							// ...but the give-up is marked INVOLUNTARY: context_down
							// re-arms it (reconnect_on_register) so a later `registered`
							// reconnects, unlike an operator ifdown which stays down.
							eq(daemon.contexts.wan._holdexpiry, true,
								'hold expiry marks an involuntary give-up (re-armable)');

							// ...AND THE DOWN IT ISSUES IS MARKED AS OURS. netifd's
							// ubus `down` clears autostart, which the ready path
							// otherwise reads as an operator ifdown and parks the
							// interface for good. reconnect.uc wrote that marker onto
							// the context entry, where it no longer lives — so the
							// give-up path, the one ddimension/wwand#35 actually took,
							// was unmarked for every reader. Raised by Codex review,
							// 2026-09-19.
							ok(daemon._our_downs.wan != null,
								'hold expiry: its down is marked as ours');

							ok(length(filter(events, (e) => e.type == 'kick' && e.data == 'wan')) >= 1,
								'boot-race kick after modem ready');
							let me = filter(events, (e) => e.type == 'wwand.modem');
							ok(length(filter(me, (e) => e.data.event == 'registered')) == 1,
								'modem registered emitted');

							// learn_device: on 'registered' the daemon writes the
							// resolved l3 device name back onto the interface section
							// (here no mux -> the plain netdev). Also exercises the
							// derive_netdev TDZ forward-declaration.
							ok(length(filter(events, (e) => e.type == 'learn_device' &&
								e.data.iface == 'wan' && e.data.l3 == 'wwand0')) >= 1,
								'learn_device: resolved l3 device written back');

							// learn_modem_path: on 'registered' the daemon also offers
							// the modem's control device for cdc-wdm-node -> stable-path
							// self-healing (the dep no-ops unless it's a cdc-wdm artifact).
							ok(length(filter(events, (e) => e.type == 'learn_modem_path' &&
								e.data.section == 'm0')) >= 1,
								'learn_modem_path: called with the modem section on register');

							// (4) adoption path: registration cycles while the
							// interface reports UP -> the daemon adopts in place
							// (retry_activate) instead of kicking netifd.
							// Regression: this closure crashed on an undeclared
							// retry_activate (use-before-declare in ucode).
							iface_up = true;
							let kicks1 = length(filter(events, (e) => e.type == 'kick' && e.data == 'wan'));

							mock.indicate(3, 0xff, 'SERVING_SYSTEM_IND', {
								serving_system: { registration: 0, cs_attach: 2, ps_attach: 2,
								                  selected_network: 1, radio_ifs: [] },
							});

							uloop.timer(50, () => {
								mock.indicate(3, 0xff, 'SERVING_SYSTEM_IND', {
									serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
									                  selected_network: 1, radio_ifs: [ 8 ] },
									current_plmn: { mcc: 262, mnc: 1, description: 'Testnet' },
								});

								uloop.timer(120, () => {
									eq(length(filter(events, (e) => e.type == 'kick' && e.data == 'wan')),
										kicks1, 'adopt: no kick while the interface is up');

									conn_cli.defer('wwand', 'status', {}, (c5, st5) => {
										eq(c5, 0, 'adopt: daemon alive after adopt path');

										// settings editor read path: NAS sys-sel-pref via ubus
										conn_cli.defer('wwand', 'modem_get_settings', { modem: 'm0' }, (c6, s6) => {
											eq(c6, 0, 'settings: call ok');
											eq(s6.ok, true, 'settings: ok flag');
											eq(s6.mode_preference, 0x18, 'settings: mode pref');
											eq(s6.lte_band_preference, 524420, 'settings: lte band mask');
											eq(s6.usage_preference, 1, 'settings: usage pref');
											// 524420 -> bits 2,7,19 -> bands 3,8,20
											eq(s6.lte_bands, [ 3, 8, 20 ], 'settings: band list decoded');

											// write path: whitelisted set, permanent duration
											conn_cli.defer('wwand', 'modem_set_settings',
												{ modem: 'm0', settings: { usage_preference: 2, lte_bands: [ 1, 3, 8 ] } }, (c7, s7) => {
												eq(s7.ok, true, 'set: ok');

												let set = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
												eq(set[length(set) - 1].args.usage_preference, 2, 'set: value reached modem');
												eq(set[length(set) - 1].args.change_duration, 1, 'set: permanent duration');
												// bands 1,3,8 -> bits 0,2,7 -> 0x85. This mock reports no
												// extended LTE band mask, so the legacy TLV is the one sent —
												// never both (a Quectel RG502Q rejects that pair); the
												// extended-modem case is covered in test_netsel.
												eq(set[length(set) - 1].args.lte_band_preference, 133, 'set: band list -> mask');
												eq(set[length(set) - 1].args.ext_lte_band, null, 'set: no extended TLV alongside the legacy one');

												// non-whitelisted key is rejected before the modem
												conn_cli.defer('wwand', 'modem_set_settings',
													{ modem: 'm0', settings: { network_selection: 1 } }, (c8, s8) => {
													eq(s8.ok, false, 'set: unknown key rejected');
													eq(s8.error, 'invalid_setting', 'set: reject reason');

													// this test modem runs the DMS legacy path (no
													// UIM) — plmn lists must fail cleanly
													conn_cli.defer('wwand', 'modem_plmn_lists',
														{ modem: 'm0' }, (c9, s9) => {
														eq(s9.ok, false, 'plmn: no-uim guarded');
														eq(s9.error, 'no_sim_transport', 'plmn: guard reason');

														completed = true;
														guard.cancel();
														uloop.end();
													});
												});
											});
										});
									});
								});
							});
						});
					});
				});
			});
		});
	});
});

uloop.run();
// --- false device-gone recovery ---------------------------------------------
// The transport reports the device gone while it is still on the bus (HW-seen:
// GDSP provider SIM reset on the E392). The 'removed' event must detach the
// modem and enter the waiting state; the presence re-check path (shared with
// hotplug 'add') must then rebuild it.
let entry_m0 = daemon.modems.m0;
ok(entry_m0 != null && entry_m0.modem != null, 'gone: modem bound before the test');
entry_m0.modem._device_gone();
eq(entry_m0.modem, null, 'gone: modem detached on the removed event');
ok(length(entry_m0.control_note ?? '') > 0, 'gone: waiting control_note set');
daemon.hotplug('add', 'mock0');
ok(daemon.modems.m0.modem != null, 'gone: modem rebuilt via the add/presence path');

daemon.shutdown();

ok(completed, 'full deferred-callback chain completed (no silent uloop unwind)');

// --- generic modem_reset chain: GPIO priority, multi-modem gating, backend
// fallback. Uses a bare daemon instance with a fake board + hand-built modem
// entries (no transport needed — the chain never opens the device).
let pulses = [];
let cycles = 0;
let rdeps = {
	log: (level, msg) => null,
	board: {
		profile: { reset_gpio: 'gpio900' },
		reset_pulse: (rg, off) => { push(pulses, rg); return true; },
		power_cycle: (off) => { cycles++; return true; },
	},
};
let rd = daemon_mod.create({ timing: TIMING, deps: rdeps });
let backend_resets = [];
let mk_entry = (cfg, with_reset) => ({
	cfg: cfg,
	modem: with_reset ?
		{ stop: () => null,
		  reset: (cb) => { push(backend_resets, 1); cb(null, { resetting: true }); } } :
		{ stop: () => null },
});

// single modem, no per-modem gpio -> board default GPIO wins over backend
rd.modems = { m0: mk_entry({}, true) };
rd.modem_reset('m0', (err, res) => {
	eq(err, null, 'reset single: no error');
	eq(res.action, 'gpio', 'reset single: board default GPIO used');
});
eq(pulses, [ 'gpio900' ], 'reset single: board reset line pulsed');
eq(length(backend_resets), 0, 'reset single: backend reset not touched');

// two modems, no per-modem gpio -> board default is ambiguous, backend reset
rd.modems = { m0: mk_entry({}, true), m1: mk_entry({}, true) };
rd.modem_reset('m1', (err, res) => {
	eq(err, null, 'reset multi: no error');
	eq(res.action, 'backend', 'reset multi: falls back to backend reset');
});
eq(length(pulses), 1, 'reset multi: board GPIO not pulsed');
eq(length(backend_resets), 1, 'reset multi: backend reset ran');

// two modems, per-modem reset_gpio -> that line is pulsed
rd.modems.m1.cfg = { reset_gpio: 'gpio7' };
rd.modem_reset('m1', (err, res) => {
	eq(res.gpio, 'gpio7', 'reset multi+gpio: per-modem line used');
});
eq(pulses[1], 'gpio7', 'reset multi+gpio: per-modem line pulsed');

// two modems, no gpio, backend without reset -> clean unsupported error
rd.modems = { m0: mk_entry({}, false), m1: mk_entry({}, false) };
rd.modem_reset('m0', (err, res) =>
	eq(err.error, 'unsupported_on_backend', 'reset multi no-backend: clean error'));

// repower: multi-modem without per-modem gpio must NOT power-cycle the shared rail
let rp = rd.repower_modem('m0');
eq(rp.error, 'multi_modem_needs_reset_gpio', 'repower multi: shared rail guarded');
eq(cycles, 0, 'repower multi: power_cycle not fired');

// repower: a named-but-unknown ref must error, never fall back to another
// modem's cfg (a typo'd ref used to pulse the FIRST modem's reset GPIO)
rp = rd.repower_modem('nope');
eq(rp.error, 'no_such_modem', 'repower unknown ref: clean error');
eq(cycles, 0, 'repower unknown ref: nothing pulsed');

// repower: single modem -> power-cycle allowed... but board default GPIO wins first
rd.modems = { m0: mk_entry({}, false) };
rp = rd.repower_modem('m0');
eq(rp.action, 'reset', 'repower single: board reset line preferred');
delete rdeps.board.profile.reset_gpio;
rp = rd.repower_modem('m0');
eq(rp.action, 'power_cycle', 'repower single: falls back to power cycle');
eq(cycles, 1, 'repower single: power_cycle fired');
// THE PLAN MUST MATCH THE ACTION. The status page shows what a repower would do
// on this box for this modem; if that answer came from a second copy of the
// precedence it would drift from the one that fires. repower_modem() is built
// on repower_plan(), so asking is the same as doing — minus the doing.
rdeps.board.profile.reset_gpio = 'gpio900';
rd.modems = { m0: mk_entry({}, false) };
eq(rd.repower_plan('m0').action, 'reset_gpio', 'plan: board reset line, as the action takes');
eq(rd.repower_plan('m0').source, 'board', 'plan: and says whose gpio it is');
rd.modems = { m0: mk_entry({ reset_gpio: 'gpio7' }, false) };
eq(rd.repower_plan('m0').gpio, 'gpio7', 'plan: a per-modem gpio wins');
eq(rd.repower_plan('m0').source, 'modem', 'plan: named as the modem\'s own');

// two modems and no per-modem gpio: the board lines would hit the wrong modem,
// so the hardware rung has nothing to fire — and now says so instead of being
// a silent no-op at the moment it matters
rd.modems = { m0: mk_entry({}, false), m1: mk_entry({}, false) };
eq(rd.repower_plan('m0').action, 'none', 'plan: multi-modem box cannot use board lines');
eq(rd.repower_plan('m0').error, 'multi_modem_needs_reset_gpio',
	'plan: and names why, which is what an operator has to act on');
eq(rd.repower_modem('m0').error, 'multi_modem_needs_reset_gpio',
	'plan: the action agrees with the plan');

rd.shutdown();

// --- the recovery ladder, as status reports it ------------------------------
//
// `attempts` alone is a number. What an operator needs when a box misbehaves is
// which escalations have already fired, what comes next and how far off it is —
// and at the hardware rung, WHICH of the two actions this box would take. The
// numbers come from recovery.rungs() rather than a copy here, so the UI cannot
// still say 8/16/24 after the ladder moves.
(function() {
	let sdeps = { ...rdeps };
	let sd = daemon_mod.create({ timing: TIMING, deps: sdeps });

	sdeps.board.profile.reset_gpio = 'gpio900';
	sd.modems = { m0: { cfg: {}, modem: { stop: () => null,
		counters: { attempts: 17, rung: 2, proto_ok: 1, proto_errors: 0 } } } };

	let st = sd.status();
	let r = st.modems.m0.recovery;

	eq(r.attempts, 17, 'recovery view: attempts carried');
	eq(r.fired, 2, 'recovery view: two rungs have gone off this outage');
	eq(r.armed, true, 'recovery view: armed once the protocol has proven itself');
	// four, not three: the reboot is part of the ladder. Leaving it out made the
	// page say "nothing comes next" while a reboot was still pending — at 25
	// attempts with the default failreboot of 100 there are 76 failures to go.
	eq(length(r.rungs), 4, 'recovery view: the whole ladder is listed, reboot included');

	// WHICH MBIM MESSAGE LAYOUT THIS MODEM'S DECODERS ARE USING. The agreed MS
	// extension version decides it — v1 Base Stations Info has no NR arrays and
	// every pointer after SystemType sits four bytes earlier — and it lived in
	// one log line at open. A reporter comparing wwand's reading against
	// mbimcli's could not see that mbimcli opens v1 unless told otherwise, so
	// the two were reading different structures of the same CID and neither
	// output said so (ddimension/wwand#30, 2026-09-23).
	eq(st.modems.m0.mbimex, null, 'mbimex: a modem with no MBIM client claims no version');

	sd.modems.m0.modem.mbim = { mbimex_version: 0x0300 };
	eq(sd.status().modems.m0.mbimex, '3.0', 'mbimex: the agreed version is reported');

	// 0 is "the handshake was refused", which is NOT the same as 1.0 and must
	// not be printed as a version the modem agreed to
	sd.modems.m0.modem.mbim = { mbimex_version: 0 };
	eq(sd.status().modems.m0.mbimex, null, 'mbimex: a refused handshake is not a version');

	// DELIBERATELY SYNTHETIC: libmbim 1.32.0 defines 1.0, 2.0 and 3.0 and
	// nothing with a non-zero minor. The point here is the extraction, which a
	// 0x0200 case could not distinguish from one that only reads the high
	// byte. Raised by Codex review, 2026-09-23 — worth saying so, because a
	// reader could otherwise take this for evidence that 2.1 exists.
	sd.modems.m0.modem.mbim = { mbimex_version: 0x0201 };
	eq(sd.status().modems.m0.mbimex, '2.1', 'mbimex: both halves of the number survive');
	delete sd.modems.m0.modem.mbim;
	eq(r.rungs[3].action, 'reboot', 'recovery view: and the reboot is last');
	eq(r.rungs[0].fired, true, 'recovery view: opmode cycle already fired');
	eq(r.rungs[2].fired, false, 'recovery view: the hardware rung has not');
	eq(r.next?.action, 'usb_repower', 'recovery view: names what comes next');
	eq(r.next?.at, 24, 'recovery view: and at which attempt count');
	eq(r.next?.in, 7, 'recovery view: and how many attempts away it is');

	// WHAT THE HARDWARE RUNG WOULD ACTUALLY DO on this box, for this modem
	eq(r.hardware?.action, 'reset_gpio', 'recovery view: a reset line, not a power cycle');
	eq(r.hardware?.source, 'board', 'recovery view: and whose line it is');

	// `option failreboot 0` disables ONLY the reboot; the hardware rungs still
	// run, so the ladder shown must shrink by exactly one entry
	sd.modems.m0.cfg = { failreboot: '0' };
	let nr = sd.status().modems.m0.recovery;
	eq(length(nr.rungs), 3, 'recovery view: failreboot 0 drops the reboot rung');
	eq(nr.rungs[2].action, 'usb_repower', 'recovery view: ...and nothing else');
	sd.modems.m0.cfg = {};

	// the ladder is gated until one exchange has succeeded in the selected
	// protocol — a misdetected modem must never be repowered, and the page has
	// to show that rather than promising an escalation that cannot fire
	sd.modems.m0.modem.counters.proto_ok = 0;
	eq(sd.status().modems.m0.recovery.armed, false,
		'recovery view: not armed while the protocol is unproven');

	sd.shutdown();
})();

// --- idempotent reload diff -------------------------------------------------
// apply_config must bounce ONLY what actually changed: an unrelated edit leaves
// every session untouched; a single context's APN change re-applies just that
// context (its modem + siblings keep running); a changed/removed/added modem or
// mux channel is scoped to it. A fake QMI backend (deps.load_qmi) lets
// start_modem/start_context build trackable stand-ins with no transport;
// rl_events records every backend start/stop + context down. Interfaces pin an
// explicit `device` so the auto wwandN numbering can't renumber survivors and
// confound the diff (that stability is itself the point of the pinned names).
let rl_events = [];
let rl_modem_opts = {};   // id -> the opts the modem create() was called with
let fake_qmi = {
	modem: { create: (o) => {
		rl_modem_opts[o.id] = o;
		return {
			start: () => push(rl_events, 'mstart:' + o.id),
			stop:  () => push(rl_events, 'mstop:' + o.id),
		};
	} },
	context: { create: (o) => ({
		state: 'CONNECTED',
		down: (cb) => { push(rl_events, 'cdown:' + o.name); if (cb) cb(); },
	}) },
};
let rld = daemon_mod.create({ timing: TIMING, deps: {
	log: (l, m) => null,
	load_qmi: () => fake_qmi,
} });

let netcfg = (mut) => {
	let net = {
		g:    { '.type': 'wwand_globals' },
		m0:   { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
		m1:   { '.type': 'wwand_modem', device: '/dev/mock1' },
		wanA: { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', pdp_type: 'ipv4' },
		wanB: { '.type': 'interface', proto: 'wwand', modem: 'm1', device: 'l3b', apn: 'b', pdp_type: 'ipv4' },
	};
	if (mut) mut(net);
	return config.parse({ network: net });
};

// initial apply: both modems + both contexts come up
rld.apply_config(netcfg());
eq(sort(keys(rld.modems)), [ 'm0', 'm1' ], 'reload init: both modems present');
eq(sort(keys(rld.contexts)), [ 'wanA', 'wanB' ], 'reload init: both contexts present');
ok(rld.modems.m0.modem != null && rld.contexts.wanA.ctx != null, 'reload init: m0/wanA built');
eq(rl_modem_opts.m0.protocol, 'qmi', 'reload init: an explicit option protocol reaches the modem create');
eq(rl_modem_opts.m1.protocol, 'qmi', 'reload init: the historic qmi default reaches the modem create');

// THE OUR-DOWN MARKERS ARE SWEPT ON RELOAD. They are keyed by interface and
// pruned on read, which only reaches names something still asks about — an
// interface renamed or deleted from the config leaves its key behind with
// nobody left to prune it. Deliberately NOT cleared when a context goes away:
// that is exactly the case the map exists for (an interface whose modem
// stopped resolving loses its entry and must still be recognised when it comes
// back, ddimension/wwand#35). The clock arbitrates, and a reload applies it.
// Raised by Codex review, 2026-09-19.
// ...AND THEY SURVIVE AN INTERFACE LOSING ITS ENTRY ENTIRELY, which is the
// whole reason the marker left the entry. A reload that cannot resolve an
// interface's modem produces no entry for it at all (config.uc warns
// "references unknown modem" and skips it), so the old carry-over had nothing
// to carry from: re-adding the modem built a fresh entry with no marker, the
// poll read netifd's cleared autostart as operator intent, and wwand parked an
// interface IT had taken down. ddimension/wwand#35. Found by a full review,
// 2026-09-19.
rld._our_downs.wanA = time();

rld.apply_config(netcfg((n) => { delete n.m0; }));
eq(index(sort(keys(rld.contexts)), 'wanA'), -1,
	'rebuild: the interface really did lose its entry');
ok(rld._our_downs.wanA != null, 'rebuild: the marker did not go with it');

rld.apply_config(netcfg());
ok(rld.contexts.wanA != null, 'rebuild: and the entry came back when the modem did');
ok(rld._our_downs.wanA != null,
	'rebuild: ...with our own down still recognisable');

delete rld._our_downs.wanA;

rld._our_downs.gone = time() - 10000;   // long past OUR_DOWN_TTL
rld._our_downs.wanA = time();           // fresh

rld.apply_config(netcfg());

eq(rld._our_downs.gone, null, 'sweep: a marker past its TTL is dropped on reload');
ok(rld._our_downs.wanA != null, 'sweep: ...and a fresh one is left alone');

delete rld._our_downs.wanA;

let m0_obj = rld.modems.m0.modem, m1_obj = rld.modems.m1.modem;
let ctxA_obj = rld.contexts.wanA.ctx, ctxB_obj = rld.contexts.wanB.ctx;

// (1) no-op reload: identical config -> zero churn (whole-config fast path)
rl_events = [];
rld.apply_config(netcfg());
eq(rl_events, [], 'reload no-op: nothing stopped or started');
ok(rld.modems.m0.modem == m0_obj, 'reload no-op: m0 modem object identical');
ok(rld.contexts.wanA.ctx == ctxA_obj, 'reload no-op: wanA ctx object identical');

// (2) change ONE context's APN -> only that context re-applies; siblings +
//     both modems keep running untouched (the core win)
rl_events = [];
rld.apply_config(netcfg((n) => { n.wanA.apn = 'a2'; }));
ok(index(rl_events, 'cdown:wanA') >= 0, 'reload apn: changed context taken down');
eq(index(rl_events, 'mstop:m0'), -1, 'reload apn: its modem NOT restarted');
eq(index(rl_events, 'mstop:m1'), -1, 'reload apn: other modem untouched');
eq(index(rl_events, 'cdown:wanB'), -1, 'reload apn: sibling context untouched');
ok(rld.modems.m0.modem == m0_obj, 'reload apn: m0 modem object preserved');
ok(rld.contexts.wanB.ctx == ctxB_obj, 'reload apn: wanB ctx object preserved');
ok(rld.contexts.wanA.ctx != ctxA_obj, 'reload apn: wanA ctx rebuilt with new config');
eq(rld.contexts.wanA.cfg.apn, 'a2', 'reload apn: wanA carries the new APN');
ctxA_obj = rld.contexts.wanA.ctx;

// (3) add a new modem + interface -> only the new one starts; existing untouched
rl_events = [];
rld.apply_config(netcfg((n) => {
	n.wanA.apn = 'a2';
	n.m2 = { '.type': 'wwand_modem', device: '/dev/mock2' };
	n.wanC = { '.type': 'interface', proto: 'wwand', modem: 'm2', device: 'l3c', apn: 'c', pdp_type: 'ipv4' };
}));
ok(index(rl_events, 'mstart:m2') >= 0, 'reload add: new modem started');
eq(index(rl_events, 'mstop:m0'), -1, 'reload add: existing modem m0 untouched');
eq(index(rl_events, 'mstop:m1'), -1, 'reload add: existing modem m1 untouched');
eq(index(rl_events, 'cdown:wanA'), -1, 'reload add: existing context wanA untouched');
ok(rld.contexts.wanA.ctx == ctxA_obj, 'reload add: wanA ctx object preserved');
ok(rld.modems.m1.modem == m1_obj, 'reload add: m1 modem object preserved');

// (4) remove modem m1 + its interface -> only that one is torn down
rl_events = [];
rld.apply_config(netcfg((n) => {
	n.wanA.apn = 'a2';
	n.m2 = { '.type': 'wwand_modem', device: '/dev/mock2' };
	n.wanC = { '.type': 'interface', proto: 'wwand', modem: 'm2', device: 'l3c', apn: 'c', pdp_type: 'ipv4' };
	delete n.m1; delete n.wanB;
}));
ok(index(rl_events, 'mstop:m1') >= 0, 'reload remove: m1 modem stopped');
ok(index(rl_events, 'cdown:wanB') >= 0, 'reload remove: wanB context downed');
ok(!rld.modems.m1, 'reload remove: m1 dropped from the map');
ok(!rld.contexts.wanB, 'reload remove: wanB dropped from the map');
eq(index(rl_events, 'mstop:m0'), -1, 'reload remove: m0 untouched');
ok(rld.contexts.wanA.ctx == ctxA_obj, 'reload remove: wanA ctx preserved');

// (5) add a mux channel on m0 -> m0 rebuilds (datapath changes) and its contexts
//     bounce with it; the unrelated modem m2 + its context stay put
let m2_obj = rld.modems.m2.modem, ctxC_obj = rld.contexts.wanC.ctx;
rl_events = [];
rld.apply_config(netcfg((n) => {
	delete n.m1; delete n.wanB;
	n.wanA.apn = 'a2';
	n.wanA.mux_id = '1';
	n.m2 = { '.type': 'wwand_modem', device: '/dev/mock2' };
	n.wanC = { '.type': 'interface', proto: 'wwand', modem: 'm2', device: 'l3c', apn: 'c', pdp_type: 'ipv4' };
}));
ok(index(rl_events, 'mstop:m0') >= 0 && index(rl_events, 'mstart:m0') >= 0,
	'reload mux: m0 rebuilt for the datapath change');
eq(index(rl_events, 'mstop:m2'), -1, 'reload mux: m2 untouched');
ok(rld.modems.m2.modem == m2_obj, 'reload mux: m2 modem object preserved');
ok(rld.contexts.wanC.ctx == ctxC_obj, 'reload mux: wanC ctx preserved');

rld.shutdown();

// --- sim_refresh: a changed subscription drops the stale session --------------
//
// An eSIM profile switch or a card swap leaves the running context dialled with
// the PREVIOUS subscription's PDP session. The daemon knew — `sim_refresh`
// carries the new identity — and nothing listened, so the data path stayed up
// carrying nothing until somebody pressed Reconnect (patrakov on a Fibocom,
// OpenWrt forum 2026-09-22; the tail of ddimension/wwand#35).
//
// What must NOT happen is equally load-bearing: a re-read of the SAME card, or
// the first read of a modem, must leave a healthy session alone. And the
// mid-dial context must be dropped AND restarted — not skipped, because it may
// already hold a bearer, and not left to the `down` event, because one backend
// does not send one.
(function() {
	let sr_on_event = null;
	let sr_downs = [];

	let sd = daemon_mod.create({
		timing: TIMING,
		deps: {
			transport_open: () => null,
			load_qmi: () => ({
				modem: { create: (o) => {
					sr_on_event = o.deps.on_event;
					return { start: () => null, stop: () => null };
				} },
				context: { create: (o) => ({ state: 'IDLE', up: (cb) => cb?.(null, {}),
				                             down: (cb) => cb?.(), attach: () => null,
				                             detach: () => null }) },
			}),
			log: () => null,
			emit_event: () => null,
			kick_interface: () => null,
			renew_interface: () => null,
			down_interface: () => null,
			iface_status: (iface, cb) => cb({ up: false }),
			datapath_fx: dpfx,
			read_config: () => ({}),
			resolve_modem_device: (cfg) => cfg.device,
			resolve_netdev: () => 'wwan0',
			learn_device: () => null,
			learn_modem_path: () => null,
		},
	});

	sd.apply_config(config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/mock0' },
		m1: { '.type': 'wwand_modem', device: '/dev/mock1' },
		wanA: { '.type': 'interface', proto: 'wwand', modem: 'm0' },
		wanB: { '.type': 'interface', proto: 'wwand', modem: 'm0' },
		wanC: { '.type': 'interface', proto: 'wwand', modem: 'm1' },
	} }));

	// down() goes IDLE, as every real context does — without that the stub
	// would take a second drop for the same session
	let arm = (name, state, wanted) => {
		let c = sd.contexts[name].ctx;
		c.state = state;
		// the retry path reads the modem through the context; REGISTERING is
		// what a modem looks like just after its card was power-cycled, which
		// is exactly when this fires
		c.modem = { state: 'REGISTERING', id: 'm0' };
		c.down = (cb) => { push(sr_downs, name); c.state = 'IDLE'; cb?.(); };
		sd.contexts[name].wanted = wanted ?? true;
	};

	// wanA is carrying traffic; wanB is MID-DIAL, which is not the same as
	// "holds nothing" — MBIM sets its activated flag before it queries the IP
	// configuration (context_mbim.uc:359-360) and NCM before it reads its own
	// (context_ncm.uc:702). wanC belongs to the other modem.
	arm('wanA', 'CONNECTED');
	arm('wanB', 'ACTIVATING');
	arm('wanC', 'CONNECTED');

	let m0 = { id: 'm0' };

	// the FIRST identity this modem ever reported: there is nothing to compare
	// it against, and a modem coming up must not tear down what it just built
	sr_on_event(m0, 'sim_refresh', { iccid: '8949000000000000001', imsi: '262011111111111' });
	eq(sr_downs, [], 'sim_refresh: the first identity of a modem is not a change');

	// ...and the same card answering again is a re-read, not a swap. Without
	// this the shared reapply tail — which emits on EVERY re-read, unlike the
	// MBIM path that filters — would drop a healthy session on a UIM refresh.
	sr_on_event(m0, 'sim_refresh', { iccid: '8949000000000000001', imsi: '262011111111111' });
	eq(sr_downs, [], 'sim_refresh: a re-read of the same card changes nothing');

	// a different card: every session on that modem belongs to a subscription
	// that is gone, whatever state the context reports
	sr_on_event(m0, 'sim_refresh', { iccid: '8949000000000000002', imsi: '262012222222222' });
	eq(sr_downs, [ 'wanA', 'wanB' ], 'sim_refresh: a changed card drops every wanted session');
	eq(index(sr_downs, 'wanC'), -1, 'sim_refresh: another modem is not touched');

	// AND THE RECONNECT IS ACTUALLY ENTERED. This is the half the earlier
	// version left to an event that one backend does not send:
	// context_ncm.down() emits nothing when the activation had not set
	// `activated` yet (context_ncm.uc:823-826), so a mid-dial NCM context
	// would have been left IDLE and wanted with nothing scheduled.
	ok(sd.contexts.wanA.hold_timer != null, 'sim_refresh: the dropped session enters reconnect');
	ok(sd.contexts.wanB.hold_timer != null, 'sim_refresh: ...including the one that emitted no down event');
	eq(sd.contexts.wanC.hold_timer, null, 'sim_refresh: and the untouched modem is left alone');

	// a context nobody asked for has nothing to re-establish
	sd.contexts.wanA.wanted = false;
	sd.contexts.wanA.ctx.state = 'CONNECTED';
	let n = length(sr_downs);
	sr_on_event(m0, 'sim_refresh', { iccid: '8949000000000000003', imsi: '262013333333333' });
	eq(index(slice(sr_downs, n), 'wanA'), -1, 'sim_refresh: an unwanted context is not dropped');

	// the newest identity is the baseline, so a re-read of IT is quiet again
	let m = length(sr_downs);
	sr_on_event(m0, 'sim_refresh', { iccid: '8949000000000000003', imsi: '262013333333333' });
	eq(length(sr_downs), m, 'sim_refresh: the new card becomes the baseline');

	// A SECOND RETRY CHAIN IS A REAL STATE, not a hypothetical. schedule()
	// assigned over entry.retry_timer, and a dropped uloop handle still fires —
	// so anything calling retry_activate while a retry was already pending left
	// two chains walking one entry, both incrementing retry_n and both calling
	// ctx.up(). The modem-ready and adoption paths call it directly
	// (daemon.uc:484,:556) and this handler is a third.
	let ups = 0;
	let rc = sd.contexts.wanC.ctx;

	rc.state = 'IDLE';
	rc.modem = { state: 'READY', id: 'm1' };
	rc.up = (cb) => { ups++; cb?.({ error: 'no-service' }); };
	sd.contexts.wanC.wanted = true;

	sd._retry_activate('wanC');          // one chain, retry scheduled, no hold
	sd._retry_activate('wanC');          // ...and a second caller lands on it

	uloop.timer(300, () => {
		// The separation is structural, not a lucky measurement: with
		// backoff_min 40 the shortest possible spacing is 40 ms, so ONE chain
		// cannot exceed 300/40 = 8 attempts in the window however fast the
		// host is, while two chains share one entry and roughly double it.
		// Measured here: 7 with the fix, 11-12 without. The bound sits at 9 —
		// above the ceiling for one chain, below the floor for two. Setting it
		// on the measured 7 would pass here and flake on a slower machine,
		// which is a worse test than none.
		ok(ups > 0, 'retry: the chain is running at all');
		ok(ups <= 9, sprintf('retry: one chain, not two (%d attempts in 300 ms)', ups));

		sd.shutdown();
	});
})();

// --- a re-enumerating modem is not a PPP-only device ------------------------
//
// A device coming back from a reset passes through a state where only its
// serial port has appeared. Reading that as a diagnosis told an NR7101 owner
// his QMI modem "looks like a PPP-only device, which wwand does not support"
// thirty-one seconds after wwand pulsed its reset GPIO — and seventeen seconds
// later the QMI channel answered and it came up normally (MassiPi,
// ddimension/wwand#40, 2026-09-23). `_had_modem` is the distinction: this
// control device was once ours.
(function() {
	let pd_logs = [];
	// m1 answers QMI to begin with, so its `_had_modem` is set the way the
	// daemon sets it — by actually building a modem — rather than by the test
	// reaching in. m0 is serial-only throughout: a genuine PPP stick.
	let m1_proto = 'qmi';

	let pd = daemon_mod.create({
		timing: TIMING,
		deps: {
			transport_open: () => null,
			load_qmi: () => ({
				modem: { create: () => ({ start: () => null, stop: () => null }) },
				context: { create: () => ({ state: 'IDLE', up: (cb) => cb?.(null, {}),
				                            down: (cb) => cb?.(), attach: () => null,
				                            detach: () => null }) },
			}),
			log: (l, m) => push(pd_logs, m),
			emit_event: () => null,
			kick_interface: () => null, renew_interface: () => null,
			down_interface: () => null,
			iface_status: (iface, cb) => cb({ up: false }),
			datapath_fx: dpfx,
			read_config: () => ({}),
			resolve_control: (cfg) => (cfg.device == '/dev/mock1')
				? (m1_proto == 'qmi'
					? { protocol: 'qmi', device: '/dev/mock1', tty: null, netdev: null }
					: m1_proto == 'gone'
					? { protocol: 'ppp', device: null, tty: null, netdev: null }
					: { protocol: 'ppp', device: null, tty: '/dev/ttyUSB2', netdev: null })
				: { protocol: 'ppp', device: null, tty: '/dev/ttyUSB9', netdev: null },
			resolve_modem_device: (cfg) => cfg.device,
			resolve_netdev: () => 'wwan0',
			learn_device: () => null, learn_modem_path: () => null,
		},
	});

	pd.apply_config(config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/mock0' },
		m1: { '.type': 'wwand_modem', device: '/dev/mock1' },
		wan0: { '.type': 'interface', proto: 'wwand', modem: 'm0' },
		wan1: { '.type': 'interface', proto: 'wwand', modem: 'm1' },
	} }));

	// THE LOG, not the note: apply_config runs start_modem twice and the second
	// pass rebuilds the entry, so the note is a poor witness here.
	let said = (who, what) => length(filter(pd_logs,
		(l) => index(l, sprintf('modem %s:', who)) == 0 && index(l, what) >= 0)) > 0;

	ok(said('m0', 'PPP-only device'),
		'ppp: a modem that never spoke anything else is diagnosed as PPP-only');
	ok(pd.modems.m1._had_modem == true,
		'ppp: ...while driving m1 once is what sets _had_modem');

	// m1's modem is now gone and it comes back showing only its serial port —
	// the half-enumerated state after a reset pulse. hotplug is the real
	// rebuild path for that; a config reload would run stop_modem first and
	// delete the entry, which is not what a re-enumerating device does.
	pd_logs = [];
	m1_proto = 'ppp';
	pd.modems.m1.modem = null;
	pd.hotplug('add', 'cdc-wdm0');

	ok(said('m1', 'has been driven before'),
		'ppp: a modem we have driven is re-enumerating, not a PPP stick');
	ok(!said('m1', '(ppp), no rich control interface'),
		'ppp: ...and is not announced as one');
	ok(said('m0', '(ppp), no rich control interface'),
		'ppp: while the one we never drove is still read as what it presents');

	// ...AND THE WAIT IS BOUNDED. `_had_modem` is about the config entry, not
	// the hardware on the port: swap the QMI stick for a serial one and it
	// still says yes. A device that is STILL serial-only long after the
	// enumeration window is what it presents.
	pd_logs = [];
	pd.modems.m1._ppp_since = time() - 600;
	pd.modems.m1.modem = null;
	pd.hotplug('add', 'cdc-wdm0');

	ok(said('m1', '(ppp), no rich control interface'),
		'ppp: past the settle window it is read as what it presents after all');
	ok(!said('m1', 'has been driven before'),
		'ppp: ...and stops being called a re-enumeration');

	// ...and a spell ENDS when the device leaves, so the next one gets its own
	// window rather than inheriting an expired timestamp.
	pd_logs = [];
	m1_proto = 'gone';
	pd.hotplug('add', 'cdc-wdm0');
	eq(pd.modems.m1._ppp_since, null, 'ppp: a device that leaves ends the serial-only spell');

	m1_proto = 'ppp';
	pd.hotplug('add', 'cdc-wdm0');
	ok(said('m1', 'has been driven before'),
		'ppp: ...so the next re-enumeration is waited on again');

	pd.shutdown();
})();

// --- esim_ready bring-up refresh ---------------------------------------------
// A second, fully stubbed daemon: the modem stub's create() captures the
// on_event binding (the esim_ready handler), and the ubus-facing modem_esim is
// overridden with a fake — the chain under test is the handler itself: the
// 3 s defer, the modem.at gate, the eUICC-active slot filter, the physical
// slot hand-through, and the once-per-object refresh gate.
let ed_on_event = null;
let es_ops = [];

let ed = daemon_mod.create({
	timing: TIMING,
	deps: {
		transport_open: () => null,
		load_qmi: () => ({
			modem: {
				create: (o) => {
					ed_on_event = o.deps.on_event;
					return { start: () => null, stop: () => null };
				},
			},
			context: {
				create: (o) => ({ state: 'IDLE', up: (cb) => cb?.(null, {}),
				                  down: (cb) => cb?.(), attach: () => null, detach: () => null }),
			},
		}),
		log: (level, msg) => null,
		emit_event: (type, data) => null,
		kick_interface: (iface) => null,
		renew_interface: (iface) => null,
		down_interface: (iface) => null,
		iface_status: (iface, cb) => cb({ up: false }),
		datapath_fx: dpfx,
		read_config: () => config.parse({ network: {
			m0: { '.type': 'wwand_modem', device: '/dev/mock0' },
			wan: { '.type': 'interface', proto: 'wwand', modem: 'm0' },
		} }),
		resolve_modem_device: (cfg) => cfg.device,
		resolve_netdev: (cfg, device) => 'wwan0',
		learn_device: (iface, l3) => null,
		learn_modem_path: (section, dev) => null,
	},
});

ed.apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mock0' },
	wan: { '.type': 'interface', proto: 'wwand', modem: 'm0' },
} }));

let es_modem = {
	id: 'm0',
	at: { send: (cmd, cb) => cb(null, { lines: [ 'OK' ] }) },
	slot_status: (cb) => cb(null, [ { physical: 2, active: true, is_euicc: true,
		eid: '89000000000000000000000000000000', iccid: null } ]),
	stop: () => null,   // daemon.shutdown() calls it
};

ed.modems.m0.modem = es_modem;   // swap in the stub after the wiring ran

// override the ubus-facing modem_esim with a recorder — the handler's logic
// (defer/gates/slot) is the unit under test, not the ES10c transport
ed.modem_esim = (ref, op, params, cb) => {
	push(es_ops, { op: op, slot: params?.slot });
	if (op == 'eid')
		return cb(null, { eid: '89000000000000000000000000000000' });
	if (op == 'profiles')
		return cb(null, { profiles: [ { iccid: 'x' } ] });
	cb({ error: 'unexpected_op' });
};

ed_on_event(es_modem, 'esim_ready', { eslots: [] });

uloop.timer(3200, () => {
	eq(length(es_ops), 2, 'esim_ready: eid + profiles ops ran');
	eq(es_ops[0], { op: 'eid', slot: 2 }, 'esim_ready: eid op on the ACTIVE eUICC slot (2, not hardcoded 1)');
	eq(es_ops[1].op, 'profiles', 'esim_ready: profiles op second');
	eq(es_modem.esim_info?.eid, '89000000000000000000000000000000', 'esim_ready: eid read into esim_info');
	eq(length(es_modem.esim_info?.profiles), 1, 'esim_ready: profiles read');

	// once-per-object gate: a second event must not re-run the refresh
	let n = length(es_ops);
	ed_on_event(es_modem, 'esim_ready', { eslots: [] });
	uloop.timer(50, () => {
		eq(length(es_ops), n, 'esim_ready: _esim_refreshed gate — refresh once per object');
		ed.shutdown();
		// the main daemon instance keeps arming its own timers — end the loop
		// explicitly, else this second run never drains
		uloop.end();
	});
});

// --- dhcpv6 subinterface gate -------------------------------------------------
// The RNDIS v6 model applies to EVERY AT-driven NCM datapath: the E3372H on
// huawei_cdc_ncm shows the same kernel_ra addresses on the parent netdev
// (HW-observed 2026-08-30). A context 'up' from such a datapath must trigger
// ensure_wan6 like rndis_host does; a v4-only PDP never qualifies.
let wan6_calls = [];
let w6_on_event = null;

let w6 = daemon_mod.create({
	timing: TIMING,
	deps: {
		load_qmi: () => ({
			modem: { create: (o) => ({
				start: () => null,
				stop: () => null,
				note_connect_success: () => null,
				datapath: { backend: 'huawei_cdc_ncm' },
			}) },
			context: { create: (o) => {
				w6_on_event = o.deps.on_event;
				return {
					state: 'IDLE',
					modem: o.modem,
					config: { pdp_type: o.config.pdp_type },
					up: (cb) => cb?.(null, {}),
					down: (cb) => cb?.(),
					attach: () => null,
					detach: () => null,
				};
			} },
		}),
		log: (level, msg) => null,
		emit_event: (type, data) => null,
		kick_interface: (iface) => null,
		renew_interface: (iface) => null,
		down_interface: (iface) => null,
		iface_status: (iface, cb) => cb({ up: false }),
		ensure_wan6: (parent, pdp) => push(wan6_calls, parent + ':' + pdp),
		datapath_fx: dpfx,
		read_config: () => config.parse({ network: {
			m0: { '.type': 'wwand_modem', device: '/dev/mock0' },
			wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'a', pdp_type: 'ipv4v6' },
		} }),
		resolve_modem_device: (cfg) => cfg.device,
		resolve_netdev: (cfg, device) => 'wwan0',
	},
});

w6.apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mock0' },
	wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'a', pdp_type: 'ipv4v6' },
} }));

ok(w6_on_event != null && w6.contexts.wan.ctx != null, 'wan6 gate: context wired');

// AFTER THE LOOP TURNS, both of them. ensure_wan6 is deferred by a tick and
// confirmed on a second reading (daemon.uc), so the positive case has nothing
// to see yet at this point — and the negative case would report "not called"
// before anything had a chance to call it, which is not the same statement.
w6_on_event(w6.contexts.wan.ctx, 'up', {});

uloop.timer(900, () => {
	ok(index(wan6_calls, 'wan:ipv4v6') >= 0,
		'wan6 gate: huawei_cdc_ncm context up -> dhcpv6 subinterface ensured');

	// v4-only PDP: the same datapath must NOT trigger ensure_wan6
	wan6_calls = [];
	w6.contexts.wan.ctx.config.pdp_type = 'ipv4';
	w6_on_event(w6.contexts.wan.ctx, 'up', {});

	uloop.timer(900, () => {
		eq(length(wan6_calls), 0, 'wan6 gate: a v4-only PDP never qualifies');
		w6.shutdown();
	});
});

uloop.run();
// --- option lowpower: park the radio when nothing on this modem is up --------
// For battery and solar installs. Two things make it dangerous if done naively,
// and both are asserted: it must fire only on an OPERATOR down (a transient
// loss keeps the interface up by design and is exactly when the radio must
// stay on), and only when no OTHER context of the same modem still wants up —
// two interfaces commonly share one modem.
(() => {
	let ops = [];
	let mk = (lp) => {
		let fake = {
			modem: { create: (o) => ({
				id: o.id, state: 'READY', config: o.config,
				start: () => null, stop: () => null,
				// mirrors the real set_opmode: it is the SUCCESSFUL write that
				// records the parked state, and the supervisors read that flag
				set_opmode: function(mode, cb) {
					push(ops, o.id + ':' + mode);
					this.lowpower_parked = (mode == 'low_power');
					cb(null);
				},
			}) },
			context: { create: (o) => ({
				// the real context carries its modem, and activate() reads
				// `ctx.modem.state` before anything else — a fixture without it
				// cannot exercise the bring-up path at all
				state: 'CONNECTED', name: o.name, modem: o.modem,
				down: (cb) => cb ? cb() : null,
			}) },
		};
		let d = daemon_mod.create({ timing: TIMING,
			deps: { log: () => null, load_qmi: () => fake } });
		d.apply_config(config.parse({ network: {
			m0:   { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi',
			        lowpower: lp },
			wanA: { '.type': 'interface', proto: 'wwand', modem: 'm0',
			        device: 'l3a', apn: 'a', pdp_type: 'ipv4' },
			wanB: { '.type': 'interface', proto: 'wwand', modem: 'm0',
			        device: 'l3b', apn: 'b', pdp_type: 'ipv4' },
		} }));
		return d;
	};

	// both interfaces want up; downing one must NOT park the shared radio
	let d = mk('1');
	for (let n, e in d.contexts)
		e.wanted = true;

	ops = [];
	d.context_down('wanA', () => null);
	eq(ops, [ ], 'lowpower: the other interface still wants the modem, radio stays on');

	// now the last one goes down too
	d.context_down('wanB', () => null);
	eq(ops, [ 'm0:low_power' ], 'lowpower: with nothing left up, the radio is parked');

	// ...and an ifup must WAKE it. Parking without a wake path is worse than
	// never parking: the radio is off, so activating would dial a modem that
	// cannot register, and the interface would stay down until something else
	// happened to power the radio back up.
	ops = [];
	d.context_up('wanA', () => null);
	eq(ops[0], 'm0:online', 'lowpower: an ifup on a parked modem wakes the radio first');

	// a modem still coming up must not be parked: its init chain sets the mode
	// online itself, and two writers on one setting is decided by timing
	let d3 = mk('1');
	for (let n, e in d3.contexts)
		e.wanted = true;
	d3.modems.m0.modem.state = 'INIT_SERVICES';

	ops = [];
	d3.context_down('wanA', () => null);
	d3.context_down('wanB', () => null);
	eq(ops, [ ], 'lowpower: a modem that is not READY is left alone');

	// and with the option off, nothing happens at all
	let d2 = mk('0');
	for (let n, e in d2.contexts)
		e.wanted = true;

	ops = [];
	d2.context_down('wanA', () => null);
	d2.context_down('wanB', () => null);
	eq(ops, [ ], 'lowpower: off by default, the radio is never parked');
})();


// --- a firmware protocol switch must not leave a pin that disarms recovery ---
//
// `option protocol` pins which protocol wwand uses to drive a modem. A pin that
// contradicts the driver wwand recognises is NOT inert: recovery.revoke_arming
// withdraws the permission to touch hardware for that modem, persistently. So a
// modem switched from QMI to MBIM while pinned to `qmi` comes back with its
// reset and power-cycle rungs silently disabled, and nothing says why.
//
// Cleared, not rewritten to the target: the option exists for a device wwand
// cannot classify ("leave on detect"), and the reason for the pin — detection
// failing on the OLD protocol — usually does not survive the switch. Raised in
// review on openwrt/luci#8917 (the Tools page carries a second control with the
// same label and issues this switch).
(() => {
	let cleared = [], switched = [];
	let fail = false;

	let fake = {
		modem: { create: (o) => ({
			id: o.id, state: 'READY', config: o.config,
			start: () => null, stop: () => null,
			note_connect_success: () => null, note_connect_failure: () => null,
			switch_protocol: (t, cb) => { push(switched, t); cb(fail ? { error: 'x' } : null, {}); },
		}) },
		context: { create: (o) => ({ state: 'IDLE', config: o.config, modem: o.modem,
					// part of the context contract (context.uc:1040); the
					// daemon tells a bound context when its modem is removed
					modem_event: () => null }) },
	};

	let mk = () => daemon_mod.create({ timing: TIMING, deps: {
		log: () => null, load_qmi: () => fake,
		clear_protocol_pin: (sec, target) => push(cleared, sec + ':' + target),
	} });

	let d = mk();
	d.apply_config(config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
	} }));

	d.modem_set_protocol('m0', 'mbim', () => null);
	eq(switched, [ 'mbim' ], 'setproto: the switch is issued');
	eq(cleared, [ 'm0:mbim' ],
		'setproto: ...and the now-stale pin is cleared, by uci SECTION name');

	// a switch that FAILED leaves the pin alone — it still describes reality
	cleared = []; switched = []; fail = true;
	let d2 = mk();
	d2.apply_config(config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
	} }));
	d2.modem_set_protocol('m0', 'mbim', () => null);

	eq(switched, [ 'mbim' ], 'setproto: the failing switch was attempted');
	eq(cleared, [], 'setproto: a failed switch does not touch the pin');
})();

// --- context_failed: an external prober drives the rungs it cannot reach -----
//
// L3 reachability is measured OUTSIDE (watchcat, mwan3, cron): with policy
// routing in play the source address and table are decided elsewhere, so a
// probe the daemon built itself would fail towards false alarms and tear down
// working sessions. What the daemon owns is the recovery ladder, and nothing
// external can drive it — `ifup` is a no-op on a live no_proto_task interface
// and `context_down` records operator intent, the opposite of what a prober
// means. See ddimension/wwand#13.
(() => {
	let climbed = 0, downs = 0;
	let ctxs = [];
	// the order events actually happen in, so a race between them is visible
	let seq = [];

	let fake = {
		modem: { create: (o) => ({
			id: o.id, state: 'READY', config: o.config,
			start: () => null, stop: () => null,
			note_connect_success: () => null,
			note_connect_failure: (done) => { climbed++; push(seq, 'climb'); done('opmode_cycle'); },
		}) },
		context: { create: (o) => {
			// forward-declared: the object's own `down` references it, and a
			// self-referencing `let` throws "Can't access lexical declaration
			// before initialization" — the ucode TDZ trap, hit here while
			// writing the very test that audits for it
			let c;

			c = { state: 'CONNECTED', name: o.name, modem: o.modem,
			      config: o.config,
			      /* Faithful to every real context (context.uc:757,
			         context_mbim.uc, context_ncm.uc): the 'down' EVENT is emitted
			         BEFORE the callback runs. A fake that only flips state and
			         calls back cannot see an ordering bug, and this one did not —
			         the daemon's own down handler reconnects a still-wanted
			         context, so downing before the ladder climbs raced a redial
			         against the recovery rung. Found by audit, 2026-09-08. */
			      down: (cb) => {
			              downs++;
			              c.state = 'IDLE';
			              push(seq, 'down');
			              o.deps.on_event(c, 'down', { reason: 'admin' });
			              return cb ? cb() : null;
			      },
			      up: (cb) => { push(seq, 'up'); return cb(null); } };
			push(ctxs, c);
			return c;
		} },
	};

	let d = daemon_mod.create({ timing: { ...TIMING, failed_min_gap: 30 },
		deps: { log: () => null, load_qmi: () => fake } });

	d.apply_config(config.parse({ network: {
		m0:  { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0',
		       device: 'l3a', apn: 'a', pdp_type: 'ipv4' },
	} }));

	d.contexts.wan.wanted = true;

	let got = null;
	d.context_failed('wan', 'probe', (err, res) => { got = err ?? res; });

	eq(downs, 1, 'failed: the live session is dropped so the redial is honest');
	eq(climbed, 1, 'failed: ...and it counts against the recovery ladder');
	eq(got.action, 'opmode_cycle', 'failed: the rung the ladder chose is reported back');

	// the ladder picks (and runs) its rung BEFORE anything tears the session
	// down, so no activation can start against a modem that is about to be
	// opmode-cycled, reset or power-cycled
	eq(seq[0], 'climb', 'failed: the rung is chosen before the teardown');
	eq(index(seq, 'down') > index(seq, 'climb'), true,
		'failed: ...and the redial cannot race the recovery it asked for');

	// `wanted` must survive: this is NOT an operator ifdown, and clearing it
	// would park the interface instead of reconnecting it — the exact thing
	// context_down does and this method exists to avoid
	eq(d.contexts.wan.wanted, true, 'failed: the context is still wanted');

	// This drives HARDWARE, so a stuck prober loop must not walk a healthy modem
	// to the reboot rung in a minute. A second call inside the window is refused
	// out loud rather than silently ignored.
	let again = null;
	d.context_failed('wan', 'probe', (err, res) => { again = err ?? res; });

	eq(climbed, 1, 'failed: a second call inside the window does not climb again');
	eq(again.throttled, true, 'failed: ...and the caller is told, not ignored');
	ok(again.retry_in > 0, 'failed: with how long to wait');

	// once the window has passed it counts again
	d.contexts.wan._failed_at -= 100;
	d.context_failed('wan', 'probe', (err, res) => null);
	eq(climbed, 2, 'failed: past the window it climbs once more');

	// The rate limit guards HARDWARE, so it must survive the very thing it
	// guards against causing: a rung that re-enumerates the modem tears the
	// contexts down (detach_modem keeps the entry, clears ctx) and the 30 s
	// retry re-binds them. A rebuild that dropped `_failed_at` reset the limit
	// on every recovery action — so a looping prober climbed the ladder as fast
	// as it could call. Found by audit, 2026-09-08.
	d.contexts.wan._failed_at -= 5;      // still well inside the window
	let stamp = d.contexts.wan._failed_at;

	// `ctx = null` with the entry kept is exactly the state detach_modem leaves
	// behind (daemon.uc: "centry.ctx = null" in the loop over self.contexts),
	// and it is what makes hotplug's rebind loop pick the context up again.
	// Modelled directly because detach_modem is a local, not part of the API.
	d.contexts.wan.ctx = null;
	d.hotplug('add', 'cdc-wdm0');

	ok(d.contexts.wan.ctx != null, 'failed: the context was re-bound');
	eq(d.contexts.wan._failed_at, stamp,
		'failed: the rate limit survives a modem detach + re-bind');

	// ...and so does the marker that says a cleared autostart is OUR doing.
	// Losing it let the next `registered` read our own down as an operator
	// ifdown and park the interface — reachable after a SIM block or a
	// hold-expiry give-up followed by a re-enumeration.
	//
	// It lives OUTSIDE the entry now, keyed by interface, because a reload
	// that cannot resolve an interface's modem produces no entry at all
	// (config.uc "references unknown modem") — and a carry-over has nothing
	// to carry from when there was no previous entry. Found by a full review,
	// 2026-09-19.
	d._our_downs.wan = 4711;
	d.contexts.wan.reconnect_on_register = true;

	d.contexts.wan.ctx = null;
	d.hotplug('add', 'cdc-wdm0');

	eq(d._our_downs.wan, 4711,
		'failed: our-down survives the re-bind, stamp and all');
	eq(d.contexts.wan.reconnect_on_register, true,
		'failed: and so does the give-up re-arm');

	// The limit has to follow a RELOAD. It is the knob an operator raises to
	// contain a prober stuck in a loop, and one that needs a daemon restart to
	// take effect is no use in exactly that moment — the daemon reload path
	// updates hold_max through a setter it has to remember, and this one was
	// not on that list. Read from globals in apply_config instead, which cannot
	// be forgotten. Found by audit, 2026-09-08.
	d.apply_config(config.parse({ network: {
		globals: { '.type': 'wwand_globals', failed_min_gap: '300' },
		m0:  { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0',
		       device: 'l3a', apn: 'a', pdp_type: 'ipv4' },
	} }));

	eq(d.failed_min_gap, 300, 'failed: a reload changes the rate limit');

	d.contexts.wan.wanted = true;
	d.contexts.wan._failed_at = time() - 60;   // past the OLD 30s, inside the new
	climbed = 0;

	let late = null;
	d.context_failed('wan', 'probe', (err, res) => { late = err ?? res; });

	eq(climbed, 0, 'failed: ...and the new value is what the next call is judged by');
	eq(late.throttled, true, 'failed: the caller is told the raised limit applies');

	// an unknown interface is an error, not a silent no-op
    let bad = null;
	d.context_failed('nosuch', 'probe', (err, res) => { bad = err ?? res; });
	eq(bad.error, 'no_such_context', 'failed: an unknown context is refused by name');
})();

// --- the outage state must survive EVERY rebuild, not just the normal one -----
//
// start_modem builds a fresh entry on each hotplug re-add and each 30 s
// waiting-modem retry, and there are THREE places it does so: the two early
// returns (device owned by another stack, control protocol unidentifiable) and
// the normal one. Only the normal one carried the outage markers.
//
// The unknown-protocol return is reachable exactly when it costs most. A device
// that re-appears after the ladder pulsed its reset spends a moment with its
// node present and no driver bound yet — which IS that path — so the rebuild
// --- hotplug 'remove' must enter the vanish state ----------------------------
//
// The remove branch only detached the modem: it set neither control_note nor
// waiting_since nor `vanished`, so the tick's re-check and the vanish
// escalation stayed disarmed and the modem was waited on passively forever. On
// NCM this is the ONLY removal path — no on_gone is wired there — so the
// recovery that the NR7101 incident produced could never fire at all.
//
// And the bound contexts were never told. Dropping `centry.ctx` releases only
// the daemon's HANDLE; the context object lives on with its monitor timers
// armed and its clients alive, polling a hub that was just closed.
// Found by a full review, 2026-09-19.
{
	let ctl = { device: '/dev/cdc-wdm0', protocol: 'qmi',
	            driver: 'qmi_wwan', netdev: 'wwan0' };
	let lost = [];
	let parsed2 = config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/cdc-wdm0' },
		wwan0: { '.type': 'interface', proto: 'wwand', modem: 'm0', apn: 'web' },
	} });

	let d2 = daemon_mod.create({
		timing: { sync_retry: 1, settle: 1, sim_settle: 1, card_poll: 1,
		          reg_timeout: 500, backoff_min: 40, backoff_max: 60 },
		deps: {
			log: () => null,
			load_qmi: () => ({
				// ONE sequence for both objects: the order is the point. A
				// context told AFTER its modem was stopped is told too late —
				// its clients are already talking to a closed hub.
				modem: { create: () => ({ id: 'm0', start: () => null,
					stop: () => { push(lost, 'stop'); },
					note_connect_success: () => null,
					note_connect_failure: () => null, datapath: {} }) },
				context: { create: (o) => ({
					state: 'CONNECTED', config: o.config, modem: o.modem,
					modem_event: (ev) => push(lost, ev),
				}) },
			}),
			emit_event: () => null, kick_interface: () => null,
			renew_interface: () => null, down_interface: () => null,
			iface_status: (i, cb) => cb({ up: false }),
			datapath_fx: null, read_config: () => parsed2,
			resolve_control: () => ctl,
			resolve_netdev: () => null,
			learn_device: () => null, learn_modem_path: () => null,
		},
	});

	d2.apply_config(parsed2);
	d2.modems.m0._had_modem = true;

	ok(d2.modems.m0.modem != null, 'remove: the modem is running before the unplug');

	ctl = null;
	d2.hotplug('remove', 'cdc-wdm0');

	eq(d2.modems.m0.modem, null, 'remove: the modem object is dropped');
	ok(match(d2.modems.m0.control_note ?? '', /waiting for modem/),
		'remove: ...and the wait is REPORTED, not silent');
	ok(d2.modems.m0.waiting_since != null, 'remove: the outage clock starts');
	eq(d2.modems.m0.vanished, true,
		'remove: flagged as a vanish, which is what arms the escalation');
	eq(lost, [ 'lost', 'stop' ],
		'remove: the context is told BEFORE the modem stops, not after');
	eq(d2.contexts.wwan0.ctx, null,
		'remove: ...and the daemon then drops its handle to it');
}


// wiped `_had_modem` and the outage clock, the next tick classified the wait as
// a cold boot, and the reboot rung could never be reached. The reboot rung is
// the one that actually recovered the NR7101. Found by audit, 2026-09-07.
{
	let ctl = null;
	let logs = [];
	let parsed = config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/cdc-wdm0' },
	} });

	let d = daemon_mod.create({
		timing: { sync_retry: 1, settle: 1, sim_settle: 1, card_poll: 1,
		          reg_timeout: 500, backoff_min: 40, backoff_max: 60 },
		deps: {
			log: (lvl, msg) => push(logs, msg),
			load_qmi: () => ({ modem: { create: () => ({ id: 'm', start: () => null,
				stop: () => null, note_connect_success: () => null,
				note_connect_failure: () => null, datapath: {} }) },
				context: { create: (o) => ({ state: 'IDLE', config: o.config, modem: o.modem,
					// part of the context contract (context.uc:1040); the
					// daemon tells a bound context when its modem is removed
					modem_event: () => null }) } }),
			emit_event: () => null, kick_interface: () => null,
			renew_interface: () => null, down_interface: () => null,
			iface_status: (i, cb) => cb({ up: false }),
			datapath_fx: null, read_config: () => parsed,
			resolve_control: () => ctl,
			resolve_netdev: () => null,
			learn_device: () => null, learn_modem_path: () => null,
		},
	});

	// the modem was there and running, then vanished: this is the state the
	// ladder reads
	d.apply_config(parsed);
	d.modems.m0._had_modem = true;
	d.modems.m0.vanished = true;
	d.modems.m0.waiting_since = 111;
	d.modems.m0._vanish_rung = 1;
	// ...and what it had identified itself as, which an NCM modem needs back
	// when it refuses AT+CGMI/CGMM after a re-enumeration (wwand#32)
	d.modems.m0._ident = { manufacturer: 'Fibocom Wireless Inc.', model: 'FM350-GL',
	                       imei: '353165094409590' };

	// it comes back mid-enumeration: the node is there, no driver bound yet.
	// Driven through hotplug, which is how the real retry re-runs start_modem —
	// apply_config short-circuits on an unchanged config signature and would
	// have tested nothing.
	ctl = { device: '/dev/cdc-wdm0', unknown: true, driver: null, protocol: null };
	d.hotplug('add', 'cdc-wdm0');

	ok(match(d.modems.m0.control_note ?? '', /unknown control protocol/),
		'rebuild: the unidentifiable device is reported, not driven');
	eq(d.modems.m0._had_modem, true,
		'rebuild: ...and the unknown-protocol path still knows the modem WAS running');
	eq(d.modems.m0.waiting_since, 111, 'rebuild: the outage clock is not restarted');
	eq(d.modems.m0._vanish_rung, 1, 'rebuild: the rung already climbed is not forgotten');
	eq(d.modems.m0.vanished, true, 'rebuild: still flagged as a vanish, not a cold boot');
	eq(d.modems.m0._ident?.manufacturer, 'Fibocom Wireless Inc.',
		'rebuild: the identity the hardware gave us survives the rebuild');
	eq(d.modems.m0._ident?.imei, '353165094409590',
		'rebuild: ...including the imei that cross-checks it');
}

// --- a modem that vanished must climb the ladder, not wait forever ------------
//
// Measured on a Zyxel NR7101 (2026-09-07): the modem disconnected during
// operation and was still gone 13 hours later, with wwand logging "waiting for
// hotplug" every 30 s and touching nothing. The recovery ladder could not help
// — it hangs off the modem object that detach destroys, and counts CONNECTION
// attempts, of which there are none without a modem.
//
// Both rungs were measured on that board: the reset GPIO does work (line high
// -> USB disconnect in under 5 s, low -> re-enumeration in ~10 s) but did NOT
// revive the modem from that hung state; only a reboot did. So the reset comes
// first and the reboot must stay reachable.
(function() {
	const T = { vanish_reset_after: 120, vanish_reboot_after: 900 };
	let v = (o) => daemon_mod.vanish_action(o, 1000, T);

	// a cold boot is NOT a vanish: `vanished` is set only by modem_removed, and
	// is deliberately not persisted — after a restart we cannot know the modem
	// was ever there, and a boot-time wait must never reboot the router
	eq(v({ waiting_since: 0, _vanish_rung: 0 }), null,
		'vanish: a boot-time wait escalates to nothing');
	// waiting_since must be NONZERO here, or this proves nothing: the guard
	// rejects a falsy timestamp too, so with `waiting_since: 0` the assertion
	// stayed green with the `entry.modem` test removed altogether. Caught by
	// audit (2026-09-07) — a test can agree with the code and still describe
	// nothing, which is the failure mode docs/gotchas.md warns about.
	eq(v({ vanished: true, modem: {}, waiting_since: 50 }), null,
		'vanish: a modem that is back escalates to nothing, however long it was gone');
	eq(v({ vanished: true }), null, 'vanish: no waiting_since, no action');

	// below the first threshold nothing happens — a modem may re-enumerate on
	// its own, and pulsing reset at second one would fight that
	eq(v({ vanished: true, waiting_since: 950 }), null,
		'vanish: 50s gone is too early to touch anything');

	eq(v({ vanished: true, waiting_since: 880 }), 'reset',
		'vanish: past the first threshold -> reset the modem');
	eq(v({ vanished: true, waiting_since: 880, _vanish_rung: 1 }), null,
		'vanish: the reset fires once, not every tick');

	// the expensive rung, and the reason it exists: on that board the reset was
	// not enough
	eq(v({ vanished: true, waiting_since: 50, _vanish_rung: 1 }), 'reboot',
		'vanish: still gone much later -> reboot');
	eq(v({ vanished: true, waiting_since: 50, _vanish_rung: 2 }), null,
		'vanish: and the reboot fires once');

	// `failreboot 0` disables ONLY the reboot — same gate as the ladder's final
	// rung, so a headless box can log forever without restarting under itself
	eq(v({ vanished: true, waiting_since: 50, _vanish_rung: 1, cfg: { failreboot: '0' } }), 'none',
		'vanish: failreboot 0 reaches the rung but declines to reboot');
	eq(v({ vanished: true, waiting_since: 50, _vanish_rung: 1, cfg: { failreboot: '5' } }), 'reboot',
		'vanish: a positive failreboot still reboots');
})();

// `mux_id 'auto'` AND MORE THAN ONE CONTEXT — the case where demoting would be
// the wrong kindness.
//
// One auto channel on a modem that turns out to have no QMAP can safely become
// a plain raw-IP parent: that interface still works. TWO cannot. A raw-IP
// parent carries ONE session, so demoting there would bring interface A up and
// leave B dead with no error naming the reason — the daemon would have chosen
// which of two configured APNs survives. That is a real configuration error
// (two APNs on a modem that cannot mux) and has to be reported as one, so the
// permission to demote is withheld and the datapath fails loudly instead.
let am_opts = {};
let am_qmi = {
	modem: { create: (o) => { am_opts[o.id] = o; return { start: () => null, stop: () => null }; } },
	context: { create: (o) => ({ state: 'IDLE', down: (cb) => cb ? cb() : null }) },
};
let am_daemon = () => daemon_mod.create({ timing: TIMING, deps: {
	log: (l, m) => null,
	load_qmi: () => am_qmi,
} });

am_daemon().apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
	a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', mux_id: 'auto' },
} }));
eq(am_opts.m0?.datapath?.mux_auto, true,
	'automux-demote: a lone auto channel may be given up');
eq(length(am_opts.m0?.datapath?.mux_links ?? []), 1,
	'automux-demote: and one channel is still requested first');

am_opts = {};
am_daemon().apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
	a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', mux_id: 'auto' },
	b:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3b', apn: 'b', mux_id: 'auto' },
} }));
eq(am_opts.m0?.datapath?.mux_auto, false,
	'automux-demote: two contexts — no demotion, one parent cannot carry both');
eq(length(am_opts.m0?.datapath?.mux_links ?? []), 2,
	'automux-demote: both channels are requested');

// MBIM ASKS FOR NO CHANNEL AT ALL in the lone-auto case, where QMI asks for one
// and gives it back if the modem cannot carry it. The difference is the
// hardware: untagged traffic on a cdc_mbim parent already IS IPS session 0
// (cdc_mbim.c:262-270, Linux 6.18.41), so taking a session id buys nothing and
// costs an 802.1q tag on every frame in both directions plus a sub-device to
// route through. QMAP has no session 0 to fall back on, which is why the
// allocator numbers from 1 and why only MBIM can spend that 1.
let am_mbim = {
	modem: { create: (o) => { am_opts[o.id] = o; return { start: () => null, stop: () => null }; } },
	context: { create: (o) => ({ state: 'IDLE', down: (cb) => cb ? cb() : null }) },
};
let am_mbim_daemon = () => daemon_mod.create({ timing: TIMING, deps: {
	log: (l, m) => null,
	load_mbim: () => am_mbim,
	load_qmi: () => am_qmi,
} });

am_opts = {};
am_mbim_daemon().apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'mbim' },
	a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', mux_id: 'auto' },
} }));
eq(length(am_opts.m0?.datapath?.mux_links ?? []), 0,
	'automux-mbim: a lone auto channel asks for no session — untagged on the parent');

// two contexts still need a tag each: one untagged parent carries one session.
am_opts = {};
am_mbim_daemon().apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'mbim' },
	a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', mux_id: 'auto' },
	b:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3b', apn: 'b', mux_id: 'auto' },
} }));
eq(length(am_opts.m0?.datapath?.mux_links ?? []), 2,
	'automux-mbim: two contexts still take a session each');

// ...and a PINNED channel is the operator asking for a tagged session. It is
// not auto, so it is not demotable, and it keeps the number it was given.
am_opts = {};
am_mbim_daemon().apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'mbim' },
	a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', mux_id: '1' },
} }));
eq(length(am_opts.m0?.datapath?.mux_links ?? []), 1,
	'automux-mbim: a pinned session 1 stays a tagged session 1');
eq(am_opts.m0?.datapath?.mux_links?.[0]?.id, 1, 'automux-mbim: ...with its number intact');

// THE PARENT'S NAME FOLLOWS THE SAME DECISION.
//
// A muxed modem leaves its parent on the kernel name because the mux CHILD
// takes the stable wwandN. For a demotable modem that reasoning may turn out to
// be void — no channel is built — and the interface would then sit on `wwan0`.
// An interface whose device name depends on which modem is plugged in is the
// exact instability stable L3 names exist to remove, so a demotable modem is
// named as if unmuxed. If the channel IS built, netlink.setup() moves the
// parent out of the child's way (the displacement it already does for a config
// that switches into muxing).
am_opts = {};
let am1 = am_daemon();
am1.apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
	a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', mux_id: 'auto' },
} }));
// the name the interface pinned: an explicit `option device` is honoured on a
// muxed context too (wwandN is only what wwand suggests when nobody said
// otherwise), and a demotable modem has to answer the same in BOTH outcomes or
// the device name would still move with the modem
eq(am1.modems.m0?.l3_name, 'l3a',
	'automux-name: a demotable modem renames its parent to the pinned name');

am_opts = {};
let am2 = am_daemon();
am2.apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
	a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', mux_id: 'auto' },
	b:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3b', apn: 'b', mux_id: 'auto' },
} }));
eq(am2.modems.m0?.l3_name, false,
	'automux-name: two channels are not demotable, so the children own the naming');

// a pinned channel is never demoted, so the parent keeps its kernel name —
// unchanged from before `auto` existed
am_opts = {};
let am3 = am_daemon();
am3.apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
	a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', mux_id: '1' },
} }));
eq(am3.modems.m0?.l3_name, false,
	'automux-name: a pinned channel leaves the parent on its kernel name');

// ONE READER PER MODEM.
//
// This block used to pin the opposite rule. ugps had a single `config gps`
// section and a single `gps` ubus object, so on a two-modem box only one modem
// could ever have a position, and the daemon had to pick which and tell the
// other one why. wwand reads the NMEA port itself now, so both modems get
// their own reader and neither is told about the other. The arbitration is
// gone because its cause is gone, not because it stopped mattering.
(function() {
	let started = [], stopped = [];
	let hooks = {};
	let fake = {
		modem: { create: (o) => {
			hooks[o.id] = o.deps.on_event;
			return { id: o.id, state: 'READY', config: { gnss: true },
			         gps_tty: sprintf('/dev/ttyUSB%s', substr(o.id, 1)),
			         start: () => null, stop: () => null,
			         note_connect_success: () => null };
		} },
		context: { create: (o) => ({ state: 'IDLE', down: (cb) => cb ? cb() : null,
		                             modem_event: () => null }) },
	};

	let d = daemon_mod.create({ timing: TIMING, deps: {
		log: () => null,
		load_qmi: () => fake,
		gps_start: (ref, port, opts) => { push(started, [ ref, port ]); return { started: true }; },
		gps_stop: (ref) => { push(stopped, ref); return true; },
		gps_snapshot: (ref) => ({ latitude: 52.0 + length(ref), longitude: 8.5, running: true }),
		gps_status: (modem, snap) => ({ modem: modem.id, port: modem.gps_tty,
		                                reading: snap != null, ...(snap ?? {}) }),
	} });

	d.apply_config(config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi', gnss: '1' },
		m1: { '.type': 'wwand_modem', device: '/dev/mock1', protocol: 'qmi', gnss: '1' },
		a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a' },
		b:  { '.type': 'interface', proto: 'wwand', modem: 'm1', device: 'l3b', apn: 'b' },
	} }));

	hooks.m0(d.modems.m0.modem, 'registered', {});
	hooks.m1(d.modems.m1.modem, 'registered', {});

	eq(started, [ [ 'm0', '/dev/ttyUSB0' ], [ 'm1', '/dev/ttyUSB1' ] ],
		'gps: BOTH modems get a reader, on their own port');

	let got0 = null, got1 = null;
	d.modem_gps('m0', (e, r) => { got0 = r; });
	d.modem_gps('m1', (e, r) => { got1 = r; });

	eq(got0?.port, '/dev/ttyUSB0', 'gps: each modem answers with its own port');
	eq(got1?.port, '/dev/ttyUSB1', 'gps: ...and the other with the other');
	eq(got0?.reading, true, 'gps: and with its own reader, not a shared one');
	eq(got1?.reading, true, 'gps: which the second modem has too — it could not before');

	// A MODEM LEAVING STOPS ITS OWN READER and touches no other.
	stopped = [];
	d.apply_config(config.parse({ network: {
		m1: { '.type': 'wwand_modem', device: '/dev/mock1', protocol: 'qmi', gnss: '1' },
		b:  { '.type': 'interface', proto: 'wwand', modem: 'm1', device: 'l3b', apn: 'b' },
	} }));

	eq(stopped, [ 'm0' ], 'gps: dropping a modem stops ITS reader, and only its');

	// THE HARDWARE VANISHING IS THE OTHER WAY A MODEM GOES, and it is a
	// different code path from a config reload — only the second had the
	// release. A device that disappears would otherwise hold its port open for
	// the life of the daemon.
	stopped = [];
	hooks.m1(d.modems.m1.modem, 'removed', {});
	eq(stopped, [ 'm1' ], 'gps: a vanished device releases its port too');
})();

// NO wwand-gps INSTALLED is an answer, not a crash.
(function() {
	let fake = {
		modem: { create: (o) => ({ id: o.id, state: 'READY', config: { gnss: true },
		                           gps_tty: '/dev/ttyUSB3', start: () => null, stop: () => null }) },
		context: { create: (o) => ({ state: 'IDLE', down: (cb) => cb ? cb() : null }) },
	};

	// gps_status returns null exactly when wwand.gps could not be loaded
	let d = daemon_mod.create({ timing: TIMING, deps: {
		log: () => null, load_qmi: () => fake,
		gps_status: () => null, gps_snapshot: () => null,
	} });

	d.apply_config(config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi', gnss: '1' },
		a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a' },
	} }));

	let got = null;
	d.modem_gps('m0', (e, r) => { got = e ?? r; });

	eq(got?.error, 'package_not_installed', 'gps: a missing wwand-gps says so');
})();


// A CONTROL NOTE THE BACKEND SET HAS TO REACH STATUS.
//
// `control_note` exists on two objects: the daemon's modem entry (package not
// installed, device owned by another interface) and the modem the backend
// built. Only the first was ever published, so modem_mbim's "radio disabled by
// the hardware switch" existed and nobody could see it — and status/LuCI is the
// only place that note matters. Raised by Codex review, 2026-09-20.
(function() {
	let made = null;
	let fake = {
		modem: { create: (o) => { made = { id: o.id, state: 'READY', config: o.config,
		                                   start: () => null, stop: () => null }; return made; } },
		context: { create: (o) => ({ state: 'IDLE', down: (cb) => cb ? cb() : null }) },
	};
	let d = daemon_mod.create({ timing: TIMING, deps: { log: () => null, load_qmi: () => fake } });

	d.apply_config(config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
		a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a' },
	} }));

	eq(d.status().modems.m0.control_note, null, 'control note: none to start with');

	made.control_note = 'radio disabled by the hardware switch';
	eq(d.status().modems.m0.control_note, 'radio disabled by the hardware switch',
		'control note: a backend note reaches status');

	// ...and a daemon-level note still wins, because it describes a modem that
	// is not running at all — there is then no backend worth quoting.
	d.modems.m0.control_note = 'wwand-qmi package not installed';
	eq(d.status().modems.m0.control_note, 'wwand-qmi package not installed',
		'control note: the daemon-level note takes precedence');
})();

// A DEMOTABLE MODEM WHOSE NAME IS ALREADY TAKEN IS NOT AN ERROR.
//
// The stable name is asked for up front because the auto channel may turn out
// not to exist. When it DOES exist, the mux child takes that name and the
// parent keeping its kernel name is the correct outcome — so the rename losing
// the race is one of two expected results, not a failure. Reported at error
// level it meant a healthy muxed modem logged a daemon.err on every start
// (HW-observed on an NR7101, 2026-09-11: "cannot rename netdev wwan0 to
// wwand0: name already in use", once per restart, with the datapath up and
// QMAP v5 negotiated).
(function() {
	let lines = [];
	let fx = {
		link_set: (dev, o) => true,
		exists: (p) => true,          // the wanted name is always taken
	};
	let d = daemon_mod.create({ timing: TIMING, deps: {
		log: (l, m) => push(lines, l + ':' + m),
		datapath_fx: fx,
		resolve_netdev: (cfg, dev) => 'wwan0',
		load_qmi: () => am_qmi,
	} });

	d.apply_config(config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
		a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', mux_id: 'auto' },
	} }));

	let errs = filter(lines, (l) => index(l, 'err:') == 0 && index(l, 'rename') >= 0);
	eq(length(errs), 0, 'rename-taken: a demotable modem does not log an error');

	let notes = filter(lines, (l) => index(l, 'is taken') >= 0);
	eq(length(notes), 1, 'rename-taken: it says the mux child has the name');

	// ...and a modem that is NOT demotable still reports a real conflict
	lines = [];
	let d2 = daemon_mod.create({ timing: TIMING, deps: {
		log: (l, m) => push(lines, l + ':' + m),
		datapath_fx: fx,
		resolve_netdev: (cfg, dev) => 'wwan0',
		load_qmi: () => am_qmi,
	} });

	d2.apply_config(config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
		a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a' },
	} }));

	ok(length(filter(lines, (l) => index(l, 'err:') == 0 && index(l, 'cannot rename') >= 0)) == 1,
		'rename-taken: an unmuxed modem still reports the clash as an error');
})();

// ...BUT AN MBIM MODEM THAT ALREADY KNOWS IT WILL RUN UNTAGGED TAKES THE NAME
// BACK, because there is not going to be a mux child.
//
// Coming from a tagged config the old vlan child still holds the stable name at
// this moment; setup() prunes it a second later, after the rename has been
// skipped, and nothing retries. The parent then keeps a raw kernel name that
// depends on USB enumeration order — the instability stable names exist to
// remove — and the next unchanged reload is a no-op, so it stays. HW-reproduced
// on the GL-X3000/RM520N (2026-09-20).
//
// Deleting a network device on a name match alone is not something to get
// wrong, so ownership is PROVEN, not assumed: stacked on this parent, DEVTYPE
// vlan, and the VLAN id this modem's own config asked for.
(function() {
	let mk = (files, deleted) => {
		let lines = [];
		let renamed = [];
		let d = daemon_mod.create({ timing: TIMING, deps: {
			log: (l, m) => push(lines, l + ':' + m),
			datapath_fx: {
				// the name is taken until the device is deleted — the whole
				// point of the reclaim is what happens after that
				exists: (p) => (p == '/sys/class/net/l3a')
					? !length(filter(deleted, (x) => x == 'l3a'))
					: exists(files, p),
				read: (p) => files[p],
				link_del: (dev) => { push(deleted, dev); return true; },
				link_set: (dev, o) => { push(renamed, dev + '->' + (o.rename ?? '')); return true; },
			},
			resolve_netdev: (cfg, dev) => 'wwan1',
			load_mbim: () => am_qmi,
			load_qmi: () => am_qmi,
		} });

		d.apply_config(config.parse({ network: {
			m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'mbim' },
			a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', mux_id: 'auto' },
		} }));

		return { lines: lines, renamed: renamed };
	};

	// our own leftover: stacked on wwan1, a vlan, VID 1 (the channel the
	// allocator handed this modem's lone auto context)
	let mine = {};
	mine['/sys/class/net/l3a/lower_wwan1'] = '';
	mine['/sys/class/net/l3a/uevent'] = 'DEVTYPE=vlan\nINTERFACE=l3a\n';
	mine['/proc/net/vlan/l3a'] = 'l3a  VID: 1\t REORDER_HDR: 1  dev->priv_flags: 81021\n';

	let del1 = [];
	let r1 = mk(mine, del1);
	eq(del1, [ 'l3a' ], 'reclaim: our own leftover vlan child is removed');
	eq(r1.renamed, [ 'wwan1->l3a' ], 'reclaim: ...and the parent then takes the name');
	ok(length(filter(r1.lines, (l) => index(l, 'netifd still holds a device record') >= 0)) == 1,
		'reclaim: ...and the operator is told netifd needs a restart, not a reload');

	// NOT ours: same name, same parent, but a macvlan. An operator's own device
	// on this modem is not wwand's to delete.
	let foreign = { ...mine };
	foreign['/sys/class/net/l3a/uevent'] = 'DEVTYPE=macvlan\nINTERFACE=l3a\n';
	delete foreign['/proc/net/vlan/l3a'];

	let del2 = [];
	let r2 = mk(foreign, del2);
	eq(del2, [], 'reclaim: a macvlan of the same name is left alone');
	eq(r2.renamed, [], 'reclaim: ...and the parent keeps its kernel name');

	// NOT ours: a vlan on this parent carrying a DIFFERENT session id
	let othervid = { ...mine };
	othervid['/proc/net/vlan/l3a'] = 'l3a  VID: 7\t REORDER_HDR: 1\n';

	let del3 = [];
	mk(othervid, del3);
	eq(del3, [], 'reclaim: a vlan with another session id is left alone');

	// NOT ours: a vlan of that name stacked on somebody else's parent
	let elsewhere = { ...mine };
	delete elsewhere['/sys/class/net/l3a/lower_wwan1'];
	elsewhere['/sys/class/net/l3a/lower_eth0'] = '';

	let del4 = [];
	mk(elsewhere, del4);
	eq(del4, [], 'reclaim: a vlan on another parent is left alone');
})();

// ...and a pinned channel beside an auto one is not demotable either: the
// modem needs QMAP for the pinned one regardless.
am_opts = {};
am_daemon().apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
	a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a', mux_id: 'auto' },
	b:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3b', apn: 'b', mux_id: '4' },
} }));
eq(am_opts.m0?.datapath?.mux_auto, false,
	'automux-demote: a pinned sibling keeps the modem on the muxed path');

// --- netifd holds the interface down while the session is connected ---------
// The renew the daemon sends into that is thrown away: interface_renew()
// returns -1 for IFS_DOWN and IFS_TEARDOWN before it ever reaches the proto
// handler (netifd interface.c:1380-1386, 2026.07.08~6088f7b3), and our renew is
// fire-and-forget, so nothing says so. The interface then stays down with a
// CONNECTED context behind it — for as long as the modem stays registered,
// because the path that kicks needs a MODEM transition to fire and a modem that
// never moved never gives one.
//
// This is deliberately NOT part of the big integration chain above. Driving it
// there means going through the monitor's settings refresh, which holds a
// ten-second cooldown (context_monitor_qmi.uc, REFRESH_MIN_MS) and a reconnect
// gated by `failed_min_gap` — so the test would be measuring timers. Here the
// context event is handed to the daemon directly and the decision is all that
// is left.
(() => {
	let calls = [];
	let netifd = { up: false, autostart: true, pending: false,
	               'ipv4-address': [ { address: '10.11.12.99' } ] };
	let on_event;
	let deferred = false, parked = [];
	let answer = () => { let q = parked; parked = []; for (let cb in q) cb(netifd); };

	let fake = {
		modem: { create: (o) => ({ id: o.id, state: 'READY', config: o.config,
		                           start: () => null, stop: () => null,
		                           note_connect_success: () => null }) },
		context: { create: (o) => {
			on_event = o.deps.on_event;

			let ctx = { state: 'CONNECTED', name: o.name, modem: o.modem,
			            settings: { ipv4: { addr: '10.11.12.99' } },
			            down: (cb) => cb ? cb() : null };
			return ctx;
		} },
	};

	let d = daemon_mod.create({ timing: TIMING, deps: {
		log: () => null,
		load_qmi: () => fake,
		kick_interface:  (i) => push(calls, 'kick:'  + i),
		renew_interface: (i) => push(calls, 'renew:' + i),
		down_interface:  (i) => push(calls, 'down:'  + i),
		// synchronous by default; `deferred` parks the callback so a test can
		// run code BETWEEN the probe going out and its answer coming back —
		// which is what the shipped dep does (a deferred ubus call) and what a
		// synchronous fixture can never show.
		iface_status: (i, cb) => deferred ? push(parked, cb) : cb(netifd),
	} });

	d.apply_config(config.parse({ network: {
		m0:  { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'qmi' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0',
		       device: 'l3', apn: 'a', pdp_type: 'ipv4' },
	} }));

	let entry = d.contexts.wan;
	ok(entry != null && on_event != null, 'netifd-down: context and event hook wired');
	entry.wanted = true;

	// (1) down, autostart still set: kicked up, and NOT renewed
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	eq(calls, [ 'kick:wan' ], 'netifd down + connected session -> kicked, not renewed');

	// ...and the signature goes with it. It described what was pushed to an
	// interface that is not holding it any more; setup will push the lot again.
	eq(entry._applied_sig, null, 'netifd down: the stale applied-signature is dropped');

	// (2) operator ifdown: autostart cleared by somebody who is not us. That is
	// intent, so nothing is kicked and the context stops wanting the interface.
	calls = [];
	netifd.autostart = false;
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	eq(calls, [], 'administratively down -> not kicked up');
	eq(entry.wanted, false, 'administratively down -> the context stops wanting it');

	// (3) counter-proof for (1): with netifd holding the interface UP and the
	// same address, the renew is skipped as before — the new branch has not
	// swallowed the idempotence guard it sits in front of.
	calls = [];
	entry.wanted = true;
	netifd.autostart = true;
	netifd.up = true;
	entry._applied_sig = sprintf('%J', entry.ctx.settings);
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	eq(calls, [], 'interface up and address unchanged -> still skipped');

	// (4) and an up interface whose address moved still renews
	calls = [];
	entry.ctx.settings = { ipv4: { addr: '10.11.12.200' } };
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	eq(calls, [ 'renew:wan' ], 'interface up and address changed -> renewed');

	// (5) `auto 0` waits for an ifup even with the session connected
	calls = [];
	netifd.up = false;
	entry.cfg.auto = false;
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	eq(calls, [], 'auto=0 -> a down interface is left dormant');

	// (6) THE v6 COMPARISON IS ON THE PREFIX, not the whole address.
	//
	// The question this guard asks is "is netifd still holding what we pushed",
	// and the host half is not part of that answer: some firmware hands back
	// different low 64 bits on every settings read while prefix, gateway and DNS
	// stay put (RG502Q — context_common.keep_stable_v6 exists for exactly that,
	// so the MONITOR already compared this way), and netifd can re-derive the
	// identifier itself from an interface token. Comparing the literal address
	// answered "changed" for an interface that had changed nothing.
	entry.cfg.auto = true;
	netifd.up = true;

	let v6 = (netifd_addr, session_addr) => {
		calls = [];
		netifd['ipv6-address'] = [ { address: netifd_addr } ];
		entry.ctx.settings = { ipv4: { addr: '10.11.12.99' },
		                       ipv6: { addr: session_addr, plen: 64 } };
		entry._applied_sig = sprintf('%J', entry.ctx.settings);
		on_event(entry.ctx, 'settings', entry.ctx.settings);
		return calls;
	};

	eq(v6('2a01:59d:b810:6d53:8d47:418:76aa:2f8f', '2a01:59d:b810:6d53::1'), [],
		'v6: same /64, different host part -> still skipped');
	eq(v6('2a01:59d:b810:6d54::1', '2a01:59d:b810:6d53::1'), [ 'renew:wan' ],
		'v6: a different /64 -> renewed');

	// (7) v4 is still half of the idempotence test. A v6 prefix that matches
	// says nothing about the v4 address, and on a v4-only context both v6
	// values are absent — so a guard that asks only the v6 question answers
	// "unchanged" for every v4-only interface there is, whatever netifd holds.
	calls = [];
	netifd['ipv6-address'] = [];
	netifd['ipv4-address'] = [ { address: '10.11.12.7' } ];
	entry.ctx.settings = { ipv4: { addr: '10.11.12.99' } };
	entry._applied_sig = sprintf('%J', entry.ctx.settings);
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	eq(calls, [ 'renew:wan' ], 'v4 moved under an unchanged signature -> still renewed');

	// (8) THE PROBE IS DEFERRED, and the world moves while it is out.
	//
	// The `up` handler calls renew_iface() and clears `_kick_after_connect` on
	// the next line, so a callback that reads the live flag finds it false and
	// kicks on top of the kick that handler is already arranging. The flag has
	// to be sampled when the probe goes out.
	calls = [];
	deferred = true;
	netifd.up = false;
	netifd['ipv4-address'] = [ { address: '10.11.12.99' } ];
	entry._applied_sig = null;
	entry._kick_after_connect = true;

	on_event(entry.ctx, 'settings', entry.ctx.settings);
	entry._kick_after_connect = false;   // exactly what the `up` handler does
	answer();

	// it still renews (harmlessly — netifd drops that one, and the `up` handler's
	// own kick follows); what it must not do is add a second kick.
	eq(filter(calls, (c) => substr(c, 0, 5) == 'kick:'), [],
		'connect-first: the probe does not kick behind the up handler');

	// (9) one probe in flight per context: two settings events landing together
	// must not both kick the same interface.
	calls = [];
	entry._kick_after_connect = false;
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	answer();
	eq(calls, [ 'kick:wan' ], 'two settings events in flight -> one kick');

	// (10) and a context retired while the probe is out is not acted on. A
	// reload that cannot resolve an interface's modem deletes the entry
	// (stop_context), and kicking an interface on behalf of a context the
	// daemon has already dropped is how a torn-down interface comes back up.
	calls = [];
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	delete d.contexts.wan;
	answer();
	eq(calls, [], 'context retired while the probe was out -> nothing kicked');

	// (11) a lost probe must not silence the interface for good. Nothing here
	// can cancel an outstanding ubus request, so the in-flight latch carries
	// WHEN it went out and expires; a plain flag would be cleared in a callback
	// that never comes.
	d.contexts.wan = entry;
	calls = [];
	parked = [];
	entry._renew_probe = { at: time() };
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	eq(length(parked), 0, 'a probe already in flight is not duplicated');

	entry._renew_probe = { at: time() - 60 };   // older than PROBE_STALE_S
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	eq(length(parked), 1, 'a probe that never answered stops blocking later renews');

	// (12) the connection generation. The same entry and the same ctx object
	// survive a reconnect and the state is CONNECTED again at the end of it, so
	// an answer about the PREVIOUS session passes every identity check there
	// is. On a connect-first backend that reconnect arms its own kick, and this
	// stale answer would add a second one.
	calls = [];
	parked = [];
	// ...and clear the latch the case above deliberately left standing, or this
	// probe is never sent and the absence below proves nothing.
	entry._renew_probe = null;

	on_event(entry.ctx, 'settings', entry.ctx.settings);
	eq(length(parked), 1, 'the probe this case is about was actually sent');

	on_event(entry.ctx, 'up', {});      // the reconnect: a new generation

	// The `up` handler must get a probe of its OWN out. That renew is how the
	// new session's addresses reach netifd, so a latch still held by the old
	// connection's probe would not merely delay it — netifd would keep the
	// previous session's settings until the next refresh came round. (This
	// assertion is the one that would have caught the earlier version of this
	// test, whose comment claimed to drop a probe that was never sent.)
	eq(length(parked), 2, 'the reconnect sends its own probe, not blocked by the old one');

	let stale = parked[0];
	parked = [];
	stale(netifd);
	eq(filter(calls, (c) => substr(c, 0, 5) == 'kick:'), [],
		'an answer about the previous connection is not acted on');

	// (13) the expiry lets a SECOND probe out while the first is still live,
	// and both will eventually answer. A latch that only records "a probe
	// exists" cannot tell them apart: the superseded one acts on its own stale
	// answer, and clears the live probe's latch on the way out — which is the
	// double action the latch exists to prevent, one step removed.
	calls = [];
	parked = [];
	entry._renew_probe = null;
	netifd.up = false;

	on_event(entry.ctx, 'settings', entry.ctx.settings);
	entry._renew_probe.at -= 60;        // the first probe is now overdue
	on_event(entry.ctx, 'settings', entry.ctx.settings);
	eq(length(parked), 2, 'an overdue probe does not stop the next one');

	let live = entry._renew_probe;

	parked[0](netifd);                  // the superseded answer comes back
	eq(filter(calls, (c) => substr(c, 0, 5) == 'kick:'), [],
		'a superseded answer is not acted on');
	ok(entry._renew_probe === live, '...and does not clear the live probe');

	parked[1](netifd);                  // the current one
	eq(filter(calls, (c) => substr(c, 0, 5) == 'kick:'), [ 'kick:wan' ],
		'the current answer still acts, exactly once');
})();

done('test_daemon');
