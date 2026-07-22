// wwand tests — PDP context state machine against the mock hub.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as mockhub from './lib/mockhub.uc';
import * as modem_mod from 'wwand/modem.uc';
import * as context_mod from 'wwand/context.uc';

uloop.init();

const TIMING = {
	sync_retry: 1, settle: 1, sim_settle: 1, card_poll: 1,
	reg_timeout: 500, backoff_min: 1, backoff_max: 5,
};

const V4_SETTINGS = {
	ipv4: '10.11.12.13', netmask: '255.255.255.248', gateway: '10.11.12.14',
	dns1: '9.9.9.9', dns2: '1.1.1.1', mtu: 1430, ip_family: 4,
};

const V6_SETTINGS = {
	ipv6: { addr: '2001:db8:0:0:0:0:0:2', plen: 64 },
	ipv6_gateway: { addr: '2001:db8:0:0:0:0:0:1', plen: 64 },
	ipv6_dns1: '2001:4860:4860:0:0:0:0:8888',
	mtu: 1430, ip_family: 6,
};

function card_status()
{
	return {
		index_gw_primary: 0, index_1x_primary: 0xffff,
		index_gw_secondary: 0xffff, index_1x_secondary: 0xffff,
		cards: [ {
			card_state: 1, upin_state: 0, upin_retries: 3, upuk_retries: 10,
			error_code: 0,
			applications: [ {
				type: 2, state: 7,
				personalization_state: 0, personalization_feature: 0,
				personalization_retries: 0, personalization_unblock_retries: 0,
				aid: '', upin_replaces_pin1: 0,
				pin1_state: 2, pin1_retries: 3, puk1_retries: 10,
				pin2_state: 0, pin2_retries: 3, puk2_retries: 10,
			} ],
		} ],
	};
}

// handlers bringing a modem to READY plus context-level defaults; the
// started map tracks which wds cid carries which ip family
function make_handlers(over, started)
{
	return {
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 60 },
			{ service: 2, major: 1, minor: 14 },
			{ service: 3, major: 1, minor: 25 },
			{ service: 11, major: 1, minor: 22 },
		] },
		GET_MODEL: { model: 'RG502Q-EA' },
		GET_REVISION: { revision: 'R11A06' },
		GET_IDS: { imei: '860000000000001' },
		SET_OPERATING_MODE: {},
		GET_CARD_STATUS: { card_status: card_status() },
		GET_MANUFACTURER: { manufacturer: 'Quectel' },
		GET_CAPABILITIES: { capabilities: { max_tx_rate: 262144, max_rx_rate: 4194304,
			data_service_cap: 1, sim_cap: 2, radio_ifs: [ 8, 12 ] } },
		GET_MSISDN: { msisdn: '4915112345678' },
		// EF-IMSI/EF-ICCID, nibble-swapped BCD (imsi 262011234567890)
		READ_TRANSPARENT: (args, meta) =>
			({ data: (args.file.file_id == 0x6F07)
				? [ 0x08, 0x29, 0x26, 0x10, 0x21, 0x43, 0x65, 0x87, 0x09 ]
				: [ 0x98, 0x94, 0x20, 0x00, 0x00, 0x01, 0x22, 0x38, 0x42, 0x09 ] }),
		REGISTER_EVENTS: { mask: 1 },
		REGISTER_INDICATIONS: {},
		GET_SERVING_SYSTEM: {
			serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
			                  selected_network: 1, radio_ifs: [ 8 ] },
		},

		MODIFY_PROFILE: {},
		GET_PROFILE_SETTINGS: { pdp_type: 3, apn: 'web' },
		SET_IP_FAMILY: {},
		START_NETWORK: (args, meta) => {
			started[sprintf('%d', meta.cid)] = (meta.count == 1) ? 4 : 6;
			return { pdh: (meta.count == 1) ? 1111 : 2222 };
		},
		GET_CURRENT_SETTINGS: (args, meta) =>
			(started[sprintf('%d', meta.cid)] == 4) ? V4_SETTINGS : V6_SETTINGS,
		STOP_NETWORK: {},
		// benign defaults so any connected scenario can run the stats sample
		GET_PACKET_STATISTICS: { tx_packets_ok: 0, rx_packets_ok: 0 },
		GET_CHANNEL_RATES: { rates: { tx_rate: 0, rx_rate: 0, max_tx_rate: 0, max_rx_rate: 0 } },

		...(over ?? {}),
	};
}

