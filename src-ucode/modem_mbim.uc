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
import * as atcmd from './atcmd.uc';
import * as protoswitch from './protocol_switch.uc';
import * as netlink from './netlink.uc';
import * as bc from './codec/mbim-schema/basic_connect.uc';
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
import * as tlv from './codec/tlv.uc';

const TIMING_DEFAULTS = {
	settle: 2000,
	reg_timeout: 240000,
	backoff_min: 5000,
	backoff_max: 30000,
	at_drain: 60000,
};

// fast "watch" mode timing (mirrors modem.uc): while a consumer (the LuCI status
// page) polls modem_signal/modem_cells, refresh at most once a second and revert
// to the slow telemetry timer a few seconds after polling stops. The adaptive
// cadence itself lives in modem_common.watch_driver (shared with modem.uc).

// Null out the i16 signal metrics QMI reports as -32768 ("not available") on
// serving + neighbour cells (the passthrough cell path decodes the same NAS TLVs
// modem.uc does). Applied once at ingestion so LuCI renders "—". Mirrors
// modem.uc clean_cell_metrics.
function clean_cell_metrics(cells)
{
	let scrub = (c) => {
		for (let f in [ 'rsrp', 'rsrq', 'rssi', 'srxlev', 'snr' ])
			if (c[f] == tlv.SENTINEL.i16)
				c[f] = null;
	};

	for (let c in (cells?.lte_intra?.cells ?? []))
		scrub(c);

	for (let fr in (cells?.lte_inter?.freqs ?? []))
		for (let c in (fr.cells ?? []))
			scrub(c);

	if (cells?.nr5g_cell)
		scrub(cells.nr5g_cell);

	return cells;
}

