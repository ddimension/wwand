// wwand tests — modem state machine against the mock hub.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as mockhub from './lib/mockhub.uc';
import * as fakefx from './lib/fakefx.uc';
import * as modem_mod from 'wwand/modem.uc';

uloop.init();

const TIMING = {
	sync_retry: 1, settle: 1, sim_settle: 5, card_poll: 1,
	reg_timeout: 500, backoff_min: 1, backoff_max: 5,
};

function app(over)
{
	return {
		type: 2, state: 7,
		personalization_state: 0, personalization_feature: 0,
		personalization_retries: 0, personalization_unblock_retries: 0,
		aid: '', upin_replaces_pin1: 0,
		pin1_state: 2, pin1_retries: 3, puk1_retries: 10,
		pin2_state: 0, pin2_retries: 3, puk2_retries: 10,
		...(over ?? {}),
	};
}

function card_status(app_over)
{
	return {
		index_gw_primary: 0, index_1x_primary: 0xffff,
		index_gw_secondary: 0xffff, index_1x_secondary: 0xffff,
		cards: [ {
			card_state: 1, upin_state: 0, upin_retries: 3, upuk_retries: 10,
			error_code: 0,
			applications: [ app(app_over) ],
		} ],
	};
}

function base_handlers(over)
{
	return {
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 60 },
			{ service: 2, major: 1, minor: 14 },
			{ service: 3, major: 1, minor: 25 },
			{ service: 11, major: 1, minor: 22 },
			{ service: 26, major: 1, minor: 16 },
		] },
		GET_MODEL: { model: 'RG502Q-EA' },
		GET_REVISION: { revision: 'RG502QEAAAR11A06M4G' },
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
		// config validation reads this back; default reflects a matching state
		// (lte|nr5g allowed, manual selection) so unrelated scenarios see no
		// warnings. Scenarios exercising validation override it.
		GET_SYSTEM_SELECTION_PREFERENCE: {
			mode_preference: (1 << 4) | (1 << 6),
			network_selection: 1,
		},
		GET_SERVING_SYSTEM: {
			serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
			                  selected_network: 1, radio_ifs: [ 8, 12 ] },
			roaming: 1,
			current_plmn: { mcc: 262, mnc: 1, description: 'Telekom.de' },
		},
		...(over ?? {}),
	};
}

let scenarios = [];
let current = 0;

function scenario(name, cfg, until, verify)
{
	push(scenarios, { name: name, cfg: cfg, until: until, verify: verify });
}

function run_next()
{
	if (current >= length(scenarios)) {
		uloop.end();
		return;
	}

	let s = scenarios[current++];
	let mock = mockhub.create({ handlers: s.cfg.handlers });
	let events = [];
	let finished = false;
	let guard = null;

	let finish = (modem) => {
		if (finished)
			return;

		finished = true;

		if (guard)
			guard.cancel();

		s.verify(modem, mock, events);
		modem.stop();
		uloop.timer(1, run_next);
	};

	let modem = modem_mod.create({
		id: s.name,
		device: '/dev/mock0',
		config: s.cfg.config ?? {},
		datapath: s.cfg.datapath,
		recovery: s.cfg.recovery ?? { fx: fakefx.create(), state_dir: '/state' },
		at: s.cfg.at ?? { fx: fakefx.create() },   // no AT port unless injected
		timing: TIMING,
		deps: {
			transport_open: mock.transport_open,
			log: (level, msg) => null,
			on_event: (m, event, data) => {
				push(events, { event: event, data: data });

				if (event == s.until)
					finish(m);
			},
		},
	});

	guard = uloop.timer(3000, () => {
		ok(false, sprintf('%s: timed out waiting for %s', s.name, s.until));
		finish(modem);
	});

	if (s.cfg.setup)
		s.cfg.setup(mock, modem);

	modem.start();
}

// --- 1: happy path, SIM ready ------------------------------------------------