let scenarios = [];
let current = 0;

function scenario(name, cfg, run)
{
	push(scenarios, { name: name, cfg: cfg, run: run });
}

function run_next()
{
	if (current >= length(scenarios)) {
		uloop.end();
		return;
	}

	let s = scenarios[current++];
	let started = {};
	let mock = mockhub.create({ handlers: make_handlers(s.cfg.handlers, started) });
	let ctx_events = [];
	let finished = false;
	let guard = null;

	let modem;

	modem = modem_mod.create({
		id: s.name, device: '/dev/mock0',
		config: {},
		timing: TIMING,
		deps: {
			transport_open: mock.transport_open,
			log: (level, msg) => null,
			on_event: (m, event, data) => {
				if (event == 'registered' && !finished) {
					// modem ready: hand over to the scenario
					let ctx = context_mod.create({
						name: s.name + '_ctx',
						modem: m,
						config: s.cfg.config ?? {},
						timing: s.cfg.ctx_timing,
						deps: {
							log: (level, msg) => null,
							on_event: (c, ev, d) => push(ctx_events, { event: ev, data: d }),
						},
					});

					s.run(ctx, mock, ctx_events, () => {
						if (finished)
							return;

						finished = true;
						guard.cancel();
						modem.stop();
						uloop.timer(1, run_next);
					});
				}
			},
		},
	});

	guard = uloop.timer(3000, () => {
		ok(false, sprintf('%s: scenario timed out', s.name));
		finished = true;
		modem.stop();
		uloop.timer(1, run_next);
	});

	modem.start();
}

// --- A: dual-stack happy path ------------------------------------------------

scenario('dual', { config: { apn: 'web', pdp_type: 'ipv4v6' } }, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		eq(err, null, 'dual: no error');
		eq(ctx.state, 'CONNECTED', 'dual: state CONNECTED');
		eq(settings.ipv4.addr, '10.11.12.13', 'dual: v4 addr');
		eq(settings.ipv4.gateway, '10.11.12.14', 'dual: v4 gateway');
		eq(settings.ipv4.prefix, 32, 'dual: v4 forced to /32');
		eq(settings.ipv4.pushed_prefix, 29, 'dual: pushed prefix recorded');
		eq(settings.ipv4.dns, [ '9.9.9.9', '1.1.1.1' ], 'dual: v4 dns');
		eq(settings.ipv6.addr, '2001:db8:0:0:0:0:0:2', 'dual: v6 addr');
		eq(settings.ipv6.plen, 64, 'dual: v6 prefix length');
		eq(settings.mtu, 1430, 'dual: mtu');

		// profile write: base + roaming retry, pdp type matches -> no 3rd
		eq(length(mock.calls_for('MODIFY_PROFILE')), 2, 'dual: profile modified twice');
		eq(length(mock.calls_for('START_NETWORK')), 2, 'dual: two start-network calls');
		eq(mock.calls_for('START_NETWORK')[0].args.profile_3gpp, 1, 'dual: profile 1');
		eq(mock.calls_for('START_NETWORK')[0].args.apn, 'web', 'dual: apn in start-network');

		let sif = mock.calls_for('SET_IP_FAMILY');
		eq(sif[0].args.preference, 4, 'dual: family v4 set');
		eq(sif[1].args.preference, 6, 'dual: family v6 set');

		let up = filter(events, (e) => e.event == 'up');
		eq(length(up), 1, 'dual: one up event');
		next();
	});
});

// --- B: v6 fails, v4 survives ------------------------------------------------

