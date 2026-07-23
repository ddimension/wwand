// wwand-esim — host-side eSIM download/notification bridge.
//
// Shipped as the optional wwand-esim package; the daemon loads it lazily via
// require() and delegates modem_esim to it. Exportless plain script (like
// esim.uc / mbim_lazy): require() cannot compile ES modules, but imports are
// fine and the script returns its API — here a create(deps) factory.
//
// It spawns lpac (LPAC_APDU=stdio), drains its JSON APDU requests non-blocking
// via uloop and answers each straight from sim.apdu_* (no ubus, no jsonfilter);
// lpac does the SM-DP+ HTTPS itself. Progress + lpac stderr go to the log file,
// which download_status streams. Management ops (backend/profiles/enable/…)
// and the modem-internal AT download are delegated to the injected esim module.

'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as sim from './sim.uc';

const ESIM_LOGF = '/tmp/wwand/esim-download.log';
const ESIM_LPAC = '/usr/lib/lpac';

return {
	// deps: { esim (the wwand.esim module), log(level,msg), modem_of(ref) }
	create: function(deps) {
		let esim = deps.esim, log = deps.log, modem_of = deps.modem_of;
		let dl = { state: 'idle' };   // one host download at a time

		// spawn lpac for a host-side op (download / chip / notif-list /
		// notif-process) and bridge its stdio APDU protocol; on_done(err, log)
		let lpac_run = (ref, slot, op, code, conf, on_done) => {
			let entry = modem_of(ref);

			if (fs.access(ESIM_LPAC) != true)
				return false;   // wwand-lpac not installed — caller reports it

			let cmd;
			switch (op) {
			case 'download':      cmd = sprintf("profile download -a '%s'%s", code ?? '',
			                                    length(conf ?? '') ? sprintf(" -c '%s'", conf) : ''); break;
			case 'notif-list':    cmd = 'notification list'; break;
			case 'notif-process': cmd = 'notification process -a'; break;
			default:              cmd = 'chip info';
			}

			let tr = fs.open(ESIM_LOGF, 'w'); if (tr) tr.close();   // truncate the log
			let logf = fs.open(ESIM_LOGF, 'a');

			// native spawn gives a non-blocking stdout + writable stdin; the
			// shell only sets the env and appends lpac's stderr to the log
			let qmit = require('wwand_io');
			let h = qmit.spawn([ '/bin/sh', '-c',
				sprintf("mkdir -p /tmp/wwand; exec env LPAC_APDU=stdio LPAC_HTTP=curl %s %s 2>>%s",
					ESIM_LPAC, cmd, ESIM_LOGF) ]);

			if (!h) { if (logf) logf.close(); return null; }

			log('notice', sprintf('modem %s: esim[%s]: lpac stdio (inline bridge)', ref, op));

			let chan = 0, uh = null, buf = '';

			let logline = (s) => {
				if (logf) { logf.write(s + '\n'); logf.flush(); }
				log('notice', sprintf('modem %s: esim[%s]: %s', ref, op, s));
			};
			let send = (ecode, data) =>
				h.write(sprintf('{"type":"apdu","payload":{"ecode":%d,"data":"%s"}}\n', ecode, data ?? ''));
			let field = (s, re) => { let m = match(s, re); return m ? m[1] : null; };

			let finish;   // forward-declare (ucode TDZ on self-referencing arrows)
			finish = () => {
				if (uh) { uh.delete(); uh = null; }
				let ec = h.close();   // reaps the child, returns its exit status
				if (logf) { logf.close(); logf = null; }
				on_done(ec == 0 ? null : { error: 'lpac', code: ec }, trim(fs.readfile(ESIM_LOGF) ?? ''));
			};

			// stdout carries only the protocol's JSON objects; fields are pulled
			// with match() as ucode's json() throws uncatchably. APDU ops
			// dispatch async (reply written when the modem answers); the rest log.
			let handle_line = (s) => {
				if (substr(s, 0, 1) != '{') { if (length(s)) logline(s); return; }

				let mtype = field(s, /"type": *"([a-z]+)"/);
				if (mtype == 'apdu') {
					let func = field(s, /"func": *"([a-z_]+)"/);
					let param = field(s, /"param": *"([0-9A-Fa-f]*)"/) ?? '';
					switch (func) {
					case 'connect':
					case 'disconnect':
						send(0, ''); break;
					case 'logic_channel_open':
						sim.apdu_open(entry.modem, slot, param, (err, res) => {
							chan = res?.channel ?? 0;
							send(err ? -1 : chan, '');
						}); break;
					case 'transmit':
						// apdu_send yields the response hex directly (modem_apdu is
						// what wraps it as {response}); use it as-is
						sim.apdu_send(entry.modem, slot, chan, param, (err, res) =>
							send(err ? -1 : 0, err ? '' : (res ?? ''))); break;
					case 'logic_channel_close':
						sim.apdu_close(entry.modem, slot, chan, () => send(0, '')); break;
					default:
						send(-1, '');
					}
				} else if (mtype == 'progress')
					logline('progress: ' + (field(s, /"message": *"([^"]*)"/) ?? 'step'));
				else if (mtype == 'lpa') {
					logline(sprintf('result: code=%s %s',
						field(s, /"code": *(-?[0-9]+)/) ?? '?',
						field(s, /"message": *"([^"]*)"/) ?? ''));
					let d = field(s, /"data": *"([^"]*)"/);
					if (d) logline('data: ' + d);
				}
			};

			// h.read() is non-blocking (edge-triggered fd): drain all available
			// bytes, then process every complete line
			uh = uloop.handle(h.fileno(), () => {
				while (true) {
					let chunk = h.read();
					if (chunk === false) return finish();   // EOF: lpac exited
					if (chunk === null) break;               // no more data right now
					buf += chunk;
				}

				let nl;
				while ((nl = index(buf, '\n')) >= 0) {
					let s = trim(substr(buf, 0, nl));
					buf = substr(buf, nl + 1);
					if (length(s)) handle_line(s);
				}
			}, uloop.ULOOP_READ);

			return h;
		};

		// host-side download via lpac; on success chain the install-ack
		// notification to the SM-DP+ (ES9+) unless auto_notify is disabled
		let download_lpac = (ref, slot, code, conf, cb, auto_notify) => {
			dl = { state: 'running', via: 'lpac', logf: ESIM_LOGF, phase: 'download' };

			let finish = (state, extra) => {
				dl = { state, via: 'lpac', ...extra };
				log('notice', sprintf('modem %s: eSIM download %s%s', ref, state,
					extra?.notified != null ? sprintf(' (ack %s)', extra.notified ? 'sent' : 'skipped') : ''));
			};

			let p = lpac_run(ref, slot, 'download', code, conf, (err, out) => {
				// the bridge exits 0 even when the SM-DP+ refuses; the real
				// verdict is lpac's own result line
				let ok = !err && match(out ?? '', /result:[^\n]*code=0/);

				if (!ok)
					return finish('failed', { code: err?.code ?? -1, log: out, phase: 'download' });

				if (!auto_notify)
					return finish('done', { code: 0, log: out, phase: 'download', notified: false });

				dl = { state: 'running', via: 'lpac', logf: ESIM_LOGF, phase: 'notify', log: out };
				let np = lpac_run(ref, slot, 'notif-process', '', '', (nerr, nout) => {
					finish('done', { code: 0, phase: 'notify', notified: !nerr,
					                 log: trim((out ?? '') + '\n' + (nout ?? '')) });
				});
				if (!np)
					finish('done', { code: 0, log: out, phase: 'download', notified: false });
			});

			if (!p) {
				dl = { state: 'failed', via: 'lpac', code: -1 };
				return cb({ error: 'esim_not_installed' });
			}

			cb(null, { started: true, via: 'lpac' });
		};

		return {
			modem_esim: function(ref, op, params, cb) {
				let entry = modem_of(ref);

				if (!entry?.modem)
					return cb({ error: 'no_such_modem', ref: ref });

				let slot = +(params?.slot ?? 1);
				let iccid = params?.iccid ?? '';
				let done = (err, res) => cb(err ? { error: 'esim', detail: err } : null, res);

				switch (op) {
				case 'backend':
					return esim.backend(entry.modem, slot, (be) => cb(null, { backend: be }));

				case 'download': {
					if (dl?.state == 'running')
						return cb({ error: 'busy' });

					let code = params?.activation_code ?? '';

					if (!length(code))
						return cb({ error: 'missing_argument' });

					// shell-safe: activation codes are LPA:1$host$token style
					if (!match(code, /^[A-Za-z0-9$:._+-]+$/) ||
					    (params?.confirmation_code != null &&
					     !match(params.confirmation_code, /^[A-Za-z0-9._-]*$/)))
						return cb({ error: 'invalid_argument' });

					// standard: acknowledge the install to the operator afterwards;
					// callers pass auto_notify=false only for testing
					let auto_notify = params?.auto_notify ?? true;

					// AT modems download internally (AT+QESIM, no host data), QMI
					// modems use the host-side lpac glue
					return esim.backend(entry.modem, slot, (be) => {
						if (be == 'at') {
							dl = { state: 'running', via: 'modem' };
							esim.download_at(entry.modem, code, params?.confirmation_code, (err, res) => {
								dl = err
									? { state: 'failed', via: 'modem', error: err.error, ret: err.ret }
									: { state: 'done', via: 'modem', ret: res?.ret };
								log('notice', sprintf('modem %s: eSIM AT download %s', ref, dl.state));
							});

							return cb(null, { started: true, via: 'modem' });
						}

						download_lpac(ref, slot, code, params?.confirmation_code, cb, auto_notify);
					});
				}

				case 'download_status': {
					let st = dl ?? { state: 'idle' };

					// stream the live lpac output while a run is in progress
					if (st.state == 'running' && st.logf)
						st = { ...st, log: trim(fs.readfile(st.logf) ?? '') };

					return cb(null, st);
				}

				// pending eUICC notifications: after any profile op the eUICC
				// queues notifications that confirm the operation to the SM-DP+
				// (ES9+) — 'notifications' lists them, 'notify' sends them
				case 'notifications':
					if (!lpac_run(ref, slot, 'notif-list', '', '', (err, out) =>
						cb(err ? { error: 'lpac', ...err } : null, { ok: !err, log: out })))
						return cb({ error: 'esim_not_installed' });
					return;

				case 'notify':
					if (dl?.state == 'running')
						return cb({ error: 'busy' });

					dl = { state: 'running', via: 'notify', logf: ESIM_LOGF };

					if (!lpac_run(ref, slot, 'notif-process', '', '', (err, out) => {
						dl = { state: err ? 'failed' : 'done', via: 'notify',
						       code: err?.code ?? 0, log: out };
						log('notice', sprintf('modem %s: eSIM notifications %s', ref, dl.state));
					}))
						return cb({ error: 'esim_not_installed' });
					return cb(null, { started: true, via: 'notify' });

				case 'profiles': return esim.profiles(entry.modem, slot, done);
				case 'eid':      return esim.get_eid(entry.modem, slot, done);
				case 'enable':
					if (!length(iccid)) return cb({ error: 'missing_argument' });
					return esim.enable(entry.modem, slot, iccid, (err, res) => {
						if (!err)
							log('notice', sprintf('modem %s: eSIM profile %s enabled', ref, iccid));
						done(err, res);
					});
				case 'disable':
					if (!length(iccid)) return cb({ error: 'missing_argument' });
					return esim.disable(entry.modem, slot, iccid, done);
				case 'delete':
					if (!length(iccid)) return cb({ error: 'missing_argument' });
					return esim.del(entry.modem, slot, iccid, done);
				default:
					return cb({ error: 'invalid_op', op: op });
				}
			},
		};
	},
};