scenario('happy', { handlers: base_handlers() }, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'happy: state READY');
		eq(modem.info.model, 'RG502Q-EA', 'happy: model read');
		eq(modem.info.imei, '860000000000001', 'happy: imei read');
		eq(modem.info.manufacturer, 'Quectel', 'happy: manufacturer read');
		eq(modem.info.imsi, '262011234567890', 'happy: imsi decoded from EF');
		eq(modem.info.iccid, '89490200001022832490', 'happy: iccid decoded from EF');
		eq(modem.info.msisdn, '4915112345678', 'happy: msisdn read');
		eq(modem.reg.plmn.mcc, 262, 'happy: plmn mcc');
		eq(modem.reg.plmn.description, 'Telekom.de', 'happy: plmn description');
		ok(modem.uim != null, 'happy: uim client allocated');
		eq(length(mock.calls_for('SET_OPERATING_MODE')), 1, 'happy: opmode set once');
		eq(length(mock.calls_for('VERIFY_PIN')), 0, 'happy: no pin verify needed');
		eq(modem.counters.attempts, 0, 'happy: attempts reset');
	});

// --- 2: registration arrives later via indication ----------------------------

scenario('late-reg', {
	handlers: base_handlers({
		GET_SERVING_SYSTEM: (args, meta) => ({
			serving_system: { registration: 2, cs_attach: 0, ps_attach: 0,
			                  selected_network: 0, radio_ifs: [] },
		}),
	}),
	setup: (mock, modem) => {
		// when the modem starts searching, deliver the registered indication
		let poll = null;
		poll = uloop.timer(20, () => {
			if (modem.state == 'REGISTERING' && modem.nas) {
				mock.indicate(3, modem.nas.cid, 'SERVING_SYSTEM_IND', {
					serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
					                  selected_network: 1, radio_ifs: [ 8 ] },
					current_plmn: { mcc: 262, mnc: 2, description: 'Vodafone' },
				});
				return;
			}

			poll.set(20);
		});
	},
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'late-reg: state READY');
		eq(modem.reg.plmn.mnc, 2, 'late-reg: plmn from indication');
	});

// --- 3: PIN required, verified via UIM ---------------------------------------

scenario('pin-unlock', {
	handlers: base_handlers({
		GET_CARD_STATUS: (args, meta) =>
			({ card_status: card_status(meta.count == 1 ? { state: 2, pin1_state: 1 } : {}) }),
		VERIFY_PIN: { retries: { verify: 2, unblock: 10 } },
	}),
	config: { pincode: '1234' },
	setup: (mock, modem) => {
		let poll = null;
		poll = uloop.timer(10, () => {
			if (length(mock.calls_for('VERIFY_PIN')) > 0 && modem.uim) {
				mock.indicate(11, modem.uim.cid, 'CARD_STATUS_IND',
					{ card_status: card_status() });
				return;
			}

			poll.set(10);
		});
	},
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'pin: state READY');
		let vp = mock.calls_for('VERIFY_PIN');
		eq(length(vp), 1, 'pin: verify called once');
		eq(vp[0].args.info.pin, '1234', 'pin: correct pin sent');
		eq(vp[0].args.info.pin_id, 1, 'pin: pin1 id');
	});

// --- 3b: per-SIM PIN override (config wwand_sim matched by ICCID) -------------

scenario('pin-override', {
	handlers: base_handlers({
		GET_CARD_STATUS: (args, meta) =>
			({ card_status: card_status(meta.count == 1 ? { state: 2, pin1_state: 1 } : {}) }),
		VERIFY_PIN: { retries: { verify: 2, unblock: 10 } },
	}),
	// the active card's ICCID (89490200001022832490) matches a wwand_sim whose
	// pincode overrides the modem default; its ICCID is read BEFORE unlock.
	config: {
		pincode: '1234',
		sims: [ { iccid: '89490200001022832490', pincode: '9999', apn: 'sim.apn' } ],
	},
	setup: (mock, modem) => {
		let poll = null;
		poll = uloop.timer(10, () => {
			if (length(mock.calls_for('VERIFY_PIN')) > 0 && modem.uim) {
				mock.indicate(11, modem.uim.cid, 'CARD_STATUS_IND',
					{ card_status: card_status() });
				return;
			}
			poll.set(10);
		});
	},
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'pin-override: state READY');
		let vp = mock.calls_for('VERIFY_PIN');
		eq(vp[0].args.info.pin, '9999', 'pin-override: the wwand_sim pincode is used, not the modem default');
		eq(modem.active_sim?.iccid, '89490200001022832490', 'pin-override: active_sim resolved by ICCID');
		eq(modem.active_sim?.apn, 'sim.apn', 'pin-override: active_sim carries the carrier apn');
	});

