// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — protocol-neutral helpers shared by the QMI/MBIM/NCM modem state
// machines (operate on the modem `self` object).

'use strict';

import * as uloop from 'uloop';
import * as atcmd from 'wwand.atcmd';
import * as protoswitch from 'wwand.protocol_switch';
import * as recovery_mod from 'wwand.recovery';
import * as netlink from 'wwand.netlink';
import * as tlv from 'wwand.codec.tlv';
import * as nasmod from 'wwand.codec.schema.nas';
import * as ratmod from 'wwand.codec.schema.rat';
import * as merge from 'wwand.codec.schema.merge';
import * as arfcn_bands from 'wwand.codec.arfcn_bands';
import * as discovery from 'wwand.discovery';

// scrub NAS cell-info sentinel metrics (-32768 = "not measured") to null so
// consumers never render the sentinel as a real dBm value.
export function clean_cell_metrics(cells)
{
	let scrub = (c) => {
		for (let f in [ 'rsrp', 'rsrq', 'rssi', 'srxlev', 'snr' ])
			if (c[f] == tlv.SENTINEL.i16)   // only the actual sentinel, not absent keys
				c[f] = null;
	};

	for (let c in (cells?.lte_intra?.cells ?? []))
		scrub(c);

	for (let fr in (cells?.lte_inter?.freqs ?? []))
		for (let c in (fr.cells ?? []))
			scrub(c);

	if (cells?.nr5g_cell)
		scrub(cells.nr5g_cell);

	return cells;
};

// serving_still_current(serving, cells): does a carried-over `serving` object
// (from an AT +QENG read) still describe the serving cell that `cells` (from a
// NAS/passthrough/native cell-location read) reports? Compares the LTE EARFCN,
// then the NR ARFCN; if neither side carries a comparable identity, keep it
// (conservative). A handover between the two reads makes them disagree.
function serving_still_current(serving, cells)
{
	let le = serving.lte?.earfcn, nle = cells?.lte_intra?.earfcn;
	if (le != null && nle != null)
		return le == nle;

	let ne = serving.nr?.arfcn, nne = cells?.nr5g_arfcn;
	if (ne != null && nne != null)
		return ne == nne;

	return true;
};

// preserve_serving(newc, oldc): carry the AT-`+QENG`-derived `serving` (which
// alone carries LTE/NR `band` + `bandwidth_mhz`) forward across a cells refresh
// that came from a band-less transport (NAS / MBIM passthrough / native MBIM).
// Only fills when the new object lacks `serving` (gap) AND the old serving still
// describes the current serving cell (identity guard) — a handover drops the
// stale band instead of mislabelling it. Without this, `serving.band` is only
// re-read on the slow loop, so band flickers out during 1 s LuCI polling on
// backends whose fast loop refreshes cells but not the serving detail (MBIM).
// Returns newc. Mirrors the existing `cells.ca` carry-over.
export function preserve_serving(newc, oldc)
{
	if (newc == null || oldc?.serving == null)
		return newc;

	return merge.fill(newc, oldc, {
		gap:   [ 'serving' ],
		guard: (dst, src) => serving_still_current(src.serving, dst),
	});
};

// serving_from_ca(self): the QMI LTE-CPHY CA-info PCC (self.cells.ca[role=PCC])
// IS the serving LTE cell and — unlike the cell-location decode — carries the
// channel BANDWIDTH (dl_bandwidth). It reaches every QMI/MBIM modem over the
// (passthrough) QMI stack, so this is the VENDOR-NEUTRAL bandwidth source: no AT
// parser, works on Fibocom/Foxconn/Sierra/… all the same. Gap-fill serving.lte
// from it (a Quectel AT-QENG value already there wins), EARFCN-guarded; seeds
// serving.lte when the modem has no AT serving read. The BAND is left to EARFCN
// derivation (LuCI, disjoint ranges) / AT-QENG — the QMI CA `band` TLV is the
// non-3GPP ActiveBand enum. LTE only (there is no NR CPHY CA info).
export function serving_from_ca(self)
{
	let ca = self.cells?.ca;

	if (!self.cells || type(ca) != 'array')
		return;

	let pcc = null;
	for (let c in ca)
		if (c?.role == 'PCC') { pcc = c; break; }

	if (!pcc || pcc.bandwidth_mhz == null)
		return;

	self.cells.serving = self.cells.serving ?? {};
	self.cells.serving.lte = merge.fill(self.cells.serving.lte, pcc, {
		src:   'qmi-ca',
		gap:   [ 'bandwidth_mhz', 'earfcn', 'pci' ],
		guard: (dst, src) => dst.earfcn == null || src.earfcn == null || dst.earfcn == src.earfcn,
	});
};

// fill_serving_band(self): gap-fill serving.lte.band / serving.nr.band from the
// serving-cell EARFCN / NR-ARFCN when no vendor source (AT +QENG, QMI CA-info)
// already named the band. For the band-less transports (native MBIM on Intel /
// MediaTek modems) this is the ONLY band source. Call AFTER serving_from_ca so a
// real vendor band always wins — band is only ever set when currently absent.
// The serving EARFCN comes from cells.serving.lte.earfcn (seeded by
// serving_from_ca / AT) or, failing that, the serving cell-info earfcn
// (cells.lte_intra.earfcn); NR from cells.nr5g_arfcn.
export function fill_serving_band(self)
{
	let cells = self.cells;

	if (!cells)
		return;

	let earfcn = cells.serving?.lte?.earfcn ?? cells.lte_intra?.earfcn;
	let arfcn  = cells.serving?.nr?.arfcn ?? cells.nr5g_arfcn;

	if (earfcn != null) {
		let d = arfcn_bands.lte_band(earfcn);
		if (d?.band != null) {
			cells.serving = cells.serving ?? {};
			cells.serving.lte = cells.serving.lte ?? {};
			cells.serving.lte.earfcn ??= earfcn;
			cells.serving.lte.band ??= d.band;
			cells.serving.lte.dl_freq_mhz ??= d.mhz;
		}
	}

	if (arfcn != null) {
		let d = arfcn_bands.nr_band(arfcn);
		if (d != null) {
			cells.serving = cells.serving ?? {};
			cells.serving.nr = cells.serving.nr ?? {};
			cells.serving.nr.arfcn ??= arfcn;
			if (d.band != null)
				cells.serving.nr.band ??= d.band;
			cells.serving.nr.dl_freq_mhz ??= d.mhz;
		}
	}
};

// manufacturers whose AT firmware answers AT+QENG (serving/neighbour cell). Gate
// the QENG reads on this so a non-Quectel modem (Fibocom, Foxconn, Sierra, Telit,
// SIMCom, …) is not sent an unsupported command every cycle — its band/bandwidth
// come from the vendor-neutral QMI CA-info (serving_from_ca) + EARFCN derivation.
// Defined before fetch_nr_neighbours, which calls it (ucode does not hoist exports).
const QENG_VENDORS = /quectel|asr/;

export function qeng_ok(self)
{
	return !!match(lc(sprintf('%s', self.info?.manufacturer ?? '')), QENG_VENDORS);
};

// `option gnss`: switch the receiver on so the NMEA port actually streams.
// Reporting the port (see open_at_tty) is only half of it — on most modems the
// port exists from boot and stays silent until GNSS is started, and the command
// that starts it is vendor AT, not QMI. So wwand does it, because wwand owns the
// AT port; what comes out of the NMEA port is then gpsd's business.
//
// Deliberately a small table, not a guess: an unknown vendor gets a log line and
// nothing sent. An AT command invented for a modem that does not know it is at
// best an ERROR and at worst a different command that firmware DOES implement.
const GNSS_START = [
	// Quectel (and the ASR-based modems that copy its AT set). "+CME ERROR: 504"
	// is "session is ongoing" — already running, which is success for us.
	{ vendors: /quectel|asr/, cmd: 'AT+QGPS=1', ok_errors: /504/ },
];

