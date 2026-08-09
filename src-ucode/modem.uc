// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — per-modem QMI state machine.
//
// States: ABSENT -> INIT_TRANSPORT -> INIT_SERVICES -> INIT_DATAPATH ->
//   SET_OPMODE -> SIM_UNLOCK -> CONFIGURE_NET -> REGISTERING -> READY.
//   SIM_BLOCKED terminal until config reload; any failure -> backoff retry;
//   device removal -> ABSENT.
//
// opts = { id, device, config, deps: { transport_open, log, on_event },
//          timing } — transport_open is test injection; see TIMING_DEFAULTS.

'use strict';

import * as uloop from 'uloop';
import * as fs from 'fs';
import * as transport_mod from './transport.uc';
import * as client_mod from './client.uc';
import * as sim from './sim.uc';
import * as netlink from './netlink.uc';
import * as recovery_mod from './recovery.uc';
import * as qmi_backend from './qmi_backend.uc';
import * as modem_common from './modem_common.uc';
import * as regdetail from './regdetail.uc';
import * as telemetry_qmi from './telemetry_qmi.uc';
import * as config_check from './config_check.uc';
import * as modem_init_qmi from './modem_init_qmi.uc';
import * as protoswitch from './protocol_switch.uc';
import * as ctlmod from './codec/schema/ctl.uc';
import * as dmsmod from './codec/schema/dms.uc';
import * as nasmod from './codec/schema/nas.uc';
import * as uimmod from './codec/schema/uim.uc';
// loc.uc + wms.uc are lazy-loaded (require of a *_lazy shim) only when GPS /
// SMS is actually used, keeping those schemas off the heap on the common path.

const TIMING_DEFAULTS = {
	...modem_common.TIMING_BASE,   // settle/reg_timeout/backoff_min/backoff_max
	sync_retry: 1000,      // delay between CTL sync attempts
	sim_settle: 5000,      // settle after PIN verify without indication (old: sleep 5)
	card_poll: 1000,       // card-status re-poll while initializing
};


// parse_modes lives in qmi_backend.uc; re-exported for daemon/tests.
export const parse_modes = qmi_backend.parse_modes;

// unpack GSM 7-bit packed septets (LSB-first) into bytes. Latin operator names
// map 1:1 to ASCII in the default alphabet, so we emit them directly.
function gsm7_unpack(bytes)
{
	let out = '', acc = 0, bits = 0;

	for (let i = 0; i < length(bytes); i++) {
		acc |= (ord(bytes, i) << bits);
		bits += 8;

		while (bits >= 7) {
			out += chr(acc & 0x7f);
			acc >>= 7;
			bits -= 7;
		}
	}

	return out;
}

// the NAS current-PLMN description is a raw name string with no coding-scheme
// byte: RG50x/RG65x send plain ASCII, older Quectel (EG06) GSM-7-bit pack it.
// Heuristic: a plain-ASCII name is all printable; anything with a high byte
// (>=0x80) OR a control byte (<0x20) is treated as GSM-7-bit packed and
// unpacked, keeping the result only if it decodes to clean printable ASCII.
// (A packed short name can be all-low-byte — e.g. "PLAY" packs to 50 66 30 0b,
// which as raw ASCII reads "Pf0\x0b" — so the trigger must include control
// bytes, not just high bytes; issue #2.)
function decode_operator_name(s)
{
	if (s == null || s == '')
		return s;

	// drop trailing pad some modems append (NUL, CR/LF, spaces) before deciding,
	// so a clean ASCII name with a trailing NUL is not mistaken for packed data
	while (length(s) && (ord(s, length(s) - 1) == 0 || ord(s, length(s) - 1) == 0x0d ||
	                     ord(s, length(s) - 1) == 0x0a || ord(s, length(s) - 1) == 0x20))
		s = substr(s, 0, length(s) - 1);

	if (s == '')
		return s;

	let packed = false;

	for (let i = 0; i < length(s); i++) {
		let c = ord(s, i);
		if (c >= 0x80 || c < 0x20) { packed = true; break; }
	}

	if (!packed)
		return trim(s);

	let u = gsm7_unpack(s);

	while (length(u) && (ord(u, length(u) - 1) == 0 || ord(u, length(u) - 1) == 0x0d))
		u = substr(u, 0, length(u) - 1);

	for (let i = 0; i < length(u); i++)
		if (ord(u, i) < 0x20 || ord(u, i) > 0x7e)
			return s;   // not clean -> keep the original (trimmed) raw string

	return u;
}

