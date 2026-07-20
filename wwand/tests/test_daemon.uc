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
	reg_timeout: 500, backoff_min: 1, backoff_max: 5,
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
		GET_SERVING_SYSTEM: {
			serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
			                  selected_network: 1, radio_ifs: [ 8 ] },
			current_plmn: { mcc: 262, mnc: 1, description: 'Testnet' },
		},
		MODIFY_PROFILE: {},
		GET_PROFILE_SETTINGS: { pdp_type: 0, apn: 'web' },
		SET_IP_FAMILY: {},
		START_NETWORK: { pdh: 4242 },
		GET_CURRENT_SETTINGS: V4_SETTINGS,
		STOP_NETWORK: {},
	};
}

let conn_srv = libubus.connect(sock);
let conn_cli = libubus.connect(sock);

ok(conn_srv != null && conn_cli != null, 'ubus connections established');

let events = [];
let mock = mockhub.create({ handlers: handlers() });
let dpfx = fakefx.create();

let daemon = daemon_mod.create({
	timing: TIMING,
	deps: {
		transport_open: mock.transport_open,
		log: (level, msg) => null,
		emit_event: (type, data) => push(events, { type: type, data: data }),
		kick_interface: (iface) => push(events, { type: 'kick', data: iface }),
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

		// context_wait parks a deferred reply while the context is CONNECTED
		// and must fire only once it drops. Its callback drives the remaining
		// checks so the test does not depend on reply-delivery ordering
		// between the parked wait and the context_down reply below.
		conn_cli.defer('wwand', 'context_wait', { interface: 'wan' }, (cw, rw) => {
			eq(cw, 0, 'context_wait: status ok');
			eq(rw.event, 'down', 'context_wait: woke on context down');

			conn_cli.defer('wwand', 'context_status', { interface: 'wan' }, (c4, r4) => {
				eq(r4.state, 'IDLE', 'context_status: IDLE after down');

				// events: context up + down were broadcast
				let ctx_events = filter(events, (e) => e.type == 'wwand.context');
				eq(map(ctx_events, (e) => e.data.event), [ 'up', 'down' ], 'events: up + down emitted');

				// boot-race nudge: idle interface kicked when modem registered
				ok(length(filter(events, (e) => e.type == 'kick' && e.data == 'wan')) >= 1,
					'events: interface kicked after modem ready');

				let modem_events = filter(events, (e) => e.type == 'wwand.modem');
				ok(length(filter(modem_events, (e) => e.data.event == 'registered')) == 1,
					'events: modem registered emitted');

				guard.cancel();
				uloop.end();
			});
		});

		// an unknown ref must return immediately (gone) so netifd re-runs setup
		conn_cli.defer('wwand', 'context_wait', { interface: 'nope' }, (cg, rg) => {
			eq(rg.event, 'gone', 'context_wait: unknown ref -> gone');
		});

		// bringing the context down wakes the parked context_wait above
		conn_cli.defer('wwand', 'context_down', { context: 'wan_ctx' }, (c3, r3) => {
			eq(c3, 0, 'context_down: ok');
		});
	});
});

uloop.run();
daemon.shutdown();

done('test_daemon');
