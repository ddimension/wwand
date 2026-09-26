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
		GET_OPERATING_MODE: { mode: 0 },   // online (FCC verify pass-through)
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
		SET_EVENT_REPORT: {},
		REFRESH_REGISTER_ALL: {},
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
	let seen_until = 0;

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
		timing: { ...TIMING, ...(s.cfg.timing ?? {}) },
		deps: {
			transport_open: mock.transport_open,
			log: (level, msg) => null,
			on_event: (m, event, data) => {
				push(events, { event: event, data: data });

				// `until_nth` lets a scenario observe a RETRY: make_fail arms
				// `uloop.timer(backoff, () => self.start())` on the same modem
				// object, so the second init pass is where per-instance state
				// that should not accumulate shows up.
				if (event == s.until && ++seen_until >= (s.cfg.until_nth ?? 1))
					finish(m);
			},
		},
	});

	// 3 s covers a bring-up; a scenario that has to watch several fast-telemetry
	// cycles go by (min_interval is a fixed 1000 ms) says so with guard_ms
	guard = uloop.timer(s.cfg.guard_ms ?? 3000, () => {
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

// --- 1b: GSM-7-bit packed operator name (issue #2) ---------------------------
// EG06-class firmware GSM-7-bit packs the Current-PLMN name. "PLAY" packs to the
// octets 50 66 30 0b, which as raw ASCII read "Pf0\x0b" (note the 0x0b control
// byte, no high byte) — so the decode must trigger on control bytes, not just
// high bytes, and unpack to "PLAY".
scenario('operator name gsm7-packed',
	{ handlers: base_handlers({
		GET_SERVING_SYSTEM: {
			serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
			                  selected_network: 1, radio_ifs: [ 8 ] },
			roaming: 0,
			current_plmn: { mcc: 260, mnc: 6,
			                description: chr(0x50) + chr(0x66) + chr(0x30) + chr(0x0b) },
		},
	}) },
	'registered',
	(modem, mock, events) => {
		eq(modem.reg.plmn.description, 'PLAY', 'issue#2: gsm7-packed operator name unpacked');
		eq(modem.reg.plmn.mcc, 260, 'issue#2: plmn mcc');
		eq(modem.reg.plmn.mnc, 6, 'issue#2: plmn mnc (raw int; UI zero-pads to 06)');
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
		// a later serving-system indication that OMITS the optional Current-PLMN
		// TLV (as on a cell reselection) must keep the last-known plmn
		modem._update_serving({ serving_system: { registration: 1, radio_ifs: [ 8 ] } });
		eq(modem.reg.plmn?.mnc, 2, 'reselection without Current-PLMN keeps last plmn');

		// PARKED (option lowpower): we switched the radio off ourselves, so the
		// deregistration that follows is the consequence, not a fault. Re-entering
		// the registration chain here would fight the parking, fail, and walk the
		// recovery ladder into an op-mode cycle and a power-cycle — for a modem
		// doing exactly what it was told.
		modem.lowpower_parked = true;
		modem._update_serving({ serving_system: { registration: 0, radio_ifs: [] } });
		eq(modem.state, 'READY', 'parked: losing registration does not re-enter the register chain');

		// ...and unparked, the same loss DOES chase it — otherwise the guard
		// above would be indistinguishable from never supervising at all
		modem.lowpower_parked = false;
		modem._update_serving({ serving_system: { registration: 0, radio_ifs: [] } });
		eq(modem.state, 'REGISTERING', 'unparked: a real registration loss is chased');
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

// ...AND A FIRMWARE THAT CANNOT ENUMERATE MUST NOT BE SWITCHED. sim.slot_status
// answers a firmware refusing GET_SLOT_STATUS (71/94) with ONE inferred row so
// the status page and the eSIM panel have something to work with. That row says
// a card is reachable; it does not say where. Acting on it here would send
// SWITCH_SLOT to a modem whose slot support has just declined to answer — and
// because the row reads "slot 1 active", a `sim_slot 2` would do exactly that,
// where the old unsupported-error branch had correctly walked away. Raised by
// Codex review of the single-slot fallback, 2026-09-22.

scenario('sim-slot-unenumerable', {
	handlers: base_handlers({
		GET_SLOT_STATUS: { __err: { code: 94 } },
		SWITCH_SLOT: {},
	}),
	config: { sim_slot: 2 },
}, 'registered',
	(modem, mock, events) => {
		eq(length(mock.calls_for('SWITCH_SLOT')), 0,
			'slot-unenum: no switch is sent on an inferred slot list');
		eq(modem.state, 'READY', 'slot-unenum: ...and init continues regardless');
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
		// the ICCID rides the same legacy path and was the half nothing pinned:
		// DMS UIM Get ICCID, message 0x003C, value in TLV 0x01 (libqmi 1.38,
		// "since 1.0") — what identifies the card on a modem too old for UIM
		eq(modem.info.iccid, '8949020000012345678', 'dms: iccid via legacy path');
	});

// --- 5a2: the serving-cell overlay, where the unit tests cannot reach --------
//
// modem_common.overlay_serving_signal is pinned field by field in
// test_modem_common. What that cannot pin is WHICH measurement reaches it and
// WHEN, and both of those were wrong in review before they were right:
//
//   1. store_cells holds the last neighbour list for NEIGH_HOLD seconds so the
//      UI list does not flicker. Reading the serving row out of self.cells
//      therefore served a measurement up to 30 s old as if it were current.
//      The stash is taken off the WIRE, before that substitution.
//   2. When GET_SIGNAL_INFO fails, the GET_SIGNAL_STRENGTH fallback may answer
//      with GSM or WCDMA alone. The shallow merge then carries the PREVIOUS
//      cycle's lte block through untouched, and overlaying it would pair a
//      current rsrp with an old snr.
//
// Three phases, counted by the mock:
//   cycle 1  signal ok          cells: TWO rows, serving -90.2  -> _neigh stored
//   cycle 2  signal ok          cells: ONE row,  serving -70.0  -> carry-over fires
//   cycle 3+ signal REJECTED    cells: ONE row,  serving -50.0  -> GSM-only fallback
const OVERLAY_HANDLERS = {
	GET_SIGNAL_INFO: (args, m) => (m.count <= 2)
		? { lte: { rssi: -35, rsrq: -14, rsrp: -95, snr: 98 } }
		: { __error: 71 },
	// LTE is absent on purpose: a GSM row must not authorise an LTE overlay
	GET_SIGNAL_STRENGTH: { rssi_list: [ { rssi: 85, radio_if: 4 } ] },
	// the watched fast loop walks on to carrier aggregation; refuse it so the
	// ladder settles on AT and the scenario stays about the signal
	GET_LTE_CPHY_CA_INFO: { __error: 71 },
	GET_CELL_LOCATION_INFO: (args, m) => ({ lte_intra: {
		serving_cell_id: 100, earfcn: 1850, ue_idle: 0,
		plmn: { mcc: 262, mnc: 1 }, tac: 1, global_cell_id: 1,
		cells: (m.count <= 1)
			? [ { pci: 100, rsrq: -110, rsrp: -902, rssi: -700, srxlev: 0 },
			    { pci: 200, rsrq: -180, rsrp: -1100, rssi: -900, srxlev: 0 } ]
			: [ { pci: 100,
			      rsrq: (m.count == 2) ? -120 : -130,
			      rsrp: (m.count == 2) ? -700 : -500,
			      rssi: (m.count == 2) ? -600 : -400, srxlev: 0 } ],
	} }),
};

// answers the open_at probe and anything the telemetry ladder tries with a
// bare OK — a silent command would hang the atcmd engine
let ov_at_tr;
ov_at_tr = {
	write: (d) => { if (ov_at_tr.data_cb) ov_at_tr.data_cb('\r\nOK\r\n'); },
	on_data: (cb) => { ov_at_tr.data_cb = cb; },
	close: () => null,
	drain: () => null,
};

scenario('signal-overlay', {
	handlers: base_handlers(OVERLAY_HANDLERS),
	at: { fx: fakefx.create(), open_transport: () => ov_at_tr },
	until_nth: 4,
	guard_ms: 9000,   // four fast-telemetry cycles at 1000 ms, plus the bring-up
	setup: (mock, modem) => {
		let poll = null;
		poll = uloop.timer(10, () => {
			if (modem.state == 'READY')
				modem.watch();   // the fast loop only runs while watched
			poll.set(10);
		});
	},
}, 'telemetry',
	(modem, mock, events) => {
		// (1) the overlay reached the signal at all, in 0.1 dB
		ok(modem.signal?.lte?.rsrp != -95,
			'overlay: the latched signal TLV did not survive a cell measurement');

		// (2) THE CARRY-OVER TEST. Cycle 2's wire row says -70.0 while
		// store_cells has put cycle 1's two-row list back for the UI, whose
		// serving row still says -90.2. The signal must show the wire.
		eq(modem.signal?.lte?.rsrp, -70.0,
			'overlay: the measurement comes off the wire, not from the held neighbour list');

		// ...and the hold itself still works, which is what it is there for
		eq(length(modem.cells?.lte_intra?.cells ?? []), 2,
			'overlay: NEIGH_HOLD still keeps the UI neighbour list from flickering');

		// (3) THE GSM-ONLY TEST. Cycles 3+ reject GET_SIGNAL_INFO and the
		// fallback answers with a GSM row only, so the lte block is last
		// cycle's — it must NOT pick up cycle 3's -50.0.
		eq(modem.signal?.gsm_rssi, -85,
			'overlay: the GET_SIGNAL_STRENGTH fallback did land');
		eq(modem.signal?.lte?.rsrp, -70.0,
			'overlay: a GSM-only fallback does not authorise an LTE overlay');
		eq(modem.signal?.lte?.snr, 98,
			'overlay: ...so the lte block is still whole — no current rsrp beside a stale snr');
	});

// --- 5b: minimal-service QMI stack (2011-era, the Huawei E182E class) --------
//
// Only CTL/WDS/DMS/NAS-1.0 + the 0xE0 placeholder: no UIM, no DSD, no WDA.
// NAS 1.0 rejects every message newer than itself (71 = Invalid QMI command)
// but answers GET_SIGNAL_STRENGTH (0x0020). The datapath: no WDA service ->
// `ethernet` (802.3 kept, NOARP) — the datapath probes would claim rmnet,
// the WDA-less gate must beat them.
// (let/assignment: the arrows inside reference the transport itself)
let e182e_at_tr;
e182e_at_tr = {
	write: (d) => {
		// answer the open_at probe and the CSQ floor read; everything else
		// (QCFG autoconnect check, CEER, temperature probes) gets a bare OK —
		// a silent command would hang the atcmd engine
		if (e182e_at_tr.data_cb && match(d ?? '', /^AT\r?$/))
			e182e_at_tr.data_cb('\r\nOK\r\n');
		else if (e182e_at_tr.data_cb && index(d ?? '', 'AT+CSQ') == 0)
			e182e_at_tr.data_cb('\r\n+CSQ: 20,99\r\n\r\nOK\r\n');
		else if (e182e_at_tr.data_cb)
			e182e_at_tr.data_cb('\r\nOK\r\n');
	},
	on_data: (cb) => { e182e_at_tr.data_cb = cb; },
	close: () => null,
	drain: () => null,
};
const e182e_dpfx = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/add_mux': true,
	'/sys/module/rmnet': true,
} });