export function start_gnss(self, log, cb)
{
	cb = cb ?? (() => null);

	if (!self.config?.gnss || self.gnss_started)
		return cb(null);

	if (!self.at)
		return cb({ error: 'unsupported', detail: 'no at channel' });

	let mfr = lc(sprintf('%s', self.info?.manufacturer ?? ''));
	let recipe = null;

	for (let r in GNSS_START)
		if (match(mfr, r.vendors)) {
			recipe = r;
			break;
		}

	if (!recipe) {
		log('info', sprintf('option gnss is set but no GNSS start command is known for %J — leaving the receiver alone',
			self.info?.manufacturer ?? '?'));
		return cb({ error: 'unsupported', detail: 'unknown vendor' });
	}

	self.at.send(recipe.cmd, (err, res) => {
		let line = join(' ', res?.lines ?? []);
		let already = err && recipe.ok_errors && match(line, recipe.ok_errors);

		if (err && !already) {
			log('warn', sprintf('gnss: %s failed: %J', recipe.cmd, err));
			return cb(err);
		}

		// latch only on success, so a failed start is retried on the next
		// bring-up instead of being remembered as done
		self.gnss_started = true;
		log('notice', sprintf('gnss: receiver on (%s)%s%s', recipe.cmd,
			already ? ' — was already running' : '',
			self.gps_tty ? sprintf(', NMEA on %s', self.gps_tty) : ''));
		cb(null);
	}, { timeout: 10000 });
};

export function dsd_from_serving(serving)
{
	let lte = serving?.lte != null;
	let nr  = serving?.nr != null;
	let mode = nr ? (serving.nr.mode ?? (lte ? 'NSA' : 'SA')) : (lte ? 'LTE' : null);

	return mode ? { mode: mode, lte: lte, nr: nr } : null;
};

// convert a QMI NAS Network-Time "Universal Time" struct (already UTC) to a Unix
// epoch, or null if absent/implausible. QMI months are 1-based (as timegm()
// expects). Guards against a modem pushing a zeroed NITZ frame before it has a
// real network time.
export function nitz_epoch(ut)
{
	if (ut?.year == null || ut.year < 2000 || ut.year > 2200 ||
	    ut.month == null || ut.month < 1 || ut.month > 12)
		return null;

	return timegm({
		year: ut.year, mon: ut.month, mday: ut.day ?? 1,
		hour: ut.hour ?? 0, min: ut.minute ?? 0, sec: ut.second ?? 0,
	});
};

// parse a Fibocom T700 +CTZV NITZ URC line into { epoch, tz_offset_min } —
// the NCM backend's equivalent of the QMI NETWORK_TIME_IND feed. The payload
// is `+CTZV: "yy/MM/dd,hh:mm:ss±qq"` with the timezone in QUARTER HOURS
// (+32 = +8h), like the QMI timezone_offset field. null on any implausible
// frame (the modem can push a zeroed NITZ before it has real network time).
export function nitz_ctzv(line)
{
	let m = match(line, /^\+CTZV:\s*"([0-9]{2})\/([0-9]{2})\/([0-9]{2}),([0-9]{2}):([0-9]{2}):([0-9]{2})([+-][0-9]+)"/);

	if (!m)
		return null;

	let epoch = nitz_epoch({
		year: 2000 + +m[1], month: +m[2], day: +m[3],
		hour: +m[4], minute: +m[5], second: +m[6],
	});

	return (epoch != null) ? { epoch: epoch, tz_offset_min: +m[7] * 15 } : null;
};

// derive a coarse mode from NAS radio interfaces (last-resort fallback; can't
// see NSA — an NSA anchor reports LTE only here). radio_ifs: 8=LTE, 12=5GNR.
// Backend-neutral URC handling. NITZ and the +CGEV PDN notifications are not
// NCM-specific — a QMI or MBIM modem with an AT port emits them just the same,
// and until now nothing consumed them there (open_at passed on_urc: null unless
// the backend defined one, which only NCM did).
//
// Returns a handler; a backend that needs more composes on top rather than
// re-implementing these two.
export function urc_common(self, o)
{
	let log = o.log;
	let deps = o.deps ?? {};

	return (line) => {
		// NITZ (network identity/time, pushed at attach). The daemon applies it
		// only when the system clock is clearly unset (RTC-less router before
		// NTP), so recording it is always safe.
		let tz = nitz_ctzv(line);

		if (tz) {
			self.network_time = { epoch: tz.epoch, tz_offset_min: tz.tz_offset_min };
			log('info', sprintf('network time (NITZ): %d utc, tz %+d min', tz.epoch, tz.tz_offset_min));

			if (deps.set_clock)
				deps.set_clock(tz.epoch, tz.tz_offset_min);
		}

		// +CGEV PDN events are the modem's own session notifications: DEACT pokes
		// the affected context's liveness probe (the probe's result decides, not
		// the URC), ACT pokes a settings re-read (the network may have reassigned
		// IPs on re-activation). Suppressed during an eSIM op, which drives its
		// own long-running AT sequence.
		let m = match(line, /^\+CGEV:.*\bPDN (ACT|DEACT)\s*(\d*)/);

		if (m && !self._esim_op) {
			let cid = +m[2];
			let is_deact = (m[1] == 'DEACT');

			for (let c in (self.contexts ?? []))
				if (!cid || c.cid == cid)
					is_deact ? c.liveness_poke?.() : c.settings_poke?.();
		}
	};
};

export function dsd_from_radio(radio_ifs)
{
	let lte = false, nr = false;

	for (let r in (radio_ifs ?? []))
		if (r == 8) lte = true;
		else if (r == 12) nr = true;

	let mode = nr ? (lte ? 'NSA' : 'SA') : (lte ? 'LTE' : null);

	return mode ? { mode: mode, lte: lte, nr: nr } : null;
};

// the 14 identifying IMEI digits (TAC+serial), dropping the check digit and any
// IMEISV software-version so IMEI (15) and IMEISV (16) forms compare equal.
function imei_key(s)
{
	return substr(replace(sprintf('%s', s ?? ''), /[^0-9]/g, ''), 0, 14);
}

// every modem state any backend may enter — the single source of truth for
// the names (the per-backend step chains use different subsets). set_state
// warns (does not refuse) on a name missing here: a typo'd state string
// would otherwise silently "work" while every consumer matching on it misses.
export const MODEM_STATES = {
	ABSENT: true,          // control device not present (waiting for hotplug)
	INIT_TRANSPORT: true,
	INIT_SERVICES: true,
	SET_OPMODE: true,      // QMI only
	SIM_UNLOCK: true,
	SIM_BLOCKED: true,     // terminal until reload (PIN/PUK)
	CONFIGURE_NET: true,   // QMI only
	CONFIGURING: true,     // QMI (deferred-settings apply) and NCM (attach cfg)
	INIT_DATAPATH: true,
	ATTACHING: true,       // MBIM packet-service attach
	REGISTERING: true,
	READY: true,
};

// timing defaults shared by all backends; each spreads its extras on top.
export const TIMING_BASE = {
	settle: 2000,          // settle after operating-mode changes
	reg_timeout: 240000,   // registration guard
	backoff_min: 5000,     // retry backoff after failures
	backoff_max: 30000,
};

// match a configured wwand_sim list against a card identity: ICCID first
// (authoritative — needed for PIN overrides; trailing-F padding tolerated),
// then IMSI (option imsi, or an IMSI mistakenly put into the iccid field).
export function match_sim_override(sims, iccid, imsi)
{
	sims = sims ?? [];

	let norm = (x) => replace(lc(x ?? ''), /f+$/, '');

	if (iccid) {
		let want = norm(iccid);

		for (let s in sims)
			if (s.iccid && norm(s.iccid) == want)
				return s;
	}

	if (imsi)
		for (let s in sims)
			if ((s.imsi ?? '') == imsi || (s.iccid ?? '') == imsi)
				return s;

	return null;
};