// --- 4: PIN retry guard ------------------------------------------------------

scenario('pin-guard', {
	handlers: base_handlers({
		GET_CARD_STATUS: { card_status: card_status({ state: 2, pin1_state: 1, pin1_retries: 0 }) },
	}),
	config: { pincode: '1234' },
}, 'sim_blocked',
	(modem, mock, events) => {
		eq(modem.state, 'SIM_BLOCKED', 'guard: state SIM_BLOCKED');
		eq(length(mock.calls_for('VERIFY_PIN')), 0, 'guard: pin never sent');
	});

// --- 4b: configured sim_slot asserts the physical slot at init ---------------

scenario('sim-slot', {
	handlers: base_handlers({
		GET_SLOT_STATUS: { slots: [
			{ card_status: 2, slot_status: 1, logical_slot: 1, iccid: "\x98\x94\x20" },
			{ card_status: 2, slot_status: 0, logical_slot: 1, iccid: "\x98\x94\x21" },
		] },
		SWITCH_SLOT: {},
	}),
	config: { sim_slot: 2 },
}, 'registered',
	(modem, mock, events) => {
		eq(length(mock.calls_for('SWITCH_SLOT')), 1, 'slot: switch issued');
		eq(mock.calls_for('SWITCH_SLOT')[0].args.physical, 2, 'slot: target slot');
		eq(mock.calls_for('SWITCH_SLOT')[0].args.logical, 1, 'slot: logical slot 1');
		eq(modem.state, 'READY', 'slot: init continues to READY');
	});

// --- 5: no UIM service, DMS legacy fallback ----------------------------------

scenario('dms-fallback', {
	handlers: base_handlers({
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 9 },
			{ service: 2, major: 1, minor: 5 },
			{ service: 3, major: 1, minor: 8 },
		] },
		GET_PIN_STATUS: { pin1: { status: 3, verify_retries: 3, unblock_retries: 10 } },
		GET_IMSI: { imsi: '262019876543210' },
		GET_ICCID: { iccid: '8949020000012345678' },
	}),
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'dms: state READY');
		eq(modem.uim, null, 'dms: no uim client');
		eq(length(mock.calls_for('GET_PIN_STATUS')), 1, 'dms: legacy pin status used');
		eq(modem.info.imsi, '262019876543210', 'dms: imsi via legacy path');
	});

// --- 6: configured modes + manual PLMN ---------------------------------------

scenario('modes', {
	handlers: base_handlers({ SET_SYSTEM_SELECTION_PREFERENCE: {} }),
	config: { modes: 'lte,nr5g', mcc: '262', mnc: '1' },
}, 'registered',
	(modem, mock, events) => {
		let calls = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
		eq(length(calls), 1, 'modes: preference set once');
		eq(calls[0].args.mode_preference, (1 << 4) | (1 << 6), 'modes: lte|nr5g bitmask');
		eq(calls[0].args.network_selection, { mode: 1, mcc: 262, mnc: 1 }, 'modes: manual plmn');
	});

// --- 6b: runtime config validation — live modem MISMATCHES config ------------

