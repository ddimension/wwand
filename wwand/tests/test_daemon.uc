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
		GET_PIN_STATUS: { pin1: { status: 3, verify_retries: 3, unblock_retries: 10 } },
		GET_MANUFACTURER: { manufacturer: 'Quectel' },
		GET_CAPABILITIES: { capabilities: { max_tx_rate: 262144, max_rx_rate: 4194304,
			data_service_cap: 1, sim_cap: 2, radio_ifs: [ 8 ] } },
		GET_MSISDN: { msisdn: '4915112345678' },
		GET_IMSI: { imsi: '262011234567890' },
		GET_ICCID: { iccid: '89490200001022832490' },
		REGISTER_INDICATIONS: {},
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
		GET_CURRENT_SETTINGS: (args, meta) =>
			(meta.count <= 1) ? V4_SETTINGS : { ...V4_SETTINGS, ipv4: '10.11.12.99' },
		STOP_NETWORK: {},
		// the stats sample now fires immediately on connect
		GET_PACKET_STATISTICS: { tx_packets_ok: 0, rx_packets_ok: 0 },
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
		iface_status: (iface) => ({ up: iface_up }),   // false -> kick, true -> adopt
		datapath_fx: dpfx,
		resolve_modem_device: (cfg) => cfg.device,
		resolve_netdev: (cfg, device) => 'wwan0',
	},
});

let parsed = config.parse({
	wwand: {
		m0: { '.type': 'modem', device: '/dev/mock0' },
		wan_ctx: { '.type': 'context', modem: 'm0', apn: 'web', pdp_type: 'ipv4' },
	},
	network: {
		wan: { '.type': 'interface', proto: 'qmi', context: 'wan_ctx' },
	},
});

eq(length(parsed.warnings), 0, 'test config parses clean');

daemon.apply_config(parsed);
ok(ubus_api.publish(conn_srv, daemon, null) != null, 'wwand object published');

let guard = uloop.timer(5000, () => {
	ok(false, 'daemon test timed out');
	uloop.end();
});

// context_up is called while the modem is still initializing — this
// exercises the queued-until-ready path.
conn_cli.defer('wwand', 'context_up', { interface: 'wan' }, (code, reply) => {
	eq(code, 0, 'context_up: status ok');
	eq(reply.up, true, 'context_up: reports up');
	eq(reply.context, 'wan_ctx', 'context_up: context name');
	eq(reply.interface, 'wan', 'context_up: interface');
	eq(reply.netdev, 'wwan0', 'context_up: netdev');
	eq(reply.ipv4.addr, '10.11.12.13', 'context_up: v4 addr');
	eq(reply.ipv4.dns, [ '9.9.9.9', '1.1.1.1' ], 'context_up: v4 dns');
	eq(reply.ipv6, null, 'context_up: no v6 for ipv4 context');
	eq(reply.pushed_mtu, 1430, 'context_up: pushed mtu');
	ok(dpfx.action_index('link_set wwan0 mtu 1430') >= 0, 'context_up: mtu applied via rtnl layer');

	conn_cli.defer('wwand', 'status', {}, (c2, st) => {
		eq(c2, 0, 'status: ok');
		eq(st.modems.m0.state, 'READY', 'status: modem READY');
		eq(st.modems.m0.model, 'RG502Q-EA', 'status: model');
		eq(st.contexts.wan_ctx.state, 'CONNECTED', 'status: context CONNECTED');
		eq(st.contexts.wan_ctx.interface, 'wan', 'status: interface mapping');

		// In-place model: a settings change and a transient drop NEVER tear the
		// interface down — the daemon reconnects/renews in place. Only an admin
		// context_down (or a permanent loss) drives network.interface down.
		conn_cli.defer('wwand', 'context_settings', { interface: 'wan' }, (cs, rs) => {
			eq(cs, 0, 'context_settings: ok');
			eq(rs.up, true, 'context_settings: up while connected');
			eq(rs.ipv4.addr, '10.11.12.13', 'context_settings: v4 addr');

			let renews0 = length(filter(events, (e) => e.type == 'renew' && e.data == 'wan'));

			// (1) settings change -> in-place renew (no teardown)
			mock.indicate(3, 0xff, 'SERVING_SYSTEM_IND', {
				serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
				                  selected_network: 1, radio_ifs: [ 8 ] },
				current_plmn: { mcc: 262, mnc: 1, description: 'Testnet' },
			});

			uloop.timer(80, () => {
				ok(length(filter(events, (e) => e.type == 'renew' && e.data == 'wan')) > renews0,
					'settings change -> in-place renew');

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
						let downs1 = length(filter(events, (e) => e.type == 'down' && e.data == 'wan'));
						mock.indicate(1, 0xff, 'PACKET_SERVICE_STATUS_IND', {
							status: { status: 1, reconfigure: 0 }, call_end_reason: 2, ip_family: 4,
						});

						uloop.timer(320, () => {
							ok(length(filter(events, (e) => e.type == 'down' && e.data == 'wan')) > downs1,
								'reconnect hold expired -> interface downed (bounded blackhole)');

							ok(length(filter(events, (e) => e.type == 'kick' && e.data == 'wan')) >= 1,
								'boot-race kick after modem ready');
							let me = filter(events, (e) => e.type == 'wwand.modem');
							ok(length(filter(me, (e) => e.data.event == 'registered')) == 1,
								'modem registered emitted');

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

											// write path: whitelisted set, permanent duration
											conn_cli.defer('wwand', 'modem_set_settings',
												{ modem: 'm0', settings: { usage_preference: 2 } }, (c7, s7) => {
												eq(s7.ok, true, 'set: ok');
												eq(s7.applied, [ 'usage_preference' ], 'set: applied list');

												let set = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
												eq(set[length(set) - 1].args.usage_preference, 2, 'set: value reached modem');
												eq(set[length(set) - 1].args.change_duration, 1, 'set: permanent duration');

												// non-whitelisted key is rejected before the modem
												conn_cli.defer('wwand', 'modem_set_settings',
													{ modem: 'm0', settings: { network_selection: 1 } }, (c8, s8) => {
													eq(s8.ok, false, 'set: unknown key rejected');
													eq(s8.error, 'invalid_setting', 'set: reject reason');

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

uloop.run();
daemon.shutdown();

done('test_daemon');