// The minimal-stack handler set, shared by every scenario that models this
// class of modem. Extracted because a scenario that omits one of these does
// not fail a check: mockhub die()s on an unhandled message, the exception
// leaves the uloop callback, and the REST OF THE RUN is skipped while the
// summary still reads 0 failures.
const E182E_HANDLERS = {
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 5 },
			{ service: 2, major: 1, minor: 2 },
			{ service: 3, major: 1, minor: 0 },
			{ service: 224, major: 0, minor: 0 },
		] },
		GET_MODEL: { model: '8' },
		GET_REVISION: { revision: '21.200.07.00.00' },
		GET_IDS: { imei: '359740023613407' },
		GET_MANUFACTURER: { manufacturer: 'huawei' },
		GET_SERVING_SYSTEM: {
			serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
			                  selected_network: 1, radio_ifs: [ 8 ] },
			roaming: 0,
			current_plmn: { mcc: 515, mnc: 66, description: 'DITO' },
		},
		GET_PIN_STATUS: { pin1: { status: 3, verify_retries: 3, unblock_retries: 10 } },
		GET_IMSI: { imsi: '515661009472658' },
		GET_ICCID: { iccid: '8963112400000000000' },
		GET_SIGNAL_STRENGTH: {
			rssi_list: [ { rssi: 73, radio_if: 8 } ],
			rsrq: { rsrq: -11, radio_if: 8 },
			lte_snr: 115,
			lte_rsrp: -97,
		},
		GET_SIGNAL_INFO: { __error: 71 },
		GET_CELL_LOCATION_INFO: { __error: 71 },
		GET_LTE_CPHY_CA_INFO: { __error: 71 },
		GET_SYSTEM_INFO: { __error: 71 },
		GET_SYSTEM_SELECTION_PREFERENCE: { __error: 71 },
		// the 2011 stack does not answer CTL SYNC (field-observed; the
		// host mock expresses it as a rejection — same error path, and
		// a real silence costs 3s x SYNC_TRIES in the suite) — the
		// bring-up must continue on the version query, not hard-fail
		SYNC: { __error: 71 },
};

scenario('e182e', {
	handlers: base_handlers(E182E_HANDLERS),
	config: { tty: '/dev/ttyUSB3' },
	datapath: { netdev: 'wwan0', mux: 'auto', mux_links: [], dgram_size: 0, fx: e182e_dpfx },
	at: { fx: fakefx.create(), open_transport: () => e182e_at_tr },
	setup: (mock, modem) => {
		let poll = null;
		poll = uloop.timer(10, () => {
			if (modem.state == 'READY')
				modem.watch();   // the fast loop only runs while watched
			poll.set(10);
		});
	},
}, 'telemetry',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'e182e: state READY');
		eq(length(mock.calls_for('SYNC')), 11, 'e182e: SYNC retried the full ladder, then continued');
		eq(modem.uim, null, 'e182e: no uim client');
		eq(modem.dsd, null, 'e182e: no dsd client');
		eq(modem.datapath?.backend, 'ethernet', 'e182e: ethernet datapath (no WDA, probes beaten)');
		eq(length(mock.calls_for('SET_DATA_FORMAT')), 0, 'e182e: no WDA negotiation at all');
		ok(e182e_dpfx.action_index('write /sys/class/net/wwan0/qmi/raw_ip N') > 0,
			'e182e: raw_ip asserted OFF (802.3 kept)');
		eq(e182e_dpfx.action_index('link_set wwan0 noarp'), -1,
			'e182e: NOARP NOT set — the 802.3 bridge needs ARP (HW-verified)');
		eq(length(mock.calls_for('GET_PIN_STATUS')), 1, 'e182e: DMS pin-status fallback used');
		eq(modem.info.imsi, '515661009472658', 'e182e: imsi via the DMS legacy path');
		eq(modem.signal?.lte?.rssi, -73, 'e182e: rssi from GET_SIGNAL_STRENGTH (negative dBm)');
		eq(modem.signal?.lte?.rsrp, -97, 'e182e: rsrp from GET_SIGNAL_STRENGTH');
		eq(modem.signal?.lte?.snr, 115, 'e182e: snr from GET_SIGNAL_STRENGTH (0.1 dB)');
		eq(modem.signal?.lte?.rsrq, -11, 'e182e: rsrq from GET_SIGNAL_STRENGTH');
		eq(modem.dsd_status?.mode, 'LTE', 'e182e: data mode resolved via the nas radio_ifs fallback');
		eq(modem.counters?.proto_errors ?? 0, 0,
			'e182e: rejected polls did not feed the recovery counter');

		// teardown releases the live service clients on the modem (CTL
		// RELEASE_CID), not just locally — old stacks with a tiny client
		// table leak a slot per attempt otherwise
		modem.stop();
		eq(length(mock.calls_for('RELEASE_CID')), 3,
			'e182e: teardown released dms/nas/wds on the modem');
	});

// --- 5c: exhausted client table (ClientIdsExhausted, CTL error 5) ------------
//
// The 2011-era stack keeps ~5 client slots; a failed attempt can leak one and
// plain retries only burn attempts, so the daemon resets the modem stack over
// AT (CFUN=1,1) instead — fire-and-forget, then the normal failure path.
let e182e_at_writes = [];
let e182e_at_log_tr;
e182e_at_log_tr = {
	write: (d) => {
		push(e182e_at_writes, d ?? '');
		if (e182e_at_log_tr.data_cb)
			e182e_at_log_tr.data_cb('\r\nOK\r\n');
	},
	on_data: (cb) => { e182e_at_log_tr.data_cb = cb; },
	close: () => null,
	drain: () => null,
};

scenario('e182e_exhaust', {
	handlers: base_handlers({
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 5 },
			{ service: 2, major: 1, minor: 2 },
			{ service: 3, major: 1, minor: 0 },
			{ service: 224, major: 0, minor: 0 },
		] },
		GET_MODEL: { model: '8' },
		GET_REVISION: { revision: '21.200.07.00.00' },
		GET_IDS: { imei: '359740023613407' },
		GET_MANUFACTURER: { manufacturer: 'huawei' },
		ALLOCATE_CID: { __error: 5 },
		SYNC: { __error: 71 },
	}),
	config: { tty: '/dev/ttyUSB3' },
	datapath: { netdev: 'wwan0', mux: 'auto', mux_links: [], dgram_size: 0, fx: e182e_dpfx },
	at: { fx: fakefx.create(), open_transport: () => e182e_at_log_tr },
}, 'error',
	(modem, mock, events) => {
		ok(length(mock.calls_for('ALLOCATE_CID')) >= 1, 'exhaust: allocation attempted');
		let last = events[length(events) - 1];
		eq(last?.event, 'error', 'exhaust: the init failed');
		eq(last?.data?.err?.code, 5, 'exhaust: the failure carried ClientIdsExhausted');
		eq(last?.data?.stage, 'alloc_dms', 'exhaust: dms allocation is the first client');
		ok(length(e182e_at_writes) > 0 && index(e182e_at_writes[0], 'AT+CFUN=1,1') == 0,
			'exhaust: modem stack reset (CFUN) sent over AT');
		eq(last?.data?.action, 'retry', 'exhaust: failure handled, retry pending');
		eq(length(mock.calls_for('RELEASE_CID')), 0, 'exhaust: nothing was allocated, nothing to release');
	});

// --- 5d: teardown releases the lazy WMS client too ---------------------------
scenario('wms_release', {
	// the same minimal stack as e182e, plus WMS (service 5) — that is the whole
	// point here, a lazily allocated SMS client that teardown has to release
	handlers: base_handlers({ ...E182E_HANDLERS,
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 5 },
			{ service: 2, major: 1, minor: 2 },
			{ service: 3, major: 1, minor: 0 },
			{ service: 5, major: 1, minor: 3 },
			{ service: 224, major: 0, minor: 0 },
		] },
	}),
	config: { tty: '/dev/ttyUSB3' },
	datapath: { netdev: 'wwan0', mux: 'auto', mux_links: [], dgram_size: 0, fx: e182e_dpfx },
	at: { fx: fakefx.create(), open_transport: () => e182e_at_tr },
	setup: (mock, modem) => {
		let poll = null;
		poll = uloop.timer(10, () => {
			if (modem.state == 'READY') {
				// watch() first: the fast telemetry loop only runs while
				// watched, and 'telemetry' is what this scenario waits for
				modem.watch();
				modem._ensure_wms(() => null);
			}
			poll.set(10);
		});
	},
}, 'telemetry',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'wms: state READY');
		ok(modem.wms != null, 'wms: lazy client allocated');
		modem.stop();
		eq(length(mock.calls_for('RELEASE_CID')), 4, 'wms: teardown released dms/nas/wds/wms on the modem');
	});

// GET_SIGNAL_INFO hands the decoded TLVs straight to consumers, so any field
// whose wire unit is not its apparent unit has to be converted at this edge.
// WCDMA Ec/Io is the one: a raw gint16 in units of -0.5 dB, which libqmi renders
// as (-0.5)*raw (qmicli-nas.c:460-462, 1.38.0). Left raw it disagreed with the
// AT path, which already reports real dB (atcmd_parse.uc:356) — one key, two
// units, and no way for a consumer to tell which backend answered.
scenario('signal_units', {
	handlers: base_handlers({
		GET_SIGNAL_INFO: {
			lte: { rssi: -66, rsrq: -11, rsrp: -94, snr: 138 },
			wcdma: { rssi: -85, ecio: 20 },
			gsm_rssi: -78,
		},
		// the rest of the fast cycle: stubbed out so the scenario reaches
		// 'telemetry' on the signal read alone, which is what it is about
		GET_CELL_LOCATION_INFO: { __error: 71 },
		GET_LTE_CPHY_CA_INFO: { __error: 71 },
		GET_SYSTEM_INFO: { __error: 71 },
	}),
	setup: (mock, modem) => {
		let poll = null;
		poll = uloop.timer(10, () => {
			if (modem.state == 'READY')
				modem.watch();
			poll.set(10);
		});
	},
}, 'telemetry',
	(modem, mock, events) => {
		// -10.0, not -10: the conversion yields a double, and the half-dB
		// resolution is real — a raw 21 is -10.5 dB, not a rounding artefact
		eq(modem.signal?.wcdma?.ecio, -10.0,
			'signal: wcdma ec/io converted from raw -0.5 dB units to dB');
		eq(modem.signal?.wcdma?.rssi, -85, 'signal: wcdma rssi passes through as dBm');
		eq(modem.signal?.gsm_rssi, -78, 'signal: gsm rssi passes through as dBm');
		eq(modem.signal?.lte?.rsrp, -94, 'signal: lte fields are untouched');
		eq(modem.signal?.lte?.snr, 138, 'signal: lte snr stays in tenths of a dB');

		// THE INDICATION IS THE SECOND DOOR. NAS SIGNAL_INFO_IND carries the
		// same TLV layout (schema/nas.uc:419-422) and arrives BETWEEN refreshes,
		// so a conversion applied only to the polled reply would let the raw
		// value straight back in — the same key alternating between -10 dB and
		// 20 for one measurement. Found by review, not by the first test.
		// The registered handler is invoked directly, the way the reselection
		// case below does for SERVING_SYSTEM_IND — the mock's indicate() is
		// asynchronous and this assertion has to be deterministic.
		for (let cb in (modem.nas.handlers['SIGNAL_INFO_IND'] ?? []))
			cb({ wcdma: { rssi: -85, ecio: 24 } });

		eq(modem.signal?.wcdma?.ecio, -12.0,
			'signal: an indication is normalised the same way as a poll');
		eq(modem.signal?.lte, null,
			'signal: the indication replaced the reply, it did not merge into it');

		modem.stop();
	});

// --- 6: configured modes + manual PLMN ---------------------------------------