scenario('validate-mismatch', {
	handlers: base_handlers({
		SET_SYSTEM_SELECTION_PREFERENCE: {},
		// modem allows lte|nr5g and sits in automatic selection, while config
		// asks for lte-only and pins a manual PLMN -> two warnings
		GET_SYSTEM_SELECTION_PREFERENCE: {
			mode_preference: (1 << 4) | (1 << 6),
			network_selection: 0,
		},
	}),
	config: { modes: 'lte', mcc: '262', mnc: '1' },
}, 'registered',
	(modem, mock, events) => {
		let w = modem.config_warnings;
		ok(w != null, 'validate: config_warnings populated');

		let mp = filter(w, (e) => e.check == 'mode_preference');
		eq(length(mp), 1, 'validate: mode_preference mismatch flagged');
		eq(mp[0].severity, 'warn', 'validate: mode_preference is a warn');
		eq(mp[0].expected, 1 << 4, 'validate: expected lte mask');
		eq(mp[0].actual, (1 << 4) | (1 << 6), 'validate: actual lte|nr5g mask');

		let ns = filter(w, (e) => e.check == 'network_selection');
		eq(length(ns), 1, 'validate: network_selection mismatch flagged');
		eq(ns[0].actual, 'automatic', 'validate: modem reported automatic');

		// RG502Q-EA also carries the profile-2 self-activation quirk note
		let q = filter(w, (e) => e.check == 'quirk');
		eq(length(q), 1, 'validate: RG502Q quirk note present');
		eq(q[0].severity, 'info', 'validate: quirk is info severity');
	});

// --- 6c: runtime config validation — live modem MATCHES config ---------------

scenario('validate-match', {
	handlers: base_handlers({
		GET_MODEL: { model: 'RG650E-EU' },   // no static quirk notes
		SET_SYSTEM_SELECTION_PREFERENCE: {},
		GET_SYSTEM_SELECTION_PREFERENCE: {
			mode_preference: 1 << 4,
			network_selection: 1,
		},
	}),
	config: { modes: 'lte', mcc: '262', mnc: '1' },
}, 'registered',
	(modem, mock, events) => {
		eq(length(modem.config_warnings), 0, 'validate: no warnings when modem matches');
	});

// --- 7: QMAP datapath setup (rmnet backend) ----------------------------------

let dpfx = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => ({
			qos: 0, llp: 2,
			ul_protocol: args.ul_protocol, dl_protocol: args.dl_protocol,
			dl_max_datagrams: 32, dl_max_size: args.dl_max_size,
			ul_max_datagrams: 32, ul_max_size: args.dl_max_size,
		}),
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [ { id: 1 }, { id: 2, mtu: 1430 } ],
		dgram_size: 0, fx: dpfx,
	},
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'dp: state READY');
		eq(modem.datapath.backend, 'rmnet', 'dp: rmnet backend');
		eq(modem.datapath.urb_size, 4100, 'dp: urb size');
		eq(modem.datapath.mux_devs, [ 'wwan0m1', 'wwan0m2' ], 'dp: mux devices');
		eq(modem.datapath.ep_id, 4, 'dp: ep id kept');

		let sdf = mock.calls_for('SET_DATA_FORMAT');
		eq(length(sdf), 1, 'dp: one wda format request');
		eq(sdf[0].args.llp, 2, 'dp: raw-ip requested');
		eq(sdf[0].args.ul_protocol, 8, 'dp: qmap v5 requested for rmnet');
		eq(modem.datapath.v5, true, 'dp: v5 negotiated');
		eq(sdf[0].args.dl_max_size, 4096, 'dp: aggregation size');
		eq(sdf[0].args.endpoint, { type: 2, iface: 4 }, 'dp: endpoint tlv');

		ok(dpfx.action_index('link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x31') >= 0,
			'dp: rmnet link created with v5 flags');
	});

// --- 7b: modem declines v5 with zeroed aggregation -> renegotiate plain qmap --

let dpfx2 = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath-v5-declined', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => {
			if (args.dl_protocol == 8)
				return { qos: 0, llp: 2, ul_protocol: 0, dl_protocol: 0,
				         dl_max_datagrams: 0, dl_max_size: 0 };

			return { qos: 0, llp: 2,
				ul_protocol: args.ul_protocol, dl_protocol: args.dl_protocol,
				dl_max_datagrams: 32, dl_max_size: args.dl_max_size };
		},
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [ { id: 1 } ], dgram_size: 0, fx: dpfx2,
	},
}, 'registered',
	(modem, mock, events) => {
		eq(length(mock.calls_for('SET_DATA_FORMAT')), 2, 'v5d: renegotiated');
		eq(modem.datapath.v5, false, 'v5d: fell back to plain qmap');
		eq(modem.datapath.urb_size, 4100, 'v5d: urb from requested size, not the zeroed echo');
		ok(dpfx2.action_index('link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x1') >= 0,
			'v5d: links with deagg only');
	});