// post-open identity gate: always emits 'identity'; when config pinned `imei`
// and the modem is a DIFFERENT device, emits 'identity_mismatch' and returns
// false (caller must halt bring-up — wrong modem = wrong SIM/PIN/APN).
export function check_identity(self, o)
{
	let got = self.info?.imei;
	let want = self.config?.imei;

	if (got != null && got != '')
		o.emit('identity', { imei: got, serial: self.config?.serial, model: self.info?.model });

	if (!want || got == null || got == '')
		return true;

	if (imei_key(want) == imei_key(got))
		return true;

	o.log('err', sprintf('identity mismatch: configured IMEI %s, modem reports %s — not binding this modem',
		want, got));
	self.identity_mismatch = { expected: want, found: got };
	o.emit('identity_mismatch', self.identity_mismatch);

	return false;
};

// scaffolding(self, o): install the protocol-neutral modem plumbing shared by
// all three state machines — state transitions, context attach/notify, recovery
// passthroughs. Sets self.set_state / attach_context / note_connect_success /
// trip_zero_rx, and returns { emit, notify_contexts } the state machine uses.
//   o.deps  — deps.on_event fans events out
//   o.rec   — recovery instance
export function scaffolding(self, o)
{
	// every backend gets the shared URC handling; one that needs more composes
	// on top by wrapping self.at_on_urc (see modem_ncm)
	self.at_on_urc = urc_common(self, o);

	let deps = o.deps;
	let log = o.log;
	let rec = o.rec;

	// surface parse-time dead-option notes ('pin' vs 'pincode' & co) on every
	// backend — the QMI live validation (config_check) re-adds them after its
	// reset; MBIM/NCM have no validate pass, this seed is their only source
	if (length(self.config?.config_notes ?? []) && self.config_warnings == null)
		self.config_warnings = map(self.config.config_notes, (n) => ({
			check: 'config', severity: 'warn', message: n,
			expected: null, actual: null,
		}));

	// carry the last registration problem across a re-init: the failure retry
	// recreates the modem object, which would wipe the reject cause. Marked
	// stale — any fresh detail (inline capture / telemetry) overwrites it, a
	// clean registration clears it.
	if (self.reg_detail == null && o.rec?.last_reg_detail != null)
		self.reg_detail = { ...o.rec.last_reg_detail, stale: true };

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

		// warn-only registry check (see MODEM_STATES)
		if (!MODEM_STATES[state])
			log('warn', sprintf('set_state: unknown modem state %J (typo?)', state));

		log('info', sprintf('state %s -> %s', self.state, state));
		self.state = state;
		emit('state', { state: state, ...(data ?? {}) });
	};

	self.attach_context = function(ctx) {
		push(self.contexts, ctx);

		if (self.state == 'READY')
			ctx.modem_event('ready');
	};

	// counterpart for reload teardown: without it a replaced context stays in
	// self.contexts forever — retained closures AND still receiving events
	self.detach_context = function(ctx) {
		self.contexts = filter(self.contexts, (c) => c != ctx);
	};

	// admin control-protocol switch (QMI <-> MBIM) — identical across all
	// three backends: on success the modem resets and re-enumerates, so drop
	// clients/timers immediately; discovery rebuilds the modem afterwards.
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

	// terminal SIM block: one emitter for the set_state/emit/notify triple that
	// every backend repeated (payload passes through untouched — QMI hands the
	// full err object incl. `blocked`, MBIM/NCM hand { reason, retries })
	let sim_block = (data) => {
		self.set_state('SIM_BLOCKED', data);
		emit('sim_blocked', data);
		notify_contexts('sim_blocked', data);
	};

	// re-match the per-SIM override for the (possibly new) card and announce
	// it — the shared tail of every backend's reapply_sim. Identity is passed
	// explicitly: QMI deliberately matches the RAW re-read values (a failed
	// read must not keep matching the old card), MBIM/NCM pass self.info.*.
	let resolve_active_sim = (iccid, imsi) => {
		self.active_sim = match_sim_override(self.config?.sims, iccid, imsi);
		log('notice', sprintf('sim reapply: iccid %s imsi %s%s',
			iccid ?? '?', imsi ?? '?',
			self.active_sim ? ' (matched a configured wwand_sim)' : ''));
		emit('sim_refresh', { iccid: self.info.iccid, imsi: self.info.imsi });
	};

	// READY epilogue shared by the backends. The 'registered' emit can run a
	// SYNCHRONOUS config reload that tears this very instance down (HW-hit on
	// the Cudy LT300: autosetup phase 2 writes uci and reloads) — `after`
	// (telemetry/LOC start) runs only when the modem survived the emit.
	let enter_ready = (after) => {
		self.set_state('READY');
		emit('registered', self.reg);
		notify_contexts('ready');

		// best-effort and fire-and-forget: GNSS is not part of being connected,
		// and a modem that will not start it must not hold up the interface
		start_gnss(self, log);

		if (self.state == 'READY' && after)
			after();
	};

	self.note_connect_success = function() {
		rec.on_connect_success();
	};

	// zero-rx watchdog tripped on a context of this modem
	self.trip_zero_rx = function() {
		rec.usb_repower();
	};

	// administrative teardown (daemon shutdown / reload / modem removed)
	self.stop = function() {
		self.teardown();
		self.set_state('ABSENT');
	};

	// control transport reported the device vanished (on_gone): notify contexts,
	// tear down, go ABSENT and announce removal so the daemon detaches. (NCM never
	// calls this — removal arrives as a net hotplug — but keeps the contract uniform.)
	self._device_gone = function() {
		log('warn', 'device disappeared');
		notify_contexts('lost');
		self.teardown();
		self.set_state('ABSENT');
		emit('removed', {});
	};

	return { emit: emit, notify_contexts: notify_contexts, sim_block: sim_block,
	         enter_ready: enter_ready, resolve_active_sim: resolve_active_sim };
};

// install "record a failed connection cycle" for modems with no live DMS to
// cycle (MBIM, NCM): bump the recovery counter and run only the reboot/usb_repower
// rungs. QMI installs its own richer version that also cycles opmode / resets.
// handlers (optional): { opmode_cycle: (done) => …, modem_reset: (done) => … }
// — backend implementations for the two soft recovery rungs. Without them the
// rungs are no-ops and the ladder silently skips from plain retries to board
// repower; every backend that has the primitives should pass them.
export function note_connect_failure_light(self, rec, handlers)
{
	self.note_connect_failure = function(done) {
		done = done ?? ((a) => null);

		let action = rec.on_attempt();

		if (action == 'reboot')
			rec.reboot('connection attempt limit reached');
		else if (action == 'usb_repower')
			rec.usb_repower();
		else if (action == 'opmode_cycle' && handlers?.opmode_cycle)
			return handlers.opmode_cycle(() => done(action));
		else if (action == 'modem_reset' && handlers?.modem_reset)
			return handlers.modem_reset(() => done(action));

		done(action);
	};
};

// make_fail(self, o): shared "a bring-up step failed" handler. Runs the modem's
// note_connect_failure, then on the resulting ladder action emits 'error', tears
// down, and either stops (reboot pending) or schedules a capped-backoff retry of
// self.start(). Returns fail(stage, err). (The daemon ignores the 'error' event;
// it is test/observability only.)
//   o.timing          — { backoff_min, backoff_max }
//   o.set_retry_timer — (timer) => …  store where teardown cancels it
// shared modem-factory preamble (identical in all three backends): recovery
// instance wired to the board repower hook, persisted counters loaded, and the
// counters/recovery/log_fn fields attached to self. Returns the rec instance.
export function make_recovery(self, opts, log, proto)
{
	let rec = recovery_mod.create({
		id: opts.id,
		// persisted with the counters: a protocol change invalidates `proven`
		protocol: opts.protocol,
		failreboot: (opts.config ?? {}).failreboot,
		proto_error_limit: (opts.config ?? {}).proto_error_limit,
		fx: opts.recovery?.fx ?? netlink.default_fx((l, m) => log(l, m)),
		state_dir: opts.recovery?.state_dir,
		reboot_delay: opts.recovery?.reboot_delay,
		// board-provided modem repower (power-cycle or reset-gpio pulse)
		repower: opts.recovery?.repower,
		log: (l, m) => log(l, m),
	});

	rec.load();

	// Tell the ladder which control protocol this modem run settled on. It
	// withdraws the permission to touch hardware whenever that changes, because
	// "the modem answered once" was proved with the PREVIOUS choice and says
	// nothing about the new one. Without this a corrected misdetection would
	// inherit the arming from the wrong protocol.
	rec.note_protocol(proto ?? opts.protocol ?? null);

	self.counters = rec.counters;
	self.recovery = rec;
	self.log_fn = log;

	return rec;
};

