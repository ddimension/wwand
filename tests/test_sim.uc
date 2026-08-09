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

function card(app_state, pin1_retries, upin_replaces)
{
	return { cards: [ {
		card_state: uimmod.CARD_STATE_PRESENT,
		upin_retries: 9,
		applications: [ {
			type: uimmod.APP_TYPE_USIM,
			state: app_state,
			upin_replaces_pin1: upin_replaces ? 1 : 0,
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

scenario('plmn write: no AT channel -> clean error', (next) => {
	sim.write_user_plmn({ at: null }, [ { mcc: '262', mnc: '01' } ], (err, res) => {
		eq(err?.error, 'no_at_channel', 'plmn write: no AT channel reported');
		next();
	});
});

scenario('plmn write: invalid plmn rejected', (next) => {
	sim.write_user_plmn({ at: mock_at([]), uim: null }, [ { mcc: '26', mnc: '1' } ], (err, res) => {
		eq(err?.error, 'invalid_plmn', 'plmn write: too-short plmn rejected');
		next();
	});
});

// --- drive -------------------------------------------------------------------

uloop.timer(1, run_next);
uloop.run();

ok(all_done, 'all scenarios completed (no silent uloop unwind)');
eq(idx, length(scenarios), 'every scenario ran');

done('test_sim');
