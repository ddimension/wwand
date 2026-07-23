// wwand — ubus object registration. Maps the 'wwand' ubus object onto the
// daemon core. context_up uses a deferred reply: the request stays open
// until the context reports CONNECTED or fails.

'use strict';

import * as uloop from 'uloop';

// Backstop watchdog for a deferred reply. All deferred methods route through a
// daemon op whose own client/AT timeouts guarantee a callback — but a dropped
// callback (a bug on some future path) would otherwise leave the ubus request
// open forever. This far exceeds any legitimate op (a network scan can run a few
// minutes), so it never false-fires; it only frees a genuinely wedged request.
const REPLY_WATCHDOG_MS = 300000;

// defer(req, run, watchdog_ms?): run(reply) starts the backend op and must call
// reply(obj) once with the final response object. Guarantees the request
// completes exactly once: a late/second callback after completion is ignored,
// and the watchdog replies with a timeout error if the backend never calls back.
// Preserves each method's own reply shape (run builds the object). Exported for
// unit testing.
export function defer(req, run, watchdog_ms)
{
	let settled = false;

	let timer = uloop.timer(watchdog_ms ?? REPLY_WATCHDOG_MS, () => {
		if (settled)
			return;

		settled = true;
		req.reply({ ok: false, error: 'timeout', detail: 'wwand backend did not respond' });
	});

	let reply = (obj) => {
		if (settled)
			return;

		settled = true;
		timer.cancel();
		req.reply(obj);
	};

	run(reply);
	req.defer();
}

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
			call: (req) => defer(req, (reply) =>
				daemon.modem_get_settings(req.args.modem, (err, res) =>
					reply(err ? { ok: false, ...err } : { ok: true, ...res }))),
		},

		modem_sim_slots: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_sim_slots(req.args.modem, (err, res) =>
					reply(err ? { ok: false, ...err } : { ok: true, ...res }))),
		},

		modem_sim_switch_slot: {
			args: { modem: '', slot: 0, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_sim_switch_slot(req.args.modem, req.args.slot, (err, res) =>
					reply(err ? { ok: false, ...err } : { ok: true, ...res }))),
		},

		// enable/disable the SIM PIN query (PIN lock); needs the current PIN
		modem_sim_pin_lock: {
			args: { modem: '', pin: '', enable: false, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_sim_pin_lock(req.args.modem, req.args.pin, req.args.enable, (err, res) =>
					reply(err ? { ok: false, ...err } : { ok: true, ...res }))),
		},

		// eSIM management (optional wwand-esim package; reports
		// esim_not_installed when absent)
		modem_esim: {
			args: { modem: '', op: '', slot: 0, iccid: '',
			        activation_code: '', confirmation_code: '',
			        auto_notify: true, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_esim(req.args.modem, req.args.op, req.args, (err, res) =>
					reply(err ? { ok: false, ...err } : { ok: true, ...(res ?? {}) }))),
		},

		// raw APDU access (write ACL — security relevant)
		modem_apdu: {
			args: { modem: '', op: '', slot: 0, channel: 0, aid: '', apdu: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_apdu(req.args.modem, req.args.op, req.args, (err, res) =>
					reply(err ? { ok: false, ...err } : { ok: true, ...res }))),
		},

		modem_plmn_lists: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_plmn_lists(req.args.modem, (err, res) =>
					reply(err ? { ok: false, ...err } : { ok: true, ...res }))),
		},

		modem_set_settings: {
			args: { modem: '', settings: {}, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_set_settings(req.args.modem, req.args.settings, (err, res) =>
					reply(err ? { ok: false, ...err } : { ok: true, ...res }))),
		},

		// scan visible operators (COPS=? equivalent); may be slow, so the reply
		// is deferred until the modem answers
		modem_scan: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_scan(req.args.modem, (err, res) =>
					reply(err ? { ok: false, ...err } : { ok: true, ...res }))),
		},

		// network selection: mode 'auto' or 'manual' + mcc/mnc (write ACL)
		modem_set_network_selection: {
			args: { modem: '', mode: '', mcc: 0, mnc: 0, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_set_network_selection(req.args.modem, req.args.mode,
					req.args.mcc, req.args.mnc, (err, res) =>
					reply(err ? { ok: false, ...err } : { ok: true, ...res }))),
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
				// the watchdog must outlast the (user-supplied) AT timeout so it
				// only ever catches a genuinely dropped callback, never a slow but
				// working command.
				let at_to = req.args.timeout > 0 ? req.args.timeout : null;
				let wd = at_to ? (at_to + 30000) : null;

				defer(req, (reply) =>
					daemon.modem_at(req.args.modem, req.args.command, (err, res) =>
						reply(err ? { ok: false, ...err } : { ok: true, response: res.lines }),
					at_to), wd);
			},
		},

		modem_set_protocol: {
			args: { modem: '', protocol: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_set_protocol(req.args.modem, req.args.protocol, (err, res) =>
					reply(err ? { ok: false, ...err } : { ok: true, ...res }))),
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

				defer(req, (reply) =>
					daemon.context_up(ref, (err, result) =>
						reply(err ? { up: false, ...err } : result)));
			},
		},

		context_down: {
			args: { context: '', interface: '', ubus_rpc_session: '' },
			call: (req) => {
				let ref = req.args.context ?? req.args.interface;

				if (ref == null)
					return { error: 'missing_argument' };

				defer(req, (reply) =>
					daemon.context_down(ref, (err) => reply(err ? { ...err } : {})));
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
