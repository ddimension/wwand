// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand-ipa — the eIM side of an eSIM fleet (GSMA SGP.32).
//
// An eIM is the operator's fleet server: it queues eUICC packages (download
// this profile, enable that one, delete another) and the IoT Profile Assistant
// on the device fetches and executes them. The assistant here is onomondo-ipa
// (AGPL, a separate program: /usr/lib/wwand/ipad from the feed's wwand-ipad
// package), built with a card backend that speaks lpac's stdio protocol, so
// esim_bridge relays its APDUs over the modem's own channel exactly as it does
// for lpac. This module decides WHEN it runs and does what only the host can:
// make the modem use a profile the eIM has just switched to.
//
// Two facts shape it:
// - onomondo-ipa implements SGP.32 v1.0 and is always run in its IoT eUICC
//   EMULATION mode (-E) here, which drives an ordinary SGP.22 consumer eUICC —
//   the cards wwand-esim already manages. In that mode the eIM configuration
//   and the replay counter live in the assistant's nvstate file, not on the
//   card; that file is keyed by EID below and must survive an upgrade, hence
//   /etc. The eIM has to accept emulation-mode results: their signature is a
//   placeholder (onomondo-ipa es10b_load_euicc_pkg.c:550, commit 6aaeb38,
//   2026-09-01).
// - A profile change is finished only when the modem runs the new profile AND
//   the result has reached the eIM over it. The assistant cannot do the first
//   part, so it hands it to us (event `profile_changed`) and waits; if the eIM
//   stays unreachable it rolls the profile back itself on its next poll, and
//   hands that change to us the same way.
//
// Exportless plain script (like esim_bridge): require() returns the API.

'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';

const IPAD = '/usr/lib/wwand/ipad';
const STATE_DIR = '/etc/wwand/ipa';

// seconds; every one overridable through deps.timing for the tests
const TIMING = {
	// online this long before the first poll, so the poll does not race the
	// rest of bring-up (renew, firewall, a DNS that is not answering yet)
	settle: 60,
	// ...plus up to this much more, different per device (see spread_of): a
	// fleet that comes back from one power cut must not reach the eIM in the
	// same second
	settle_spread: 300,
	// after a failed run: soon enough to catch an eIM that was briefly away,
	// rare enough not to hammer one that is down
	retry: 600,
	// after a profile change: how long the SIM reset plus reconnect may take
	// before the assistant is told the connection is not back. A generous
	// bound, not a measurement: a new profile may first have to register on a
	// network the modem has not seen, and answering too early costs a rollback
	// the eIM did not ask for.
	online_timeout: 300,
	// how often the connection is checked while waiting for it
	online_poll: 5,
};

const INTERVAL_DEFAULT = 3600;
const INTERVAL_MIN = 300;

// Arguments land in a shell command line. Each is checked against what it can
// legitimately be, and refused otherwise — quoting alone would still let a
// quote character through.
let safe_path = (p) => type(p) == 'string' && match(p, /^\/[A-Za-z0-9._\/-]+$/) && !match(p, /\.\./);
let safe_id = (s) => type(s) == 'string' && match(s, /^[A-Za-z0-9._:-]+$/);

// The TAC is the first 8 digits of the IMEI (3GPP TS 23.003 6.2.1). The eIM may
// use it to tell device models apart; the assistant's own default is a
// placeholder, so the real one is passed whenever the modem reported an IMEI.
function tac_of(imei)
{
	return (type(imei) == 'string' && match(imei, /^[0-9]{14,16}$/)) ? substr(imei, 0, 8) : null;
}

function interval_of(cfg)
{
	let n = +(cfg?.ipa_interval ?? INTERVAL_DEFAULT);

	if (n != n || n <= 0)
		n = INTERVAL_DEFAULT;

	return (n < INTERVAL_MIN) ? INTERVAL_MIN : n;
}

