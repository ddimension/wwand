// wwand tests — SIM PIN unlock state machine (sim.uc) against mock UIM/DMS
// clients. This is the most safety-critical logic in the tree (a wrong branch
// burns the last PIN retry and PUK-locks the card), so every pin_block_reason
// branch and both transports are driven explicitly.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as sim from 'wwand/sim.uc';
import * as uimmod from 'wwand/codec/schema/uim.uc';

uloop.init();

// --- mock plumbing -----------------------------------------------------------

// mock QMI client: handlers[name] is either a function (args, cb) or a canned
// { __err, data } / plain-data reply. Every request name is appended to `calls`.
function mkclient(handlers, calls)
{
	let self;   // forward-declare: the literal's methods capture `self`

	self = {
		_ind: {},
		request: function(name, args, cb, opts) {
			push(calls, name);

			let h = handlers[name];

			if (type(h) == 'function')
				return h(args, cb);

			if (h?.__err)
				return cb(h.__err, h.data);

			cb(null, h ?? {});
		},
		on: function(ev, cb) { self._ind[ev] = cb; },
	};

	return self;
}

function card(app_state, pin1_retries, upin_replaces, perso_state)
{
	return { cards: [ {
		card_state: uimmod.CARD_STATE_PRESENT,
		upin_retries: 9,
		applications: [ {
			type: uimmod.APP_TYPE_USIM,
			state: app_state,
			upin_replaces_pin1: upin_replaces ? 1 : 0,
			personalization_state: perso_state ?? 0,
			pin1_state: 2, pin1_retries: pin1_retries ?? 3,
		} ],
	} ] };
}

const T = { sim_settle: 1, card_poll: 1 };

let scenarios = [];
let idx = 0;
let all_done = false;

function scenario(name, fn) { push(scenarios, { name: name, fn: fn }); }

function run_next()
{
	if (idx >= length(scenarios)) {
		all_done = true;
		uloop.end();
		return;
	}

	let s = scenarios[idx++];
	s.fn(() => uloop.timer(1, run_next));
}

// --- unlock via UIM ----------------------------------------------------------

scenario('uim: ready card', (next) => {
	let calls = [];
	let m = { timing: T, config: {}, uim: mkclient({
		GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_READY, 3) },
	}, calls) };

	sim.unlock(m, (err, st) => {
		eq(err, null, 'uim-ready: no error');
		eq(st.status, 'ready', 'uim-ready: status');
		eq(st.pin1_retries, 3, 'uim-ready: retries reported');
		next();
	});
});

scenario('uim: pin verify ok (indication)', (next) => {
	let calls = [];
	let uim;
	uim = mkclient({
		GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_PIN1_OR_UPIN_PIN_REQUIRED, 3) },
		REGISTER_EVENTS: {},
		VERIFY_PIN: (args, cb) => {
			eq(args.info.pin, '1234', 'uim-verify: configured PIN sent');
			cb(null, {});
			// readiness indication arrives right after the verify reply
			uim._ind.CARD_STATUS_IND({ card_status: card(uimmod.APP_STATE_READY, 3) });
		},
	}, calls);

	let m = { timing: T, config: { pincode: '1234' }, uim: uim };

	sim.unlock(m, (err, st) => {
		eq(err, null, 'uim-verify: no error');
		eq(st.status, 'ready', 'uim-verify: ready after indication');
		next();
	});
});

scenario('uim: low retries block auto-entry', (next) => {
	let calls = [];
	let m = { timing: T, config: { pincode: '1234' }, uim: mkclient({
		GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_PIN1_OR_UPIN_PIN_REQUIRED, 1) },
	}, calls) };

	sim.unlock(m, (err) => {
		eq(err.blocked, true, 'uim-low: blocked');
		eq(err.reason, 'pin_retries_low', 'uim-low: precautionary reason');
		eq(err.retries, 1, 'uim-low: retries surfaced');
		ok(index(calls, 'VERIFY_PIN') < 0, 'uim-low: VERIFY_PIN never sent');
		next();
	});
});