scenario('modes', {
	handlers: base_handlers({ SET_SYSTEM_SELECTION_PREFERENCE: {} }),
	config: { modes: 'lte,nr5g', mcc: '262', mnc: '1' },
}, 'registered',
	(modem, mock, events) => {
		let calls = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
		eq(length(calls), 1, 'modes: preference set once');
		// idempotency guard: the mock's GET already reports lte|nr5g, so the
		// mode_preference is DROPPED from the write; the manual PLMN (whose
		// target is not readable pre-registration) is still applied
		eq(calls[0].args.mode_preference, null, 'modes: live mode matches -> dropped by guard');
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
		// 9, not 8: libqmi's QMAPV4 is 0x08 and QMAPV5 is 0x09. This assertion
		// held the wrong value and so froze the bug — asking for v4 and calling
		// it v5, which the modem answered by renegotiating.
		eq(sdf[0].args.ul_protocol, 9, 'dp: qmap v5 (0x09) requested for rmnet');
		eq(modem.datapath.v5, true, 'dp: v5 negotiated');
		eq(sdf[0].args.dl_max_size, 4096, 'dp: aggregation size');
		eq(sdf[0].args.endpoint, { type: 2, iface: 4 }, 'dp: endpoint tlv');
		eq(sdf[0].args.ul_max_datagrams, 11, 'dp: uplink aggregation requested');
		ok((sdf[0].args.ul_max_size ?? 0) > 0, 'dp: uplink aggregation size set');

		ok(dpfx.action_index('link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x31') >= 0,
			'dp: rmnet link created with v5 flags');
	});

// --- 7b: modem declines v5 with zeroed aggregation -> renegotiate plain qmap --

let dpfx2 = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

let dpfx3 = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

// refuses every checksum version: the ladder has to bottom out at plain QMAP
// rather than keep trying or give up on aggregation altogether
scenario('datapath-all-declined', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => {
			if (args.dl_protocol == 9 || args.dl_protocol == 8)
				return { qos: 0, llp: 2, ul_protocol: 0, dl_protocol: 0,
				         dl_max_datagrams: 0, dl_max_size: 0 };

			return { qos: 0, llp: 2,
				ul_protocol: args.ul_protocol, dl_protocol: args.dl_protocol,
				dl_max_datagrams: 32, dl_max_size: args.dl_max_size };
		},
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [ { id: 1 } ], dgram_size: 0, fx: dpfx3,
	},
}, 'registered',
	(modem, mock, events) => {
		eq(length(mock.calls_for('SET_DATA_FORMAT')), 3, 'alld: tried v5, v4, then plain');
		eq(modem.datapath.qmap_version, 1, 'alld: bottomed out at plain QMAP');
		ok(dpfx3.action_index('link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x1') >= 0,
			'alld: links with deaggregation only');
	});

// --- an UNMUXED modem must never be asked for QMAP -------------------------
//
// The datapath probe claims the box for `rmnet` whether or not channels are
// configured (that is deliberate — an accelerated datapath has to be able to
// identify itself before anyone writes `option mux`). What must NOT follow is a
// QMAP negotiation: with no channel to build there is nothing to unwrap the
// frames the modem would then send, and plenty of modems only ever do plain
// raw-IP.
//
// This regressed once, hard: the "no mux channel" case was caught in
// netlink.setup() AFTER the WDA ladder had already run, so an ordinary unmuxed
// modem walked v5 -> v4 -> v1 and then died with "add `option mux_id`".
// Reported on an EC25-E that had worked for months, which then failed to
// connect at all (openwrt/packages#30185, 2026-09-07). `option mux_id` is
// optional and has to stay optional.

let dpfx_nomux = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath-unmuxed', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => ({
			qos: 0, llp: args.llp,
			ul_protocol: args.ul_protocol, dl_protocol: args.dl_protocol,
			dl_max_datagrams: args.dl_max_datagrams ?? 0,
			dl_max_size: args.dl_max_size ?? 0,
		}),
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [], dgram_size: 0, fx: dpfx_nomux,
	},
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'nomux: the modem connects — this is not an error');
		eq(modem.datapath.backend, 'raw_ip', 'nomux: a plain raw-IP parent');

		let sdf = mock.calls_for('SET_DATA_FORMAT');
		eq(length(sdf), 1, 'nomux: one format request, no ladder');
		eq(sdf[0].args.llp, 2, 'nomux: raw-IP link layer still requested');
		eq(sdf[0].args.ul_protocol, null, 'nomux: no uplink QMAP protocol asked for');
		eq(sdf[0].args.dl_protocol, null, 'nomux: no downlink QMAP protocol asked for');
		eq(sdf[0].args.dl_max_datagrams, null, 'nomux: no aggregation requested');
		eq(modem.datapath.qmap_version, null, 'nomux: nothing QMAP was negotiated');

		// and no rmnet child was built for a config that named none
		ok(dpfx_nomux.action_index('link_add_rmnet') < 0,
			'nomux: no mux child created');
	});

// A MODEM THAT DOES NO QMAP AT ALL, on a config that asks for mux channels.
//
// "protocol 0" in the WDA answer means aggregation DISABLED — it is an answer,
// not a refusal. The Huawei E392 (M9200B, 2012 firmware) has WDA 1.0 and gives
// llp 2 / proto 0 to v5, v4 and v1 alike, so the ladder bottoms out with
// nothing agreed (observed on a Chateau, 2026-09-11). Muxing is then genuinely
// impossible and the bring-up must fail — but it has to say WHY and name the
// option that fixes it, instead of reporting "aggregation_rejected" with a raw
// echo, which reads like a protocol error and tells an operator nothing.
//
// (Unmuxed, this modem never gets asked in the first place — see
// `datapath-unmuxed` above. That is the path the same stick takes on a current
// build.)
let dpfx_noqmap = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath-no-qmap', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => ({
			qos: 0, llp: 2, ul_protocol: 0, dl_protocol: 0,
			dl_max_datagrams: 0, dl_max_size: 0,
		}),
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [ { id: 1 } ], dgram_size: 0, fx: dpfx_noqmap,
	},
}, 'error',
	(modem, mock, events) => {
		eq(length(mock.calls_for('SET_DATA_FORMAT')), 3,
			'noqmap: the whole ladder was offered — v5, v4, v1');

		let errs = filter(events, (e) => e.event == 'error');

		ok(length(errs) > 0, 'noqmap: the bring-up fails, muxing really is impossible');
		eq(errs[0].data?.stage, 'wda_format', 'noqmap: fails in the format stage');
		eq(errs[0].data?.err?.error, 'no_qmap_support',
			'noqmap: named as "no QMAP support", not as a rejected protocol');
		eq(errs[0].data?.err?.echo?.dl_protocol, 0,
			'noqmap: the modem answer is carried for the record');

		// Worth pinning because it is what an operator sees on the box: the
		// daemon retries, so a permanent mismatch cycles ABSENT -> INIT ->
		// ABSENT rather than settling. Whether that should become a sticky
		// config error is a separate question; this records today's answer.
		eq(errs[0].data?.action, 'retry',
			'noqmap: today this retries rather than settling as a config error');
	});

// THE SAME MODEM, with `option mux_id 'auto'` instead of a pinned channel.
//
// This is the whole point of `auto`: the only authority on whether a modem does
// QMAP is its own WDA answer, and that arrives here — long after the config had
// to decide. Autosetup cannot know it (the host-side probes say "the DRIVER can
// mux", which on an E392 is true and useless), so it writes `auto` and the
// datapath settles it. A modem that says no gets a plain raw-IP parent and
// comes up, instead of a channel it cannot carry and a log line telling the
// operator to remove an option the daemon wrote itself.
let dpfx_autodemote = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath-auto-demote', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => ({
			qos: 0, llp: 2, ul_protocol: 0, dl_protocol: 0,
			dl_max_datagrams: 0, dl_max_size: 0,
		}),
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [ { id: 1 } ], mux_auto: true,
		dgram_size: 0, fx: dpfx_autodemote,
	},
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY',
			'auto-demote: the modem comes up — an auto channel is an offer, not a demand');
		eq(modem.datapath.backend, 'raw_ip',
			'auto-demote: demoted to the plain raw-IP parent');
		eq(modem.datapath.qmap_version, null,
			'auto-demote: no QMAP version recorded — none is on the wire');

		eq(length(mock.calls_for('SET_DATA_FORMAT')), 3,
			'auto-demote: the whole ladder was still offered before giving up');

		ok(dpfx_autodemote.action_index('link_add_rmnet') < 0,
			'auto-demote: no mux child was built');
		eq(length(modem.datapath.mux_devs ?? []), 0,
			'auto-demote: and none is reported in status');

		let errs = filter(events, (e) => e.event == 'error');
		eq(length(errs), 0, 'auto-demote: no error event at all');
	});

// ...but an ADOPTING datapath cannot be demoted, and this is the case that
// makes the distinction necessary rather than tidy. A vendor driver
// (qmi_wwan_q, pcie_mhi) creates its QMAP children at module load, so the modem
// is in QMAP whatever wwand negotiates. An unmuxed parent there carries QMAP
// frames with nothing to unwrap them — silent, and worse than the error.
let dpfx_autoadopt = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath-auto-adopts', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => ({
			qos: 0, llp: 2, ul_protocol: 0, dl_protocol: 0,
			dl_max_datagrams: 0, dl_max_size: 0,
		}),
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'vendorqmap',
		mux_links: [ { id: 1 } ], mux_auto: true,
		dgram_size: 0, fx: dpfx_autoadopt,
		plugins: { vendorqmap: {
			proto: [ 'qmi' ],
			qmap: true,
			// `prune` is what marks an adopter (netlink.datapath_caps)
			prune: (fx, netdev) => [],
			links: (fx, ctx) => ({ ok: true, mux_devs: [], map_ids: {} }),
			probe: (fx, netdev) => true,
		} },
	},
}, 'error',
	(modem, mock, events) => {
		let errs = filter(events, (e) => e.event == 'error');

		ok(length(errs) > 0,
			'auto-adopts: still fails — the driver already put this modem in QMAP');
		eq(errs[0].data?.err?.error, 'no_qmap_support',
			'auto-adopts: and says why, rather than demoting into a silent mismatch');
	});

// AN ADOPTING DATAPATH IS NOT DEMOTABLE AT *ANY* OF THE THREE SITES.
//
// The terminal "aggregation disabled" case had the guard from the start; the
// WDA-less gate and the 802.3 echo did not, and the invariant is worthless if
// it holds at one site out of three. Both of these would have announced an
// unmuxed 802.3 parent for a device whose vendor driver had already built QMAP
// children at module load — an interface that comes up and carries nothing,
// and whose children the ethernet path's ordinary pruning would then remove.
let adopter = () => ({
	proto: [ 'qmi' ],
	qmap: true,
	prune: (fx, netdev) => [],     // `prune` is what marks an adopter
	links: (fx, ctx) => ({ ok: true, mux_devs: [], map_ids: {} }),
	probe: (fx, netdev) => true,
});

let dpfx_adopt_nowda = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath-auto-adopts-no-wda', {
	// WDA (service 26) absent from the version table — the same way the
	// pinned-channel `wda_unavailable_for_mux` case is built
	handlers: base_handlers({
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 60 },
			{ service: 2, major: 1, minor: 14 },
			{ service: 3, major: 1, minor: 25 },
			{ service: 11, major: 1, minor: 22 },
		] },
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'vendorqmap',
		mux_links: [ { id: 1 } ], mux_auto: true,
		dgram_size: 0, fx: dpfx_adopt_nowda,
		plugins: { vendorqmap: adopter() },
	},
}, 'error',
	(modem, mock, events) => {
		let errs = filter(events, (e) => e.event == 'error');

		ok(length(errs) > 0, 'adopt-nowda: fails instead of demoting to ethernet');
		eq(errs[0].data?.err?.error, 'wda_unavailable_for_mux',
			'adopt-nowda: named for what is missing');
	});

let dpfx_adopt_llp = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath-auto-adopts-llp', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => ({
			qos: 0, llp: 1, ul_protocol: 0, dl_protocol: 0,
			dl_max_datagrams: 0, dl_max_size: 0,
		}),
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'vendorqmap',
		mux_links: [ { id: 1 } ], mux_auto: true,
		dgram_size: 0, fx: dpfx_adopt_llp,
		plugins: { vendorqmap: adopter() },
	},
}, 'error',
	(modem, mock, events) => {
		let errs = filter(events, (e) => e.event == 'error');

		ok(length(errs) > 0, 'adopt-llp: fails instead of demoting to ethernet');
		eq(errs[0].data?.err?.error, 'no_raw_ip_support',
			'adopt-llp: named for what the modem refused');
	});