// When the next run is due: null while offline. The first run waits for the
// connection to settle; later ones follow the interval, or the shorter retry
// after a failure.
// A fixed fraction in [0, 1) per device, from its IMEI (FNV-1a). The whole
// point is that two routers get different values; being FIXED rather than
// random keeps one router's rhythm the same across restarts and makes the
// schedule testable. No IMEI: 0, i.e. no spread, which is also where every
// router stood before.
function spread_of(key)
{
	if (type(key) != 'string' || !length(key))
		return 0;

	let h = 2166136261;

	for (let i = 0; i < length(key); i++)
		h = ((h ^ ord(key, i)) * 16777619) % 4294967296;

	return (h % 10000) / 10000.0;   // .0: an integer division here is always 0
}

// When the next run is due: null while offline.
// - first run: after the settle time plus this device's share of the spread
// - after a good run: the interval, stretched by up to a tenth per device so
//   a fleet started together drifts apart instead of polling in lockstep
// - after failures: the retry time, doubled per consecutive failure (an eIM
//   that is down should not see the whole fleet every ten minutes), never
//   beyond the interval
function due(st, cfg, timing)
{
	let t = { ...TIMING, ...(timing ?? {}) };
	let sp = st?.spread ?? 0;

	if (st?.online_since == null)
		return null;

	if (st.last_end == null)
		return st.online_since + t.settle + int(t.settle_spread * sp);

	let iv = interval_of(cfg);

	if (st.last_ok)
		return st.last_end + iv + int(iv / 10 * sp);

	let back = t.retry;

	for (let i = 1; i < (st.fails ?? 1) && back < iv; i++)
		back *= 2;

	return st.last_end + ((back < iv) ? back : iv);
}

// The assistant's command line. Always -E (a consumer eUICC, see the header)
// and -H (profile changes go to the host). `init_cfg` makes it a provisioning
// run: it stores the eIM configuration (an AddInitialEimRequest, BER) in the
// nvstate and exits.
//
// stderr (its log) goes into the protocol pipe, 2>&1: the bridge takes every
// line that is not protocol JSON as a log line, and log_level below maps it
// onto wwand's own levels. So the assistant's log is in the syslog, filtered
// by wwand's log level, with no file of its own to find or rotate.
function build_cmd(o)
{
	let parts = [ o.ipad ?? IPAD, '-E', '-H', '-n', sprintf("'%s'", o.nvstate) ];

	if (o.tac)
		push(parts, '-t', o.tac);

	if (o.eim_id)
		push(parts, '-e', sprintf("'%s'", o.eim_id));

	if (o.insecure)
		push(parts, '-I');

	if (o.init_cfg)
		push(parts, '-f', sprintf("'%s'", o.init_cfg));

	return sprintf('%s 2>&1', join(' ', parts));
}

// The syslog level for one line of the assistant's log. Its format is
// "%8s %8s " subsystem and level, then the message (onomondo-ipa
// libipa/log.c:69, levels ERROR/INFO/DEBUG at :40-43, commit 6aaeb38,
// 2026-09-01).
// ERROR goes to warn, not err: an eIM that is briefly unreachable logs ERROR
// on every retry, and that is a condition, not a fault of the router.
// Anything else (main.c's printf of its parameters) is debug.
function log_level(line)
{
	let m = match(line ?? '', /^ *[A-Za-z0-9]+ +(ERROR|INFO|DEBUG) /);

	if (!m)
		return 'debug';

	return { ERROR: 'warn', INFO: 'info', DEBUG: 'debug' }[m[1]];
}

