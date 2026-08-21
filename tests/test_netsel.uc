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
import * as netsel_ops from 'wwand/netsel_ops.uc';

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
		GET_OPERATING_MODE: { mode: 0 },   // online (FCC verify pass-through)
		GET_PIN_STATUS: { pin1: { status: 3, verify_retries: 3, unblock_retries: 10 } },
		GET_MANUFACTURER: { manufacturer: 'Quectel' },
		GET_CAPABILITIES: { capabilities: { max_tx_rate: 262144, max_rx_rate: 4194304,
			data_service_cap: 1, sim_cap: 2, radio_ifs: [ 8 ] } },
		GET_MSISDN: { msisdn: '4915112345678' },
		GET_IMSI: { imsi: '262011234567890' },
		GET_ICCID: { iccid: '89490200001022832490' },
		REGISTER_INDICATIONS: {},
		SET_EVENT_REPORT: {},
		REFRESH_REGISTER_ALL: {},
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
				{ mcc: 262, mnc: 2, network_status: 0x0C, description: 'Other' },   // preferred(0x04)+roaming(0x08)
				{ mcc: 262, mnc: 3, network_status: 0x10, description: 'Nope' },
			],
			// the separate RAT list: Testnet is on both LTE and UMTS (two entries
			// for one PLMN), Other on 5G, Nope has none reported
			radio_access_technology: [
				{ mcc: 262, mnc: 1, radio_interface: 8 },   // LTE
				{ mcc: 262, mnc: 1, radio_interface: 5 },   // UMTS
				{ mcc: 262, mnc: 2, radio_interface: 12 },  // NR5G
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
	network: { m0: { '.type': 'wwand_modem', device: '/dev/mock0' } },
}));

// hold_max is re-read live on reload (not only at daemon start). main.reload
// derives it from globals.hold_max and calls set_hold_max_ms — kept separate
// from apply_config so it applies even when the modem/context signature is
// unchanged, and so a create-time timing override is never clobbered by the
// config default. status() exposes the effective value.
eq(daemon.status().globals.hold_max_ms, 90000, 'hold_max: default 90s at start');

daemon.set_hold_max_ms((config.parse({
	network: { g: { '.type': 'wwand_globals', hold_max: 30 } },
}).globals.hold_max ?? 90) * 1000);
eq(daemon.status().globals.hold_max_ms, 30000, 'hold_max: live-updated from a reloaded globals.hold_max');

daemon.set_hold_max_ms((config.parse({
	network: { g: { '.type': 'wwand_globals', hold_max: 45 } },
}).globals.hold_max ?? 90) * 1000);
eq(daemon.status().globals.hold_max_ms, 45000, 'hold_max: updates again on a later reload');

