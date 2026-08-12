// wwand tests — MBIM SIM unlock: cold-boot init wait + verify-error semantics.
//
// Regression coverage for the GL-X3000/RM520N cold-boot bug: MBIM opens before
// the SIM (slot 2) is up, SUBSCRIBER_READY_STATUS answers NOT_INITIALIZED with
// no identity, and the old step_sim raced straight into the PIN query — the
// firmware reported "locked" for a PIN-disabled card mid-init, the ENTER came
// back as an error WITHOUT consuming a retry, and the modem landed in a
// terminal SIM_BLOCKED/verify_failed that only a wwand restart cleared.
//
// Scenarios (each on a fresh mock + modem):
//   A  ready_state 0 -> step_sim polls SUBSCRIBER_READY_STATUS (QMI card-poll
//      parity), picks up the late identity + per-SIM override, never touches
//      the PIN, reaches registered.
//   B  verify refused with NO retry consumed (the x1800 case, forced via
//      DEVICE_LOCKED + PIN ENTER erroring once) -> retriable failure, NOT
//      SIM_BLOCKED; the retry unlocks and reaches registered.
//   C  genuinely wrong PIN (re-query shows a burned retry) -> terminal
//      SIM_BLOCKED/verify_failed with the remaining count, exactly ONE ENTER.
//   D  verify reply lost but effective (re-query says unlocked) -> proceeds.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as mbim_mockhub from './lib/mbim_mockhub.uc';
import * as modem_mbim from 'wwand/modem_mbim.uc';
import * as bc from 'wwand/codec/mbim-schema/basic_connect.uc';
import * as ext from 'wwand/codec/mbim-schema/ms_basic_connect_ext.uc';

uloop.init();

const ICCID = '89490200001022832490';
const IMSI = '262011234567890';

// scenarios chain via `next` callbacks — forward-declare (ucode: no access to
// a lexical declaration before its statement ran)
let scenario_a, scenario_b, scenario_c, scenario_d;

function base_handlers() {
	return {
		DEVICE_CAPS: {
			device_type: 1, cellular_class: 1, voice_class: 1, sim_class: 2,
			data_class: 0x3f, sms_caps: 0, control_caps: 0, max_sessions: 8,
			custom_data_class: '', device_id: '359072060000000',
			firmware_info: 'RM520NGL', hardware_info: 'RM520N-GL',
		},
		SUBSCRIBER_READY_STATUS: {
			ready_state: bc.READY_STATE_INITIALIZED,
			subscriber_id: IMSI, sim_iccid: ICCID,
			ready_info: 0, telephone_numbers_count: 0,
		},
		REGISTER_STATE: {
			nw_error: 0, register_state: bc.REGISTER_STATE_HOME, register_mode: 1,
			available_data_classes: ext.DATA_CLASS_LTE, current_cellular_class: 1,
			provider_id: '26201', provider_name: 'Telekom.de',
			roaming_text: '', registration_flag: 0,
		},
		PACKET_SERVICE: {
			nw_error: 0, packet_service_state: bc.PACKET_SERVICE_STATE_ATTACHED,
			highest_available_data_class: ext.DATA_CLASS_LTE,
		},
	};
}

// one scenario = fresh mock + modem; o.handlers / o.config / o.on_event /
// o.done(modem, mock, events)
function scenario(name, o, next) {
	let mock = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: o.handlers });
	let events = [];
	let finished = false;
	let modem = null;
	let guard = null;

	let finish = () => {
		if (finished)
			return;
		finished = true;
		if (guard)
			guard.cancel();
		o.done(modem, mock, events);
		modem.stop();
		uloop.timer(1, next);
	};

	modem = modem_mbim.create({
		id: name, device: '/dev/mock0',
		config: o.config ?? {},
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5,
		          at_drain: 1, card_poll: 1 },
		at: { fx: { read: () => null, glob: () => [] } },   // no AT tty in tests
		deps: {
			transport_open: mock.transport_open,
			log: () => null,
			on_event: (m, event, data) => {
				push(events, { event: event, data: data });
				if (event == o.until)
					finish();
			},
		},
	});

	// per-scenario guard so a hung chain fails that scenario, not the file
	guard = uloop.timer(4000, () => {
		ok(false, name + ': timed out waiting for ' + o.until);
		finish();
	});

	modem.start();
}

function count_events(events, name) {
	return length(filter(events, (e) => e.event == name));
}

// --- A: cold boot, SIM still initializing -----------------------------------

scenario_a = function() {
	let h = base_handlers();

	// first query (boot-time identity read): card not up yet, no identity;
	// every later query (the step_sim poll): initialized + identity
	h.SUBSCRIBER_READY_STATUS = (args, meta) => {
		if (meta.count == 1)
			return { ready_state: bc.READY_STATE_NOT_INITIALIZED,
			         subscriber_id: '', sim_iccid: '',
			         ready_info: 0, telephone_numbers_count: 0 };
		return { ready_state: bc.READY_STATE_INITIALIZED,
		         subscriber_id: IMSI, sim_iccid: ICCID,
		         ready_info: 0, telephone_numbers_count: 0 };
	};
	h.PIN = () => ({ pin_type: bc.PIN_TYPE_PIN1, pin_state: bc.PIN_STATE_UNLOCKED,
	                 remaining_attempts: 3 });

	scenario('m_coldboot', {
		handlers: h,
		until: 'registered',
		config: { pincode: '0000', sims: [ { iccid: ICCID, apn: 'per-sim' } ] },
		done: (modem, mock, events) => {
			eq(count_events(events, 'registered'), 1, 'A: reached registered');
			eq(count_events(events, 'sim_blocked'), 0, 'A: no sim_blocked from the init race');
			ok(mock.counts.SUBSCRIBER_READY_STATUS >= 2, 'A: ready-status polled while initializing');
			eq(length(mock.calls_for('PIN')), 0, 'A: PIN untouched (query raced no longer)');
			eq(modem.info.imsi, IMSI, 'A: imsi picked up from the poll');
			eq(modem.info.iccid, ICCID, 'A: iccid picked up from the poll');
			ok(modem.active_sim != null && modem.active_sim.iccid == ICCID,
				'A: per-SIM override matched after the late identity');
		},
	}, scenario_b);
};