export function make_fail(self, o)
{
	return (stage, err) => {
		o.log('err', sprintf('failed in %s: %J', stage, err));

		// keep the last fresh registration problem on the persistent recovery
		// record: the retry recreates the modem object, which would otherwise
		// wipe the reject cause the user needs to see (scaffolding re-seeds it)
		if (o.rec && self.reg_detail && !self.reg_detail.stale)
			o.rec.last_reg_detail = self.reg_detail;

		self.note_connect_failure((action) => {
			o.emit('error', {
				stage: stage, err: err,
				attempts: self.counters.attempts, action: action,
			});

			self.teardown();

			if (action == 'reboot') {
				self.set_state('ABSENT');
				return;   // no retry, reboot is pending
			}

			let backoff = min(o.timing.backoff_min * self.counters.attempts,
			                  o.timing.backoff_max);

			self.set_state('ABSENT', { retry_in: backoff });
			o.set_retry_timer(uloop.timer(backoff, () => self.start()));
		});
	};
};

// watch_driver(o): the adaptive "fast telemetry" cadence shared by the QMI and
// MBIM state machines. While a consumer polls (modem_signal/modem_cells over
// ubus), runs o.refresh at most once per min_interval, NON-OVERLAPPING (next
// cycle scheduled only after the previous finishes, so it stretches under load),
// and decays back to idle `decay` ms after the last poll.
//   o.alive   () => bool   — control channel up
//   o.ready   () => bool   — self.state == 'READY'
//   o.refresh (done) => …  — run one refresh cycle; call done() EXACTLY ONCE when
//                            it finishes or bails. done() reschedules iff still
//                            watched and alive, else goes idle (a bail with
//                            !alive() stops the loop).
//   o.min_interval?  ms (default 1000) — never poll faster than this
//   o.decay?         ms (default 6000) — idle-out delay after the last watch()
// Returns { watch(), stop() }.
export function watch_driver(o)
{
	let min_interval = o.min_interval ?? 1000;
	let decay = o.decay ?? 6000;

	let decay_timer = null, fast_timer = null;
	let active = false, running = false;

	// mutually-referencing arrows -> forward-declare (ucode TDZ trap)
	let tick, finish;

	finish = () => {
		if (active && o.alive())
			fast_timer = uloop.timer(min_interval, tick);
		else
			running = false;
	};

	tick = () => {
		fast_timer = null;

		if (!active || !o.ready() || !o.alive()) {
			running = false;
			return;
		}

		running = true;
		o.refresh(finish);
	};

	return {
		watch: function() {
			active = true;

			if (decay_timer)
				decay_timer.cancel();

			decay_timer = uloop.timer(decay, () => {
				active = false;
				decay_timer = null;
			});

			// kick an immediate refresh so the first poll already returns fresh data
			if (!running && o.ready() && o.alive())
				tick();
		},

		stop: function() {
			if (decay_timer) { decay_timer.cancel(); decay_timer = null; }
			if (fast_timer)  { fast_timer.cancel();  fast_timer = null; }
			active = running = false;
		},
	};
};

// telemetry_at(self): the AT engine a telemetry poll runs over — the dedicated
// 'at2' channel when the modem has one, else the control channel (self.at).
// Both are opened up front by open_at(); this only selects between them.
//
// NEVER returns null: a torn-down modem (close_at ran — teardown/reload can happen
// synchronously under an emit while a poll callback is still in flight) gets a stub
// engine whose send() fails immediately, so the many unguarded
// `telemetry_at(self).send(...)` call sites degrade to an AT error instead of
// crashing on `null.send` (HW-hit: autosetup phase-2 reload on the Cudy LT300 tore
// the modem down inside the 'registered' emit; the READY hook then ran on the corpse).
export function telemetry_at(self)
{
	return self.at_telemetry ?? {
		send: (cmd, cb) => { if (cb) cb('closed', null); },
		run_sequence: (cmds, cb) => { if (cb) cb(); },
		close: () => null,
	};
};

// +CSQ: <rssi>,<ber> — rssi 0..31 coded (99 = unknown) -> dBm. The shared CSQ
// floor read for signal fallback paths (NCM baseline, and the QMI backend's
// fallback when the modem has no working QMI signal message).
export function parse_csq(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /\+CSQ:\s*([0-9]+),/);

		if (m) {
			let raw = +m[1];

			return { rssi_raw: raw, rssi: (raw != 99) ? (-113 + 2 * raw) : null };
		}
	}

	return null;
};

// merge a CSQ RSSI floor into self.signal without clobbering per-RAT metrics
export function sig_csq_floor(self, s)
{
	let base = { ...(self.signal ?? {}) };

	if (s) {
		base.rssi_raw = s.rssi_raw;

		if (base.lte == null && base.nr5g == null)
			base.rssi = s.rssi;
	}

	self.signal = base;
};

// the ONLY source of NR5G neighbour cells — QMI Get Cell Location Info carries
// none (only the NR serving cell), so ALL backends read them over the shared AT
// side channel (AT+QENG="neighbourcell", Quectel/ASR). Best-effort: gated on an
// active NR serving cell; silently skipped when the modem has no usable AT.
// Stores self.cells.nr5g_neigh (or null).
export function fetch_nr_neighbours(self, cb)
{
	cb = cb ?? (() => null);

	let at = telemetry_at(self);

	if (!self.cells?.nr5g_cell) {
		if (self.cells)
			self.cells.nr5g_neigh = null;
		return cb();
	}

	// QENG is Quectel/ASR — don't send it to a modem that can't answer it
	if (!qeng_ok(self))
		return cb();

	// no-AT modem surfaces as a send error here, clearing the neighbour list
	at.send('AT+QENG="neighbourcell"', (err, res) => {
		if (self.cells) {
			let n = err ? null : atcmd.parse_qeng_neighbourcell(res?.lines).nr;
			self.cells.nr5g_neigh = length(n ?? []) ? n : null;
		}
		cb();
	});
};

// manufacturers whose AT firmware answers AT+QNWINFO (the active access-tech
// query). Extensible: add a vendor here once its QNWINFO/analogue is verified.
const QNWINFO_VENDORS = /quectel/;

// collect_caps(self, cb): build self.caps — a best-effort summary of which RATs
// the modem supports, for status display. The Quectel AT+QCFG="iotopmode" query
// (which cellular-IoT modes it searches) runs ONCE and is cached; the summary
// is then rebuilt each call so newly-observed RATs fold in. Combined with a
// model-string hint (RedCap/NTN). Stores self.caps = { rats, iot_modes, ntn }.
// Defined before probe_iot_rat, which calls it (ucode does not hoist exports).
export function collect_caps(self, cb)
{
	cb = cb ?? (() => null);

	// authoritative supported-RAT families for caps.rats on a 5G modem currently
	// camped on LTE. Source order native -> passthrough/QMI: the native MBIM
	// DEVICE_CAPS data_class bitmask first (no passthrough/AT needed), else the
	// QMI DMS device-capabilities radio_ifs list. DMS 5GNR=10 (not the NAS 12).
	let mode_caps = null;

	if (self.info?.mbim_data_class != null) {
		mode_caps = ratmod.families_from_mbim(self.info.mbim_data_class,
			self.info.mbim_custom_data_class);
	}
	else {
		let cap_ifs = self.info?.capabilities?.radio_ifs;

		if (type(cap_ifs) == 'array') {
			mode_caps = [];
			for (let r in cap_ifs) {
				let o = ratmod.from_dms_radio_if(r);
				if (o && index(mode_caps, o.rat) < 0)
					push(mode_caps, o.rat);
			}
		}
	}

	let build = () => {
		self.caps = ratmod.caps_from({
			model:     self.info?.model,
			iot_modes: self._iot_modes,
			observed:  keys(self._rats_seen ?? {}),
			modes:     mode_caps,
		});
		cb();
	};

	if (self._caps_done)
		return build();

	self._caps_done = true;

	let mfr = lc(sprintf('%s', self.info?.manufacturer ?? ''));

	if (!match(mfr, QNWINFO_VENDORS))
		return build();

	telemetry_at(self).send('AT+QCFG="iotopmode"', (err, res) => {
		self._iot_modes = err ? null : atcmd.parse_qcfg_iotopmode(res?.lines);
		build();
	});
};

