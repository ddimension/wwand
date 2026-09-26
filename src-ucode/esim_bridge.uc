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

// An activation code (and confirmation code) that may go into the lpac shell
// command. The byte-wise check comes FIRST because the regex cannot do it:
// ucode regexes run on a C string and stop at a NUL, so "LPA:1$h$t\0anything"
// matches this anchored allowlist on its prefix alone. Nothing is injected —
// sprintf truncates at the same NUL, so the shell only ever sees the prefix
// (measured, 2026-08-31) — but then the string we VALIDATED and the string we
// ACT on are different, and the profile downloaded is not the one the caller
// named. A boundary should refuse what it cannot carry faithfully. Same
// reasoning as atcmd's ctrl_at.
function codes_ok(code, conf)
{
	let ctrl = (v) => {
		for (let i = 0; i < length(v ?? ''); i++) {
			let c = ord(v, i);

			if (c < 0x20 || c == 0x7f)
				return true;
		}

		return false;
	};

	if (ctrl(code) || ctrl(conf))
		return false;

	return !!match(code, /^[A-Za-z0-9$:._+-]+$/) &&
		(conf == null || !!match(conf, /^[A-Za-z0-9._-]*$/));
}

// JSON string escapes back to text (RFC 8259 section 7)
function json_unescape(v)
{
	return replace(v, /\\(["\\\/bfnrt]|u[0-9a-fA-F]{4})/g, (m, c) => {
		switch (substr(c, 0, 1)) {
		case 'n': return '\n';
		case 't': return '\t';
		case 'r': return '\r';
		case 'b': return '\b';
		case 'f': return '\f';
		case 'u': return uchr(hex(substr(c, 1)));
		default:  return c;
		}
	});
}

// The flat fields of an event's payload: strings (unescaped), booleans and
// integers. Pulled with match() for the reason the header gives, which is why
// nested objects and arrays are not supported — no event carries one.
function event_payload(s)
{
	let out = {};
	let at = index(s, '"payload"');

	if (at < 0)
		return out;

	let body = substr(s, at + 9);

	for (let m in (match(body, /"([a-z_]+)": *"(([^"\\]|\\.)*)"/g) ?? []))
		out[m[1]] = json_unescape(m[2]);

	for (let m in (match(body, /"([a-z_]+)": *(true|false)/g) ?? []))
		out[m[1]] = (m[2] == 'true');

	for (let m in (match(body, /"([a-z_]+)": *(-?[0-9]+) *[,}]/g) ?? []))
		out[m[1]] = +m[2];

	return out;
}

// classify one lpac stdout line — the testable core of the stdio bridge.
// Protocol fields are pulled with match() because ucode's json() throws
// uncatchably on malformed input (and lpac interleaves non-JSON noise).
//   { kind: 'apdu', func, param }        an APDU request to answer
//   { kind: 'progress', message }        ES9+/ES10 progress step
//   { kind: 'lpa', code, message, data } final result (code '0' = success)
//   { kind: 'event', event, payload }    the process hands a step to the host
//                                        and waits: the answer is one line back
//                                        (session_run's on_event); payload holds
//                                        the event's string, boolean and integer
//                                        fields (event_payload)
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

	if (mtype == 'event')
		return { kind: 'event', event: field(s, /"event": *"([a-z_]+)"/), payload: event_payload(s) };

	// unknown JSON object: keep it visible in the log rather than dropping it
	return { kind: 'log', text: s };
}

