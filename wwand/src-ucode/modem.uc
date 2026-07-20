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
import * as transport_mod from './transport.uc';
import * as client_mod from './client.uc';
import * as sim from './sim.uc';
import * as netlink from './netlink.uc';
import * as recovery_mod from './recovery.uc';
import * as atcmd from './atcmd.uc';
import * as protoswitch from './protocol_switch.uc';
import * as ctlmod from './codec/schema/ctl.uc';
import * as dmsmod from './codec/schema/dms.uc';
import * as nasmod from './codec/schema/nas.uc';
import * as uimmod from './codec/schema/uim.uc';
import * as wdsmod from './codec/schema/wds.uc';
import * as wdamod from './codec/schema/wda.uc';
import * as locmod from './codec/schema/loc.uc';

const TIMING_DEFAULTS = {
	sync_retry: 1000,      // delay between CTL sync attempts
	settle: 2000,          // settle after operating-mode changes (old: sleep 2)
	sim_settle: 5000,      // settle after PIN verify without indication (old: sleep 5)
	card_poll: 1000,       // card-status re-poll while initializing
	reg_timeout: 240000,   // registration guard (old: 240s loop)
	backoff_min: 5000,     // retry backoff after failures
	backoff_max: 30000,
};

const SYNC_TRIES = 10;
const MODES_TRIES = 3;

