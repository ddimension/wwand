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

// obj: the modem (state carrier); key: the cache slot, e.g. '_apdu_be'.
// cb(name) with the chosen backend name, or cb(null) if none is available.
export function choose(obj, key, candidates, cb)
{
	let cached = obj[key];

	if (cached != null)
		return cb(cached == 'none' ? null : cached);

	let i = 0, step;

	step = () => {
		if (i >= length(candidates)) {
			obj[key] = 'none';
			return cb(null);
		}

		let c = candidates[i++];

		c.probe((available) => {
			if (available) {
				obj[key] = c.name;
				return cb(c.name);
			}

			step();
		});
	};

	step();
};

// forget the cached decision (e.g. on SIM slot switch / removable eUICC), so
// the next call re-probes. Pass the same keys the features cache under.
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
// switch: reset(modem, '_apdu_be', '_esim_be')
export function reset(obj, ...keys)
{
	for (let k in keys)
		delete obj[k];
};