// --- B: verify refused, no retry consumed (transient -> retriable) ----------

let b_enters = 0;

scenario_b = function() {
	let h = base_handlers();

	h.SUBSCRIBER_READY_STATUS = (args, meta) => ({
		ready_state: bc.READY_STATE_DEVICE_LOCKED,
		subscriber_id: IMSI, sim_iccid: ICCID,
		ready_info: 0, telephone_numbers_count: 0,
	});

	let unlocked = false;

	h.PIN = (args, meta) => {
		if (meta.kind == 'set') {
			b_enters++;
			// first ENTER: firmware refuses (mid-init / PIN not enabled) —
			// NO retry consumed; second ENTER succeeds
			if (b_enters == 1)
				return { __error: 2 /* MBIM_STATUS_FAILURE */ };
			unlocked = true;
			return { pin_type: bc.PIN_TYPE_PIN1, pin_state: bc.PIN_STATE_UNLOCKED,
			         remaining_attempts: 3 };
		}
		return { pin_type: bc.PIN_TYPE_PIN1,
		         pin_state: unlocked ? bc.PIN_STATE_UNLOCKED : bc.PIN_STATE_LOCKED,
		         remaining_attempts: 3 };
	};

	scenario('m_refused', {
		handlers: h,
		until: 'registered',
		config: { pincode: '0000' },
		done: (modem, mock, events) => {
			eq(count_events(events, 'registered'), 1, 'B: reached registered after the retriable refusal');
			eq(count_events(events, 'sim_blocked'), 0, 'B: refusal without a burned retry is NOT terminal');
			eq(count_events(events, 'error'), 1, 'B: surfaced as one retriable connection error');
			eq(b_enters, 2, 'B: ENTER retried once after the refusal');
		},
	}, scenario_c);
};

// --- C: genuinely wrong PIN (retry burned) -> terminal ------------------------

scenario_c = function() {
	let h = base_handlers();

	h.SUBSCRIBER_READY_STATUS = {
		ready_state: bc.READY_STATE_DEVICE_LOCKED,
		subscriber_id: IMSI, sim_iccid: ICCID,
		ready_info: 0, telephone_numbers_count: 0,
	};

	let burned = false;

	h.PIN = (args, meta) => {
		if (meta.kind == 'set') {
			burned = true;   // wrong PIN: the modem decrements the counter
			return { __error: 2 };
		}
		return { pin_type: bc.PIN_TYPE_PIN1, pin_state: bc.PIN_STATE_LOCKED,
		         remaining_attempts: burned ? 2 : 3 };
	};

	scenario('m_wrongpin', {
		handlers: h,
		until: 'sim_blocked',
		config: { pincode: '9999' },
		done: (modem, mock, events) => {
			let blocked = filter(events, (e) => e.event == 'sim_blocked')[0];
			eq(blocked?.data?.reason, 'verify_failed', 'C: wrong PIN -> terminal verify_failed');
			eq(blocked?.data?.retries, 2, 'C: remaining retries surfaced');
			eq(modem.state, 'SIM_BLOCKED', 'C: modem parked in SIM_BLOCKED');
			eq(length(filter(mock.calls_for('PIN'), (c) => c.kind == 'set')), 1,
				'C: exactly one ENTER — no retry burning loop');
		},
	}, scenario_d);
};

// --- D: verify reply lost but effective --------------------------------------

scenario_d = function() {
	let h = base_handlers();

	h.SUBSCRIBER_READY_STATUS = {
		ready_state: bc.READY_STATE_DEVICE_LOCKED,
		subscriber_id: IMSI, sim_iccid: ICCID,
		ready_info: 0, telephone_numbers_count: 0,
	};

	let entered = false;

	h.PIN = (args, meta) => {
		if (meta.kind == 'set') {
			entered = true;   // the ENTER worked, but the reply is an error
			return { __error: 2 };
		}
		return { pin_type: bc.PIN_TYPE_PIN1,
		         pin_state: entered ? bc.PIN_STATE_UNLOCKED : bc.PIN_STATE_LOCKED,
		         remaining_attempts: 3 };
	};

	scenario('m_lostreply', {
		handlers: h,
		until: 'registered',
		config: { pincode: '0000' },
		done: (modem, mock, events) => {
			eq(count_events(events, 'registered'), 1, 'D: lost verify reply -> re-query sees unlocked, proceeds');
			eq(count_events(events, 'sim_blocked'), 0, 'D: no sim_blocked');
			eq(count_events(events, 'error'), 0, 'D: no retriable error needed');
		},
	}, () => uloop.end());
};

scenario_a();
uloop.run();

done('test_modem_mbim_sim');
