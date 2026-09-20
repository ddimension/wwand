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

// outcome: a transport that STOPS answering is demoted, so the ladder can pick
// the fallback that was there all along.
//
// The shape this exists for (ddimension/wwand#30): the QMI-over-MBIM passthrough
// won the choice while it worked, then began failing every request. The cache
// kept dispatching to it, the consumers kept their last values, and LuCI drew a
// flat line for an hour on a modem whose AT port was answering fine.
{
	let obj = {};
	let probes = [];
	let ladder = [
		{ name: 'tunnel', probe: (ok) => { push(probes, 'tunnel'); ok(!!obj._tunnel_up); } },
		{ name: 'at',     probe: (ok) => { push(probes, 'at'); ok(true); } },
	];

	obj._tunnel_up = true;
	backend.choose(obj, 'k', ladder, (be) => eq(be, 'tunnel', 'outcome: the tunnel wins while it works'));

	// it breaks, but not every hiccup is a break
	obj._tunnel_up = false;
	eq(backend.outcome(obj, 'k', false), false, 'outcome: one failure does not demote');
	eq(backend.outcome(obj, 'k', false), false, 'outcome: two do not either');
	backend.choose(obj, 'k', ladder, (be) => eq(be, 'tunnel', 'outcome: ...and the choice still stands'));

	// a success in between clears the streak — a busy modem is not a dead one
	eq(backend.outcome(obj, 'k', true), false, 'outcome: a success breaks the streak');
	eq(backend.outcome(obj, 'k', false), false, 'outcome: so the count starts over');
	eq(backend.outcome(obj, 'k', false), false, 'outcome: still counting');
	eq(backend.outcome(obj, 'k', false), true, 'outcome: the third consecutive failure demotes');

	probes = [];
	backend.choose(obj, 'k', ladder, (be) => eq(be, 'at', 'outcome: the ladder re-probes and the fallback takes over'));
	eq(probes, [ 'tunnel', 'at' ], 'outcome: re-probed FROM THE TOP, so a recovered transport can win again');

	// and it does win again once it answers
	obj._tunnel_up = true;
	eq(backend.outcome(obj, 'k', false), false, 'outcome: the fallback gets its own streak');
	eq(backend.outcome(obj, 'k', false), false, 'outcome: ...');
	eq(backend.outcome(obj, 'k', false), true, 'outcome: ...and is demoted on the same terms');
	backend.choose(obj, 'k', ladder, (be) => eq(be, 'tunnel', 'outcome: a recovered transport is chosen again'));
}