// a non-positive / invalid value is ignored (config.parse warns + keeps prior)
daemon.set_hold_max_ms(0);
eq(daemon.status().globals.hold_max_ms, 45000, 'hold_max: non-positive value ignored');

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
				{ mcc: 262, mnc: 1, plmn: '262/01', name: 'Testnet', status: 'current',
				  roaming: false, preferred: false, rats: [ 'LTE', 'UMTS' ] },
				{ mcc: 262, mnc: 2, plmn: '262/02', name: 'Other', status: 'available',
				  roaming: true, preferred: true, rats: [ 'NR5G' ] },
				{ mcc: 262, mnc: 3, plmn: '262/03', name: 'Nope', status: 'forbidden',
				  roaming: false, preferred: false, rats: [] },
			], 'scan: operators + per-PLMN RAT list from NAS network scan (0x11 TLV)');

			// (3) manual selection issues the right NAS request
			daemon.modem_set_network_selection('m0', 'manual', 262, 3, (merr, mres) => {
				eq(merr, null, 'set_network_selection manual: no error');
				eq(mres, { mode: 'manual', mcc: 262, mnc: 3 }, 'set_network_selection manual: result');

				let sel = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
				let last = sel[length(sel) - 1].args;
				eq(last.network_selection, { mode: 1, mcc: 262, mnc: 3 },
					'set_network_selection manual: NAS network_selection TLV');
				eq(last.change_duration, 1, 'set_network_selection manual: permanent');

				// (4) auto selection while the modem already runs auto (the mock's
				// GET_SYSTEM_SELECTION_PREFERENCE says network_selection 0): the
				// idempotency guard must SKIP the set — no radio disturbance —
				// and flag the result `unchanged`
				daemon.modem_set_network_selection('m0', 'auto', 0, 0, (aerr, ares) => {
					eq(aerr, null, 'set_network_selection auto: no error');
					eq(ares, { mode: 'auto', unchanged: true },
						'set_network_selection auto: unchanged (idempotency guard)');

					let sel2 = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
					eq(sel2[length(sel2) - 1].args.network_selection.mode, 1,
						'set_network_selection auto: SET skipped, last request still the manual one');

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

							// (6b) a value the modem already has (mock GET says
							// mode_preference 0x18) is dropped by the idempotency
							// guard -> nothing left to set, result `unchanged`
							daemon.modem_set_settings('m0',
								{ mode_preference: 0x18 }, (uerr, ures) => {
								eq(uerr, null, 'set_settings unchanged: no error');
								eq(ures, { applied: [], unchanged: true },
									'set_settings unchanged: guard skipped the set');

								let sset2 = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
								eq(length(sset2), length(sset),
									'set_settings unchanged: no new SET reached the modem');
								eq(wl.ext_lte_band, null,
									'set_settings: legacy-only modem gets no extended LTE band TLV');

							// (6c) firmware shaping: a modem that reports an extended
							// LTE band mask must get ONLY the extended TLV (0x24) —
							// a Quectel RG502Q rejects the legacy (0x15) + extended
							// pair with INVALID_ARGUMENT (48).
							mock.handlers.GET_SYSTEM_SELECTION_PREFERENCE = {
								mode_preference: 0x18, roaming_preference: 0xFF,
								lte_band_preference: 524420, usage_preference: 1,
								network_selection: 0,
								ext_lte_band: { mask_low: 524420, mask_mid_low: 0,
								                mask_mid_high: 0, mask_high: 0 },
							};

							daemon.modem_set_settings('m0', { lte_bands: [ 1, 3, 8 ] }, (eerr, eres) => {
								eq(eerr, null, 'set_settings ext: no error');
								eq(eres.applied, [ 'ext_lte_band' ],
									'set_settings ext: only the extended TLV reported applied');

								let esets = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
								let el = esets[length(esets) - 1].args;
								eq(el.ext_lte_band, { mask_low: 133, mask_mid_low: 0,
								                      mask_mid_high: 0, mask_high: 0 },
									'set_settings ext: band list -> extended mask');
								eq(el.lte_band_preference, null,
									'set_settings ext: legacy LTE band TLV NOT sent alongside');

								// (6d) an NR5G band TLV needs a mode preference in the
								// same request (RG502Q answers MISSING_ARGUMENT (17)
								// without one). The idempotency guard strips the
								// unchanged mode_preference, so the current value is
								// re-added — without counting as "applied".
								daemon.modem_set_settings('m0', { nr5g_sa_bands: [ 1, 3 ] }, (nerr, nres) => {
									eq(nerr, null, 'set_settings nr: no error');
									eq(nres.applied, [ 'nr5g_sa_band' ],
										'set_settings nr: only the band counts as applied');

									let nsets = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
									let nl = nsets[length(nsets) - 1].args;
									eq(nl.nr5g_sa_band.m0, 5, 'set_settings nr: band list -> mask');
									eq(nl.mode_preference, 0x18,
										'set_settings nr: current mode preference carried alongside the NR band TLV');

									// (6e) the OTHER firmware flavour: a modem that
									// reports an extended mask but refuses it in SET.
									// Which of the two TLVs a firmware takes cannot be
									// probed up front, so one retry with the other one
									// rescues it instead of surfacing a bare "qmi".
									mock.handlers.SET_SYSTEM_SELECTION_PREFERENCE = (a) =>
										(a.ext_lte_band != null) ? { __error: 48 } : {};

									daemon.modem_set_settings('m0', { lte_bands: [ 1, 3 ] }, (rerr, rres) => {
										eq(rerr, null, 'set_settings retry: rejection did not reach the caller');
										eq(rres.applied, [ 'lte_band_preference' ],
											'set_settings retry: fell back to the legacy TLV');

										let rsets = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
										ok(rsets[length(rsets) - 2].args.ext_lte_band != null,
											'set_settings retry: first attempt carried the extended TLV');

										let rl = rsets[length(rsets) - 1].args;
										eq(rl.lte_band_preference, 5, 'set_settings retry: retry carried the legacy mask');
										eq(rl.ext_lte_band, null, 'set_settings retry: retry dropped the extended TLV');

										// a second failure is NOT retried again — it is the
										// caller's error
										mock.handlers.SET_SYSTEM_SELECTION_PREFERENCE = { __error: 48 };

										daemon.modem_set_settings('m0', { lte_bands: [ 1, 5 ] }, (ferr) => {
											eq(ferr.error, 'qmi', 'set_settings retry: exhausted retry surfaces the error');
											eq(ferr.detail.code, 48, 'set_settings retry: original qmi code preserved');

											mock.handlers.SET_SYSTEM_SELECTION_PREFERENCE = {};

							// (7) no_such_modem guard preserved
							daemon.modem_scan('nope', (gerr) => {
								eq(gerr.error, 'no_such_modem', 'scan: unknown modem guarded');

								// (8) async job: start returns immediately,
								// status polling delivers the result
								daemon.modem_scan_start('m0', (xerr, xres) => {
									eq(xerr, null, 'scan_start: no error');
									eq(xres.running, true, 'scan_start: job running');

									let tries = 0;
									let poll;
									poll = () => uloop.timer(20, () => {
										daemon.modem_scan_status('m0', (perr, st) => {
											eq(perr, null, 'scan_status: no error');

											if (st.running && tries++ < 100)
												return poll();

											eq(st.running, false, 'scan_status: job finished');
											eq(st.operators, [
												{ mcc: 262, mnc: 1, plmn: '262/01', name: 'Testnet', status: 'current',
												  roaming: false, preferred: false, rats: [ 'LTE', 'UMTS' ] },
												{ mcc: 262, mnc: 2, plmn: '262/02', name: 'Other', status: 'available',
												  roaming: true, preferred: true, rats: [ 'NR5G' ] },
												{ mcc: 262, mnc: 3, plmn: '262/03', name: 'Nope', status: 'forbidden',
												  roaming: false, preferred: false, rats: [] },
											], 'scan_status: operators delivered async');

											guard.cancel();
											// (9) reattach: QMI-native path issues the DMS
											// opmode bounce (low_power = 1), the network
											// re-registration trigger
											daemon.modem_reattach('m0', () => {});
											let opc = mock.calls_for('SET_OPERATING_MODE');
											ok(length(opc) && opc[length(opc) - 1].args.mode == 1,
												'reattach: QMI opmode low_power (bounce) issued');

											uloop.end();
										});
									});
									poll();
								});
							});
										});   // (6e-b) retry exhausted
									});       // (6e) one-shot retry to the other TLV
								});   // (6d) NR band + mode preference
								});   // (6c) extended LTE band TLV only
								});   // (6b) idempotency guard
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

// --- AT-path reattach bounces connected contexts (T700 field finding) -------
// A standalone netsel_ops install with a fake AT engine + fake contexts:
// COPS deregister -> automatic, then every CONNECTED context is bounced
// (down+up); IDLE contexts are left alone.
{
	let sent = [];
	let at = { send: (cmd, cb) => { push(sent, cmd); cb(null); } };
	let events = [];
	let mkctx = (state) => {
		let c = { state: state };

		c.down = (cb) => { push(events, c.state + ':down'); c.state = 'IDLE'; cb(); };
		c.up = (cb) => { push(events, c.state + ':up'); c.state = 'CONNECTED'; cb(); };
		return c;
	};
	let entry = { modem: { at: at, contexts: [ mkctx('CONNECTED'), mkctx('IDLE') ], reattach: null } };
	let fake = {};

	netsel_ops.install(fake, {
		log: () => null,
		check_modem: (ref, cb) => (ref == 'm1') ? entry : (cb({ error: 'no_such_modem' }), null),
		reg_plmn: () => null,
	});

	fake.modem_reattach('m1', (err, res) => {
		eq(err, null, 'at-reattach: no error');
		ok(sent[0] == 'AT+COPS=2' && sent[1] == 'AT+COPS=0',
			'at-reattach: COPS deregister -> automatic');
		eq(events, [ 'CONNECTED:down', 'IDLE:up' ],
			'at-reattach: only the connected context bounced');
		eq(res.contexts_bounced, 1, 'at-reattach: bounce count');
		eq(length(res.contexts_failed ?? []), 0, 'at-reattach: no failed contexts');
		eq(entry.modem._reattaching, false, 'at-reattach: reattaching flag cleared');

		// error path: a failing up() is reported, not swallowed (the daemon's
		// error machinery must not be the only place that notices)
		let sent2 = [];
		let at2 = { send: (cmd, cb) => { push(sent2, cmd); cb(null); } };
		let mkctx2 = (state) => {
			let c = { state: state, name: 'sim' };

			c.down = (cb) => { c.state = 'IDLE'; cb(); };
			c.up = (cb) => { c.state = 'CONNECTED'; cb({ error: 'at' }); };
			return c;
		};
		let entry2 = { modem: { at: at2, contexts: [ mkctx2('CONNECTED') ], reattach: null } };
		let fake2 = {};

		netsel_ops.install(fake2, {
			log: () => null,
			check_modem: (ref, cb) => (ref == 'm1') ? entry2 : (cb({ error: 'no_such_modem' }), null),
			reg_plmn: () => null,
		});

		fake2.modem_reattach('m1', (e2, r2) => {
			eq(e2, null, 'at-reattach err path: op still ok');
			eq(length(r2.contexts_failed ?? []), 1, 'at-reattach: failed context reported');
			eq(r2.contexts_failed?.[0]?.step, 'up', 'at-reattach: failed step is up');
			eq(entry2.modem._reattaching, false, 'at-reattach: flag cleared on failure too');
		});
	});
}

wait_ready();
uloop.run();
daemon.shutdown();

done('test_netsel');
