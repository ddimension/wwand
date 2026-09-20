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
		// forbidden one — covers the three status buckets. The status bytes also
		// pin HOME (0x04) and PREFERRED (0x40) apart: they are different bits in
		// QmiNasNetworkStatus, and reading home AS preferred is the bug this
		// fixture was written around until 2026-09-12 — 0x0C was labelled
		// "preferred" here and the code agreed with the label, so both were wrong
		// together and the suite stayed green.
		NETWORK_SCAN: {
			network_information: [
				{ mcc: 262, mnc: 1, network_status: 0x01, description: 'Testnet' },
				{ mcc: 262, mnc: 2, network_status: 0x4C, description: 'Other' },   // home(0x04)+roaming(0x08)+preferred(0x40)
				{ mcc: 262, mnc: 3, network_status: 0x10, description: 'Nope' },
				{ mcc: 262, mnc: 4, network_status: 0x04, description: 'HomeOnly' }, // home, NOT preferred
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
			// `mnc_digits` comes from the scan's own TLV 0x12 where the modem
			// sends one, else from the number; the mock sends none here, so
			// every 2-digit MNC reads as 2. 310/030 gets its own case below.
			eq(sc.operators, [
				{ mcc: 262, mnc: 1, mnc_digits: 2, plmn: '262/01', name: 'Testnet', status: 'current',
				  roaming: false, home: false, preferred: false, rats: [ 'LTE', 'UMTS' ] },
				{ mcc: 262, mnc: 2, mnc_digits: 2, plmn: '262/02', name: 'Other', status: 'available',
				  roaming: true, home: true, preferred: true, rats: [ 'NR5G' ] },
				{ mcc: 262, mnc: 3, mnc_digits: 2, plmn: '262/03', name: 'Nope', status: 'forbidden',
				  roaming: false, home: false, preferred: false, rats: [] },
				{ mcc: 262, mnc: 4, mnc_digits: 2, plmn: '262/04', name: 'HomeOnly', status: 'available',
				  roaming: false, home: true, preferred: false, rats: [] },
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
												{ mcc: 262, mnc: 1, mnc_digits: 2, plmn: '262/01', name: 'Testnet', status: 'current',
												  roaming: false, home: false, preferred: false, rats: [ 'LTE', 'UMTS' ] },
												{ mcc: 262, mnc: 2, mnc_digits: 2, plmn: '262/02', name: 'Other', status: 'available',
												  roaming: true, home: true, preferred: true, rats: [ 'NR5G' ] },
												{ mcc: 262, mnc: 3, mnc_digits: 2, plmn: '262/03', name: 'Nope', status: 'forbidden',
												  roaming: false, home: false, preferred: false, rats: [] },
												{ mcc: 262, mnc: 4, mnc_digits: 2, plmn: '262/04', name: 'HomeOnly', status: 'available',
												  roaming: false, home: true, preferred: false, rats: [] },
											], 'scan_status: operators delivered async');

											guard.cancel();
											// (9) reattach: QMI-native path issues the DMS
											// opmode bounce (low_power = 1), the network
											// re-registration trigger
											daemon.modem_reattach('m0', () => {});
											let opc = mock.calls_for('SET_OPERATING_MODE');
											ok(length(opc) && opc[length(opc) - 1].args.mode == 1,
												'reattach: QMI opmode low_power (bounce) issued');

											// A 3-DIGIT MNC IS NOT KNOWABLE FROM THE NUMBER. 310/030 and 310/30 are
											// different operators and both arrive as the integer 30, so without TLV
											// 0x1A the modem writes whichever its own default assumes — and reads it
											// back the same way, so nothing downstream can tell either. libqmi 1.38,
											// Set System Selection Preference input 0x1A, format guint8. Last in the
											// chain because every step above reads "the last SET". Found by a full
											// review, 2026-09-19.
											daemon.modem_set_network_selection('m0', 'manual', 310, 30, (perr) => {
												eq(perr, null, 'pcs: 310/030 selection accepted');

												let s3 = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
												let l3 = s3[length(s3) - 1].args;

												eq(l3.network_selection, { mode: 1, mcc: 310, mnc: 30 },
													'pcs: the PLMN TLV is unchanged...');
												eq(l3.mnc_pcs_digit, 1,
													'pcs: ...and TLV 0x1A says the MNC carries its third digit');

												// AND A SCAN LISTS THE WIDTH IT SAW. 310/030 and 310/30 arrive
			// identically in the scan's TLV 0x10, so TLV 0x12 is the only
			// thing that tells them apart — without it a UI choosing an
			// entry from the list could not round-trip the one with the
			// leading zero. Found by a full review, 2026-09-19.
			mock.handlers.NETWORK_SCAN = {
				network_information: [
					{ mcc: 310, mnc: 30, network_status: 0x01, description: 'Leading' },
					{ mcc: 310, mnc: 260, network_status: 0x01, description: 'Plain' },
				],
				radio_access_technology: [],
				mnc_pcs_digit: [
					{ mcc: 310, mnc: 30, includes_pcs_digit: 1 },
					{ mcc: 310, mnc: 260, includes_pcs_digit: 1 },
				],
				scan_result: 0,
			};

			daemon.modem_scan('m0', (zerr, zsc) => {
				eq(zerr, null, 'pcs scan: no error');
				eq(zsc.operators[0].mnc_digits, 3,
					'pcs scan: TLV 0x12 marks 310/030 as a 3-digit MNC');
				eq(zsc.operators[0].plmn, '310/030',
					'pcs scan: ...and it renders with its leading zero');
				eq(zsc.operators[1].plmn, '310/260',
					'pcs scan: a plain 3-digit MNC is unaffected');
			});

			// a 2-digit MNC says so too, rather than leaving the modem to guess
												daemon.modem_set_network_selection('m0', 'manual', 262, 3, (qerr) => {
													eq(qerr, null, 'pcs: 262/03 selection accepted');

													let s4 = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
													eq(s4[length(s4) - 1].args.mnc_pcs_digit, 0,
														'pcs: a 2-digit MNC sets the flag to 0');

													// and an MNC of 100 or more settles its own width
													daemon.modem_set_network_selection('m0', 'manual', 302, 220, (rerr) => {
														eq(rerr, null, 'pcs: 302/220 selection accepted');

														let s5 = mock.calls_for('SET_SYSTEM_SELECTION_PREFERENCE');
														eq(s5[length(s5) - 1].args.mnc_pcs_digit, 1,
															'pcs: an MNC >= 100 needs no telling');

														// THE WIDTH IS PART OF THE IDEMPOTENCY COMPARISON. Matching
														// numerically made a serving 310/30 equal to a requested
														// 310/030, so the guard skipped the very write that would have
														// corrected it and reported `unchanged` — the fix above could
														// never fire on the box that needed it. The serving cell carries
														// no width of its own, so a 3-digit request is never treated as
														// already applied. Raised by Codex review, 2026-09-19.
														daemon.modems.m0.modem.cells = { serving: { lte: { mcc: 310, mnc: 30 } } };
														mock.handlers.GET_SYSTEM_SELECTION_PREFERENCE = {
															mode_preference: 0x18, roaming_preference: 0xFF,
															lte_band_preference: 133, usage_preference: 1,
															network_selection: 1,
														};

														daemon.modem_set_network_selection('m0', 'manual', 310, 30, (gerr, gres) => {
															eq(gerr, null, 'guard: 310/30 against a serving 310/30');
															eq(gres.unchanged, true,
																'guard: the same 2-digit PLMN is still skipped');

															daemon.modem_set_network_selection('m0', 'manual', 310, 30,
																(herr, hres) => {
																	eq(herr, null, 'guard: 310/030 against a serving 310/30');
																	eq(hres.unchanged, null,
																		'guard: a 3-digit request is NOT the serving 2-digit PLMN');

																	uloop.end();
																}, 3);
														});
													});
												});
											}, 3);
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

// --- the scan ladder's bottom rung: native MBIM ------------------------------
//
// MBIM has had a scan of its own all along (VISIBLE_PROVIDERS) and wwand never
// called it, so an MBIM modem whose QMI passthrough refuses a NAS scan and has
// no AT port answered `unsupported_on_backend` for an operation its own
// protocol implements.
//
// Duck-typed on purpose: the MBIM schemas ship in wwand-mbim and netsel_ops is
// in the base package, so the modem offers the method and nobody else does.
(function() {
	let asked = 0;
	let mk = (native) => {
		let fake = {
			modem: { create: (o) => {
				let m = { id: o.id, state: 'READY', config: o.config, protocol: 'mbim',
				          at: null, with_nas: (cb) => cb(null),
				          start: () => null, stop: () => null };

				if (native)
					m.native_scan = (cb, timeout) => { asked++; return native(cb, timeout); };

				return m;
			} },
			context: { create: (o) => ({ state: 'IDLE', down: (cb) => cb ? cb() : null }) },
		};
		let d = daemon_mod.create({ timing: { hold_max_ms: 1000, failed_min_gap: 1 },
			deps: { log: () => null, load_qmi: () => fake, load_mbim: () => fake } });

		d.apply_config(config.parse({ network: {
			m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'mbim' },
			a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a' },
		} }));

		return d;
	};

	// no NAS, no AT, no native scan -> the honest error, as before
	mk(null).modem_scan('m0', (err, res) => {
		eq(err?.error, 'unsupported_on_backend',
			'scan ladder: nothing to ask with is still reported as such');
	});

	// ...and with the native one, the operators come back through it
	let ops = [ { mcc: 262, mnc: 1, mnc_digits: 2, description: 'Telekom.de',
	              home: true, registered: true, forbidden: false } ];

	mk((cb, timeout) => {
		ok(timeout > 0, 'scan ladder: the native scan is given the scan timeout');
		cb(null, ops);
	}).modem_scan('m0', (err, res) => {
		eq(err, null, 'scan ladder: the native MBIM scan answers');
		eq(res.operators, ops, 'scan ladder: ...and its operators are what comes back');
	});

	eq(asked, 1, 'scan ladder: the native scan was reached exactly once');

	// a native scan that FAILS is reported as a scan failure, not as
	// "unsupported" — the modem was asked and said no
	mk((cb) => cb({ error: 'mbim', status: 9 }, null)).modem_scan('m0', (err) => {
		eq(err?.error, 'mbim', 'scan ladder: a refused native scan reports the refusal');
	});
})();

// --- and the same bottom rung for network SELECTION --------------------------
//
// MBIM's REGISTER_STATE set takes a provider id and an action. The WIDTH is the
// statement: a 3-digit MNC written two digits wide names a different operator,
// and a provider id carries no flag to say which was meant.
(function() {
	let asked = [];
	let mk = (native) => {
		let fake = {
			modem: { create: (o) => {
				let m = { id: o.id, state: 'READY', config: o.config, protocol: 'mbim',
				          at: null, with_nas: (cb) => cb(null), info: {},
				          start: () => null, stop: () => null };

				if (native)
					m.native_register = (plmn, cb) => { push(asked, plmn); return native(plmn, cb); };

				return m;
			} },
			context: { create: (o) => ({ state: 'IDLE', down: (cb) => cb ? cb() : null }) },
		};
		let d = daemon_mod.create({ timing: { hold_max_ms: 1000, failed_min_gap: 1 },
			deps: { log: () => null, load_qmi: () => fake, load_mbim: () => fake } });

		d.apply_config(config.parse({ network: {
			m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'mbim' },
			a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a' },
		} }));

		return d;
	};

	let ok_native = (plmn, cb) => cb(null);

	mk(ok_native).modem_set_network_selection('m0', 'manual', 262, 3, (err, res) => {
		eq(err, null, 'netsel ladder: the native MBIM register answers');
		eq(res.mode, 'manual', 'netsel ladder: ...with the mode it was asked for');
	});
	eq(asked[0], { mcc: 262, mnc: 3, width: 2 },
		'netsel ladder: the plmn reaches the backend with its width');

	asked = [];
	mk(ok_native).modem_set_network_selection('m0', 'auto', null, null, (err, res) => {
		eq(err, null, 'netsel ladder: automatic too');
		eq(res.mode, 'auto', 'netsel ladder: ...and says so');
	});
	eq(asked[0], null, 'netsel ladder: automatic passes no plmn at all');

	// a refusal is reported as one, not as "unsupported"
	asked = [];
	mk((plmn, cb) => cb({ error: 'mbim', status: 9 }))
		.modem_set_network_selection('m0', 'auto', null, null, (err) => {
			eq(err?.error, 'mbim', 'netsel ladder: a refused register reports the refusal');
		});

	// and with no native path at all the honest error survives
	mk(null).modem_set_network_selection('m0', 'auto', null, null, (err) => {
		eq(err?.error, 'unsupported_on_backend',
			'netsel ladder: nothing to ask with is still reported as such');
	});
})();