// --- 8: mux wanted but unsupported modem -> error ----------------------------

scenario('datapath-nomux', {
	handlers: base_handlers(),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [ { id: 1 } ], fx: fakefx.create(),   // no mux capabilities in sysfs
	},
}, 'error',
	(modem, mock, events) => {
		let errs = filter(events, (e) => e.event == 'error');
		eq(errs[0].data.stage, 'datapath', 'nomux: failed in datapath stage');
		eq(errs[0].data.err.error, 'mux_backend_unavailable', 'nomux: backend error');
	});

// --- 9: recovery ladder rung at attempt 8 (opmode cycle) ---------------------

let ladder_fx = fakefx.create({
	files: { '/state/ladder.json': '{"attempts":7,"qmi_errors":0}' },
});

scenario('ladder', {
	handlers: base_handlers({
		// first cycle fails at SIM stage (transient), second succeeds
		GET_CARD_STATUS: (args, meta) =>
			(meta.count == 1) ? { __error: 3 } : { card_status: card_status() },
	}),
	recovery: { fx: ladder_fx, state_dir: '/state' },
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'ladder: recovered to READY');

		// restored 7 + 1 failure = 8 -> opmode_cycle rung ran
		let errs = filter(events, (e) => e.event == 'error');
		eq(errs[0].data.attempts, 8, 'ladder: attempt counter restored+bumped');
		eq(errs[0].data.action, 'opmode_cycle', 'ladder: opmode cycle chosen');

		let modes = map(mock.calls_for('SET_OPERATING_MODE'), (c) => c.args.mode);
		// rung: low_power (1) then online (0), plus one normal online per cycle
		ok(index(modes, 1) >= 0, 'ladder: low_power sent');
		eq(ladder_fx.files['/state/ladder.json'], '{ "attempts": 8, "proto_errors": 0, "rung": 1 }',
			'ladder: state persisted (rung 1 = opmode_cycle fired)');
	});

// --- 10: AT init runs model quirks + configured commands ---------------------

function fake_at_transport()
{
	let self = { written: [], data_cb: null };

	self.write = (data) => {
		push(self.written, trim(data));

		// auto-ack asynchronously, like a real modem
		uloop.timer(1, () => self.data_cb("OK\r\n"));

		return length(data);
	};
	self.on_data = (cb) => { self.data_cb = cb; };
	self.drain = () => null;
	self.close = () => null;

	return self;
}

let at_tr = fake_at_transport();

scenario('at-init', {
	handlers: base_handlers(),
	config: { tty: '/dev/ttyUSB2', at_init: [ 'ATE0' ] },
	at: {
		fx: fakefx.create(),
		open_transport: (path, baud, log) => at_tr,
	},
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'at: READY');
		eq(modem.at_tty, '/dev/ttyUSB2', 'at: tty from config override');
		// model RG502Q-EA -> QMBNCFG quirk, then configured ATE0 (validate_config
		// later appends its AT+QCFG="autoconnect" probe, so check just the prefix)
		eq(slice(at_tr.written, 0, 2), [ 'AT+QMBNCFG="AutoSel",1', 'ATE0' ], 'at: quirk + at_init sequence');
		ok(index(at_tr.written, 'AT+QCFG="autoconnect"') >= 0, 'at: autoconnect probed at validate');
	});

// --- 10b: eSIM host-access quirk (RG650E) queries lpa_enable at init --------

let at_tr_esim = fake_at_transport();

scenario('esim-quirk', {
	handlers: base_handlers({ GET_MODEL: { model: 'RG650E-EU' } }),
	config: { tty: '/dev/ttyUSB2' },
	at: {
		fx: fakefx.create(),
		open_transport: (path, baud, log) => at_tr_esim,
	},
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'esim-quirk: READY');
		ok(index(at_tr_esim.written, 'AT+QESIM="lpa_enable"') >= 0,
			'esim-quirk: internal LPA state queried at init');
		// the fake acks "OK" (not lpa_enable,1) -> nothing to change -> no reset
		eq(index(at_tr_esim.written, 'AT+CFUN=1,1'), -1,
			'esim-quirk: no reset when the value is unchanged');
	});

