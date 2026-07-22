// wwand — modem control protocol switching (QMI <-> MBIM), the software
// equivalent of usb_modeswitch for the modem's USB configuration.
//
// Modems expose their control protocol through vendor AT commands; changing
// it re-enumerates the USB device with a different driver (qmi_wwan for QMI,
// cdc_mbim for MBIM). This module knows the per-vendor commands and drives
// them over the existing AT engine, then resets the modem to apply.
//
// switch_protocol(modem, target, cb): target 'qmi' | 'mbim'
//   cb(null, { changed: bool, resetting: bool }) on success
//   cb({ error: ... }) otherwise
//
// After a successful switch that required a reset the modem disappears and
// re-enumerates; discovery picks it up again with the new driver, so the
// daemon simply lets the current modem object die and rebuilds it.

'use strict';

// per-model AT recipes. `query` returns the current mode token; `modes` maps
// our protocol name to the value to set; `needs_reset` commands re-enumerate.
const RECIPES = [
	{
		// Quectel RG5xx/RG6xx/EG_ etc.: AT+QCFG="usbnet",<n>
		//   0 = RmNet/QMI, 1 = ECM, 2 = MBIM
		match: '^(RG|EG|EM|EC|BG|AG)[0-9]',
		query: 'AT+QCFG="usbnet"',
		query_re: /\+QCFG:\s*"usbnet",([0-9]+)/,
		values: { qmi: '0', mbim: '2' },
		set: (v) => sprintf('AT+QCFG="usbnet",%s', v),
		reset: 'AT+CFUN=1,1',
	},
	{
		// Sierra/Netgear: AT!USBCOMP or AT+QCFG differs; MBIM via AT!UDUSBCOMP.
		// Placeholder recipe kept minimal — extend when hardware is available.
		// MC-only: the EM prefix is ambiguous (Quectel EM06/EM12 vs Sierra
		// EM7455) and is claimed by the Quectel recipe above; disambiguating a
		// Sierra EM needs a revision check, out of scope until we have one.
		match: '^MC[0-9]',
		query: 'AT!USBCOMP?',
		query_re: /([0-9]+)/,
		values: { qmi: '8', mbim: '6' },
		set: (v) => sprintf('AT!USBCOMP=1,1,%s', v),
		reset: 'AT!RESET',
	},
];

function recipe_for(model)
{
	for (let r in RECIPES)
		if (match(model ?? '', regexp(r.match)))
			return r;

	return null;
}

// map a raw mode token back to a protocol name
function token_protocol(recipe, token)
{
	for (let proto, val in recipe.values)
		if (val == token)
			return proto;

	return null;
}

export function supported(model)
{
	return recipe_for(model) != null;
}

export function switch_protocol(modem, target, cb)
{
	let log = modem.log_fn ?? ((l, m) => warn(sprintf('%s: %s\n', l, m)));

	if (target != 'qmi' && target != 'mbim')
		return cb({ error: 'invalid_target', target: target });

	let recipe = recipe_for(modem.info?.model);

	if (!recipe)
		return cb({ error: 'unsupported_model', model: modem.info?.model });

	if (!modem.at)
		return cb({ error: 'no_at_port' });

	let want = recipe.values[target];

	if (want == null)
		return cb({ error: 'protocol_unsupported_by_model', target: target });

	// read current mode first so we can skip a needless reset
	modem.at.send(recipe.query, (qerr, qres) => {
		let current = null;

		if (!qerr) {
			for (let line in (qres.lines ?? [])) {
				let m = match(line, recipe.query_re);

				if (m) {
					current = m[1];
					break;
				}
			}
		}

		if (current == want) {
			log('notice', sprintf('control protocol already %s (usbnet %s)', target, want));
			return cb(null, { changed: false, resetting: false });
		}

		log('notice', sprintf('switching control protocol %s -> %s (usbnet %s -> %s)',
			token_protocol(recipe, current) ?? '?', target, current ?? '?', want));

		modem.at.send(recipe.set(want), (serr) => {
			if (serr)
				return cb({ error: 'set_failed', detail: serr });

			// apply via modem reset; the device re-enumerates and discovery
			// rebuilds the modem object under the new driver
			modem.at.send(recipe.reset, (rerr) => {
				// a reset often drops the AT link before answering OK — that
				// is expected, treat a link error as success
				log('notice', 'protocol change applied, modem resetting');
				cb(null, { changed: true, resetting: true });
			}, { timeout: 5000 });
		});
	}, { timeout: 8000 });
}