scenario('uim: zero retries -> puk needed', (next) => {
	let calls = [];
	let m = { timing: T, config: { pincode: '1234' }, uim: mkclient({
		GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_PIN1_OR_UPIN_PIN_REQUIRED, 0) },
	}, calls) };

	sim.unlock(m, (err) => {
		eq(err.reason, 'retries_exhausted', 'uim-zero: PUK-needed reason');
		ok(index(calls, 'VERIFY_PIN') < 0, 'uim-zero: VERIFY_PIN never sent');
		next();
	});
});

scenario('uim: manual force releases the low-retry block', (next) => {
	let calls = [];
	let uim;
	uim = mkclient({
		GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_PIN1_OR_UPIN_PIN_REQUIRED, 1) },
		REGISTER_EVENTS: {},
		VERIFY_PIN: (args, cb) => {
			cb(null, {});
			uim._ind.CARD_STATUS_IND({ card_status: card(uimmod.APP_STATE_READY, 1) });
		},
	}, calls);

	let m = { timing: T, config: { pincode: '1234' }, pin_force: true, uim: uim };

	sim.unlock(m, (err, st) => {
		eq(err, null, 'uim-force: no error');
		ok(index(calls, 'VERIFY_PIN') >= 0, 'uim-force: VERIFY_PIN sent past the block');
		next();
	});
});

scenario('uim: pin required but none configured', (next) => {
	let m = { timing: T, config: {}, uim: mkclient({
		GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_PIN1_OR_UPIN_PIN_REQUIRED, 3) },
	}, []) };

	sim.unlock(m, (err) => {
		eq(err.reason, 'pin_required_no_pin', 'uim-nopin: blocked with reason');
		next();
	});
});

scenario('uim: verify failure surfaces remaining retries', (next) => {
	let m = { timing: T, config: { pincode: '9999' }, uim: mkclient({
		GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_PIN1_OR_UPIN_PIN_REQUIRED, 3) },
		REGISTER_EVENTS: {},
		VERIFY_PIN: { __err: { error: 'qmi', code: 12 }, data: { retries: { verify: 2 } } },
	}, []) };

	sim.unlock(m, (err) => {
		eq(err.reason, 'verify_failed', 'uim-badpin: verify_failed');
		eq(err.retries, 2, 'uim-badpin: remaining retries from the reply');
		next();
	});
});

scenario('uim: per-SIM override pincode wins', (next) => {
	let sent = null;
	let uim;
	uim = mkclient({
		GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_PIN1_OR_UPIN_PIN_REQUIRED, 3) },
		REGISTER_EVENTS: {},
		VERIFY_PIN: (args, cb) => {
			sent = args.info.pin;
			cb(null, {});
			uim._ind.CARD_STATUS_IND({ card_status: card(uimmod.APP_STATE_READY, 3) });
		},
	}, []);

	let m = { timing: T, config: { pincode: '0000' },
	          active_sim: { pincode: '4321' }, uim: uim };

	sim.unlock(m, (err) => {
		eq(sent, '4321', 'uim-override: wwand_sim pincode used over the modem default');
		next();
	});
});

scenario('uim: no sim after poll exhaustion', (next) => {
	let m = { timing: T, config: {}, uim: mkclient({
		GET_CARD_STATUS: { card_status: { cards: [] } },
	}, []) };

	sim.unlock(m, (err) => {
		eq(err.blocked, true, 'uim-nosim: blocked');
		eq(err.reason, 'no_sim', 'uim-nosim: reason');
		next();
	});
});

// CHECK_PERSONALIZATION_STATE without an active perso lock (Huawei E392 quirk:
// QMI reports state 4 persistently while AT says READY) -> treat as ready.
scenario('uim: check-perso, no active lock -> ready', (next) => {
	let m = { timing: T, config: {}, uim: mkclient({
		GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_CHECK_PERSONALIZATION_STATE,
			3, false, uimmod.PERSO_STATE_READY) },
	}, []) };

	sim.unlock(m, (err, st) => {
		eq(err, null, 'uim-perso-ok: no error');
		eq(st.status, 'ready', 'uim-perso-ok: ready after poll exhaustion');
		next();
	});
});

