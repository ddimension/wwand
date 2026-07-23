// wwand tests — protocol-neutral NAS settings + network selection (Phase D).
//
// Drives a real QMI modem through the daemon over the mock hub (no ubusd) and
// exercises the with_nas() routing behind modem_get_settings / modem_set_settings
// and the new modem_scan / modem_set_network_selection methods. The whole path
// runs over the real qmux/tlv codec, so a wrong TLV id or a broken with_nas
// accessor shows up here.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as mockhub from './lib/mockhub.uc';
import * as fakefx from './lib/fakefx.uc';
import * as config from 'wwand/config.uc';
import * as daemon_mod from 'wwand/daemon.uc';

uloop.init();

const TIMING = {
	sync_retry: 1, settle: 1, sim_settle: 1, card_poll: 1,
	reg_timeout: 500, backoff_min: 40, backoff_max: 60,
};

function handlers()
{
	return {
		GET_VERSION_INFO: { services: [
			{ service: 1, major: 1, minor: 60 },
			{ service: 2, major: 1, minor: 14 },
			{ service: 3, major: 1, minor: 25 },
		] },
		GET_MODEL: { model: 'RG502Q-EA' },
		GET_REVISION: { revision: 'R11' },
		GET_IDS: { imei: '860000000000001' },
		SET_OPERATING_MODE: {},
		GET_PIN_STATUS: { pin1: { status: 3, verify_retries: 3, unblock_retries: 10 } },
		GET_MANUFACTURER: { manufacturer: 'Quectel' },
		GET_CAPABILITIES: { capabilities: { max_tx_rate: 262144, max_rx_rate: 4194304,
			data_service_cap: 1, sim_cap: 2, radio_ifs: [ 8 ] } },
		GET_MSISDN: { msisdn: '4915112345678' },
		GET_IMSI: { imsi: '262011234567890' },
		GET_ICCID: { iccid: '89490200001022832490' },
		REGISTER_INDICATIONS: {},
		GET_SIGNAL_INFO: {},
		GET_CELL_LOCATION_INFO: {},
		GET_SERVING_SYSTEM: {
			serving_system: { registration: 1, cs_attach: 1, ps_attach: 1,
			                  selected_network: 1, radio_ifs: [ 8 ] },
			current_plmn: { mcc: 262, mnc: 1, description: 'Testnet' },
		},
		// network_selection present (0 = automatic) so selection_mode is derived
		GET_SYSTEM_SELECTION_PREFERENCE: {
			mode_preference: 0x18, roaming_preference: 0xFF,
			lte_band_preference: 524420, usage_preference: 1,
			network_selection: 0,
		},
		SET_SYSTEM_SELECTION_PREFERENCE: {},
		// visible operators: home (current serving), a plain available one, and a
		// forbidden one — covers the three status buckets
		NETWORK_SCAN: {
			network_information: [
				{ mcc: 262, mnc: 1, network_status: 0x01, description: 'Testnet' },
				{ mcc: 262, mnc: 2, network_status: 0x22, description: 'Other' },
				{ mcc: 262, mnc: 3, network_status: 0x10, description: 'Nope' },
			],
		},
	};
}

let mock = mockhub.create({ handlers: handlers() });

let daemon = daemon_mod.create({
	timing: TIMING,
	deps: {
		transport_open: mock.transport_open,
		log: (level, msg) => null,
		datapath_fx: fakefx.create(),
		resolve_modem_device: (cfg) => cfg.device,
		resolve_netdev: (cfg, device) => 'wwan0',
	},
});

daemon.apply_config(config.parse({
	wwand: { m0: { '.type': 'modem', device: '/dev/mock0' } },
	network: {},
}));

let guard = uloop.timer(5000, () => { ok(false, 'test_netsel timed out'); uloop.end(); });

// forward-declared: wait_ready (a let arrow) references run (also a let arrow) —
// ucode captures only already-declared vars, so declare both up front
let run, wait_ready, ticks = 0;

