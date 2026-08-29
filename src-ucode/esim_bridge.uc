// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
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
// which download_status streams. Profile management writes (enable/disable/
// delete) also run through lpac over the same APDU bridge — the proven-good
// write path (some eUICC/modem combos, e.g. the RG650E, refuse ES10c writes
// over the QMI channel with undefinedError 127 and speak a different AT+QESIM
// dialect); the injected esim module's own ES10c/AT paths remain the fallback
// when no lpac is installed. Reads (backend/profiles/eid) and the
// modem-internal AT download stay delegated to the esim module.

'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as sim from 'wwand.sim';

const ESIM_LOGF = '/tmp/wwand/esim-download.log';
// /usr/bin/lpac is the standard entry point provided by BOTH lpac packages the
// wwand-esim dependency (+lpac) can be satisfied by: the generic openwrt-packages
// lpac (binary here) and our self-contained wwand-lpac (a thin wrapper here that
// execs its static /usr/lib/lpac). Calling this path works for either.
const ESIM_LPAC = '/usr/bin/lpac';
// Nothing read from lpac for this long -> the run is stuck (curl waiting on a
// dead SM-DP+ socket, or an APDU the modem never answers). Without a timeout
// dl.state stays 'running' forever and every later download is refused as
// 'busy'. Generous on purpose: the ES9+ profile transfer is one quiet HTTPS
// POST and is slow over a bad link.
const ESIM_IDLE_MS = 300000;

// classify one lpac stdout line — the testable core of the stdio bridge.
// Protocol fields are pulled with match() because ucode's json() throws
// uncatchably on malformed input (and lpac interleaves non-JSON noise).
//   { kind: 'apdu', func, param }        an APDU request to answer
//   { kind: 'progress', message }        ES9+/ES10 progress step
//   { kind: 'lpa', code, message, data } final result (code '0' = success)
//   { kind: 'log', text }                anything that is not protocol JSON
//   null                                 empty line
function parse_lpac_line(s)
{
	let field = (str, re) => { let m = match(str, re); return m ? m[1] : null; };

	if (!length(s ?? ''))
		return null;

	if (substr(s, 0, 1) != '{')
		return { kind: 'log', text: s };

	let mtype = field(s, /"type": *"([a-z]+)"/);

	if (mtype == 'apdu')
		return {
			kind: 'apdu',
			func: field(s, /"func": *"([a-z_]+)"/),
			param: field(s, /"param": *"([0-9A-Fa-f]*)"/) ?? '',
		};

	if (mtype == 'progress')
		return { kind: 'progress', message: field(s, /"message": *"([^"]*)"/) ?? 'step' };

	if (mtype == 'lpa')
		return {
			kind: 'lpa',
			code: field(s, /"code": *(-?[0-9]+)/),
			message: field(s, /"message": *"([^"]*)"/) ?? '',
			data: field(s, /"data": *"([^"]*)"/),
		};

	// unknown JSON object: keep it visible in the log rather than dropping it
	return { kind: 'log', text: s };
}