// CHECK_PERSONALIZATION_STATE with an active perso lock -> honest block.
scenario('uim: check-perso, code required -> blocked', (next) => {
	let m = { timing: T, config: {}, uim: mkclient({
		GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_CHECK_PERSONALIZATION_STATE,
			3, false, uimmod.PERSO_STATE_CODE_REQUIRED) },
	}, []) };

	sim.unlock(m, (err) => {
		eq(err.blocked, true, 'uim-perso-lock: blocked');
		eq(err.reason, 'personalization', 'uim-perso-lock: reason');
		eq(err.perso_state, uimmod.PERSO_STATE_CODE_REQUIRED, 'uim-perso-lock: perso_state reported');
		next();
	});
});

// --- unlock via legacy DMS ---------------------------------------------------

scenario('dms: verified pin -> ready', (next) => {
	let m = { timing: T, config: {}, dms: mkclient({
		GET_PIN_STATUS: { pin1: { status: 2, verify_retries: 3 } },
	}, []) };

	sim.unlock(m, (err, st) => {
		eq(st.status, 'ready', 'dms-ready: status');
		next();
	});
});

scenario('dms: verify no-effect means no pin needed', (next) => {
	let m = { timing: T, config: { pincode: '1234' }, dms: mkclient({
		GET_PIN_STATUS: { pin1: { status: 1, verify_retries: 3 } },
		VERIFY_PIN: { __err: { error: 'qmi', code: 26 } },
	}, []) };

	sim.unlock(m, (err, st) => {
		eq(st.status, 'no_pin_needed', 'dms-noeffect: mapped to no_pin_needed');
		next();
	});
});

scenario('dms: low retries block (dms threshold)', (next) => {
	let calls = [];
	let m = { timing: T, config: { pincode: '1234' }, dms: mkclient({
		GET_PIN_STATUS: { pin1: { status: 1, verify_retries: 1 } },
	}, calls) };

	sim.unlock(m, (err) => {
		eq(err.reason, 'pin_retries_low', 'dms-low: blocked');
		ok(index(calls, 'VERIFY_PIN') < 0, 'dms-low: VERIFY_PIN never sent');
		next();
	});
});

scenario('dms: successful verify settles to ready', (next) => {
	let m = { timing: T, config: { pincode: '1234' }, dms: mkclient({
		GET_PIN_STATUS: { pin1: { status: 1, verify_retries: 3 } },
		VERIFY_PIN: {},
	}, []) };

	sim.unlock(m, (err, st) => {
		eq(st.status, 'ready', 'dms-verify: ready after settle');
		next();
	});
});

// --- set_pin_lock ------------------------------------------------------------

scenario('pinlock: idempotent short-circuit', (next) => {
	let calls = [];
	let m = { timing: T, config: {}, uim: mkclient({
		GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_READY, 3) },   // pin1_state 2 = enabled
	}, calls) };

	sim.set_pin_lock(m, true, '1234', (err, res) => {
		eq(err, null, 'pinlock-idem: no error');
		eq(res.already, true, 'pinlock-idem: already in requested state');
		ok(index(calls, 'SET_PIN_PROTECTION') < 0, 'pinlock-idem: no NV write');
		next();
	});
});

scenario('pinlock: transport rejection falls through, pin error stops', (next) => {
	let calls = [];
	let m = { timing: T, config: {},
		uim: mkclient({
			GET_CARD_STATUS: { __err: { error: 'qmi', code: 94 } },
			SET_PIN_PROTECTION: { __err: { error: 'qmi', code: 94 } },   // NotSupported -> next
		}, calls),
		dms: mkclient({
			SET_PIN_PROTECTION: { __err: { error: 'qmi', code: 12 },     // IncorrectPin -> STOP
			                      data: { retries: { verify: 2 } } },
		}, calls),
		at: { send: (cmd, cb) => { push(calls, 'AT'); cb(null, {}); } },
	};

	sim.set_pin_lock(m, true, '1234', (err) => {
		ok(err != null, 'pinlock-chain: pin error surfaces');
		eq(err.retries, 2, 'pinlock-chain: retries surfaced');
		ok(index(calls, 'AT') < 0, 'pinlock-chain: AT never tried after a real PIN error');
		next();
	});
});