// --- 10c: cell-lock read-back over AT when the modem reports it unset ---------

let at_tr_lock = fake_at_transport();

scenario('validate-lock', {
	handlers: base_handlers({
		GET_MODEL: { model: 'RG650E-EU' },
		SET_SYSTEM_SELECTION_PREFERENCE: {},
		GET_SYSTEM_SELECTION_PREFERENCE: { mode_preference: 1 << 4, network_selection: 0 },
	}),
	// fake AT auto-acks bare "OK" (no +QNWLOCK line) -> lock reads as not applied
	config: { modes: 'lte', tty: '/dev/ttyUSB2', lock_4g: [ '1300:246' ] },
	at: {
		fx: fakefx.create(),
		open_transport: (path, baud, log) => at_tr_lock,
	},
}, 'registered',
	(modem, mock, events) => {
		let lk = filter(modem.config_warnings, (e) => e.check == 'lock_4g');
		eq(length(lk), 1, 'validate: unapplied 4G lock flagged');
		eq(lk[0].actual, 'off', 'validate: lock reported off');
		ok(index(at_tr_lock.written, 'AT+QNWLOCK="common/4g"') >= 0,
			'validate: 4G lock read back over AT');
	});

// --- 11: LOC positioning session ----------------------------------------------

scenario('loc', {
	handlers: base_handlers({
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 60 },
			{ service: 2, major: 1, minor: 14 },
			{ service: 3, major: 1, minor: 25 },
			{ service: 11, major: 1, minor: 22 },
			{ service: 16, major: 2, minor: 0 },
		] },
		'16:REGISTER_EVENTS': {},
		START: {},
	}),
	config: { location: true },
	setup: (mock, modem) => {
		let poll = null;
		poll = uloop.timer(10, () => {
			if (modem.loc && length(mock.calls_for('START'))) {
				mock.indicate(16, modem.loc.cid, 'POSITION_REPORT_IND', {
					status: 1, session_id: 1,
					latitude: 52.5, longitude: 13.375,
					altitude: 34.5, h_speed: 1.25, heading: 90.5,
					technology: 1, utc_ms: 1753000000000,
				});
				return;
			}

			poll.set(10);
		});
	},
}, 'location',
	(modem, mock, events) => {
		eq(modem.location.latitude, 52.5, 'loc: latitude');
		eq(modem.location.longitude, 13.375, 'loc: longitude');
		eq(modem.location.altitude, 34.5, 'loc: altitude');
		eq(modem.location.utc_ms, 1753000000000, 'loc: timestamp');

		let starts = mock.calls_for('START');
		eq(starts[0].args.session_id, 1, 'loc: session id');
		eq(starts[0].args.min_interval_ms, 1000, 'loc: report interval');
	});

// --- 12: telemetry collector --------------------------------------------------

