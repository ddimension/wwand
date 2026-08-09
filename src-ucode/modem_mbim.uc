// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — per-modem state machine for MBIM control (cdc_mbim driver).
//
// MBIM exposes a single control channel (no per-service client ids like QMI),
// so the flow is: open control channel -> MBIM OPEN -> DEVICE_CAPS /
// SUBSCRIBER_READY -> PIN (if required) -> REGISTER_STATE (wait home/roaming)
// -> PACKET_SERVICE attach -> READY. Registration and signal are kept fresh
// through INDICATE_STATUS notifications.
//
// The object exposes the same contract as modem.uc (start/stop/state/config/
// info/reg/signal/at/attach_context/note_connect_*/switch_protocol + events)
// so daemon.uc, the netifd shim and ubus stay protocol-neutral. Contexts use
// context_mbim.uc.

'use strict';

import * as uloop from 'uloop';
import * as transport_mod from './transport.uc';
import * as mbim_client from './mbim_client.uc';
import * as modem_common from './modem_common.uc';
import * as mbimmod from './codec/mbim.uc';
import * as recovery_mod from './recovery.uc';
import * as protoswitch from './protocol_switch.uc';
import * as telemetry_mbim from './telemetry_mbim.uc';
import * as netlink from './netlink.uc';
import * as bc from './codec/mbim-schema/basic_connect.uc';
import * as quectel_svc from './codec/mbim-schema/quectel.uc';
// rich telemetry: native-MBIM backend + the QMI-over-MBIM passthrough (the whole
// QMI client stack tunnelled over the open MBIM channel) + AT, chosen per
// capability like modem.uc does over qmux.
import * as backend from './backend.uc';
import * as mbim_backend from './mbim_backend.uc';
import * as qmi_backend from './qmi_backend.uc';
import * as qom from './qmi_over_mbim.uc';
import * as client_mod from './client.uc';
import * as ctlmod from './codec/schema/ctl.uc';
import * as nasmod from './codec/schema/nas.uc';
import * as dsdmod from './codec/schema/dsd.uc';
import * as uimmod from './codec/schema/uim.uc';
import * as wmsmod from './codec/schema/wms.uc';
import * as dmsmod from './codec/schema/dms.uc';
import * as sim from './sim.uc';

const TIMING_DEFAULTS = {
	...modem_common.TIMING_BASE,   // settle/reg_timeout/backoff_min/backoff_max
	at_drain: 60000,
};