// --- a fallback is provisional: { reprobe: N } walks the ladder again --------
//
// outcome() only drops the cache when the CURRENT choice fails, so a rung that
// answers RELIABLY while answering WORSE keeps the choice for the whole session
// and the preferred rung is never asked whether it has recovered.
//
// This is not theory. ddimension/wwand#30, reporter log 2026-09-19 10:25-10:27:
// a band switch took the RM520F-GL's AT port and its QMI-over-MBIM passthrough
// down together for ~85 s; the passthrough missed three signal reads and lost
// the choice; native MBIM SIGNAL_STATE won it and answers `rssi` and nothing
// else. Passthrough and AT were both back a minute later, and the signal line
// still read `LTE rssi -79 dBm` an hour on, because the rung holding the choice
// never failed again.
{
	let obj = { up: false };
	let probes = [];
	let ladder = [
		{ name: 'tunnel', probe: (okcb) => { push(probes, 'tunnel'); okcb(obj.up); } },
		{ name: 'native', probe: (okcb) => { push(probes, 'native'); okcb(true); } },
	];

	// the tunnel is down, so the fallback wins — as it should
	backend.choose(obj, 'k', ladder, (be) => eq(be, 'native', 'reprobe: the fallback wins while the tunnel is down'), { reprobe: 4 });
	eq(obj.k, 'native', 'reprobe: and the choice is cached');

	// it now recovers, but nothing asks: the fallback keeps answering
	obj.up = true;
	probes = [];

	// the count runs over the CACHED uses; the call that made the choice is not
	// one of them.
	backend.choose(obj, 'k', ladder, (be) => eq(be, 'native', 'reprobe: cached use 1 of 4 — still the fallback'), { reprobe: 4 });
	backend.choose(obj, 'k', ladder, (be) => eq(be, 'native', 'reprobe: cached use 2 of 4'), { reprobe: 4 });
	backend.choose(obj, 'k', ladder, (be) => eq(be, 'native', 'reprobe: cached use 3 of 4'), { reprobe: 4 });
	eq(probes, [], 'reprobe: no probing while the count runs — this is not a poll');

	// the Nth use drops the cache and walks the ladder from the top
	backend.choose(obj, 'k', ladder, (be) => eq(be, 'tunnel', 'reprobe: the Nth use re-walks the ladder and the recovered rung wins it back'), { reprobe: 4 });
	eq(probes, [ 'tunnel' ], 'reprobe: re-probed FROM THE TOP, and stopped at the first hit');

	// the preferred rung holding the choice is never re-probed: there is nothing
	// better to find, and a probe would cost a request to prove it.
	probes = [];
	for (let i = 0; i < 20; i++)
		backend.choose(obj, 'k', ladder, () => null, { reprobe: 4 });
	eq(probes, [], 'reprobe: the top candidate is not re-probed — nothing above it to win');

	// without the option a fallback is forever, which is what an operation-driven
	// caller (sim.uc _apdu_be, esim.uc, sms.uc) wants: no ladder walk mid-session.
	let o2 = { up: false };
	let pr2 = [];
	let l2 = [
		{ name: 'tunnel', probe: (okcb) => { push(pr2, 'tunnel'); okcb(o2.up); } },
		{ name: 'native', probe: (okcb) => { push(pr2, 'native'); okcb(true); } },
	];

	backend.choose(o2, 'k', l2, () => null);
	o2.up = true;
	pr2 = [];

	for (let i = 0; i < 50; i++)
		backend.choose(o2, 'k', l2, (be) => null);

	eq(o2.k, 'native', 'reprobe: omitted -> the choice sticks until it fails');
	eq(pr2, [], 'reprobe: omitted -> no ladder walk at all');

	// a cached 'none' is provisional on the same terms. It is a verdict taken at
	// one moment, and b426619 had to reorder a whole tick because a first-tick
	// 'none' was permanent.
	let o3 = { up: false };
	let l3 = [ { name: 'only', probe: (okcb) => okcb(o3.up) } ];

	backend.choose(o3, 'k', l3, (be) => eq(be, null, 'reprobe: nothing answers -> none'), { reprobe: 2 });
	eq(o3.k, 'none', 'reprobe: cached as the none marker');
	o3.up = true;
	backend.choose(o3, 'k', l3, (be) => eq(be, null, 'reprobe: cached use 1 of 2 still returns none'), { reprobe: 2 });
	backend.choose(o3, 'k', l3, (be) => eq(be, 'only', 'reprobe: ...and the 2nd re-probes, so none is not a life sentence'), { reprobe: 2 });

	// outcome() must clear the use counter with the cache, or the count it left
	// behind makes the NEXT choice re-probe early.
	let o4 = { up: false };
	let pr4 = [];
	let l4 = [
		{ name: 'tunnel', probe: (okcb) => { push(pr4, 'tunnel'); okcb(o4.up); } },
		{ name: 'native', probe: (okcb) => { push(pr4, 'native'); okcb(true); } },
	];

	backend.choose(o4, 'k', l4, () => null, { reprobe: 4 });
	backend.choose(o4, 'k', l4, () => null, { reprobe: 4 });   // uses = 1
	backend.choose(o4, 'k', l4, () => null, { reprobe: 4 });   // uses = 2

	backend.outcome(o4, 'k', false);
	backend.outcome(o4, 'k', false);
	eq(backend.outcome(o4, 'k', false), true, 'reprobe: three failures demote as before');
	eq(o4.k_uses, null, 'reprobe: ...and the use count goes with the cache');

	// ...and the other way round: a HALF-FINISHED streak must not be charged to
	// whichever rung wins the ladder next. Without this, one failure of the
	// fallback followed by a re-probe leaves the recovered preferred rung two
	// failures from demotion instead of three — it inherits a debt it never ran
	// up. Found by review, 2026-09-19.
	let o5 = { up: false };
	let l5 = [
		{ name: 'tunnel', probe: (okcb) => okcb(o5.up) },
		{ name: 'native', probe: (okcb) => okcb(true) },
	];

	backend.choose(o5, 'k', l5, () => null, { reprobe: 2 });
	eq(backend.outcome(o5, 'k', false), false, 'reprobe: the fallback fails once');
	eq(o5.k_fails, 1, 'reprobe: ...and carries a streak of one');

	o5.up = true;
	backend.choose(o5, 'k', l5, () => null, { reprobe: 2 });          // cached use 1
	backend.choose(o5, 'k', l5, (be) => eq(be, 'tunnel', 'reprobe: the 2nd use re-probes and the tunnel wins'), { reprobe: 2 });

	eq(o5.k_fails, null, 'reprobe: the old rung\'s streak did NOT follow it');
	eq(backend.outcome(o5, 'k', false), false, 'reprobe: so the new choice starts at one...');
	eq(backend.outcome(o5, 'k', false), false, 'reprobe: ...two...');
	eq(backend.outcome(o5, 'k', false), true, 'reprobe: ...and is demoted on its own third, not its second');

	// forget()/reset() drop the decision, so the bookkeeping goes too
	let o6 = { k: 'native', k_fails: 2, k_uses: 7 };
	backend.reset(o6, 'k');
	eq([ o6.k, o6.k_fails, o6.k_uses ], [ null, null, null ],
		'reset: the decision and everything said about it are dropped together');
}