// A MODEM THAT REFUSES RAW IP. wwand asks for raw-IP framing everywhere except
// the `ethernet` pseudo-mode; the modem echoes its choice in the WDA answer's
// `llp`, and that echo used to be logged and never read. Carrying on would put
// the kernel in raw-IP (netlink.setup writes qmi_wwan's raw_ip=Y for every
// backend but `ethernet`) and the modem in 802.3 — link up, traffic garbage.
//
// It settles muxing too, and the kernel agrees from the other side:
// pass-through can only be set on a raw-IP device (qmi_wwan.c:505-510,
// 6.18.41), so a modem that will not do raw IP cannot carry QMAP either.
let dpfx_llp = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath-llp-802-3', {
	handlers: base_handlers({
		// asked for raw IP (llp 2), answers 802.3 (llp 1)
		SET_DATA_FORMAT: (args, meta) => ({
			qos: 0, llp: 1, ul_protocol: 0, dl_protocol: 0,
			dl_max_datagrams: 0, dl_max_size: 0,
		}),
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [ { id: 1 } ], mux_auto: true,
		dgram_size: 0, fx: dpfx_llp,
	},
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'llp: the modem comes up');
		eq(modem.datapath.backend, 'ethernet',
			'llp: the 802.3 datapath — the framing the modem actually chose');

		// the kernel must be put in the SAME framing, which is what the
		// ethernet backend exists to do
		eq(trim(dpfx_llp.files['/sys/class/net/wwan0/qmi/raw_ip'] ?? ''), 'N',
			'llp: the kernel is left in 802.3 too, not asserted to raw-IP');

		eq(length(mock.calls_for('SET_DATA_FORMAT')), 1,
			'llp: no QMAP ladder — the answer settled it on the first reply');
		ok(dpfx_llp.action_index('link_add_rmnet') < 0,
			'llp: no mux child, because 802.3 cannot carry QMAP');
	});

// ...and with a PINNED channel it stays an error: the operator asked for that
// channel, and a modem that cannot do raw IP cannot provide it. Demoting a
// pinned channel silently would be the same class of bug as ignoring the echo.
let dpfx_llp_pin = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath-llp-802-3-pinned', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => ({
			qos: 0, llp: 1, ul_protocol: 0, dl_protocol: 0,
			dl_max_datagrams: 0, dl_max_size: 0,
		}),
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [ { id: 1 } ], dgram_size: 0, fx: dpfx_llp_pin,
	},
}, 'error',
	(modem, mock, events) => {
		let errs = filter(events, (e) => e.event == 'error');

		ok(length(errs) > 0, 'llp-pinned: fails rather than quietly changing datapath');
		eq(errs[0].data?.err?.error, 'no_raw_ip_support',
			'llp-pinned: named for what the modem refused, not for the symptom');
	});

// ...and a modem that answers v5 with a REAL but unusable protocol before going
// to zero further down is NOT the same fault. Claiming "answered disabled to
// every version offered" there would name the wrong thing; the ladder has to
// remember what it was told, not just what it was told last.
let dpfx_mixed = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath-mixed-refusal', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => (args.dl_protocol == 9)
			// v5: a real protocol, but not the one asked for -> a refusal that
			// is NOT "aggregation disabled"
			? { qos: 0, llp: 2, ul_protocol: 6, dl_protocol: 6,
			    dl_max_datagrams: 32, dl_max_size: 4096 }
			: { qos: 0, llp: 2, ul_protocol: 0, dl_protocol: 0,
			    dl_max_datagrams: 0, dl_max_size: 0 },
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [ { id: 1 } ], dgram_size: 0, fx: dpfx_mixed,
	},
}, 'error',
	(modem, mock, events) => {
		let errs = filter(events, (e) => e.event == 'error');

		ok(length(errs) > 0, 'mixed: still fails — nothing usable was agreed');
		eq(errs[0].data?.err?.error, 'aggregation_rejected',
			'mixed: NOT reported as "no QMAP support" — v5 offered a protocol');
	});

// a modem that echoes the requested version downlink but a DIFFERENT one uplink
// has not agreed to what was asked: both directions are configured from this one
// answer (dl drives the rmnet ingress flags, ul the egress ones and the uplink
// coalescing), so accepting it would apply v5 egress framing the modem never
// confirmed. The ladder must treat it as a refusal.
let dpfx_asym = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/pass_through': true,
	'/sys/class/net/wwan0/qmi/raw_ip': true,
	'/sys/module/rmnet': true,
} });

scenario('datapath-asymmetric-echo', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => {
			// v5 downlink, plain QMAP uplink — a half-agreement
			if (args.dl_protocol == 9)
				return { qos: 0, llp: 2, ul_protocol: 5, dl_protocol: 9,
				         dl_max_datagrams: 32, dl_max_size: args.dl_max_size };

			return { qos: 0, llp: 2,
				ul_protocol: args.ul_protocol, dl_protocol: args.dl_protocol,
				dl_max_datagrams: 32, dl_max_size: args.dl_max_size };
		},
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [ { id: 1 } ], dgram_size: 0, fx: dpfx_asym,
	},
}, 'registered',
	(modem, mock, events) => {
		ok(modem.datapath.qmap_version != 5,
			'asym: a half-echoed v5 is not recorded as v5');
		eq(dpfx_asym.action_index('link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0x31'), -1,
			'asym: ...and no v5 checksum flags are programmed');
	});

// raw-IP: no QMAP on the wire at all. The ladder still bottoms out at rung 1
// internally (it needs SOMETHING to ask for), but reporting that as "QMAP v1"
// would name a header format nobody sends — status pages read this field.
let dpfx_raw = fakefx.create({ present: {
	'/sys/class/net/wwan0/qmi/raw_ip': true,
} });

scenario('datapath-raw-ip-version', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => ({ qos: 0, llp: 2,
			ul_protocol: args.ul_protocol ?? 0, dl_protocol: args.dl_protocol ?? 0,
			dl_max_datagrams: 0, dl_max_size: 0 }),
	}),
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'off',
		mux_links: [], dgram_size: 0, fx: dpfx_raw,
	},
}, 'registered',
	(modem, mock, events) => {
		eq(modem.datapath.backend, 'raw_ip', 'rawver: raw-IP datapath');
		eq(modem.datapath.qmap_version, null,
			'rawver: no QMAP version is reported where QMAP is not on the wire');
	});