return {
	// exposed for tests (test_esim_bridge): the pure lpac line classifier
	parse_lpac_line: parse_lpac_line,

	// deps: { esim (the wwand.esim module), log(level,msg), modem_of(ref) }
	create: function(deps) {
		let esim = deps.esim, log = deps.log, modem_of = deps.modem_of;
		let lpac = deps.lpac_path ?? ESIM_LPAC;   // test seam for the lpac binary
		let idle_ms = deps.idle_ms ?? ESIM_IDLE_MS;   // test seam for the watchdog
		let dl = { state: 'idle' };   // one host download at a time
		let mgmt_busy = false;        // one lpac profile-management op at a time

		// --- quiet mode (modem._esim_op) ------------------------------------
		// While an eSIM op runs, URC-driven background actions (the NCM
		// register fast-path poll, +CGEV pokes) stay out of the AT queue so a
		// long APDU run is not starved behind poll bursts. It is a REFCOUNT,
		// not a flag: the daemon's bring-up eSIM refresh and a concurrent user
		// op both raise it, and as a plain bool the first completion re-opened
		// the queue while the other op was still running. Readers only test
		// truthiness, so 0 (idle) / n>0 (quiet) keeps their contract.
		let quiet_raise = (m) => {
			if (m)
				m._esim_op = (+(m._esim_op ?? 0)) + 1;
		};

		// one claim on the quiet mode, released exactly once: a long op whose
		// completion handler is also reachable from an error path must never
		// release twice — that would re-open the queue for a parallel op.
		let quiet_claim = (m) => {
			let released = false;

			quiet_raise(m);

			return () => {
				if (released || !m)
					return;

				released = true;

				let n = (+(m._esim_op ?? 0)) - 1;
				m._esim_op = (n > 0) ? n : 0;
			};
		};

		// spawn lpac for a host-side op (download / chip / notif-list /
		// notif-process) and bridge its stdio APDU protocol; on_done(err, log)
		let lpac_run = (ref, slot, op, code, conf, on_done) => {
			let entry = modem_of(ref);

			if (fs.access(lpac) != true)
				return false;   // no lpac package installed — caller reports it

			let cmd;
			switch (op) {
			case 'download':      cmd = sprintf("profile download -a '%s'%s", code ?? '',
			                                    length(conf ?? '') ? sprintf(" -c '%s'", conf) : ''); break;
			case 'notif-list':    cmd = 'notification list'; break;
			case 'notif-process': cmd = 'notification process -a'; break;
			// management writes: the ICCID rides in the code arg (validated
			// digits-only by the caller, so the quoting is shell-safe)
			case 'enable':        cmd = sprintf("profile enable '%s'",  code); break;
			case 'disable':       cmd = sprintf("profile disable '%s'", code); break;
			case 'delete':        cmd = sprintf("profile delete '%s'",  code); break;
			default:              cmd = 'chip info';
			}

			let tr = fs.open(ESIM_LOGF, 'w'); if (tr) tr.close();   // truncate the log
			let logf = fs.open(ESIM_LOGF, 'a');

			// native spawn gives a non-blocking stdout + writable stdin; the
			// shell sets the env and appends lpac's stderr to the log. The
			// __EXIT marker carries the exit status IN-BAND: uloop's SIGCHLD
			// handler reaps all children, so h.close()'s waitpid can lose the
			// race and not know the status (returns null) — the marker line is
			// then the only reliable source. (No exec: the shell must survive
			// lpac to echo the marker.) The marker's own stderr is dropped: an
			// aborted run (inactivity timeout) closes the pipe under the shell,
			// and its "echo: I/O error" would reach the log as a wwand error.
			let qmit = require('wwand_io');
			let h = qmit.spawn([ '/bin/sh', '-c',
				sprintf("mkdir -p /tmp/wwand; env LPAC_APDU=stdio LPAC_HTTP=curl %s %s 2>>%s; echo \"__EXIT:$?\" 2>/dev/null",
					lpac, cmd, ESIM_LOGF) ]);

			if (!h) { if (logf) logf.close(); return null; }

			log('notice', sprintf('modem %s: esim[%s]: lpac stdio (inline bridge)', ref, op));

			let chan = 0, uh = null, buf = '';

			let logline = (s) => {
				if (logf) { logf.write(s + '\n'); logf.flush(); }
				log('notice', sprintf('modem %s: esim[%s]: %s', ref, op, s));
			};
			// h.write() may write only PART of the string (it returns the byte
			// count) or nothing at all (null = EAGAIN, lpac's stdin pipe full);
			// false is a hard error. Dropping the remainder would leave lpac
			// waiting for an APDU answer that never arrives, so keep the tail
			// and retry it from a timer rather than spinning in the callback.
			let wq = '', wtimer = null, wdead = false;

			let pump;
			pump = () => {
				wtimer = null;

				while (length(wq)) {
					let n = h.write(wq);

					if (n === false) {   // hard error: lpac's stdin is gone
						wdead = true;
						wq = '';
						logline('write to lpac failed - aborting');

						// end the run HERE. lpac is waiting for an APDU answer
						// it will never get, so nothing more arrives on stdout
						// either: without this the run would sit there until
						// the inactivity watchdog fires minutes later.
						return finish({ error: 'lpac_stdin', code: -1 });
					}

					if (n === null || n === 0)   // would block: retry shortly
						return (wtimer = uloop.timer(20, pump));

					wq = substr(wq, n);
				}
			};

			let send = (ecode, data) => {
				if (wdead)
					return;

				wq += sprintf('{"type":"apdu","payload":{"ecode":%d,"data":"%s"}}\n', ecode, data ?? '');

				if (!wtimer)
					pump();
			};
			let field = (s, re) => { let m = match(s, re); return m ? m[1] : null; };

			let inband_ec = null;   // exit status from the __EXIT stdout marker
			let idle = null;        // inactivity watchdog (ESIM_IDLE_MS)
			let done = false;

			let finish;   // forward-declare (ucode TDZ on self-referencing arrows)
			finish = (err) => {
				if (done)
					return;

				done = true;
				idle?.cancel();   idle = null;
				wtimer?.cancel(); wtimer = null;
				if (uh) { uh.delete(); uh = null; }

				// An ABORTED run (watchdog, dead stdin) still has a live child:
				// close() below only drops the pipes and reaps without blocking,
				// and a process stuck elsewhere does not notice its stdout
				// going away — an lpac blocked in curl on a dead SM-DP+ socket
				// would keep running (and keep the APDU channel claimed) long
				// after wwand considers the run over. h.kill() signals the whole
				// process group; guarded because an older wwand_io.so has no
				// such method (then it stays as before: orphaned, not fatal).
				if (err && type(h.kill) == 'function')
					h.kill();
				// close() returns null when uloop already reaped the child
				// (status unknown) — the in-band marker fills the gap; with
				// neither (shell killed) the missing result line is the
				// caller-visible failure, so don't fabricate an error here
				let ec = h.close();
				if (ec === null)
					ec = inband_ec ?? 0;
				if (logf) { logf.close(); logf = null; }
				on_done(err ?? (ec == 0 ? null : { error: 'lpac', code: ec }),
					trim(fs.readfile(ESIM_LOGF) ?? ''));
			};

			// dispatch a classified lpac line (parse_lpac_line above). APDU ops
			// dispatch async (reply written when the modem answers); the rest log.
			let handle_line = (s) => {
				let rec = parse_lpac_line(s);

				if (rec == null)
					return;

				if (rec.kind == 'log')
					return logline(rec.text);

				if (rec.kind == 'progress')
					return logline('progress: ' + rec.message);

				if (rec.kind == 'lpa') {
					logline(sprintf('result: code=%s %s', rec.code ?? '?', rec.message));
					if (rec.data)
						logline('data: ' + rec.data);
					return;
				}

				switch (rec.func) {
				case 'connect':
				case 'disconnect':
					send(0, ''); break;
				case 'logic_channel_open':
					sim.apdu_open(entry.modem, slot, rec.param, (err, res) => {
						chan = res?.channel ?? 0;
						send(err ? -1 : chan, '');
					}); break;
				case 'transmit':
					// apdu_send yields the response hex directly (modem_apdu is
					// what wraps it as {response}); use it as-is
					sim.apdu_send(entry.modem, slot, chan, rec.param, (err, res) =>
						send(err ? -1 : 0, err ? '' : (res ?? ''))); break;
				case 'logic_channel_close':
					sim.apdu_close(entry.modem, slot, chan, () => send(0, '')); break;
				default:
					send(-1, '');
				}
			};

			// h.read() is non-blocking (edge-triggered fd): drain all available
			// bytes, then process every complete line
			uh = uloop.handle(h.fileno(), () => {
				let eof = false;

				idle?.set(idle_ms);   // any output means the run is alive

				while (true) {
					let chunk = h.read();
					if (chunk === false) { eof = true; break; }   // lpac exited
					if (chunk === null) break;                    // no more data right now
					buf += chunk;
				}

				// EOF and the last payload arrive in the SAME drain cycle for a
				// short-lived child: process what is buffered BEFORE finishing -
				// that tail carries lpac's result line and the __EXIT marker.
				if (eof && length(trim(buf)))
					buf += '\n';   // terminate a trailing unterminated line

				let nl;
				while ((nl = index(buf, '\n')) >= 0) {
					let s = trim(substr(buf, 0, nl));
					buf = substr(buf, nl + 1);

					// in-band exit status (see spawn above), not an lpac line
					let em = match(s, /^__EXIT:(\d+)$/);
					if (em) { inband_ec = +em[1]; continue; }

					if (length(s)) handle_line(s);
				}

				if (eof)
					finish();
			}, uloop.ULOOP_READ);

			idle = uloop.timer(idle_ms, () => {
				idle = null;
				logline(sprintf('timeout: no output from lpac for %d s - aborting',
					idle_ms / 1000));
				finish({ error: 'timeout', code: -1 });
			});

			return h;
		};

		// host-side download via lpac; on success chain the install-ack
		// notification to the SM-DP+ (ES9+) unless auto_notify is disabled
		// `release` is this run's quiet-mode claim (quiet_claim): the lpac run
		// outlives the ack, so the caller raises it before starting us and we
		// drop it when the run really ends.
		let download_lpac = (ref, slot, code, conf, cb, auto_notify, release) => {
			dl = { state: 'running', via: 'lpac', logf: ESIM_LOGF, phase: 'download' };

			let finish = (state, extra) => {
				dl = { state, via: 'lpac', ...extra };
				release?.();   // run finished — this op's quiet claim is dropped
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
				release?.();   // never started — drop the claim right away
				return cb({ error: 'esim_not_installed' });
			}

			cb(null, { started: true, via: 'lpac' });
		};

		// apply after a profile switch: hot-reset the SIM so the modem drops
		// its cached (old-profile) SIM state and re-reads the card — without
		// this the RG650E keeps running the stale identity into limited
		// service. Then re-unlock (PIN may re-arm with the card) and re-read
		// identity so status/LuCI show the new profile. cb fires immediately;
		// the re-read finishes in the background and the data session comes
		// back via the normal transient-loss path.
		let apply_sim_reset = (ref, entry, slot, res, cb) => {
			sim.power_cycle(entry.modem, slot, (perr) => {
				if (perr) {
					log('warn', sprintf('modem %s: eSIM apply: sim power-cycle failed (%J) — modem reset needed',
						ref, perr));
					return cb(null, { ...res, apply: 'modem_reset' });
				}

				// after the card is back: unlock (PIN may re-arm), then the full
				// per-SIM reapply — identity, wwand_sim override re-match and
				// attach profile (modem.reapply_sim; QMI/MBIM). Fallback for
				// modems without it: at least refresh the cached identity.
				uloop.timer(2000, () => sim.unlock(entry.modem, () => {
					if (entry.modem.reapply_sim)
						return entry.modem.reapply_sim();

					sim.read_identity(entry.modem, (id) => {
						entry.modem.info.imsi   = id.imsi   ?? entry.modem.info.imsi;
						entry.modem.info.iccid  = id.iccid  ?? entry.modem.info.iccid;
						entry.modem.info.msisdn = id.msisdn ?? entry.modem.info.msisdn;
						log('notice', sprintf('modem %s: eSIM apply: sim re-read: iccid %s imsi %s',
							ref, id.iccid ?? '?', id.imsi ?? '?'));
					});
				}));

				cb(null, { ...res, applied: 'sim_reset' });
			});
		};

		// profile management (enable/disable/delete) via lpac — always
		// preferred over the esim module's own ES10c/AT writes (see header);
		// falls back to those only when no lpac binary is installed.
		let profile_op_lpac = (ref, slot, op, iccid, cb, fallback) => {
			if (dl?.state == 'running' || mgmt_busy)
				return cb({ error: 'busy' });

			mgmt_busy = true;
			let p = lpac_run(ref, slot, op, iccid, '', (err, out) => {
				mgmt_busy = false;
				// lpac exits 0 even when the eUICC refuses; the real verdict
				// is its own result line (same convention as download)
				let ok = !err && match(out ?? '', /result:[^\n]*code=0/);
				log('notice', sprintf('modem %s: eSIM profile %s %s%s (lpac)',
					ref, iccid, op, ok ? 'd' : ' FAILED'));
				if (ok)
					return cb(null, { ok: true, via: 'lpac' });
				cb({ error: 'esim',
				     detail: { error: 'lpac', code: err?.code ?? -1, log: out } });
			});

			if (p === false) { mgmt_busy = false; return fallback(); }
			if (!p) { mgmt_busy = false; return cb({ error: 'esim', detail: { error: 'spawn' } }); }
		};

		return {
			modem_esim: function(ref, op, params, cb) {
				let entry = modem_of(ref);

				if (!entry?.modem)
					return cb({ error: 'no_such_modem', ref: ref });

				let slot = +(params?.slot ?? 1);
				let iccid = params?.iccid ?? '';
				// quiet mode for the duration of this call (see quiet_claim);
				// ops that outlive their ack raise a SECOND, longer-lived
				// claim of their own below
				let release = quiet_claim(entry.modem);
				let done = (err, res) => {
					release();
					cb(err ? { error: 'esim', detail: err } : null, res);
				};

				switch (op) {
				case 'backend':
					return esim.backend(entry.modem, slot, (be) => done(null, { backend: be }));

				case 'download': {
					if (dl?.state == 'running' || mgmt_busy)
						return done({ error: 'busy' });

					let code = params?.activation_code ?? '';

					if (!length(code))
						return done({ error: 'missing_argument' });

					// shell-safe: activation codes are LPA:1$host$token style
					if (!match(code, /^[A-Za-z0-9$:._+-]+$/) ||
					    (params?.confirmation_code != null &&
					     !match(params.confirmation_code, /^[A-Za-z0-9._-]*$/)))
						return done({ error: 'invalid_argument' });

					// standard: acknowledge the install to the operator afterwards;
					// callers pass auto_notify=false only for testing
					let auto_notify = params?.auto_notify ?? true;

					// AT modems download internally (AT+QESIM, no host data), QMI
					// modems use the host-side lpac glue
					return esim.backend(entry.modem, slot, (be) => {
						if (be == 'at') {
							dl = { state: 'running', via: 'modem' };

							// the in-modem download runs long after this ack —
							// its own claim spans the whole run and is raised
							// BEFORE the ack, so the count never dips to zero
							// in between (nor if download_at answers inline)
							let at_quiet = quiet_claim(entry.modem);

							esim.download_at(entry.modem, code, params?.confirmation_code, (err, res) => {
								dl = err
									? { state: 'failed', via: 'modem', error: err.error, ret: err.ret }
									: { state: 'done', via: 'modem', ret: res?.ret };
								at_quiet();   // run finished — URCs may resume
								log('notice', sprintf('modem %s: eSIM AT download %s', ref, dl.state));
							});

							done(null, { started: true, via: 'modem' });
							return;
						}

						// same for the host-side lpac run: raise its claim
						// first, download_lpac drops it when the run ends (or
						// immediately when the spawn never happened)
						let lpac_quiet = quiet_claim(entry.modem);

						download_lpac(ref, slot, code, params?.confirmation_code,
							done, auto_notify, lpac_quiet);
					});
				}

				case 'download_status': {
					let st = dl ?? { state: 'idle' };

					// stream the live lpac output while a run is in progress
					if (st.state == 'running' && st.logf)
						st = { ...st, log: trim(fs.readfile(st.logf) ?? '') };

					return done(null, st);
				}

				// pending eUICC notifications: after any profile op the eUICC
				// queues notifications that confirm the operation to the SM-DP+
				// (ES9+) — 'notifications' lists them, 'notify' sends them
				case 'notifications':
					if (!lpac_run(ref, slot, 'notif-list', '', '', (err, out) =>
						done(err ? { error: 'lpac', ...err } : null, { ok: !err, log: out })))
						return done({ error: 'esim_not_installed' });
					return;

				case 'notify': {
					if (dl?.state == 'running' || mgmt_busy)
						return done({ error: 'busy' });

					dl = { state: 'running', via: 'notify', logf: ESIM_LOGF };

					// notif-process runs long after this ack — its own claim
					// spans the whole run (raised before the ack, dropped by
					// the completion handler or on a failed spawn)
					let notify_quiet = quiet_claim(entry.modem);

					if (!lpac_run(ref, slot, 'notif-process', '', '', (err, out) => {
						dl = { state: err ? 'failed' : 'done', via: 'notify',
						       code: err?.code ?? 0, log: out };
						notify_quiet();   // run finished — URCs may resume
						log('notice', sprintf('modem %s: eSIM notifications %s', ref, dl.state));
					})) {
						// lpac missing / spawn failed: never leave dl wedged
						// 'running' — every later download/notify would read busy
						dl = { state: 'failed', via: 'notify', code: -1 };
						notify_quiet();
						return done({ error: 'esim_not_installed' });
					}

					done(null, { started: true, via: 'notify' });
					return;
				}

				case 'profiles': return esim.profiles(entry.modem, slot, done);
				case 'eid':      return esim.get_eid(entry.modem, slot, done);
				case 'enable':
				case 'disable':
				case 'delete': {
					if (!length(iccid)) return done({ error: 'missing_argument' });
					if (!match(iccid, /^[0-9]+$/)) return done({ error: 'invalid_argument' });
					return profile_op_lpac(ref, slot, op, iccid, (err, res) => {
						// enable/disable change the active profile — the modem
						// must re-read the card; delete only removes a disabled
						// profile, nothing to apply
						if (err || op == 'delete')
							return done(err, res);
						apply_sim_reset(ref, entry, slot, res, done);
					}, () => {
						if (op == 'enable')
							return esim.enable(entry.modem, slot, iccid, (err, res) => {
								if (!err)
									log('notice', sprintf('modem %s: eSIM profile %s enabled', ref, iccid));
								done(err, res);
							});
						if (op == 'disable')
							return esim.disable(entry.modem, slot, iccid, done);
						return esim.del(entry.modem, slot, iccid, done);
					});
				}
				default:
					return done({ error: 'invalid_op', op: op });
				}
			},
		};
	},
};