// --- a re-probe must not pull the cache out from under a running walk --------
//
// The probes are asynchronous and the fast telemetry loop calls the same key as
// the slow one, independently (telemetry_mbim.uc). If the use-counter fires
// while a ladder walk is still in flight, a second walk starts; both callbacks
// write the cache, the later one home wins regardless of which is newer, and
// their outcomes share one _fails counter. Found by review, 2026-09-19.
{
	let obj = {};
	let pending = null;
	let walks = 0;
	let ladder = [
		{ name: 'slow', probe: (okcb) => { walks++; pending = okcb; } },   // never answers by itself
		{ name: 'fast', probe: (okcb) => okcb(true) },
	];

	// first walk: parks in the top candidate's probe
	backend.choose(obj, 'k', ladder, () => null, { reprobe: 1 });
	eq(walks, 1, 'inflight: the first walk started');
	eq(obj.k, null, 'inflight: ...and has not decided yet');

	// a caller arriving mid-walk must not start a second one
	backend.choose(obj, 'k', ladder, () => null, { reprobe: 1 });
	backend.choose(obj, 'k', ladder, () => null, { reprobe: 1 });
	eq(walks, 1, 'inflight: no competing walk is started while one is running');

	// the queued callers get the ONE walk's answer — they are not left hanging,
	// which is the other half of not racing
	let answers = [];
	backend.choose(obj, 'k', ladder, (be) => push(answers, be), { reprobe: 1 });

	// let it finish on the fallback
	pending(false);
	eq(obj.k, 'fast', 'inflight: the walk settles on the fallback');
	eq(answers, [ 'fast' ], 'inflight: ...and a caller queued behind it is answered');

	// and now the counter works again: reprobe 1 -> the next cached use re-walks
	backend.choose(obj, 'k', ladder, () => null, { reprobe: 1 });
	eq(walks, 2, 'inflight: once finished, re-probing resumes');
	pending(false);

	// forget() clears the marker too, or a walk abandoned by a teardown would
	// block every later re-probe of this key
	let o2 = { k: 'fast', k_probing: true };
	backend.forget(o2, 'k');
	eq(o2.k_probing, null, 'inflight: forget() clears an abandoned walk marker');
}

// ...and clearing the marker is NOT enough on its own. forget() runs on
// teardown and on a protocol change while probes are still outstanding; the
// retired walk's callback must not then write the cache, clear the new walk's
// marker, or answer the new walk's waiters with its stale result — for a modem
// that may already be gone. Found by review, 2026-09-19.
{
	let obj = {};
	let held = null;
	let ladder = [
		{ name: 'slow', probe: (okcb) => { held = okcb; } },
		{ name: 'fast', probe: (okcb) => okcb(true) },
	];

	let answered = [];
	backend.choose(obj, 'k', ladder, (be) => push(answered, [ 'first', be ]));

	// teardown while that walk is parked in its probe
	backend.forget(obj, 'k');

	// a new walk, which settles immediately on the fallback
	let held2 = held;
	held = null;
	backend.choose(obj, 'k', ladder, (be) => push(answered, [ 'second', be ]));
	held(false);

	eq(obj.k, 'fast', 'retired walk: the new walk decided');
	eq(answered, [ [ 'second', 'fast' ] ], 'retired walk: only the new one answered');

	// now the RETIRED walk finally reports — and must change nothing
	held2(true);

	eq(obj.k, 'fast', 'retired walk: a superseded probe does not resurrect the cache');
	eq(answered, [ [ 'second', 'fast' ] ],
		'retired walk: ...and does not answer for a modem that was torn down');
}