// coarse current RAT from the always-present NAS radio_ifs (highest-tech wins):
// the steady-state fallback for rat_label when neither DSD (no such service on
// older/simple QMI modems, e.g. Huawei E392) nor QNWINFO (non-Quectel) named the
// mode. Mirrors format_telemetry's radio_ifs-derived `tech`, so status `rat`
// stays consistent with the telemetry log line instead of showing null on a
// registered modem. NR5G(12) > LTE(8) > TD-SCDMA(9)/UMTS(5) > EVDO(2) > GSM(4)/
// CDMA(1). Returns a canonical rat object or null.
const RADIO_IF_RANK = { '12': 6, '8': 5, '9': 4, '5': 4, '2': 3, '4': 2, '1': 1 };
export function rat_from_radio_ifs(radio_ifs)
{
	let best = null, best_rank = -1;

	for (let r in (radio_ifs ?? [])) {
		let rank = RADIO_IF_RANK[sprintf('%d', r)] ?? 0;
		if (rank > best_rank) { best_rank = rank; best = r; }
	}

	return best != null ? ratmod.from_qmi_radio_if(best) : null;
};

// probe_iot_rat(self, cb): identify the active radio-access technology to the
// fine IoT granularity that QMI/MBIM structured data cannot express — NB-IoT,
// LTE-M (Cat-M1/eMTC), RedCap, the 5G NSA/SA split — over the shared AT side
// channel (AT+QNWINFO, Quectel). Stores self.rat_fine (a canonical rat.uc
// object { rat, mode, ntn, src }) or null. Best-effort and vendor-gated: a
// non-Quectel or no-AT modem leaves self.rat_fine null and sends nothing.
export function probe_iot_rat(self, cb)
{
	cb = cb ?? (() => null);

	let mfr = lc(sprintf('%s', self.info?.manufacturer ?? ''));

	// record the identified RAT (label for status, slug into the observed set)
	// and refresh the capability summary, then finish. `fine` is the AT-QNWINFO
	// result (NB-IoT/RedCap detail) when available; otherwise fall back to the
	// backend-neutral current RAT from the resolved dsd_status (native MBIM /
	// QMI-passthrough serving), so the RAT shows even with a dead AT port.
	let finish = (fine) => {
		// combine the coarse structured base (dsd_status: LTE/NSA/SA) with the
		// fine AT source (QNWINFO: IoT/RedCap + NSA/SA). ratmod.merge scores them
		// so a finer source wins — but ALSO so a fresh DSD "5G-NSA" is not masked
		// by a QNWINFO that only reported the LTE anchor (the old `fine ?? base`
		// let a coarser QNWINFO always win). fine==null -> base; base==null -> fine.
		// The DSD mode is populated only by the fast/watched loop; when it is
		// absent (steady state, or a modem with no DSD service like the E392),
		// fall back to the coarse RAT from the always-present NAS radio_ifs so a
		// registered modem never reports rat=null while its telemetry logs LTE.
		let base = ratmod.from_dsd_mode(self.dsd_status?.mode)
		           ?? rat_from_radio_ifs(self.reg?.radio_ifs);
		self.rat_fine = ratmod.merge(base, fine);
		self.rat_label = self.rat_fine ? ratmod.label(self.rat_fine) : null;

		if (self.rat_fine?.rat) {
			self._rats_seen = self._rats_seen ?? {};
			self._rats_seen[self.rat_fine.rat] = true;
		}

		collect_caps(self, cb);
	};

	// AT+QNWINFO is the fine (IoT-aware) source, but only for the vendors that
	// implement it AND with a live AT port — otherwise the native dsd fallback
	// above carries the base RAT.
	if (!match(mfr, QNWINFO_VENDORS))
		return finish(null);

	telemetry_at(self).send('AT+QNWINFO', (err, res) => {
		let info = err ? null : atcmd.parse_qnwinfo(res?.lines);
		finish(info ? { rat: info.rat, mode: info.mode, ntn: false, src: 'qnwinfo' } : null);
	});
};

// collect_temperature(self, cb): read the modem die/board temperature over the
// shared AT side channel and store self.temperature = { celsius, source:'at' }.
// The command + parser are picked per manufacturer (QModem-derived): Quectel
// AT+QTEMP, MeiG AT+TEMP, Huawei AT^CHIPTEMP, SIMCom AT+CPMUTEMP. Slow-loop only
// (temperature drifts slowly). Best-effort: an unknown vendor or a no-AT modem
// (e.g. EG06 in MBIM mode) skips silently and keeps the last-known value.
export function collect_temperature(self, cb)
{
	cb = cb ?? (() => null);

	// latched off: this modem's AT temperature command failed once — an
	// unsupported command (old Huawei E392: no AT^CHIPTEMP) or a dead AT port
	// (EG06 in MBIM mode). Don't re-send a command we know fails every slow tick.
	if (self._temp_unavail)
		return cb();

	let mfr = lc(self.info?.manufacturer ?? '');
	let cmd, parse;

	if (index(mfr, 'quectel') >= 0)     { cmd = 'AT+QTEMP';    parse = atcmd.parse_qtemp; }
	else if (index(mfr, 'meig') >= 0)   { cmd = 'AT+TEMP';     parse = atcmd.parse_meig_temp; }
	else if (index(mfr, 'huawei') >= 0) { cmd = 'AT^CHIPTEMP'; parse = atcmd.parse_chiptemp; }
	else if (index(mfr, 'simcom') >= 0) { cmd = 'AT+CPMUTEMP'; parse = atcmd.parse_cpmutemp; }
	// FM350/T700 (MediaTek): AT+ETHERMAL? (field-verified — the FM350 REJECTS
	// the 3ginfo-lite NL952 command AT+MTSM=1)
	else if (index(mfr, 'fibocom') >= 0) { cmd = 'AT+ETHERMAL?'; parse = atcmd.parse_ethermal; }
	else {
		self._temp_unavail = true;   // no known temperature command for this vendor
		return cb();
	}

	telemetry_at(self).send(cmd, (err, res) => {
		if (err)
			self._temp_unavail = true;   // AT error / timeout / unsupported -> latch off
		else {
			let c = parse(res?.lines);
			self.temperature = (c != null) ? { celsius: c, source: 'at' } : null;
		}
		cb();
	});
};

// tear down both AT engines opened by open_at (control + distinct telemetry
// channel). Idempotent.
export function close_at(self)
{
	if (self.at_telemetry && self.at_telemetry != self.at)
		self.at_telemetry.close();

	if (self.at)
		self.at.close();

	self.at = null;
	self.at_telemetry = null;
	self.at_tty = null;
	self.at_telemetry_tty = null;
};

// best-effort AT side-channel bring-up: discover + open the AT tty, run
// model-init + configured at_init + cell-lock commands, then o.next(). Always
// non-fatal (no usable AT port -> next() with self.at unset).
//   o = { at_opts?, log, drain_interval?, set_drain_timer, next, reopen_next?,
//         base_override? — explicit sysfs USB-device base for tty discovery
//         (NCM: the datapath netdev's USB parent; there is no cdc-wdm anchor) }
// atcmd_mbim lives in wwand-mbim, because it needs that package's MBIM client
// and codec. An MHI box is exactly the case where it is wanted and may be
// absent: such a modem installs wwand-qmi + wwand-mhi, and nothing there pulls
// wwand-mbim in. A bare require() would then throw out of open_at.
//
// Same shape as daemon.uc's lazy_backend(): try once, remember the failure,
// report the capability as absent rather than crashing.
let _at_mbim = null, _at_mbim_failed = false;