export function parse_modes(str)
{
	if (str == null || str == '')
		return null;

	if (str == 'all')
		return nasmod.MODE_ALL;

	let mask = 0;

	for (let m in split(str, /[, ]+/)) {
		if (m == '')
			continue;

		let bits = nasmod.MODE_BITS[m];

		if (bits == null)
			return null;   // unknown mode name: refuse to guess

		mask |= bits;
	}

	return mask || null;
}

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

		services: {},      // service id (string) -> { major, minor }
		info: {},          // model, revision, imei, ...
		reg: {},           // registration snapshot
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
		fx: opts.recovery?.fx ?? netlink.default_fx((level, msg) => log(level, msg)),
		state_dir: opts.recovery?.state_dir,
		reboot_delay: opts.recovery?.reboot_delay,
		log: (level, msg) => log(level, msg),
	});

	rec.load();
	self.counters = rec.counters;
	self.recovery = rec;
	self.log_fn = log;

	let retry_timer = null, reg_timer = null, settle_timer = null;

	let emit = (event, data) => {
		if (deps.on_event)
			deps.on_event(self, event, data);
	};

	let notify_contexts = (event, data) => {
		for (let ctx in self.contexts)
			ctx.modem_event(event, data);
	};

	self.set_state = function(state, data) {
		if (self.state == state)
			return;

		log('info', sprintf('state %s -> %s', self.state, state));
		self.state = state;
		emit('state', { state: state, ...(data ?? {}) });
	};

	// hooks shared by all clients: feed the recovery error counter; the
	// ceiling (25, preserved) escalates straight to reboot
	let client_hooks = {
		on_error: (client, kind) => {
			if (rec.on_qmi_error() == 'reboot')
				rec.reboot('qmi error limit reached');

			log('debug', sprintf('qmi error (%s), counter %d', kind, self.counters.qmi_errors));
		},
		on_success: (client) => {
			rec.on_qmi_success();
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

	self.attach_context = function(ctx) {
		push(self.contexts, ctx);

		if (self.state == 'READY')
			ctx.modem_event('ready');
	};

	// --- step chain --------------------------------------------------------

	let dp = opts.datapath ?? {};
	let at_opts = opts.at ?? {};
	let at_drain_timer = null;
	let telemetry_timer = null;
	let watch_decay_timer = null, fast_timer = null;
	let watch_active = false, fast_running = false;

	let step_sync, step_services, step_at, step_datapath, step_opmode, step_sim, step_identity, step_confnet, step_register;

	let fail = (stage, err) => {
		log('err', sprintf('failed in %s: %J', stage, err));

		self.note_connect_failure((action) => {
			emit('error', {
				stage: stage, err: err,
				attempts: self.counters.attempts, action: action,
			});

			self.teardown();

			if (action == 'reboot') {
				self.set_state('ABSENT');
				return;   // no retry, reboot is pending
			}

			let backoff = min(self.timing.backoff_min * self.counters.attempts,
			                  self.timing.backoff_max);

			self.set_state('ABSENT', { retry_in: backoff });
			retry_timer = uloop.timer(backoff, () => self.start());
		});
	};

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
			self.dms.request('SET_OPERATING_MODE', { mode: dmsmod.OPMODE_LOW_POWER }, () => {
				settle_timer = uloop.timer(self.timing.settle, () => {
					self.dms.request('SET_OPERATING_MODE', { mode: dmsmod.OPMODE_ONLINE }, () => {
						settle_timer = uloop.timer(self.timing.settle, () => done(action));
					});
				});
			});
			return;

		case 'modem_reset':
			if (!self.dms)
				return done(action);

			log('warn', 'recovery: resetting modem');
			self.dms.request('SET_OPERATING_MODE', { mode: dmsmod.OPMODE_OFFLINE }, () => {
				self.dms.request('SET_OPERATING_MODE', { mode: dmsmod.OPMODE_RESET }, () => done(action));
			});
			return;

		default:
			return done(action);
		}
	};

	self.note_connect_success = function() {
		rec.on_connect_success();
	};

	// zero-rx watchdog tripped on a context of this modem
	self.trip_zero_rx = function() {
		rec.usb_repower();
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
							self._read_info(step_at);
						});
					};

					if (self.services[sprintf('%d', uimmod.default.service)]) {
						self.alloc(uimmod.default, (e3, uim) => {
							if (e3) {
								log('warn', 'uim allocation failed, using dms fallback');
								self.uim = null;
							}
							else {
								self.uim = uim;
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
		self.dms.request('GET_MANUFACTURER', {}, (e0, d0) => {
			if (!e0)
				self.info.manufacturer = d0.manufacturer;

			self.dms.request('GET_MODEL', {}, (e1, d1) => {
				if (!e1)
					self.info.model = d1.model;

				self.dms.request('GET_REVISION', {}, (e2, d2) => {
					if (!e2)
						self.info.revision = d2.revision;

					self.dms.request('GET_IDS', {}, (e3, d3) => {
						if (!e3) {
							self.info.imei = d3.imei;
							self.info.meid = d3.meid;
						}

						self.dms.request('GET_CAPABILITIES', {}, (e4, d4) => {
							if (!e4 && d4.capabilities) {
								self.info.capabilities = d4.capabilities;
								log('info', sprintf('capabilities: max tx %d rx %d kbps, radio ifs [%s]',
									d4.capabilities.max_tx_rate, d4.capabilities.max_rx_rate,
									join(' ', d4.capabilities.radio_ifs ?? [])));
							}

							log('notice', sprintf('%s %s, revision %s, imei %s',
								self.info.manufacturer ?? '?', self.info.model,
								self.info.revision, self.info.imei));
							next();
						});
					});
				});
			});
		});
	};

	// AT side channel: best-effort, failures never block bring-up
	step_at = () => {
		if (self.at)
			return step_datapath();

		let fxi = at_opts.fx ?? netlink.default_fx((level, msg) => log(level, msg));
		let tty = atcmd.find_tty(fxi, self.device, self.config.tty);

		if (!tty) {
			log('info', 'no AT port found');
			return step_datapath();
		}

		let open_transport = at_opts.open_transport ?? atcmd.open_transport;
		let tr = open_transport(tty, 115200, (level, msg) => log(level, msg));

		if (!tr) {
			log('warn', sprintf('cannot open AT port %s', tty));
			return step_datapath();
		}

		self.at = atcmd.create(tr, { log: (level, msg) => log(level, sprintf('at: %s', msg)) });
		self.at_tty = tty;
		log('notice', sprintf('AT port: %s', tty));

		// model quirks + configured at_init list (old serial_init + at_init),
		// then cell locks
		let cmds = [
			...atcmd.model_init_commands(self.info.model),
			...(self.config.at_init ?? []),
			...atcmd.cell_lock_commands(self.config),
		];

		// M9200B: periodically drain stale serial output (old
		// empty_serial_buffers quirk, ran from the watchdog loop)
		if (index(self.info.revision ?? '', 'M9200B') >= 0) {
			let interval = self.timing.at_drain ?? 60000;
			let tick;

			tick = () => {
				self.at.drain();
				at_drain_timer = uloop.timer(interval, tick);
			};

			at_drain_timer = uloop.timer(interval, tick);
			log('notice', 'M9200B detected, enabling serial drain');
		}

		if (!length(cmds))
			return step_datapath();

		self.at.run_sequence(cmds, step_datapath);
	};

	step_datapath = () => {
		self.set_state('INIT_DATAPATH');

		let want_mux = length(dp.mux_links ?? []) > 0;

		if (!dp.netdev) {
			if (want_mux)
				return fail('datapath', { error: 'netdev_unknown' });

			log('info', 'netdev unknown, skipping datapath setup');
			return step_opmode();
		}

		// modems without WDA keep their default framing (old behavior:
		// "no wda support, skipping data format switch")
		if (!self.services[sprintf('%d', wdamod.default.service)]) {
			if (want_mux)
				return fail('datapath', { error: 'wda_unavailable_for_mux' });

			log('info', 'no wda service, skipping data format setup');
			return step_opmode();
		}

		self.alloc(wdamod.default, (err, wda) => {
			if (err)
				return fail('alloc_wda', err);

			self.wda = wda;

			let fxi = dp.fx ?? netlink.default_fx((level, msg) => log(level, msg));
			let backend = netlink.select_backend(fxi, dp.netdev, dp.mux ?? 'auto', want_mux);

			if (backend == null)
				return fail('datapath', { error: 'mux_backend_unavailable', mux: dp.mux });

			let dgram = netlink.board_dgram_size(fxi, dp.dgram_size, self.info.model);
			let negotiate;

			// rmnet supports MAPv5 checksum offload; try it first there and
			// renegotiate plain QMAP when the modem rejects it (some answer
			// a v5 request with aggregation fully disabled)
			negotiate = (dap, allow_fallback) => {
				let args = { qos: 0, llp: wdamod.LLP_RAW_IP };

				if (backend != 'none') {
					args.ul_protocol = dap;
					args.dl_protocol = dap;
					args.dl_max_datagrams = 32;
					args.dl_max_size = dgram;
				}

				if (dp.ep_id != null)
					args.endpoint = { type: wdamod.ENDPOINT_TYPE_HSUSB, iface: dp.ep_id };

				wda.request('SET_DATA_FORMAT', args, (werr, wdata) => {
					if (werr)
						return fail('wda_format', werr);

					log('info', sprintf('wda format negotiated: llp %d, ul/dl aggregation %d/%d, dl max %d x %d bytes (requested proto %d, %d bytes)',
						wdata.llp, wdata.ul_protocol ?? 0, wdata.dl_protocol ?? 0,
						wdata.dl_max_datagrams ?? 0, wdata.dl_max_size ?? 0, dap, dgram));

					let aggr_ok = (backend == 'none') ||
						((wdata.dl_protocol == wdamod.DAP_QMAP ||
						  wdata.dl_protocol == wdamod.DAP_QMAPV5) &&
						 (wdata.dl_max_size ?? 0) > 0);

					if (!aggr_ok && allow_fallback && dap != wdamod.DAP_QMAP) {
						log('notice', sprintf('modem rejected aggregation protocol %d, renegotiating plain qmap', dap));
						return negotiate(wdamod.DAP_QMAP, false);
					}

					if (!aggr_ok)
						return fail('wda_format', { error: 'aggregation_rejected', echo: wdata });

					let v5 = (wdata.dl_protocol == wdamod.DAP_QMAPV5);

					// the modem may clamp the aggregation size; follow it
					let r = netlink.setup(fxi, {
						netdev: dp.netdev,
						backend: backend,
						v5: v5,
						mux: map(dp.mux_links ?? [], (e) => ({
							id: e.id,
							name: e.name ?? sprintf('%sm%d', dp.netdev, e.id),
							mtu: e.mtu,
						})),
						dgram_size: (wdata.dl_max_size > 0) ? wdata.dl_max_size : dgram,
						mtu: dp.mtu,
					});

					if (!r.ok)
						return fail('datapath', r);

					self.datapath = {
						backend: backend,
						v5: v5,
						urb_size: r.urb_size,
						mux_devs: r.mux_devs,
						ep_id: dp.ep_id,
					};

					log('notice', sprintf('datapath: %s%s, urb %d, mux [%s]',
						backend, v5 ? '/qmapv5' : '', r.urb_size, join(' ', r.mux_devs)));
					step_opmode();
				});
			};

			negotiate((backend == 'rmnet') ? wdamod.DAP_QMAPV5 : wdamod.DAP_QMAP,
				backend == 'rmnet');
		});
	};

	step_opmode = () => {
		self.set_state('SET_OPMODE');
		self.dms.request('SET_OPERATING_MODE', { mode: dmsmod.OPMODE_ONLINE }, (err) => {
			// error 26 = "no effect": already online
			if (err && !(err.error == 'qmi' && err.code == 26))
				return fail('opmode', err);

			// settle after mode change (old: sleep 2)
			settle_timer = uloop.timer(self.timing.settle, step_sim);
		});
	};

	step_sim = () => {
		self.set_state('SIM_UNLOCK');
		sim.unlock(self, (err, status) => {
			if (err?.blocked) {
				self.set_state('SIM_BLOCKED', err);
				emit('sim_blocked', err);
				notify_contexts('sim_blocked', err);
				return; // terminal until reload
			}

			if (err)
				return fail('sim', err);

			log('notice', sprintf('sim: %s%s', status.status,
				(status.pin1_state != null)
					? sprintf(' (pin1 state %d, %d retries left)', status.pin1_state, status.pin1_retries)
					: ''));
			step_identity();
		});
	};

	// card identity, logged like the old proto handler did after unlock
	step_identity = () => {
		sim.read_identity(self, (id) => {
			self.info.imsi = id.imsi;
			self.info.iccid = id.iccid;
			self.info.msisdn = id.msisdn;

			log('notice', sprintf('imsi %s, iccid %s, msisdn %s',
				id.imsi ?? '?', id.iccid ?? '?', id.msisdn ?? '?'));
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
			return step_register();

		let args = {};

		if (mask != null) {
			args.mode_preference = mask;
			log('notice', sprintf('setting network modes "%s" (mask 0x%02x)', self.config.modes, mask));
		}

		if (sel) {
			args.network_selection = sel;
			log('notice', sprintf('setting manual PLMN %d/%02d', sel.mcc, sel.mnc));
		}

		let attempt;

		attempt = (tries) => {
			self.nas.request('SET_SYSTEM_SELECTION_PREFERENCE', args, (err) => {
				if (err) {
					if (tries < MODES_TRIES)
						return attempt(tries + 1);

					// AT fallback hook lands here with M6
					log('warn', sprintf('failed to set system selection: %J', err));
					emit('modes_failed', { err: err });
				}

				step_register();
			});
		};

		attempt(1);
	};

	step_register = () => {
		self.set_state('REGISTERING');

		self.nas.request('REGISTER_INDICATIONS', {
			serving_system_events: 1,
			signal_info: 1,
		}, (err) => {
			// some modems lack this; fall back to the initial query result
			if (err)
				log('warn', sprintf('register indications failed: %J', err));

			reg_timer = uloop.timer(self.timing.reg_timeout, () => {
				if (self.state == 'REGISTERING')
					fail('registration_timeout', { reg: self.reg });
			});

			self.nas.request('GET_SERVING_SYSTEM', {}, (e2, d2) => {
				if (!e2)
					self._update_serving(d2);
			});
		});
	};

	self._install_nas_handlers = function() {
		self.nas.on('SERVING_SYSTEM_IND', (data) => self._update_serving(data));
		self.nas.on('SIGNAL_INFO_IND', (data) => {
			self.signal = data;
		});
	};

	self._update_serving = function(data) {
		let ss = data.serving_system;

		if (!ss)
			return;

		self.reg = {
			registration: ss.registration,
			radio_ifs: ss.radio_ifs,
			roaming: (data.roaming != null) ? (data.roaming == 0) : null,
			plmn: data.current_plmn,
		};

		emit('serving_system', self.reg);

		if (ss.registration == nasmod.REG_REGISTERED) {
			if (self.state == 'REGISTERING') {
				if (reg_timer) {
					reg_timer.cancel();
					reg_timer = null;
				}

				self.counters.attempts = 0;
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

	// periodic telemetry: cell environment, signal, operator — the compact
	// per-interval log line replaces what the old proto handler logged during
	// setup, and the collected data feeds future lock automation
	// Fast "watch" mode: while a consumer (the LuCI status page) actively
	// polls modem_signal/modem_cells, refresh signal + cell info at most once
	// per second, non-overlapping so the cadence stretches automatically when
	// the modem is busy (load-adaptive). Reverts to the slow telemetry timer a
	// few seconds after polling stops. Signal also keeps arriving via the NAS
	// SIGNAL_INFO indication subscription between refreshes.
	const WATCH_MIN_INTERVAL = 1000;   // never faster than 1/s
	const WATCH_DECAY = 6000;          // stop after this long without a poll

	let fast_tick;   // forward-declared: it reschedules itself
	fast_tick = () => {
		fast_timer = null;

		if (!watch_active || self.state != 'READY' || !self.nas) {
			fast_running = false;
			return;
		}

		fast_running = true;

		// signal first, then cells; scheduling the next cycle only after both
		// complete keeps it non-overlapping (adaptive to modem load)
		self.nas.request('GET_SIGNAL_INFO', {}, (serr, sdata) => {
			if (!serr && sdata)
				self.signal = sdata;

			if (!self.nas) { fast_running = false; return; }

			self.nas.request('GET_CELL_LOCATION_INFO', {}, (cerr, cdata) => {
				if (!cerr && cdata) {
					self.cells = cdata;
					emit('telemetry', { cells: self.cells, signal: self.signal, reg: self.reg });
				}

				if (watch_active && self.nas)
					fast_timer = uloop.timer(WATCH_MIN_INTERVAL, fast_tick);
				else
					fast_running = false;
			});
		});
	};

	// called by the daemon whenever modem_signal / modem_cells is queried
	self.watch = function() {
		watch_active = true;

		if (watch_decay_timer)
			watch_decay_timer.cancel();

		watch_decay_timer = uloop.timer(WATCH_DECAY, () => {
			watch_active = false;
			watch_decay_timer = null;
		});

		// kick an immediate refresh so the first poll already returns fresh data
		if (!fast_running && self.state == 'READY' && self.nas)
			fast_tick();
	};

	self._start_telemetry = function() {
		if (telemetry_timer)
			return;

		let interval = +(self.config.stats_interval ?? 60) * 1000;

		if (interval <= 0)
			return;

		// first sample soon after registration (the old handler dumped the
		// cell neighbourhood right at connect time), then at the interval
		let first = min(interval, 5000);

		let tick;

		tick = () => {
			// modem may have been torn down while a request was in flight
			if (!self.nas)
				return;

			self.nas.request('GET_CELL_LOCATION_INFO', {}, (err, data) => {
				if (!err) {
					self.cells = data;
					self._log_telemetry();
				}
				else if (err.error != 'cancelled') {
					log('warn', sprintf('telemetry: cell location query failed: %J', err));
				}

				if (self.nas)
					telemetry_timer = uloop.timer(interval, tick);
			});
		};

		telemetry_timer = uloop.timer(first, tick);
	};

	self._log_telemetry = function() {
		let parts = [];
		let techs = [];

		for (let r in (self.reg.radio_ifs ?? [])) {
			if (r == nasmod.RADIO_IF_LTE) push(techs, 'LTE');
			else if (r == nasmod.RADIO_IF_5GNR) push(techs, 'NR5G');
			else if (r == nasmod.RADIO_IF_UMTS) push(techs, 'UMTS');
			else if (r == nasmod.RADIO_IF_GSM) push(techs, 'GSM');
			else push(techs, sprintf('rat%d', r));
		}

		push(parts, sprintf('tech=%s', length(techs) ? join('+', techs) : 'none'));

		if (self.reg.plmn)
			push(parts, sprintf('plmn=%d/%02d%s', self.reg.plmn.mcc, self.reg.plmn.mnc,
				self.reg.plmn.description ? sprintf(' (%s)', trim(self.reg.plmn.description)) : ''));

		if (self.reg.roaming != null)
			push(parts, sprintf('roaming=%s', self.reg.roaming ? 'yes' : 'no'));

		let lte = self.cells?.lte_intra;

		if (lte) {
			let serving = null;

			for (let c in (lte.cells ?? []))
				if (c.pci == lte.serving_cell_id)
					serving = c;

			push(parts, sprintf('lte=[plmn %s tac %d gci %d earfcn %d pci %d%s neigh %d]',
				lte.plmn, lte.tac, lte.global_cell_id, lte.earfcn, lte.serving_cell_id,
				serving ? sprintf(' rsrp %.1f rsrq %.1f', serving.rsrp / 10.0, serving.rsrq / 10.0) : '',
				length(lte.cells ?? [])));
		}

		let nr = self.cells?.nr5g_cell;

		if (nr)
			push(parts, sprintf('nr5g=[plmn %s tac %d pci %d arfcn %d rsrp %.1f rsrq %.1f snr %.1f]',
				nr.plmn, nr.tac, nr.pci, self.cells?.nr5g_arfcn ?? 0,
				nr.rsrp / 10.0, nr.rsrq / 10.0, nr.snr / 10.0));

		// -32768 is the QMI "not available" sentinel for i16 metrics;
		// filter per field (mixed valid/sentinel values do occur)
		let sig_part = (label, fields) => {
			let out = [];

			for (let name, spec in fields)
				if (spec[0] != null && spec[0] > -32768)
					push(out, sprintf('%s %s', name,
						spec[1] ? sprintf('%.1f', spec[0] / 10.0) : sprintf('%d', spec[0])));

			if (length(out))
				push(parts, sprintf('%s=[%s]', label, join(' ', out)));
		};

		if (self.signal?.lte)
			sig_part('sig_lte', {
				rssi: [ self.signal.lte.rssi, false ],
				rsrp: [ self.signal.lte.rsrp, false ],
				snr:  [ self.signal.lte.snr, true ],
			});

		if (self.signal?.nr5g)
			sig_part('sig_nr5g', {
				rsrp: [ self.signal.nr5g.rsrp, false ],
				snr:  [ self.signal.nr5g.snr, true ],
			});

		if (length(self.config.lock_4g ?? []))
			push(parts, sprintf('lock_4g=%s', join(',', self.config.lock_4g)));

		if (self.config.lock_5g)
			push(parts, sprintf('lock_5g=%s', self.config.lock_5g));

		log('notice', sprintf('telemetry: %s', join(' ', parts)));
		emit('telemetry', { cells: self.cells, signal: self.signal, reg: self.reg });
	};

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
		for (let t in [ retry_timer, reg_timer, settle_timer, at_drain_timer, telemetry_timer,
		                watch_decay_timer, fast_timer ])
			if (t)
				t.cancel();

		retry_timer = reg_timer = settle_timer = at_drain_timer = telemetry_timer = null;
		watch_decay_timer = fast_timer = null;
		watch_active = fast_running = false;

		if (self.at) {
			self.at.close();
			self.at = null;
			self.at_tty = null;
		}

		for (let c in [ self.ctl, self.dms, self.nas, self.uim, self.wda, self.loc, self.wds_cfg ])
			if (c)
				c.destroy();

		self.ctl = self.dms = self.nas = self.uim = self.wda = self.loc = self.wds_cfg = null;

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