// --- the ladder says who won -------------------------------------------------
//
// It decides which transport answers a whole class of question — signal, cells,
// data mode — and it decided in SILENCE: the demotion was logged, the
// replacement was not, so a reader could see that something had been given up
// and never which thing took over. "Where does this number come from" then
// needed the daemon's source rather than its log, twice in one issue
// (ddimension/wwand#30).
(() => {
	let lines = [];
	let log = (lvl, msg) => push(lines, lvl + ':' + msg);
	let obj = {};

	let ladder = (avail, opts) => {
		let got = null;
		backend.choose(obj, '_sig_be', [
			{ name: 'qmi',  probe: (ok) => ok(avail.qmi) },
			{ name: 'mbim', probe: (ok) => ok(avail.mbim) },
		], (n) => { got = n; }, opts);
		return got;
	};

	// the preferred one wins and says so, once
	eq(ladder({ qmi: true, mbim: true }, { log: log }), 'qmi', 'announce: the ladder still answers');
	eq(lines, [ 'notice:_sig_be: answered by qmi' ], 'announce: ...and names the winner');

	// ...and a caller that says WHAT the ladder is for gets that instead of the
	// key. `_sig_be` sends its reader to the source to find out what the line
	// is about, which is the failure this line exists to end.
	{
		let named = [], nobj = {};
		backend.choose(nobj, '_sig_be', [ { name: 'qmi', probe: (ok) => ok(true) } ],
			() => null, { log: (l, m) => push(named, m), what: 'signal' });
		eq(named, [ 'signal: answered by qmi' ], 'announce: the ladder is named in words');
	}

	// ...and NOT again on every call. This runs on the fast telemetry path; a
	// line per walk would drown the log it exists to make readable.
	lines = [];
	ladder({ qmi: true, mbim: true }, { log: log });
	ladder({ qmi: true, mbim: true }, { log: log });
	eq(lines, [], 'announce: an unchanged choice is not repeated');

	// a demotion, and the REPLACEMENT is what the reader could never see
	lines = [];
	backend.outcome(obj, '_sig_be', false);
	backend.outcome(obj, '_sig_be', false);
	backend.outcome(obj, '_sig_be', false);
	eq(ladder({ qmi: false, mbim: true }, { log: log }), 'mbim',
		'announce: the ladder falls to the next rung');
	eq(lines, [ 'notice:_sig_be: answered by mbim' ],
		'announce: ...and the replacement is named');

	// "nothing here can do this" is a decision with the same consequences
	lines = [];
	backend.forget(obj, '_sig_be');
	eq(ladder({ qmi: false, mbim: false }, { log: log }), null, 'announce: nothing answers');
	eq(lines, [ 'notice:_sig_be: no transport can serve this' ],
		'announce: ...and that is said too');

	// A DEMOTION IS ALWAYS FOLLOWED BY AN ANSWER, even when the same transport
	// wins its place back. The reader has just been told this one stopped
	// answering; leaving the sequel unsaid is the half that was missing.
	// set the stage explicitly: mbim is the announced winner, and it is still
	// the only one available — so the re-walk lands on the SAME name, which is
	// the only shape that needs outcome() to clear the announcement.
	backend.forget(obj, '_sig_be');
	eq(ladder({ qmi: false, mbim: true }, { log: log }), 'mbim', 'announce: mbim holds the choice');
	eq(obj._sig_be_said, 'mbim', 'announce: ...and is what was last said');

	lines = [];
	backend.outcome(obj, '_sig_be', false);
	backend.outcome(obj, '_sig_be', false);
	backend.outcome(obj, '_sig_be', false);
	eq(ladder({ qmi: false, mbim: true }, { log: log }), 'mbim',
		'announce: mbim wins its place back after its own demotion');
	eq(lines, [ 'notice:_sig_be: answered by mbim' ],
		'announce: ...and that is said, though the name did not change');

	// ...while the PROVISIONAL re-probe is not a demotion: nothing failed, and
	// the same answer there is noise rather than news.
	lines = [];
	obj._sig_be_uses = 999;
	ladder({ qmi: false, mbim: true }, { log: log, reprobe: 1 });
	eq(lines, [], 'announce: a re-probe landing on the same rung says nothing');

	// a caller that passes no logger gets no logging, and still works
	lines = [];
	backend.forget(obj, '_sig_be');
	eq(ladder({ qmi: true, mbim: true }, {}), 'qmi', 'announce: no logger, same answer');
	eq(lines, [], 'announce: ...and no lines');

	// forget() clears the announcement: after a teardown or a SIM change the
	// next walk is a fresh decision and deserves saying, even on the same rung
	lines = [];
	backend.forget(obj, '_sig_be');
	ladder({ qmi: true, mbim: true }, { log: log });
	eq(lines, [ 'notice:_sig_be: answered by qmi' ],
		'announce: a fresh decision is announced again after forget()');
})();

done('test_backend');
