// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — generic per-modem backend selection.
//
// Many features can be served by more than one transport: a cheap QMI message,
// sometimes an alternate QMI message, and an AT command as the last resort.
// choose() probes an ordered candidate list ONCE, caches the first that reports
// available on the modem, and returns its name; later calls return the cached
// name without re-probing (a 'none' marker is cached when all fail, so we never
// re-probe a modem that can't do it). Consumers then dispatch their actual
// operation by the returned name — the same shape sim.apdu_*/esim/CA all use.
//
// candidate = { name, probe: (cb) => cb(available_bool) }
//   Order candidates cheapest-first (preferred QMI, then any alternate QMI,
//   then AT). A probe reports true only when that transport actually works on
//   this modem (e.g. the QMI message returned data rather than NOT_SUPPORTED /
//   INFO_UNAVAILABLE); an AT candidate typically probes just `!!modem.at`.
//
// ----------------------------------------------------------------------------
// DUCK-TYPED MODEM CONTRACT (the fields cross-module consumers may rely on).
// The three modem backends (modem.uc / modem_mbim.uc / modem_ncm.uc) expose a
// shared surface *by convention* — this is its single written-down spec:
//
//   always:      id, state, config, info{model,imei,imsi,iccid,…}, reg,
//                active_sim, at (may be null), timing, contexts[],
//                set_state/attach_context/… (modem_common.scaffolding),
//                reset(cb), reapply_sim(cb)   [re-read identity + re-match
//                wwand_sim + (QMI) attach profile after in-place card change]
//   QMI:         uim/dms/nas/wds_cfg clients, datapath{netdev,…}
//   MBIM:        mbim client, mbim_uicc{open,apdu,close,reset},
//                mbim_sms{read_all,del}, _ensure_uim(cb) [QMI-over-MBIM
//                passthrough: populates .uim on success]
//   NCM:         vendor/dial tables (AT command model)
//
// Consumers feature-test with `if (modem.x)` — never assume a backend.
// Underscore fields (_apdu_be/_esim_be/_pin_override/…) are private caches;
// the daemon's direct pokes at _pin_override/_apdu_be are the documented
// exceptions (one-shot PIN release, status reporting) — do not add new ones.
// ----------------------------------------------------------------------------

'use strict';

// A FALLBACK IS PROVISIONAL, and so is 'none'. outcome() below drops the cache
// when the CURRENT choice fails, which walks the ladder again — but ONLY then.
// A lower rung that answers reliably while answering *worse* therefore holds the
// choice for the rest of the session, and nothing ever asks the preferred rung
// whether it has recovered.
//
// Field-traced on the same RM520F-GL as outcome() below (ddimension/wwand#30,
// reporter log 2026-09-19 10:25-10:27): a band switch (n41 TDD -> n28 FDD) took
// the modem's AT port and the QMI-over-MBIM passthrough down together for ~85 s.
// The passthrough missed three signal reads, lost the choice as designed, and
// native MBIM SIGNAL_STATE won it — which on this modem yields `rssi` and
// nothing else. The passthrough then came back, the AT port answered QENG on
// every tick again, and the signal line stayed `LTE rssi -79 dBm` because the
// rung holding the choice never failed again.
//
// So a caller whose ladder runs on a tick passes `{ reprobe: N }`: after N uses
// of a choice that is NOT the top candidate, the cache is dropped once and the
// ladder is walked from the top. While the preferred rung holds the choice this
// costs nothing at all; on a fallback it costs one probe per rung every N ticks.
// Callers driven by a user operation rather than a clock (sim.uc `_apdu_be`,
// esim.uc, sms.uc) do NOT pass it — re-probing in the middle of an APDU session
// would be both wasteful and unsafe.
//
// WHAT THIS DOES NOT REACH, so nobody has to rediscover it: a candidate can
// decline for a reason of its own that outlives the re-probe. The MBIM
// passthrough rungs all go through `modem_mbim._ensure_pt`, which latches
// `_pt_failed` when the SHIM SETUP fails and then declines without trying again
// until the modem is torn down (modem_mbim.uc:1019,1025,1295). That latch is
// deliberate — it is what keeps a modem with no passthrough at all (RG650E)
// from rebuilding a shim on every capability — so re-probing walks the ladder
// and the top rung still says no. The field case this was written for is the
// other one: a passthrough that WAS built and later stopped answering, where
// `self.pt` exists and the probe is a real request. Raised by review,
// 2026-09-19.
const REPROBE_DEFAULT = 30;

