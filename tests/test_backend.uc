// wwand tests — backend.uc: the per-modem transport chooser (choose), the
// sequential provider ladder (first_of), the step sequencer (run_seq) and the
// cache reset. Pure callback plumbing, no I/O.
'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as backend from 'wwand/backend.uc';

// --- choose(): first available candidate wins, probes run once ---------------

let modem = {};
let probes = [];

let cands = [
	{ name: 'qmi', probe: (okcb) => { push(probes, 'qmi'); okcb(false); } },
	{ name: 'at',  probe: (okcb) => { push(probes, 'at');  okcb(true); } },
	{ name: 'mbim', probe: (okcb) => { push(probes, 'mbim'); okcb(true); } },
];

backend.choose(modem, '_x_be', cands, (be) => {
	eq(be, 'at', 'choose: first available candidate wins');
});
eq(probes, [ 'qmi', 'at' ], 'choose: probing stops at the first hit');
eq(modem._x_be, 'at', 'choose: choice cached on the modem');

backend.choose(modem, '_x_be', cands, (be) => {
	eq(be, 'at', 'choose: cached choice returned');
});
eq(length(probes), 2, 'choose: no re-probe on the second call');

// all candidates unavailable -> null, and the miss is cached as well
let m2 = {};
let p2 = 0;
let none = [ { name: 'a', probe: (okcb) => { p2++; okcb(false); } } ];

backend.choose(m2, '_y_be', none, (be) => eq(be, null, 'choose: none available -> null'));
backend.choose(m2, '_y_be', none, (be) => eq(be, null, 'choose: miss cached -> null again'));
eq(p2, 1, 'choose: failed probe set not re-run');
eq(m2._y_be, 'none', 'choose: miss cached as the none marker');

// reset() clears the cache so the next call re-probes
backend.reset(m2, '_y_be');
backend.choose(m2, '_y_be', none, (be) => eq(be, null, 'choose: after reset probes again'));
eq(p2, 2, 'reset: probe ran again');

// reset with several keys
let m3 = { _a: 1, _b: 2, _c: 3 };
backend.reset(m3, '_a', '_c');
eq(m3._a ?? null, null, 'reset: first key dropped');
eq(m3._b, 2, 'reset: unrelated key kept');
eq(m3._c ?? null, null, 'reset: second key dropped');

// --- first_of(): sequential provider ladder ----------------------------------

let order = [];

backend.first_of([
	(d) => { push(order, 1); d(null); },
	(d) => { push(order, 2); d('hit'); },
	(d) => { push(order, 3); d('never'); },
], (v) => eq(v, 'hit', 'first_of: first non-null value wins'));
eq(order, [ 1, 2 ], 'first_of: later providers not called');

backend.first_of([
	(d) => d(null),
	(d) => d(null),
], (v) => eq(v, null, 'first_of: all empty -> null'));

backend.first_of([], (v) => eq(v, null, 'first_of: empty ladder -> null'));

// value 0/false must count as a result (only null/undefined fall through)
backend.first_of([ (d) => d(0) ], (v) => eq(v, 0, 'first_of: falsy 0 is a valid hit'));
backend.first_of([ (d) => d(false) ], (v) => eq(v, false, 'first_of: false is a valid hit'));

// --- run_seq(): strict sequencing --------------------------------------------

let seq = [];

backend.run_seq([
	(next) => { push(seq, 'a'); next(); },
	(next) => { push(seq, 'b'); next(); },
	(next) => { push(seq, 'c'); next(); },
], () => push(seq, 'end'));
eq(seq, [ 'a', 'b', 'c', 'end' ], 'run_seq: steps then cb, in order');

backend.run_seq([], () => push(seq, 'empty-ok'));
eq(seq[-1], 'empty-ok', 'run_seq: empty step list still calls cb');

// forget: clears the cached decision, next choose re-probes
{
	let probes = 0;
	let obj = {};

	backend.choose(obj, 'k', [ { name: 'a', probe: (ok) => { probes++; ok(true); } } ], (be) => {
		eq(be, 'a', 'forget: first choose probes');
		backend.choose(obj, 'k', [ { name: 'b', probe: (ok) => { probes++; ok(true); } } ], (be2) => {
			eq(be2, 'a', 'forget: cached value served without probing');
			backend.forget(obj, 'k');
			backend.choose(obj, 'k', [ { name: 'b', probe: (ok) => { probes++; ok(true); } } ], (be3) => {
				eq(be3, 'b', 'forget: re-probe after forget');
				eq(probes, 2, 'forget: exactly two probes ran');
			});
		});
	});
}

done('test_backend');
