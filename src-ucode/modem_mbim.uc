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
import * as voice_svc from 'wwand.codec.mbim_schema.ms_voice_ext';
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
import * as atparse from 'wwand.atcmd_parse';
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

// tries to wake a radio an earlier init pass parked before this pass fails
// (step_register): a refusal is retried, and bounded, so a modem that keeps
// refusing reaches the recovery ladder instead of retrying forever
const WAKE_TRIES = 3;


export function create(opts)
{
	let self = {
		id: opts.id,
		device: opts.device,
		protocol: 'mbim',
		config: opts.config ?? {},
		timing: { ...TIMING_DEFAULTS, ...(opts.timing ?? {}) },

		state: 'ABSENT',
		// Which incarnation of this modem a callback belongs to. Bumped FIRST in
		// teardown, because teardown cancels its timers before destroying the
		// passthrough clients — and destroying one fires its pending callbacks
		// synchronously, so a callback that arms a timer arms it AFTER the
		// cancellation pass has run. Same role as `_gen` in modem.uc.
		_gen: 0,
		hub: null,
		mbim: null,
		pt: null,          // lazy QMI-over-MBIM passthrough stack { shim, ctl, nas, dsd, services }
		extra_clients: [], // plugins' clients over the passthrough (extra_client)
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
		// the radio switched off on purpose (set_opmode low_power: a plugin's
		// hold, `option lowpower`) — the registration it costs is no fault
		lowpower_parked: false,
		// what an earlier modem object (an earlier daemon) did to the DMS
		// operating mode is not known here; set_opmode wakes it too
		_dms_unknown: true,
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
	// the LTE attach configuration is not a numbered profile (modem_common
	// attach_owner): the scaffolding's owner check follows the same rule
	self.attach_numbered = false;
	let emit = scaffold.emit;
	let notify_contexts = scaffold.notify_contexts;
	let sim_block = scaffold.sim_block;
	let enter_ready = scaffold.enter_ready;

	let hooks = {
		// the client logs the negotiated MBIMEx version — only when one is
		// requested at all, which it is not by default (mbim_client.open())
		log: log,
		on_error: (c, kind, what, status) => {
			let act = rec.on_proto_error();
			// same escalation as QMI: a wedged control channel gets a hardware
			// reset first; reboot only if that fails to clear it (the NR7101
			// reboot-loop fix — see recovery.on_proto_error)
			if (act == 'usb_repower')
				rec.usb_repower();
			else if (act == 'reboot')
				rec.reboot('mbim error limit reached');

			// the QMI side logs "qmi error (kind) svc N NAME" (modem.uc); this is
			// its counterpart, with the MBIM_STATUS_ERROR decoded where there is
			// one — the number alone is not readable, and it is usually the whole
			// answer (status 21 InvalidParameters = the modem rejected the shape
			// of the buffer, not its contents).
			let nm = (kind == 'mbim') ? mbimmod.status_name(status) : null;

			log('debug', sprintf('mbim error (%s) %s%s, counter %d',
				kind ?? '?', what ?? '?',
				(kind == 'mbim')
					? sprintf(' status %d%s', status ?? -1,
						nm ? sprintf(' (%s)', nm) : '')
					: '',
				self.counters.proto_errors));
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

	let hold_at_open, fcc_unlock, step_open, step_fcc, step_caps, step_at, step_at_ident, step_datapath, step_simslot, step_sim, step_attach_profile, step_register, do_register, step_attach;

	// MBIM reports the operator as one concatenated MCC+MNC string
	// (MbimRegisterState ProviderId, "26006"), while QMI reports the pair
	// separately — and every consumer was written against the QMI shape, so an
	// MBIM modem showed no operator at all (ddimension/luci-app-wwand#4).
	//
	// Emit BOTH: the split pair for anything reading mcc/mnc, and `id`
	// unchanged so nothing that already reads it breaks. MCC is always three
	// digits; whatever follows is the MNC, two or three of them, and the count
	// is significant — 260/06 and 260/060 are different networks, so the raw
	// string is kept alongside the numbers that lose a leading zero.
	let plmn_of = (data) => {
		if (!data?.provider_id)
			return null;

		let id = trim(sprintf('%s', data.provider_id));
		let out = { description: data.provider_name, id: id };

		if (match(id, /^[0-9]{5,6}$/)) {
			out.mcc = +substr(id, 0, 3);
			out.mnc = +substr(id, 3);
			out.mnc_digits = length(id) - 3;
		}

		return out;
	};


	// WHAT THE MODEM SAYS ABOUT ITS TWO RADIO SWITCHES, from every message that
	// carries them. The SET response is the same HwRadioState/SwRadioState pair
	// as the query and the notification (libmbim 1.32.0,
	// mbim-service-basic-connect.json "Radio State": the set carries RadioState
	// alone, its response carries both) — and all four writers here threw it
	// away, keeping only `serr`.
	//
	// Otherwise a modem that ships with its software radio off, which
	// step_register then switches on, keeps reporting the reading from BEFORE
	// the switch: `radio: { hw: 1, sw: 0 }` and "Radio off (software)" in LuCI on
	// a modem that is registered and carrying traffic (evidence:
	// ddimension/wwand#38). The indication cannot repair it —
	// it fires on a change the modem chooses to report, and a change we
	// commanded ourselves is exactly the one that may not come.
	//
	// Storage only, plus the one note that must not outlive its cause. Setting
	// a "radio disabled" note is left to the sites that can tell a switch
	// somebody moved from a cycle we are running ourselves.
	//
	// NOT CALLED FOR THE OFF HALF of the three off->on cycles below, though
	// that answer is just as valid. LuCI renders `radio` directly and paints
	// an amber "off (software)" the moment either switch reads 0
	// (luci-app-wwand status.js:538) — so publishing a state we are, by
	// construction, about to leave within `settle` turns an accurate instant
	// into the very message #38 was about. Nothing is lost by skipping it: if
	// the ON half never runs, it is because the modem was torn down, and
	// teardown nulls `radio` outright.
	//
	// Returns whether the answer was usable, so a caller can tell "the radio
	// is on" from "that message told us nothing".
	let note_radio = (data) => {
		if (data?.hw_radio_state == null || data?.sw_radio_state == null)
			return false;

		self.radio = { hw: data.hw_radio_state, sw: data.sw_radio_state };

		if (data.hw_radio_state != bc.RADIO_STATE_OFF &&
		    data.sw_radio_state != bc.RADIO_STATE_OFF &&
		    self.control_note != null &&
		    index(self.control_note, 'radio disabled') == 0)
			self.control_note = null;

		return true;
	};

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
						// a parked radio stays off: a cycle ending online
						// un-parks it behind the park's back (modem.uc
						// online_unless_parked)
						if (self.lowpower_parked || !self.mbim)
							return done();

						self.mbim.command(bc, 'RADIO_STATE', 'set',
							{ radio_state: bc.RADIO_STATE_ON }, (e2, d2) => {
								note_radio(d2);
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
			// slot_status() parks its own SYS_CAPS answer on the client. Take
			// that before asking again — the comment above always said "getter,
			// not a copy", but this read the local field only, so a status page
			// that had just listed the slots paid for a second identical query.
			self.multisim_caps = self.multisim_caps ?? self.mbim?._multisim_caps;

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

			hold_at_open(step_fcc);
		});
	};

	// A PLUGIN HOLDS THE RADIO OFF (its card is lent, or it waits for a
	// remote SIM): off right after OPEN, before anything else. An MBIM modem
	// registers on its own whenever its software radio is on: that state
	// persists across boots, wwand sends no REGISTER_STATE set at init, and
	// the only thing step_register ever had to do for it was switch an off
	// radio on (ddimension/wwand#3, EG18). So the QMI chain's point of asking
	// (step_opmode) comes too late here: on LTE a registration is an attach,
	// and the network has seen the local IMSI. The native switch, because
	// the passthrough cannot be probed this early (extra_client). A refused
	// switch does not fail the init: it continues held, REGISTERING waits,
	// and its interfaces are refused (radio_held).
	//
	// THE VENDOR FCC UNLOCK WAITS FOR THE WAKE. It is a radio-on of its own
	// (quectel Radio State), and sent before the park it could let an
	// RF-locked modem register on its local card first; the wake sends it
	// before it switches the parked radio back on (set_opmode, `_fcc_due`).
	// Held, `next` (the FCC step) is skipped for the capabilities.
	hold_at_open = (next) => {
		let hold = self.radio_hold?.();

		if (!hold)
			return next();

		log('notice', sprintf('radio stays off at init — %s', hold));
		self._plugin_held = true;

		if (self.config.fcc_auth == 'quectel')
			self._fcc_due = true;

		self.set_opmode('low_power', (err) => {
			if (err?.error == 'cancelled')
				return;

			if (err)
				log('warn', sprintf('radio stays off at init: switching it off failed (%J) — continuing held; its interfaces are refused until the hold ends',
					err));

			step_caps();
		});
	};

	// FCC RF unlock (laptop-SKU Quectel modems in MBIM mode, e.g. EM120R-GL /
	// EM160R-GL in Lenovo machines): `option fcc_auth 'quectel'` sends the
	// vendor Radio State = on right after MBIM OPEN — the MBIM mirror of
	// ModemManager's `mbimcli --quectel-set-radio-state=on` unlock helper.
	// Best-effort: an error is logged and bring-up continues (an unlocked
	// modem simply ignores/rejects the vendor CID). cb() either way.
	fcc_unlock = (cb) => {
		self.mbim.command(quectel_svc, 'RADIO_STATE', 'set',
			{ radio_state: quectel_svc.RADIO_ON }, (err, data) => {
			if (err)
				log('warn', sprintf('FCC unlock (quectel radio state) failed: %J', err));
			else
				log('notice', sprintf('FCC unlock: quectel radio state now %d', data?.radio_state));

			cb();
		});
	};

	step_fcc = () => {
		if (self.config.fcc_auth != 'quectel')
			return step_caps();

		fcc_unlock(step_caps);
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

			// MBIMEx v3 only, and ASKED ONLY WHEN IT WAS AGREED. These two CIDs
			// exist solely in the v3 extensions service; putting them to a modem
			// that negotiated v1 earns a refusal, and every refusal on a native
			// command votes on the channel through the recovery ladder. The
			// version gate is what keeps a diagnostic from looking like a fault.
			self._read_v3_extras();

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
	// It is not the only way in: modem_common.open_at() falls back to the same pipe on its own whenever
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
			next: () => {
				// a mute port is asked again later (ddimension/wwand#47)
				modem_common.at_late_retry(self, {
					at_opts: at_opts, log: log, drain_interval: self.timing.at_drain,
					set_drain_timer: (t) => { at_drain_timer = t; },
					next: () => null,
				});
				step_at_ident();
			},
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
	// netifd's device binding matches). It goes through netlink.setup() rather
	// than a private copy, because a copy drifts: a fix to the stale-child prune
	// in one would leave the other with the very defect it was fixed for.
	// Skipped gracefully when no datapath info is wired (host tests).
	step_datapath = () => {
		let dp = opts.datapath;

		if (!dp?.netdev || !dp.fx) {
			self.datapath = { backend: 'untagged', netdev: dp?.netdev ?? null, mux: [] };
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

			// a cdc_mbim parent with no channels is session 0 carried
			// untagged, not a raw-IP trunk — see the `untagged` mode in
			// netlink.uc
			backend = 'untagged';
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
			// what setup() ACTUALLY ran: it drops to `untagged` when the
			// selected backend has no channels to build (session 0 only)
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

		// name what setup() ACTUALLY ran, not what was selected: the two differ
		// whenever the fallback above fires, and a log line reading "datapath:
		// vlan" beside a status reading "datapath": "raw_ip" costs a reader the
		// same minutes twice (asked in ddimension/wwand#5). The configured name
		// stays visible when it was overridden, so the fallback is still legible.
		let eff = self.datapath.backend;

		log('notice', sprintf('datapath: %s%s, parent %s, mux [%s]',
			eff, (eff != backend) ? sprintf(' (%s not applicable here)', backend) : '',
			parent, join(' ', r.mux_devs)));
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
			// AND AN INFERRED ROW IS NOT A SLOT MAP. sim.slot_status answers
			// with one addressable card when the modem cannot enumerate, which
			// is right for the status page and wrong here: acting on it would
			// send a slot switch to a modem whose slot support we have just
			// established does not answer. Same outcome as the error branch
			// above.
			if (err || !sim.enumerated(slots)) {
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
		// THE POLL MUST NOT OUTLIVE THE SESSION. Teardown cancels
		// sim_poll_timer and then destroys the MBIM client, which completes the
		// in-flight query with `cancelled` — and a callback that walked on
		// regardless would re-arm the timer AFTER that cancel pass. When that
		// timer fires, self.mbim is null and `self.mbim.command` throws:
		// a throw inside a uloop callback ends the program (measured
		// 2026-09-19), so the daemon dies and procd respawns it. Reachable on
		// any unplug or config reload inside the up-to-10 s cold-boot wait —
		// the GL-X3000/RM520N case.
		let gen = self._gen;

		self.set_state('SIM_UNLOCK');

		// ready_state 1 = initialized (unlocked). Other states need a PIN or
		// signal a SIM problem.
		if (self._ready_state == bc.READY_STATE_INITIALIZED) {
			// ...and say so in `pin1`, which is the field every consumer reads
			// to answer "is this card usable". An earlier attempt at QMI parity
			// filled it in the PIN-query branch below — but that branch only
			// runs for a LOCKED card, so on the ordinary unlocked one it stayed
			// null and the status page had nothing to print (HW-seen on a
			// GL-X3000 / RM520N-GL, 2026-09-12: the SIM column read "-" beside
			// a modem that was registered and carrying traffic).
			//
			// `retries` and `enabled` stay NULL rather than being invented.
			// MBIM reports the PIN it CURRENTLY requires; on an unlocked card
			// there is none, so whether a PIN query is configured at all is not
			// something this protocol can answer, and "not required" would be a
			// claim about the card rather than about what we were told. Only
			// the state is known, and the state is what is recorded.
			self.pin1 = { state: 2, retries: null, enabled: null };

			return step_attach_profile();
		}

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
				sim_poll_timer = null;

				if (self._gen != gen || !self.mbim)
					return;

				self.mbim.command(bc, 'SUBSCRIBER_READY_STATUS', 'query', {}, (e2, d2) => {
					// a cancellation is the session ending, not a slow card
					if (e2?.error == 'cancelled' || self._gen != gen)
						return;

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
					// ...but a CANCELLATION is the session ending, not the
					// firmware refusing. destroy() pays its pending callbacks
					// synchronously and only then clears them
					// (mbim_client.uc:265,275), so re-querying here enqueued a
					// command into the client being torn down. Same shape as
					// the ready-state poll above.
					if (verr.error == 'cancelled' || self._gen != gen || !self.mbim)
						return;

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

	// Network time (NITZ) over the MS Voice Extensions service — the native
	// path, so an MBIM modem without a usable AT port gets it too.
	self._on_nitz = function(d) {
		// all-zero until the network has sent one; nitz_epoch refuses it
		let epoch = modem_common.nitz_epoch(d);

		if (epoch == null)
			return;

		let tz_min = voice_svc.tz_minutes(d.tz_offset_min);

		self.network_time = { epoch: epoch, tz_offset_min: tz_min,
			dst: voice_svc.tz_minutes(d.dst_offset_min) };
		log('info', sprintf('network time (NITZ): %d utc, tz %s',
			epoch, tz_min != null ? sprintf('%+d min', tz_min) : '?'));
		modem_common.nitz_apply(self, deps, epoch, tz_min);
	};

	// QUERY FIRST, SUBSCRIBE ONLY ON AN ANSWER. The subscribe list is one SET
	// carrying every service; putting a service in it that the firmware does
	// not implement risks the whole list being refused, and with it the
	// subscriptions that are not optional (REGISTER_STATE, CONNECT, ...). A
	// successful query is the proof that the service exists. no_recovery: a
	// firmware without it answers a refusal, which says nothing about the
	// channel.
	self._query_nitz = function() {
		let mc = self.mbim;

		mc.command(voice_svc, 'NITZ', 'query', {}, (err, d) => {
			if (err || self.mbim != mc)
				return;

			// once per client: on() appends, and a re-registration would
			// otherwise stack a second handler for the same indication
			if (!mc._nitz_on) {
				mc._nitz_on = true;
				mc.on(voice_svc, 'NITZ', self._on_nitz);
				mc.subscribe_events();
			}

			self._on_nitz(d);
		}, { no_recovery: true });
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
		// PACKET_SERVICE was discarded outright. Under MBIMEx it carries three
		// fields the rest of the stack has to infer otherwise — see
		// _update_packet_service.
		self.mbim.on(bc, 'PACKET_SERVICE', (data) => self._update_packet_service(data));
		// SIM ready-state changes (hot-swap, removal, post-PIN initialisation) —
		// the MBIM counterpart of the QMI UIM CARD_STATUS_IND. Keep identity fresh
		// and surface SIM removal instead of running stale. (Closes the one native
		// MBIM indication gap vs the QMI backend.)
		// A card re-initialising under a running modem (an eSIM profile enable
		// by somebody else's LPA): the native ready-state leaves INITIALIZED.
		// If it is not back within refresh_end, the card gets the eSIM
		// switch's apply (sim.refresh_fallback). It is a BASIC CONNECT
		// notification of the MBIM 1.0 command set (mbim-service-basic-
		// connect.json:50-54, libmbim 1.32.0), so it needs neither the QMI
		// passthrough nor the MS extensions.
		// SLOT_INFO_STATUS below would announce it earlier, but names a slot
		// index this backend cannot map to the card in use, and arming on
		// another slot's card would power-cycle the one carrying the WAN.
		let gen = self._gen;
		let mc = self.mbim;

		self._refresh_fb?.disarm();
		self._refresh_fb = sim.refresh_fallback(self, {
			log: log, reapply: () => self.reapply_sim(),
			alive: () => self._gen == gen && self.mbim == mc,
			end_ms: self.timing.refresh_end, apply_ms: self.timing.refresh_apply,
		});

		self.mbim.on(bc, 'SUBSCRIBER_READY_STATUS', (data) => {
			let prev = self._ready_state;
			self._ready_state = data.ready_state;

			if (prev == bc.READY_STATE_INITIALIZED &&
			    (data.ready_state == bc.READY_STATE_NOT_INITIALIZED ||
			     data.ready_state == bc.READY_STATE_DEVICE_LOCKED))
				self._refresh_fb.arm('card re-initialising (ready-state left initialized)');
			else if (data.ready_state == bc.READY_STATE_INITIALIZED)
				self._refresh_fb.end();

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

		// THE HARDWARE KILL SWITCH, which nothing else in this daemon can see.
		// A physical RF switch or a host airplane-mode toggle turns the radio
		// off under a running modem: registration drops, every reconnect fails,
		// and the recovery ladder climbs through opmode cycles and resets
		// trying to fix a modem that is doing exactly what it was told. The two
		// states are separate for a reason — a SOFTWARE off is ours to undo
		// (init already switches it back on), a HARDWARE off is a switch
		// somebody moved and wwand must not fight it.
		self.mbim.on(bc, 'RADIO_STATE', (data) => {
			let had_note = self.control_note;

			// an indication missing either state says nothing about either
			// switch — it must not clear a note or announce a switch-on
			if (!note_radio(data))
				return;

			let hw_off = (data.hw_radio_state == bc.RADIO_STATE_OFF);
			let sw_off = (data.sw_radio_state == bc.RADIO_STATE_OFF);

			if (hw_off) {
				self.control_note = 'radio disabled by the hardware switch';
				log('warn', 'radio switched off in hardware — the modem will not register until the switch is moved back');
			}
			else if (sw_off) {
				self.control_note = 'radio disabled in software';
				log('notice', 'radio switched off in software');
			}
			else if (had_note != null && index(had_note, 'radio disabled') == 0) {
				// note_radio already cleared it; this is the line that says so
				log('notice', 'radio switched back on');
			}
		});

		// LTE ATTACH INFO, unasked. The RM520N-GL sends this one on its own
		// roughly once a minute (measured on the GL-X3000, 2026-09-20) —
		// before this handler existed it was the one indication arriving with
		// nobody listening, and wwand queried the same CID on demand instead.
		//
		// It also has to be here for a second reason: CID 19 REPLACES the
		// modem's default event set with exactly what was asked for, so an
		// indication the modem used to volunteer stops arriving the moment a
		// subscription that omits it goes out. Measured, not assumed — it
		// stopped, and this is what brings it back.
		//
		// Only the state is taken here. The cause top-up (AT+CEER) belongs to
		// the failure path, which is where somebody is waiting for an answer;
		// running an AT round trip on every unsolicited update would be a
		// minute-ly cost for a line nobody reads.
		self.mbim.on(ext, 'LTE_ATTACH_INFO', (data) => {
			let state = data.lte_attach_state;
			let was = self.attach_info?.state;

			self.attach_info = {
				state: state,
				state_text: ext.LTE_ATTACH_STATE[sprintf('%d', state ?? -1)],
				ip_type: data.ip_type,
				apn: length(data.access_string ?? '') ? data.access_string : null,
			};

			if (data.nw_error != null && data.nw_error != 0) {
				self.attach_info.nw_error = data.nw_error;
				self.attach_info.nw_error_text =
					nasmod.REJECT_CAUSE[sprintf('%d', data.nw_error)] ??
					sprintf('cause %d', data.nw_error);
			}

			// only when it MOVED: this arrives on a timer whether anything
			// changed or not, and a log line per minute saying "still attached"
			// is noise that hides the one that matters.
			if (state != was)
				log('notice', sprintf('lte attach: %s (apn %s)%s',
					self.attach_info.state_text ?? sprintf('state %d', state ?? -1),
					self.attach_info.apn ?? '-',
					self.attach_info.nw_error_text
						? sprintf(' — %s', self.attach_info.nw_error_text) : ''));
		});

		// CARRIER CONFIGURATION, unasked. The query is issued at init and this
		// hardware answers it with status 14 (NotInitialized) — too early — and
		// then sends the same CID as an indication a moment later (GL-X3000 /
		// RM520N, 2026-09-20). So the indication is not a nicety here, it is
		// the only way the value arrives at all on that modem; on one that
		// answers the query it is how a configuration SWITCH announces itself
		// instead of being polled for.
		self.mbim.on(ext, 'MODEM_CONFIGURATION', (data) => {
			self.modem_config = {
				status: data.configuration_status,
				status_text: ext.MODEM_CONFIG_STATUS[sprintf('%d', data.configuration_status ?? -1)],
				name: length(data.configuration_name ?? '') ? data.configuration_name : null,
			};

			log('info', sprintf('carrier configuration: %s (%s)',
				self.modem_config.name ?? '-', self.modem_config.status_text ?? '?'));
		});

		// SIM SLOT STATE, per slot. Today this is polled at init and after a
		// slot switch; a card pulled or pushed while the modem runs is
		// otherwise noticed only by the failures that follow it. `ext` is
		// duck-typed the way the rest of the extensions are — a modem without
		// the extensions service simply never sends it.
		self.mbim.on(ext, 'SLOT_INFO_STATUS', (data) => {
			self.slot_state = self.slot_state ?? {};
			self.slot_state[sprintf('%d', data.slot_index ?? 0)] = data.state;

			log('notice', sprintf('sim slot %d: state %d (%s)',
				data.slot_index ?? 0, data.state,
				ext.UICC_SLOT_STATE_NAMES?.[sprintf('%d', data.state)] ?? 'unknown'));
		});
	};

	// NATIVE OPERATOR SCAN. MBIM has had one all along (VISIBLE_PROVIDERS,
	// cid 8) and wwand never called it, so an MBIM modem whose QMI passthrough
	// refuses a NAS scan and has no AT port answered `unsupported_on_backend`
	// for an operation its own protocol implements. netsel_ops reaches this by
	// duck-typing (the schemas ship in wwand-mbim; that file is in the base
	// package), and puts it BELOW the other two on purpose: the QMI scan
	// carries band and RAT per operator, and AT+COPS=? is the one every modem
	// answers.
	self.native_scan = function(cb, timeout) {
		if (!self.mbim)
			return cb({ error: 'no_channel' }, null);

		// FULL scan, not the cached list: a caller asking to scan wants the
		// radio to go and look (MbimVisibleProvidersAction, libmbim 1.32.0 —
		// 0 = full scan, 1 = restricted).
		self.mbim.command(bc, 'VISIBLE_PROVIDERS', 'query', { action: 0 },
			(err, data) => cb(err, err ? null : (data?.operators ?? [])),
			{ timeout: timeout });
	};

	// NATIVE NETWORK SELECTION. MBIM's REGISTER_STATE set takes a provider id
	// and an action; `plmn` null means automatic. Reached by duck-typing from
	// netsel_ops, below the QMI and AT rungs — those carry the RAT preference
	// and the 3-digit-MNC flag, which this does not.
	//
	// The width IS the statement: a 3-digit MNC written two digits wide names a
	// different operator, and a provider id carries no flag to say which was
	// meant — the digit count is all there is. Same rule AT+COPS follows.
	self.native_register = function(plmn, cb) {
		if (!self.mbim)
			return cb({ error: 'no_channel' });

		// zero-padded by hand: ucode's sprintf has no `%0*d`, and a `%02d` that
		// silently truncated a 3-digit MNC would name a different operator
		let id = '';

		if (plmn) {
			let mnc = sprintf('%d', +plmn.mnc);
			let want = (plmn.width == 3) ? 3 : 2;

			while (length(mnc) < want)
				mnc = '0' + mnc;

			id = sprintf('%d%s', +plmn.mcc, mnc);
		}

		self.mbim.command(bc, 'REGISTER_STATE', 'set', {
			provider_id: id,
			register_action: plmn ? bc.REGISTER_ACTION_MANUAL : bc.REGISTER_ACTION_AUTOMATIC,
			data_class: 0,
		}, (err) => cb(err), { timeout: 60000 });
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

	// The MBIMEx additions on PACKET_SERVICE (v2 appends FrequencyRange, v3 adds
	// DataSubclass and Tai — all APPENDED, so a v1 modem simply answers null).
	//
	// `data_subclass` is the one that earns its keep: MbimDataSubclass is a
	// bitmask naming 5G_ENDC / 5G_NR / 5G_NEDC / 5G_ELTE / 5G_NGENDC, which
	// separates non-standalone from standalone outright. The backend otherwise
	// derives that from the serving-cell shape (modem_common.dsd_from_serving),
	// which is inference from what the cell looks like rather than the modem
	// saying so.
	//
	// STORED, NOT ACTED ON. It is published through status/telemetry; nothing
	// decides anything on it yet, and it must not silently start to.
	self._update_packet_service = function(data) {
		if (data == null)
			return;

		let ps = {};

		if (data.frequency_range != null && data.frequency_range != 0)
			ps.frequency_range = data.frequency_range;

		if (data.data_subclass != null && data.data_subclass != 0)
			ps.data_subclass = data.data_subclass;

		// MbimTai: PlmnMcc/PlmnMnc as u16 each, then Tac. mcc 0 is not a PLMN,
		// so it doubles as "the modem did not fill this in".
		if (data.tai_mcc != null && data.tai_mcc != 0)
			ps.tai = { mcc: data.tai_mcc, mnc: data.tai_mnc, tac: data.tai_tac };

		self.packet_service = length(ps) ? ps : null;
	};

	self._update_register = function(data) {
		let st = data.register_state;
		let registered = (st == bc.REGISTER_STATE_HOME || st == bc.REGISTER_STATE_ROAMING ||
		                  st == bc.REGISTER_STATE_PARTNER);

		self.reg = {
			registration: registered ? 1 : 0,
			roaming: (st == bc.REGISTER_STATE_ROAMING),
			plmn: plmn_of(data),
			data_class: data.available_data_classes,
			// MBIMEx v2 appends what the network PREFERS, as against
			// available_data_classes, which is what it offers. Absent on v1.
			preferred_data_class: data.preferred_data_classes,
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

		if (registered)
			self._reg_released = false;

		if (registered && self.state == 'REGISTERING') {
			if (reg_timer) { reg_timer.cancel(); reg_timer = null; }
			// woken from a park at init: this READY entry emits `registered`
			// itself, the READY wake below must not add a second
			self._wake_pending = false;
			// ATTACHING guards against REGISTER_STATE indications piling up
			// while the attach is in flight — without it each one would re-run
			// step_attach and re-emit 'registered' (kick spam in the daemon)
			self.set_state('ATTACHING');
			step_attach();
		}
		else if (registered && self.state == 'READY' && self._wake_pending) {
			// Woken from a park while READY: registered again with no
			// REGISTERING step, so no `registered` event, and the daemon never
			// re-arms the interfaces it gave up while the radio was off
			// (modem.uc set_opmode has the QMI twin). Through the attach, as
			// a registration regained after a loss goes, which ends in READY
			// and `registered`.
			self._wake_pending = false;
			log('notice', 'registered again after the radio was parked');
			self.set_state('ATTACHING');
			step_attach();
		}
		else if (!registered && (self.state == 'READY' || self.state == 'ATTACHING')) {
			// PARKED: we switched the radio off ourselves, so losing
			// registration is the consequence, not a fault — step_register
			// would fight the park (it switches the software radio on) and
			// its timeout walk the recovery ladder. Same as modem.uc.
			if (self.lowpower_parked || self.detached) {
				// ONCE per loss: a modem that is detached but keeps camping
				// reports its serving system every few seconds, and each
				// report re-logged this and re-suspended the contexts
				// (HW-observed over QMI on the RG650E, 2026-10-10)
				if (self._reg_released)
					return;

				self._reg_released = true;
				log('info', self.detached ? 'registration released (detached by the operator)'
				                          : 'registration released (radio parked)');
				emit('deregistered', self.reg);
				notify_contexts('suspend', self.reg);
				return;
			}

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
	self._apply_attach = function(next) {
		// the LTE attach configuration is not a numbered profile: session 1
		// owns nothing here
		let ctx = modem_common.attach_owner(self.contexts, self.attach_numbered);

		// no interface bound yet: the first one to bind programs it
		// (modem_common attach_context, via reapply_sim)
		if (!ctx && self.mbim) {
			log('notice', 'attach profile: no interface bound yet — programmed when the first one binds');
			self._attach_pending = true;
			return next();
		}

		if (!ctx || !self.mbim)
			return next();

		let apn = context_common.conn_cfg(ctx, 'apn');

		// '#N' means "use the modem-provisioned context as-is" — never rewrite
		// it. Every other config, an UNSET APN included, is written: unset is
		// the empty APN (the network's default), never "whatever the context
		// happened to hold" — see context.uc ensure_attach_profile for the
		// MC7710 whose stale attach APN out of another box flapped a Telekom
		// card (deborah-3, 2026-10-04). NCM writes it at every dial too.
		if (apn != null && substr(apn, 0, 1) == '#')
			return next();

		apn = apn ?? '';

		let want_ip = bc.IP_TYPE_FROM_PDP[context_common.effective_pdp(ctx)] ?? bc.IP_TYPE_IPV4V6;
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
				return next();
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
					return next();
				}

				self.effective_apn = apn;

				// parked or held: the attach runs with the new profile when
				// the radio is woken — a cycle ending online here would
				// register behind the park's back
				if (self.lowpower_parked || self._plugin_held)
					return next();

				// force the (possibly already-completed) autonomous attach to
				// re-run with the new profile: radio off -> settle -> on -> settle
				log('notice', 'attach profile changed, cycling radio to re-attach');
				self.mbim.command(bc, 'RADIO_STATE', 'set',
					{ radio_state: bc.RADIO_STATE_OFF }, () => {
					settle_timer = uloop.timer(self.timing.settle, () => {
						self.mbim.command(bc, 'RADIO_STATE', 'set',
							{ radio_state: bc.RADIO_STATE_ON }, (e2, d2) => {
							note_radio(d2);
							settle_timer = uloop.timer(self.timing.settle, next);
						});
					});
				});
			});
		});
	};

	step_attach_profile = () => self._apply_attach(step_register);

	step_register = () => {
		// HELD: the radio stays off (hold_at_open has the reason), and this is
		// the second place to ask — a hold that began after OPEN, or a
		// registration lost while held but not parked. REGISTERING waits.
		let hold = self.radio_hold?.();

		if (hold) {
			self._plugin_held = true;

			if (self.lowpower_parked)
				return do_register();

			log('notice', sprintf('radio stays off — %s', hold));

			return self.set_opmode('low_power', (err) => {
				if (err?.error == 'cancelled')
					return;

				if (err)
					log('warn', sprintf('switching the radio off failed (%J) — continuing held', err));

				do_register();
			});
		}

		// Not held, and a park from an earlier pass still recorded: this
		// object outlives a failed init (make_fail restarts the same
		// instance), so it is woken the way it was parked — a DMS low power
		// is not undone by the Radio State query below — and the flags go
		// with it. Left, REGISTERING waited forever and the next
		// registration loss read as "radio parked".
		//
		// A FAILED WAKE KEEPS THE PARK: the radio is still off, and flags
		// saying otherwise sent the init into a registration that cannot
		// come, with the knowledge of how it was parked gone. Tried again
		// after a settle, and after WAKE_TRIES the init fails — the ladder,
		// whose retry lands here again with the flags intact.
		if (self.lowpower_parked)
			return self.set_opmode('online', (err) => {
				if (err?.error == 'cancelled')
					return;

				if (err) {
					self._wake_tries = (self._wake_tries ?? 0) + 1;

					if (self._wake_tries >= WAKE_TRIES) {
						self._wake_tries = 0;
						return fail('radio_wake', err);
					}

					log('warn', sprintf('waking the parked radio failed (%J) — trying again', err));
					settle_timer = uloop.timer(self.timing.settle, step_register);
					return;
				}

				self._wake_tries = 0;
				self._plugin_held = false;
				step_register();
			});

		self._plugin_held = false;

		// A DMS LOW POWER LEFT BY AN EARLIER DAEMON. A park over the
		// passthrough's DMS outlives the modem object that made it (a daemon
		// restart), and the Radio State query below cannot see it — the two
		// are independent switches — so the modem sat in REGISTERING until
		// the recovery ladder's reset. Asked once per modem object, and only
		// here, not held. Low power is switched online; OFFLINE is left to
		// that reset — libqmi calls it RF off and "partially shutdown"
		// (qmi-enums-dms.h, 1.38.0), and it is left only by a reset. No
		// passthrough: nothing to ask, the Radio State path as before.
		if (self._dms_unknown && !self._dms_checked) {
			self._dms_checked = true;

			return self._pt_get_opmode((err, mode) => {
				if (err?.error == 'cancelled')
					return;

				if (err || mode != dmsmod.OPMODE_LOW_POWER) {
					if (!err)
						self._dms_unknown = false;

					if (!err && mode == dmsmod.OPMODE_OFFLINE)
						log('warn', 'the modem reports DMS offline — only a reset leaves that');

					return step_register();
				}

				log('notice', 'the modem was left in low power by an earlier park, switching it online');

				self._pt_opmode('online', (e2) => {
					if (e2?.error == 'cancelled')
						return;

					if (e2)
						log('warn', sprintf('switching it online failed: %J', e2));
					else
						self._dms_unknown = false;

					step_register();
				});
			});
		}

		// The SOFTWARE radio can be off, and stay off across reboots: some modems
		// ship that way. Nothing else in this backend ever turns it on — the two
		// existing RADIO_STATE writers both cycle off->on inside a flow that only
		// runs on an attach-profile change or a low-power wake — so registration
		// simply never started. Field-reported on an EG18 in MBIM mode
		// (ddimension/wwand#3): `umbim radio` showed hwradiostate on,
		// swradiostate off, and stopping wwand to run `umbim radio on` by hand
		// was the workaround.
		//
		// Read before write, like every other setting the daemon applies: a modem
		// whose radio is already on sees no command at all. The hardware switch
		// is reported too but deliberately not acted on — no software write can
		// clear a physical kill switch, and saying so beats a silent retry.
		self.mbim.command(bc, 'RADIO_STATE', 'query', {}, (err, data) => {
			// keep what it answered, not only what it makes us do here. The
			// indication only fires on a CHANGE, so without this `status` shows
			// nothing about the radio until somebody flips a switch — and
			// "no answer yet" and "both switches on" would look the same.
			note_radio(data);

			if (err || data?.sw_radio_state != bc.RADIO_STATE_OFF) {
				if (!err && data?.hw_radio_state == bc.RADIO_STATE_OFF) {
					log('warn', 'hardware radio switch is off — registration will not start');
					self.control_note = 'radio disabled by the hardware switch';
				}

				return do_register();
			}

			log('notice', 'software radio is off, switching it on');

			self.mbim.command(bc, 'RADIO_STATE', 'set',
				{ radio_state: bc.RADIO_STATE_ON }, (serr, sdata) => {
				if (serr)
					log('warn', sprintf('could not switch the radio on: %J', serr));

				// the answer to OUR OWN switch is the authoritative reading
				note_radio(sdata);
				settle_timer = uloop.timer(self.timing.settle, do_register);
			});
		});
	};

	do_register = () => {
		// before registering: debug-dump the NAS preferred list + SIM/network,
		// then restore the configured list (per-SIM wins over per-modem) — via the
		// QMI-over-MBIM passthrough NAS / AT+CPOL. Best-effort, never blocks.
		sim.log_preradio(self, log, () => sim.restore_preferred_plmn(self, log, () => {
			self.set_state('REGISTERING');
			self._install_indications();

			// ...and TELL THE MODEM, which is the half that was missing. The
			// handlers above are only half a subscription: without CID 19 the
			// modem sends its own default set, and on the RM520N-GL that set
			// turned out to be CONNECT and LTE_ATTACH_INFO and nothing else
			// (measured over four minutes of a live connection, GL-X3000,
			// 2026-09-20). Best-effort and never blocking: the list is derived
			// from the handlers just installed, and a modem that refuses it is
			// no worse off than before.
			self.mbim.subscribe_events();
			self._query_nitz();

			let reg_timeout;

			reg_timeout = () => {
				if (self.state != 'REGISTERING')
					return;

				// parked or held on purpose: not registered because the radio
				// is off, not a fault — failing would walk the recovery ladder
				// (radio cycles, resets that end online) over a modem doing
				// as told. The timer re-arms, so a woken modem still times out.
				if (self.lowpower_parked || self._plugin_held) {
					reg_timer = uloop.timer(self.timing.reg_timeout, reg_timeout);
					return;
				}

				// ASK WHY BEFORE GIVING UP. A registration that never completes
				// is the case LTE Attach Info exists for: under MBIMEx v3 it
				// carries the 3GPP cause for a refused EPS attach, and a wrong
				// attach APN is the commonest way to sit here forever —
				// measured on a GL-X3000, where a bogus APN left the modem in
				// REGISTERING with nothing in the log to say so (2026-09-20).
				//
				// The failure is reported either way; this only fills in the
				// reason first. BOUNDED EXPLICITLY, because the defaults are no
				// bound worth having on a failure path: mbim_client falls back
				// to 15 s and atcmd to 5, and the teardown plus the recovery
				// ladder wait behind this. The reason is worth a few seconds,
				// not twenty.
				let tgen = self._gen;

				self._read_attach_info((e, info) => {
					// ...AND RE-CHECKED AFTERWARDS. Asking costs up to seven
					// seconds, and the modem can register inside them — the
					// state test above is a statement about when the timer
					// fired, not about now. Failing on it anyway would tear
					// down a modem that had just succeeded, which is a far
					// worse bug than the missing diagnostic this adds. The
					// generation guard covers the other end: a teardown during
					// the query answers `gone`, and that must not be reported
					// as a registration timeout either.
					if (self._gen != tgen || self.state != 'REGISTERING')
						return;

					fail('registration_timeout', {
						reg: self.reg,
						detail: self.reg_detail,
						attach: info,
					});
				});
			};

			reg_timer = uloop.timer(self.timing.reg_timeout, reg_timeout);

			self.mbim.command(bc, 'REGISTER_STATE', 'query', {}, (err, data) => {
				if (!err)
					self._update_register(data);
			});
		}));
	};

	step_attach = () => {
		// ASK AGAIN, once, for what the modem said it was not ready for. The
		// init query runs before the radio is up and this hardware answers it
		// with status 14 (NotInitialized) — the modem saying "not yet" rather
		// than "never" (GL-X3000 / RM520N, 2026-09-20). By the time
		// registration has completed it has had every chance. One retry, not a
		// loop: if it still will not answer, it does not have it.
		// ONCE per modem incarnation, and only for this one. Without the flag
		// every registration-loss/re-registration cycle asks again; without the
		// generation check a teardown mid-flight lets the answer land on the
		// next session, and an indication that arrived while it was out would
		// be overwritten by the older reading.
		if (self.modem_config == null && !self._modem_config_asked) {
			let cfg_gen = self._gen;

			self._modem_config_asked = true;

			self.mbim.command(ext, 'MODEM_CONFIGURATION', 'query', {}, (err, data) => {
				if (err || data == null || self._gen != cfg_gen || self.modem_config != null)
					return;

				self.modem_config = {
					status: data.configuration_status,
					status_text: ext.MODEM_CONFIG_STATUS[sprintf('%d', data.configuration_status ?? -1)],
					name: length(data.configuration_name ?? '') ? data.configuration_name : null,
				};

				log('info', sprintf('carrier configuration: %s (%s)',
					self.modem_config.name ?? '-', self.modem_config.status_text ?? '?'));
			}, { no_recovery: true });
		}

		// attach to the packet service before contexts can connect
		self.mbim.command(bc, 'PACKET_SERVICE', 'set',
			{ packet_service_action: bc.PACKET_SERVICE_ATTACH }, (err, data) => {
			if (self.state != 'ATTACHING')
				return;   // registration flapped while attaching

			// the MBIMEx fields ride on this answer too (frequency range, data
			// subclass, TAI) — same shape as the indication
			self._update_packet_service(data);

			// already-attached returns an error on some modems; tolerate it
			self.counters.attempts = 0;
			log('notice', sprintf('registered: plmn %J, roaming %J',
				self.reg.plmn?.description, self.reg.roaming));

			// ...and ask the modem WHY if the attach did not take. MBIMEx v3
			// carries the 3GPP cause in LTE Attach Info (NwError, inserted
			// after LteAttachState — see the schema note); on v1 the field is
			// not there and this is a no-op. Best-effort and non-blocking: the
			// bring-up continues either way, this only writes the reason down.
			if (err || data?.nw_error)
				self._read_attach_info();

			enter_ready(() => self._start_telemetry());
		});
	};

	// BOTH BOUNDED, and deliberately short. This runs on the registration
	// timeout, which is a failure path: the failure report, the teardown and
	// the recovery ladder all wait behind it. The reason a modem gives is worth
	// a couple of seconds and not the 15 s mbim_client defaults to, nor that
	// plus the 5 s atcmd defaults to on top.
	const ATTACH_INFO_MS = 4000;
	const ATTACH_CEER_MS = 3000;

	// Two MBIMEx v3 diagnostics, read once at init and published through status.
	//
	// MODEM CONFIGURATION (CID 16) is the carrier configuration (MBN) the modem
	// is running. wwand otherwise reads that over QMI PDC (hwops.uc), which a
	// MBIM-only firmware does not offer at all — so on those boxes this is the
	// only way to know what profile is loaded.
	//
	// WAKE REASON (CID 19) says why the modem last woke the host: a CID
	// response, a CID indication, or a data packet. That is the half the
	// lowpower work cannot see today.
	//
	// BOTH ARE BEST-EFFORT AND NEITHER GATES ANYTHING. A modem may implement
	// v3 layouts and still not these CIDs; `no_recovery` keeps such a refusal
	// from counting against the control channel, the same way the QMI-over-MBIM
	// tunnel's refusals are excluded (ddimension/wwand#30).
	self._read_v3_extras = function() {
		if (!mbimmod.mbimex_v3(self.mbim))
			return;

		let gen = self._gen;

		self.mbim.command(ext, 'MODEM_CONFIGURATION', 'query', {}, (err, data) => {
			if (self._gen != gen)
				return;

			// SAY SO WHEN IT IS REFUSED. `no_recovery` keeps the refusal from
			// voting on the channel, and it also keeps it out of the error log
			// that on_error writes — so without this line an unimplemented CID
			// is indistinguishable from one that was never asked, which for a
			// diagnostic is the one thing it must not be.
			// STATUS 14 IS `NotInitialized`, which is the modem saying "not
			// yet" rather than "never" — this one answers it that way at init
			// and then volunteers the value as an indication (GL-X3000 /
			// RM520N, 2026-09-20). The indication handler catches that; there
			// is deliberately no retry loop here, because one observation is
			// not a schedule.
			if (err || data == null)
				return log('debug', sprintf('carrier configuration unavailable: %J', err));

			self.modem_config = {
				status: data.configuration_status,
				status_text: ext.MODEM_CONFIG_STATUS[sprintf('%d', data.configuration_status ?? -1)],
				name: length(data.configuration_name ?? '') ? data.configuration_name : null,
			};

			log('info', sprintf('carrier configuration: %s (%s)',
				self.modem_config.name ?? '-',
				self.modem_config.status_text ?? '?'));
		}, { no_recovery: true });

		self.mbim.command(ext, 'WAKE_REASON', 'query', {}, (err, data) => {
			if (self._gen != gen)
				return;

			if (err || data == null)
				return log('debug', sprintf('wake reason unavailable: %J', err));

			log('debug', sprintf('wake reason: %s (session %d)',
				ext.WAKE_TYPE[sprintf('%d', data.wake_type ?? -1)] ?? '?',
				data.session_id ?? -1));

			self.wake_reason = {
				type: data.wake_type,
				type_text: ext.WAKE_TYPE[sprintf('%d', data.wake_type ?? -1)],
				session_id: data.session_id,
			};
		}, { no_recovery: true });
	};

	// LTE Attach Info (CID 4): the profile the modem attached with, and under
	// MBIMEx v3 the cause when it did not. Recorded on reg_detail so it reaches
	// status and the failure path the same way a registration reject does.
	self._read_attach_info = function(cb) {
		let gen = self._gen;

		// ALWAYS ANSWERS. The registration-timeout path waits on this callback
		// before reporting its failure, so a silent return here would swallow
		// the failure rather than delay it.
		self.mbim.command(ext, 'LTE_ATTACH_INFO', 'query', {}, (err, data) => {
			if (err || self._gen != gen || data == null)
				return cb ? cb(err ?? { error: 'gone' }, null) : null;

			self.attach_info = {
				state: data.lte_attach_state,
				state_text: ext.LTE_ATTACH_STATE[sprintf('%d', data.lte_attach_state ?? -1)],
				ip_type: data.ip_type,
				apn: length(data.access_string ?? '') ? data.access_string : null,
			};

			if (data.nw_error != null && data.nw_error != 0) {
				self.attach_info.nw_error = data.nw_error;
				self.attach_info.nw_error_text =
					nasmod.REJECT_CAUSE[sprintf('%d', data.nw_error)] ??
					sprintf('cause %d', data.nw_error);

				log('warn', sprintf('attach: %s (apn %s)',
					self.attach_info.nw_error_text,
					self.attach_info.apn ?? '-'));

				return cb ? cb(null, self.attach_info) : null;
			}

			// TOP UP FROM AT+CEER when MBIM gave no cause, and that is the
			// common case rather than the exception: an RM520N-GL answers this
			// query with state `detached` and NwError absent, which tells the
			// reader nothing they did not already see (measured with a
			// deliberately wrong attach APN, 2026-09-20 — the status page said
			// "searching" and "detached" and stopped there).
			//
			// Same complementarity regdetail.uc already relies on for the
			// registration cause: the structured protocol reliably reports the
			// STATE, the modem's own extended error report carries the reason.
			// Only when there is a channel to ask on — MBIM-only boxes have
			// none, and then the answer is simply the state.
			if (!self.at)
				return cb ? cb(null, self.attach_info) : null;

			self.at.send('AT+CEER', (aerr, ares) => {
				if (self._gen != gen)
					return cb ? cb({ error: 'gone' }, null) : null;

				let c = aerr ? null : atparse.parse_ceer(ares?.lines);

				if (c) {
					self.attach_info.ceer_text = c.text;

					// a numeric cause maps through the same 3GPP table the
					// registration reject uses; a free-text one stands alone
					if (c.cause != null) {
						self.attach_info.nw_error = c.cause;
						self.attach_info.nw_error_text =
							nasmod.REJECT_CAUSE[sprintf('%d', c.cause)] ?? c.text;
					}

					log('warn', sprintf('attach: %s — %s (apn %s)',
						self.attach_info.state_text ?? '?', c.text,
						self.attach_info.apn ?? '-'));
				}

				return cb ? cb(null, self.attach_info) : null;
			}, { timeout: ATTACH_CEER_MS });
		}, { timeout: ATTACH_INFO_MS });
	};

	// --- rich telemetry ----------------------------------------------------
	//
	// self.signal / self.cells / self.dsd_status / self.reg_detail are populated
	// in the SAME shapes the QMI modem.uc produces, so daemon.modem_signal /
	// modem_cells surface either backend unchanged. Each capability is sourced
	// via backend.choose in the order native-MBIM -> QMI-passthrough -> AT, the
	// choice cached per modem (_sig_be/_cells_be/_ca_be/_dsd_be/_regd_be).

	let drop_pt;   // defined beside teardown; forward-declared for _ensure_pt
	let flush_releases;   // defined beside pt_release; forward-declared for _ensure_pt

	// ONE BRING-UP AT A TIME. GET_VERSION_INFO and the CID allocations are
	// asynchronous, and until they finish self.pt is still null: every probe
	// arriving meanwhile would start a bring-up of its own, each allocating
	// modem-side CIDs, and only the last to finish would stay reachable in
	// self.pt — the others' CIDs could never be released. Callers arriving
	// while one runs wait for it (pt_waiters).
	let pt_opening = false, pt_waiters = [];

	// A passthrough whose requests have failed this many times IN A ROW is
	// rebuilt rather than trusted. The count (qmi_over_mbim.uc `failures`) is of
	// MBIM-level failures only — a status or a timeout, the channel not carrying
	// the request. A QMI error reply (a message the firmware lacks, a value it
	// cannot give) is an answer and resets it, so the per-tick probes of
	// optional messages can never drive a rebuild.
	//
	// What notices: every _ensure_pt caller, which includes the telemetry
	// dispatch (telemetry_mbim.uc with_pt) and _ensure_uim/_ensure_wms. Code that
	// holds self.uim / self.wms directly (sim.uc, sms.uc) keeps failing on a dead
	// stack until one of those runs; with telemetry off that is the next SIM/SMS
	// op through the ensure functions or a reset.
	const PT_STALE_AFTER = 5;

	let pt_stale = () => ((self.pt?.shim?.failures ?? 0) >= PT_STALE_AFTER);

	// Lazy, idempotent bring-up of the QMI-over-MBIM passthrough service stack.
	// The whole QMI client stack runs over the open MBIM channel (qom shim), so
	// qmi_backend.* works unchanged. Non-fatal: cb(false) simply drops the
	// capability to its AT/none fallback.
	//
	// CRITICAL: never CTL SYNC — on real HW that resets the embedded QMI state
	// and tears down the live MBIM data session. GET_VERSION_INFO is issued
	// directly, then a CID is allocated per needed service.
	self._ensure_pt = function(cb) {
		// A STACK THAT STOPPED ANSWERING IS REBUILT, NOT KEPT. The modem can drop
		// the QMI clients it handed out over the passthrough while the MBIM
		// session stays up — an RM520N answered every passthrough request with
		// MBIM_STATUS_FAILURE after the network ended its session and it
		// re-applied its carrier configuration (evidence: ddimension/wwand#30).
		// A cached stack that is never re-validated keeps QMI away until the
		// modem restarts. A rebuild is GET_VERSION_INFO and fresh ALLOCATE_CIDs
		// over the same channel, exactly the first bring-up; never a SYNC (see
		// below).
		if (self.pt && pt_stale()) {
			log('notice', sprintf('qmi-over-mbim: %d passthrough requests failed in a row over %d s — rebuilding its QMI clients',
				self.pt.shim.failures, time() - (self.pt.shim.failing_since || time())));
			drop_pt();
		}

		if (self.pt) {
			// owed releases go out while the stack they belong to answers
			flush_releases();
			return cb(true);
		}

		// remembered "no passthrough on this modem" so we don't rebuild a shim +
		// re-probe on every capability (reset on teardown/protocol change)
		if (self._pt_failed || !self.mbim)
			return cb(false);

		push(pt_waiters, cb);

		if (pt_opening)
			return;

		pt_opening = true;

		let gen = self._gen;

		let shim = qom.create(self.mbim, { log: log });
		let ctl = client_mod.create(shim, ctlmod.default, 0, hooks);

		let complete = (up) => {
			let waiters = pt_waiters;

			pt_waiters = [];
			pt_opening = false;

			for (let w in waiters)
				w(up);
		};

		// A bring-up that fails on a modem whose passthrough never worked this
		// session means it has none, and that is remembered. Once one has worked
		// (_pt_built), a failure is a stack caught mid-reset: remembering it
		// would turn one bad moment into no QMI until the next teardown, so it is
		// simply tried again at the next re-probe — however many times it fails.
		// A failure caused by a teardown (its destroy() pays the pending request
		// with an error) says nothing about the modem and remembers nothing.
		let bail = () => {
			// ...and never from a probe made while the modem was still coming
			// up: that says nothing about the modem either
			if (self._gen == gen && index([ 'ABSENT', 'INIT_TRANSPORT', 'INIT_SERVICES' ], self.state) < 0)
				self._pt_failed = !self._pt_built;
			if (self._pt_built && self._gen == gen)
				log('notice', 'qmi-over-mbim: rebuilding the passthrough failed — trying again at the next re-probe');
			ctl.destroy();
			shim.close();
			complete(false);
		};

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
					// a teardown that ran meanwhile ended the session this stack
					// was built for; publishing it would hand the next session a
					// stack on a channel that is gone
					if (self._gen != gen) {
						for (let c in [ ctl, nas, dsd ])
							if (c)
								c.destroy();

						shim.close();
						return complete(false);
					}

					// the services the modem lists over the passthrough: what a
					// plugin's client can be asked for (extra_client)
					self.pt = { shim: shim, ctl: ctl, nas: nas, dsd: dsd, services: have };

					// the counterpart of the "rebuilding" line: without it a
					// log shows the attempt and never whether it took
					if (self._pt_built)
						log('notice', sprintf('qmi-over-mbim: passthrough rebuilt — QMI answering again (NAS cid %d%s)',
							nas.cid, dsd ? sprintf(', DSD cid %d', dsd.cid) : ''));

					self._pt_built = true;
					complete(true);
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
		let done = () => {
			scaffold.resolve_active_sim(self.info.iccid, self.info.imsi);

			// re-program the attach profile from the (possibly new) override
			// and config — QMI parity (modem.uc reapply_sim); only once the
			// init chain has passed its own attach step
			if (index([ 'REGISTERING', 'READY' ], self.state) >= 0 && self.mbim)
				return self._apply_attach(() => cb ? cb(null) : null);

			if (cb)
				cb(null);
		};

		self.mbim.command(bc, 'SUBSCRIBER_READY_STATUS', 'query', {}, (err, d) => {
			if (!err) {
				if (d.subscriber_id != null && d.subscriber_id != '')
					self.info.imsi = d.subscriber_id;
				if (d.sim_iccid != null && d.sim_iccid != '')
					self.info.iccid = d.sim_iccid;
			}

			// MBIM says nothing of a card that is not in the modem's own
			// slot (QMI UIM Remote, wwand-rsim): the card's own files — over
			// the passthrough's UIM or AT, fresh — name it instead. Without
			// it the card's wwand_sim did not match and the interface's APN
			// was dialled (HW-seen on an RM520N lent a card, 2026-09-27).
			if (self.info.iccid != null && self.info.imsi != null)
				return done();

			sim.read_identity(self, (id) => {
				self.info.imsi = self.info.imsi ?? id.imsi;
				self.info.iccid = self.info.iccid ?? id.iccid;
				done();
			}, { fresh: true });
		});
	};

	// ensure a QMI client over the passthrough and cache it as self[field]:
	// one factory for the identical _ensure_uim/_ensure_wms bodies. cb() either
	// way — the caller's probe verifies the service actually answers.
	let ensure_pt_client = (field, schema) => (cb) => {
		// a client on a stack that stopped answering goes with the rebuild in
		// _ensure_pt (drop_pt clears it), so do not hand it out meanwhile
		if (self[field] && !pt_stale())
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
	// GIVE THE CID BACK. Every passthrough client is allocated out of the
	// MODEM's client table, and a destroyed-but-not-released one stays in it
	// until the modem's stack resets — the same finite resource modem.uc's
	// teardown release burst exists to protect (modem.uc:359,:1416). The
	// session-long clients (pt.nas/dsd, uim, wms) are allocated once and go
	// with the session; these two allocate PER CALL, so a scripted reattach
	// loop walked the table down on its own. An E182E-class stack has room for
	// a handful. Nothing in the passthrough released anything before this.
	// A RELEASE THAT WAS NOT ACKNOWLEDGED IS STILL OWED. destroy() forgets
	// the client on our side, the modem's table keeps the CID until a
	// RELEASE_CID succeeds — one that timed out or failed left a CID nobody
	// tracked, and every hold/wake (a DMS client each) took another out of a
	// table the E182E class has room for a handful in (drop_pt). Entries
	// { service, cid, pt, tries, busy } stay here until acknowledged, are
	// tried again at the next use of the same stack (flush_releases), go
	// with drop_pt's release burst when the stack is dropped, and are given
	// up after PT_RELEASE_TRIES — said, so a leak is at least visible.
	const PT_RELEASE_TRIES = 3;

	self._pt_unreleased = [];

	let send_release = (e) => {
		if (e.busy || self.pt !== e.pt || !e.pt?.ctl)
			return;

		e.busy = true;

		e.pt.ctl.request('RELEASE_CID', { release: { service: e.service, cid: e.cid } }, (err) => {
			e.busy = false;

			// acknowledged; or cancelled — the stack went, and drop_pt's
			// burst carried this entry
			if (!err || err.error == 'cancelled') {
				self._pt_unreleased = filter(self._pt_unreleased, (x) => x !== e);
				return;
			}

			if (++e.tries >= PT_RELEASE_TRIES) {
				log('warn', sprintf('qmi-over-mbim: releasing CID %d (service %d) failed %d times (%J) — giving it up; the modem may keep it until it resets',
					e.cid, e.service, e.tries, err));
				self._pt_unreleased = filter(self._pt_unreleased, (x) => x !== e);
			}
		}, { timeout: self.timing.pt_release_ms ?? 3000, no_recovery: true });
	};

	flush_releases = () => {
		for (let e in self._pt_unreleased)
			send_release(e);
	};

	let pt_release = (client) => {
		if (!client)
			return;

		client.destroy();

		// the session ending takes the whole table with it; asking a modem
		// that is gone only logs a failure nobody can act on
		if (self._gen != client._pt_gen || !self.pt?.ctl)
			return;

		let e = { service: client.service, cid: client.cid, pt: client._pt ?? self.pt, tries: 0 };

		push(self._pt_unreleased, e);
		send_release(e);
	};

	// A plugin's client of a QMI service the core does not know, over the
	// QMI-over-MBIM passthrough — the QMI modem's extra_client, same contract
	// (modem.uc), `before_release` included: the modem owns it, releases its CID on teardown and when the
	// passthrough is rebuilt, and `destroyed` tells the plugin to ask again.
	// Which indications the passthrough carries depends on the service
	// (qmi_over_mbim.uc:143-151): NAS pushes none on the EG06 and the RM520N,
	// UIM Remote pushes all of its own on the RM520N — a remote SIM works over
	// MBIM there (HW-observed 2026-09-27). A plugin whose service stays silent
	// finds that out from its own protocol.
	self.extra_client = function(schema, cb) {
		let gen = self._gen;

		// the MBIM session not open yet (init, a restart): a moment away,
		// not "this modem cannot" — the plugin tries again without a backoff.
		// Still in its init chain counts too: a passthrough probe there fails
		// (function_error before MBIM is through its own bring-up) and, the
		// flag of a working one reset by the restart, was remembered as "no
		// passthrough on this modem" until the next teardown (HW-seen on an
		// RM520N, 2026-09-27)
		if (!self.mbim || index([ 'ABSENT', 'INIT_TRANSPORT', 'INIT_SERVICES' ], self.state) >= 0)
			return cb({ error: 'not_ready' }, null);

		self._ensure_pt((up) => {
			if (self._gen != gen)
				return cb({ error: 'cancelled' }, null);

			if (!up)
				return cb({ error: 'unsupported', detail: 'no QMI passthrough on this modem' }, null);

			if (self.pt.services && !self.pt.services[sprintf('%d', schema.service)])
				return cb({ error: 'service_unavailable' }, null);

			let pt = self.pt;

			pt.ctl.request('ALLOCATE_CID', { service: schema.service }, (aerr, adata) => {
				if (aerr || !adata?.allocation)
					return cb(aerr ?? { error: 'no_allocation' }, null);

				let c = client_mod.create(pt.shim, schema, adata.allocation.cid, hooks);

				c._pt_gen = gen;

				// the stack went while the allocation was on its way: a
				// client on it would never answer, and nothing would free it
				if (self._gen != gen || self.pt !== pt) {
					// its CID is on a stack that is gone: releasing it through
					// the new one would free somebody else's number there
					c.destroy();
					return cb({ error: 'cancelled' }, null);
				}

				push(self.extra_clients, c);
				cb(null, c);
			}, { no_recovery: true });
		});
	};

	// a plugin giving its client back; only one this modem still owns is
	// released on the wire (a rebuilt passthrough numbers its CIDs afresh)
	self.extra_release = function(client, cb) {
		let owned = false;

		self.extra_clients = filter(self.extra_clients ?? [], (c) => {
			if (c === client) {
				owned = true;
				return false;
			}

			return true;
		});

		if (owned) {
			if (self._gen == client._pt_gen && self.pt?.ctl)
				modem_common.before_release([ client ], log);

			pt_release(client);
		}
		else
			client?.destroy();

		if (cb)
			cb(null);
	};

	self.reset = function(cb) {
		// also the way out when MBIM or its passthrough is what hangs: the
		// AT port is opened for the one write if it is not open yet
		// (modem_common.at_reset)
		let at_reset = (why) => modem_common.at_reset(self, at_opts, log,
			why ?? 'no QMI passthrough to reset with', (sent) => {
				if (!sent)
					return cb({ error: 'unsupported_on_backend' });

				notify_contexts('lost');
				cb(null, { resetting: true, via: 'at' });
			});

		self._ensure_pt((up) => {
			if (!up)
				return at_reset();

			self.pt.ctl.request('ALLOCATE_CID', { service: dmsmod.default.service }, (aerr, adata) => {
				if (aerr || !adata?.allocation)
					return at_reset();

				let dms = client_mod.create(self.pt.shim, dmsmod.default, adata.allocation.cid, hooks);

				dms._pt_gen = self._gen;

				log('warn', 'admin modem reset (DMS offline -> reset over the MBIM passthrough)');
				qmi_backend.set_opmode(dms, 'offline', () =>
					qmi_backend.set_opmode(dms, 'reset', (rerr) => {
						// a reset that took wipes the modem's client table with
						// it, so there is nothing to give back — and the request
						// would chase a modem already on its way down. A REFUSED
						// one leaves the modem and the CID exactly as they were,
						// which is the case that leaked.
						if (rerr)
							pt_release(dms);
						else
							dms.destroy();

						// and say which of the two happened. This reported
						// `resetting: true` unconditionally, so a refusal read
						// to LuCI and to the caller exactly like a reset under
						// way — and they then waited for a modem that was never
						// going anywhere.
						if (rerr?.error == 'timeout')
							return at_reset('the QMI passthrough does not answer');

						if (rerr)
							return cb({ error: 'qmi', detail: rerr });

						notify_contexts('lost');
						cb(null, { resetting: true });
					}));
			}, { no_recovery: true });
		});
	};

	// PS attach (on) or detach over MBIM PACKET_SERVICE set, radio on — the
	// same raw network action as modem.uc ps_attach; the session and
	// registration handling around it is netsel_ops (modem_detach /
	// modem_attach). The answer carries the resulting packet-service state.
	self.ps_attach = function(on, cb) {
		if (!self.mbim)
			return cb({ error: 'unsupported_on_backend' });

		self.mbim.command(bc, 'PACKET_SERVICE', 'set', {
			packet_service_action: on ? bc.PACKET_SERVICE_ATTACH : bc.PACKET_SERVICE_DETACH,
		}, (err, data) => {
			if (err)
				return cb({ error: 'mbim', detail: err });

			self._update_packet_service(data);
			cb(null, { ok: true, via: 'mbim', packet_service_state: data?.packet_service_state });
		}, { no_recovery: true, timeout: 60000 });
	};

	// network reattach (ubus modem_reattach): detach/attach at registration
	// level WITHOUT a full reset. Preference: passthrough DMS low_power ->
	// online (identical to the HW-proven QMI path), else native RADIO_STATE
	// off -> on. Implemented here because netsel_ops' AT+COPS fallback rides a
	// port that is frequently dead in MBIM mode (EG06: AT times out).
	// A reattach is radio OFF, wait, radio ON — so it is half-finished at every
	// await, and a teardown landing in the middle must not be read as a reason to
	// carry on. The generation captured here is what tells the two apart: a
	// cancellation is the session ending, not a transport declining.
	self.reattach = function(cb) {
		cb = cb ?? (() => null);

		let gen = self._gen;
		let gone = () => self._gen != gen;

		let via_radio = () => {
			if (gone())
				return cb({ error: 'cancelled' });

			// a modem that never had an MBIM client is a different answer from
			// one whose session ended under us — keep them apart
			if (!self.mbim)
				return cb({ error: 'unsupported_on_backend' });

			log('notice', 'network reattach (MBIM radio off -> on)');
			self.mbim.command(bc, 'RADIO_STATE', 'set',
				{ radio_state: bc.RADIO_STATE_OFF }, () => {
					// Arming here is what outlived teardown: it cancels its
					// timers first and destroys the clients after, so a timer
					// armed from a cancellation callback is never cancelled —
					// and by the time it fires `self.mbim` is null and the
					// command below throws.
					if (gone())
						return cb({ error: 'cancelled' });

					settle_timer = uloop.timer(self.timing.settle, () => {
						if (gone() || !self.mbim)
							return cb({ error: 'cancelled' });

						self.mbim.command(bc, 'RADIO_STATE', 'set',
							{ radio_state: bc.RADIO_STATE_ON }, (err, rdata) => {
								note_radio(rdata);
								cb(err ? { error: 'mbim', detail: err } : null,
									{ ok: true, action: 'reattach', via: 'mbim_radio' });
							});
					});
				});
		};

		self._ensure_pt((up) => {
			if (gone())
				return cb({ error: 'cancelled' });

			if (!up)
				return via_radio();

			self.pt.ctl.request('ALLOCATE_CID', { service: dmsmod.default.service }, (aerr, adata) => {
				// A cancelled allocation is the session ending. Falling through
				// to via_radio() here sent a native MBIM RADIO_STATE_OFF into a
				// teardown — the QMI client refuses further requests by itself
				// now, but MBIM is a different transport and still reaches the
				// modem.
				if (gone() || aerr?.error == 'cancelled')
					return cb({ error: 'cancelled' });

				if (aerr || !adata?.allocation)
					return via_radio();

				let dms = client_mod.create(self.pt.shim, dmsmod.default, adata.allocation.cid, hooks);

				dms._pt_gen = self._gen;

				// this client exists for the duration of ONE reattach; every exit
				// below goes through here, so the CID comes back on all of them
				let done = (err, res) => {
					pt_release(dms);
					cb(err, res);
				};

				log('notice', 'network reattach (passthrough DMS low_power -> online)');
				qmi_backend.set_opmode(dms, 'low_power', () => {
					if (gone())
						return done({ error: 'cancelled' });

					settle_timer = uloop.timer(self.timing.settle, () => {
						if (gone())
							return done({ error: 'cancelled' });

						qmi_backend.set_opmode(dms, 'online', (err) => {
							done(err ? { error: 'qmi', detail: err } : null,
								{ ok: true, action: 'reattach', via: 'qmi_passthrough' });
						});
					});
				});
			}, { no_recovery: true });
		});
	};

	// One DMS request over the QMI passthrough, on a CID held for that
	// request only (the reattach's pattern): fn(dms, done) runs it, and
	// done(err, data) gives the CID back and answers cb(err, data). err
	// { error: 'no_passthrough' } when there is no QMI to ask, `cancelled`
	// when the session ended meanwhile. Never a CTL SYNC: over the
	// passthrough it resets the modem's embedded QMI state and ends the MBIM
	// data session (qmi_over_mbim.uc blocks it).
	let pt_dms = (fn, cb) => {
		let gen = self._gen;

		self._ensure_pt((up) => {
			if (self._gen != gen)
				return cb({ error: 'cancelled' });

			if (!up)
				return cb({ error: 'no_passthrough' });

			// the owed releases first: a table with a leaked CID in it is
			// the one that refuses this allocation
			flush_releases();

			self.pt.ctl.request('ALLOCATE_CID', { service: dmsmod.default.service }, (aerr, adata) => {
				if (self._gen != gen || aerr?.error == 'cancelled')
					return cb({ error: 'cancelled' });

				if (aerr || !adata?.allocation)
					return cb({ error: 'no_passthrough' });

				let dms = client_mod.create(self.pt.shim, dmsmod.default, adata.allocation.cid, hooks);

				dms._pt_gen = self._gen;
				dms._pt = self.pt;

				fn(dms, (err, data) => {
					pt_release(dms);
					cb(err, data);
				});
			}, { no_recovery: true });
		});
	};

	// SET_OPERATING_MODE over the passthrough; cb(err). Methods, both, so a
	// test can stand in for a passthrough the MBIM mock does not have.
	self._pt_opmode = function(mode, cb) {
		pt_dms((dms, done) => qmi_backend.set_opmode(dms, mode, (err) => done(err)), (err) => cb(err));
	};

	// GET_OPERATING_MODE over the passthrough (libqmi 1.38.0
	// qmi-service-dms.json "Get Operating Mode", 0x002D, output Mode 0x01);
	// cb(err, mode).
	self._pt_get_opmode = function(cb) {
		pt_dms((dms, done) => dms.request('GET_OPERATING_MODE', {}, (err, d) => done(err, d?.mode),
			{ no_recovery: true }), cb);
	};

	// Backend operation `set_opmode` (docs/backend-interface.md): online /
	// low_power / offline — the radio park of a plugin's hold
	// (`modem_radio`) and of `option lowpower`. `lowpower_parked` records a
	// successful low_power, as on QMI, and the supervisors read it.
	//
	// A PARK GOES OVER THE PASSTHROUGH'S DMS FIRST: LOW_POWER is the mode QMI
	// modems are parked in, RF off with the SIM kept up ("temporarily
	// disabled RF", qmi-enums-dms.h, libqmi 1.38.0) — a remote SIM served
	// through UIM Remote over this same passthrough keeps running. MBIM's own
	// software radio switch (Basic Connect Radio State) where there is no
	// passthrough, where DMS refuses, and during the init chain, where a
	// passthrough probe fails and would be remembered as "none on this
	// modem" (extra_client). `offline` maps to that switch too: MBIM has
	// only the one.
	//
	// A WAKE UNDOES WHAT MAY BE OFF, and the two switches are independent:
	// undoing one leaves the other off. Parked over DMS by this object: DMS
	// online, and no switch fallback (the switch does not undo a DMS low
	// power, and "woken" would then be a lie). Parked over the switch: the
	// switch on — and DMS online as well while this object has not set DMS
	// itself (`_dms_unknown`): a daemon that parked it over DMS and then
	// restarted left it in low power, and the modem object that knew is
	// gone. The vendor FCC unlock a held init deferred (`_fcc_due`,
	// hold_at_open) goes first.
	self.set_opmode = function(mode, cb) {
		cb = cb ?? (() => null);

		if (!self.mbim)
			return cb({ error: 'unsupported', detail: 'no mbim channel' });

		if (mode != 'online' && mode != 'low_power' && mode != 'offline')
			return cb({ error: 'unsupported', mode: mode });

		let gen = self._gen;
		let was_parked = self.lowpower_parked;
		let early = index([ 'ABSENT', 'INIT_TRANSPORT', 'INIT_SERVICES' ], self.state) >= 0;
		let gone = () => self._gen != gen || !self.mbim;

		let done = (err, via) => {
			if (self._gen != gen)
				return cb({ error: 'cancelled' });

			if (!err) {
				self.lowpower_parked = (mode == 'low_power');
				self._park_via = self.lowpower_parked ? via : null;
			}

			// woken from a park: the next registration is reported as one
			// (_update_register)
			if (!err && was_parked && mode == 'online')
				self._wake_pending = true;

			cb(err ?? null);
		};

		// k(err)
		let radio = (k) => self.mbim.command(bc, 'RADIO_STATE', 'set',
			{ radio_state: (mode == 'online') ? bc.RADIO_STATE_ON : bc.RADIO_STATE_OFF },
			(err, data) => {
				if (gone())
					return cb({ error: 'cancelled' });

				note_radio(data);
				k(err ? { error: 'mbim', detail: err } : null);
			});

		// k(err): no_passthrough when there is no QMI to ask
		let dms = (k) => self._pt_opmode(mode, (err) => {
			if (gone() || err?.error == 'cancelled')
				return cb({ error: 'cancelled' });

			if (!err)
				self._dms_unknown = false;

			k(err);
		});

		if (mode != 'online') {
			if (early)
				return radio((err) => done(err, 'radio'));

			return dms((err) => {
				if (!err)
					return done(null, 'dms');

				if (err.error != 'no_passthrough')
					log('info', sprintf('radio %s over the QMI passthrough refused (%J) — using the MBIM radio switch',
						mode, err));

				radio((rerr) => done(rerr, 'radio'));
			});
		}

		let via = self._park_via;

		// DMS best-effort: no passthrough, or a refusal, is said and passed
		let dms_too = (k) => (early || !(via == null || self._dms_unknown)) ? k() : dms((err) => {
			if (err && err.error != 'no_passthrough')
				log('info', sprintf('radio online over the QMI passthrough refused (%J)', err));
			k();
		});

		let wake = () => (via == 'dms')
			? dms((err) => done(err))
			: dms_too(() => radio((err) => done(err)));

		if (!self._fcc_due)
			return wake();

		self._fcc_due = false;
		fcc_unlock(() => gone() ? cb({ error: 'cancelled' }) : wake());
	};

	// telemetry (signal/cells/CA/data-mode/reg-detail + slow log loop + fast
	// watch loop) — lives in telemetry_mbim.uc; attaches the _refresh_*
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

	// Drop the whole passthrough stack: give its session-long CIDs back, destroy
	// its clients and close the shim. Called by teardown, and by _ensure_pt when
	// the passthrough has stopped answering and is rebuilt.
	drop_pt = () => {
		// DETACH FIRST, clean up after. destroy() pays a client's pending
		// callbacks synchronously (client.uc:217), and one of those may be a
		// probe that calls _ensure_pt or _ensure_uim again. Still seeing the
		// stack being dropped, it would drop it a second time and start a
		// bring-up in the middle of this one.
		//
		// uim and wms go with it: they rode on the same shim, and
		// ensure_pt_client caches into self[field] and short-circuits when it is
		// set — a wms left behind survived a teardown+retry on the same object,
		// and every later SMS op used a client bound to a shim that is gone,
		// failing forever and feeding the proto-error counter, which eventually
		// power-cycles a healthy modem.
		let pt = self.pt, uim = self.uim, wms = self.wms, extra = self.extra_clients ?? [];
		// ...and the releases still owed on this stack (pt_release): the
		// burst below is their last chance
		let owed = filter(self._pt_unreleased, (e) => e.pt === pt);

		self._pt_unreleased = filter(self._pt_unreleased, (e) => e.pt !== pt);

		self.pt = null;
		self.uim = null;
		self.wms = null;
		// plugins' clients rode on the same shim: released and destroyed with
		// it, and `destroyed` tells their owners to ask again
		self.extra_clients = [];

		// EACH CLEANUP GUARDED ON ITS OWN, not the sequence. One catch around the
		// whole block means the first throwing destroy skips the clients after it
		// AND the shim close — and with the stack already detached above, that
		// strands a shim that is still open with clients registered on it
		// (qmi_over_mbim.uc:135).
		if (pt) {
			// GIVE THE SESSION-LONG CIDs BACK FIRST, while ctl and the shim are
			// still up. These were allocated out of the MODEM's client table
			// and destroy() deliberately does not release them (client.uc:201)
			// — closing the HOST's MBIM session is not shown to reset the
			// modem's embedded QMI client table, so every daemon reload leaked
			// a NAS, a DSD and (once used) a UIM and a WMS. The E182E-class
			// table has room for a handful. Same burst modem.uc:1563 does for
			// the native side, which the passthrough never had. ctl is NOT in this list: it is the
			// implicit client (cid 0) and it is what carries RELEASE_CID for
			// all the others, so it has to outlive them.
			// a plugin client's goodbye first (modem_common.before_release):
			// written ahead of the RELEASE_CID burst on the same shim
			if (pt.ctl)
				modem_common.before_release(extra, log);

			for (let c in [ pt.nas, pt.dsd, uim, wms, ...extra, ...owed ]) {
				if (!c || !pt.ctl)
					continue;

				try {
					pt.ctl.request('RELEASE_CID',
						{ release: { service: c.service, cid: c.cid } },
						() => null, { timeout: 3000, no_recovery: true });
				} catch (e) {
					log('err', sprintf('passthrough drop: releasing a CID threw: %s', e));
				}
			}

			for (let c in [ pt.ctl, pt.nas, pt.dsd, uim, wms, ...extra ]) {
				if (!c)
					continue;

				try {
					c.destroy();
				} catch (e) {
					log('err', sprintf('passthrough drop: a client callback threw: %s', e));
				}
			}

			try {
				pt.shim.close();
			} catch (e) {
				log('err', sprintf('passthrough drop: closing the shim threw: %s', e));
			}
		}
	};

	self.teardown = function() {
		// see modem.uc: make_fail refuses to arm a retry while this is raised,
		// because a failure reported from INSIDE a teardown would arm it after
		// the cancel pass below and restart a modem that is being stopped. The
		// QMI backend grew this first; MBIM reaches the same re-arm by its own
		// route (a synchronous cancellation from the recovery cycle re-arming
		// settle_timer at :249/:253). Review follow-up, 2026-09-19.
		self._teardown_depth = (self._teardown_depth ?? 0) + 1;

		// first, so anything the destroys below call back into can tell that its
		// session is over (see `_gen` at the declaration)
		self._gen++;

		for (let t in [ retry_timer, reg_timer, settle_timer, at_drain_timer, sim_poll_timer ])
			if (t)
				t.cancel();

		retry_timer = reg_timer = settle_timer = at_drain_timer = sim_poll_timer = null;
		telem.stop();

		modem_common.close_at(self);

		// GUARDED, because destroying a client pays its pending callbacks
		// SYNCHRONOUSLY (client.uc:217, mbim_client.uc:265) and those callbacks
		// are not ours. One that throws would skip the depth decrement at the
		// end, leaving it raised for the life of the object — and make_fail then
		// refuses every future retry, which is worse than whatever the callback
		// was complaining about. The QMI teardown wraps its equivalent call for
		// the same reason; NCM needs none, close_at() discards its queue without
		// paying it (atcmd.uc:1073). Review follow-up, 2026-09-19.
		drop_pt();
		self._pt_failed = false;
		self._pt_built = false;

		// WHAT THE OLD MODEM SAID IS NOT WHAT THE NEW ONE SAYS. Both of these
		// are published in `status`, and both are filled by indications that
		// only fire on a CHANGE — so a value left here describes a modem
		// incarnation that is gone and nothing will correct it until the next
		// change happens to arrive. A radio switch reported off, or a slot
		// reported empty, would then outlive the reason for it. `radio` is
		// re-read at init; `slot_state` is only ever event-driven, which is
		// exactly why it must not persist.
		self.radio = null;
		self.slot_state = null;
		// ...and the carrier configuration, for the same reason plus one more:
		// the attach-time retry below skips itself when this is already set, so
		// a value left here would also stop the NEW modem from ever being
		// asked.
		self.modem_config = null;
		self._modem_config_asked = false;

		// ...and the note that went with them. A backend note is cleared by the
		// backend; a teardown means there is no longer anything to clear it.
		if (self.control_note != null && index(self.control_note, 'radio disabled') == 0)
			self.control_note = null;
		backend.reset(self, '_sig_be', '_cells_be', '_ca_be', '_dsd_be', '_regd_be', '_apdu_be', '_esim_be');

		if (self.mbim) {
			try {
				self.mbim.destroy();
			} catch (e) {
				log('err', sprintf('teardown: an mbim callback threw: %s', e));
			}

			self.mbim = null;
			self._refresh_fb?.disarm();
			self._refresh_fb = null;
			self.mbim_uicc = null;
			self.mbim_sms = null;
			self.mbim_slots = null;
		}

		if (self.hub) {
			self.hub.close();
			self.hub = null;
		}

		self._teardown_depth--;
	};

	// stop() + _device_gone() installed by modem_common.scaffolding

	return self;
};