export function create(opts)
{
	let self = {
		id: opts.id,
		device: opts.device,
		protocol: 'mbim',
		config: opts.config ?? {},
		timing: { ...TIMING_DEFAULTS, ...(opts.timing ?? {}) },

		state: 'ABSENT',
		hub: null,
		mbim: null,
		pt: null,          // lazy QMI-over-MBIM passthrough stack { shim, ctl, nas, dsd }
		info: {},
		reg: {},
		reg_detail: null,  // why (not) registered (reject cause / limited service)
		signal: {},
		cells: null,
		dsd_status: null,  // data-system mode { mode, lte, nr, source }
		location: null,
		at: null,
		at_tty: null,
		datapath: null,
		counters: null,
		contexts: [],
	};

	let deps = opts.deps ?? {};
	let transport_open = deps.transport_open ?? transport_mod.open;
	let log = deps.log ?? ((level, msg) => warn(sprintf('%s: modem %s: %s\n', level, self.id, msg)));
	self.log_fn = log;

	let rec = recovery_mod.create({
		id: opts.id,
		failreboot: (opts.config ?? {}).failreboot,
		proto_error_limit: (opts.config ?? {}).proto_error_limit,
		fx: opts.recovery?.fx ?? netlink.default_fx((l, m) => log(l, m)),
		state_dir: opts.recovery?.state_dir,
		reboot_delay: opts.recovery?.reboot_delay,
		// board-provided modem repower (power-cycle or reset-gpio pulse); replaces usb-repower
		repower: opts.recovery?.repower,
		log: (l, m) => log(l, m),
	});

	rec.load();
	self.counters = rec.counters;
	self.recovery = rec;

	let at_opts = opts.at ?? {};
	let retry_timer = null, reg_timer = null, settle_timer = null, at_drain_timer = null;

	// protocol-neutral scaffolding (set_state / attach_context /
	// note_connect_success / trip_zero_rx on self; emit + notify_contexts here)
	let scaffold = modem_common.scaffolding(self, { deps: deps, log: log, rec: rec });
	let emit = scaffold.emit;
	let notify_contexts = scaffold.notify_contexts;

	let hooks = {
		on_error: (c, kind) => {
			if (rec.on_proto_error() == 'reboot')
				rec.reboot('mbim error limit reached');
		},
		on_success: (c) => rec.on_proto_success(),
	};

	// backend-neutral NAS accessor (daemon settings / network-selection paths):
	// MBIM has no native NAS, so bring up the QMI-over-MBIM passthrough and hand
	// out its NAS client — a normal QMI client over the open channel, so
	// qmi_backend / nas.uc messages work unchanged. cb(nas|null).
	self.with_nas = function(cb) {
		self._ensure_pt((ok) => cb(ok ? self.pt.nas : null));
	};

	self.command = function(name, kind, args, cb, o) {
		self.mbim.command(bc, name, kind, args, cb, o);
	};

	// --- step chain --------------------------------------------------------

	let step_open, step_fcc, step_caps, step_at, step_datapath, step_sim, step_register, step_attach;

	let fail = modem_common.make_fail(self, {
		log: log, timing: self.timing, emit: emit,
		set_retry_timer: (t) => retry_timer = t,
	});

	modem_common.note_connect_failure_light(self, rec);


	step_open = () => {
		self.set_state('INIT_TRANSPORT');
		self.mbim = mbim_client.create(self.hub, hooks);

		// native MS UICC Low Level Access transport for eSIM/APDU. sim.uc picks
		// this duck-typed handle first (before the QMI passthrough and AT).
		self.mbim_uicc = {
			open:  (aid_hex, cb)           => mbim_backend.uicc_open_channel(self.mbim, aid_hex, (err, r) => {
				log('info', sprintf('native MBIM UICC open: %s', err ? sprintf('%J', err) : sprintf('channel %d', r?.channel)));
				cb(err, r);
			}),
			apdu:  (channel, apdu_hex, cb) => mbim_backend.uicc_apdu(self.mbim, channel, apdu_hex, cb),
			close: (channel, cb)           => mbim_backend.uicc_close_channel(self.mbim, channel, cb),
			reset: (cb)                    => mbim_backend.uicc_reset(self.mbim, cb),
		};

		// native MBIM SMS (no storage selector) — the sms.uc fallback for a
		// pure-MBIM modem without the QMI passthrough. Duck-typed like mbim_uicc.
		self.mbim_sms = {
			read_all: (cb)        => mbim_backend.sms_read_all(self.mbim, cb),
			del:      (index, cb) => mbim_backend.sms_delete(self.mbim, index, cb),
		};

		self.mbim.open((err) => {
			if (err)
				return fail('open', err);

			step_fcc();
		});
	};

	// FCC RF unlock (laptop-SKU Quectel modems in MBIM mode, e.g. EM120R-GL /
	// EM160R-GL in Lenovo machines): `option fcc_auth 'quectel'` sends the
	// vendor Radio State = on right after MBIM OPEN — the MBIM mirror of
	// ModemManager's `mbimcli --quectel-set-radio-state=on` unlock helper.
	// Best-effort: an error is logged and bring-up continues (an unlocked
	// modem simply ignores/rejects the vendor CID).
	step_fcc = () => {
		if (self.config.fcc_auth != 'quectel')
			return step_caps();

		self.mbim.command(quectel_svc, 'RADIO_STATE', 'set',
			{ radio_state: quectel_svc.RADIO_ON }, (err, data) => {
			if (err)
				log('warn', sprintf('FCC unlock (quectel radio state) failed: %J', err));
			else
				log('notice', sprintf('FCC unlock: quectel radio state now %d', data?.radio_state));

			step_caps();
		});
	};

	step_caps = () => {
		self.set_state('INIT_SERVICES');
		self.mbim.command(bc, 'DEVICE_CAPS', 'query', {}, (err, data) => {
			if (!err) {
				self.info.model = data.hardware_info ?? self.info.model;
				self.info.firmware = data.firmware_info;
				self.info.device_id = data.device_id;   // IMEI
				self.info.imei = data.device_id;
				self.info.max_sessions = data.max_sessions;
			}

			self.mbim.command(bc, 'SUBSCRIBER_READY_STATUS', 'query', {}, (e2, d2) => {
				if (!e2) {
					self.info.imsi = d2.subscriber_id;
					self.info.iccid = d2.sim_iccid;
					self._ready_state = d2.ready_state;
				}

				log('notice', sprintf('mbim device %s, imei %s, imsi %s, iccid %s',
					self.info.model ?? '?', self.info.imei ?? '?',
					self.info.imsi ?? '?', self.info.iccid ?? '?'));

				// per-SIM override (config wwand_sim) — parity with the QMI
				// backend: matched here (before the PIN step, so a pincode
				// override applies too), consumed by contexts via conn_cfg
				self.active_sim = modem_common.match_sim_override(
					self.config?.sims, self.info.iccid, self.info.imsi);
				if (self.active_sim)
					log('notice', sprintf('SIM %s matched a configured wwand_sim (per-SIM pin/apn)',
						self.info.iccid ?? self.info.imsi));

				// stable-identity gate (see modem_common.check_identity)
				if (!modem_common.check_identity(self, { emit: emit, log: log }))
					return;

				step_at();
			});
		});
	};

	// AT side channel: best-effort, for quirks, telemetry fallback and protocol
	// switching. Shared with the QMI backend (also gains model-init + M9200B
	// drain via the common helper).
	step_at = () => modem_common.open_at(self, {
		at_opts: at_opts,
		log: log,
		drain_interval: self.timing.at_drain,
		set_drain_timer: (t) => { at_drain_timer = t; },
		next: step_datapath,
	});

	// session datapath: parent netdev up, one VLAN sub-device per session id
	// > 0 (named after the context's mux_link so netifd's device binding
	// matches). Skipped gracefully when no datapath info is wired (host tests).
	step_datapath = () => {
		let dp = opts.datapath;

		if (!dp?.netdev || !dp.fx) {
			self.datapath = { backend: 'none', netdev: dp?.netdev ?? null, mux: [] };
			return step_sim();
		}

		let r = netlink.setup_mbim(dp.fx, {
			netdev: dp.netdev,
			mux: dp.mux_links ?? [],
		});

		self.datapath = {
			backend: 'cdc_mbim',
			netdev: dp.netdev,
			ep_id: null,
			mux: r.mux_devs,
		};

		log('notice', sprintf('datapath: cdc_mbim, mux [%s]', join(' ', r.mux_devs)));
		step_sim();
	};

	step_sim = () => {
		self.set_state('SIM_UNLOCK');

		// ready_state 1 = initialized (unlocked). Other states need a PIN or
		// signal a SIM problem.
		if (self._ready_state == bc.READY_STATE_INITIALIZED)
			return step_register();

		// no card: terminal like the QMI/NCM backends (sim_absent), NOT a
		// retriable failure — climbing the recovery ladder cannot conjure a
		// SIM and would pointlessly reset the modem forever. A later
		// SUBSCRIBER_READY_STATUS indication / hotplug re-runs the chain.
		// (HW-hit on a SIM-less RM520N-GL: the PIN query answers MBIM status
		// 3 and the old path counted connection attempts.)
		if (self._ready_state == bc.READY_STATE_SIM_NOT_INSERTED) {
			self.set_state('SIM_BLOCKED', { reason: 'sim_absent' });
			emit('sim_blocked', { reason: 'sim_absent' });
			notify_contexts('sim_blocked', {});
			return;
		}

		let pincode = sim.effective_pincode(self);

		self.mbim.command(bc, 'PIN', 'query', {}, (err, data) => {
			if (err) {
				// same terminal mapping when only the PIN query reveals it
				if (self._ready_state == bc.READY_STATE_SIM_NOT_INSERTED ||
				    err.status == bc.STATUS_SIM_NOT_INSERTED) {
					self.set_state('SIM_BLOCKED', { reason: 'sim_absent' });
					emit('sim_blocked', { reason: 'sim_absent' });
					notify_contexts('sim_blocked', {});
					return;
				}

				return fail('pin_query', err);
			}

			if (data.pin_state == bc.PIN_STATE_UNLOCKED)
				return step_register();

			let block = (reason) => {
				self.set_state('SIM_BLOCKED', { reason: reason, retries: data.remaining_attempts });
				emit('sim_blocked', { reason: reason, retries: data.remaining_attempts });
				notify_contexts('sim_blocked', {});
			};

			if (!pincode)
				return block('pin_required_no_pin');

			// PIN-safety: never auto-burn the last try (<=1 left blocks; 0 = PUK)
			let br = sim.pin_block_reason(data.remaining_attempts, self.pin_force);

			if (br)
				return block(br);

			self.mbim.command(bc, 'PIN', 'set', {
				pin_type: bc.PIN_TYPE_PIN1,
				pin_operation: bc.PIN_OP_ENTER,
				pin: pincode,
				new_pin: '',
			}, (verr, vdata) => {
				if (verr) {
					self.set_state('SIM_BLOCKED', { reason: 'verify_failed' });
					emit('sim_blocked', { reason: 'verify_failed' });
					notify_contexts('sim_blocked', {});
					return;
				}

				log('notice', 'sim: pin accepted');
				settle_timer = uloop.timer(self.timing.settle, step_register);
			});
		});
	};

	self._install_indications = function() {
		self.mbim.on(bc, 'REGISTER_STATE', (data) => self._update_register(data));
		// v1 RSSI floor: only fill in when no richer per-RAT signal is in place
		// (the SIGNAL_STATE_V2 / passthrough refresh below owns self.signal once
		// it resolves). data.rssi is the 0..31 coded index (99 = unknown).
		self.mbim.on(bc, 'SIGNAL_STATE', (data) => {
			if (!self.signal?.lte && !self.signal?.nr5g) {
				let dbm = (data.rssi != null && data.rssi != 99) ? (-113 + 2 * data.rssi) : null;
				self.signal = { rssi_raw: data.rssi, rssi: dbm };
			}
		});
		self.mbim.on(bc, 'PACKET_SERVICE', (data) => null);
		// SIM ready-state changes (hot-swap, removal, post-PIN initialisation) —
		// the MBIM counterpart of the QMI UIM CARD_STATUS_IND. Keep identity fresh
		// and surface SIM removal instead of running stale. (Closes the one native
		// MBIM indication gap vs the QMI backend.)
		self.mbim.on(bc, 'SUBSCRIBER_READY_STATUS', (data) => {
			let prev = self._ready_state;
			self._ready_state = data.ready_state;

			if (data.ready_state != prev)
				log('notice', sprintf('sim ready-state: %s',
					bc.READY_STATE_NAMES[sprintf('%d', data.ready_state)] ??
					sprintf('state %d', data.ready_state)));

			if (data.ready_state == bc.READY_STATE_INITIALIZED) {
				let changed = (data.sim_iccid != self.info.iccid ||
				               data.subscriber_id != self.info.imsi);
				if (data.subscriber_id != null && data.subscriber_id != '')
					self.info.imsi = data.subscriber_id;
				if (data.sim_iccid != null && data.sim_iccid != '')
					self.info.iccid = data.sim_iccid;
				if (changed) {
					// the card changed in place (eSIM switch / swap): the old
					// card's wwand_sim override must not stick — re-match
					self.active_sim = modem_common.match_sim_override(
						self.config?.sims, self.info.iccid, self.info.imsi);
					log('notice', sprintf('sim identity changed: iccid %s imsi %s%s',
						self.info.iccid ?? '?', self.info.imsi ?? '?',
						self.active_sim ? ' (matched a configured wwand_sim)' : ''));
					emit('sim_refresh', { iccid: self.info.iccid, imsi: self.info.imsi });
				}
			}
			else if (data.ready_state == bc.READY_STATE_SIM_NOT_INSERTED && prev != null) {
				log('warn', 'sim removed');
				emit('sim_removed', {});
			}
		});
		// unsolicited per-session (de)activation — the network dropping a data
		// context. Routed to the owning context by session id so it can tear the
		// session down (cdc_mbim carrier doesn't follow the session, so nothing
		// else notices). See context_mbim connect_indication.
		self.mbim.on(bc, 'CONNECT', (data) => self._on_connect_ind(data));
	};

	self._on_connect_ind = function(data) {
		for (let ctx in self.contexts)
			if (ctx.session_id == data.session_id && ctx.connect_indication)
				ctx.connect_indication(data);
	};

	self._update_register = function(data) {
		let st = data.register_state;
		let registered = (st == bc.REGISTER_STATE_HOME || st == bc.REGISTER_STATE_ROAMING ||
		                  st == bc.REGISTER_STATE_PARTNER);

		self.reg = {
			registration: registered ? 1 : 0,
			roaming: (st == bc.REGISTER_STATE_ROAMING),
			plmn: data.provider_id ? { description: data.provider_name, id: data.provider_id } : null,
			data_class: data.available_data_classes,
		};

		emit('serving_system', self.reg);

		if (registered && self.state == 'REGISTERING') {
			if (reg_timer) { reg_timer.cancel(); reg_timer = null; }
			// ATTACHING guards against REGISTER_STATE indications piling up
			// while the attach is in flight — each one used to re-run
			// step_attach and re-emit 'registered' (kick spam in the daemon)
			self.set_state('ATTACHING');
			step_attach();
		}
		else if (!registered && (self.state == 'READY' || self.state == 'ATTACHING')) {
			log('warn', 'registration lost');
			emit('deregistered', self.reg);
			notify_contexts('suspend', self.reg);
			step_register();
		}
	};

	step_register = () => {
		self.set_state('REGISTERING');
		self._install_indications();

		reg_timer = uloop.timer(self.timing.reg_timeout, () => {
			if (self.state == 'REGISTERING')
				fail('registration_timeout', { reg: self.reg });
		});

		self.mbim.command(bc, 'REGISTER_STATE', 'query', {}, (err, data) => {
			if (!err)
				self._update_register(data);
		});
	};

	step_attach = () => {
		// attach to the packet service before contexts can connect
		self.mbim.command(bc, 'PACKET_SERVICE', 'set',
			{ packet_service_action: bc.PACKET_SERVICE_ATTACH }, (err, data) => {
			if (self.state != 'ATTACHING')
				return;   // registration flapped while attaching

			// already-attached returns an error on some modems; tolerate it
			self.counters.attempts = 0;
			log('notice', sprintf('registered: plmn %J, roaming %J',
				self.reg.plmn?.description, self.reg.roaming));
			self.set_state('READY');
			emit('registered', self.reg);
			notify_contexts('ready');
			self._start_telemetry();
		});
	};

	// --- rich telemetry ----------------------------------------------------
	//
	// self.signal / self.cells / self.dsd_status / self.reg_detail are populated
	// in the SAME shapes the QMI modem.uc produces, so daemon.modem_signal /
	// modem_cells surface either backend unchanged. Each capability is sourced
	// via backend.choose in the order native-MBIM -> QMI-passthrough -> AT, the
	// choice cached per modem (_sig_be/_cells_be/_ca_be/_dsd_be/_regd_be).

	// Lazy, idempotent bring-up of the QMI-over-MBIM passthrough service stack.
	// The whole QMI client stack runs over the open MBIM channel (qom shim), so
	// qmi_backend.* works unchanged. Non-fatal: cb(false) simply drops the
	// capability to its AT/none fallback.
	//
	// CRITICAL: never CTL SYNC — on real HW that resets the embedded QMI state
	// and tears down the live MBIM data session. GET_VERSION_INFO is issued
	// directly, then a CID is allocated per needed service.
	self._ensure_pt = function(cb) {
		if (self.pt)
			return cb(true);

		// remembered "no passthrough on this modem" so we don't rebuild a shim +
		// re-probe on every capability (reset on teardown/protocol change)
		if (self._pt_failed || !self.mbim)
			return cb(false);

		let shim = qom.create(self.mbim, { log: log });
		let ctl = client_mod.create(shim, ctlmod.default, 0, hooks);

		let bail = () => { self._pt_failed = true; shim.close(); return cb(false); };

		ctl.request('GET_VERSION_INFO', {}, (verr, vdata) => {
			if (verr)
				return bail();

			let have = {};

			for (let svc in (vdata.services ?? []))
				have[sprintf('%d', svc.service)] = true;

			let alloc = (schema, done) => {
				ctl.request('ALLOCATE_CID', { service: schema.service }, (aerr, adata) => {
					if (aerr || !adata?.allocation)
						return done(null);

					done(client_mod.create(shim, schema, adata.allocation.cid, hooks));
				}, { no_recovery: true });
			};

			// NAS is mandatory for the passthrough to be useful; DSD is optional.
			alloc(nasmod.default, (nas) => {
				if (!nas)
					return bail();

				let finish = (dsd) => {
					self.pt = { shim: shim, ctl: ctl, nas: nas, dsd: dsd };
					cb(true);
				};

				if (have[sprintf('%d', dsdmod.default.service)])
					alloc(dsdmod.default, (dsd) => finish(dsd));
				else
					finish(null);
			});
		}, { no_recovery: true });
	};

	// _ensure_uim: allocate a QMI UIM client over the passthrough and expose it
	// as self.uim, so sim.uc's QMI UIM APDU/eSIM path works on an MBIM modem whose
	// firmware lacks native MS UICC Low Level Access but does expose the QMI
	// passthrough (the fallback for the native MBIM UICC path). cb() either way.
	// the card behind the modem changed in place (eSIM switch applied via the
	// SIM hot-reset): re-query the subscriber state and re-resolve the per-SIM
	// override — the old card's wwand_sim must not stick. Contexts pick the
	// corrected override up on their next (re)dial via conn_cfg. (No QMI-style
	// attach-profile step on MBIM — the attach APN rides in CONNECT.)
	self.reapply_sim = function(cb) {
		self.mbim.command(bc, 'SUBSCRIBER_READY_STATUS', 'query', {}, (err, d) => {
			if (!err) {
				if (d.subscriber_id != null && d.subscriber_id != '')
					self.info.imsi = d.subscriber_id;
				if (d.sim_iccid != null && d.sim_iccid != '')
					self.info.iccid = d.sim_iccid;
			}

			self.active_sim = modem_common.match_sim_override(
				self.config?.sims, self.info.iccid, self.info.imsi);
			log('notice', sprintf('sim reapply: iccid %s imsi %s%s',
				self.info.iccid ?? '?', self.info.imsi ?? '?',
				self.active_sim ? ' (matched a configured wwand_sim)' : ''));
			emit('sim_refresh', { iccid: self.info.iccid, imsi: self.info.imsi });

			if (cb)
				cb(null);
		});
	};

	self._ensure_uim = function(cb) {
		if (self.uim)
			return cb();

		self._ensure_pt((up) => {
			if (!up)
				return cb();

			self.pt.ctl.request('ALLOCATE_CID', { service: uimmod.default.service }, (aerr, adata) => {
				if (!aerr && adata?.allocation)
					self.uim = client_mod.create(self.pt.shim, uimmod.default, adata.allocation.cid, hooks);

				cb();
			}, { no_recovery: true });
		});
	};

	// _ensure_wms: allocate a QMI WMS client over the passthrough and expose it as
	// self.wms, so the backend-neutral sms.uc list/read/delete works on an MBIM
	// modem (the EG06 exposes the QMI stack — incl. WMS — over the passthrough).
	// cb() either way; sms.uc's qmi probe then verifies WMS List actually works.
	self._ensure_wms = function(cb) {
		if (self.wms)
			return cb();

		self._ensure_pt((up) => {
			if (!up)
				return cb();

			self.pt.ctl.request('ALLOCATE_CID', { service: wmsmod.default.service }, (aerr, adata) => {
				if (!aerr && adata?.allocation)
					self.wms = client_mod.create(self.pt.shim, wmsmod.default, adata.allocation.cid, hooks);

				cb();
			}, { no_recovery: true });
		});
	};

	// admin-triggered soft modem reset (ubus modem_reset — backend fallback of
	// the generic reset chain; backend parity with QMI/NCM): QMI DMS
	// offline -> reset over the passthrough (same sequence as the native QMI
	// backend), falling back to AT+CFUN=1,1 for modems without the passthrough.
	// The modem drops off the bus and re-enumerates; hotplug/discovery rebuild
	// it and the daemon kicks the auto interfaces back up.
	self.reset = function(cb) {
		let at_reset = () => {
			if (!self.at)
				return cb({ error: 'unsupported_on_backend' });

			log('warn', 'admin modem reset (AT+CFUN=1,1)');
			self.at.send('AT+CFUN=1,1', () => {
				notify_contexts('lost');
				cb(null, { resetting: true });
			}, { timeout: 8000 });
		};

		self._ensure_pt((up) => {
			if (!up)
				return at_reset();

			self.pt.ctl.request('ALLOCATE_CID', { service: dmsmod.default.service }, (aerr, adata) => {
				if (aerr || !adata?.allocation)
					return at_reset();

				let dms = client_mod.create(self.pt.shim, dmsmod.default, adata.allocation.cid, hooks);

				log('warn', 'admin modem reset (DMS offline -> reset over the MBIM passthrough)');
				qmi_backend.set_opmode(dms, 'offline', () =>
					qmi_backend.set_opmode(dms, 'reset', () => {
						notify_contexts('lost');
						cb(null, { resetting: true });
					}));
			}, { no_recovery: true });
		});
	};

	// telemetry (signal/cells/CA/data-mode/reg-detail + slow log loop + fast
	// watch loop) — extracted to telemetry_mbim.uc; attaches the _refresh_*
	// methods, watch and _start_telemetry, returns { stop } for teardown.
	let telem = telemetry_mbim.install(self, { log: log, emit: emit });

	// --- lifecycle ---------------------------------------------------------

	self.switch_protocol = function(target, cb) {
		protoswitch.switch_protocol(self, target, (err, res) => {
			if (!err && res.resetting) {
				emit('protocol_switch', { target: target });
				notify_contexts('lost');
				self.teardown();
				self.set_state('ABSENT');
			}

			cb(err, res);
		});
	};

	self.protocol_switch_supported = function() {
		return protoswitch.supported(self.info?.model);
	};

	self.start = function() {
		if (self.hub)
			return;

		self.hub = transport_open(self.device, {
			on_raw: (hub, msg) => {
				let dec = mbimmod.decode(msg);

				if (dec && self.mbim)
					self.mbim.on_message(dec);
			},
			on_gone: () => self._device_gone(),
		});

		if (!self.hub)
			return fail('open', { error: 'open', device: self.device });

		step_open();
	};

	self.teardown = function() {
		for (let t in [ retry_timer, reg_timer, settle_timer, at_drain_timer ])
			if (t)
				t.cancel();

		retry_timer = reg_timer = settle_timer = at_drain_timer = null;
		telem.stop();

		modem_common.close_at(self);

		// passthrough QMI stack (torn down before the mbim channel it rides on).
		// A fresh session must re-probe, so forget the cached backend choices.
		if (self.pt) {
			for (let c in [ self.pt.ctl, self.pt.nas, self.pt.dsd ])
				if (c)
					c.destroy();

			self.pt.shim.close();
			self.pt = null;
		}

		// the passthrough-allocated UIM client (if any) rode on the shim just closed
		self.uim = null;
		self._pt_failed = false;
		backend.reset(self, '_sig_be', '_cells_be', '_ca_be', '_dsd_be', '_regd_be', '_apdu_be', '_esim_be');

		if (self.mbim) {
			self.mbim.destroy();
			self.mbim = null;
			self.mbim_uicc = null;
			self.mbim_sms = null;
		}

		if (self.hub) {
			self.hub.close();
			self.hub = null;
		}
	};

	// stop() + _device_gone() installed by modem_common.scaffolding

	return self;
};