scenario('datapath-v5-declined', {
	handlers: base_handlers({
		SET_DATA_FORMAT: (args, meta) => {
			// a modem that refuses v5 (0x09) — the renegotiation fixture
			if (args.dl_protocol == 9)
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
		// the ladder steps DOWN one version, it does not jump to plain: this
		// modem refuses v5 but takes v4, and v4 has its own rmnet flag pair
		// (CKSUMV4 0x04|0x08, not CKSUMV5 0x10|0x20). Telling rmnet the wrong
		// pair is a misparse, not a downgrade — which is why the version is
		// carried through instead of a boolean.
		eq(length(mock.calls_for('SET_DATA_FORMAT')), 2, 'v5d: renegotiated once');
		eq(modem.datapath.qmap_version, 4, 'v5d: landed on v4');
		eq(modem.datapath.v5, false, 'v5d: and the old boolean says not-v5');
		eq(modem.datapath.urb_size, 4100, 'v5d: urb from requested size, not the zeroed echo');
		ok(dpfx2.action_index('link_add_rmnet wwan0m1 link wwan0 mux_id 1 flags 0xd') >= 0,
			'v5d: links with deagg + the v4 checksum pair');
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
	recovery: { fx: ladder_fx, state_dir: '/state', now: () => 5000 },
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
		// `proto_ok: 1` is the load-bearing part: this modem answered its QMI
		// requests, so the hardware rungs are armed and the ladder is allowed to
		// escalate. A modem that never answered gets 0 here and nothing physical
		// happens — see the gate tests in test_recovery.
		eq(ladder_fx.files['/state/ladder.json'],
			'{ "attempts": 8, "proto_errors": 0, "rung": 1, "proto_hw": 0, "proto_hw_base": 0, "proto_ok": 1, "proto_name": "qmi", "unarmed_reset": 0, "outage_since": 5000 }',
			'ladder: state persisted (rung 1 = opmode_cycle fired, arming recorded)');
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
		// a bare AT goes first: open_at probes the port before committing to
		// it, so a channel that opens but never answers is dropped in favour
		// of the MBIM pipe instead of silently swallowing every command
		eq(at_tr.written[0], 'AT', 'at: the port is probed before it is used');
		eq(slice(at_tr.written, 1, 3), [ 'AT+QMBNCFG="AutoSel",1', 'ATE0' ], 'at: quirk + at_init sequence');
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

// A REFUSED DEFERRED INIT RESET DOES NOT PARK THE MODEM.
//
// step_apply_init_reset batches every AT-config step that asked for a reset and
// fires ONE. A successful reset takes the modem off the bus, so not continuing
// the chain is right there. A REFUSED one re-enumerates nothing — and both
// branches returned into a callback that only logged, so init stopped dead in
// INIT_SERVICES. fail() was never called either, so the recovery ladder never
// engaged: the modem just sat there, with one warning in the log. Found by a
// full review, 2026-09-19.
//
// Here the RG650E reports its internal LPA enabled (so the eSIM quirk requests
// a reset) and then refuses AT+CFUN=1,1. Reaching `registered` at all IS the
// assertion — without the fix this scenario dies on the 3 s guard.

let at_tr_reset_refused = fake_at_transport();
at_tr_reset_refused.write = (data) => {
	let cmd = trim(data);

	push(at_tr_reset_refused.written, cmd);

	uloop.timer(1, () => {
		if (cmd == 'AT+QESIM="lpa_enable"')
			at_tr_reset_refused.data_cb('+QESIM: "lpa_enable", 1\r\n\r\nOK\r\n');
		else if (cmd == 'AT+CFUN=1,1')
			at_tr_reset_refused.data_cb('ERROR\r\n');
		else
			at_tr_reset_refused.data_cb('OK\r\n');
	});

	return length(data);
};

scenario('init-reset-refused', {
	handlers: base_handlers({ GET_MODEL: { model: 'RG650E-EU' } }),
	config: { tty: '/dev/ttyUSB2' },
	at: {
		fx: fakefx.create(),
		open_transport: (path, baud, log) => at_tr_reset_refused,
	},
}, 'registered',
	(modem, mock, events) => {
		ok(index(at_tr_reset_refused.written, 'AT+QESIM="lpa_enable",0') >= 0,
			'init-reset: the quirk disabled the internal LPA (reset now due)');
		ok(index(at_tr_reset_refused.written, 'AT+CFUN=1,1') >= 0,
			'init-reset: the batched reset was attempted');
		eq(modem.state, 'READY',
			'init-reset: a refused reset resumes init instead of parking the modem');
	});

// A DEFERRED SETTINGS RESET IS ACTUALLY ISSUED.
//
// step_confnet_apply pushes 'system selection preference' onto _init_resets on
// a settings_deferred model (MeiG SLM7xx: mode/PLMN NV writes take effect only
// after a reboot). Its comment says step_apply_init_reset "issues ONE reset at
// the end" — but that step ran seven links EARLIER in the chain, so the push
// had no consumer and the reset never happened. The modes were accepted and
// silently never applied, and the NV-vs-live idempotency guard then read them
// back as already set on every later boot, hiding it for good. Found by a full
// review, 2026-09-19.

let at_tr_deferred = fake_at_transport();
// refuse the reset, so init resumes and the scenario can reach `registered`:
// a SUCCESSFUL one takes the modem off the bus by design and nothing follows.
at_tr_deferred.write = (data) => {
	let cmd = trim(data);

	push(at_tr_deferred.written, cmd);
	uloop.timer(1, () => at_tr_deferred.data_cb(cmd == 'AT+CFUN=1,1' ? 'ERROR\r\n' : 'OK\r\n'));

	return length(data);
};

scenario('settings-deferred-reset', {
	handlers: base_handlers({
		GET_MODEL: { model: 'SLM770A' },
		SET_SYSTEM_SELECTION_PREFERENCE: {},
		GET_SYSTEM_SELECTION_PREFERENCE: { mode_preference: 0, network_selection: 0 },
	}),
	config: { modes: 'lte', tty: '/dev/ttyUSB2' },
	at: {
		fx: fakefx.create(),
		open_transport: (path, baud, log) => at_tr_deferred,
	},
}, 'registered',
	(modem, mock, events) => {
		ok(index(at_tr_deferred.written, 'AT+CFUN=1,1') >= 0,
			'settings-deferred: the deferred reset reaches the modem');
	});

// AN ACKNOWLEDGED RESET THAT NEVER HAPPENS DOES NOT PARK THE MODEM EITHER.
//
// A successful reset takes the modem off the bus, so step_apply_init_reset
// deliberately does not continue — discovery re-inits the new incarnation. But
// an ACK is not a reboot. A modem that answers OK to AT+CFUN=1,1 and stays put
// left init parked in INIT_SERVICES with nothing pending and no fail(), so the
// recovery ladder never engaged either. The watchdog gives that case an answer.
// Raised by Codex review, 2026-09-19.
//
// The fake AT acks everything (fake_at_transport's default), so this is exactly
// the "acked, still here" case; `timing.init_reset` is shortened so the guard
// does not have to wait 30 s for it.

let at_tr_reset_stuck = fake_at_transport();

scenario('init-reset-no-reenum', {
	handlers: base_handlers({ GET_MODEL: { model: 'RG650E-EU' } }),
	config: { tty: '/dev/ttyUSB2' },
	timing: { init_reset: 150 },
	at: {
		fx: fakefx.create(),
		open_transport: (path, baud, log) => at_tr_reset_stuck,
	},
	setup: (mock, modem) => {
		// make the eSIM quirk actually request a reset: report the internal
		// LPA enabled, then ack the disable and the reset like a real modem
		at_tr_reset_stuck.write = (data) => {
			let cmd = trim(data);

			push(at_tr_reset_stuck.written, cmd);
			uloop.timer(1, () => at_tr_reset_stuck.data_cb(cmd == 'AT+QESIM="lpa_enable"'
				? '+QESIM: "lpa_enable", 1\r\n\r\nOK\r\n' : 'OK\r\n'));

			return length(data);
		};
	},
}, 'registered',
	(modem, mock, events) => {
		ok(index(at_tr_reset_stuck.written, 'AT+CFUN=1,1') >= 0,
			'no-reenum: the reset was issued and acknowledged');
		eq(modem.state, 'READY',
			'no-reenum: init resumes instead of parking in INIT_SERVICES');
		let w = filter(modem.config_warnings, (e) => e.check == 'init_reset');
		eq(length(w), 1,
			'no-reenum: the unapplied setting is surfaced, not just logged once');
	});

// THE UNAPPLIED-RESET DEBT DOES NOT ACCUMULATE ACROSS RETRIES.
//
// It is carried on `self` on purpose: the object lives for one device attach
// (daemon.uc:1671), so a modem that really did reset comes back as a NEW
// instance with no debt, and a re-init of THIS one means it did not. But
// re-init on the same instance is exactly what the failure path does —
// make_fail arms `uloop.timer(backoff, () => self.start())` (modem.uc:1362) —
// so an un-deduplicated push grows one entry per pass and repeats the warning
// as often. Raised by Codex review, 2026-09-19.
//
// Setup: the eSIM quirk requests a reset, the modem refuses it (debt recorded,
// init continues), then the datapath finds no QMAP support and the pass fails.
// The scenario ends on the SECOND such failure, i.e. after two full passes.

let at_tr_debt = fake_at_transport();
at_tr_debt.write = (data) => {
	let cmd = trim(data);

	push(at_tr_debt.written, cmd);
	uloop.timer(1, () => at_tr_debt.data_cb(
		cmd == 'AT+QESIM="lpa_enable"' ? '+QESIM: "lpa_enable", 1\r\n\r\nOK\r\n' :
		cmd == 'AT+CFUN=1,1'           ? 'ERROR\r\n' : 'OK\r\n'));

	return length(data);
};

scenario('init-reset-debt-dedup', {
	handlers: base_handlers({
		GET_MODEL: { model: 'RG650E-EU' },
		SET_DATA_FORMAT: (args, meta) => ({
			qos: 0, llp: 2, ul_protocol: 0, dl_protocol: 0,
			dl_max_datagrams: 0, dl_max_size: 0,
		}),
	}),
	config: { tty: '/dev/ttyUSB2' },
	datapath: {
		netdev: 'wwan0', ep_id: 4, mux: 'auto',
		mux_links: [ { id: 1 } ], dgram_size: 0, fx: dpfx_noqmap,
	},
	until_nth: 2,
	at: {
		fx: fakefx.create(),
		open_transport: (path, baud, log) => at_tr_debt,
	},
}, 'error',
	(modem, mock, events) => {
		eq(length(filter(events, (e) => e.event == 'error')), 2,
			'debt-dedup: two init passes really happened');
		eq(length(modem._reset_unapplied ?? []), 1,
			'debt-dedup: the same unapplied reset is recorded once, not once per pass');
	});

// THE SERVING MNC CARRIES ITS WIDTH.
//
// It arrives as a bare integer, so 310/030 and 310/30 — different operators —
// are the same number here and the operator line rendered whichever a fixed
// %02d produced. The modem says which in its own TLV (libqmi 1.38: Get Serving
// System output 0x27, and 0x29 in the indication, which is a different id).
// Found by a full review, 2026-09-19.

scenario('serving-mnc-width', {
	handlers: base_handlers({
		GET_SERVING_SYSTEM: {
			serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
				selected_network: 1, radio_ifs: [ 8 ] },
			roaming: 0,
			current_plmn: { mcc: 310, mnc: 30, description: 'AT&T MVNO' },
			mnc_pcs_digit: { mcc: 310, mnc: 30, includes_pcs_digit: 1 },
		},
	}),
}, 'registered',
	(modem, mock, events) => {
		eq(modem.reg.plmn.mnc, 30, 'mnc-width: the number is unchanged...');
		eq(modem.reg.plmn.mnc_digits, 3, '...and it is declared as three digits');
	});

// ...AND AN UPDATE THAT OMITS THE TLV DOES NOT RETRACT IT. Serving-system
// indications repeat the same PLMN constantly and the qualifier is optional,
// so taking the new object wholesale dropped a width the GET had established
// and the operator line flipped back on the next indication. Raised by Codex
// review, 2026-09-19.
scenario('serving-mnc-width-kept', {
	handlers: base_handlers({
		GET_SERVING_SYSTEM: {
			serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
				selected_network: 1, radio_ifs: [ 8 ] },
			roaming: 0,
			current_plmn: { mcc: 310, mnc: 30, description: 'AT&T MVNO' },
			mnc_pcs_digit: { mcc: 310, mnc: 30, includes_pcs_digit: 1 },
		},
	}),
}, 'registered',
	(modem, mock, events) => {
		eq(modem.reg.plmn.mnc_digits, 3, 'mnc-width: established by the GET');

		// the same PLMN again, this time without the optional qualifier
		modem._update_serving({
			serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
				selected_network: 1, radio_ifs: [ 8 ] },
			roaming: 0,
			current_plmn: { mcc: 310, mnc: 30, description: 'AT&T MVNO' },
		});

		eq(modem.reg.plmn.mnc_digits, 3,
			'mnc-width: an update that says nothing does not retract it');
	});

// ...and a modem that says nothing leaves the field absent rather than guessing
scenario('serving-mnc-width-absent', {
	handlers: base_handlers({
		GET_SERVING_SYSTEM: {
			serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
				selected_network: 1, radio_ifs: [ 8 ] },
			roaming: 0,
			current_plmn: { mcc: 262, mnc: 1, description: 'Telekom.de' },
		},
	}),
}, 'registered',
	(modem, mock, events) => {
		eq(modem.reg.plmn.mnc_digits, null,
			'mnc-width: no TLV, no claim — the formatter falls back');
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

// A CELL LOCK THE CONFIG NO LONGER ASKS FOR IS RELEASED.
//
// cell_lock_commands() only ever emits a lock when one is CONFIGURED, so
// deleting `lock_4g` left the modem locked forever — nothing was sent, and it
// kept searching for a cell that may not be there. With `lock_persist` the lock
// sits in modem NV and survives reboots and AT+CFUN, so the box could not be
// recovered by editing the config at all. HW-found on an NR7101 locked to
// EARFCN 1300 / PCI 246, a cell not receivable at that site: permanent
// "servingcell","SEARCH", +CGATT: 0. Releasing it attached within seconds on
// EARFCN 6300 (2026-09-11).
//
// This transport answers the lock READ with an enabled lock and everything else
// with OK, so the scenario is "config says no lock, modem says locked".
function fake_at_locked()
{
	let self = { written: [], data_cb: null };

	self.write = (data) => {
		let cmd = trim(data);
		push(self.written, cmd);

		uloop.timer(1, () => self.data_cb(
			(cmd == 'AT+QNWLOCK="common/4g"')
				? '+QNWLOCK: "common/4g",1,1300,246\r\nOK\r\n'
				: 'OK\r\n'));

		return length(data);
	};
	self.on_data = (cb) => { self.data_cb = cb; };
	self.drain = () => null;
	self.close = () => null;

	return self;
}

let at_tr_stale = fake_at_locked();

scenario('lock-released', {
	handlers: base_handlers({
		GET_MODEL: { model: 'RG650E-EU' },
		SET_SYSTEM_SELECTION_PREFERENCE: {},
		GET_SYSTEM_SELECTION_PREFERENCE: { mode_preference: 1 << 4, network_selection: 0 },
	}),
	// NO lock_4g / lock_5g in the config — that is the whole point
	config: { modes: 'lte', tty: '/dev/ttyUSB2' },
	at: {
		fx: fakefx.create(),
		open_transport: (path, baud, log) => at_tr_stale,
	},
}, 'registered',
	(modem, mock, events) => {
		ok(index(at_tr_stale.written, 'AT+QNWLOCK="common/4g"') >= 0,
			'lock-released: the modem is asked whether it carries a lock');
		ok(index(at_tr_stale.written, 'AT+QNWLOCK="common/4g",0') >= 0,
			'lock-released: and the lock it reports is switched off');
		ok(index(at_tr_stale.written, 'AT+QNWLOCK="save_ctrl",1,1') >= 0,
			'lock-released: the release is persisted — the old one may be in NV');

		// the modem must still come up; a release is not a failure
		eq(modem.state, 'READY', 'lock-released: the modem reaches READY');
	});

// ...and a modem that reports NO lock is not written to at all. Read-before-
// write is the rule everywhere else in this tree and a needless NV write per
// start is exactly what it exists to prevent.
let at_tr_clean = fake_at_transport();

scenario('lock-absent-no-write', {
	handlers: base_handlers({
		GET_MODEL: { model: 'RG650E-EU' },
		SET_SYSTEM_SELECTION_PREFERENCE: {},
		GET_SYSTEM_SELECTION_PREFERENCE: { mode_preference: 1 << 4, network_selection: 0 },
	}),
	config: { modes: 'lte', tty: '/dev/ttyUSB2' },
	at: {
		fx: fakefx.create(),
		open_transport: (path, baud, log) => at_tr_clean,
	},
}, 'registered',
	(modem, mock, events) => {
		ok(index(at_tr_clean.written, 'AT+QNWLOCK="common/4g"') >= 0,
			'lock-absent: still asked');
		eq(index(at_tr_clean.written, 'AT+QNWLOCK="common/4g",0'), -1,
			'lock-absent: nothing switched off — there was nothing to switch off');
		eq(index(at_tr_clean.written, 'AT+QNWLOCK="save_ctrl",1,1'), -1,
			'lock-absent: and no NV write');
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

// --- 14: unsolicited indications — NITZ network time + DSD data-system --------
// The modem advertises DSD (service 0x2A) so self.dsd is allocated and the
// SYSTEM_STATUS_CHANGE register + SYSTEM_STATUS_IND handler are wired. During
// REGISTERING we deliver a NITZ Network-Time indication and a DSD system-status
// indication (LTE+5G = NSA), then the registered serving-system indication to
// complete. Both indications round-trip through the real schema pack/unpack.
scenario('indications', {
	handlers: base_handlers({
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 60 },
			{ service: 2, major: 1, minor: 14 },
			{ service: 3, major: 1, minor: 25 },
			{ service: 11, major: 1, minor: 22 },
			{ service: 26, major: 1, minor: 16 },
			{ service: 42, major: 1, minor: 0 },   // DSD (0x2A)
		] },
		GET_SERVING_SYSTEM: (args, meta) => ({
			serving_system: { registration: 2, cs_attach: 0, ps_attach: 0,
			                  selected_network: 0, radio_ifs: [] },
		}),
		SYSTEM_STATUS_CHANGE: {},
		SET_EVENT_REPORT: {},
		GET_SYSTEM_STATUS: { available_systems: [ { technology: 1, rat: 3, so_mask: 0 } ] },
	}),
	setup: (mock, modem) => {
		let poll = null;
		poll = uloop.timer(20, () => {
			if (modem.state == 'REGISTERING' && modem.nas && modem.dsd) {
				// operator-pushed clock: 2026-07-27 13:45:09 UTC, +120 min, DST 1h
				mock.indicate(3, modem.nas.cid, 'NETWORK_TIME_IND', {
					universal_time: { year: 2026, month: 7, day: 27,
					                  hour: 13, minute: 45, second: 9, day_of_week: 1 },
					timezone_offset: 8,
					dst_adjustment: 1,
					radio_interface: 8,
				});
				// data-system: LTE + 5G present -> NSA
				mock.indicate(42, modem.dsd.cid, 'SYSTEM_STATUS_IND', {
					available_systems: [
						{ technology: 1, rat: 3, so_mask: 0 },
						{ technology: 1, rat: 6, so_mask: 0 },
					],
				});
				// NAS event report: RF band change. libqmi types Active Channel as
				// guint16, so the values here stay in u16 range (LTE band 3 earfcn
				// 1300, NR band 78 with a u16-fitting channel).
				mock.indicate(3, modem.nas.cid, 'EVENT_REPORT_IND', {
					rf_band_info: [
						{ radio_interface: 8, band: 3, channel: 1300 },
						{ radio_interface: 12, band: 78, channel: 62000 },
					],
				});
				// DMS event report: baseline (online) then an external switch to
				// offline -> handler logs the change and tracks _dms_opmode.
				mock.indicate(2, modem.dms.cid, 'EVENT_REPORT_IND', { operating_mode: 0 });
				mock.indicate(2, modem.dms.cid, 'EVENT_REPORT_IND', { operating_mode: 3 });
				// UIM refresh completed -> handler re-reads identity, emits sim_refresh
				mock.indicate(11, modem.uim.cid, 'REFRESH_IND', {
					event: { stage: 2, mode: 1, session_type: 0 },
				});
				// then complete registration
				mock.indicate(3, modem.nas.cid, 'SERVING_SYSTEM_IND', {
					serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
					                  selected_network: 1, radio_ifs: [ 8, 12 ] },
					current_plmn: { mcc: 262, mnc: 1, description: 'Telekom.de' },
				});
				return;
			}

			poll.set(20);
		});
	},
}, 'registered',
	(modem, mock, events) => {
		// NITZ: schema decode + nitz_epoch + handler stored the time
		ok(modem.network_time != null, 'ind: network_time captured');
		eq(modem.network_time.epoch,
			timegm({ year: 2026, mon: 7, mday: 27, hour: 13, min: 45, sec: 9 }),
			'ind: NITZ epoch decoded (UTC, 1-based month)');
		eq(modem.network_time.tz_offset_min, 120, 'ind: tz offset 8*15 = 120 min');
		eq(modem.network_time.dst, 1, 'ind: dst adjustment carried');
		// DSD: SYSTEM_STATUS_CHANGE registered + SYSTEM_STATUS_IND -> NSA live
		ok(length(mock.calls_for('SYSTEM_STATUS_CHANGE')) >= 1, 'ind: dsd indication registered');
		eq(modem.dsd_status.mode, 'NSA', 'ind: dsd system-status IND -> NSA');
		eq(modem.dsd_status.source, 'dsd', 'ind: dsd_status source tagged dsd');
		ok(modem.dsd_status.nr && modem.dsd_status.lte, 'ind: NSA = lte+nr');
		// NAS event report: SET_EVENT_REPORT armed + RF band decoded live
		ok(length(mock.calls_for('SET_EVENT_REPORT')) >= 1, 'ind: nas event report armed');
		ok(modem.rf_bands != null && length(modem.rf_bands) == 2, 'ind: rf band list decoded');
		eq(modem.rf_bands[0].band, 3, 'ind: lte band 3');
		eq(modem.rf_bands[0].channel, 1300, 'ind: lte earfcn 1300');
		eq(modem.rf_bands[1].band, 78, 'ind: nr band 78');
		eq(modem.rf_bands[1].channel, 62000, 'ind: nr channel (u16)');
		// DMS event report: external opmode change tracked (baseline 0 -> 3)
		ok(length(mock.calls_for('SET_EVENT_REPORT')) >= 1, 'ind: dms event report armed');
		eq(modem._dms_opmode, 3, 'ind: dms external opmode change tracked (offline)');
		// UIM refresh: register sent + REFRESH_IND decoded without error (the
		// END_SUCCESS re-read + sim_refresh emit are async and complete after
		// registration, so they are not asserted here — the register + clean
		// decode prove the schema and wiring).
		// SIM_BUSY carries one byte PER SLOT, so the handler has to know which
		// slot is in use. With none known, a MULTI-slot indication is dropped
		// rather than attributed to slot 1 — that guess would reach the status
		// page as a fact. A single-entry one is unambiguous whatever the slot is
		// numbered, and still counts.
		// dispatched directly rather than through mock.indicate(), which is
		// asynchronous — this exercises the same handler synchronously
		let busy_ind = (arr) => modem.uim.dispatch({
			kind: 'indication', msg_id: 0x004A,
			tlvs: chr(0x10) + chr(length(arr) + 1) + chr(0) + chr(length(arr)) +
			      join('', map(arr, (b) => chr(b))),
		});

		modem.active_slot = null;
		modem.config.sim_slot = null;
		modem.sim_busy = false;
		// slot 1 BUSY, slot 2 idle, and nothing knows which is in use. The old
		// code defaulted to slot 1 and reported busy — a coin toss that reaches
		// the status page as a fact. (The reverse order is not discriminating:
		// it reads false either way.)
		busy_ind([ 1, 0 ]);
		eq(modem.sim_busy, false, 'ind: a two-slot busy with no known active slot is not guessed');

		busy_ind([ 1 ]);
		eq(modem.sim_busy, true, 'ind: a single-slot busy needs no slot to be known');

		// ...and once the active slot IS known, the right byte is read
		modem.sim_busy = false;
		modem.active_slot = 2;
		busy_ind([ 0, 1 ]);
		eq(modem.sim_busy, true, 'ind: with slot 2 active, slot 2\'s byte is the one read');

		busy_ind([ 1, 0 ]);
		eq(modem.sim_busy, false, 'ind: ...not slot 1\'s');

		ok(length(mock.calls_for('REFRESH_REGISTER_ALL')) >= 1, 'ind: uim refresh registered');
		ok(modem._uim_refresh_armed === true, 'ind: uim refresh handler armed');

		// vote_for_init is deliberately NOT sent: voting asks the card to
		// consult us first, and every way the reply can be lost turns a brief
		// session interruption into the card waiting out its own timeout.
		let rr = mock.calls_for('REFRESH_REGISTER_ALL')[0];
		eq(rr.args.vote, null, 'ind: we do not ask the card to wait for us');

		// The handlers live ON THE CLIENT, so a teardown must clear the "already
		// installed" flag — otherwise a retry rebuilds the modem with a NEW uim
		// client and none of the card diagnostics, refresh handling or long-APDU
		// reassembly attached. Silently, because everything works except the
		// parts that only fire when something goes wrong.
		modem.teardown();
		eq(modem._uim_refresh_armed, false, 'teardown: uim handlers can be installed again');
		// card-side diagnostics belong to the card we were talking to; a
		// transient busy left set would survive the reconnect and keep claiming
		// the reads are failing long after they stopped
		eq(modem.sim_busy, false, 'teardown: the card diagnostics are cleared');
		eq(modem.sim_note, null, 'teardown: ...including the last card event');
		eq(modem.active_slot, null, 'teardown: and the remembered active slot');

		// same class, and these two predate the UIM work: both guard an install
		// on a client teardown destroys, so a stale flag silently cost the
		// RF-band push and the DSD data-mode push for the rest of the run
		eq(modem._nas_evt_armed, false, 'teardown: the nas event report is re-armable');
		eq(modem._dsd_ind_armed, false, 'teardown: so is the dsd indication');
		// WMS is the worst of the family: allocated lazily on the first SMS op
		// and cached, so a stale flag handed every later SMS a client bound to a
		// hub that is closed, with no way back
		eq(modem._wms_tried, false, 'teardown: wms can be allocated again');
		eq(modem.wms, null, 'teardown: and the stale wms client is gone');
		eq(modem.cat, null, 'teardown: the toolkit client too');
		eq(modem._apdu_long, null, 'teardown: the reassembly table is cleared with them');
		eq(modem.thermal, null, 'teardown: thermal readings do not outlive their client');
		ok(modem._gen > 0, 'teardown: the lifecycle generation advanced');
	});

// --- 15: UIM refresh END_SUCCESS drives an async identity re-read -------------
// Modem reaches READY normally, then a Refresh indication (stage END_SUCCESS)
// arrives; the handler re-reads identity and emits sim_refresh. Waiting on that
// event exercises the full async re-read path the scenario-14 verify runs too
// early to see.
scenario('sim-refresh', {
	handlers: base_handlers(),
	setup: (mock, modem) => {
		let poll = null;
		poll = uloop.timer(15, () => {
			if (modem.state == 'READY' && modem.uim) {
				mock.indicate(11, modem.uim.cid, 'REFRESH_IND',
					{ event: { stage: 2, mode: 1, session_type: 0 } });
				return;
			}
			poll.set(15);
		});
	},
}, 'sim_refresh',
	(modem, mock, events) => {
		let ev = filter(events, function(e) { return e.event == 'sim_refresh' });
		ok(length(ev) >= 1, 'sim-refresh: sim_refresh event emitted after re-read');
		eq(modem.info.iccid, '89490200001022832490', 'sim-refresh: iccid re-read');
		eq(modem.info.imsi, '262011234567890', 'sim-refresh: imsi re-read');
	});

run_next();
// --- 16: FCC-RF-locked modem — auto unlock chain ------------------------------
// The modem accepts set-online but reports persistent low power until an FCC
// authentication message arrives. Auto mode first tries the argument-less DMS
// 0x555F; the mock rejects it (like a Foxconn device would) and accepts the
// Foxconn 0x5571 variant, after which the mode goes online.

let fcc_unlocked = false;

scenario('fcc-unlock', {
	handlers: base_handlers({
		GET_OPERATING_MODE: () => ({ mode: fcc_unlocked ? 0 : 6 }),
		SET_FCC_AUTHENTICATION: { __error: 0x0019 },   // NotSupported
		// the v1/v2 foxconn messages share id 0x5571 — mockhub's id->name map
		// resolves to the LAST entry (V2), so register the handler under both
		FOXCONN_SET_FCC_AUTHENTICATION: (args) => { fcc_unlocked = true; return {}; },
		FOXCONN_SET_FCC_AUTHENTICATION_V2: (args) => { fcc_unlocked = true; return {}; },
	}),
}, 'registered',
	(modem, mock, events) => {
		eq(modem.state, 'READY', 'fcc: state READY after unlock');
		eq(fcc_unlocked, true, 'fcc: foxconn authentication message sent');
		eq(length(mock.calls_for('SET_FCC_AUTHENTICATION')), 1, 'fcc: dms variant tried first');
		eq(length(mock.calls_for('FOXCONN_SET_FCC_AUTHENTICATION')) +
		   length(mock.calls_for('FOXCONN_SET_FCC_AUTHENTICATION_V2')), 1, 'fcc: foxconn variant tried once');
		// set-online: the initial attempt + one after the successful unlock
		ok(length(mock.calls_for('SET_OPERATING_MODE')) >= 2, 'fcc: re-set online after unlock');
	});

// --- 17: fcc_auth off — locked modem is NOT poked -----------------------------

scenario('fcc-off', {
	handlers: base_handlers({
		// stays low-power; with fcc_auth off the chain logs and continues,
		// bring-up then proceeds (registration works in the mock regardless)
		GET_OPERATING_MODE: { mode: 6 },
	}),
	config: { fcc_auth: 'off' },
}, 'registered',
	(modem, mock, events) => {
		eq(length(mock.calls_for('SET_FCC_AUTHENTICATION')), 0, 'fcc-off: no dms fcc message');
		eq(length(mock.calls_for('FOXCONN_SET_FCC_AUTHENTICATION')) +
		   length(mock.calls_for('FOXCONN_SET_FCC_AUTHENTICATION_V2')), 0, 'fcc-off: no foxconn fcc message');
	});

// --- UIM: a teardown while REGISTER_EVENTS is pending must not send again -----
// Same lesson as the CAT release, one layer up. Destroying the client reports
// `cancelled` to the pending callback SYNCHRONOUSLY, and reading that as "the
// modem refused the wide mask" fired the card-status fallback down a client
// mid-destruction: a send that escapes teardown, and a timer that outlives the
// pending table it should have been cancelled with.
//
// A null handler leaves REGISTER_EVENTS pending forever. Init does not wait on
// it, so the modem still reaches READY with the request in flight — which is
// exactly the state we need, and with a LIVE hub (a device-gone teardown would
// not expose this, the hub is already closed there).
scenario('uim-events-teardown', {
	handlers: base_handlers({ REGISTER_EVENTS: () => null }),
}, 'registered',
	(modem, mock, events) => {
		let sent = length(mock.calls_for('REGISTER_EVENTS'));
		eq(sent, 1, 'uim-events: the wide mask went out once and is still pending');

		modem.teardown();

		eq(length(mock.calls_for('REGISTER_EVENTS')), sent,
			'uim-events: a cancelled registration is not a refusal, so no fallback is sent');
	});

// --- CAT: a teardown while RELEASE_CID is in flight must not resume init ------
// RELEASE_CID is asynchronous. A teardown starting while it is pending destroys
// CTL FIRST, which reports `cancelled` to the release callback synchronously —
// so a continuation there resumed the old init chain into _read_info() while
// teardown was still running, and could schedule work past teardown's
// timer-cancellation pass, overlapping the retry that follows.
//
// The mock swallows RELEASE_CID (a null handler withholds the reply), so the
// release is still pending when we tear down.
scenario('cat-release-teardown', {
	handlers: base_handlers({
		// CAT (0x0A = 10) has to be advertised or the whole path is skipped
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 60 },
			{ service: 2, major: 1, minor: 14 },
			{ service: 3, major: 1, minor: 25 },
			{ service: 10, major: 1, minor: 22 },
			{ service: 11, major: 1, minor: 22 },
			{ service: 26, major: 1, minor: 16 },
		] },
		GET_CONFIGURATION: { mode: 2 },       // differs from 'disabled' -> a SET runs
		SET_CONFIGURATION: {},
		RELEASE_CID: () => null,              // never answered
	}),
	config: { cat_mode: 'disabled' },
	// wait until the release is genuinely IN FLIGHT (sent, and swallowed by the
	// null handler), then make the device vanish — which is a real teardown,
	// with CTL destroyed first, exactly the ordering under test
	setup: (mock, modem) => {
		let poll = null;

		poll = uloop.timer(10, () => {
			if (length(mock.calls_for('RELEASE_CID')) >= 1) {
				mock.calls_at_teardown = length(mock.calls);
				mock.trigger_gone();
				return;
			}

			poll.set(10);
		});
	},
}, 'removed',
	(modem, mock, events) => {
		ok(length(mock.calls_for('SET_CONFIGURATION')) >= 1,
			'cat: the toolkit mode was applied');
		ok(mock.calls_at_teardown != null,
			'cat: the release was in flight when the device went away');

		// Nothing may be issued after that point. The release callback fires
		// with `cancelled` while teardown destroys CTL, and continuing there
		// would resume the init chain into _read_info() on a modem that is
		// being torn down — and schedule work past teardown's timer cancel.
		// THE assertion. Without the generation check inside the release
		// callback, the cancelled release resumed the init chain — which then
		// ran against nulled clients, failed, and retried: seven `error` events
		// where a clean teardown produces none. Counting mock traffic does NOT
		// catch this (the resumed requests never reach the mock, because the
		// clients they would go through are already gone), which is why the
		// observable is the retry storm rather than the wire.
		eq(length(filter(events, (e) => e.event == 'error')), 0,
			'cat: a cancelled release does not restart the init chain');
		eq(modem.cat, null, 'cat: the client is gone with the rest');
	});

