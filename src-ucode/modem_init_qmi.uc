// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI modem bring-up chain (extracted from modem.uc).
//
// install(self, o) wires the linear init flow
//   sync -> services/clients -> AT port -> esim quirk -> batched init reset
//   -> datapath -> opmode -> sim slot -> sim unlock -> identity -> confnet
//   -> validate -> attach profile -> register
// and returns { begin } (the start() entry). o = { log, emit, notify_contexts,
// fail, dp, at_opts, tm } — `tm` is modem.uc's shared one-shot timer holder,
// `fail` the recovery-aware failure path. All state stays on `self`; the
// self-attached methods the chain calls are installed by modem.uc before start().

'use strict';

import * as uloop from 'uloop';
import * as sim from 'wwand.sim';
import * as backend from 'wwand.backend';
import * as qmi_backend from 'wwand.qmi_backend';
import * as modem_common from 'wwand.modem_common';
import * as modem_quirks from 'wwand.modem_quirks';
import * as atcmd from 'wwand.atcmd';
import * as datapath_qmi from 'wwand.datapath_qmi';
import * as nasmod from 'wwand.codec.schema.nas';
import * as dmsmod from 'wwand.codec.schema.dms';
import * as uimmod from 'wwand.codec.schema.uim';
import * as wdsmod from 'wwand.codec.schema.wds';
import * as dsdmod from 'wwand.codec.schema.dsd';

const SYNC_TRIES = 10;
const MODES_TRIES = 3;