// obj: the modem (state carrier); key: the cache slot, e.g. '_apdu_be'.
// cb(name) with the chosen backend name, or cb(null) if none is available.
// opts.reprobe: see above; omit for a choice that should stick until it fails.
export function choose(obj, key, candidates, cb, opts)
{
	let cached = obj[key];
	let uses = key + '_uses';
	let busy = key + '_probing';

	// only a non-preferred choice is provisional; the top candidate winning is
	// already the best answer the ladder has, and re-probing it proves nothing.
	//
	// NOT WHILE A WALK IS ALREADY RUNNING. The probes are asynchronous, and the
	// fast telemetry loop and the slow one call the same key independently
	// (telemetry_mbim.uc refresh_fast / tick), so a second caller can arrive
	// mid-walk. Dropping the cache under it starts a competing walk whose
	// callbacks both write obj[key] — last one home wins, regardless of which
	// is newer — and whose outcomes share one _fails counter. Raised by review,
	// 2026-09-19. This guard removes the re-probe's contribution to that; a
	// walk begun because the CURRENT choice failed can still overlap, which is
	// older behaviour and self-correcting (the next outcome settles it).
	if (cached != null && opts?.reprobe && !obj[busy] &&
	    cached != candidates[0]?.name) {
		obj[uses] = (obj[uses] ?? 0) + 1;

		// `reprobe: true` takes the default; a number overrides it. Checked by
		// type rather than equality — in ucode a loose compare of a count
		// against a boolean is a trap, not a shorthand.
		let after = (type(opts.reprobe) == 'int') ? opts.reprobe : REPROBE_DEFAULT;

		if (obj[uses] >= after) {
			delete obj[uses];
			delete obj[key];
			// AND the streak: a half-finished run of failures belongs to the
			// rung that earned it. Carried over, it would demote whatever wins
			// the ladder next after two failures instead of three. Raised by
			// review, 2026-09-19.
			delete obj[key + '_fails'];
			cached = null;
		}
	}

	if (cached != null)
		return cb(cached == 'none' ? null : cached);

	// ONE WALK PER KEY. A caller arriving while a walk is in flight waits for
	// its result instead of racing it: two walks both write obj[key], the later
	// one home wins regardless of which is newer, and their outcomes share one
	// _fails counter. The probes are asynchronous and the fast telemetry loop
	// calls the same key as the slow one, independently, so this is reachable —
	// it merely became easier to reach when the re-probe gave the cache a second
	// way to disappear. Raised by review, 2026-09-19.
	let waiters = key + '_waiters';

	if (obj[busy]) {
		obj[waiters] = obj[waiters] ?? [];
		push(obj[waiters], cb);
		return;
	}

	let i = 0, step;

	// A WALK IS IDENTIFIED, not just flagged. Clearing the shared marker is not
	// enough to retire one: forget()/reset() runs on teardown and on a protocol
	// change while probes are still outstanding, a new walk then starts, and the
	// OLD walk's callback would still write obj[key], clear the new walk's
	// marker and drain ITS waiters with a stale answer — resurrecting a cache
	// that was deliberately dropped, for a modem that may be gone. The token
	// makes a superseded walk a no-op. Raised by review, 2026-09-19.
	let gen = key + '_gen';
	let token = (obj[gen] ?? 0) + 1;

	obj[gen] = token;
	obj[busy] = true;

	let settled = false;
	let current = () => (obj[gen] == token);

	let settle = (name) => {
		// once, and only for the walk that is still the current one: a probe
		// that calls back twice must not answer twice.
		if (settled || !current())
			return;

		settled = true;
		delete obj[uses];
		delete obj[busy];

		let queued = obj[waiters];
		delete obj[waiters];

		cb(name);

		for (let w in (queued ?? []))
			w(name);
	};

	step = () => {
		if (!current())
			return;

		if (i >= length(candidates)) {
			obj[key] = 'none';
			return settle(null);
		}

		let c = candidates[i++];

		c.probe((available) => {
			if (!current())
				return;

			if (available) {
				obj[key] = c.name;
				return settle(c.name);
			}

			step();
		});
	};

	step();
};

