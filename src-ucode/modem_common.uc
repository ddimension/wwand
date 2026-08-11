// wwand — protocol-neutral helpers shared by the QMI/MBIM/NCM modem state
// machines (operate on the modem `self` object).

'use strict';

import * as uloop from 'uloop';
import * as atcmd from './atcmd.uc';
import * as netlink from './netlink.uc';
import * as tlv from './codec/tlv.uc';
import * as nasmod from './codec/schema/nas.uc';
import * as ratmod from './codec/schema/rat.uc';

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

// derive a coarse mode from NAS radio interfaces (last-resort fallback; can't
// see NSA — an NSA anchor reports LTE only here). radio_ifs: 8=LTE, 12=5GNR.
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
	CONFIGURING: true,     // QMI only (deferred-settings apply)
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

	return { emit: emit, notify_contexts: notify_contexts };
};

// install "record a failed connection cycle" for modems with no live DMS to
// cycle (MBIM, NCM): bump the recovery counter and run only the reboot/usb_repower
// rungs. QMI installs its own richer version that also cycles opmode / resets.
export function note_connect_failure_light(self, rec)
{
	self.note_connect_failure = function(done) {
		done = done ?? ((a) => null);

		let action = rec.on_attempt();

		if (action == 'reboot')
			rec.reboot('connection attempt limit reached');
		else if (action == 'usb_repower')
			rec.usb_repower();

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
export function make_fail(self, o)
{
	return (stage, err) => {
		o.log('err', sprintf('failed in %s: %J', stage, err));

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

// telemetry_at(self): the AT engine a telemetry poll runs over. Opens the modem's
// dedicated 'at2' channel lazily on first use (if it has one); otherwise returns
// the control channel (self.at). This keeps the second tty lazy: QMI/MBIM that
// never hit the AT fallback never open it; NCM opens it on its first tick.
//
// NEVER returns null: a torn-down modem (close_at ran — teardown/reload can happen
// synchronously under an emit while a poll callback is still in flight) gets a stub
// engine whose send() fails immediately, so the many unguarded
// `telemetry_at(self).send(...)` call sites degrade to an AT error instead of
// crashing on `null.send` (HW-hit: autosetup phase-2 reload on the Cudy LT300 tore
// the modem down inside the 'registered' emit; the READY hook then ran on the corpse).
export function telemetry_at(self)
{
	if (self._at2_open) {
		let open = self._at2_open;
		self._at2_open = null;      // one-shot: never retry a failed open per poll
		open();                     // sets self.at_telemetry on success
	}

	return self.at_telemetry ?? {
		send: (cmd, cb) => { if (cb) cb('closed', null); },
		run_sequence: (cmds, cb) => { if (cb) cb(); },
		close: () => null,
	};
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

	// authoritative supported-RAT families from the QMI DMS device capabilities
	// (radio_ifs list), when the backend has them — the honest base for caps.rats
	// on a 5G modem currently camped on LTE. DMS 5GNR=10 (not the NAS 12).
	let mode_caps = null;
	let cap_ifs = self.info?.capabilities?.radio_ifs;

	if (type(cap_ifs) == 'array') {
		mode_caps = [];
		for (let r in cap_ifs) {
			let o = ratmod.from_dms_radio_if(r);
			if (o && index(mode_caps, o.rat) < 0)
				push(mode_caps, o.rat);
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
	// and refresh the capability summary, then finish
	let finish = () => {
		self.rat_label = self.rat_fine ? ratmod.label(self.rat_fine) : null;

		if (self.rat_fine?.rat) {
			self._rats_seen = self._rats_seen ?? {};
			self._rats_seen[self.rat_fine.rat] = true;
		}

		collect_caps(self, cb);
	};

	if (!match(mfr, QNWINFO_VENDORS)) {
		self.rat_fine = null;
		return finish();
	}

	telemetry_at(self).send('AT+QNWINFO', (err, res) => {
		let info = err ? null : atcmd.parse_qnwinfo(res?.lines);
		self.rat_fine = info ? { rat: info.rat, mode: info.mode, ntn: false, src: 'qnwinfo' } : null;
		finish();
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
	self._at2_open = null;
};

// best-effort AT side-channel bring-up: discover + open the AT tty, run
// model-init + configured at_init + cell-lock commands, then o.next(). Always
// non-fatal (no usable AT port -> next() with self.at unset).
//   o = { at_opts?, log, drain_interval?, set_drain_timer, next, reopen_next? }
export function open_at(self, o)
{
	let log = o.log;

	if (self.at)
		return (o.reopen_next ?? o.next)();

	let fxi = o.at_opts?.fx ?? netlink.default_fx((level, msg) => log(level, msg));
	let ch = atcmd.find_at_channels(fxi, self.device, self.config.tty, o.base_override);
	let tty = ch.primary;

	if (!tty) {
		log('info', 'no AT port found');
		return o.next();
	}

	let open_transport = o.at_opts?.open_transport ?? atcmd.open_transport;
	let tr = open_transport(tty, 115200, (level, msg) => log(level, msg));

	if (!tr) {
		log('warn', sprintf('cannot open AT port %s', tty));
		return o.next();
	}

	self.at = atcmd.create(tr, { log: (level, msg) => log(level, sprintf('at: %s', msg)) });
	self.at_tty = tty;
	log('notice', sprintf('AT port: %s', tty));

	// dedicated telemetry channel ('at2'): telemetry polls run over a separate
	// engine so they don't serialize behind control/dial commands. Opened LAZILY
	// on the first poll (see telemetry_at) to avoid wasting an fd on QMI/MBIM that
	// rarely touch AT. Until it opens, telemetry falls back to the control channel.
	self.at_telemetry = self.at;
	self.at_telemetry_tty = tty;

	// config `at2_external`: the secondary AT port is reserved for EXTERNAL
	// tools (gpsd, user scripts, ...) — wwand must never open it. Telemetry
	// stays on the control channel; log which tty is being left alone.
	if (self.config?.at2_external && ch.telemetry && ch.telemetry != tty) {
		log('notice', sprintf('secondary AT port %s released for external use (at2_external)', ch.telemetry));
		self.at2_released = ch.telemetry;
		ch = { ...ch, telemetry: null };
	}

	// one-shot opener telemetry_at() runs on first use; null when there is no
	// distinct second AT port (telemetry then stays on control).
	self._at2_open = (ch.telemetry && ch.telemetry != tty)
		? () => {
			let tr2 = open_transport(ch.telemetry, 115200, (level, msg) => log(level, msg));

			if (!tr2) {
				log('warn', sprintf('cannot open AT telemetry channel %s (using control channel)', ch.telemetry));
				return;
			}

			self.at_telemetry = atcmd.create(tr2, { log: (level, msg) => log(level, sprintf('at2: %s', msg)) });
			self.at_telemetry_tty = ch.telemetry;
			log('notice', sprintf('AT telemetry channel: %s', ch.telemetry));
		}
		: null;

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

		push(parts, sprintf('lte=[plmn %s tac %d gci %d earfcn %d pci %d%s neigh %d]',
			lte.plmn, lte.tac, lte.global_cell_id, lte.earfcn, lte.serving_cell_id,
			serving ? sprintf(' rsrp %.1f rsrq %.1f', serving.rsrp / 10.0, serving.rsrq / 10.0) : '',
			length(lte.cells ?? [])));
	}

	let nr = cells?.nr5g_cell;

	if (nr)
		push(parts, sprintf('nr5g=[plmn %s tac %d pci %d arfcn %d rsrp %.1f rsrq %.1f snr %.1f]',
			nr.plmn, nr.tac, nr.pci, cells?.nr5g_arfcn ?? 0,
			nr.rsrp / 10.0, nr.rsrq / 10.0, nr.snr / 10.0));

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
