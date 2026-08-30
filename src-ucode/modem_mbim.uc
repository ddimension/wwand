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
import * as transport_mod from 'wwand.transport';
import * as mbim_client from 'wwand.mbim_client';
import * as modem_common from 'wwand.modem_common';
import * as mbimmod from 'wwand.codec.mbim';
import * as telemetry_mbim from 'wwand.telemetry_mbim';
import * as netlink from 'wwand.netlink';
import * as bc from 'wwand.codec.mbim_schema.basic_connect';
import * as ext from 'wwand.codec.mbim_schema.ms_basic_connect_ext';
import * as context_common from 'wwand.context_common';
import * as quectel_svc from 'wwand.codec.mbim_schema.quectel';
// rich telemetry: native-MBIM backend + the QMI-over-MBIM passthrough (the whole
// QMI client stack tunnelled over the open MBIM channel) + AT, chosen per
// capability like modem.uc does over qmux.
import * as backend from 'wwand.backend';
import * as mbim_backend from 'wwand.mbim_backend';
import * as qmi_backend from 'wwand.qmi_backend';
import * as qom from 'wwand.qmi_over_mbim';
import * as client_mod from 'wwand.client';
import * as ctlmod from 'wwand.codec.schema.ctl';
import * as nasmod from 'wwand.codec.schema.nas';
import * as dsdmod from 'wwand.codec.schema.dsd';
import * as uimmod from 'wwand.codec.schema.uim';
import * as wmsmod from 'wwand.codec.schema.wms';
import * as dmsmod from 'wwand.codec.schema.dms';
import * as sim from 'wwand.sim';

const TIMING_DEFAULTS = {
	...modem_common.TIMING_BASE,   // settle/reg_timeout/backoff_min/backoff_max
	at_drain: 60000,
};