scenario('v6-degrade', {
	config: { apn: 'web', pdp_type: 'ipv4v6' },
	handlers: {
		START_NETWORK: (args, meta) => {
			if (meta.count == 2)
				return { __error: 14, call_end_reason: 3 };

			return { pdh: 1111 };
		},
		GET_CURRENT_SETTINGS: V4_SETTINGS,
	},
}, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		eq(err, null, 'v6d: still up');
		eq(settings.ipv4.addr, '10.11.12.13', 'v6d: v4 present');
		eq(settings.ipv6, null, 'v6d: no v6 settings');
		eq(ctx.state, 'CONNECTED', 'v6d: connected');
		next();
	});
});

// --- C: v4 failure is fatal --------------------------------------------------

scenario('v4-fatal', {
	config: { apn: 'web', pdp_type: 'ipv4' },
	handlers: {
		START_NETWORK: { __error: 14, call_end_reason: 3 },
	},
}, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		ok(err != null, 'v4f: error reported');
		eq(err.stage, 'start_network', 'v4f: failed at start-network');
		eq(err.call_end_reason, 3, 'v4f: call end reason passed through');
		eq(ctx.state, 'IDLE', 'v4f: back to IDLE');
		eq(length(mock.calls_for('RELEASE_CID')) > 0, true, 'v4f: cid released');
		next();
	});
});

// --- D: disconnect indication tears the context down -------------------------

scenario('disconnect', { config: { apn: 'web', pdp_type: 'ipv4' } }, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		eq(err, null, 'disc: up ok');

		let cid = ctx.families['4'].client.cid;

		mock.indicate(1, cid, 'PACKET_SERVICE_STATUS_IND', {
			status: { status: 1, reconfigure: 0 },
			call_end_reason: 2,
			ip_family: 4,
		});

		uloop.timer(20, () => {
			eq(ctx.state, 'IDLE', 'disc: back to IDLE');

			let downs = filter(events, (e) => e.event == 'down');
			eq(length(downs), 1, 'disc: one down event');
			eq(downs[0].data.reason, 'disconnected', 'disc: reason disconnected');
			ok(length(mock.calls_for('STOP_NETWORK')) > 0, 'disc: stop-network attempted');
			next();
		});
	});
});

// --- E: administrative down --------------------------------------------------

scenario('admin-down', { config: { apn: 'web', pdp_type: 'ipv4v6' } }, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		eq(err, null, 'down: up ok');

		ctx.down((derr) => {
			eq(derr, null, 'down: teardown ok');
			eq(ctx.state, 'IDLE', 'down: IDLE');

			let stops = mock.calls_for('STOP_NETWORK');
			eq(length(stops), 2, 'down: both pdhs stopped');
			eq(stops[0].args.pdh, 1111, 'down: v4 pdh stopped');
			eq(stops[1].args.pdh, 2222, 'down: v6 pdh stopped');

			let downs = filter(events, (e) => e.event == 'down');
			eq(downs[0].data.reason, 'admin', 'down: admin reason');
			next();
		});
	});
});

// --- F: '#N' profile passthrough ---------------------------------------------

// pdp_type matches the mock profile (ipv4v6), so nothing at all is modified;
// pdp-type alignment intentionally applies to '#N' profiles too (old behavior)
scenario('profile-passthrough', { config: { apn: '#3', pdp_type: 'ipv4v6' } }, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		eq(err, null, 'pp: up ok');
		eq(length(mock.calls_for('MODIFY_PROFILE')), 0, 'pp: profile untouched');
		eq(mock.calls_for('GET_PROFILE_SETTINGS')[0].args.profile.index, 3, 'pp: profile 3 checked');
		eq(mock.calls_for('START_NETWORK')[0].args.profile_3gpp, 3, 'pp: started with profile 3');
		next();
	});
});

// --- G: pdp type mismatch triggers profile update -----------------------------

scenario('pdp-update', {
	config: { apn: 'web', pdp_type: 'ipv4' },
	handlers: {
		GET_PROFILE_SETTINGS: { pdp_type: 3, apn: 'web' },   // profile says ipv4v6
	},
}, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		eq(err, null, 'pdp: up ok');

		let mods = mock.calls_for('MODIFY_PROFILE');
		eq(length(mods), 3, 'pdp: third modify for pdp type');
		eq(mods[2].args.pdp_type, 0, 'pdp: changed to ipv4');
		next();
	});
});