export function install(self, o)
{
	let log = o.log, emit = o.emit, notify_contexts = o.notify_contexts;
	let sim_block = o.sim_block;
	let fail = o.fail, dp = o.dp, at_opts = o.at_opts, tm = o.tm;

	// shared wwand_sim matcher (modem_common — parity across all backends)
	let match_sim_override = (iccid, imsi) =>
		modem_common.match_sim_override(self.config?.sims, iccid, imsi);

	let step_sync, step_services, step_at, step_esim_quirk, step_apply_init_reset, step_datapath, step_opmode, verify_online, step_simslot, step_sim, step_identity, step_confnet, step_confnet_apply, step_validate, step_attach_profile, step_register;

	// DMS model was junk and the USB descriptor filled in (generic "HUAWEI Mobile"
	// style): ATI usually knows the real model — upgrade identity off the critical
	// path once the AT channel is open.
	let _ati_info = () => {
		if (!self._model_generic || !self.at)
			return;

		self.at.send('ATI', (err, res) => {
			let inf = err ? null : atcmd.parse_ati(res?.lines);

			if (!inf?.model)
				return;

			self._model_generic = false;
			self.info.model = inf.model;
			self.info.manufacturer = inf.manufacturer ?? self.info.manufacturer;
			self.info.revision = inf.revision ?? self.info.revision;
			log('notice', sprintf('identity from ATI: %s %s (rev %s)',
				self.info.manufacturer ?? '?', self.info.model, self.info.revision ?? '?'));
		}, { timeout: 8000 });
	};

	step_sync = (tries) => {
		// the transport can vanish between scheduling and firing: a hotplug remove
		// tears the modem down (teardown() nulls self.ctl + cancels timers), but an
		// already-expired sync-retry timer can still run this callback in the same
		// uloop iteration. Bail if the control client is gone — the modem stays
		// ABSENT and the re-add path restarts init with a fresh self.ctl.
		if (!self.ctl)
			return;

		self.set_state('INIT_TRANSPORT');

		// deferred init resets: NV-changing steps push a reason here; ONE reset is
		// applied at the end of the AT config phase (not mid-init several times)
		self._init_resets = [];

		self.ctl.request('SYNC', {}, (err) => {
			if (err) {
				if (tries < SYNC_TRIES) {
					tm.retry = uloop.timer(self.timing.sync_retry,
						() => step_sync(tries + 1));
					return;
				}

				return fail('sync', err);
			}

			step_services();
		}, { timeout: 3000 });
	};

	step_services = () => {
		self.set_state('INIT_SERVICES');
		self.ctl.request('GET_VERSION_INFO', {}, (err, data) => {
			if (err)
				return fail('version_info', err);

			self.services = {};

			let names = [];

			for (let svc in (data.services ?? [])) {
				self.services[sprintf('%d', svc.service)] = { major: svc.major, minor: svc.minor };
				push(names, sprintf('%d(%d.%d)', svc.service, svc.major, svc.minor));
			}

			log('info', sprintf('services: %s', join(' ', names)));

			self.alloc(dmsmod.default, (e1, dms) => {
				if (e1)
					return fail('alloc_dms', e1);

				self.dms = dms;
				self._install_dms_handlers();

				self.alloc(nasmod.default, (e2, nas) => {
					if (e2)
						return fail('alloc_nas', e2);

					self.nas = nas;
					self._install_nas_handlers();

					let after_uim = () => {
						self.alloc(wdsmod.default, (e4, wds) => {
							if (e4)
								return fail('alloc_wds', e4);

							self.wds_cfg = wds;

							// DSD (Data System Determination): optional, gives the
							// clean LTE / 5G-NSA / 5G-SA status; absent on older modems.
							if (self.services[sprintf('%d', dsdmod.default.service)]) {
								self.alloc(dsdmod.default, (e5, dsd) => {
									self.dsd = e5 ? null : dsd;
									if (self.dsd)
										self._arm_data_mode_ind();
									self._read_info(step_at);
								});
							}
							else {
								self.dsd = null;
								self._read_info(step_at);
							}
						});
					};

					// WMS (SMS) is NOT allocated here — brought up lazily on the
					// first SMS op via _ensure_wms (wms schema off the heap until used).
					if (self.services[sprintf('%d', uimmod.default.service)]) {
						self.alloc(uimmod.default, (e3, uim) => {
							if (e3) {
								log('warn', 'uim allocation failed, using dms fallback');
								self.uim = null;
							}
							else {
								self.uim = uim;
								self._install_uim_refresh();
							}

							after_uim();
						});
					}
					else {
						after_uim();
					}
				});
			});
		});
	};

	// AT side channel: best-effort, failures never block bring-up
	step_at = () => modem_common.open_at(self, {
		at_opts: at_opts,
		log: log,
		drain_interval: self.timing.at_drain,
		set_drain_timer: (t) => { tm.at_drain = t; },
		next: () => { _ati_info(); step_esim_quirk(); },
		// preserved: when AT is already open (defensive re-entry), skip straight
		// to the datapath rather than re-running the eSIM quirk
		reopen_next: step_datapath,
	});

	// eSIM host-access quirk: free the eUICC's ISD-R from the modem's internal LPA
	// so host-side ES10 APDUs (CCHO/CGLA) work. Disabling lpa_enable takes effect
	// only after a reset, so we flag the reset (batched by step_apply_init_reset)
	// and only when we actually changed the value (NV, so at most once per modem).
	// Network is unaffected (the active profile keeps working with the LPA off).
	step_esim_quirk = () => {
		let q = atcmd.esim_quirks(self.info.model);

		if (!q.lpa_disable_for_host || !self.at)
			return step_apply_init_reset();

		self.at.send('AT+QESIM="lpa_enable"', (err, res) => {
			let enabled = false;

			for (let l in (res?.lines ?? []))
				if (match(l, /"lpa_enable", *1/))
					enabled = true;

			if (err || !enabled)
				return step_apply_init_reset();   // already disabled / unsupported

			self.at.send('AT+QESIM="lpa_enable",0', () => {
				push(self._init_resets, 'esim: free the ISD-R from the internal LPA');
				step_apply_init_reset();
			});
		}, { timeout: 8000 });
	};

	// apply a single reset if any AT-config step requested one. The reset
	// re-enumerates the modem; discovery re-inits it (nothing left to change, so
	// no reset that pass) and init proceeds normally. Do NOT continue init here
	// when resetting — this instance is being torn down.
	step_apply_init_reset = () => {
		if (!length(self._init_resets ?? []))
			return step_datapath();

		log('notice', sprintf('applying deferred init reset (%s)',
			join('; ', self._init_resets)));

		// one batched reset: AT when a command port exists, else DMS offline->reset.
		// A refused reset is only logged — the modem stays on its old settings and
		// the next boot retries.
		let logerr = (what) => (err) => {
			if (err)
				log('warn', sprintf('init reset via %s refused: %J — settings apply at the next reboot', what, err));
		};

		if (self.at)
			return self.at.send('AT+CFUN=1,1', logerr('AT+CFUN=1,1'), { timeout: 5000 });

		if (self.dms)
			return qmi_backend.set_opmode(self.dms, 'offline', () =>
				qmi_backend.set_opmode(self.dms, 'reset', logerr('DMS reset')));

		log('warn', 'init reset requested but no AT port/DMS available — settings apply at the next reboot');
		step_datapath();
	};

	// datapath bring-up (datapath_qmi.uc)
	step_datapath = () => datapath_qmi.setup(self, dp, { log: log, fail: fail }, step_opmode);

	step_opmode = () => {
		self.set_state('SET_OPMODE');

		// before enabling the radio: debug-dump the current NAS preferred-network
		// list + SIM/network state (the actual restore runs at CONFIGURE_NET,
		// after SIM unlock, so a per-SIM configured list can resolve).
		sim.log_preradio(self, log, () => {
			qmi_backend.set_opmode(self.dms, 'online', (err) => {
				// (set_opmode already treats "no effect / already online" as success)
				if (err)
					return fail('opmode', err);

				verify_online(0);
			});
		});
	};

	// FCC RF unlock: laptop-SKU modems (Lenovo/Dell/HP Quectel EM1xx, Foxconn
	// SDX55/SDX62, DW5821e-class) accept set-online but STAY in (persistent)
	// low power until an FCC authentication message. Config `option fcc_auth`:
	//   unset/'auto'  try 'dms' then 'foxconn' when the modem stays low-power
	//   'off'         never try
	//   'dms' | 'foxconn[:<magic>]' | 'foxconn2:<string>:<number>'  explicit
	// Modems without the lock answer GET_OPERATING_MODE with online on the
	// first pass and never see an FCC message.
	let fcc_variants = () => {
		let o = self.config.fcc_auth;

		if (o == null || o == '' || o == 'auto')
			return [ [ 'dms', null ], [ 'foxconn', 0 ] ];

		if (o == 'off' || o == '0' || o == 'none')
			return [];

		let p = split(sprintf('%s', o), ':');

		if (p[0] == 'foxconn')
			return [ [ 'foxconn', (p[1] != null && p[1] != '') ? +p[1] : 0 ] ];

		if (p[0] == 'foxconn2')
			return [ [ 'foxconn2', { string: p[1] ?? '', number: +(p[2] ?? 0) } ] ];

		if (p[0] == 'dms')
			return [ [ 'dms', null ] ];

		log('warn', sprintf('unknown fcc_auth value %J — treating as auto', o));
		return [ [ 'dms', null ], [ 'foxconn', 0 ] ];
	};

	verify_online = (fcc_idx) => {
		self.dms.request('GET_OPERATING_MODE', {}, (err, d) => {
			let mode = err ? null : d?.mode;

			// unsupported query or already online -> settle and continue
			// (settle after mode change; old dialer: sleep 2)
			if (mode == null || mode == dmsmod.OPMODE_ONLINE)
				return tm.settle = uloop.timer(self.timing.settle, step_simslot);

			let locked = (mode == dmsmod.OPMODE_LOW_POWER ||
			              mode == dmsmod.OPMODE_PERSISTENT_LOW_POWER ||
			              mode == dmsmod.OPMODE_MODE_ONLY_LOW_POWER);

			let variants = fcc_variants();

			if (!locked || fcc_idx >= length(variants)) {
				log('warn', sprintf('modem stays in %s after set-online%s — continuing',
					dmsmod.OPMODE_NAMES[sprintf('%d', mode)] ?? sprintf('opmode %d', mode),
					(locked && length(variants)) ? ' (FCC authentication did not release it)' : ''));
				return tm.settle = uloop.timer(self.timing.settle, step_simslot);
			}

			let variant = variants[fcc_idx][0], magic = variants[fcc_idx][1];

			log('notice', sprintf('RF locked (%s) — trying FCC authentication (%s)',
				dmsmod.OPMODE_NAMES[sprintf('%d', mode)] ?? sprintf('opmode %d', mode), variant));

			qmi_backend.fcc_auth(self.dms, variant, magic, (ferr) => {
				if (ferr) {
					log('info', sprintf('FCC authentication (%s) not accepted: %J', variant, ferr));
					return verify_online(fcc_idx + 1);
				}

				log('notice', sprintf('FCC authentication accepted (%s) — going online', variant));
				qmi_backend.set_opmode(self.dms, 'online', () => verify_online(fcc_idx + 1));
			});
		}, { no_recovery: true });
	};

	// assert the configured physical SIM slot (option sim_slot, 0 = leave
	// as-is) before touching the SIM — a switch re-initializes the SIM stack
	step_simslot = () => {
		let want = +(self.config.sim_slot ?? 0);

		if (!want || !self.uim)
			return step_sim();

		sim.slot_status(self, (err, slots) => {
			if (err) {
				log('info', sprintf('sim_slot %d configured but slot status unsupported, continuing', want));
				return step_sim();
			}

			let cur = filter(slots, (s) => s.active)[0];

			if (cur?.physical == want)
				return step_sim();

			log('notice', sprintf('switching to SIM slot %d (active: slot %d)',
				want, cur?.physical ?? 0));

			sim.switch_slot(self, want, (serr) => {
				if (serr)
					log('warn', sprintf('sim slot switch failed: %J', serr));

				// slot changed -> a different eUICC may be present (the CA backend
				// is a modem capability, not card-bound, so it is not reset here)
				backend.reset(self, '_esim_be', '_apdu_be');
				tm.settle = uloop.timer(self.timing.sim_settle, step_sim);
			});
		});
	};

	// match the per-SIM override (config wwand_sim) BEFORE unlock so its pincode is
	// used. The MF-level ICCID is readable on a locked card; the extra read only
	// runs when overrides are configured.
	let resolve_active_sim = (next) => {
		self.active_sim = null;

		let sims = self.config?.sims;

		if (!sims || !length(sims))
			return next();

		sim.read_iccid(self, (iccid) => {
			if (iccid) {
				self.active_sim = match_sim_override(iccid, null);

				if (self.active_sim)
					log('notice', sprintf('SIM %s matched a configured wwand_sim (per-SIM pin/apn)', iccid));
			}

			next();
		});
	};

	step_sim = () => {
		self.set_state('SIM_UNLOCK');
		resolve_active_sim(() => sim.unlock(self, (err, status) => {
			if (err?.blocked) {
				// identify the card before going terminal so the log says *which*
				// SIM tripped the PIN guard. EF-IMSI is PIN-protected (may read null
				// on a locked card); the MF-level ICCID is readable regardless.
				sim.read_identity(self, (id) => {
					self.info.imsi = id.imsi;
					self.info.iccid = id.iccid;
					self.info.msisdn = id.msisdn;

					log('err', sprintf('sim blocked: imsi %s, iccid %s',
						id.imsi ?? '?', id.iccid ?? '?'));

					sim_block(err);
				});
				return; // terminal until reload
			}

			if (err)
				return fail('sim', err);

			log('notice', sprintf('sim: %s%s', status.status,
				(status.pin1_state != null)
					? sprintf(' (pin1 state %d, %d retries left)', status.pin1_state, status.pin1_retries)
					: ''));

			// remember the PIN-lock state for status() / LuCI. QMI UIM pin1_state:
			// 1/2 = enabled (not-/verified), 3 = disabled, 4/5 = (perm-)blocked.
			if (status.pin1_state != null)
				self.pin1 = {
					state: status.pin1_state,
					retries: status.pin1_retries,
					enabled: (status.pin1_state == 1 || status.pin1_state == 2),
				};

			step_identity();
		}));
	};

	// card identity, logged like the old proto handler did after unlock
	step_identity = () => {
		sim.read_identity(self, (id) => {
			self.info.imsi = id.imsi;
			self.info.iccid = id.iccid;
			self.info.msisdn = id.msisdn;

			log('notice', sprintf('imsi %s, iccid %s, msisdn %s',
				id.imsi ?? '?', id.iccid ?? '?', id.msisdn ?? '?'));

			// late per-SIM match: the pre-unlock matcher only saw the ICCID. Now the
			// IMSI is readable, accept an explicit `option imsi` (or an IMSI put in
			// the iccid field) so the carrier bundle still applies. Runs BEFORE
			// step_attach_profile so the LTE attach APN honors it too. PIN overrides
			// still need `option iccid` (the PIN was consumed before this point).
			if (!self.active_sim && id.imsi) {
				self.active_sim = match_sim_override(null, id.imsi);

				if (self.active_sim)
					log('notice', sprintf(
						'SIM imsi %s matched a configured wwand_sim (per-SIM apn/credentials; PIN overrides need option iccid)',
						id.imsi));
			}

			step_confnet();
		});
	};

	step_confnet = () => {
		self.set_state('CONFIGURE_NET');

		// now that the SIM is unlocked (before registration): a second debug dump
		// WITH the SIM/network identity (the pre-radio one at SET_OPMODE runs
		// before SIM unlock), then restore the configured preferred-PLMN list
		// (per-SIM wins over per-modem). Best-effort; failures logged, init proceeds.
		sim.log_preradio(self, log, () => sim.restore_preferred_plmn(self, log, () => step_confnet_apply()));
	};

	step_confnet_apply = () => {
		let mask = qmi_backend.parse_modes(self.config.modes);
		let sel = null;

		if (self.config.mcc && self.config.mnc) {
			sel = {
				mode: nasmod.NETWORK_SELECTION_MANUAL,
				mcc: +self.config.mcc,
				mnc: +self.config.mnc,
			};
		}

		// preserved: never reset modes/PLMN to defaults when unset
		if (mask == null && !sel)
			return step_validate();

		let args = {};

		if (mask != null)
			args.mode_preference = mask;

		if (sel)
			args.network_selection = sel;

		let attempt;

		attempt = (tries) => {
			self.nas.request('SET_SYSTEM_SELECTION_PREFERENCE', args, (err) => {
				if (err) {
					if (tries < MODES_TRIES)
						return attempt(tries + 1);

					log('warn', sprintf('failed to set system selection: %J', err));
					emit('modes_failed', { err: err });
				} else if (self._init_resets && modem_quirks.for_model(self.info?.model).settings_deferred) {
					// batched: push a reason, step_apply_init_reset issues ONE
					// reset at the end so the deferred values actually apply
					push(self._init_resets, 'system selection preference');
				}

				step_validate();
			});
		};

		// idempotency guard: read the live preference and drop whatever matches —
		// the boot path must not bounce the radio for values NV already carries.
		// The manual-PLMN target is not readable here (the GET carries only the
		// selection TYPE, and registration is not up yet at CONFIGURE_NET), so a
		// configured manual selection is conservatively (re-)applied.
		self.nas.request('GET_SYSTEM_SELECTION_PREFERENCE', {}, (gerr, cur) => {
			if (!gerr && cur) {
				if (args.mode_preference != null && cur.mode_preference == args.mode_preference) {
					log('info', sprintf('network modes "%s" already set — skipping', self.config.modes));
					delete args.mode_preference;
				}
			}

			if (!length(keys(args)))
				return step_validate();

			if (args.mode_preference != null)
				log('notice', sprintf('setting network modes "%s" (mask 0x%02x)', self.config.modes, args.mode_preference));

			if (args.network_selection)
				log('notice', sprintf('setting manual PLMN %d/%02d', sel.mcc, sel.mnc));

			attempt(1);
		});
	};

	// runtime config validation: confirm the LIVE modem reflects config + per-model
	// quirks, recording mismatches in self.config_warnings (ubus + log). Non-fatal;
	// complements config.uc's static parse-time warnings.
	step_validate = () => self.validate_config(() => step_attach_profile());

	// program the LTE attach profile (CID1) BEFORE registration so the autonomous
	// attach uses the right APN + IP family. On a change, cycle the radio so an
	// in-flight attach with the stale profile re-runs. See context.uc
	// ensure_attach_profile / the EMM #33 IPv4-only-attach finding.
	step_attach_profile = () => {
		let ctx = self.contexts[0];

		if (!ctx || !ctx.ensure_attach_profile || !self.dms)
			return step_register();

		ctx.ensure_attach_profile(1, (changed) => {
			if (!changed)
				return step_register();

			log('notice', 'attach profile changed, cycling radio to re-attach');
			qmi_backend.set_opmode(self.dms, 'low_power', () => {
				tm.settle = uloop.timer(self.timing.settle, () => {
					qmi_backend.set_opmode(self.dms, 'online', () => {
						tm.settle = uloop.timer(self.timing.settle, step_register);
					});
				});
			});
		});
	};

	step_register = () => {
		self.set_state('REGISTERING');
		self.reg_detail = null;

		self._arm_nas_event_report();

		self.nas.request('REGISTER_INDICATIONS', {
			serving_system_events: 1,
			signal_info: 1,
			network_time: 1,
		}, (err) => {
			// some modems lack this; fall back to the initial query result
			if (err)
				log('warn', sprintf('register indications failed: %J', err));

			// early probe: surface a reject cause / limited service within seconds
			// (an attach reject e.g. #33 shows up almost immediately once the modem
			// camps) instead of only at the full 240s timeout. Parked in tm so
			// teardown cancels it.
			tm.probe = uloop.timer(self.timing.regdetail_probe ?? 12000, () => {
				tm.probe = null;

				if (self.state != 'REGISTERING')
					return;

				self.collect_regdetail((d) => {
					if (self.state == 'REGISTERING' && d &&
					    (d.reject_text != null || d.reject_cause != null))
						log('warn', sprintf('registration rejected: %s%s',
							d.reject_text ?? sprintf('reject cause %d', d.reject_cause),
							d.limited ? ' [limited service]' : ''));
				});
			});

			tm.reg = uloop.timer(self.timing.reg_timeout, () => {
				if (self.state != 'REGISTERING')
					return;

				// surface WHY we're still not registered before failing — EMM
				// reject cause / limited service (see reg #33 attach finding)
				self.collect_regdetail((d) => {
					if (d && (d.reject_text != null || d.reject_cause != null))
						log('warn', sprintf('not registered: %s%s',
							d.reject_text ?? sprintf('reject cause %d', d.reject_cause),
							d.limited ? ' [limited service]' : ''));

					fail('registration_timeout', { reg: self.reg, detail: d });
				});
			});

			self.nas.request('GET_SERVING_SYSTEM', {}, (e2, d2) => {
				if (!e2)
					self._update_serving(d2);
			});
		});
	};

	// register() is re-entered by _update_serving when registration is lost
	// while READY (transient dereg -> back to the REGISTERING wait)
	return { begin: () => step_sync(0), register: () => step_register() };
};