return {
	// exposed for tests (test_esim_bridge): the pure lpac line classifier
	parse_lpac_line: parse_lpac_line,

	// deps: { esim (the wwand.esim module), log(level,msg), modem_of(ref),
	//         changed?(ref, slot) }
	// `changed` fires after anything that may have altered the card's profile
	// list (a finished download, an enable/disable/delete that succeeded): the
	// host's copy of that list — status `esim`, the SIM inventory — is read
	// only at bring-up and goes stale otherwise.
	create: function(deps) {
		let esim = deps.esim, log = deps.log, modem_of = deps.modem_of;
		// the host's refresh must not take the operation that triggered it
		// down with it — but a failure is said, not swallowed
		let changed = (ref, slot) => {
			try { deps.changed?.(ref, slot); }
			catch (e) { log('warn', sprintf('modem %s: eSIM profile list refresh failed (%s)', ref, e)); }
		};
		let lpac = deps.lpac_path ?? ESIM_LPAC;   // test seam for the lpac binary
		let idle_ms = deps.idle_ms ?? ESIM_IDLE_MS;   // test seam for the watchdog
		let dl = { state: 'idle' };   // one host download at a time
		let mgmt_busy = false;        // one lpac profile-management op at a time
		let parked = null;            // { ref, slot } of a session_run waiting on its host

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

		// Spawn a host-side process that speaks lpac's stdio APDU protocol and
		// bridge it to the modem's APDU channel; on_done(err, log).
		//   cmd        the shell command (stderr redirected by the caller)
		//   opts.logf  its log file, truncated at start (ESIM_LOGF by default);
		//              false = none, the process's output goes to the syslog only
		//   opts.on_event(rec, reply)  handles { kind: 'event' } lines; reply(obj)
		//              writes the answer. Without it the answer is a refusal,
		//              so a process waiting on one never hangs.
		//   opts.log_level(line)  the syslog level for one of its non-protocol
		//              lines ('notice' when absent)
		// Returns the process handle, or null when the spawn failed.
		let stdio_run = (ref, slot, op, cmd, opts, on_done) => {
			let entry = modem_of(ref);
			let logfile = (opts?.logf === false) ? null : (opts?.logf ?? ESIM_LOGF);
			let level_of = (type(opts?.log_level) == 'function') ? opts.log_level : () => 'notice';
			let logf = null;

			if (logfile) {
				let tr = fs.open(logfile, 'w'); if (tr) tr.close();   // truncate the log
				logf = fs.open(logfile, 'a');
			}

			// native spawn gives a non-blocking stdout + writable stdin; the
			// shell appends the process's stderr to the log. The __EXIT marker
			// carries the exit status IN-BAND: uloop's SIGCHLD handler reaps all
			// children, so h.close()'s waitpid can lose the race and not know
			// the status (returns null) — the marker line is then the only
			// reliable source. (No exec: the shell must survive the process to
			// echo the marker.) The marker's own stderr is dropped: an aborted
			// run (inactivity timeout) closes the pipe under the shell, and its
			// "echo: I/O error" would reach the log as a wwand error.
			let qmit = require('wwand_io');
			let h = qmit.spawn([ '/bin/sh', '-c',
				sprintf("mkdir -p /tmp/wwand; %s; echo \"__EXIT:$?\" 2>/dev/null", cmd) ]);

			if (!h) { if (logf) logf.close(); return null; }

			log('notice', sprintf('modem %s: esim[%s]: stdio bridge', ref, op));

			let chan = 0, uh = null, buf = '';

			// protocol-level lines (results, progress, bridge errors) always
			// reach the syslog; the process's own chatter at opts.log_level
			let logline = (s, level) => {
				if (logf) { logf.write(s + '\n'); logf.flush(); }
				log(level ?? 'notice', sprintf('modem %s: esim[%s]: %s', ref, op, s));
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

			let wq_write = (line) => {
				if (wdead)
					return;

				wq += line;

				if (!wtimer)
					pump();
			};

			let send = (ecode, data) =>
				wq_write(sprintf('{"type":"apdu","payload":{"ecode":%d,"data":"%s"}}\n', ecode, data ?? ''));
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
				// THE MARKER FIRST. close() reports the SHELL's status, and the
				// shell's last command is the marker's echo, so a clean run of
				// the shell reads 0 whatever the child exited with; the child's
				// own status exists only in-band. (close() also returns null
				// when uloop reaped the shell first.) lpac never showed this —
				// its verdict is its result line — but for a session_run process the exit
				// status IS the verdict. With neither (shell killed) the
				// missing result is the caller-visible failure, so don't
				// fabricate an error here.
				let closed = h.close();
				let ec = inband_ec ?? closed ?? 0;
				if (logf) { logf.close(); logf = null; }
				on_done(err ?? (ec == 0 ? null : { error: 'lpac', code: ec }),
					logfile ? trim(fs.readfile(logfile) ?? '') : '');
			};

			// dispatch a classified lpac line (parse_lpac_line above). APDU ops
			// dispatch async (reply written when the modem answers); the rest log.
			let handle_line = (s) => {
				let rec = parse_lpac_line(s);

				if (rec == null)
					return;

				if (rec.kind == 'log')
					return logline(rec.text, level_of(rec.text));

				if (rec.kind == 'event') {
					// The process now waits on the HOST, possibly for minutes
					// (a SIM reset and a reconnect), and says nothing meanwhile.
					// That silence is not a hang, so the inactivity watchdog is
					// off until the answer is written.
					idle?.cancel();

					let reply = (obj) => {
						if (done)
							return;

						idle?.set(idle_ms);
						wq_write(sprintf('{"type":"event","payload":%J}\n', obj ?? {}));
					};

					if (type(opts?.on_event) == 'function')
						return opts.on_event(rec, reply);

					logline(sprintf('event %s with nobody to handle it', rec.event ?? '?'));
					return reply({ online: false });
				}

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
				logline(sprintf('timeout: no output from %s for %d s - aborting',
					op, idle_ms / 1000));
				finish({ error: 'timeout', code: -1 });
			});

			return h;
		};

		// spawn lpac for a host-side op (download / chip / notif-list /
		// notif-process / enable / disable / delete); on_done(err, log).
		// Returns false when no lpac is installed, null when the spawn failed.
		let lpac_run = (ref, slot, op, code, conf, on_done) => {
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

			return stdio_run(ref, slot, op,
				sprintf('env LPAC_APDU=stdio LPAC_HTTP=curl %s %s 2>>%s', lpac, cmd, ESIM_LOGF),
				null, on_done);
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
				// a failed run can have installed the profile before failing
				// (the ack is a separate step) — re-read either way
				changed(ref, slot);
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
		// the re-read finishes in the background.
		//
		// THE DATA SESSION is put back on the normal transient-loss path — a
		// sentence that stood here for months claiming it came back, while
		// nothing started it. The running context kept a PDP session belonging
		// to the profile just switched away from, so it never went down and
		// never re-dialled; the connection returned when somebody pressed
		// Reconnect (patrakov on a Fibocom, OpenWrt forum 2026-09-22).
		//
		// The re-read below emits `sim_refresh`, and daemon.modem_sim_refresh
		// drops the stale session and enters the reconnect when the identity
		// actually changed. Put ON the path, not guaranteed to arrive: that
		// path retries with a backoff and gives up at hold_max, handing over to
		// the registration path — see the comment there for what that does and
		// does not promise.
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

		// A host session of some other process on the card, for a plugin (an
		// SGP.32 IoT Profile Assistant is the one there is). It speaks the same
		// stdio protocol and is one more session on the card's ISD-R, so it
		// takes the same exclusive claim as an lpac profile operation — never
		// two host sessions on one eUICC at once. Quiet mode is held for the
		// run and DROPPED while the host handles an event (an assistant waits
		// there for the connection to come back after a profile change, and
		// the reconnect is exactly what the background polls quiet mode holds
		// back are for). on_done(err, log); returns { error: 'busy' } or
		// { error: 'spawn' } when it did not start.
		let session_run = (ref, slot, label, cmd, log_level, on_event, on_done) => {
			let entry = modem_of(ref);

			if (dl?.state == 'running' || mgmt_busy)
				return { error: 'busy' };

			mgmt_busy = true;

			let release = quiet_claim(entry?.modem);
			let finished = false;

			let p = stdio_run(ref, slot, label, cmd, {
				logf: false,
				log_level: log_level,
				on_event: (rec, reply) => {
					release();
					parked = { ref: ref, slot: slot };

					// an answer that arrives after the process died must not
					// raise a claim nothing will ever drop
					on_event(rec, (obj) => {
						if (finished)
							return;

						parked = null;
						release = quiet_claim(entry?.modem);
						reply(obj);
					});
				},
			}, (err, out) => {
				finished = true;
				parked = null;
				mgmt_busy = false;
				release();
				on_done(err, out);
			});

			if (!p) {
				mgmt_busy = false;
				release();
				return { error: 'spawn' };
			}

			return null;
		};

		// A download on behalf of the session that is waiting in an event: an
		// SGP.32 assistant's direct download (SGP.32 v1.3 3.2.3.1), which only
		// the host's ES9+ client can do. That session holds the card
		// (mgmt_busy) and is parked with its own channel closed, so the
		// download runs under its claim instead of being refused as busy —
		// and only then: outside such a wait it is refused. The install
		// notification stays on the card (no auto notify), because the
		// assistant reports the PIR to its eIM itself. cb(err, dl) when the
		// run has ENDED, not when it starts.
		let session_download = (ref, code, conf, cb) => {
			if (parked?.ref != ref)
				return cb({ error: 'no_session' });

			if (dl?.state == 'running')
				return cb({ error: 'busy' });

			if (!length(code ?? '') || !codes_ok(code, conf))
				return cb({ error: 'invalid_argument' });

			let answered = false;
			let answer = (err, res) => {
				if (answered)
					return;

				answered = true;
				cb(err, res);
			};
			let q = quiet_claim(modem_of(ref)?.modem);

			download_lpac(ref, parked.slot, code, conf,
				(err) => { if (err) answer(err); },
				false,
				() => {
					q();
					answer((dl?.state == 'done') ? null : { error: 'download_failed', code: dl?.code }, dl);
				});
		};

		return {
			session_run: session_run,
			session_download: session_download,

			// a host session is on the card (a download, a profile change,
			// a plugin's run, one parked in an event): another one beside it
			// would corrupt it — a caller that can wait, waits
			busy: () => (dl?.state == 'running' || mgmt_busy || parked != null),

			// after a profile change the modem has to re-read the card; the
			// same apply as an lpac enable (see apply_sim_reset above)
			apply_sim_reset: (ref, slot, cb) => {
				let entry = modem_of(ref);

				if (!entry?.modem)
					return cb({ error: 'no_such_modem' });

				apply_sim_reset(ref, entry, slot, {}, cb);
			},

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
					if (!codes_ok(code, params?.confirmation_code))
						return done({ error: 'invalid_argument' });

					// standard: acknowledge the install to the operator afterwards;
					// callers pass auto_notify=false only for testing
					let auto_notify = params?.auto_notify ?? true;

					// CLAIM BEFORE THE ASYNCHRONOUS LOOKUP, not after it.
					//
					// The guard above checked `dl?.state == 'running' ||
					// mgmt_busy` and then handed control to esim.backend(),
					// which answers on a later turn — and only its callback set
					// dl to running. Anything entering that window passed the
					// same guard: a second download, or the notification list,
					// which starts its own lpac and truncates the shared log
					// this run reads its verdict from. Reserving here closes
					// it, and the callback below refines the record rather
					// than creating it. Placed after every validation return,
					// so nothing can leave with the claim raised.
					dl = { state: 'running', via: 'starting' };

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
								changed(ref, slot);
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
				case 'notifications': {
					// THE ONLY lpac OP WITHOUT A CLAIM, and it is not harmless
					// for being read-only: lpac_run TRUNCATES the shared
					// ESIM_LOGF on every start (stdio_run) and opens its own APDU
					// stream to the ISD-R. Listing notifications during a
					// download therefore destroyed the log the download's own
					// completion handler reads its verdict from — a profile
					// that installed correctly was reported 'failed' and never
					// auto-notified — while a second host session talked to the
					// eUICC at the same time. Every sibling op refuses instead
					// (profile_op_lpac, session_run, the download case, 'notify'
					// below).
					if (dl?.state == 'running' || mgmt_busy)
						return done({ error: 'busy' });

					mgmt_busy = true;

					let np = lpac_run(ref, slot, 'notif-list', '', '', (err, out) => {
						mgmt_busy = false;
						done(err ? { error: 'lpac', ...err } : null, { ok: !err, log: out });
					});

					// lpac_run returns false for "no binary" and null for a
					// failed spawn; reporting both as esim_not_installed sent
					// an operator looking for a package that is already there.
					if (np === false) {
						mgmt_busy = false;

						return done({ error: 'esim_not_installed' });
					}

					if (!np) {
						mgmt_busy = false;

						return done({ error: 'esim', detail: { error: 'spawn' } });
					}

					return;
				}

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
						if (!err)
							changed(ref, slot);

						// enable/disable change the active profile — the modem
						// must re-read the card; delete only removes a disabled
						// profile, nothing to apply
						if (err || op == 'delete')
							return done(err, res);
						apply_sim_reset(ref, entry, slot, res, done);
					}, () => {
						let after = (err, res) => {
							if (!err)
								changed(ref, slot);
							done(err, res);
						};

						if (op == 'enable')
							return esim.enable(entry.modem, slot, iccid, (err, res) => {
								if (!err)
									log('notice', sprintf('modem %s: eSIM profile %s enabled', ref, iccid));
								after(err, res);
							});
						if (op == 'disable')
							return esim.disable(entry.modem, slot, iccid, after);
						return esim.del(entry.modem, slot, iccid, after);
					});
				}
				default:
					return done({ error: 'invalid_op', op: op });
				}
			},
		};
	},
};