run = () => {
	let modem = daemon.modems.m0.modem;

	// with_nas hands out the modem's live NAS client (the QMI backend accessor)
	let seen = false;
	modem.with_nas((nas) => { seen = true; eq(nas, modem.nas, 'with_nas yields the live NAS client'); });
	ok(seen, 'with_nas invoked its callback');

	// (1) get_settings routes through with_nas and augments with selection mode
	// + registered PLMN
	daemon.modem_get_settings('m0', (err, s) => {
		eq(err, null, 'get_settings: no error');
		eq(s.mode_preference, 0x18, 'get_settings: mode pref via with_nas');
		eq(s.lte_bands, [ 3, 8, 20 ], 'get_settings: band list decoded');
		eq(s.selection_mode, 'auto', 'get_settings: selection mode derived');
		eq(s.registered_plmn, { mcc: 262, mnc: 1, name: 'Testnet' },
			'get_settings: registered plmn (protocol-neutral)');

		// (2) scan returns the parsed operator list with status buckets
		daemon.modem_scan('m0', (serr, sc) => {
			eq(serr, null, 'scan: no error');
			eq(sc.operators, [
				{ mcc: 262, mnc: 1, name: 'Testnet', status: 'current' },
				{ mcc: 262, mnc: 2, name: 'Other', status: 'available' },
				{ mcc: 262, mnc: 3, name: 'Nope', status: 'forbidden' },
			], 'scan: operators parsed from NAS network scan');

			// (3) manual selection issues the right NAS request
			daemon.modem_set_network_selection('m0', 'manual', 262, 3, (merr, mres) => {
				eq(merr, null, 'set_network_selection manual: no error');
				eq(mres, { mode: 'manual', mcc: 262, mnc: 3 }, 'set_network_selection manual: result');

				let sel = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
				let last = sel[length(sel) - 1].args;
				eq(last.network_selection, { mode: 1, mcc: 262, mnc: 3 },
					'set_network_selection manual: NAS network_selection TLV');
				eq(last.change_duration, 1, 'set_network_selection manual: permanent');

				// (4) auto selection -> NAS network_selection mode 0
				daemon.modem_set_network_selection('m0', 'auto', 0, 0, (aerr, ares) => {
					eq(aerr, null, 'set_network_selection auto: no error');
					eq(ares, { mode: 'auto' }, 'set_network_selection auto: result');

					let sel2 = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
					eq(sel2[length(sel2) - 1].args.network_selection.mode, 0,
						'set_network_selection auto: NAS mode 0');

					// (5) invalid mode is rejected before touching the modem
					daemon.modem_set_network_selection('m0', 'bogus', 0, 0, (ierr) => {
						eq(ierr.error, 'invalid_mode', 'set_network_selection: bad mode rejected');

						// (6) set_settings still routes through with_nas and reaches
						// the modem (band list -> mask, permanent duration)
						daemon.modem_set_settings('m0',
							{ usage_preference: 2, lte_bands: [ 1, 3, 8 ] }, (werr, wres) => {
							eq(werr, null, 'set_settings: no error');

							let sset = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
							let wl = sset[length(sset) - 1].args;
							eq(wl.usage_preference, 2, 'set_settings: value reached modem via with_nas');
							eq(wl.lte_band_preference, 133, 'set_settings: band list -> mask');
							eq(wl.change_duration, 1, 'set_settings: permanent duration');

							// (7) no_such_modem guard preserved
							daemon.modem_scan('nope', (gerr) => {
								eq(gerr.error, 'no_such_modem', 'scan: unknown modem guarded');

								guard.cancel();
								uloop.end();
							});
						});
					});
				});
			});
		});
	});
};

// poll until the modem reaches READY, then run the checks
wait_ready = () => {
	if (daemon.modems.m0?.modem?.state == 'READY')
		return run();

	if (++ticks > 300)
		return;   // guard fires

	uloop.timer(5, wait_ready);
};

wait_ready();
uloop.run();
daemon.shutdown();

done('test_netsel');