scenario('pinlock: blocked pin refuses up front', (next) => {
	let calls = [];
	let m = { timing: T, config: {}, uim: mkclient({
		GET_CARD_STATUS: { card_status: { cards: [ { card_state: uimmod.CARD_STATE_PRESENT,
			applications: [ { type: uimmod.APP_TYPE_USIM, state: uimmod.APP_STATE_READY,
			                  pin1_state: 4, pin1_retries: 0 } ] } ] } },
	}, calls) };

	sim.set_pin_lock(m, false, '1234', (err) => {
		eq(err.error, 'pin_blocked', 'pinlock-blocked: refused');
		ok(index(calls, 'SET_PIN_PROTECTION') < 0, 'pinlock-blocked: nothing written');
		next();
	});
});

// --- write_user_plmn via AT+CPOL/CPLS ----------------------------------------

// a mock AT channel: records every command; answers AT+CPOL? with two existing
// records (so the writer must clear them), everything else OK.
function mock_at(sent)
{
	return {
		send: (cmd, cb, o) => {
			push(sent, cmd);
			if (match(cmd, /^AT\+CPOL\?$/))
				return uloop.timer(1, () => cb(null, { lines: [
					'+CPOL: 1,2,"26202",1,0,1,1', '+CPOL: 2,2,"26203",0,0,0,1', 'OK' ] }));
			uloop.timer(1, () => cb(null, { lines: [ 'OK' ] }));
		},
	};
}

scenario('plmn write: CPLS + clear existing + write new list (AT+CPOL)', (next) => {
	let sent = [];
	// uim: null -> read-back returns nulls, but the AT write sequence still runs
	let m = { at: mock_at(sent), uim: null };

	sim.write_user_plmn(m, [
		{ mcc: '262', mnc: '01', gsm: true, utran: true, eutran: true, ngran: false },
		{ mcc: '262', mnc: '03', gsm: false, utran: false, eutran: true, ngran: true },
	], (err, res) => {
		eq(err, null, 'plmn write: no error');
		eq(res.written, 2, 'plmn write: two records written');
		// selected the user list first
		eq(sent[0], 'AT+CPLS=0', 'plmn write: selects the user-controlled list');
		ok(index(sent, 'AT+CPOL?') >= 0, 'plmn write: reads current records');
		// cleared the two existing records, highest index first (2 then 1)
		ok(index(sent, 'AT+CPOL=2') < index(sent, 'AT+CPOL=1'), 'plmn write: deletes high index before low');
		// wrote the new list at explicit indices with the full 5-field AcT set
		// (GSM,GSM-compact,UTRAN,E-UTRAN,NG-RAN) — the arity the mock accepts first
		ok(index(sent, 'AT+CPOL=1,2,"26201",1,0,1,1,0') >= 0, 'plmn write: record 1 (5 AcT fields, NG-RAN 0)');
		ok(index(sent, 'AT+CPOL=2,2,"26203",0,0,0,1,1') >= 0, 'plmn write: record 2 (NG-RAN 1)');
		next();
	});
});

// arity fallback: a modem that rejects the 5-field form but accepts 4 fields
scenario('plmn write: AcT arity falls back 5 -> 4 on ERROR', (next) => {
	let sent = [];
	let at = {
		send: (cmd, cb, o) => {
			push(sent, cmd);
			// reject any 5-field CPOL write (two commas after the last needed one)
			if (match(cmd, /^AT\+CPOL=[0-9]+,2,"[0-9]+",[0-9],[0-9],[0-9],[0-9],[0-9]$/))
				return uloop.timer(1, () => cb({ error: 'ERROR' }));
			if (match(cmd, /^AT\+CPOL\?$/))
				return uloop.timer(1, () => cb(null, { lines: [ 'OK' ] }));
			uloop.timer(1, () => cb(null, { lines: [ 'OK' ] }));
		},
	};
	sim.write_user_plmn({ at: at, uim: null },
		[ { mcc: '262', mnc: '01', eutran: true } ], (err, res) => {
		eq(err, null, 'plmn write (fallback): succeeds after stepping down');
		ok(index(sent, 'AT+CPOL=1,2,"26201",0,0,0,1,0') >= 0, 'plmn write (fallback): tried 5-field first');
		ok(index(sent, 'AT+CPOL=1,2,"26201",0,0,0,1') >= 0, 'plmn write (fallback): accepted the 4-field form');
		next();
	});
});