// A CHOICE IS NOT FOREVER. choose() caches the first candidate that probes
// available, which is exactly right for a transport a modem either has or has
// not — but a transport can also STOP working mid-session, and then the cache is
// a trap: every call dispatches to a backend that cannot answer, the consumer
// keeps whatever it stored last, and a working fallback sits one candidate down
// the list, never reconsidered.
//
// Field-traced on a Quectel RM520F-GL over MBIM (ddimension/wwand#30): the
// QMI-over-MBIM passthrough served signal, cells and data-mode for an hour, then
// began failing every request. Signal and cells froze on their last values —
// visibly a flat line in LuCI — while the data-mode branch stored its null and
// the telemetry read `tech=none`, all on a connection that stayed up and an AT
// port that was answering AT+QENG correctly the whole time.
//
// So consumers report each outcome here, and a RUN of failures drops the cached
// decision. One failure is not enough: a busy modem answers badly without having
// lost anything. Dropping the cache re-probes from the TOP of the ladder, so a
// preferred transport that has recovered can win the choice back — but only when
// the ladder is walked again, which happens when whatever is chosen NOW fails
// three times in its turn. This is not a health monitor and does not poll; it
// only ends the certainty that the last choice is still the right one.
//
// A consumer must report "did the transport answer", NOT "did the answer contain
// anything" — an empty carrier-aggregation list and an OK with an unparsable
// body are answers, and counting them as failures makes this demote healthy
// transports on a quiet modem.
//
// Returns true when the cache was dropped (the caller may want to log it).
const DEMOTE_AFTER = 3;

export function outcome(obj, key, ok)
{
	let fails = key + '_fails';

	if (ok) {
		delete obj[fails];
		return false;
	}

	obj[fails] = (obj[fails] ?? 0) + 1;

	if (obj[fails] < DEMOTE_AFTER)
		return false;

	delete obj[fails];
	delete obj[key];
	delete obj[key + '_uses'];   // or a stale count re-probes the next choice early
	return true;
};

// forget the cached decision (e.g. on SIM slot switch / removable eUICC), so
// the next call re-probes. Pass the same keys the features cache under.
// The per-key bookkeeping goes with the decision: a failure streak or a use
// count that outlived the choice it described would be charged to the next one.
export function forget(obj, ...keys)
{
	for (let k in keys) {
		delete obj[k];
		delete obj[k + '_fails'];
		delete obj[k + '_uses'];
		// ...including the in-flight marker and anyone queued behind it: a walk
		// abandoned by a teardown would otherwise block every later re-probe of
		// this key, and hold references to callbacks of a modem that is gone.
		delete obj[k + '_probing'];
		delete obj[k + '_waiters'];
		// ...and retire whatever walk was running: bumping the generation makes
		// its outstanding callbacks no-ops rather than writers of a dropped
		// cache. A caller queued behind it is dropped with it — its modem is
		// being torn down, which is why forget() was called.
		obj[k + '_gen'] = (obj[k + '_gen'] ?? 0) + 1;
	}
};

// run value providers in order until one yields a non-null result; cb(value)
// with null when every provider came up empty. The shared "try QMI, then AT"
// fallback ladder used by identity reads and similar per-field chains (the
// cached-probe cousin is choose() above — use that when the winning transport
// should stick per modem).
export function first_of(providers, cb)
{
	let i = 0, step;

	step = () => {
		if (i >= length(providers))
			return cb(null);

		providers[i++]((v) => (v != null) ? cb(v) : step());
	};

	step();
};

// run async steps strictly in sequence: each step is (done) => …; done() moves
// on. Flattens hand-rolled callback pyramids (e.g. multi-getter init reads).
export function run_seq(steps, cb)
{
	let i = 0, step;

	step = () => {
		if (i >= length(steps))
			return cb();

		steps[i++](step);
	};

	step();
};

// drop cached backend choices so the next call re-probes — e.g. on a SIM slot
// switch: reset(modem, '_apdu_be', '_esim_be'). Same thing forget() does, under
// the name the modem backends happen to call it by.
export function reset(obj, ...keys)
{
	return forget(obj, ...keys);
};