// --- a settle timer must not outlive its incarnation --------------------------
//
// reattach bounces the radio: set_opmode(low_power) -> wait `settle` ->
// set_opmode(online). The wait was an ANONYMOUS uloop.timer, so teardown's
// `for (let t in values(tm))` could not reach it; opmode_cycle and reapply_sim
// did park theirs in tm but re-armed AFTER the cancel pass, because destroying
// the clients delivers a synchronous `cancelled` that their set_opmode callback
// ignored. Either way the timer fires with self.dms already null
// (modem.uc:1331) and qmi_backend.set_opmode dereferences it unguarded
// (qmi_backend.uc:66) — a throw inside a uloop callback, which kills the daemon
// and has procd respawn it. Found by a full review, 2026-09-19.
//
// The proof is the run itself: with the guard removed this scenario does not
// fail a check, it ends the suite mid-run with the dereference — exactly what
// the daemon does. `reattach_err` carries the positive half.
let reattach_err = 'never called';

scenario('reattach-teardown', { handlers: base_handlers() }, 'registered',
	(modem, mock, events) => {
		// in flight when the harness stops the modem a moment later
		modem.reattach((err) => { reattach_err = err; });

		ok(length(mock.calls_for('SET_OPERATING_MODE')) >= 1,
			'reattach-teardown: the radio-off went out');
	});