let load_at_mbim = () => {
	if (_at_mbim_failed)
		return null;

	if (_at_mbim == null) {
		try {
			_at_mbim = require('wwand.atcmd_mbim_lazy');
		}
		catch (e) {
			_at_mbim_failed = true;
			_at_mbim = null;
		}
	}

	return _at_mbim;
};

// shared tail: wire the engine on an AT-over-MBIM transport, whichever way it
// was obtained, and run the same init commands the tty path runs. There is
// deliberately no second (telemetry) channel — the pipe is request/response
// and one is all the modem offers, so telemetry shares the control engine
// exactly as it does on a single-port tty modem.
//
// The QDU AT pipe is a VENDOR extension: plenty of MBIM modems do not
// implement CID 8 and answer every command with an MBIM error. So the engine
// is only kept if a bare `AT` comes back — otherwise this is indistinguishable
// from having no AT at all, and pretending otherwise would turn one silent
// absence into a failure on every command wwand ever sends.
function finish_mbim_at(self, o, tr, path, log)
{
	let engine = atcmd.create(tr, {
		log: (level, msg) => log(level, sprintf('at: %s', msg)),
		on_urc: (line) => {
			log('debug', sprintf('urc[at]: %s', line));
			self.at_on_urc?.(line, 'at');
		},
		on_answer: o.on_answer,
	});

	engine.send('AT', (err) => {
		if (err) {
			log('info', sprintf('no AT over MBIM on %s (%J) — continuing without AT',
				path, err));
			engine.close();
			return o.next();
		}

		self.at = engine;
		self.at_tty = path;
		self.at_telemetry = engine;
		self.at_over_mbim = true;
		log('notice', sprintf('AT over MBIM ready on %s', path));

		let cmds = [
			...atcmd.model_init_commands(self.info?.model),
			...(self.config.at_init ?? []),
			...atcmd.cell_lock_commands(self.config),
		];

		if (!length(cmds))
			return o.next();

		engine.run_sequence(cmds, () => o.next());
	}, { timeout: 5000 });
}

// AT over MBIM: the fallback when a modem exposes no AT tty at all (PCIe/MHI
// without a DUN channel). Opens the MBIM sibling of the control port purely as
// an AT pipe and wires the same engine the tty path builds — callers above see
// no difference. Non-fatal throughout: no sibling, disabled by config, or a
// failed open all end in o.next() with self.at unset, exactly like "no AT port".
//
// There is deliberately NO second (telemetry) channel here: the pipe is
// request/response and one is all the modem offers. telemetry_at() therefore
// shares the control engine, which is the same thing a single-port tty modem does.
function open_at_over_mbim(self, o, fxi, log)
{
	if (self.config?.at_mbim == '0' || self.config?.at_mbim === false) {
		log('info', 'no AT port found (AT over MBIM disabled by config)');
		return o.next();
	}

	// When MBIM is what DRIVES this modem, the AT pipe rides the client the
	// backend already owns. Opening a second one on the same node is not an
	// option: MBIM_OPEN resets the function and would drop a live data
	// session. (HW: a GL-X3000 runs an RM520N this way, connected for days.)
	// injectable like open_transport/open_mbim_at: the module is always present
	// in a source tree, so absence can only be exercised through a seam
	let load = o.at_opts?.load_at_mbim ?? load_at_mbim;

	if (self.mbim) {
		let mod = load();

		if (!mod) {
			log('info', 'no AT port found (AT over MBIM needs the wwand-mbim package)');
			return o.next();
		}

		return mod.attach(self.mbim, self.device, { log: log }, (tr) => tr
			? finish_mbim_at(self, o, tr, self.device, log)
			: o.next());
	}

	// Otherwise the modem is driven by some other backend and its MBIM channel
	// is idle — that is the PCIe/MHI case, where the control ports are separate
	// nodes of one wwan device.
	let sibling = o.at_opts?.mbim_at_device ??
		discovery.wwan_sibling_port(self.device, 'mbim', o.at_opts?.discovery_fx);

	if (!sibling) {
		log('info', 'no AT port found');
		return o.next();
	}

	let opener = o.at_opts?.open_mbim_at ?? ((path, oo, cb) => {
		// via the plain-script shim: require() cannot load an ES module,
		// and importing it at top level would drag the MBIM codec into the
		// backend-neutral base package.
		let mod = load();

		return mod ? mod.open(path, oo, cb) : cb(null);
	});

	log('info', sprintf('no AT tty — trying AT over MBIM on %s', sibling));

	opener(sibling, { log: log }, (tr) => tr
		? finish_mbim_at(self, o, tr, sibling, log)
		: o.next());
}

// forward-declared: open_at dispatches to it, and ucode closures capture only
// already-declared variables (module-level functions are not hoisted)
let open_at_tty;

// The cdc-wdm control node of an AT-driven NCM modem can BE the AT channel:
// huawei_cdc_ncm registers its wdm as the embedded AT port alongside the NCM
// datapath (kernel drivers/net/usb/huawei_cdc_ncm.c), and the modem's serial
// siblings may be PCUI/diag ports that never answer AT (field-observed on an
// E3372H). Gated on the AT-driver table — AT must never be poked into a
// QMI/MBIM control channel. One channel only: telemetry shares the engine.
function open_at_over_wdm(self, o, fxi, log, next)
{
	let dev = self.device;

	if (dev == null || !match(dev, /^\/dev\/cdc-wdm[0-9]+$/) ||
	    !discovery.is_at_driver(discovery.driver_of(dev, fxi)))
		return next();

	log('info', sprintf('no AT tty — trying the cdc-wdm control channel %s', dev));

	let open_transport = o.at_opts?.open_transport ?? atcmd.open_transport;
	let tr = open_transport(dev, 115200, (level, msg) => log(level, msg));

	if (!tr) {
		log('warn', sprintf('cannot open AT channel %s', dev));
		return next();
	}

	self.at = atcmd.create(tr, {
		log: (level, msg) => log(level, sprintf('at: %s', msg)),
		on_urc: (line) => {
			log('debug', sprintf('urc[at]: %s', line));
			self.at_on_urc?.(line, 'at');
		},
		// Same hook as the tty path. A huawei_cdc_ncm modem carries its AT on
		// the cdc-wdm, so this IS its control channel — omitting the hook left
		// exactly those modems unproven until a context reached "up", although
		// AT had been answering since init.
		on_answer: o.on_answer,
	});
	self.at_tty = dev;
	self.at_telemetry = self.at;
	self.at_telemetry_tty = dev;

	// the same liveness probe as the tty path: only silence disqualifies
	self.at.send('AT', (perr) => {
		if (perr?.error != 'timeout' && perr?.error != 'closed') {
			log('notice', sprintf('AT channel: %s (cdc-wdm)', dev));

			let cmds = [
				...atcmd.model_init_commands(self.info?.model),
				...(self.config.at_init ?? []),
				...atcmd.cell_lock_commands(self.config),
			];

			if (!length(cmds))
				return o.next();

			self.at.run_sequence(cmds, o.next);
			return;
		}

		log('warn', sprintf('cdc-wdm AT channel %s opens but does not answer (%s)',
			dev, perr.error));
		self.at.close();
		self.at = null;
		self.at_tty = null;
		self.at_telemetry = null;
		next();
	}, { timeout: o.at_opts?.probe_timeout ?? 10000 });
}

