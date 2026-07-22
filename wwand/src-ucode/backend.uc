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
}

// forget the cached decision (e.g. on SIM slot switch / removable eUICC), so
// the next call re-probes. Pass the same keys the features cache under.
export function reset(obj, ...keys)
{
	for (let k in keys)
		delete obj[k];
}