// --- H: modem loss while connected -------------------------------------------

scenario('modem-lost', { config: { apn: 'web', pdp_type: 'ipv4' } }, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		eq(err, null, 'lost: up ok');

		mock.trigger_gone();

		uloop.timer(20, () => {
			eq(ctx.state, 'IDLE', 'lost: IDLE');

			let downs = filter(events, (e) => e.event == 'down');
			eq(length(downs), 1, 'lost: down event');
			eq(downs[0].data.reason, 'modem_lost', 'lost: reason modem_lost');
			// no QMI cleanup possible on a gone device
			eq(length(mock.calls_for('STOP_NETWORK')), 0, 'lost: no stop-network attempted');
			next();
		});
	});
});

// --- C2: registration loss mid-activation aborts without a ladder error ------

scenario('suspend-abort', {
	config: { apn: 'web', pdp_type: 'ipv4' },
	handlers: {
		START_NETWORK: () => null,   // swallow the request: attempt stays in flight
	},
}, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		eq(err?.error, 'suspended', 'sabort: aborted with suspended');
		eq(ctx.state, 'IDLE', 'sabort: back to IDLE');
		eq(length(filter(events, (e) => e.event == 'error')), 0,
			'sabort: no error event (recovery ladder untouched)');
		next();
	});

	// let the attempt reach START_NETWORK, then drop registration
	uloop.timer(50, () => ctx.modem_event('suspend', {}));
});

// --- G1b: internal 241 (profile in use) is reclaimed over AT and retried -----

scenario('reclaim-241', {
	config: { apn: 'web', pdp_type: 'ipv6' },
	handlers: {
		START_NETWORK: (args, meta) => {
			if (meta.count == 1)
				return { __error: 14, call_end_reason: 1,
					verbose_call_end: { type: 2, reason: 241 } };

			return { pdh: 4242 };
		},
		GET_CURRENT_SETTINGS: V6_SETTINGS,
	},
}, (ctx, mock, events, next) => {
	let at_cmds = [];

	// the modem's AT channel is what the reclaim path uses; fake it
	ctx.modem.at = {
		send: (cmd, cb, o) => { push(at_cmds, cmd); cb(null, []); },
		close: () => null,
	};

	ctx.up((err, settings) => {
		eq(err, null, 'reclaim: up after reclaim');
		eq(ctx.state, 'CONNECTED', 'reclaim: connected');
		eq(at_cmds, [ 'AT+CGACT=0,1' ], 'reclaim: stale pdp context deactivated');
		eq(length(mock.calls_for('START_NETWORK')), 2, 'reclaim: start-network retried');
		next();
	});
});

// --- G2: ipv6-only context fails hard when v6 activation fails ---------------

scenario('v6-only-fatal', {
	config: { apn: 'web', pdp_type: 'ipv6' },
	handlers: {
		START_NETWORK: { __error: 14, call_end_reason: 3 },
	},
}, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		ok(err != null, 'v6only: error reported');
		eq(ctx.state, 'IDLE', 'v6only: back to IDLE');
		next();
	});
});

// --- H1b: modem re-randomizes the v6 interface id — no renumber, no renew ----

scenario('v6-iid-stable', {
	config: { apn: 'web', pdp_type: 'ipv6' },
	handlers: {
		GET_CURRENT_SETTINGS: (args, meta) =>
			(meta.count <= 1) ? V6_SETTINGS
			                  : { ...V6_SETTINGS,
			                      ipv6: { addr: '2001:db8:0:0:dead:beef:0:99', plen: 64 } },
	},
}, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		eq(err, null, 'iid: up ok');
		eq(settings.ipv6.addr, '2001:db8:0:0:0:0:0:2', 'iid: initial addr');

		// serving change triggers a settings refresh; the modem now reports a
		// different interface id within the same /64
		ctx.modem_event('serving_change', {});

		uloop.timer(100, () => {
			eq(length(filter(events, (e) => e.event == 'settings')), 0,
				'iid: same-prefix iid change suppressed (no renew)');
			eq(ctx.status().settings.ipv6.addr, '2001:db8:0:0:0:0:0:2',
				'iid: configured address kept');
			next();
		});
	});
});