export function open_at(self, o)
{
	let log = o.log;

	if (self.at)
		return (o.reopen_next ?? o.next)();

	let fxi = o.at_opts?.fx ?? netlink.default_fx((level, msg) => log(level, msg));

	// huawei_cdc_ncm: the cdc-wdm IS the embedded AT channel (the driver
	// registers it as such — huawei_cdc_ncm.c); the serial siblings are
	// PCUI/diag ports and the firmware ignores the NCM dial (^NDISDUP)
	// everywhere else. HW-observed on the E3372H, 2026-08-30: the tty
	// answered generic AT, but a dial over it left ^NDISSTATQRY at 0 while
	// the same dial over the wdm connected. Prefer the wdm — an explicit
	// `option tty` still wins, and a wdm that stays silent falls back to
	// the normal tty search. (The readlink guard keeps driver_of out of
	// test fakes that never had to answer sysfs driver lookups.)
	let dev = self.device;

	if (dev != null && match(dev, /^\/dev\/cdc-wdm[0-9]+$/) &&
	    self.config?.tty == null && fxi.readlink != null &&
	    discovery.driver_of(dev, fxi) == 'huawei_cdc_ncm')
		return open_at_over_wdm(self, o, fxi, log, () => {
			let ch = atcmd.find_at_channels(fxi, self.device, self.config.tty, o.base_override);
			open_at_tty(self, o, fxi, log, ch);
		});

	let ch = atcmd.find_at_channels(fxi, self.device, self.config.tty, o.base_override);

	open_at_tty(self, o, fxi, log, ch);
};

open_at_tty = function(self, o, fxi, log, ch)
{
	let tty = ch.primary;

	// No tty is not necessarily no AT. An AT-driven NCM modem's control
	// cdc-wdm can be the AT channel itself (huawei_cdc_ncm); otherwise a
	// PCIe/MHI modem usually has no DUN channel and therefore no /dev/wwanNat0
	// — but its MBIM channel is a separate node on the same wwan device, and
	// Quectel carries an AT pipe there (atcmd_mbim.uc). Reach for those only
	// when there is no real port: a tty is a full-duplex channel that also
	// delivers URCs, which a request/response pipe cannot. `option at_mbim
	// '0'` opts out.
	if (!tty)
		return open_at_over_wdm(self, o, fxi, log, () => open_at_over_mbim(self, o, fxi, log));

	let open_transport = o.at_opts?.open_transport ?? atcmd.open_transport;
	let tr = open_transport(tty, 115200, (level, msg) => log(level, msg));

	if (!tr) {
		// A port that will not open is as good as absent — another process may
		// hold it, or it may have vanished between discovery and here. Try the
		// MBIM pipe rather than giving up on AT entirely.
		log('warn', sprintf('cannot open AT port %s', tty));
		return open_at_over_mbim(self, o, fxi, log);
	}

	// on_urc is LATE-BOUND on purpose: a backend may install or wrap its handler
	// after the port is open, and the lazily opened telemetry channel below must
	// reach the same one. urc_prefixes likewise — the vendor recipe that extends
	// the set is only known after identify, which runs after this.
	//
	// The channel is passed along and logged here — ONE site for all backends,
	// and the only place that still knows which port a line came off. Modems
	// that mirror their URCs onto both AT interfaces (MeiG SLM770A) otherwise
	// produce two identical, unattributable log lines per event.
	let dispatch_urc = (ch) => (line) => {
		log('debug', sprintf('urc[%s]: %s', ch, line));
		self.at_on_urc?.(line, ch);
	};

	self.at = atcmd.create(tr, {
		log: (level, msg) => log(level, sprintf('at: %s', msg)),
		on_urc: dispatch_urc('at'),
		// only the CONTROL engine, and only where the caller asks for it: on an
		// NCM modem AT *is* the control protocol, so a port that answers is the
		// evidence the recovery gate wants. On QMI/MBIM the AT port is a side
		// channel and says nothing about the protocol we drive the modem with —
		// which is why this is passed down rather than wired in here.
		on_answer: o.on_answer,
	});
	self.at_tty = tty;

	// A port that OPENS is not necessarily a port that answers. On a PCIe/MHI
	// modem the DUN channel can accept writes and then go silent: seen on an
	// RM520N-GL after an AT+CFUN=1,1, and it stayed silent across a wwand
	// restart and a reboot before coming back on a later one — flaky, not
	// permanently dead, which is worse, because nothing distinguishes the two
	// from here. Throughout, the same AT processor kept answering over MBIM.
	// Without this check wwand settles on the mute channel with a working one
	// right beside it, and every AT-backed feature times out.
	//
	// Only silence disqualifies a port. A modem that answers ERROR (or a CME
	// error) to a bare AT has answered, and stays the control channel.
	let at_ready = () => {

		// dedicated telemetry channel ('at2'): telemetry polls run over a separate
		// engine so they don't serialize behind control/dial commands. It is opened
		// EAGERLY, together with the control channel, because the port is a URC
		// source first and a poll channel second.
		//
		// It used to open lazily on the first telemetry poll, to save an fd on
		// QMI/MBIM that rarely touch AT. But an unopened port does not merely go
		// unparsed: nothing holds the fd, so whatever the modem pushes there is
		// gone. On NCM the first poll only runs at state READY, which left the
		// entire SIM and registration phase unwatched on the very port some modems
		// report it on (MeiG SLM770A: ^SIMST, ^SRVST, ^MODE). A second AT port is
		// now read for URCs exactly like the primary one.
		//
		// Falls back to the control channel when there is no distinct second port,
		// or when opening it fails — telemetry then shares the control engine as
		// before.
		self.at_telemetry = self.at;
		self.at_telemetry_tty = tty;

		// The NMEA port (role 'gps' in the generated port table). wwand NEVER
		// opens it — same rule as at2_external, and for the same reason: it
		// belongs to gpsd. It is REPORTED, not linked: wwand writes nothing into
		// /dev, so whoever wants the port asks the daemon for it (`gps` in
		// `ubus call wwand status`) and points gpsd there. The name is re-read on
		// every bring-up, so a modem that re-enumerates onto another ttyUSB
		// answers with the new one.
		if (ch.gps) {
			self.gps_tty = ch.gps;
			log('notice', sprintf('NMEA port %s available (wwand does not open it; see `gps_port` in ubus status)',
				ch.gps));
		}

		// config `at2_external`: the secondary AT port is reserved for EXTERNAL
		// tools (gpsd, user scripts, ...) — wwand must never open it. Telemetry
		// stays on the control channel; log which tty is being left alone.
		if (self.config?.at2_external && ch.telemetry && ch.telemetry != tty) {
			log('notice', sprintf('secondary AT port %s released for external use (at2_external)', ch.telemetry));
			self.at2_released = ch.telemetry;
			ch = { ...ch, telemetry: null };
		}

		if (ch.telemetry && ch.telemetry != tty) {
			let tr2 = open_transport(ch.telemetry, 115200, (level, msg) => log(level, msg));

			if (tr2) {
				// the telemetry channel carries URCs too — on many modems it is THE
				// port they arrive on. It used to get no handler at all, so every
				// URC landing there was dropped.
				//
				// urc_prefixes is seeded from the control engine and COPIED there;
				// the vendor recipe, known only after identify, is merged into BOTH
				// engines by the backend (modem_ncm), not propagated between them.
				self.at_telemetry = atcmd.create(tr2, {
					log: (level, msg) => log(level, sprintf('at2: %s', msg)),
					on_urc: dispatch_urc('at2'),
					urc_prefixes: self.at.urc_prefixes,
				});
				self.at_telemetry_tty = ch.telemetry;
				log('notice', sprintf('AT telemetry channel: %s', ch.telemetry));
			}
			else {
				log('warn', sprintf('cannot open AT telemetry channel %s (using control channel)', ch.telemetry));
			}
		}

		// model quirks + configured at_init list, then cell locks
		let cmds = [
			...atcmd.model_init_commands(self.info?.model),
			...(self.config.at_init ?? []),
			...atcmd.cell_lock_commands(self.config),
		];

		// M9200B: periodically drain stale serial output (empty_serial_buffers quirk)
		if (index(self.info?.revision ?? '', 'M9200B') >= 0) {
			let interval = o.drain_interval ?? 60000;
			let tick;

			tick = () => {
				self.at.drain();
				o.set_drain_timer(uloop.timer(interval, tick));
			};

			o.set_drain_timer(uloop.timer(interval, tick));
			log('notice', 'M9200B detected, enabling serial drain');
		}

		if (!length(cmds))
			return o.next();

		self.at.run_sequence(cmds, o.next);
	};

	self.at.send('AT', (perr) => {
		if (perr?.error != 'timeout' && perr?.error != 'closed') {
			log('notice', sprintf('AT port: %s', tty));
			return at_ready();
		}

		log('warn', sprintf('AT port %s opens but does not answer (%s) — trying the next channel',
			tty, perr.error));
		self.at.close();
		self.at = null;
		self.at_tty = null;
		self.at_telemetry = null;
		open_at_over_wdm(self, o, fxi, log, () => open_at_over_mbim(self, o, fxi, log));
	}, { timeout: o.at_opts?.probe_timeout ?? 10000 });
};