uloop.run();

// A scenario chain that DIES reports success. mockhub die()s on a message no
// handler covers, that exception leaves the uloop callback, uloop.run() returns
// early — and the summary below still reads "0 failures" because no check ever
// failed. That is how this file quietly ran 83 of its 212 checks for a while,
// with nothing in the output to say so. The count is the only thing that knows.
ok(current == length(scenarios),
	sprintf('every scenario ran (%d of %d) — a chain that ends early is not a pass',
		current, length(scenarios)));

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

// uloop has ended, so the settle timer either fired or was retired — and if it
// fired into a torn-down modem we never got here at all.
eq(reattach_err?.error, 'cancelled',
	'reattach-teardown: the caller is told the session ended, not left hanging');

// --- teardown while the settle timer is already ARMED -------------------------
//
// The scenario harness cannot reach this state: it stops the modem
// synchronously right after verify(), while mockhub answers every request via
// uloop.timer(0), so the outer set_opmode callback — the one that arms the wait
// — can only run after the teardown. So this gets its own loop.
//
// It matters because the two halves fail differently. If the wait has NOT been
// armed yet, settle_after's entry check sees the stale generation and calls the
// continuation. If it HAS, teardown cancels the timer outright and its body
// never runs — so without settle_retire() neither fn() nor gone() fires and a
// ubus reattach waits for an answer that can no longer come. Raised by review,
// 2026-09-19.
{
	uloop.init();

	let mock = mockhub.create({ handlers: base_handlers() });
	let armed_err = 'never called';
	let armed_seen = false;
	let m;

	m = modem_mod.create({
		id: 'reattach-armed', device: '/dev/mock0', config: {},
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		at: { fx: fakefx.create() },
		timing: { ...TIMING, settle: 500 },   // long enough to still be waiting
		deps: {
			transport_open: mock.transport_open,
			log: (level, msg) => null,
			on_event: (mm, event, data) => {
				if (event != 'registered' || armed_seen)
					return;

				armed_seen = true;
				m.reattach((err) => { armed_err = err; });

				// let the radio-off answer land and the wait arm (mockhub
				// answers on uloop.timer(0)), THEN tear down.
				uloop.timer(20, () => {
					m.stop();
					uloop.timer(20, () => uloop.end());
				});
			},
		},
	});

	m.start();
	uloop.timer(3000, () => uloop.end());
	uloop.run();

	ok(armed_seen, 'reattach-armed: the modem registered and reattach was issued');
	eq(armed_err?.error, 'cancelled',
		'reattach-armed: a wait cancelled by teardown still answers its caller');
}

// --- two waits in flight at once ---------------------------------------------
//
// `tm.settle` is a SHARED one-shot slot, written by the init chain too
// (modem_init_qmi.uc:323, :383, :604). Parking radio-bounce waits there let a
// second overwrite the first: teardown cancelled only the newest, the older
// timer survived unreachable, and whichever body ran first cleared the other's
// debt — so one of the two callers hung. Nothing serialises reattach, so two
// ubus calls reach this directly. Raised by review, 2026-09-19.
{
	uloop.init();

	let mock = mockhub.create({ handlers: base_handlers() });
	let errs = [];
	let issued = false;
	let m;

	m = modem_mod.create({
		id: 'reattach-overlap', device: '/dev/mock0', config: {},
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		at: { fx: fakefx.create() },
		timing: { ...TIMING, settle: 500 },
		deps: {
			transport_open: mock.transport_open,
			log: (level, msg) => null,
			on_event: (mm, event, data) => {
				if (event != 'registered' || issued)
					return;

				issued = true;
				m.reattach((err) => push(errs, err?.error ?? 'ok'));
				m.reattach((err) => push(errs, err?.error ?? 'ok'));

				uloop.timer(30, () => {
					m.stop();
					uloop.timer(20, () => uloop.end());
				});
			},
		},
	});

	m.start();
	uloop.timer(3000, () => uloop.end());
	uloop.run();

	eq(length(errs), 2, 'overlap: BOTH callers are answered, neither is orphaned');
	eq(errs, [ 'cancelled', 'cancelled' ], 'overlap: ...and both are told the session ended');
}

// --- a continuation that throws must not disable retries forever -------------
//
// Paying the owed continuations is the one place teardown runs code it does not
// own. Unguarded, a throw there skips the `_teardown_depth--` at the end, the
// counter stays raised for the life of the object, and make_fail then refuses
// to arm ANY future retry — a worse failure than the hang it pays off. Raised
// by review, 2026-09-19.
{
	uloop.init();

	let mock = mockhub.create({ handlers: base_handlers() });
	let issued = false;
	let m;

	m = modem_mod.create({
		id: 'reattach-throwing-cb', device: '/dev/mock0', config: {},
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		at: { fx: fakefx.create() },
		timing: { ...TIMING, settle: 500 },
		deps: {
			transport_open: mock.transport_open,
			log: (level, msg) => null,
			on_event: (mm, event, data) => {
				if (event != 'registered' || issued)
					return;

				issued = true;
				m.reattach((err) => { die('a caller callback that throws'); });

				uloop.timer(30, () => {
					m.stop();
					uloop.timer(20, () => uloop.end());
				});
			},
		},
	});

	m.start();
	uloop.timer(3000, () => uloop.end());
	uloop.run();

	ok(issued, 'throwing-cb: the modem registered and reattach was issued');
	eq(m._teardown_depth, 0,
		'throwing-cb: the depth is back to zero, so future retries still work');
}

