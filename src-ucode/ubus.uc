// wwand — ubus object registration. Maps the 'wwand' ubus object onto the
// daemon core. context_up uses a deferred reply: the request stays open
// until the context reports CONNECTED or fails.

'use strict';

export function publish(conn, daemon, log)
{
	let obj = conn.publish('wwand', {
		status: {
			args: { ubus_rpc_session: '' },
			call: (req) => daemon.status(),
		},

		modem_list: {
			args: { ubus_rpc_session: '' },
			call: (req) => daemon.status(),
		},

		modem_signal: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => daemon.modem_signal(req.args.modem),
		},

		modem_get_settings: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_get_settings(req.args.modem, (err, res) => {
					req.reply(err ? { ok: false, ...err } : { ok: true, ...res });
				});

				req.defer();
			},
		},

		modem_sim_slots: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_sim_slots(req.args.modem, (err, res) => {
					req.reply(err ? { ok: false, ...err } : { ok: true, ...res });
				});

				req.defer();
			},
		},

		modem_sim_switch_slot: {
			args: { modem: '', slot: 0, ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_sim_switch_slot(req.args.modem, req.args.slot, (err, res) => {
					req.reply(err ? { ok: false, ...err } : { ok: true, ...res });
				});

				req.defer();
			},
		},

		// enable/disable the SIM PIN query (PIN lock); needs the current PIN
		modem_sim_pin_lock: {
			args: { modem: '', pin: '', enable: false, ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_sim_pin_lock(req.args.modem, req.args.pin, req.args.enable, (err, res) => {
					req.reply(err ? { ok: false, ...err } : { ok: true, ...res });
				});

				req.defer();
			},
		},

		// eSIM management (optional wwand-esim package; reports
		// esim_not_installed when absent)
		modem_esim: {
			args: { modem: '', op: '', slot: 0, iccid: '',
			        activation_code: '', confirmation_code: '',
			        auto_notify: true, ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_esim(req.args.modem, req.args.op, req.args, (err, res) => {
					req.reply(err ? { ok: false, ...err } : { ok: true, ...(res ?? {}) });
				});

				req.defer();
			},
		},

		// raw APDU access (write ACL — security relevant)
		modem_apdu: {
			args: { modem: '', op: '', slot: 0, channel: 0, aid: '', apdu: '', ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_apdu(req.args.modem, req.args.op, req.args, (err, res) => {
					req.reply(err ? { ok: false, ...err } : { ok: true, ...res });
				});

				req.defer();
			},
		},

		modem_plmn_lists: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_plmn_lists(req.args.modem, (err, res) => {
					req.reply(err ? { ok: false, ...err } : { ok: true, ...res });
				});

				req.defer();
			},
		},

		modem_set_settings: {
			args: { modem: '', settings: {}, ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_set_settings(req.args.modem, req.args.settings, (err, res) => {
					req.reply(err ? { ok: false, ...err } : { ok: true, ...res });
				});

				req.defer();
			},
		},

		// scan visible operators (COPS=? equivalent); may be slow, so the reply
		// is deferred until the modem answers
		modem_scan: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_scan(req.args.modem, (err, res) => {
					req.reply(err ? { ok: false, ...err } : { ok: true, ...res });
				});

				req.defer();
			},
		},

		// network selection: mode 'auto' or 'manual' + mcc/mnc (write ACL)
		modem_set_network_selection: {
			args: { modem: '', mode: '', mcc: 0, mnc: 0, ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_set_network_selection(req.args.modem, req.args.mode,
					req.args.mcc, req.args.mnc, (err, res) => {
					req.reply(err ? { ok: false, ...err } : { ok: true, ...res });
				});

				req.defer();
			},
		},

		modem_cells: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => daemon.modem_cells(req.args.modem),
		},

		modem_location: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => daemon.modem_location(req.args.modem),
		},

		modem_at: {
			args: { modem: '', command: '', timeout: 0, ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_at(req.args.modem, req.args.command, (err, res) => {
					if (err)
						req.reply({ ok: false, ...err });
					else
						req.reply({ ok: true, response: res.lines });
				}, req.args.timeout > 0 ? req.args.timeout : null);

				req.defer();
			},
		},

		modem_set_protocol: {
			args: { modem: '', protocol: '', ubus_rpc_session: '' },
			call: (req) => {
				daemon.modem_set_protocol(req.args.modem, req.args.protocol, (err, res) => {
					if (err)
						req.reply({ ok: false, ...err });
					else
						req.reply({ ok: true, ...res });
				});

				req.defer();
			},
		},

		context_status: {
			args: { context: '', interface: '', ubus_rpc_session: '' },
			call: (req) => daemon.context_status(req.args.context ?? req.args.interface),
		},

		// read-only current IP settings (proto shim renew path); same shape as
		// context_up's reply but never (re)activates the context
		context_settings: {
			args: { context: '', interface: '', ubus_rpc_session: '' },
			call: (req) => daemon.context_settings(req.args.context ?? req.args.interface),
		},

		context_up: {
			args: { context: '', interface: '', ubus_rpc_session: '' },
			call: (req) => {
				let ref = req.args.context ?? req.args.interface;

				if (ref == null)
					return { up: false, error: 'missing_argument' };

				daemon.context_up(ref, (err, result) => {
					if (err)
						req.reply({ up: false, ...err });
					else
						req.reply(result);
				});

				req.defer();
			},
		},

		context_down: {
			args: { context: '', interface: '', ubus_rpc_session: '' },
			call: (req) => {
				let ref = req.args.context ?? req.args.interface;

				if (ref == null)
					return { error: 'missing_argument' };

				daemon.context_down(ref, (err) => {
					req.reply(err ? { ...err } : {});
				});

				req.defer();
			},
		},

		hotplug: {
			args: { action: '', device: '', ubus_rpc_session: '' },
			call: (req) => {
				daemon.hotplug(req.args.action, req.args.device);
				return {};
			},
		},

		reload: {
			args: { ubus_rpc_session: '' },
			call: (req) => {
				if (daemon.reload)
					daemon.reload();

				return {};
			},
		},

		// runtime debug switch: ubus call wwand set_log_level '{"level":"debug"}'
		// (reverted to the uci value on reload)
		set_log_level: {
			args: { level: '', ubus_rpc_session: '' },
			call: (req) => {
				if (!req.args.level)
					return { error: 'missing_argument' };

				if (!daemon.set_log_level || !daemon.set_log_level(req.args.level))
					return { error: 'invalid_level' };

				return { level: req.args.level };
			},
		},
	});

	if (!obj && log)
		log('err', 'failed to publish wwand ubus object');

	return obj;
}
