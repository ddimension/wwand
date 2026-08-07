// wwand — per-modem state machine.
//
// States:
//   ABSENT -> INIT_TRANSPORT -> INIT_SERVICES -> SET_OPMODE -> SIM_UNLOCK
//     -> CONFIGURE_NET -> REGISTERING -> READY
//   SIM_BLOCKED  terminal until config reload (PIN guard tripped)
//   Any failure schedules a backoff retry; device removal -> ABSENT.
//
// INIT_DATAPATH (WDA data format / mux link setup) is inserted before
// SET_OPMODE with milestone M4; the hook is already in the step chain.
//
// opts = {
//   id, device,                    // name + /dev/cdc-wdmX
//   config: { pincode, modes, mcc, mnc, delay },
//   deps: {
//     transport_open,              // (device, cbs) => hub   [test injection]
//     log,                         // (level, msg)
//     on_event,                    // (modem, event, data)
//   },
//   timing: { ... }                // ms overrides, see TIMING_DEFAULTS
// }

'use strict';

import * as uloop from 'uloop';
import * as fs from 'fs';
import * as transport_mod from './transport.uc';
import * as client_mod from './client.uc';
import * as sim from './sim.uc';
import * as netlink from './netlink.uc';
import * as recovery_mod from './recovery.uc';
import * as atcmd from './atcmd.uc';
import * as modem_quirks from './modem_quirks.uc';
import * as backend from './backend.uc';
import * as qmi_backend from './qmi_backend.uc';
import * as modem_common from './modem_common.uc';
import * as regdetail from './regdetail.uc';
import * as telemetry_qmi from './telemetry_qmi.uc';
import * as config_check from './config_check.uc';
import * as datapath_qmi from './datapath_qmi.uc';
import * as protoswitch from './protocol_switch.uc';
import * as tlv from './codec/tlv.uc';
import * as ctlmod from './codec/schema/ctl.uc';
import * as dmsmod from './codec/schema/dms.uc';
import * as nasmod from './codec/schema/nas.uc';
import * as dsdmod from './codec/schema/dsd.uc';
import * as uimmod from './codec/schema/uim.uc';
import * as wdsmod from './codec/schema/wds.uc';
import * as wdamod from './codec/schema/wda.uc';
// loc.uc + wms.uc are lazy-loaded (require of a *_lazy shim) only when GPS /
// SMS is actually used, keeping those schemas off the heap on the common path.

const TIMING_DEFAULTS = {
	...modem_common.TIMING_BASE,   // settle/reg_timeout/backoff_min/backoff_max
	sync_retry: 1000,      // delay between CTL sync attempts
	sim_settle: 5000,      // settle after PIN verify without indication (old: sleep 5)
	card_poll: 1000,       // card-status re-poll while initializing
};

const SYNC_TRIES = 10;
const MODES_TRIES = 3;

// parse_modes moved to qmi_backend.uc (needed by config_check too);
// re-exported for existing consumers (daemon, tests)
export const parse_modes = qmi_backend.parse_modes;

// unpack GSM 7-bit packed septets (LSB-first) into bytes. For Latin operator
// names the default-alphabet septets map 1:1 to ASCII, so we emit them directly.
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
// Heuristic: all-ASCII -> use as-is; any high byte -> try GSM7 and keep the
// result only if it decodes to clean printable ASCII, else keep the original.
function decode_operator_name(s)
{
	if (s == null || s == '')
		return s;

	let hi = false;

	for (let i = 0; i < length(s); i++)
		if (ord(s, i) >= 0x80) { hi = true; break; }

	if (!hi)
		return trim(s);

	let u = gsm7_unpack(s);

	while (length(u) && (ord(u, length(u) - 1) == 0 || ord(u, length(u) - 1) == 0x0d))
		u = substr(u, 0, length(u) - 1);

	for (let i = 0; i < length(u); i++)
		if (ord(u, i) < 0x20 || ord(u, i) > 0x7e)
			return s;   // not clean -> keep the original raw string

	return u;
}