// format_telemetry(o): the single telemetry log line for EVERY backend, defensive
// about per-backend shape differences so all produce the same style of line:
//   - tech:  numeric NAS radio_ifs (QMI) -> else string reg.mode/reg.tech (NCM);
//   - plmn:  {mcc,mnc,description} (QMI) -> else {id,description} (MBIM);
//   - cells: QMI/NCM lte_intra + nr5g_cell (0.1-unit rsrp/rsrq);
//   - signal: per-tech sig.lte/sig.nr5g (QMI/NCM) -> else flat sig.rsrp/rssi
//            (native MBIM). rsrp/rssi are dBm; snr is 0.1 dB.
export function format_telemetry(o)
{
	let reg = o.reg ?? {}, cells = o.cells, sig = o.signal;
	let rd = o.reg_detail, cfg = o.config ?? {};
	let parts = [], techs = [];

	// a fine RAT identified over AT (QNWINFO/QENG/AcT) that names an IoT / RedCap
	// / NTN variant wins: QMI/MBIM radio interfaces cannot represent these, so it
	// replaces the coarse radio-interface derivation for the tech label.
	let iot = (o.rat_fine != null && ratmod.is_iot(o.rat_fine.rat)) ? o.rat_fine : null;

	if (iot)
		push(techs, ratmod.label(iot));

	for (let r in (iot ? [] : (reg.radio_ifs ?? []))) {
		if (r == nasmod.RADIO_IF_LTE) push(techs, 'LTE');
		else if (r == nasmod.RADIO_IF_5GNR) push(techs, 'NR5G');
		else if (r == nasmod.RADIO_IF_UMTS) push(techs, 'UMTS');
		else if (r == nasmod.RADIO_IF_GSM) push(techs, 'GSM');
		else push(techs, sprintf('rat%d', r));
	}

	// no numeric radio_ifs (MBIM/NCM): tech is a string on reg.mode/reg.tech
	// or on the DSD status (LTE/NSA/SA)
	if (!iot && !length(techs) && (reg.mode != null || reg.tech != null))
		push(techs, uc(sprintf('%s', reg.mode ?? reg.tech)));

	if (!iot && !length(techs) && o.dsd_status?.mode != null)
		push(techs, uc(sprintf('%s', o.dsd_status.mode)));

	// NSA: LTE-registered while the NR anchor shows in the 5G cell/signal info
	let nr_anchor = !iot && (cells?.nr5g_cell != null ||
		(sig?.nr5g?.rsrp != null && !tlv.is_unavailable(sig.nr5g.rsrp, 'i16')));
	let has_lte = index(techs, 'LTE') >= 0;
	let has_nr = index(techs, 'NR5G') >= 0;

	if (has_lte && !has_nr && nr_anchor)
		push(techs, 'NR5G');

	push(parts, sprintf('tech=%s%s', length(techs) ? join('+', techs) : 'none',
		(has_lte && (has_nr || nr_anchor)) ? '(NSA)' : ''));

	if (reg.plmn) {
		let desc = reg.plmn.description ? sprintf(' (%s)', trim(reg.plmn.description)) : '';

		if (reg.plmn.mcc != null)
			push(parts, sprintf('plmn=%d/%02d%s', reg.plmn.mcc, reg.plmn.mnc, desc));
		else if (reg.plmn.id != null) {
			// a numeric provider id (MBIM) is the concatenated MCCMNC — split it
			// to the same mcc/mnc form the QMI backend prints
			let m = match(sprintf('%s', reg.plmn.id), /^([0-9]{3})([0-9]{2,3})$/);
			push(parts, m ? sprintf('plmn=%s/%s%s', m[1], m[2], desc)
			              : sprintf('plmn=%s%s', reg.plmn.id, desc));
		}
		else if (reg.plmn.description)
			push(parts, sprintf('plmn=%s', trim(reg.plmn.description)));
	}

	if (reg.roaming != null)
		push(parts, sprintf('roaming=%s', reg.roaming ? 'yes' : 'no'));

	let lte = cells?.lte_intra;

	if (lte) {
		let serving = null;

		for (let c in (lte.cells ?? []))
			if (c.pci == lte.serving_cell_id)
				serving = c;

		// band (+ channel bandwidth) from the serving detail — vendor AT/CA-info
		// where available, else EARFCN-derived (fill_serving_band)
		let sl = cells?.serving?.lte;
		let band = (sl?.band != null) ? sprintf(' band %s', sl.band) : '';
		let bw = (sl?.bandwidth_mhz != null) ? sprintf(' bw %gMHz', sl.bandwidth_mhz) : '';

		push(parts, sprintf('lte=[plmn %s tac %d gci %d earfcn %d pci %d%s%s%s neigh %d]',
			lte.plmn, lte.tac, lte.global_cell_id, lte.earfcn, lte.serving_cell_id, band, bw,
			serving ? sprintf(' rsrp %.1f rsrq %.1f', serving.rsrp / 10.0, serving.rsrq / 10.0) : '',
			length(lte.cells ?? [])));
	}

	let nr = cells?.nr5g_cell;

	if (nr) {
		let sn = cells?.serving?.nr;
		let band = (sn?.band != null) ? sprintf(' band %s', sn.band) : '';

		push(parts, sprintf('nr5g=[plmn %s tac %d pci %d arfcn %d%s rsrp %.1f rsrq %.1f snr %.1f]',
			nr.plmn, nr.tac, nr.pci, cells?.nr5g_arfcn ?? 0, band,
			nr.rsrp / 10.0, nr.rsrq / 10.0, nr.snr / 10.0));
	}

	// signal: i16 metrics report -32768 when absent (filter per field). rsrp/rssi
	// are dBm (%d); snr is 0.1 dB (%.1f).
	let sig_part = (label, fields) => {
		let out = [];

		for (let name, spec in fields)
			if (spec[0] != null && !tlv.is_unavailable(spec[0], 'i16'))
				push(out, sprintf('%s %s', name,
					spec[1] ? sprintf('%.1f', spec[0] / 10.0) : sprintf('%d', spec[0])));

		if (length(out))
			push(parts, sprintf('%s=[%s]', label, join(' ', out)));
	};

	if (sig?.lte)
		sig_part('sig_lte', { rssi: [ sig.lte.rssi, false ],
			rsrp: [ sig.lte.rsrp, false ], snr: [ sig.lte.snr, true ] });
	else if (sig != null && (sig.rsrp != null || sig.rssi != null))
		// native-MBIM flat signal (a single coded/dBm reading, no per-tech split)
		sig_part('sig', { rssi: [ sig.rssi, false ], rsrp: [ sig.rsrp, false ] });

	if (sig?.nr5g)
		sig_part('sig_nr5g', { rsrp: [ sig.nr5g.rsrp, false ], snr: [ sig.nr5g.snr, true ] });

	if (o.temperature?.celsius != null)
		push(parts, sprintf('temp=%dC', o.temperature.celsius));

	if (length(cfg.lock_4g ?? []))
		push(parts, sprintf('lock_4g=%s', join(',', cfg.lock_4g)));

	if (cfg.lock_5g)
		push(parts, sprintf('lock_5g=%s', cfg.lock_5g));

	if (rd?.reject_text != null || rd?.reject_cause != null)
		push(parts, sprintf('reject=%s', rd.reject_text ?? sprintf('%d', rd.reject_cause)));

	if (rd?.limited)
		push(parts, 'limited_service');

	return join(' ', parts);
};