scenario('plmn read: AT+CPOL fallback when UIM rejects the EF read', (next) => {
	let sent = [];
	// a modem WITH a UIM client that returns null for the user EF (E392-style
	// rejection) but answers AT+CPOL? — read_plmn_lists must fall back to AT
	let m = {
		uim: { request: (name, args, cb) => uloop.timer(1, () => cb({ error: 'ef_read' }, null)) },
		at: {
			send: (cmd, cb, o) => {
				push(sent, cmd);
				if (match(cmd, /^AT\+CPOL\?$/))
					return uloop.timer(1, () => cb(null, { lines: [
						'+CPOL: 1,2,"26202",1,0,1,1', '+CPOL: 2,2,"310260",0,0,0,1,1', 'OK' ] }));
				uloop.timer(1, () => cb(null, { lines: [ 'OK' ] }));
			},
		},
	};

	sim.read_plmn_lists(m, (lists) => {
		eq(length(lists.user), 2, 'plmn read: user list came from AT+CPOL fallback');
		eq(lists.user[0], { mcc: '262', mnc: '02', gsm: true, utran: true, eutran: true, ngran: false },
			'plmn read: first record decoded from CPOL');
		eq(lists.user[1].mnc, '260', 'plmn read: 3-digit mnc');
		eq(lists.user[1].ngran, true, 'plmn read: NG-RAN flag from CPOL');
		ok(index(sent, 'AT+CPLS=0') >= 0, 'plmn read: selected the user list first');
		next();
	});
});

// QMI NAS path preferred over AT: write via SET_PREFERRED_NETWORKS, read via GET
function mock_nas(store, calls) {
	return {
		request: (name, args, cb) => {
			push(calls, name);
			if (name == 'SET_PREFERRED_NETWORKS') {
				store.pn = args.preferred_networks;
				return uloop.timer(1, () => cb(null, {}));
			}
			if (name == 'GET_PREFERRED_NETWORKS')
				return uloop.timer(1, () => cb(null, { preferred_networks: store.pn ?? [] }));
			uloop.timer(1, () => cb({ error: 'unknown' }));
		},
	};
}

// write_nas_plmn writes the SEPARATE QMI NAS preferred-networks list (not AT).
scenario('plmn write (nas): QMI NAS Set + read-back via NAS Get', (next) => {
	let store = {}, calls = [];
	let m = { nas: mock_nas(store, calls), uim: null };

	sim.write_nas_plmn(m, [
		{ mcc: '262', mnc: '01', utran: true, eutran: true },
		{ mcc: '310', mnc: '260', eutran: true, ngran: true },
	], (err, res) => {
		eq(err, null, 'nas write: ok');
		eq(index(calls, 'SET_PREFERRED_NETWORKS') >= 0, true, 'nas write: used NAS Set');
		eq(store.pn[0], { mcc: 262, mnc: 1, rat: 0xC000 }, 'nas write: record 0 mcc/mnc/rat');
		eq(store.pn[1].rat, 0x4800, 'nas write: record 1 rat (E-UTRAN|NG-RAN)');
		eq(length(res.nas), 2, 'nas write: read-back returns the nas list');
		eq(res.nas[1], { mcc: '310', mnc: '260', gsm: false, utran: false, eutran: true, ngran: true },
			'nas write: read-back decodes 3-digit mnc + AcT flags');
		next();
	});
});

scenario('plmn write (nas): clean error when NAS Set fails', (next) => {
	let m = { nas: { request: (name, args, cb) => uloop.timer(1, () => cb({ error: 'not_supported' })) } };
	sim.write_nas_plmn(m, [ { mcc: '262', mnc: '01', eutran: true } ], (err) => {
		eq(err?.error, 'nas_set', 'nas write: surfaces the NAS error');
		next();
	});
});

scenario('plmn write (nas): no NAS client -> clean error', (next) => {
	sim.write_nas_plmn({ uim: null }, [ { mcc: '262', mnc: '01' } ], (err) => {
		eq(err?.error, 'no_nas_client', 'nas write: no NAS reported');
		next();
	});
});