// derive the data-system mode from the QENG serving detail (Quectel AT): the
// NR line states NSA/SA directly. Fallback for modems without the DSD service.
// dsd_from_serving / dsd_from_radio moved to modem_common (shared with the MBIM
// data-mode resolver).

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

	let retry_timer = null, reg_timer = null, settle_timer = null;

	// protocol-neutral scaffolding (set_state / attach_context /
	// note_connect_success / trip_zero_rx on self; emit + notify_contexts here)
	let scaffold = modem_common.scaffolding(self, { deps: deps, log: log, rec: rec });
	let emit = scaffold.emit;
	let notify_contexts = scaffold.notify_contexts;

	// hooks shared by all clients: feed the recovery error counter; the
	// ceiling (25, preserved) escalates straight to reboot
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

	// backend-neutral NAS accessor (daemon settings / network-selection paths):
	// QMI exposes its live NAS client directly. cb(nas|null).
	self.with_nas = function(cb) {
		cb(self.nas ?? null);
	};

	// backend-neutral WMS (SMS) accessor: QMI exposes its live WMS client (native
	// or allocated over the passthrough). cb(wms|null).
	self.with_wms = function(cb) {
		cb(self.wms ?? null);
	};

	// lazily allocate the WMS (SMS) client on first use — the wms schema is
	// require()d here (via the *_lazy shim) rather than imported at the top, so it
	// stays off the heap until SMS is actually used. sms.uc's probe calls this.
	// `_wms_tried` gates the one-shot (ucode has no `undefined`; self.wms is null
	// until resolved, then null = unavailable or the client).
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
	let at_drain_timer = null;

	let step_sync, step_services, step_at, step_esim_quirk, step_apply_init_reset, step_datapath, step_opmode, step_simslot, step_sim, step_identity, step_confnet, step_validate, step_attach_profile, step_register;

	let fail = modem_common.make_fail(self, {
		log: log, timing: self.timing, emit: emit,
		set_retry_timer: (t) => retry_timer = t,
	});

	// record a failed connection cycle and run the resulting ladder action;
	// also called by the daemon when a context activation fails. QMI-side
	// rungs run against the live clients, so this happens before teardown.
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
				settle_timer = uloop.timer(self.timing.settle, () => {
					qmi_backend.set_opmode(self.dms, 'online', () => {
						settle_timer = uloop.timer(self.timing.settle, () => done(action));
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
	// `deferred` selection/band settings): DMS offline -> reset, the same
	// sequence the recovery ladder's modem_reset rung uses. The modem drops off
	// the bus and re-enumerates; discovery rebuilds this modem and the daemon
	// kicks every auto interface back up once it re-registers.
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

	// switch the control protocol (QMI <-> MBIM). On a successful change the
	// modem resets and re-enumerates; the caller lets this modem object die
	// and discovery rebuilds it under the new driver.
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

	step_sync = (tries) => {
		self.set_state('INIT_TRANSPORT');

		// deferred init resets: steps that change NV settings needing a modem
		// reset push a reason here; one reset is applied at the end of the AT
		// config phase instead of resetting mid-init several times
		self._init_resets = [];

		self.ctl.request('SYNC', {}, (err) => {
			if (err) {
				if (tries < SYNC_TRIES) {
					retry_timer = uloop.timer(self.timing.sync_retry,
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
							// clean LTE / 5G-NSA / 5G-SA data-system status. Absent
							// on older modems — non-fatal.
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

					// The WMS (SMS) client is NOT allocated here — it is lazily
					// brought up on the first SMS operation via _ensure_wms, so the
					// wms schema stays off the heap until SMS is actually used.
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

	self._read_info = function(next) {
		qmi_backend.read_info(self.dms, (info) => {
			for (let k, v in info)
				self.info[k] = v;

			// …/device is the USB *interface* dir (1-1:1.3); one level up is
			// the USB device (1-1) carrying the descriptor strings (two would
			// be the hub — "xHCI Host Controller")
			let base = '/sys/class/usbmisc/' + substr(self.device, 5) + '/device/..';
			let sf = (f) => trim(fs.readfile(base + '/' + f) ?? '');

			// USB identity for status/detail (vid:pid + product string)
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

			// stable-identity gate: halt before touching SIM/context if the
			// pinned IMEI does not match this physical modem.
			if (!modem_common.check_identity(self, { emit: emit, log: log }))
				return;

			next();
		});
	};

	// the DMS model was junk and the USB descriptor filled in (generic
	// "HUAWEI Mobile" style): ATI usually knows the real model — upgrade the
	// identity off the critical path once the AT channel is open.
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

	// AT side channel: best-effort, failures never block bring-up
	step_at = () => modem_common.open_at(self, {
		at_opts: at_opts,
		log: log,
		drain_interval: self.timing.at_drain,
		set_drain_timer: (t) => { at_drain_timer = t; },
		next: () => { _ati_info(); step_esim_quirk(); },
		// preserved: when AT is already open (defensive re-entry), skip straight
		// to the datapath rather than re-running the eSIM quirk
		reopen_next: step_datapath,
	});

	// eSIM host-access quirk: free the eUICC's ISD-R from the modem's internal
	// LPA so host-side ES10 APDUs (CCHO/CGLA) work. Disabling lpa_enable only
	// takes effect after a reset — but instead of resetting here, we just flag
	// the reset and let step_apply_init_reset do a single reset at the end of
	// the AT config phase. Reset happens ONLY when we changed the value (it is
	// NV, so at most once per modem). Network is unaffected (the active profile
	// keeps working with the LPA disabled).
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

	// apply a single reset if any AT-config step requested one (NV changes that
	// need a power cycle). The reset re-enumerates the modem; discovery re-inits
	// it and this time nothing needs changing, so no reset is requested and init
	// proceeds normally. Do NOT continue init here when resetting — this
	// instance is being torn down.
	step_apply_init_reset = () => {
		if (!length(self._init_resets ?? []))
			return step_datapath();

		log('notice', sprintf('applying deferred init reset (%s)',
			join('; ', self._init_resets)));

		// one batched reset for everything collected during init: AT when a
		// command port exists, otherwise the DMS offline->reset sequence. A
		// refused reset is only logged — the modem stays up on its old
		// settings and the next boot retries (nothing to recover here).
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

	// datapath bring-up — extracted to datapath_qmi.uc (audit round)
	step_datapath = () => datapath_qmi.setup(self, dp, { log: log, fail: fail }, step_opmode);

	step_opmode = () => {
		self.set_state('SET_OPMODE');
		qmi_backend.set_opmode(self.dms, 'online', (err) => {
			// (set_opmode already treats "no effect / already online" as success)
			if (err)
				return fail('opmode', err);

			// settle after mode change (old: sleep 2)
			settle_timer = uloop.timer(self.timing.settle, step_simslot);
		});
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
				settle_timer = uloop.timer(self.timing.sim_settle, step_sim);
			});
		});
	};

	// shared wwand_sim matcher (modem_common — parity across all backends)
	let match_sim_override = (iccid, imsi) =>
		modem_common.match_sim_override(self.config?.sims, iccid, imsi);

	// pick the per-SIM override (config wwand_sim) matching the active card BEFORE
	// unlock, so its pincode is used. The MF-level ICCID is readable on a locked
	// card, and the extra read only runs when overrides are actually configured.
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
				// identify the card before going terminal so the log says
				// *which* SIM tripped the PIN guard. EF-IMSI is PIN-protected
				// and may read as null on a locked card; the MF-level ICCID
				// is readable regardless.
				sim.read_identity(self, (id) => {
					self.info.imsi = id.imsi;
					self.info.iccid = id.iccid;
					self.info.msisdn = id.msisdn;

					log('err', sprintf('sim blocked: imsi %s, iccid %s',
						id.imsi ?? '?', id.iccid ?? '?'));

					self.set_state('SIM_BLOCKED', err);
					emit('sim_blocked', err);
					notify_contexts('sim_blocked', err);
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

			// late per-SIM match: the pre-unlock matcher only sees the ICCID
			// (readable on a locked card). Now that the IMSI is readable,
			// accept an explicit `option imsi` — or an IMSI mistakenly put in
			// the iccid field — so the carrier bundle (apn/auth/credentials)
			// still applies. Runs BEFORE step_attach_profile, so the LTE
			// attach APN honors the override too. PIN overrides still need
			// `option iccid` (the PIN was consumed before this point).
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

		let mask = parse_modes(self.config.modes);
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

					// AT fallback hook lands here with M6
					log('warn', sprintf('failed to set system selection: %J', err));
					emit('modes_failed', { err: err });
				} else if (self._init_resets && modem_quirks.for_model(self.info?.model).settings_deferred) {
					// boot rule: during init a modem reset is always allowed so
					// the values actually apply — but BATCHED: push a reason and
					// let step_apply_init_reset issue ONE reset at the end.
					push(self._init_resets, 'system selection preference');
				}

				step_validate();
			});
		};

		// idempotency guard: read the live preference first and drop whatever
		// already matches — the boot path must not bounce the radio for values
		// the modem NV already carries. The manual-PLMN target itself is not
		// readable here (the GET carries only the selection TYPE and the
		// registration is not up yet at CONFIGURE_NET), so a configured manual
		// selection is conservatively (re-)applied.
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

	// runtime config validation: after step_confnet has APPLIED the config-derived
	// NAS prefs, confirm the LIVE modem actually reflects config + per-model quirks
	// and record any mismatch in self.config_warnings (surfaced on ubus + logged).
	// Complements config.uc's static parse-time warnings. Non-fatal: a check that
	// cannot read simply skips, and init proceeds to the attach profile regardless.
	step_validate = () => self.validate_config(() => step_attach_profile());

	// live-config validation — extracted to config_check.uc (audit round);
	// kept as a method so the init chain and ubus revalidation are unchanged
	self.validate_config = function(cb) {
		config_check.validate(self, log, cb);
	};

	// program the LTE attach profile (CID1) from the primary context's config
	// BEFORE registration so the modem's autonomous attach uses the right APN +
	// IP family. If it changed, cycle the radio (low-power -> online) so an
	// attach already in flight with the stale profile re-runs. See context.uc
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
				settle_timer = uloop.timer(self.timing.settle, () => {
					qmi_backend.set_opmode(self.dms, 'online', () => {
						settle_timer = uloop.timer(self.timing.settle, step_register);
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

			// early probe: surface a reject cause / limited service within
			// seconds (into the log + status reg_detail) instead of only at the
			// full 240s registration timeout — an attach reject (e.g. #33) shows
			// up almost immediately once the modem camps
			uloop.timer(self.timing.regdetail_probe ?? 12000, () => {
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

			reg_timer = uloop.timer(self.timing.reg_timeout, () => {
				if (self.state != 'REGISTERING')
					return;

				// surface WHY we're still not registered before failing —
				// EMM reject cause / limited service (see reg #33 attach finding)
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

	// the card behind the modem changed in place (eSIM profile switch applied
	// via SIM hot-reset, or a UIM REFRESH): re-read identity, RE-RESOLVE the
	// per-SIM override (the old card's wwand_sim must not stick) and re-program
	// the LTE attach profile — the same work the INIT chain does, without
	// tearing the modem down. Contexts pick the corrected override up on their
	// next (re)dial via conn_cfg. cb(changed) optional.
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
					settle_timer = uloop.timer(self.timing.settle, () => {
						qmi_backend.set_opmode(self.dms, 'online', () => {
							if (cb)
								cb(changed);
						});
					});
				});
			});
		});
	};

	// UIM refresh: register for SIM/eUICC refresh notifications so a network- or
	// LPA-initiated refresh (eSIM profile switch, SIM OTA file update) makes wwand
	// re-read identity (ICCID/IMSI can change) rather than running stale. On some
	// modems (e.g. RG650E) UIM logical-channel ops are unsupported and the
	// register is refused — best-effort, no_recovery.
	self._install_uim_refresh = function() {
		if (!self.uim || self._uim_refresh_armed)
			return;
		self._uim_refresh_armed = true;

		self.uim.on('REFRESH_IND', (data) => {
			let stage = data?.event?.stage;
			log('info', sprintf('sim refresh (stage %d)', stage ?? -1));
			// the full reapply once the refresh has completed successfully
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

	// DMS event report: catch an EXTERNAL operating-mode or PIN change (airplane
	// mode toggled via AT / another tool / a hardware switch) that wwand did not
	// initiate. We only observe + log it here; the state machine still reacts to
	// the resulting serving-system / registration change through its own path.
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
		// Network Time / NITZ: the operator-pushed UTC clock. Store it for status
		// and hand the epoch + timezone to the daemon, which decides whether to
		// apply it (only when the system clock is clearly unset — an RTC-less
		// router booted before NTP). tz offset is signed 15-minute units.
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
		// pushed instead of waiting for the next cell poll. Stored on self.rf_bands
		// for status; a change in the active-band set is logged.
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

	// enable the NAS event report (RF band + reject reason). Separate from the
	// REGISTER_INDICATIONS toggles; best-effort — some modems reject it. Called
	// once the NAS handlers are installed and registration is armed.
	self._arm_nas_event_report = function() {
		if (!self.nas || self._nas_evt_armed)
			return;
		self._nas_evt_armed = true;
		self.nas.request('SET_EVENT_REPORT', { rf_band_info: 1, reject_reason: 1 }, (e) => {
			if (e)
				log('debug', 'nas set-event-report failed (rf-band push unavailable)');
		}, { no_recovery: true });
	};

	// registration-detail collector — extracted to regdetail.uc (audit round);
	// kept as a method so daemon/status callers are unchanged
	self.collect_regdetail = function(cb) {
		regdetail.collect(self, log, cb);
	};

	self._update_serving = function(data) {
		let ss = data.serving_system;

		if (!ss)
			return;

		if (data.current_plmn?.description != null)
			data.current_plmn.description = decode_operator_name(data.current_plmn.description);

		// An incremental SERVING_SYSTEM_IND (e.g. on a cell reselection) may omit
		// the OPTIONAL Current-PLMN / roaming TLVs. Carry the last-known values
		// forward instead of wiping them, so the operator name + roaming flag stay
		// in status/telemetry across a reselection rather than blinking out.
		let prev = self.reg ?? {};

		self.reg = {
			registration: ss.registration,
			radio_ifs: ss.radio_ifs,
			roaming: (data.roaming != null) ? (data.roaming == 0) : prev.roaming,
			plmn: data.current_plmn ?? prev.plmn,
		};

		emit('serving_system', self.reg);

		// serving-system update while already connected: the network may have
		// re-issued IP config (prefix/DNS/MTU). Nudge contexts to re-check
		// their settings in place (they diff + rate-limit; no-op if unchanged).
		if (ss.registration == nasmod.REG_REGISTERED && self.state == 'READY')
			notify_contexts('serving_change');

		if (ss.registration == nasmod.REG_REGISTERED) {
			if (self.state == 'REGISTERING') {
				if (reg_timer) {
					reg_timer.cancel();
					reg_timer = null;
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
			step_register();
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

	// telemetry subsystem (fast watch loop, CA, data-mode, slow log tick)
	// extracted to telemetry_qmi.uc — attaches watch/_start_telemetry/… methods
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

		let begin = () => step_sync(0);

		// old 'delay' option: wait before touching the modem
		if (+(self.config.delay ?? 0) > 0)
			settle_timer = uloop.timer(+self.config.delay * 1000, begin);
		else
			begin();
	};

	self.teardown = function() {
		for (let t in [ retry_timer, reg_timer, settle_timer, at_drain_timer ])
			if (t)
				t.cancel();

		retry_timer = reg_timer = settle_timer = at_drain_timer = null;
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
