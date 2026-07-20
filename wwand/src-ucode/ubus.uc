// wwand — ubus object registration. Maps the 'wwand' ubus object onto the
// daemon core. context_up uses a deferred reply: the request stays open
// until the context reports CONNECTED or fails.

'use strict';

export function publish(conn, daemon, log)
{
	let obj = conn.publish('wwand', {
		status: {
			call: (req) => daemon.status(),
		},

		modem_list: {
			call: (req) => daemon.status(),
		},

		modem_signal: {
			args: { modem: '' },
			call: (req) => daemon.modem_signal(req.args.modem),
		},

		modem_cells: {
			args: { modem: '' },
			call: (req) => daemon.modem_cells(req.args.modem),
		},

		modem_location: {
			args: { modem: '' },
			call: (req) => daemon.modem_location(req.args.modem),
		},

		modem_at: {
			args: { modem: '', command: '', timeout: 0 },
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
			args: { modem: '', protocol: '' },
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
			args: { context: '', interface: '' },
			call: (req) => daemon.context_status(req.args.context ?? req.args.interface),
		},

		context_up: {
			args: { context: '', interface: '' },
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
			args: { context: '', interface: '' },
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
			args: { action: '', device: '' },
			call: (req) => {
				daemon.hotplug(req.args.action, req.args.device);
				return {};
			},
		},

		reload: {
			call: (req) => {
				if (daemon.reload)
					daemon.reload();

				return {};
			},
		},
	});

	if (!obj && log)
		log('err', 'failed to publish wwand ubus object');

	return obj;
}
