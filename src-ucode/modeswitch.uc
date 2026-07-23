// wwand — one-time usbnet mode switch for PPP-only modems.
//
// A modem that enumerates exposing ONLY serial/ACM ports (no cdc-wdm, no
// cdc_ncm/cdc_ether datapath netdev) cannot be managed by wwand as-is: there is
// no QMI/MBIM control device and no data netdev. Before giving up we attempt a
// conservative, per-vendor USB-composition switch over AT to a mode wwand can
// drive (QMI preferred, else NCM/ECM), then reset so the device re-enumerates.
// The reset fires a usbmisc/net hotplug event and daemon.uc rebuilds the modem
// under the new driver.
//
// GUARD: this is ONLY ever invoked by daemon.uc for the ppp-only case, and only
// ONCE per modem (daemon tracks the attempt) — never when a richer control or
// datapath interface already exists.
//
// SAFETY: idempotent. Where the modem supports a mode query we read the current
// composition first and skip the (destructive) reset if it is already rich.
// Recipes flagged `unverified` have NOT been checked on hardware and log a
// warning; extend/confirm them per model.

'use strict';

import * as atcmd from './atcmd.uc';

// per-vendor recipes, matched against the manufacturer (AT+CGMI) or model
// (AT+CGMM) string (case-insensitive). `want`/`query`/`query_re` enable the
// idempotency skip; `set` changes the composition; `reset` re-enumerates.
const RECIPES = [
	{
		// Quectel RG/EG/EM/EC/BG/AG: AT+QCFG="usbnet",<n>
		//   0 = RmNet/QMI (preferred), 1 = ECM/NCM, 2 = MBIM
		match: '^(RG|EG|EM|EC|BG|AG)[0-9]',
		target: 'qmi',
		query: 'AT+QCFG="usbnet"',
		query_re: /\+QCFG:\s*"usbnet",([0-9]+)/,
		want: '0',
		set: 'AT+QCFG="usbnet",0',
		reset: 'AT+CFUN=1,1',
	},
	{
		// Huawei: ^SETPORT / ^U2DIAG select the USB profile. The profile string
		// is model-specific; this one requests the NDIS(NCM)+diag+modem set that
		// wwand's NCM backend can drive. UNVERIFIED — confirm per model before
		// trusting it in the field.
		match: 'huawei',
		target: 'ncm',
		query: null,
		want: null,
		set: 'AT^SETPORT="A1,A2;10,12,16,A1,A2"',
		reset: 'AT^RESET',
		unverified: true,
	},
];

// generic default: no known recipe -> do nothing (return switched:false)
function recipe_for(manuf, model)
{
	for (let r in RECIPES) {
		let re = regexp(r.match, 'i');

		if ((model != null && match(model, re)) || (manuf != null && match(manuf, re)))
			return r;
	}

	return null;
}

// attempt(opts, cb):
//   opts = { tty, log?, open_transport? }
//   cb(err, { switched: bool, target?: 'qmi'|'ncm'|'mbim' })
//     switched=true  -> composition changed, modem is resetting/re-enumerating
//     switched=false -> already rich, or no recipe for this modem (no-op)
export function attempt(opts, cb)
{
	cb = cb ?? ((e, r) => null);

	let log = opts.log ?? ((l, m) => warn(sprintf('%s: modeswitch: %s\n', l, m)));

	if (!opts.tty)
		return cb({ error: 'no_tty' });

	let open_transport = opts.open_transport ?? atcmd.open_transport;
	let tr = open_transport(opts.tty, 115200, (l, m) => log(l, m));

	if (!tr)
		return cb({ error: 'open_failed', tty: opts.tty });

	let at = atcmd.create(tr, { log: (l, m) => log(l, sprintf('at: %s', m)) });
	let finish = (err, res) => { at.close(); cb(err, res); };

	// read a single AT+... value (first non-empty response line)
	let ask = (cmd, done) => at.send(cmd, (err, r) => {
		let val = null;

		for (let line in (r?.lines ?? [])) {
			let m = match(line, /^\+[A-Z]+:\s*(.*)/);

			val = m ? trim(m[1]) : trim(line);

			if (val != '')
				break;
		}

		done(err ? null : val);
	});

	ask('AT+CGMI', (manuf) => {
		ask('AT+CGMM', (model) => {
			let recipe = recipe_for(manuf, model);

			if (!recipe) {
				log('notice', sprintf('no mode-switch recipe for %J / %J; leaving as-is', manuf, model));
				return finish(null, { switched: false });
			}

			if (recipe.unverified)
				log('warn', sprintf('mode-switch recipe for %J is UNVERIFIED on hardware', model ?? manuf));

			let apply = () => {
				log('notice', sprintf('setting usbnet mode for %J -> %s', model ?? manuf, recipe.target));

				at.send(recipe.set, (serr) => {
					if (serr)
						return finish({ error: 'set_failed', detail: serr });

					// apply via reset; a reset usually drops the AT link before
					// answering OK — that is expected, treat it as success.
					at.send(recipe.reset, (rerr) => {
						log('notice', 'usbnet mode change applied, modem resetting');
						finish(null, { switched: true, target: recipe.target });
					}, { timeout: 5000 });
				});
			};

			// idempotency: skip the destructive reset if already in the wanted mode
			if (recipe.query && recipe.want != null) {
				at.send(recipe.query, (qerr, qres) => {
					let cur = null;

					if (!qerr)
						for (let line in (qres?.lines ?? [])) {
							let m = match(line, recipe.query_re);

							if (m) { cur = m[1]; break; }
						}

					if (cur == recipe.want) {
						log('notice', sprintf('usbnet already in mode %s; nothing to switch', cur));
						return finish(null, { switched: false });
					}

					apply();
				}, { timeout: 8000 });
			}
			else {
				apply();
			}
		});
	});
}