// read returns the user (EF/AT) and nas lists as SEPARATE fields
scenario('plmn read: user (AT+CPOL) and nas (NAS Get) are separate', (next) => {
	let store = { pn: [ { mcc: 262, mnc: 2, rat: 0x8000 | 0x4000 | 0x0080 } ] }, calls = [], sent = [];
	let m = { nas: mock_nas(store, calls), at: mock_at(sent), uim: null };
	sim.read_plmn_lists(m, (lists) => {
		eq(index(calls, 'GET_PREFERRED_NETWORKS') >= 0, true, 'read: used NAS Get for the nas list');
		eq(lists.nas[0], { mcc: '262', mnc: '02', gsm: true, utran: true, eutran: true, ngran: false },
			'read: nas list decoded from NAS Get');
		// user list comes from AT+CPOL (the mock_at returns two records)
		eq(length(lists.user), 2, 'read: user list from AT+CPOL, distinct from nas');
		next();
	});
});

scenario('plmn write: no write channel -> clean error', (next) => {
	sim.write_user_plmn({ at: null }, [ { mcc: '262', mnc: '01' } ], (err, res) => {
		eq(err?.error, 'no_write_channel', 'plmn write: no NAS and no AT reported');
		next();
	});
});

scenario('plmn write: invalid plmn rejected', (next) => {
	sim.write_user_plmn({ at: mock_at([]), uim: null }, [ { mcc: '26', mnc: '1' } ], (err, res) => {
		eq(err?.error, 'invalid_plmn', 'plmn write: too-short plmn rejected');
		next();
	});
});

// --- physical slots: passthrough bring-up + native MBIM fallback -------------

// QMI-shaped GET_SLOT_STATUS canned response (2 slots, slot 1 active)
const SLOTS2 = { slots: [
	{ card_status: 2, slot_status: 1, logical_slot: 1, iccid: '' },
	{ card_status: 2, slot_status: 0, logical_slot: 0, iccid: '' },
] };

scenario('slots: MBIM modem brings up the passthrough UIM on demand', (next) => {
	let calls = [];
	let m = { timing: T, config: {} };
	m._ensure_uim = (cb) => { m.uim = mkclient({ GET_SLOT_STATUS: SLOTS2 }, calls); cb(); };

	sim.slot_status(m, (err, slots) => {
		eq(err, null, 'slots: no error after on-demand UIM bring-up');
		eq(calls, [ 'GET_SLOT_STATUS' ], 'slots: served by the passthrough UIM');
		eq(length(slots), 2, 'slots: both slots listed');
		eq(slots[0].active, true, 'slots: slot 1 active');
		eq(slots[1].card, 'present', 'slots: slot 2 present');
		next();
	});
});

scenario('slots: pure-MBIM fallback fills the active ICCID from modem info', (next) => {
	let m = { timing: T, config: {}, info: { iccid: '891234' },
		mbim_slots: { status: (cb) => cb(null, [
			{ physical: 1, card: 'present', active: true, logical_slot: 1,
			  iccid: null, is_euicc: true, eid: null },
			{ physical: 2, card: 'absent', active: false, logical_slot: null,
			  iccid: null, is_euicc: false, eid: null },
		]) } };

	sim.slot_status(m, (err, slots) => {
		eq(err, null, 'slots-mbim: no error');
		eq(slots[0].iccid, '891234', 'slots-mbim: active slot ICCID from modem info');
		eq(slots[1].iccid, null, 'slots-mbim: inactive slot has no identity');
		next();
	});
});

scenario('slots: UIM refusal (err 71) flips to native MBIM permanently', (next) => {
	let calls = [];
	let native = 0;
	let m = { timing: T, config: {}, info: {},
		uim: mkclient({ GET_SLOT_STATUS: { __err: { code: 71 } } }, calls),
		mbim_slots: { status: (cb) => { native++; cb(null, []); },
		              switch_to: (p, cb) => cb(null, { unchanged: true }) } };

	sim.slot_status(m, (err) => {
		eq(err, null, 'slots-flip: native fallback answered');
		eq(m._slot_via_mbim, true, 'slots-flip: flip cached on the modem');

		sim.slot_status(m, () => {
			eq(calls, [ 'GET_SLOT_STATUS' ], 'slots-flip: UIM not asked again');
			eq(native, 2, 'slots-flip: second call went native directly');

			sim.switch_slot(m, 1, (serr, sres) => {
				ok(sres?.unchanged, 'slots-flip: switch rides native too (idempotent)');
				next();
			});
		});
	});
});