// --- ...and it must not strand the continuations queued behind it ------------
//
// The guard above was one `try` around the WHOLE walk, which fixed the depth
// and left the rest of the queue unpaid: the first thrower unwound out of the
// loop, and every continuation after it had its timer cancelled and its caller
// never answered — the exact hang the walk exists to prevent, now for everyone
// but the first. The guard belongs inside the loop. Found by review,
// 2026-09-20.
{
	uloop.init();

	let mock = mockhub.create({ handlers: base_handlers() });
	let issued = false;
	let second = null;
	let m;

	m = modem_mod.create({
		id: 'reattach-throwing-first', device: '/dev/mock0', config: {},
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		at: { fx: fakefx.create() },
		timing: { ...TIMING, settle: 500 },
		deps: {
			transport_open: mock.transport_open,
			log: (level, msg) => null,
			on_event: (mm, event, data) => {
				if (event != 'registered' || issued)
					return;

				issued = true;

				// TWO waits, and the FIRST one throws. Order matters: the
				// second is the one that used to be lost.
				m.reattach((err) => { die('a caller callback that throws'); });
				m.reattach((err) => { second = err?.error ?? 'answered'; });

				uloop.timer(30, () => {
					m.stop();
					uloop.timer(20, () => uloop.end());
				});
			},
		},
	});

	m.start();
	uloop.timer(3000, () => uloop.end());
	uloop.run();

	ok(issued, 'throwing-first: two reattach waits were issued');
	eq(second, 'cancelled',
		'throwing-first: the second caller is still answered after the first threw');
	eq(m._teardown_depth, 0,
		'throwing-first: ...and the depth still came back down');
}

// --- the depth has to cover the callbacks teardown itself runs ---------------
//
// `_teardown_depth` is what stops make_fail from arming a retry, or re-entering
// teardown, while a teardown is in progress. It was decremented up beside the
// client destruction — and BELOW that line teardown still calls callers' code:
// the PDC waiters and the long-APDU reassembly, each of which can reach the
// shared failure ladder. Those callbacks therefore ran with the guard already
// lowered, which is precisely when it was supposed to be up. Found by review,
// 2026-09-20.
{
	uloop.init();

	let mock = mockhub.create({ handlers: base_handlers() });
	let seen = null;
	let m;

	m = modem_mod.create({
		id: 'pdc-depth', device: '/dev/mock0', config: {},
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		at: { fx: fakefx.create() },
		timing: { ...TIMING },
		deps: {
			transport_open: mock.transport_open,
			log: () => null,
			on_event: (mm, event) => {
				if (event != 'registered' || seen != null)
					return;

				// a PDC waiter that records what the guard said when teardown
				// cancelled it
				m._pdc_waits = m._pdc_waits ?? {};
				m._pdc_waits['probe'] = {
					timer: { cancel: () => null },
					cb: () => { seen = m._teardown_depth; },
				};

				uloop.timer(20, () => { m.stop(); uloop.timer(20, () => uloop.end()); });
			},
		},
	});

	m.start();
	uloop.timer(3000, () => uloop.end());
	uloop.run();

	ok(seen != null, 'pdc-depth: the waiter was cancelled by the teardown');
	ok(seen >= 1, 'pdc-depth: ...and saw the teardown guard still raised');
	eq(m._teardown_depth, 0, 'pdc-depth: the guard comes back down afterwards');
}

// --- ...and a throw anywhere in the teardown must still balance it -----------
//
// The per-callback guards keep one caller's throw from stranding the next. They
// do NOT balance `_teardown_depth`: the work BETWEEN them can throw too, and a
// throw that escapes the function skips the decrement, leaving the guard raised
// for the life of the object — which disables every future retry. ucode has no
// `finally`, so the body is wrapped. Here the waiter table holds a SCALAR,
// which makes `w.timer?.cancel()` read a property off a number and throw
// exactly where no per-callback guard sits. Found by review, 2026-09-20.
{
	uloop.init();

	let mock = mockhub.create({ handlers: base_handlers() });
	let armed = false;
	let m;

	m = modem_mod.create({
		id: 'teardown-throws-outside', device: '/dev/mock0', config: {},
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		at: { fx: fakefx.create() },
		timing: { ...TIMING },
		deps: {
			transport_open: mock.transport_open,
			log: () => null,
			on_event: (mm, event) => {
				if (event != 'registered' || armed)
					return;

				armed = true;
				m._pdc_waits = { hostile: 7 };   // not an object with .timer/.cb

				uloop.timer(20, () => { m.stop(); uloop.timer(20, () => uloop.end()); });
			},
		},
	});

	m.start();
	uloop.timer(3000, () => uloop.end());
	uloop.run();

	ok(armed, 'teardown-throws: the hostile waiter table was installed');
	eq(m._teardown_depth, 0,
		'teardown-throws: the depth came back down even so, so retries still work');
}

// --- a plugin's own service client (modem.extra_client) ---------------------
//
// A plugin brings a schema the core does not know and gets a client on the
// modem's channel. The modem owns it: teardown must RELEASE its CID like the
// core's own clients, because the plugin cannot see the teardown coming and a
// CID left allocated sits in the modem's client table until the stack resets.
{
	uloop.init();

	const XSVC = {
		service: 0x32,
		messages: {
			PING:    { id: 0x0020, req: {}, resp: {} },
			EVT_IND: { id: 0x0023, ind: { slot: { t: 0x01, f: 'u32' } } },
		},
	};
	let vi = { services: [
		{ service: 1, major: 1, minor: 60 }, { service: 2, major: 1, minor: 14 },
		{ service: 3, major: 1, minor: 25 }, { service: 11, major: 1, minor: 22 },
		{ service: 26, major: 1, minor: 16 },
	] };
	let run = (with_svc, body) => {
		let vi2 = { services: [ ...vi.services, ...(with_svc ? [ { service: 0x32, major: 1, minor: 5 } ] : []) ] };
		let mock = mockhub.create({ handlers: base_handlers({ GET_VERSION_INFO: vi2, PING: {} }),
		                            schemas: [ XSVC ] });
		let m;
		let done_once = false;

		m = modem_mod.create({
			id: 'extra', device: '/dev/mock0', config: {},
			recovery: { fx: fakefx.create(), state_dir: '/state' },
			at: { fx: fakefx.create() },
			timing: TIMING,
			deps: {
				transport_open: mock.transport_open,
				log: (level, msg) => null,
				on_event: (mm, event) => {
					if (event != 'registered' || done_once)
						return;
					done_once = true;
					body(m, mock);
				},
			},
		});
		m.start();
		// cancelled after the run: a guard timer left armed would end the NEXT
		// block's loop early, before its modem has registered
		let guard = uloop.timer(3000, () => uloop.end());
		uloop.run();
		guard.cancel();
		return done_once;
	};

	let got = {};

	run(true, (m, mock) => {
		m.extra_client(XSVC, (err, c) => {
			got.err = err;
			got.c = c;
			if (!c)
				return uloop.end();
			c.on('EVT_IND', (d) => { got.ind = d.slot; });
			c.request('PING', {}, (e) => {
				got.ping = e;
				mock.indicate(0x32, c.cid, 'EVT_IND', { slot: 1 });
				uloop.timer(20, () => {
					m.stop();
					uloop.timer(20, () => uloop.end());
				});
			});
		});
	});

	eq(got.err, null, 'extra client: allocated for a service the modem lists');
	eq(got.ping, null, 'extra client: its requests reach the modem');
	eq(got.ind, 1, 'extra client: and its indications reach the plugin');
	eq(got.c?.destroyed, true, 'extra client: teardown destroys it, so the plugin knows to allocate again');

	let got2 = {};

	run(false, (m, mock) => {
		m.extra_client(XSVC, (err, c) => {
			got2.err = err;
			got2.c = c;
			m.stop();
			uloop.timer(20, () => uloop.end());
		});
	});

	eq(got2.err?.error, 'service_unavailable',
		'extra client: a service missing from GET_VERSION_INFO is refused with the reason, not asked for');
	eq(got2.c, null, 'extra client: ...and no client');
}

// the RELEASE on teardown, checked on the wire
{
	uloop.init();

	const XSVC = { service: 0x32, messages: { PING: { id: 0x0020, req: {}, resp: {} } } };
	let mock = mockhub.create({ handlers: base_handlers({ GET_VERSION_INFO: { services: [
		{ service: 1, major: 1, minor: 60 }, { service: 2, major: 1, minor: 14 },
		{ service: 3, major: 1, minor: 25 }, { service: 11, major: 1, minor: 22 },
		{ service: 26, major: 1, minor: 16 }, { service: 0x32, major: 1, minor: 5 } ] } }),
		schemas: [ XSVC ] });
	let m, cid = null, released = null;

	m = modem_mod.create({
		id: 'extra-rel', device: '/dev/mock0', config: {},
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		at: { fx: fakefx.create() },
		timing: TIMING,
		deps: {
			transport_open: mock.transport_open,
			log: (level, msg) => null,
			on_event: (mm, event) => {
				if (event != 'registered' || cid != null)
					return;
				m.extra_client(XSVC, (err, c) => {
					cid = c?.cid;
					m.stop();
					uloop.timer(20, () => uloop.end());
				});
			},
		},
	});
	m.start();
	let guard = uloop.timer(3000, () => uloop.end());
	uloop.run();
	guard.cancel();

	for (let c in mock.calls)
		if (c.name == 'RELEASE_CID' && c.args?.release?.service == 0x32)
			released = c.args.release.cid;

	ok(cid != null, 'extra client release: a client was allocated');
	eq(released, cid, 'extra client release: teardown sent RELEASE_CID for the plugin\'s CID');

}

// a client given back twice while the modem runs is released ONCE: the
// second number may already belong to someone else (teardown released it, or
// the modem was replaced and numbers its CIDs afresh)
{
	uloop.init();

	const XSVC = { service: 0x32, messages: { PING: { id: 0x0020, req: {}, resp: {} } } };
	let mock = mockhub.create({ handlers: base_handlers({ GET_VERSION_INFO: { services: [
		{ service: 1, major: 1, minor: 60 }, { service: 2, major: 1, minor: 14 },
		{ service: 3, major: 1, minor: 25 }, { service: 11, major: 1, minor: 22 },
		{ service: 26, major: 1, minor: 16 }, { service: 0x32, major: 1, minor: 5 } ] } }),
		schemas: [ XSVC ] });
	let m, done_once = false;

	m = modem_mod.create({
		id: 'extra-twice', device: '/dev/mock0', config: {},
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		at: { fx: fakefx.create() },
		timing: TIMING,
		deps: {
			transport_open: mock.transport_open,
			log: (level, msg) => null,
			on_event: (mm, event) => {
				if (event != 'registered' || done_once)
					return;
				done_once = true;
				m.extra_client(XSVC, (err, c) => {
					m.extra_release(c);
					m.extra_release(c);
					uloop.timer(30, () => { m.stop(); uloop.timer(20, () => uloop.end()); });
				});
			},
		},
	});
	m.start();
	let guard = uloop.timer(3000, () => uloop.end());
	uloop.run();
	guard.cancel();

	eq(length(filter(mock.calls, (c) => c.name == 'RELEASE_CID' && c.args?.release?.service == 0x32)), 1,
	   'extra client: given back twice, released once');
}

done('test_modem');