// --- H2: use_pushed_prefix keeps the network-provided netmask ----------------

scenario('pushed-prefix', {
	config: { apn: 'web', pdp_type: 'ipv4', use_pushed_prefix: true },
}, (ctx, mock, events, next) => {
	ctx.up((err, settings) => {
		eq(err, null, 'ppfx: up ok');
		eq(settings.ipv4.prefix, 29, 'ppfx: pushed prefix used');
		next();
	});
});

// --- I: muxed context binds its QMAP channel ---------------------------------

scenario('mux-bind', {
	config: { apn: 'web', pdp_type: 'ipv4', mux_id: 2 },
	handlers: { BIND_MUX_DATA_PORT: {} },
}, (ctx, mock, events, next) => {
	// datapath state normally produced by INIT_DATAPATH; injected here
	ctx.modem.datapath = { backend: 'rmnet', ep_id: 4, urb_size: 4100, mux_devs: [ 'wwan0m2' ] };

	ctx.up((err, settings) => {
		eq(err, null, 'mux: up ok');

		let binds = mock.calls_for('BIND_MUX_DATA_PORT');
		eq(length(binds), 1, 'mux: one bind call');
		eq(binds[0].args.mux_id, 2, 'mux: mux id bound');
		eq(binds[0].args.endpoint, { type: 2, iface: 4 }, 'mux: endpoint');

		// bind must precede ip-family selection on the same cid
		let names = map(mock.calls, (c) => c.name);
		ok(index(names, 'BIND_MUX_DATA_PORT') < index(names, 'SET_IP_FAMILY'),
			'mux: bind before set-ip-family');
		next();
	});
});

// --- J: muxed context without mux datapath fails cleanly ---------------------

scenario('mux-unavailable', {
	config: { apn: 'web', pdp_type: 'ipv4', mux_id: 1 },
}, (ctx, mock, events, next) => {
	ctx.modem.datapath = { backend: 'none', ep_id: null, mux_devs: [] };

	ctx.up((err, settings) => {
		ok(err != null, 'muxna: error reported');
		eq(err.stage, 'mux', 'muxna: mux stage');
		eq(ctx.state, 'IDLE', 'muxna: back to IDLE');
		next();
	});
});

// --- K: zero-rx watchdog trips on stalled counters ---------------------------

scenario('zero-rx', {
	config: { apn: 'web', pdp_type: 'ipv4' },
	ctx_timing: { stats_interval: 5, zero_rx_ms: 12 },
	handlers: {
		GET_CURRENT_SETTINGS: V4_SETTINGS,
		GET_PACKET_STATISTICS: { tx_packets_ok: 50, rx_packets_ok: 100 },   // never changes
	},
}, (ctx, mock, events, next) => {
	ctx.up((err) => {
		eq(err, null, 'zrx: up ok');

		uloop.timer(80, () => {
			let trips = filter(events, (e) => e.event == 'zero_rx');
			eq(length(trips), 1, 'zrx: tripped exactly once');
			ok(trips[0].data.stalled_ms >= 12, 'zrx: stall duration reported');
			ok(length(mock.calls_for('GET_PACKET_STATISTICS')) >= 3, 'zrx: stats sampled');
			next();
		});
	});
});

// --- L: increasing rx counters keep the watchdog quiet -----------------------

scenario('zero-rx-quiet', {
	config: { apn: 'web', pdp_type: 'ipv4' },
	ctx_timing: { stats_interval: 5, zero_rx_ms: 12 },
	handlers: {
		GET_CURRENT_SETTINGS: V4_SETTINGS,
		GET_PACKET_STATISTICS: (args, meta) =>
			({ tx_packets_ok: 50, rx_packets_ok: 100 + meta.count * 10 }),
	},
}, (ctx, mock, events, next) => {
	ctx.up((err) => {
		eq(err, null, 'zrxq: up ok');

		uloop.timer(60, () => {
			eq(length(filter(events, (e) => e.event == 'zero_rx')), 0, 'zrxq: no trip');
			ok(length(mock.calls_for('GET_PACKET_STATISTICS')) >= 4, 'zrxq: still sampling');
			next();
		});
	});
});