return {
	// exposed for tests (test_ipa)
	tac_of: tac_of,
	spread_of: spread_of,
	interval_of: interval_of,
	due: due,
	build_cmd: build_cmd,
	log_level: log_level,

	// deps: { bridge (an esim_bridge instance), esim (wwand.esim), log,
	//         modem_of(ref), online(ref) -> a token for the current connection
	//         generation, or null while not connected,
	//         refresh(ref, eid, slot, cb(profiles)) -> re-read the card's
	//         profile list into status, then hand it to cb,
	//         modem_reset(ref, cb) -> the daemon's modem reset (hwops) }
	// test seams: ipad_path, state_dir, timing, now(), exists(path)
	create: function(deps) {
		let log = deps.log;
		let ipad = deps.ipad_path ?? IPAD;
		let dir = deps.state_dir ?? STATE_DIR;
		let timing = { ...TIMING, ...(deps.timing ?? {}) };
		let now = deps.now ?? (() => time());
		let exists = deps.exists ?? ((p) => fs.access(p) == true);
		let states = {};

		let state_of = (ref) => {
			if (!states[ref])
				states[ref] = { state: 'idle', seq: 0, runs: 0, profile_changes: 0 };

			return states[ref];
		};

		let slot_of = (cfg) => ((+(cfg?.sim_slot ?? 0)) > 0) ? +cfg.sim_slot : 1;

		// The card to manage is the ACTIVE eUICC, which on a dual-SIM module is
		// not necessarily the configured slot (the FM350's eUICC sits in SUB2).
		// Asked the way the daemon's esim_ready read asks it (daemon.uc,
		// `esim_ready`); a modem that cannot list its slots, or lists no active
		// eUICC, gets the configured slot — the one it always got.
		let pick_slot = (modem, cfg, cb) => {
			if (type(modem?.slot_status) != 'function')
				return cb(slot_of(cfg));

			modem.slot_status((err, slots) => {
				let e = filter(slots ?? [], (s) => s.is_euicc && s.active)[0];

				cb((!err && e?.physical != null) ? +e.physical : slot_of(cfg));
			});
		};

		// the one place a run ends; everything else only returns into it
		let finish = (ref, st, ok, error, cb) => {
			st.seq++;   // anything still pending from this run is stale now
			st.state = 'idle';
			st.last_end = now();
			st.last_ok = ok;
			st.last_error = ok ? null : error;
			st.fails = ok ? 0 : (st.fails ?? 0) + 1;
			st.runs++;

			if (ok)
				log('info', sprintf('modem %s: ipa: poll done', ref));
			else
				log('warn', sprintf('modem %s: ipa: run failed (%s)', ref, error ?? '?'));

			// The assistant may have installed, deleted or switched profiles
			// without the host seeing which, so the card's list in status is
			// read again after every run that reached the card — failed ones
			// too, a package can fail halfway.
			//
			// The list is also how installs and deletions become visible at
			// all: the assistant reports neither, and the eIM package result
			// it sends carries codes, not ICCIDs (onomondo-ipa
			// es10b_load_euicc_pkg.h, commit 6aaeb38, 2026-09-01). So the
			// list from before the run is compared with the one after it.
			if (st.reached_card && type(deps.refresh) == 'function') {
				let before = st.profiles_before;
				let changes = st.changes;

				deps.refresh(ref, st.eid, st.slot, (profiles) => {
					let now_ids = map(profiles ?? [], (p) => p.iccid);

					// no list from before (never read on this modem): nothing
					// to compare, and reporting every profile as installed
					// would be a lie
					if (before != null) {
						changes.installed = filter(now_ids, (i) => index(before, i) < 0);
						changes.deleted = filter(before, (i) => index(now_ids, i) < 0);
					}

					for (let i in changes.installed ?? [])
						log('notice', sprintf('modem %s: ipa: profile %s installed by the eIM', ref, i));

					for (let i in changes.deleted ?? [])
						log('notice', sprintf('modem %s: ipa: profile %s deleted by the eIM', ref, i));
				});
			}

			st.last_changes = st.changes;
			st.reached_card = false;

			cb?.(ok ? null : { error: 'ipa', detail: error }, null);
		};

		// A profile change inside the run: reset the SIM so the modem takes the
		// new profile, then wait for a NEW connection. Waiting for "online"
		// alone would return at once — the old session is still CONNECTED
		// until the daemon notices the identity change and drops it — so it
		// waits for the connection generation to move.
		let on_profile_changed = (ref, st, slot, reply) => {
			let before = deps.online(ref);
			let deadline = now() + timing.online_timeout;

			// THIS run's wait. The assistant can die while we wait (the bridge
			// kills a run, or it crashes); finish() then moves seq on, and a
			// timer firing afterwards must not put the scheduler back into
			// 'running' — nothing would ever end that run, and every later
			// poll would be refused as busy.
			let mine = st.seq;
			let live = () => st.seq == mine;

			st.state = 'waiting_online';
			st.profile_changes++;

			// which profile this was, by the modem's own reading of the card:
			// the ICCID now, and the one after the SIM reset below. A switch
			// back to where the run started is the assistant's rollback.
			let from = deps.modem_of(ref)?.modem?.info?.iccid;
			log('notice', sprintf('modem %s: ipa: the eIM changed the active profile — resetting the SIM and waiting for the connection', ref));

			let answer = (online) => {
				if (!live())
					return;

				st.state = 'running';

				// looked up NOW, not the object from the event: a modem reset
				// (below) replaces the modem object, and the old one never
				// learns the new ICCID
				let to = deps.modem_of(ref)?.modem?.info?.iccid;
				let rollback = (to != null && to == st.iccid_at_start && length(st.changes.switched) > 0);

				push(st.changes.switched, { from: from, to: to, rollback: rollback });
				log('notice', sprintf('modem %s: ipa: %s %s -> %s', ref,
					rollback ? 'profile rolled back' : 'profile switched', from ?? '?', to ?? '?'));

				log(online ? 'notice' : 'warn', sprintf('modem %s: ipa: connection %s after the profile change%s',
					ref, online ? 'back' : 'NOT back', online ? '' : ' — the assistant will roll back if the eIM stays unreachable'));
				reply({ online: online });
			};

			deps.bridge.apply_sim_reset(ref, slot, (err, res) => {
				if (err)
					log('warn', sprintf('modem %s: ipa: SIM reset failed (%J)', ref, err));

				// The SIM power cycle did not happen, and the apply falls back to
				// a modem reset (esim_bridge apply_sim_reset). In LuCI a person
				// presses that button; here nobody would, and the modem would
				// keep the OLD profile until the assistant gave up and rolled
				// back a switch that may well have worked. So do it.
				if (res?.apply == 'modem_reset' && type(deps.modem_reset) == 'function') {
					log('warn', sprintf('modem %s: ipa: the SIM could not be reset — resetting the modem to take the new profile', ref));
					deps.modem_reset(ref, (rerr) => {
						if (rerr)
							log('warn', sprintf('modem %s: ipa: modem reset failed too (%J) — the modem may keep the old profile', ref, rerr));
					});
				}

				let check;
				check = () => {
					if (!live())
						return;

					let tok = deps.online(ref);

					if (tok != null && tok !== before)
						return answer(true);

					// Still the pre-reset session (or none) at the deadline is
					// NOT back: a profile change always drops the old session,
					// because the daemon sees the ICCID change
					// (daemon.modem_sim_refresh). Reporting it as
					// online would send the result over the old profile.
					if (now() >= deadline)
						return answer(false);

					uloop.timer(timing.online_poll * 1000, check);
				};

				uloop.timer(timing.online_poll * 1000, check);
			});
		};

		let run = (ref, cfg, why, cb) => {
			let entry = deps.modem_of(ref);
			let st = state_of(ref);

			if (!entry?.modem)
				return cb?.({ error: 'no_such_modem' }, null);

			if (st.state != 'idle')
				return cb?.({ error: 'busy' }, null);

			if (!exists(ipad))
				return cb?.({ error: 'ipa_not_installed', detail: sprintf('%s is missing (package wwand-ipad)', ipad) }, null);

			let init_cfg = cfg?.ipa_eim_config;
			let eim_id = cfg?.ipa_eim_id;

			if (init_cfg != null && !safe_path(init_cfg))
				return cb?.({ error: 'invalid_argument', detail: 'ipa_eim_config' }, null);

			if (eim_id != null && !safe_id(eim_id))
				return cb?.({ error: 'invalid_argument', detail: 'ipa_eim_id' }, null);

			let slot = slot_of(cfg);

			st.state = 'running';
			st.last_start = now();
			st.why = why;
			st.slot = slot;
			st.reached_card = false;
			st.iccid_at_start = entry.modem.info?.iccid;
			st.profiles_before = (type(entry.modem.esim_info?.profiles) == 'array')
				? map(entry.modem.esim_info.profiles, (p) => p.iccid) : null;
			st.changes = { switched: [], installed: null, deleted: null };
			log('info', sprintf('modem %s: ipa: polling the eIM (%s)', ref, why));

			pick_slot(entry.modem, cfg, (picked) => {
				slot = picked;
				st.slot = picked;

				deps.esim.get_eid(entry.modem, slot, (err, res) => {
					let eid = uc(res?.eid ?? '');

					if (err || !match(eid, /^[0-9A-F]{32}$/))
						return finish(ref, st, false, 'no_eid', cb);

					st.eid = eid;

					// keyed by EID: the nvstate belongs to the CARD. Keyed by modem, a
					// swapped card would inherit the previous card's eIM trust.
					let nv = sprintf('%s/%s.nvstate', dir, eid);
					let provision = !exists(nv);

					if (provision && init_cfg == null)
						return finish(ref, st, false, 'no_eim_config', cb);

					if (provision && !exists(init_cfg))
						return finish(ref, st, false, 'eim_config_missing', cb);

					let step;
					step = (phase) => {
						let cmd = sprintf('mkdir -p %s && %s', dir, build_cmd({
							ipad: ipad, nvstate: nv,
							tac: tac_of(entry.modem.info?.imei),
							eim_id: eim_id,
							insecure: !!cfg?.ipa_insecure,
							init_cfg: (phase == 'provision') ? init_cfg : null,
						}));

						// set BEFORE the call: the run may end inside it, and
						// finish() reads this; a refused start takes it back
						st.reached_card = true;

						let r = deps.bridge.ipa_run(ref, slot, cmd, log_level,
							(rec, reply) => {
								if (rec.event == 'profile_changed')
									return on_profile_changed(ref, st, slot, reply);

								log('warn', sprintf('modem %s: ipa: unknown event %s', ref, rec.event ?? '?'));
								reply({ online: false });
							},
							(rerr) => {
								if (rerr)
									return finish(ref, st, false,
										(rerr.error == 'lpac') ? sprintf('exit %d', rerr.code ?? -1) : (rerr.error ?? 'error'), cb);

								if (phase == 'provision') {
									log('notice', sprintf('modem %s: ipa: eIM configuration stored for card %s', ref, eid));
									return step('poll');
								}

								finish(ref, st, true, null, cb);
							});

						if (r) {
							st.reached_card = false;
							finish(ref, st, false, r.error, cb);
						}
					};

					step(provision ? 'provision' : 'poll');
				});
			});
		};

		return {
			// called from the daemon's 10 s status tick for every modem
			tick: function(ref, cfg) {
				if (!cfg?.ipa)
					return;

				let st = state_of(ref);

				if (deps.online(ref) == null) {
					st.online_since = null;
					return;
				}

				if (st.online_since == null)
					st.online_since = now();

				let imei = deps.modem_of(ref)?.modem?.info?.imei;

				if (st.spread == null && imei)
					st.spread = spread_of(imei);

				if (st.state != 'idle')
					return;

				let d = due(st, cfg, timing);

				if (d != null && now() >= d)
					run(ref, cfg, 'schedule', null);
			},

			// ubus modem_ipa { op: 'poll' }: run now. The answer comes when the
			// run has started or been refused; the outcome is in status.
			poll: function(ref, cfg, cb) {
				let started = false;

				run(ref, cfg, 'request', (err, res) => {
					if (!started)
						cb(err, res);
				});

				if (state_of(ref).state != 'idle') {
					started = true;
					cb(null, { started: true });
				}
			},

			status: function(ref, cfg) {
				let st = state_of(ref);

				return {
					// the daemon's clock, which every timestamp here is on:
					// a browser computing "5 min ago" from its own clock is
					// off by whatever the two disagree
					now: now(),
					enabled: !!cfg?.ipa,
					state: st.state,
					eid: st.eid,
					runs: st.runs,
					profile_changes: st.profile_changes,
					last_start: st.last_start,
					last_end: st.last_end,
					last_ok: st.last_ok,
					last_error: st.last_error,
					fails: st.fails ?? 0,
					// what the last run did to the card: profile switches
					// ({ from, to, rollback }), and the ICCIDs it installed
					// and deleted (null when there was no list to compare)
					last_changes: st.last_changes,
					next_due: cfg?.ipa ? due(st, cfg, timing) : null,
					interval: interval_of(cfg),
					nvstate: st.eid ? exists(sprintf('%s/%s.nvstate', dir, st.eid)) : null,
				};
			},
		};
	},
};