// SIM-init wait (ready_state 0 after MBIM open on a cold boot) — mirrors the
// QMI backend's CARD_POLL_TRIES/CARD_POLL_MS in sim.uc
const SIM_POLL_TRIES = 10;
const SIM_POLL_MS = 1000;


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

	let rec = modem_common.make_recovery(self, opts, log, 'mbim');

	let at_opts = opts.at ?? {};
	let retry_timer = null, reg_timer = null, settle_timer = null, at_drain_timer = null,
	    sim_poll_timer = null;

	// protocol-neutral scaffolding (set_state / attach_context /
	// note_connect_success / trip_zero_rx on self; emit + notify_contexts here)
	let scaffold = modem_common.scaffolding(self, { deps: deps, log: log, rec: rec });
	let emit = scaffold.emit;
	let notify_contexts = scaffold.notify_contexts;
	let sim_block = scaffold.sim_block;
	let enter_ready = scaffold.enter_ready;

	let hooks = {
		on_error: (c, kind) => {
			let act = rec.on_proto_error();
			// same escalation as QMI: a wedged control channel gets a hardware
			// reset first; reboot only if that fails to clear it (the NR7101
			// reboot-loop fix — see recovery.on_proto_error)
			if (act == 'usb_repower')
				rec.usb_repower();
			else if (act == 'reboot')
				rec.reboot('mbim error limit reached');

			log('debug', sprintf('mbim proto error (%s), counter %d',
				kind ?? '?', self.counters.proto_errors));
		},
		on_success: (c) => rec.on_proto_success(),
		// see the QMI side: "the modem answered MBIM", which a failure status
		// establishes as well as a success (recovery.note_answer)
		on_answer: (c) => rec.note_answer(),
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

	let step_open, step_fcc, step_caps, step_at, step_at_ident, step_datapath, step_simslot, step_sim, step_attach_profile, step_register, step_attach;

	let fail = modem_common.make_fail(self, {
		log: log, timing: self.timing, emit: emit,
		set_retry_timer: (t) => retry_timer = t,
		rec: rec,
	});

	// soft recovery rungs (parity with QMI's DMS-based implementations):
	// opmode_cycle = radio off -> settle -> on; modem_reset = self.reset
	// (passthrough DMS offline->reset, AT+CFUN=1,1 fallback)
	modem_common.note_connect_failure_light(self, rec, {
		opmode_cycle: (done) => {
			if (!self.mbim)
				return done();

			log('warn', 'recovery: cycling radio state');
			self.mbim.command(bc, 'RADIO_STATE', 'set',
				{ radio_state: bc.RADIO_STATE_OFF }, () => {
					settle_timer = uloop.timer(self.timing.settle, () => {
						self.mbim.command(bc, 'RADIO_STATE', 'set',
							{ radio_state: bc.RADIO_STATE_ON }, () => {
								settle_timer = uloop.timer(self.timing.settle, done);
							});
					});
				});
		},
		modem_reset: (done) => {
			log('warn', 'recovery: resetting modem');
			self.reset((err) => done());
		},
	});


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

		// PUK entry for sim.unblock_puk (duck-typed like mbim_uicc so the base
		// sim.uc stays free of mbim imports): PIN set with PUK1 + ENTER carries
		// the new PIN per the MBIM spec.
		self.mbim_pin = {
			unblock: (puk, new_pin, cb) => self.mbim.command(bc, 'PIN', 'set', {
				pin_type: bc.PIN_TYPE_PUK1,
				pin_operation: bc.PIN_OP_ENTER,
				pin: puk, new_pin: new_pin,
			}, (err, d) => cb(err, err ? null : { retries: d?.remaining_attempts })),
		};

		// native MBIM multi-slot (MS BCE SysCaps/DeviceSlotMappings/SlotInfo-
		// Status) — sim.uc's slot fallback when the passthrough UIM is
		// unavailable. Duck-typed like mbim_uicc.
		self.mbim_slots = {
			status:    (cb)           => mbim_backend.slot_status(self.mbim, cb),
			switch_to: (physical, cb) => mbim_backend.slot_switch(self.mbim, physical, cb),
		};

		// SYS_CAPS answers the executor/concurrency question exactly, which QMI
		// cannot be asked at all. slot_status() parks it on the client when it
		// reads the slot count; expose it so status() can report the shape of
		// this modem rather than inferring it. Getter, not a copy: the value
		// only exists after the first slot query.
		self.multisim_caps = null;
		self.read_multisim_caps = (cb) => {
			if (self.multisim_caps)
				return cb(self.multisim_caps);

			mbim_backend.sys_caps(self.mbim, (err, caps) => {
				if (!err && caps)
					self.multisim_caps = caps;

				cb(self.multisim_caps);
			});
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
				// status `revision` (QMI parity — stayed null on MBIM; AT ATI
				// overwrites it later with the richer string when a port works)
				self.info.revision = self.info.revision ?? data.firmware_info;
				self.info.device_id = data.device_id;   // IMEI
				self.info.imei = data.device_id;
				self.info.max_sessions = data.max_sessions;
				// supported-RAT bitmask -> caps.rats natively (no passthrough/AT).
				// Some modems (Quectel RM520N) leave the 5G bits unset and instead
				// set the CUSTOM bit, describing the extra classes in the free-text
				// custom_data_class string ("5G/TDS") — kept so caps can read it.
				self.info.mbim_data_class = data.data_class;
				self.info.mbim_custom_data_class = data.custom_data_class;
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
	//
	// `option at_over_mbim '<fibocom|compal|1>'` (default unset): route AT over
	// the vendor AT-over-MBIM CID instead of opening a serial port. The tunnel
	// engine is duck-typed exactly like the tty engine, so step_at_ident and the
	// telemetry fallbacks use it unchanged (telemetry_at returns
	// self.at_telemetry). NOT HW-validated.
	//
	// It is not the only way in, and the comment used to claim otherwise:
	// modem_common.open_at() falls back to the same pipe on its own whenever
	// there is no tty or the tty will not open. What this option adds is
	// FORCING it past a working tty, and choosing the vendor CID flavour — the
	// automatic path cannot pick 'compal'. `option at_mbim '0'` turns the
	// automatic fallback off.
	step_at = () => {
		let aom = self.config?.at_over_mbim;

		if (aom) {
			let vendor = (aom == 'compal') ? 'compal' : 'fibocom';
			let eng = mbim_backend.make_at_engine(self.mbim, vendor);

			log('notice', sprintf('AT side channel over MBIM (%s vendor CID)', vendor));
			self.at = eng;
			self.at_telemetry = eng;
			return step_at_ident();
		}

		return modem_common.open_at(self, {
			at_opts: at_opts,
			log: log,
			drain_interval: self.timing.at_drain,
			set_drain_timer: (t) => { at_drain_timer = t; },
			next: step_at_ident,
		});
	};

	// MBIM DEVICE_CAPS carries no manufacturer — fill it best-effort from the AT
	// side channel (AT+CGMI), for parity with the QMI DMS / NCM CGMI identity.
	// Fully non-blocking: no AT, an error or a timeout just leaves it null and
	// proceeds (some MBIM firmwares answer AT slowly or not at all).
	step_at_ident = () => {
		if (self.info.manufacturer || !self.at)
			return step_datapath();

		self.at.send('AT+CGMI', (err, res) => {
			if (!err)
				for (let l in (res?.lines ?? [])) {
					let t = trim(replace(l, /^\+CGMI:\s*/, ''));

					if (t != '' && t != 'OK' && !match(t, /^[+^]/)) {
						self.info.manufacturer = t;
						break;
					}
				}

			step_datapath();
		}, { timeout: 3000 });
	};

	// Session datapath. It goes through the SAME netlink.setup() as QMI — the
	// cdc_mbim session mux is the built-in `vlan` backend there (one VLAN
	// sub-device per session id > 0, named after the context's mux_link so
	// netifd's device binding matches). It used to be a netlink.setup_mbim() of
	// its own, and the copy drifted: the stale-child prune was fixed in setup()
	// and missed here, leaving this path with the very defect it was fixed for.
	// Skipped gracefully when no datapath info is wired (host tests).
	step_datapath = () => {
		let dp = opts.datapath;

		if (!dp?.netdev || !dp.fx) {
			self.datapath = { backend: 'raw_ip', netdev: dp?.netdev ?? null, mux: [] };
			return step_simslot();
		}

		let mux_links = dp.mux_links ?? [];
		let want_mux = length(filter(mux_links, (e) => e.id > 0)) > 0;
		let backend = netlink.select_backend(dp.fx, dp.netdev, dp.mux ?? 'auto',
			want_mux, dp.plugins, { model: self.info?.model, proto: 'mbim' });

		// `option mux` named a datapath whose package is not installed. Never
		// substitute another one silently (the contract in netlink.uc): the
		// sessions would come up on the wrong link names and netifd would bind
		// nothing. Reported the way a missing control backend is.
		if (backend == null) {
			if (want_mux)
				return fail('datapath', { error: 'mux_backend_unavailable', mux: dp.mux });

			backend = 'raw_ip';
		}

		let r = netlink.setup(dp.fx, {
			netdev: dp.netdev,
			backend: backend,
			plugins: dp.plugins,
			mux: mux_links,
			mtu: dp.mtu,
		});

		if (!r.ok)
			return fail('datapath', r);

		// setup() may move the parent to a raw kernel name (freeing a stale
		// stable-L3 name for a mux child) — follow it
		let parent = r.parent ?? dp.netdev;

		self.datapath = {
			// what setup() ACTUALLY ran: it drops to raw_ip when the selected
			// backend has no channels to build (session 0 only)
			backend: r.backend ?? backend,
			netdev: parent,
			parent: parent,
			ep_id: null,
			// config channel -> the id the modem must tag it with. On MBIM that
			// IS the session id (context_mbim.wire_session), so dropping it here
			// silently disables every remap a datapath asks for — which is
			// exactly what happened until this line existed.
			map_ids: r.map_ids,
			mux: r.mux_devs,
			mux_devs: r.mux_devs,
		};

		log('notice', sprintf('datapath: %s, parent %s, mux [%s]', backend, parent, join(' ', r.mux_devs)));
		step_simslot();
	};

	// assert the configured physical SIM slot before touching the SIM (QMI
	// parity — `option sim_slot` was silently ignored on MBIM). sim.slot_status/
	// switch_slot handle the MBIM transports themselves (passthrough UIM on
	// demand, native MS-BCE fallback); unsupported -> log + continue.
	step_simslot = () => {
		let want = +(self.config.sim_slot ?? 0);

		if (!want)
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

				// a different eUICC may be present after the switch
				backend.reset(self, '_esim_be', '_apdu_be');
				settle_timer = uloop.timer(self.timing.sim_settle ?? 5000, step_sim);
			});
		});
	};

	step_sim = (tries) => {
		self.set_state('SIM_UNLOCK');

		// ready_state 1 = initialized (unlocked). Other states need a PIN or
		// signal a SIM problem.
		if (self._ready_state == bc.READY_STATE_INITIALIZED)
			return step_attach_profile();

		// no card: terminal like the QMI/NCM backends (sim_absent), NOT a
		// retriable failure — climbing the recovery ladder cannot conjure a
		// SIM and would pointlessly reset the modem forever. A later
		// SUBSCRIBER_READY_STATUS indication / hotplug re-runs the chain.
		// (HW-hit on a SIM-less RM520N-GL: the PIN query answers MBIM status
		// 3 and the old path counted connection attempts.)
		if (self._ready_state == bc.READY_STATE_SIM_NOT_INSERTED) {
			sim_block({ reason: 'sim_absent' });
			return;
		}

		// SIM still initializing (cold boot: MBIM opens before the card is
		// up — ready_state 0, no imsi/iccid yet). Wait like the QMI backend's
		// card poll instead of racing ahead: a PIN query answered mid-init
		// reports "locked" for a PIN-disabled card, and the ENTER the old
		// path then sent came back as an error (no retry consumed) that was
		// mapped to a terminal SIM_BLOCKED/verify_failed. HW-hit on a
		// GL-X3000 (RM520N, sim_slot 2) on every cold boot.
		if (self._ready_state == bc.READY_STATE_NOT_INITIALIZED) {
			if ((tries ?? 0) >= SIM_POLL_TRIES)
				return fail('sim_ready', { error: 'sim_not_initialized' });

			sim_poll_timer = uloop.timer(self.timing.card_poll ?? SIM_POLL_MS, () => {
				self.mbim.command(bc, 'SUBSCRIBER_READY_STATUS', 'query', {}, (e2, d2) => {
					if (!e2) {
						self._ready_state = d2.ready_state;

						// the boot-time identity query ran before the card:
						// imsi/iccid and the per-SIM override are still
						// unset — refresh them now (mirrors the indication
						// handler; some firmwares never send the indication)
						if (d2.ready_state == bc.READY_STATE_INITIALIZED) {
							if (d2.subscriber_id != null && d2.subscriber_id != '')
								self.info.imsi = d2.subscriber_id;
							if (d2.sim_iccid != null && d2.sim_iccid != '')
								self.info.iccid = d2.sim_iccid;
							self.active_sim = modem_common.match_sim_override(
								self.config?.sims, self.info.iccid, self.info.imsi);
							log('notice', sprintf('sim initialized after wait (poll %d): imsi %s, iccid %s%s',
								(tries ?? 0) + 1, self.info.imsi ?? '?', self.info.iccid ?? '?',
								self.active_sim ? ' (matched a configured wwand_sim)' : ''));
						}
					}

					step_sim((tries ?? 0) + 1);
				});
			});
			return;
		}

		let pincode = sim.effective_pincode(self);

		self.mbim.command(bc, 'PIN', 'query', {}, (err, data) => {
			if (err) {
				// same terminal mapping when only the PIN query reveals it
				if (self._ready_state == bc.READY_STATE_SIM_NOT_INSERTED ||
				    err.status == bc.STATUS_SIM_NOT_INSERTED) {
					sim_block({ reason: 'sim_absent' });
					return;
				}

				return fail('pin_query', err);
			}

			// status `pin1` (QMI parity — stayed null on MBIM): MBIM only
			// reports the CURRENTLY required pin, so `enabled` is unknowable
			// once unlocked (null, not false)
			self.pin1 = {
				state: (data.pin_state == bc.PIN_STATE_LOCKED) ? 1 : 2,
				retries: data.remaining_attempts,
				enabled: (data.pin_state == bc.PIN_STATE_LOCKED &&
				          data.pin_type == bc.PIN_TYPE_PIN1) ? true : null,
			};

			if (data.pin_state == bc.PIN_STATE_UNLOCKED)
				return step_attach_profile();

			let block = (reason) =>
				sim_block({ reason: reason, retries: data.remaining_attempts });

			// The card may be waiting for something our PIN1 ENTER cannot
			// satisfy — a PUK, PIN2 or a personalization code. Entering PIN1
			// there loops fail('pin_verify') -> recovery ladder -> resets on a
			// SIM only a PUK can fix. Terminal-block instead (like QMI/NCM).
			let pt = data.pin_type;

			if (pt == bc.PIN_TYPE_PUK1 || pt == bc.PIN_TYPE_PUK2)
				return block('puk_required');

			if (pt >= bc.PIN_TYPE_NETWORK_PIN && pt <= bc.PIN_TYPE_CORPORATE_PIN)
				return block('personalization');

			if (pt == bc.PIN_TYPE_PIN2) {
				// PIN2 gates FDN/settings only, not attach — carry on
				log('notice', 'sim: pin2 requested by card, not required for attach');
				return step_attach_profile();
			}

			if (pt != null && pt != bc.PIN_TYPE_PIN1)
				return block('pin_type_unsupported');

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
					// A rejected ENTER is either a genuinely wrong PIN (a
					// retry was consumed) or the firmware refusing the
					// operation (SIM mid-init / PIN1 not enabled — no retry
					// consumed). Only the former may be terminal: re-query
					// and let the retry counter decide.
					self.mbim.command(bc, 'PIN', 'query', {}, (qerr, qdata) => {
						if (!qerr && qdata.pin_state == bc.PIN_STATE_UNLOCKED) {
							// the verify reply got lost/garbled but took effect
							log('notice', 'sim: pin accepted (verify reply lost)');
							settle_timer = uloop.timer(self.timing.settle, step_attach_profile);
							return;
						}

						if (!qerr && qdata.remaining_attempts != null &&
						    data.remaining_attempts != null &&
						    qdata.remaining_attempts < data.remaining_attempts) {
							sim_block({ reason: 'verify_failed', retries: qdata.remaining_attempts });
							return;
						}

						// no retry consumed -> transient refusal; retriable
						// (the pin_block_reason guard above still keeps a
						// later attempt from burning the last try)
						fail('pin_verify', verr);
					});
					return;
				}

				log('notice', 'sim: pin accepted');
				self.pin1 = { state: 2, retries: vdata?.remaining_attempts ?? data.remaining_attempts,
				              enabled: true };
				settle_timer = uloop.timer(self.timing.settle, step_attach_profile);
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
		// match on the WIRE session id: a datapath that adopts a driver's own
		// children can remap it (the Quectel MHI driver offsets MBIM sessions by
		// 112 on an SDX7x), and matching the configured channel number would
		// silently drop every indication — taking MBIM's primary
		// session-loss signal with it. Identity wherever nothing remaps.
		for (let ctx in self.contexts) {
			let sid = (type(ctx.wire_session) == 'function')
				? ctx.wire_session() : ctx.session_id;

			if (sid == data.session_id && ctx.connect_indication)
				ctx.connect_indication(data);
		}
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

		// why (not) registered — MBIM carries the 3GPP reject cause (NwError)
		// inline in every REGISTER_STATE response/indication. Capture it HERE
		// so a denied/limited registration is visible immediately (status +
		// the registration_timeout failure), not only once the slow telemetry
		// loop has run; a clean registration clears any stale cause.
		if ((data.nw_error != null && data.nw_error != 0) ||
		    st == bc.REGISTER_STATE_DENIED) {
			let d = { source: 'mbim', limited: (st == bc.REGISTER_STATE_DENIED) };

			if (data.nw_error != null && data.nw_error != 0) {
				d.reject_cause = data.nw_error;
				d.reject_text = nasmod.REJECT_CAUSE[sprintf('%d', data.nw_error)] ??
					sprintf('reject cause %d', data.nw_error);
			}

			let prev = self.reg_detail;

			self.reg_detail = d;

			if (prev?.reject_cause != d.reject_cause || prev?.limited != d.limited)
				log('warn', sprintf('registration problem: %s%s',
					d.reject_text ?? 'limited service',
					(d.limited && d.reject_text) ? ' (limited service)' : ''));
		}
		else if (registered) {
			self.reg_detail = null;
		}

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

	// Program the default LTE attach context (MS BCE LTE_ATTACH_CONFIG, CID 3)
	// from the primary context's config BEFORE registering, so the modem's
	// *autonomous* EPS attach uses the right APN + IP family. The modem attaches
	// before wwand ever issues a CONNECT, so a stale/carrier-default attach APN
	// gets the whole attach rejected (LIMSRV / EMM reject) and we never reach a
	// data session. MBIM parity with modem_init_qmi step_attach_profile /
	// context.uc ensure_attach_profile. On a change, cycle the radio so an
	// already-completed attach with the stale profile re-runs. Best-effort:
	// firmware without the CID (or any error) just proceeds to step_register.
	step_attach_profile = () => {
		let ctx = self.contexts[0];

		if (!ctx || !self.mbim)
			return step_register();

		let apn = context_common.conn_cfg(ctx, 'apn');

		// no configured APN, or '#N' (use the modem-provisioned context as-is) —
		// never overwrite the SIM/modem-provisioned attach context (QMI parity)
		if (apn == null || apn == '' || substr(apn, 0, 1) == '#')
			return step_register();

		let want_ip = bc.IP_TYPE_FROM_PDP[ctx.config.pdp_type ?? 'ipv4v6'] ?? bc.IP_TYPE_IPV4V6;
		let user = context_common.conn_cfg(ctx, 'username') ?? '';
		let pass = context_common.conn_cfg(ctx, 'password') ?? '';
		let auth = bc.AUTH_FROM_CFG[context_common.conn_cfg(ctx, 'auth')] ?? bc.AUTH_NONE;

		mbim_backend.get_lte_attach_config(self.mbim, (gerr, cur) => {
			// compare against the home-roaming context (fallback: the first)
			let home = null;

			for (let c in (cur?.contexts ?? []))
				if (c.roaming == ext.ROAMING_HOME) { home = c; break; }

			home ??= (cur?.contexts ?? [])[0];

			let cur_apn = home?.access_string ?? '';
			let cur_ip = home?.ip_type;

			// up to date: same APN and (unknown or matching) IP family — leave it
			if (!gerr && cur_apn == apn && (cur_ip == null || cur_ip == want_ip)) {
				log('debug', sprintf('attach profile up to date (apn %J, ip %J)', cur_apn, cur_ip));
				return step_register();
			}

			// overwrite all three roaming contexts with the same config (a Set
			// must carry exactly three, one per roaming condition)
			let mk = (roaming) => ({
				ip_type: want_ip, roaming: roaming, source: ext.CONTEXT_SOURCE_ADMIN,
				access_string: apn, user_name: user, password: pass,
				compression: 0, auth_protocol: auth,
			});

			log('notice', sprintf('attach profile: apn %J -> %J, ip %J (was %J)',
				cur_apn == '' ? '(default)' : cur_apn, apn, want_ip, cur_ip));

			mbim_backend.set_lte_attach_config(self.mbim,
				[ mk(ext.ROAMING_HOME), mk(ext.ROAMING_PARTNER), mk(ext.ROAMING_NON_PARTNER) ],
				(serr) => {
				if (serr) {
					log('warn', sprintf('attach profile set failed: %J — continuing', serr));
					return step_register();
				}

				self.effective_apn = apn;

				// force the (possibly already-completed) autonomous attach to
				// re-run with the new profile: radio off -> settle -> on -> settle
				log('notice', 'attach profile changed, cycling radio to re-attach');
				self.mbim.command(bc, 'RADIO_STATE', 'set',
					{ radio_state: bc.RADIO_STATE_OFF }, () => {
					settle_timer = uloop.timer(self.timing.settle, () => {
						self.mbim.command(bc, 'RADIO_STATE', 'set',
							{ radio_state: bc.RADIO_STATE_ON }, () => {
							settle_timer = uloop.timer(self.timing.settle, step_register);
						});
					});
				});
			});
		});
	};

	step_register = () => {
		// before registering: debug-dump the NAS preferred list + SIM/network,
		// then restore the configured list (per-SIM wins over per-modem) — via the
		// QMI-over-MBIM passthrough NAS / AT+CPOL. Best-effort, never blocks.
		sim.log_preradio(self, log, () => sim.restore_preferred_plmn(self, log, () => {
			self.set_state('REGISTERING');
			self._install_indications();

			reg_timer = uloop.timer(self.timing.reg_timeout, () => {
				if (self.state == 'REGISTERING')
					fail('registration_timeout', { reg: self.reg, detail: self.reg_detail });
			});

			self.mbim.command(bc, 'REGISTER_STATE', 'query', {}, (err, data) => {
				if (!err)
					self._update_register(data);
			});
		}));
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
			enter_ready(() => self._start_telemetry());
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
	// corrected override up on their next (re)dial via conn_cfg. (The LTE attach
	// APN is programmed separately in step_attach_profile before registration.)
	self.reapply_sim = function(cb) {
		self.mbim.command(bc, 'SUBSCRIBER_READY_STATUS', 'query', {}, (err, d) => {
			if (!err) {
				if (d.subscriber_id != null && d.subscriber_id != '')
					self.info.imsi = d.subscriber_id;
				if (d.sim_iccid != null && d.sim_iccid != '')
					self.info.iccid = d.sim_iccid;
			}

			scaffold.resolve_active_sim(self.info.iccid, self.info.imsi);

			if (cb)
				cb(null);
		});
	};

	// ensure a QMI client over the passthrough and cache it as self[field]:
	// one factory for the identical _ensure_uim/_ensure_wms bodies. cb() either
	// way — the caller's probe verifies the service actually answers.
	let ensure_pt_client = (field, schema) => (cb) => {
		if (self[field])
			return cb(self[field]);

		self._ensure_pt((up) => {
			if (!up)
				return cb(null);

			self.pt.ctl.request('ALLOCATE_CID', { service: schema.default.service }, (aerr, adata) => {
				if (!aerr && adata?.allocation)
					self[field] = client_mod.create(self.pt.shim, schema.default, adata.allocation.cid, hooks);

				cb(self[field]);
			}, { no_recovery: true });
		});
	};

	self._ensure_uim = ensure_pt_client('uim', uimmod);

	// self.wms via the passthrough so the backend-neutral sms.uc list/read/
	// delete works on an MBIM modem (the EG06 exposes QMI-WMS over it)
	self._ensure_wms = ensure_pt_client('wms', wmsmod);

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

	// network reattach (ubus modem_reattach): detach/attach at registration
	// level WITHOUT a full reset. Preference: passthrough DMS low_power ->
	// online (identical to the HW-proven QMI path), else native RADIO_STATE
	// off -> on. Implemented here because netsel_ops' AT+COPS fallback rides a
	// port that is frequently dead in MBIM mode (EG06: AT times out).
	self.reattach = function(cb) {
		cb = cb ?? (() => null);

		let via_radio = () => {
			if (!self.mbim)
				return cb({ error: 'unsupported_on_backend' });

			log('notice', 'network reattach (MBIM radio off -> on)');
			self.mbim.command(bc, 'RADIO_STATE', 'set',
				{ radio_state: bc.RADIO_STATE_OFF }, () => {
					settle_timer = uloop.timer(self.timing.settle, () => {
						self.mbim.command(bc, 'RADIO_STATE', 'set',
							{ radio_state: bc.RADIO_STATE_ON }, (err) => {
								cb(err ? { error: 'mbim', detail: err } : null,
									{ ok: true, action: 'reattach', via: 'mbim_radio' });
							});
					});
				});
		};

		self._ensure_pt((up) => {
			if (!up)
				return via_radio();

			self.pt.ctl.request('ALLOCATE_CID', { service: dmsmod.default.service }, (aerr, adata) => {
				if (aerr || !adata?.allocation)
					return via_radio();

				let dms = client_mod.create(self.pt.shim, dmsmod.default, adata.allocation.cid, hooks);

				log('notice', 'network reattach (passthrough DMS low_power -> online)');
				qmi_backend.set_opmode(dms, 'low_power', () => {
					settle_timer = uloop.timer(self.timing.settle, () => {
						qmi_backend.set_opmode(dms, 'online', (err) => {
							cb(err ? { error: 'qmi', detail: err } : null,
								{ ok: true, action: 'reattach', via: 'qmi_passthrough' });
						});
					});
				});
			}, { no_recovery: true });
		});
	};

	// telemetry (signal/cells/CA/data-mode/reg-detail + slow log loop + fast
	// watch loop) — extracted to telemetry_mbim.uc; attaches the _refresh_*
	// methods, watch and _start_telemetry, returns { stop } for teardown.
	let telem = telemetry_mbim.install(self, { log: log, emit: emit });

	// --- lifecycle ---------------------------------------------------------
	// (switch_protocol / protocol_switch_supported come from scaffolding)

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
		for (let t in [ retry_timer, reg_timer, settle_timer, at_drain_timer, sim_poll_timer ])
			if (t)
				t.cancel();

		retry_timer = reg_timer = settle_timer = at_drain_timer = sim_poll_timer = null;
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
			self.mbim_slots = null;
		}

		if (self.hub) {
			self.hub.close();
			self.hub = null;
		}
	};

	// stop() + _device_gone() installed by modem_common.scaffolding

	return self;
};
