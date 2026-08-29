// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
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

	// defer BEFORE running: a handler that validates its arguments answers
	// synchronously, and then reply() would land on a request not yet marked
	// deferred. It happens to be harmless in the current ubus binding (the
	// post-handler completion path is skipped once `replied` is set), but that
	// is an internal detail of the binding, not a contract — and the deferred
	// pattern the binding documents is defer-then-reply.
	req.defer();
	run(reply);
};

// ok_reply(reply): the standard deferred-method completion — adapts a daemon
// op's (err, res) callback to the uniform { ok: ... } reply envelope.
let ok_reply = (reply) => (err, res) =>
	reply(err ? { ok: false, ...err } : { ok: true, ...(res ?? {}) });

// ok_sync(r): uniform envelope for LuCI-facing sync methods. Purely additive —
// keeps every field of the daemon result and only adds the ok flag, so existing
// consumers reading fields or .error keep working.
let ok_sync = (r) => (r?.error ? { ok: false, ...r } : { ok: true, ...(r ?? {}) });

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
			call: (req) => ok_sync(daemon.modem_signal(req.args.modem)),
		},

		// manual hardware repower/reset via the board profile (also the recovery
		// path). modem optional; defaults to the first configured modem.
		modem_repower: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => ok_sync(daemon.repower_modem(req.args.modem)),
		},

		// admin soft modem reset (QMI: DMS offline->reset, NCM: AT+CFUN=1,1) —
		// the apply step for `deferred` selection/band settings (write ACL).
		// auto interfaces come back up on their own once the modem re-registers.
		modem_reset: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_reset(req.args.modem, ok_reply(reply))),
		},

		// manual PIN release: enter the PIN once past the low-retry safety block
		// (security relevant — write ACL). `pin` optional (overrides the config).
		modem_sim_puk: {
			args: { modem: '', puk: '', new_pin: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.sim_puk_unblock(req.args.modem, req.args.puk, req.args.new_pin, ok_reply(reply))),
		},

		modem_sim_pin_verify: {
			args: { modem: '', pin: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.sim_pin_verify(req.args.modem, req.args.pin, ok_reply(reply))),
		},

		modem_get_settings: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_get_settings(req.args.modem, ok_reply(reply))),
		},

		modem_sim_slots: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_sim_slots(req.args.modem, ok_reply(reply))),
		},

		// detected modems for the LuCI stable-binding picker (managed + present)
		modem_probe: {
			args: { ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_probe(ok_reply(reply))),
		},

		modem_sim_switch_slot: {
			args: { modem: '', slot: 0, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_sim_switch_slot(req.args.modem, req.args.slot, ok_reply(reply))),
		},

		// enable/disable the SIM PIN query (PIN lock); needs the current PIN
		modem_sim_pin_lock: {
			args: { modem: '', pin: '', enable: false, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_sim_pin_lock(req.args.modem, req.args.pin, req.args.enable, ok_reply(reply))),
		},

		// eSIM management (optional wwand-esim package; reports
		// esim_not_installed when absent)
		modem_esim: {
			args: { modem: '', op: '', slot: 0, iccid: '',
			        activation_code: '', confirmation_code: '',
			        auto_notify: true, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_esim(req.args.modem, req.args.op, req.args, ok_reply(reply))),
		},

		// raw APDU access (write ACL — security relevant)
		modem_apdu: {
			args: { modem: '', op: '', slot: 0, channel: 0, aid: '', apdu: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_apdu(req.args.modem, req.args.op, req.args, ok_reply(reply))),
		},

		// SMS: list/read (read ACL), delete (write ACL). storage 'SM'|'ME'.
		modem_sms_list: {
			args: { modem: '', storage: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_sms_list(req.args.modem, req.args.storage, ok_reply(reply))),
		},

		modem_sms_read: {
			args: { modem: '', storage: '', index: 0, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_sms_read(req.args.modem, req.args.storage, req.args.index, ok_reply(reply))),
		},

		modem_sms_send: {
			args: { modem: '', number: '', text: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_sms_send(req.args.modem, req.args.number, req.args.text, ok_reply(reply))),
		},

		modem_sms_delete: {
			args: { modem: '', storage: '', index: 0, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_sms_delete(req.args.modem, req.args.storage, req.args.index, ok_reply(reply))),
		},

		modem_plmn_lists: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_plmn_lists(req.args.modem, ok_reply(reply))),
		},

		modem_plmn_set: {
			args: { modem: '', list_type: '', entries: [], ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_plmn_set(req.args.modem, req.args.list_type, req.args.entries, ok_reply(reply))),
		},

		modem_plmn_restore: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_plmn_restore(req.args.modem, ok_reply(reply))),
		},

		modem_set_settings: {
			args: { modem: '', settings: {}, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_set_settings(req.args.modem, req.args.settings, ok_reply(reply))),
		},

		// scan visible operators (COPS=? equivalent); may be slow, so the reply
		// is deferred until the modem answers. NOTE: a real scan often runs
		// MINUTES — interactive callers should use the async start/status pair
		// below instead of this blocking form (kept for CLI use).
		modem_scan: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_scan(req.args.modem, ok_reply(reply))),
		},

		// async scan: start returns immediately, status is polled. Survives the
		// LuCI→uhttpd→rpcd timeout chain that kills a minutes-long blocking call.
		modem_scan_start: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_scan_start(req.args.modem, ok_reply(reply))),
		},

		modem_scan_status: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_scan_status(req.args.modem, ok_reply(reply))),
		},

		// network selection: mode 'auto' or 'manual' + mcc/mnc (write ACL)
		modem_set_network_selection: {
			args: { modem: '', mode: '', mcc: 0, mnc: 0, ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_set_network_selection(req.args.modem, req.args.mode,
					req.args.mcc, req.args.mnc, ok_reply(reply))),
		},

		modem_reattach: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => defer(req, (reply) =>
				daemon.modem_reattach(req.args.modem, ok_reply(reply))),
		},

		modem_cells: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => ok_sync(daemon.modem_cells(req.args.modem)),
		},

		modem_location: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => ok_sync(daemon.modem_location(req.args.modem)),
		},

		modem_datapath: {
			args: { modem: '', ubus_rpc_session: '' },
			call: (req) => ok_sync(daemon.modem_datapath(req.args.modem)),
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
				daemon.modem_set_protocol(req.args.modem, req.args.protocol, ok_reply(reply))),
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

		// user-triggered config migration (LuCI modem list). apply=false returns
		// the planned uci changes for preview; apply=true converts the selected
		// legacy proto qmi/mbim/ncm interfaces to proto wwand in place. An empty
		// interfaces list migrates everything migratable.
		migrate: {
			args: { apply: false, interfaces: [], ubus_rpc_session: '' },
			call: (req) => {
				if (!daemon.migrate)
					return { ok: false, error: 'unsupported' };

				return ok_sync(daemon.migrate(req.args.interfaces, req.args.apply));
			},
		},

		// runtime debug switch: ubus call wwand set_log_level '{"level":"debug"}'
		// (reverted to the uci value on reload)
		set_log_level: {
			args: { level: '', ubus_rpc_session: '' },
			call: (req) => {
				if (!req.args.level)
					return { ok: false, error: 'missing_argument' };

				if (!daemon.set_log_level || !daemon.set_log_level(req.args.level))
					return { ok: false, error: 'invalid_level' };

				return { ok: true, level: req.args.level };
			},
		},
	});

	if (!obj && log)
		log('err', 'failed to publish wwand ubus object');

	return obj;
};