scenario('telemetry', {
	handlers: base_handlers({
		GET_CELL_LOCATION_INFO: {
			lte_intra: {
				ue_idle: 0, plmn: '262/01', tac: 4321, global_cell_id: 29582339,
				earfcn: 1300, serving_cell_id: 246, resel_priority: 5,
				s_non_intra_search: 4, thresh_serving_low: 2, s_intra_search: 6,
				cells: [
					{ pci: 246, rsrq: -100, rsrp: -950, rssi: -650, srxlev: 30 },
					{ pci: 100, rsrq: -180, rsrp: -1100, rssi: -800, srxlev: 5 },
				],
			},
			nr5g_arfcn: 431070,
			nr5g_cell: { plmn: '262/01', tac: 54321, global_cell_id: 123456789,
			             pci: 242, rsrq: -100, rsrp: -970, snr: 200 },
		},
	}),
	config: { stats_interval: 0.005, lock_4g: [ '1300:246' ] },
}, 'telemetry',
	(modem, mock, events) => {
		ok(length(mock.calls_for('GET_CELL_LOCATION_INFO')) >= 1, 'tele: cell info queried');

		let lte = modem.cells.lte_intra;
		eq(lte.plmn, '262/01', 'tele: lte plmn decoded');
		eq(lte.earfcn, 1300, 'tele: lte earfcn');
		eq(lte.serving_cell_id, 246, 'tele: lte serving pci');
		eq(length(lte.cells), 2, 'tele: neighbour list');
		eq(lte.cells[1].rsrp, -1100, 'tele: neighbour rsrp raw');

		let nr = modem.cells.nr5g_cell;
		eq(nr.pci, 242, 'tele: nr5g pci');
		eq(nr.tac, 54321, 'tele: nr5g tac (u24be)');
		eq(modem.cells.nr5g_arfcn, 431070, 'tele: nr5g arfcn');

		let tev = filter(events, (e) => e.event == 'telemetry');
		ok(length(tev) >= 1, 'tele: telemetry event emitted');
		eq(tev[0].data.cells.lte_intra.tac, 4321, 'tele: event carries cells');
	});

// --- 13: device disappears ---------------------------------------------------

scenario('gone', {
	handlers: base_handlers(),
	setup: (mock, modem) => {
		let poll = null;
		poll = uloop.timer(10, () => {
			if (modem.state == 'READY') {
				mock.trigger_gone();
				return;
			}

			poll.set(10);
		});
	},
}, 'removed',
	(modem, mock, events) => {
		eq(modem.state, 'ABSENT', 'gone: state ABSENT');
	});

run_next();
uloop.run();

// parse_modes edge cases (pure function)
eq(modem_mod.parse_modes('all') != null, true, 'parse_modes all');
eq(modem_mod.parse_modes('lte'), 1 << 4, 'parse_modes lte');
eq(modem_mod.parse_modes('bogus'), null, 'parse_modes unknown -> null');
eq(modem_mod.parse_modes(''), null, 'parse_modes empty -> null');

// --- modem_quirks.for_model (pure resolver) ----------------------------------

import * as modem_quirks from 'wwand/modem_quirks.uc';

let q502 = modem_quirks.for_model('RG502Q-EA');
ok(length(q502.warn) >= 1, 'quirks: RG502Q carries a warn note');
eq(q502.expect.attach_pdp_type, 'ipv4v6', 'quirks: RG502Q inherits the Quectel ipv4v6 attach expectation');

let q650 = modem_quirks.for_model('RG650E-EU');
eq(q650.expect.attach_pdp_type, 'ipv4v6', 'quirks: RG650E expects ipv4v6 attach');
eq(length(q650.warn), 0, 'quirks: RG650E has no static warn note');

let qnone = modem_quirks.for_model('SIMCOM7600');
eq(length(qnone.warn), 0, 'quirks: unknown model -> no warns');
eq(length(qnone.init_commands), 0, 'quirks: unknown model -> no init commands');
eq(modem_quirks.for_model(null).expect.attach_pdp_type, null, 'quirks: null model safe');

// --- PLMNwAcT decoder (pure; bytes captured from a live Telekom SIM) ---------

import { decode_plmn_act } from 'wwand/sim.uc';

let plmn = decode_plmn_act([
	0x62, 0xF2, 0x10, 0x48, 0x00,   // 262/01, E-UTRAN + NG-RAN
	0x12, 0xF4, 0x70, 0xC8, 0x80,   // 214/07, all RATs
	0xFF, 0xFF, 0xFF, 0x00, 0x00,   // empty slot
]);

eq(length(plmn), 2, 'plmn: empty slot skipped');
eq(plmn[0].mcc, '262', 'plmn: mcc');
eq(plmn[0].mnc, '01', 'plmn: 2-digit mnc');
eq(plmn[0].eutran, true, 'plmn: eutran flag');
eq(plmn[0].ngran, true, 'plmn: ngran flag');
eq(plmn[0].utran, false, 'plmn: no utran');
eq(plmn[1].mcc, '214', 'plmn: second entry mcc');
eq(plmn[1].gsm, true, 'plmn: gsm flag');

done('test_modem');