// unlock on a modem with neither uim nor dms (native-MBIM-UICC / NCM) must not
// crash (used to null-deref modem.dms via unlock_dms — eSIM apply path)
scenario('unlock: no uim/dms -> clean no_unlock_backend', (next) => {
	let m = { timing: T, config: {} };

	sim.unlock(m, (err, st) => {
		eq(err, null, 'unlock-none: no error');
		eq(st.status, 'no_unlock_backend', 'unlock-none: clean status');
		next();
	});
});

// unlock on an MBIM modem bridges via _ensure_uim to the passthrough UIM
scenario('unlock: _ensure_uim bridges to passthrough UIM', (next) => {
	let m = { timing: T, config: {} };
	m._ensure_uim = (cb) => {
		m.uim = mkclient({
			GET_CARD_STATUS: { card_status: card(uimmod.APP_STATE_READY, 3) },
		}, []);
		cb(m.uim);
	};

	sim.unlock(m, (err, st) => {
		eq(err, null, 'unlock-ensure: no error');
		eq(st.status, 'ready', 'unlock-ensure: unlocked via passthrough UIM');
		next();
	});
});

// read_identity without a dms client (AT-only modem) must not crash and still
// return via the AT chain
scenario('read_identity: no dms -> AT chain, no crash', (next) => {
	let m = { timing: T, config: {},
		at: { send: (cmd, cb) => cb(null, { lines: [
			(cmd == 'AT+CIMI') ? '262021234567890' : '89490240001234567890',
		] }) } };

	sim.read_identity(m, (id) => {
		eq(id.imsi, '262021234567890', 'identity-nodms: imsi via AT');
		eq(id.iccid, '89490240001234567890', 'identity-nodms: iccid via AT');
		eq(id.msisdn, null, 'identity-nodms: msisdn stays null');
		next();
	});
});

// --- drive -------------------------------------------------------------------

uloop.timer(1, run_next);
uloop.run();

ok(all_done, 'all scenarios completed (no silent uloop unwind)');
eq(idx, length(scenarios), 'every scenario ran');

// --- EF_FPLMN codec (forbidden-PLMN list, 3 bytes/entry, no AcT) -------------
// 262/02 = 62 F2 20 ; 234/07 = 32 F4 70 (2-digit MNC -> MNC3 nibble = F); 0xFF pad
eq(sim.decode_fplmn([ 0x62, 0xF2, 0x20, 0x32, 0xF4, 0x70, 0xFF, 0xFF, 0xFF ]),
	[ { mcc: '262', mnc: '02' }, { mcc: '234', mnc: '07' } ],
	'decode_fplmn: two 2-digit-MNC entries + pad');
// 3-digit MNC: 310/410 = 13 00 14 (octet2 = MNC3<<4 | MCC3)
eq(sim.decode_fplmn([ 0x13, 0x00, 0x14 ]), [ { mcc: '310', mnc: '410' } ],
	'decode_fplmn: 3-digit MNC');
eq(sim.decode_fplmn([ 0xFF, 0xFF, 0xFF ]), [], 'decode_fplmn: all-empty -> []');
eq(sim.decode_fplmn(null), [], 'decode_fplmn: null -> []');

// encode round-trips, padded to the 12-byte (4-slot) minimum
eq(sim.encode_fplmn([ { mcc: '262', mnc: '02' } ]),
	[ 0x62, 0xF2, 0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF ],
	'encode_fplmn: one entry padded to 12 bytes');
eq(sim.encode_fplmn([ { mcc: '310', mnc: '410' } ], 3),
	[ 0x13, 0x00, 0x14 ], 'encode_fplmn: 3-digit MNC, no extra pad');
eq(sim.decode_fplmn(sim.encode_fplmn([ { mcc: '262', mnc: '02' }, { mcc: '234', mnc: '07' }, { mcc: '310', mnc: '410' } ])),
	[ { mcc: '262', mnc: '02' }, { mcc: '234', mnc: '07' }, { mcc: '310', mnc: '410' } ],
	'fplmn: encode->decode round-trip');
// malformed entries are skipped
eq(sim.encode_fplmn([ { mcc: '26', mnc: '02' }, { mcc: '262', mnc: '2' } ], 0), [],
	'encode_fplmn: drops short mcc / short mnc');

done('test_sim');