// --- carrier configuration: no PDC is not the same as no answer -------------
//
// MBIMEx v3 has a carrier configuration of its own (MODEM_CONFIGURATION), which
// modem_mbim reads at init and keeps — reachable on a modem with no QMI PDC
// service at all, which is exactly the case this used to refuse outright.
//
// READ ONLY, and it has to say so: MBIM has a status and a name and no way to
// SELECT a configuration, so answering a `set` with the read would be worse
// than refusing it.
(function() {
	let mk = (mc, pdc) => {
		let fake = {
			modem: { create: (o) => ({ id: o.id, state: 'READY', config: o.config,
			                           protocol: 'mbim', modem_config: mc, pdc: pdc,
			                           start: () => null, stop: () => null }) },
			context: { create: (o) => ({ state: 'IDLE', down: (cb) => cb ? cb() : null }) },
		};
		let d = daemon_mod.create({ timing: { hold_max_ms: 1000, failed_min_gap: 1 },
			deps: { log: () => null, load_qmi: () => fake, load_mbim: () => fake } });

		d.apply_config(config.parse({ network: {
			m0: { '.type': 'wwand_modem', device: '/dev/mock0', protocol: 'mbim' },
			a:  { '.type': 'interface', proto: 'wwand', modem: 'm0', device: 'l3a', apn: 'a' },
		} }));

		return d;
	};

	let mc = { status: 1, status_text: 'activated', name: 'ROW_Generic_3GPP' };

	mk(mc, null).modem_carrier_config('m0', 'get', '', (err, res) => {
		eq(err, null, 'carrier: an MBIM modem with no PDC still answers a get');
		eq(res.active, 'ROW_Generic_3GPP', 'carrier: ...with the configuration name');
		eq(res.status_text, 'activated', 'carrier: ...and its status');
		eq(res.source, 'mbim', 'carrier: the answer names where it came from');
		eq(res.read_only, true, 'carrier: ...and that it cannot be changed here');
	});

	mk(mc, null).modem_carrier_config('m0', 'list', '', (err, res) => {
		eq(err, null, 'carrier: list answers too');
		eq(length(res.configs), 1, 'carrier: MBIM knows of exactly the active one');
	});

	// a SET is genuinely unavailable, and the refusal says why rather than
	// repeating the generic "no PDC"
	mk(mc, null).modem_carrier_config('m0', 'set', 'x', (err) => {
		eq(err?.error, 'no_pdc', 'carrier: selecting still needs PDC');
		ok(index(err?.detail ?? '', 'can read it but not select') > 0,
			'carrier: ...and the refusal says why, not just that');
	});

	// and a modem with neither is refused as before
	mk(null, null).modem_carrier_config('m0', 'get', '', (err) => {
		eq(err?.error, 'no_pdc', 'carrier: no PDC and no MBIM configuration -> refused');
		ok(index(err?.detail ?? '', 'no QMI PDC service') >= 0,
			'carrier: ...with the original reason');
	});
})();

done('test_netsel');