// derive the data-system mode from the QENG serving detail (Quectel AT): the NR
// line states NSA/SA directly. Last-resort data_mode source. Mirrors modem.uc.
// dsd_from_serving moved to modem_common (shared with the QMI data-mode resolver).

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
		fx: opts.recovery?.fx ?? netlink.default_fx((l, m) => log(l, m)),
		state_dir: opts.recovery?.state_dir,
		reboot_delay: opts.recovery?.reboot_delay,
		log: (l, m) => log(l, m),
	});

	rec.load();
	self.counters = rec.counters;
	self.recovery = rec;

	let at_opts = opts.at ?? {};
	let retry_timer = null, reg_timer = null, settle_timer = null, at_drain_timer = null, telemetry_timer = null;
	let telem_watch;   // modem_common.watch_driver (adaptive fast telemetry loop)

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

	// convenience wrapper used by contexts
	self.command = function(name, kind, args, cb, o) {
		self.mbim.command(bc, name, kind, args, cb, o);
	};

	// --- step chain --------------------------------------------------------

	let step_open, step_caps, step_at, step_datapath, step_sim, step_register, step_attach;

	let fail = (stage, err) => {
		log('err', sprintf('failed in %s: %J', stage, err));

		let action = rec.on_attempt();

		if (action == 'reboot') {
			rec.reboot('connection attempt limit reached');
			self.teardown();
			self.set_state('ABSENT');
			return;
		}

		if (action == 'usb_repower')
			rec.usb_repower();

		self.teardown();

		let backoff = min(self.timing.backoff_min * self.counters.attempts, self.timing.backoff_max);

		self.set_state('ABSENT', { retry_in: backoff });
		retry_timer = uloop.timer(backoff, () => self.start());
	};

	self.note_connect_failure = function(done) {
		done = done ?? ((a) => null);
		let action = rec.on_attempt();

		if (action == 'reboot')
			rec.reboot('connection attempt limit reached');
		else if (action == 'usb_repower')
			rec.usb_repower();

		done(action);
	};


	step_open = () => {
		self.set_state('INIT_TRANSPORT');
		self.mbim = mbim_client.create(self.hub, hooks);

		self.mbim.open((err) => {
			if (err)
				return fail('open', err);

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

		let pincode = self.config.pincode;

		self.mbim.command(bc, 'PIN', 'query', {}, (err, data) => {
			if (err)
				return fail('pin_query', err);

			if (data.pin_state == bc.PIN_STATE_UNLOCKED)
				return step_register();

			if (!pincode) {
				self.set_state('SIM_BLOCKED', { reason: 'pin_required_no_pin' });
				emit('sim_blocked', { reason: 'pin_required_no_pin' });
				notify_contexts('sim_blocked', {});
				return;
			}

			if (data.remaining_attempts != null && data.remaining_attempts < 2) {
				self.set_state('SIM_BLOCKED', { reason: 'retries_exhausted' });
				emit('sim_blocked', { reason: 'retries_exhausted' });
				notify_contexts('sim_blocked', {});
				return;
			}

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

			// allocate a CID and wrap a client for `schema` over the shim
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

	// signal: prefer the QMI passthrough (GET_SIGNAL_INFO — reuses the battle-
	// tested QMI decode), then native MBIMEx v2 Signal State as a fallback for
	// modems without the passthrough. (The native MS-ext buffer decode is not yet
	// validated against real-HW buffers — on the EG06 it returned only rssi with
	// null rsrp/rsrq/snr and misaligned cells, while the passthrough is correct.)
	// Stores self.signal (QMI GET_SIGNAL_INFO shape).
	self._refresh_signal = function(cb) {
		cb = cb ?? (() => null);

		backend.choose(self, '_sig_be', [
			{ name: 'qmi', probe: (ok) => self._ensure_pt((up) => up
				? self.pt.nas.request('GET_SIGNAL_INFO', {},
					(e, d) => ok(!e && tlv.has_payload(d)), { no_recovery: true })
				: ok(false)) },
			{ name: 'mbim', probe: (ok) => self.mbim
				? mbim_backend.get_signal(self.mbim, (s) => ok(s != null))
				: ok(false) },
		], (be) => {
			if (be == 'mbim')
				return mbim_backend.get_signal(self.mbim, (s) => { if (s) self.signal = s; cb(); });

			if (be == 'qmi')
				return self.pt.nas.request('GET_SIGNAL_INFO', {}, (e, d) => {
					if (!e && tlv.has_payload(d))
						self.signal = d;
					cb();
				}, { no_recovery: true });

			cb();
		});
	};

	// cells: native Base Stations Info, else passthrough NAS cell-location info
	// (decoded + scrubbed exactly as modem.uc), else a best-effort AT QENG
	// serving cell. Stores self.cells, preserving any carrier-aggregation set.
	self._refresh_cells = function(cb) {
		cb = cb ?? (() => null);

		let ca = self.cells?.ca;
		let store = (c) => {
			if (c) {
				if (ca != null)
					c.ca = ca;
				self.cells = c;
			}
			cb();
		};

		backend.choose(self, '_cells_be', [
			{ name: 'qmi', probe: (ok) => self._ensure_pt((up) => up
				? self.pt.nas.request('GET_CELL_LOCATION_INFO', {},
					(e, d) => ok(!e && tlv.has_payload(d)), { no_recovery: true })
				: ok(false)) },
			{ name: 'mbim', probe: (ok) => self.mbim
				? mbim_backend.get_cells(self.mbim, (c) => ok(c != null))
				: ok(false) },
			{ name: 'at', probe: (ok) => ok(!!self.at) },
		], (be) => {
			if (be == 'mbim')
				return mbim_backend.get_cells(self.mbim, (c) => store(c));

			if (be == 'qmi')
				return self.pt.nas.request('GET_CELL_LOCATION_INFO', {}, (e, d) =>
					store((!e && tlv.has_payload(d)) ? clean_cell_metrics(d) : null),
					{ no_recovery: true });

			if (be == 'at')
				return modem_common.telemetry_at(self).send('AT+QENG="servingcell"', (e, r) => {
					let serving = e ? null : atcmd.parse_qeng_servingcell(r?.lines);
					store(serving ? { serving: serving } : null);
				});

			cb();
		});
	};

	// carrier aggregation: passthrough NAS GET_LTE_CPHY_CA_INFO, else AT+QCAINFO
	// (no native MBIM CA CID). Stores self.cells.ca. Mirrors modem.uc _fetch_ca_info.
	self._refresh_ca = function(cb) {
		cb = cb ?? (() => null);

		if (!self.cells)   // nowhere to hang CA yet
			return cb();

		let store = (ca) => { if (self.cells) self.cells.ca = ca ?? []; cb(); };

		backend.choose(self, '_ca_be', [
			{ name: 'qmi', probe: (ok) => self._ensure_pt((up) => up
				? qmi_backend.get_ca(self.pt.nas, (ca) => ok(ca != null))
				: ok(false)) },
			{ name: 'at', probe: (ok) => ok(!!self.at) },
		], (be) => {
			if (be == 'qmi')
				return qmi_backend.get_ca(self.pt.nas, (ca) => store(ca ?? []));

			if (be == 'at')
				return modem_common.telemetry_at(self).send('AT+QCAINFO', (e, r) =>
					store(e ? [] : atcmd.parse_qcainfo(r?.lines)));

			store([]);
		});
	};

	// data-system mode (LTE/NSA/SA): native register-state class mask, else
	// passthrough DSD, else the AT QENG serving detail. Stores self.dsd_status.
	self._refresh_data_mode = function(cb) {
		cb = cb ?? (() => null);

		backend.choose(self, '_dsd_be', [
			{ name: 'qmi', probe: (ok) => self._ensure_pt((up) => (up && self.pt.dsd)
				? qmi_backend.get_data_mode(self.pt.dsd, (m) => ok(m != null))
				: ok(false)) },
			{ name: 'mbim', probe: (ok) => self.mbim
				? mbim_backend.get_data_mode(self.mbim, (m) => ok(m != null))
				: ok(false) },
			{ name: 'at', probe: (ok) => ok(self.cells?.serving?.lte != null ||
			                                self.cells?.serving?.nr != null) },
		], (be) => {
			let tag = (s) => { if (s) s.source = be; return s; };

			if (be == 'mbim')
				return mbim_backend.get_data_mode(self.mbim, (m) => { self.dsd_status = tag(m); cb(); });

			if (be == 'qmi')
				return qmi_backend.get_data_mode(self.pt.dsd, (m) => { self.dsd_status = tag(m); cb(); });

			if (be == 'at')
				self.dsd_status = tag(modem_common.dsd_from_serving(self.cells?.serving));

			cb();
		});
	};

	// registration detail (reject cause / limited service): native register
	// state, else passthrough NAS system-info. Stores self.reg_detail.
	self._refresh_reg_detail = function(cb) {
		cb = cb ?? (() => null);

		backend.choose(self, '_regd_be', [
			{ name: 'qmi', probe: (ok) => self._ensure_pt((up) => up
				? qmi_backend.get_reg_detail(self.pt.nas, (d) => ok(d != null))
				: ok(false)) },
			{ name: 'mbim', probe: (ok) => self.mbim
				? mbim_backend.get_reg_detail(self.mbim, (d) => ok(d != null))
				: ok(false) },
		], (be) => {
			if (be == 'mbim')
				return mbim_backend.get_reg_detail(self.mbim, (d) => { if (d) self.reg_detail = d; cb(); });

			if (be == 'qmi')
				return qmi_backend.get_reg_detail(self.pt.nas, (d) => { if (d) self.reg_detail = d; cb(); });

			cb();
		});
	};

	let emit_telemetry = () => emit('telemetry', { signal: self.signal, cells: self.cells, reg: self.reg });

	let log_telemetry = () => {
		log('notice', sprintf('telemetry: plmn=%s roaming=%s rssi=%s dBm mode=%s cells=%s',
			self.reg.plmn?.description ?? '?', self.reg.roaming ? 'yes' : 'no',
			(self.signal?.lte?.rssi ?? self.signal?.rssi) ?? '?',
			self.dsd_status?.mode ?? '?', self.cells ? 'yes' : 'no'));
	};

	// Fast "watch" loop: while a consumer polls modem_signal/modem_cells, refresh
	// the LuCI-visible data (signal + cells + CA) at most once a second,
	// non-overlapping so the cadence stretches when the modem is busy. Reverts to
	// the slow telemetry timer after polling stops. The adaptive cadence lives in
	// modem_common.watch_driver (shared with modem.uc); this is just the MBIM
	// refresh body. done() is called exactly once per cycle (finish or bail).
	let refresh_fast = (done) => {
		self._refresh_signal(() => {
			if (!self.mbim)
				return done();

			self._refresh_cells(() => self._refresh_ca(() => {
				emit_telemetry();
				done();
			}));
		});
	};

	telem_watch = modem_common.watch_driver({
		alive:   () => self.mbim != null,
		ready:   () => self.state == 'READY',
		refresh: refresh_fast,
	});

	// called by the daemon whenever modem_signal / modem_cells is queried
	self.watch = () => telem_watch.watch();

	// Slow telemetry loop (the stats interval): the baseline v1 SIGNAL_STATE
	// query (kept working for modems without V2 / passthrough) plus the richer
	// signal, data-system mode and registration detail. Cells stay on the fast
	// loop / the fast-loop-primed cell set.
	self._start_telemetry = function() {
		if (telemetry_timer)
			return;

		let interval = +(self.config.stats_interval ?? 60) * 1000;

		if (interval <= 0)
			return;

		let tick;

		tick = () => {
			if (!self.mbim)
				return;

			// v1 RSSI floor first, then let the rich per-RAT refresh overwrite it
			self.mbim.command(bc, 'SIGNAL_STATE', 'query', {}, (err, data) => {
				if (!err && !self.signal?.lte && !self.signal?.nr5g) {
					let dbm = (data.rssi != null && data.rssi != 99)
						? (-113 + 2 * data.rssi) : null;
					self.signal = { rssi_raw: data.rssi, rssi: dbm };
				}

				self._refresh_signal(() => self._refresh_data_mode(() => self._refresh_reg_detail(() => {
					if (!self.mbim)
						return;

					log_telemetry();
					emit_telemetry();
					telemetry_timer = uloop.timer(interval, tick);
				})));
			});
		};

		telemetry_timer = uloop.timer(min(interval, 5000), tick);
	};

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
		for (let t in [ retry_timer, reg_timer, settle_timer, at_drain_timer, telemetry_timer ])
			if (t)
				t.cancel();

		retry_timer = reg_timer = settle_timer = at_drain_timer = telemetry_timer = null;
		telem_watch.stop();

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

		self._pt_failed = false;
		backend.reset(self, '_sig_be', '_cells_be', '_ca_be', '_dsd_be', '_regd_be');

		if (self.mbim) {
			self.mbim.destroy();
			self.mbim = null;
		}

		if (self.hub) {
			self.hub.close();
			self.hub = null;
		}
	};

	self._device_gone = function() {
		log('warn', 'device disappeared');
		notify_contexts('lost');
		self.teardown();
		self.set_state('ABSENT');
		emit('removed', {});
	};

	self.stop = function() {
		self.teardown();
		self.set_state('ABSENT');
	};

	return self;
}
