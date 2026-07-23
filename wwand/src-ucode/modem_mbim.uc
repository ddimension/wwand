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
import * as mbimmod from './codec/mbim.uc';
import * as recovery_mod from './recovery.uc';
import * as atcmd from './atcmd.uc';
import * as protoswitch from './protocol_switch.uc';
import * as netlink from './netlink.uc';
import * as bc from './codec/mbim-schema/basic_connect.uc';

const TIMING_DEFAULTS = {
	settle: 2000,
	reg_timeout: 240000,
	backoff_min: 5000,
	backoff_max: 30000,
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
		info: {},
		reg: {},
		signal: {},
		cells: null,
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

	let hooks = {
		on_error: (c, kind) => {
			if (rec.on_proto_error() == 'reboot')
				rec.reboot('mbim error limit reached');
		},
		on_success: (c) => rec.on_proto_success(),
	};

	self.attach_context = function(ctx) {
		push(self.contexts, ctx);

		if (self.state == 'READY')
			ctx.modem_event('ready');
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

	self.note_connect_success = function() {
		rec.on_connect_success();
	};

	self.trip_zero_rx = function() {
		rec.usb_repower();
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

	// AT side channel: best-effort, only for quirks and protocol switching
	step_at = () => {
		if (self.at)
			return step_datapath();

		let fxi = at_opts.fx ?? netlink.default_fx((l, m) => log(l, m));
		let tty = atcmd.find_tty(fxi, self.device, self.config.tty);

		if (!tty)
			return step_datapath();

		let open_transport = at_opts.open_transport ?? atcmd.open_transport;
		let tr = open_transport(tty, 115200, (l, m) => log(l, m));

		if (!tr)
			return step_datapath();

		self.at = atcmd.create(tr, { log: (l, m) => log(l, sprintf('at: %s', m)) });
		self.at_tty = tty;
		log('notice', sprintf('AT port: %s', tty));

		let cmds = [ ...(self.config.at_init ?? []), ...atcmd.cell_lock_commands(self.config) ];

		if (!length(cmds))
			return step_datapath();

		self.at.run_sequence(cmds, step_datapath);
	};

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
		self.mbim.on(bc, 'SIGNAL_STATE', (data) => { self.signal = { rssi: data.rssi }; });
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

	// --- telemetry (signal query; MBIM has no rich cell info in basic svc) --

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

			self.mbim.command(bc, 'SIGNAL_STATE', 'query', {}, (err, data) => {
				if (!err) {
					// MBIM RSSI: 0..31 -> -113..-51 dBm, 99 = unknown
					let dbm = (data.rssi != null && data.rssi != 99)
						? (-113 + 2 * data.rssi) : null;

					self.signal = { rssi_raw: data.rssi, rssi: dbm };
					log('notice', sprintf('telemetry: plmn=%s roaming=%s rssi=%s dBm class=0x%x',
						self.reg.plmn?.description ?? '?', self.reg.roaming ? 'yes' : 'no',
						dbm ?? '?', self.reg.data_class ?? 0));
					emit('telemetry', { signal: self.signal, reg: self.reg });
				}

				if (self.mbim)
					telemetry_timer = uloop.timer(interval, tick);
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

		if (self.at) {
			self.at.close();
			self.at = null;
			self.at_tty = null;
		}

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