// dsd_from_serving / dsd_from_radio moved to modem_common (shared with MBIM).

export function create(opts)
{
	let self = {
		id: opts.id,
		device: opts.device,
		config: opts.config ?? {},
		timing: { ...TIMING_DEFAULTS, ...(opts.timing ?? {}) },

		state: 'ABSENT',
		hub: null,
		ctl: null,
		dms: null,
		nas: null,
		uim: null,
		wda: null,
		wds_cfg: null,     // config-scope wds client (profiles)
		datapath: null,    // { backend, urb_size, mux_devs, ep_id } after INIT_DATAPATH
		at: null,          // AT engine, best-effort
		at_tty: null,
		loc: null,         // LOC client when config.location is set
		location: null,    // last position report
		cells: null,       // last cell location info (telemetry collector)
		active_sim: null,  // matched per-SIM override (config wwand_sim) for the
		                   // inserted card: overrides pincode + apn/auth/pdp
		pin1: null,        // SIM PIN-lock state { state, retries, enabled }

		services: {},      // service id (string) -> { major, minor }
		info: {},          // model, revision, imei, ...
		reg: {},           // registration snapshot
		reg_detail: null,  // why (not) registered: reject cause, limited service
		config_warnings: null,  // runtime "modem doesn't match config/spec" checks
		signal: {},        // last signal info

		counters: null,    // shared with the recovery instance below
		contexts: [],
	};

	let deps = opts.deps ?? {};
	let transport_open = deps.transport_open ?? transport_mod.open;
	let log = deps.log ?? ((level, msg) => warn(sprintf('%s: modem %s: %s\n', level, self.id, msg)));

	let rec = recovery_mod.create({
		id: opts.id,
		failreboot: (opts.config ?? {}).failreboot,
		proto_error_limit: (opts.config ?? {}).proto_error_limit,
		fx: opts.recovery?.fx ?? netlink.default_fx((level, msg) => log(level, msg)),
		state_dir: opts.recovery?.state_dir,
		reboot_delay: opts.recovery?.reboot_delay,
		// board-provided modem repower (power-cycle or reset-gpio pulse); replaces usb-repower
		repower: opts.recovery?.repower,
		log: (level, msg) => log(level, msg),
	});

	rec.load();
	self.counters = rec.counters;
	self.recovery = rec;
	self.log_fn = log;

	// shared one-shot timer holder; teardown cancels whatever is pending.
	let tm = { retry: null, reg: null, settle: null, at_drain: null, probe: null };

	// protocol-neutral scaffolding (sets set_state/attach_context/… on self)
	let scaffold = modem_common.scaffolding(self, { deps: deps, log: log, rec: rec });
	let emit = scaffold.emit;
	let notify_contexts = scaffold.notify_contexts;

	// hooks shared by all clients: feed the recovery error counter.
	let client_hooks = {
		on_error: (client, kind, msg) => {
			let act = rec.on_proto_error();
			// a SYNC-wedged modem never reaches the attempt ladder, so escalate
			// the proto-error path itself: a hardware reset first, reboot only if
			// that fails to clear the wedge (see recovery.on_proto_error).
			if (act == 'usb_repower')
				rec.usb_repower();
			else if (act == 'reboot')
				rec.reboot('qmi error limit reached');

			log('debug', sprintf('qmi error (%s) svc %d %s, counter %d',
				kind, client.service, msg ?? '?', self.counters.proto_errors));
		},
		on_success: (client) => {
			rec.on_proto_success();
		},
	};

	self.alloc = function(schema, cb) {
		self.ctl.request('ALLOCATE_CID', { service: schema.service }, (err, data) => {
			if (err || !data?.allocation)
				return cb(err ?? { error: 'proto', detail: 'no allocation tlv' }, null);

			log('debug', sprintf('allocated cid %d for service %d',
				data.allocation.cid, schema.service));
			cb(null, client_mod.create(self.hub, schema, data.allocation.cid, client_hooks));
		});
	};

	self.release = function(client, cb) {
		if (!client)
			return cb ? cb(null) : null;

		client.destroy();

		if (!self.hub || self.hub.closed)
			return cb ? cb(null) : null;

		self.ctl.request('RELEASE_CID',
			{ release: { service: client.service, cid: client.cid } },
			(err) => cb ? cb(err) : null, { timeout: 3000 });
	};

	// backend-neutral NAS accessor. cb(nas|null).
	self.with_nas = function(cb) {
		cb(self.nas ?? null);
	};

	// backend-neutral WMS (SMS) accessor. cb(wms|null).
	self.with_wms = function(cb) {
		cb(self.wms ?? null);
	};

	// lazily allocate the WMS (SMS) client on first use — the wms schema is
	// require()d (via the *_lazy shim) so it stays off the heap until SMS is
	// used. `_wms_tried` gates the one-shot (self.wms null = unavailable or client).
	self._ensure_wms = function(cb) {
		if (self._wms_tried)
			return cb();

		self._wms_tried = true;

		let wmsmod = require('wwand.codec.schema.wms_lazy').s;

		if (!self.services[sprintf('%d', wmsmod.default.service)]) {
			self.wms = null;
			return cb();
		}

		self.alloc(wmsmod.default, (ew, wms) => {
			if (ew)
				log('warn', 'wms allocation failed, SMS unavailable');
			self.wms = ew ? null : wms;
			cb();
		});
	};

	// --- step chain --------------------------------------------------------

	let dp = opts.datapath ?? {};
	let at_opts = opts.at ?? {};


	let fail = modem_common.make_fail(self, {
		log: log, timing: self.timing, emit: emit,
		set_retry_timer: (t) => tm.retry = t,
	});

	// QMI bring-up chain (modem_init_qmi.uc); chain.begin() is the start() entry.
	let chain = modem_init_qmi.install(self, {
		log: log, emit: emit, notify_contexts: notify_contexts,
		fail: fail, dp: dp, at_opts: at_opts, tm: tm,
	});

	// record a failed connection cycle and run the resulting ladder action; also
	// called by the daemon on context-activation failure. QMI-side rungs run
	// against the live clients, so this happens before teardown.
	self.note_connect_failure = function(done) {
		done = done ?? ((action) => null);

		let action = rec.on_attempt();

		switch (action) {
		case 'reboot':
			rec.reboot('connection attempt limit reached');
			return done(action);

		case 'usb_repower':
			rec.usb_repower();
			return done(action);

		case 'opmode_cycle':
			if (!self.dms)
				return done(action);

			log('warn', 'recovery: cycling operating mode');
			qmi_backend.set_opmode(self.dms, 'low_power', () => {
				tm.settle = uloop.timer(self.timing.settle, () => {
					qmi_backend.set_opmode(self.dms, 'online', () => {
						tm.settle = uloop.timer(self.timing.settle, () => done(action));
					});
				});
			});
			return;

		case 'modem_reset':
			if (!self.dms)
				return done(action);

			log('warn', 'recovery: resetting modem');
			qmi_backend.set_opmode(self.dms, 'offline', () => {
				qmi_backend.set_opmode(self.dms, 'reset', () => done(action));
			});
			return;

		default:
			return done(action);
		}
	};


	// admin-triggered soft modem reset (ubus modem_reset — the apply step for
	// `deferred` selection/band settings): DMS offline -> reset. The modem
	// re-enumerates; discovery rebuilds it and re-kicks the auto interfaces.
	self.reset = function(cb) {
		if (!self.dms)
			return cb({ error: 'unsupported_on_backend' });

		log('warn', 'admin modem reset (DMS offline -> reset)');
		qmi_backend.set_opmode(self.dms, 'offline', () => {
			qmi_backend.set_opmode(self.dms, 'reset', () => {
				notify_contexts('lost');
				cb(null, { resetting: true });
			});
		});
	};

	// switch the control protocol (QMI <-> MBIM). On success the modem resets and
	// re-enumerates; discovery rebuilds it under the new driver.
	self.switch_protocol = function(target, cb) {
		protoswitch.switch_protocol(self, target, (err, res) => {
			if (!err && res.resetting) {
				emit('protocol_switch', { target: target });
				// drop clients/timers now; the device is about to vanish
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



	self._read_info = function(next) {
		qmi_backend.read_info(self.dms, (info) => {
			for (let k, v in info)
				self.info[k] = v;

			// …/device is the USB *interface* dir (1-1:1.3); one level up is
			// the USB device (1-1) carrying the descriptor strings (two would
			// be the hub — "xHCI Host Controller")
			let base = '/sys/class/usbmisc/' + substr(self.device, 5) + '/device/..';
			let sf = (f) => trim(fs.readfile(base + '/' + f) ?? '');

			let vid = sf('idVendor'), pid = sf('idProduct'), prod = sf('product');

			if (length(vid))
				self.info.usb = sprintf('%s:%s%s', vid, pid,
					length(prod) ? ' ' + prod : '');

			// some firmwares return junk from DMS GET_MODEL (old Huawei
			// sticks literally answer "0") — fall back to the USB device
			// descriptor strings so status/LuCI show a usable name; once the
			// AT channel opens, ATI (which such sticks answer properly)
			// upgrades this further (step_at -> _ati_info).
			let bogus = (s) => (s == null || trim(s) == '' || trim(s) == '0');

			if (bogus(self.info.model)) {
				self._model_generic = true;

				if (length(prod))
					self.info.model = prod;

				if (bogus(self.info.manufacturer)) {
					let manu = sf('manufacturer');

					if (length(manu))
						self.info.manufacturer = manu;
				}
			}

			let c = info.capabilities;

			if (c)
				log('info', sprintf('capabilities: max tx %d rx %d kbps, radio ifs [%s]',
					c.max_tx_rate, c.max_rx_rate, join(' ', c.radio_ifs ?? [])));

			log('notice', sprintf('%s %s, revision %s, imei %s',
				self.info.manufacturer ?? '?', self.info.model,
				self.info.revision, self.info.imei));

			// stable-identity gate: halt before SIM/context if the pinned IMEI
			// does not match this physical modem.
			if (!modem_common.check_identity(self, { emit: emit, log: log }))
				return;

			next();
		});
	};








	// shared wwand_sim matcher (modem_common — parity across all backends)
	let match_sim_override = (iccid, imsi) =>
		modem_common.match_sim_override(self.config?.sims, iccid, imsi);






	// live-config validation (config_check.uc); kept as a method for the init
	// chain + ubus revalidation.
	self.validate_config = function(cb) {
		config_check.validate(self, log, cb);
	};



	// the card changed in place (eSIM profile switch via SIM hot-reset, or a UIM
	// REFRESH): re-read identity, RE-RESOLVE the per-SIM override (the old card's
	// wwand_sim must not stick) and re-program the LTE attach profile — without
	// tearing the modem down. cb(changed) optional.
	self.reapply_sim = function(cb) {
		sim.read_identity(self, (id) => {
			let changed = (id.iccid != self.info.iccid || id.imsi != self.info.imsi);

			self.info.imsi = id.imsi ?? self.info.imsi;
			self.info.iccid = id.iccid ?? self.info.iccid;
			self.info.msisdn = id.msisdn ?? self.info.msisdn;

			self.active_sim = match_sim_override(id.iccid, id.imsi);

			log('notice', sprintf('sim reapply: iccid %s imsi %s%s',
				id.iccid ?? '?', id.imsi ?? '?',
				self.active_sim ? ' (matched a configured wwand_sim)' : ''));

			emit('sim_refresh', { iccid: self.info.iccid, imsi: self.info.imsi });

			let ctx = self.contexts[0];

			if (!ctx?.ensure_attach_profile || !self.dms)
				return cb ? cb(changed) : null;

			ctx.ensure_attach_profile(1, (ch) => {
				if (!ch)
					return cb ? cb(changed) : null;

				log('notice', 'attach profile changed after sim reapply, cycling radio to re-attach');
				qmi_backend.set_opmode(self.dms, 'low_power', () => {
					tm.settle = uloop.timer(self.timing.settle, () => {
						qmi_backend.set_opmode(self.dms, 'online', () => {
							if (cb)
								cb(changed);
						});
					});
				});
			});
		});
	};

	// register for SIM/eUICC refresh notifications so a network-/LPA-initiated
	// refresh (eSIM profile switch, SIM OTA update) makes wwand re-read identity.
	// On some modems (e.g. RG650E) UIM logical-channel ops are unsupported and the
	// register is refused — best-effort, no_recovery.
	self._install_uim_refresh = function() {
		if (!self.uim || self._uim_refresh_armed)
			return;
		self._uim_refresh_armed = true;

		self.uim.on('REFRESH_IND', (data) => {
			let stage = data?.event?.stage;
			log('info', sprintf('sim refresh (stage %d)', stage ?? -1));
			// full reapply only once the refresh completed successfully
			if (stage == uimmod.REFRESH_STAGE_END_SUCCESS)
				self.reapply_sim();
		});

		self.uim.request('REFRESH_REGISTER_ALL', {
			session:  { session_type: uimmod.SESSION_TYPE_PRIMARY_GW_PROVISIONING, aid: '' },
			register: { register_flag: 1 },
		}, (e) => {
			if (e)
				log('debug', 'uim refresh register failed (sim-refresh notifications unavailable)');
		}, { no_recovery: true });
	};

	// DMS event report: observe + log an EXTERNAL operating-mode / PIN change
	// (airplane toggled via AT / another tool / a hardware switch) wwand did not
	// initiate. The state machine still reacts via its own serving-system path.
	self._install_dms_handlers = function() {
		self.dms.on('EVENT_REPORT_IND', (data) => {
			if (data?.operating_mode != null && data.operating_mode != self._dms_opmode) {
				let prev = self._dms_opmode;
				self._dms_opmode = data.operating_mode;
				// skip the very first report (baseline, not a change)
				if (prev != null)
					log('notice', sprintf('operating mode changed externally: %s',
						dmsmod.OPMODE_NAMES[sprintf('%d', data.operating_mode)] ??
						sprintf('mode %d', data.operating_mode)));
			}
			if (data?.pin1_status?.current_status != null)
				self._dms_pin1 = data.pin1_status;
		});

		self.dms.request('SET_EVENT_REPORT',
			{ operating_mode: 1, pin_state: 1, uim_state: 1 }, (e) => {
				if (e)
					log('debug', 'dms set-event-report failed (external opmode watch unavailable)');
			}, { no_recovery: true });
	};

	self._install_nas_handlers = function() {
		self.nas.on('SERVING_SYSTEM_IND', (data) => self._update_serving(data));
		self.nas.on('SIGNAL_INFO_IND', (data) => {
			self.signal = data;
		});
		// Network Time / NITZ (operator-pushed UTC clock): store for status and
		// hand epoch+tz to the daemon, which decides whether to apply it (only
		// when the system clock is clearly unset). tz offset is signed 15-min units.
		self.nas.on('NETWORK_TIME_IND', (data) => {
			let epoch = modem_common.nitz_epoch(data?.universal_time);
			if (epoch == null)
				return;
			let tz_min = (data.timezone_offset != null) ? data.timezone_offset * 15 : null;
			self.network_time = { epoch: epoch, tz_offset_min: tz_min, dst: data.dst_adjustment };
			log('info', sprintf('network time (NITZ): %d utc, tz %s',
				epoch, tz_min != null ? sprintf('%+d min', tz_min) : '?'));
			if (deps.set_clock)
				deps.set_clock(epoch, tz_min);
		});
		// NAS event report — live RF band changes (band-steer / CA reshuffle)
		// pushed instead of waiting for the next cell poll. Stored on self.rf_bands.
		self.nas.on('EVENT_REPORT_IND', (data) => {
			if (data?.rf_band_info == null)
				return;
			let bands = map(data.rf_band_info, (b) => b.band);
			let key = join(',', bands);
			if (key != self._rf_band_key) {
				self._rf_band_key = key;
				// decode the QmiNasActiveBand values ("LTE B20" instead of 145)
				let names = join(', ', map(bands, nasmod.active_band_name));
				log('info', sprintf('rf band change: %s', length(names) ? names : 'none'));
			}
			self.rf_bands = map(data.rf_band_info, (b) =>
				({ ...b, name: nasmod.active_band_name(b.band) }));
		});
	};

	// enable the NAS event report (RF band + reject reason). Separate from
	// REGISTER_INDICATIONS; best-effort — some modems reject it.
	self._arm_nas_event_report = function() {
		if (!self.nas || self._nas_evt_armed)
			return;
		self._nas_evt_armed = true;
		self.nas.request('SET_EVENT_REPORT', { rf_band_info: 1, reject_reason: 1 }, (e) => {
			if (e)
				log('debug', 'nas set-event-report failed (rf-band push unavailable)');
		}, { no_recovery: true });
	};

	// registration-detail collector (regdetail.uc); kept as a method for
	// daemon/status callers.
	self.collect_regdetail = function(cb) {
		regdetail.collect(self, log, cb);
	};

	self._update_serving = function(data) {
		let ss = data.serving_system;

		if (!ss)
			return;

		if (data.current_plmn?.description != null)
			data.current_plmn.description = decode_operator_name(data.current_plmn.description);

		// an incremental SERVING_SYSTEM_IND (e.g. on cell reselection) may omit the
		// OPTIONAL Current-PLMN / roaming TLVs — carry the last-known values forward
		// instead of wiping them, so operator name + roaming don't blink out.
		let prev = self.reg ?? {};

		self.reg = {
			registration: ss.registration,
			radio_ifs: ss.radio_ifs,
			roaming: (data.roaming != null) ? (data.roaming == 0) : prev.roaming,
			plmn: data.current_plmn ?? prev.plmn,
		};

		emit('serving_system', self.reg);

		// serving-system update while connected: the network may have re-issued IP
		// config (prefix/DNS/MTU). Nudge contexts to re-check in place (they diff +
		// rate-limit; no-op if unchanged).
		if (ss.registration == nasmod.REG_REGISTERED && self.state == 'READY')
			notify_contexts('serving_change');

		if (ss.registration == nasmod.REG_REGISTERED) {
			if (self.state == 'REGISTERING') {
				if (tm.reg) {
					tm.reg.cancel();
					tm.reg = null;
				}

				self.counters.attempts = 0;
				self.reg_detail = null;   // registered: clear any stale reject info
				log('notice', sprintf('registered: plmn %J, roaming %J, radio [%s]',
					self.reg.plmn ? sprintf('%d/%02d (%s)', self.reg.plmn.mcc, self.reg.plmn.mnc,
						trim(self.reg.plmn.description ?? '')) : null,
					self.reg.roaming, join(' ', self.reg.radio_ifs ?? [])));
				self.set_state('READY');
				emit('registered', self.reg);
				notify_contexts('ready');
				self._start_loc();
				self._start_telemetry();
			}
		}
		else if (self.state == 'READY') {
			log('warn', sprintf('registration lost (%d)', ss.registration));
			emit('deregistered', self.reg);
			notify_contexts('suspend', self.reg);
			chain.register();
		}
	};

	// start the LOC positioning session once (best-effort)
	self._start_loc = function() {
		if (self.loc || !self.config.location)
			return;

		// lazy-load the LOC schema only now (GPS enabled) — see the top-of-file note
		let locmod = require('wwand.codec.schema.loc_lazy').s;

		if (!self.services[sprintf('%d', locmod.default.service)]) {
			log('info', 'location requested but loc service unavailable');
			return;
		}

		self.alloc(locmod.default, (err, loc) => {
			if (err) {
				log('warn', sprintf('loc allocation failed: %J', err));
				return;
			}

			self.loc = loc;

			loc.on('POSITION_REPORT_IND', (data) => {
				if (data.status != locmod.SESSION_STATUS_SUCCESS &&
				    data.status != locmod.SESSION_STATUS_IN_PROGRESS)
					return;

				if (data.latitude == null)
					return;

				self.location = {
					latitude: data.latitude,
					longitude: data.longitude,
					altitude: data.altitude,
					speed: data.h_speed,
					heading: data.heading,
					uncertainty: data.h_uncertainty,
					hdop: data.dop?.hdop,
					technology: data.technology,
					utc_ms: data.utc_ms,
				};

				emit('location', self.location);
			});

			loc.request('REGISTER_EVENTS', { mask: locmod.EVENT_POSITION_REPORT }, (e2) => {
				if (e2)
					return log('warn', sprintf('loc register events failed: %J', e2));

				loc.request('START', {
					session_id: 1,
					intermediate_reports: 1,
					min_interval_ms: 1000,
				}, (e3) => {
					if (e3)
						log('warn', sprintf('loc start failed: %J', e3));
					else
						log('notice', 'location session started');
				});
			});
		});
	};

	// telemetry subsystem (fast watch loop, CA, data-mode, slow log tick) —
	// telemetry_qmi.uc attaches watch/_start_telemetry/… methods
	let telem = telemetry_qmi.install(self, { log: log, emit: emit });

	// --- lifecycle ---------------------------------------------------------

	self.start = function() {
		if (self.hub)
			return;

		self.hub = transport_open(self.device, {
			on_gone: () => self._device_gone(),
			on_unhandled: (hub, dec) => {
				if (dec.msg_id != null)
					log('debug', sprintf('unhandled message svc %d cid %d msg 0x%04x %s',
						dec.service, dec.cid, dec.msg_id, dec.kind));
			},
		});

		if (!self.hub)
			return fail('open', { error: 'open', device: self.device });

		self.ctl = client_mod.create(self.hub, ctlmod.default, 0, client_hooks);

		let begin = chain.begin;

		// old 'delay' option: wait before touching the modem
		if (+(self.config.delay ?? 0) > 0)
			tm.settle = uloop.timer(+self.config.delay * 1000, begin);
		else
			begin();
	};

	self.teardown = function() {
		for (let t in values(tm))
			if (t)
				t.cancel();

		tm.retry = tm.reg = tm.settle = tm.at_drain = null;
		telem.stop();

		modem_common.close_at(self);

		for (let c in [ self.ctl, self.dms, self.nas, self.uim, self.wda, self.loc, self.wds_cfg, self.dsd ])
			if (c)
				c.destroy();

		self.ctl = self.dms = self.nas = self.uim = self.wda = self.loc = self.wds_cfg = self.dsd = null;

		if (self.hub) {
			self.hub.close();
			self.hub = null;
		}
	};

	// stop() + _device_gone() installed by modem_common.scaffolding

	return self;
};