// --- stage B: in-place settings refresh -------------------------------------
// A serving-system change re-queries GET_CURRENT_SETTINGS; when the config
// actually changed, the context emits 'settings' and updates self.settings.
scenario('settings-change', {
	config: { apn: 'web', pdp_type: 'ipv4' },
	handlers: {
		// first call (activation) -> original; refresh -> changed addr + dns
		GET_CURRENT_SETTINGS: (args, meta) =>
			(meta.count <= 1) ? V4_SETTINGS
			                  : { ...V4_SETTINGS, ipv4: '10.99.99.99', dns1: '8.8.8.8' },
	},
}, (ctx, mock, events, next) => {
	ctx.up((err) => {
		eq(err, null, 'settings-change: up ok');
		eq(ctx.settings.ipv4.addr, '10.11.12.13', 'settings-change: initial addr');

		ctx.modem_event('serving_change');

		uloop.timer(60, () => {
			let se = filter(events, (e) => e.event == 'settings');
			eq(length(se), 1, 'settings-change: one settings event');
			eq(ctx.settings.ipv4.addr, '10.99.99.99', 'settings-change: self.settings updated');
			eq(se[0].data.ipv4.addr, '10.99.99.99', 'settings-change: event carries new addr');
			next();
		});
	});
});

// Unchanged settings on refresh must NOT emit — netifd renew stays quiet.
scenario('settings-nochange', {
	config: { apn: 'web', pdp_type: 'ipv4' },
	handlers: { GET_CURRENT_SETTINGS: V4_SETTINGS },
}, (ctx, mock, events, next) => {
	ctx.up((err) => {
		eq(err, null, 'settings-nochange: up ok');

		ctx.modem_event('serving_change');

		uloop.timer(60, () => {
			eq(length(filter(events, (e) => e.event == 'settings')), 0,
				'settings-nochange: no settings event when unchanged');
			ok(length(mock.calls_for('GET_CURRENT_SETTINGS')) >= 2,
				'settings-nochange: settings were re-queried');
			next();
		});
	});
});

// --- data-usage counters + uptime -------------------------------------------
// A stats sample while connected populates ctx.status().stats (bytes/packets/
// errors, summed across families) and reports an uptime.
scenario('data-stats', {
	config: { apn: 'web', pdp_type: 'ipv4' },
	ctx_timing: { stats_interval: 5 },
	handlers: {
		GET_CURRENT_SETTINGS: V4_SETTINGS,
		GET_PACKET_STATISTICS: (args, meta) => ({
			tx_packets_ok: 100, rx_packets_ok: 200,
			tx_bytes_ok: 5000, rx_bytes_ok: 90000,
			tx_packets_error: 1, rx_packets_error: 2,
			tx_packets_dropped: 3, rx_packets_dropped: 4,
		}),
		GET_CHANNEL_RATES: (args, meta) => ({
			rates: { tx_rate: 20000000, rx_rate: 80000000,
			         max_tx_rate: 50000000, max_rx_rate: 150000000 },
		}),
	},
}, (ctx, mock, events, next) => {
	ctx.up((err) => {
		eq(err, null, 'data-stats: up ok');

		uloop.timer(40, () => {
			let st = ctx.status();
			ok(st.stats != null, 'data-stats: stats populated');
			eq(st.stats.rx_bytes, 90000, 'data-stats: rx bytes');
			eq(st.stats.tx_bytes, 5000, 'data-stats: tx bytes');
			eq(st.stats.rx_errors, 2, 'data-stats: rx error counter');
			eq(st.stats.tx_dropped, 3, 'data-stats: tx dropped counter');
			ok(st.uptime != null && st.uptime >= 0, 'data-stats: uptime reported');
			eq(st.channel_rate.max_rx_rate, 150000000, 'data-stats: max downstream rate');
			eq(st.channel_rate.max_tx_rate, 50000000, 'data-stats: max upstream rate');
			next();
		});
	});
});

run_next();
uloop.run();

done('test_context');
