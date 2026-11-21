// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — anchor steering: move a FIXED modem's LTE primary cell onto a cell
// that advertises EN-DC, with a lock that is volatile, supervised and cleared
// the moment it does not deliver. `option anchor_steering 'auto'` on the
// wwand_modem; the measurements and the rules are docs/design/anchor-steering.md.
//
// Why it is needed: a CPE camps where the network's idle rules put it, and a
// strong cell another operator hosts can hold it there for ever — no EN-DC on
// that cell, and its SIB5 ranks its own layer highest, so the modem never even
// measures the operator's own cells. The NR7101 sat on such a B20 cell
// (broadcasting 262/02, registered 262/01); locked to the operator's own B20
// cell it reported the anchor after 8 s and an NR5G-NSA leg on n1 (2026-11-21).
//
// What it never does, and why each matters:
//   - exclude a band. The lock names the primary cell only; carrier
//     aggregation and the NR leg are the network's to add.
//   - leave a lock behind. The lock is set with saving off
//     (cell_lock.runtime_lte), released on every failure, on stop(), and
//     before any recovery rung (the daemon wraps note_connect_failure); and the
//     init's cell_lock.sync releases any lock the config does not ask for, which
//     catches a daemon that died holding one.
//   - wait out a lock on a cell that is not there. Measured: data gone after
//     3 s, then SEARCH / limited service for as long as the lock stayed, while
//     wwand's own logic held the interfaces up for 74 s without noticing. So a
//     lock that is not the serving cell within acquire_s is cleared — and
//     clearing it brought data back in 10 s with every PDN session intact.
//   - touch the radio during a voice call (fx.busy).
//
// Everything lives in this object: the learned cells, the block list, the
// state. Nothing is written to a file; a restart learns again.
//
// fx (injected; modem_fx() below builds it for a real modem):
//   now()                 monotonic seconds
//   timer(ms, cb)         { cancel() }
//   observe()             { serving: { earfcn, pci, rsrp } | null, registered,
//                           anchor: bool | null, stalled: bool }
//   reg_plmn()            'mcc/mnc' the card is registered on, or null
//   scan(cb)              cb(err, [ { plmn, earfcn, pci, rsrp, band } ], source)
//   lock(cells, cb)       cb(err) — cells [ 'earfcn:pci' ], [] releases
//   busy()                a reason not to change the radio now, or null

'use strict';

import * as cell_lock from 'wwand.cell_lock';
import * as atcmd from 'wwand.atcmd';
import * as arfcn_bands from 'wwand.codec.arfcn_bands';

export const DEFAULTS = {
	rsrp_min: -105,          // dBm: a target weaker than this is not worth a lock
	max_drop: 20,            // dB: never trade more signal than this for an anchor
	scan_interval: 21600,    // s between discovery scans (a QSCAN costs ~16 s of data)
	first_scan: 120,         // s after enabling, so the bring-up has settled
	acquire_s: 15,           // the target must be serving and registered by then
	anchor_s: 60,            // ...and advertise EN-DC by then
	weak_s: 30,              // RSRP below rsrp_min this long on the locked cell
	block_s: 21600,          // a cell that failed is not tried again for this long
};

const FAST_MS = 3000, SLOW_MS = 10000;

let key = (c) => sprintf('%d:%d', c.earfcn, c.pci);
let plmn_eq = (a, b) => a != null && b != null && replace(a, '/', '') == replace(b, '/', '');

// candidates(scan, cur, reg_plmn, blocked, o): the cells worth a lock, best
// first. Only the registered PLMN's own cells: a hosted cell of another PLMN
// carries that operator's settings, and is what the modem is usually stuck on.
// The current serving cell is never a candidate (it is what we leave), nor a
// blocked one. Ranked by: seen with an anchor, then RSRP.
export function candidates(scan, cur, reg_plmn, blocked, o)
{
	let floor = o.rsrp_min, drop = o.max_drop;
	let here = cur ? key(cur) : null;
	let out = filter(scan ?? [], (c) =>
		c.earfcn != null && c.pci != null && c.rsrp != null &&
		plmn_eq(c.plmn, reg_plmn) && key(c) != here && !blocked[key(c)] &&
		c.rsrp >= floor && (cur?.rsrp == null || c.rsrp >= cur.rsrp - drop));

	return sort(out, (a, b) => ((b.anchor ? 1 : 0) - (a.anchor ? 1 : 0)) || (b.rsrp - a.rsrp));
};

export function create(o)
{
	let fx = o.fx;
	let cfg = { ...DEFAULTS, ...(o.config ?? {}) };
	let log = o.log ?? ((lvl, msg) => null);
	let self = {
		state: 'idle',
		target: null,        // 'earfcn:pci'
		since: fx.now(),
		reason: null,
		last_scan: null,
		scan_source: null,
		cells: [],           // last scan, as seen
		blocked: {},         // 'earfcn:pci' -> { until, why }
		anchors: {},         // 'earfcn:pci' -> true once seen advertising EN-DC
		next_scan: fx.now() + cfg.first_scan,
		queue: [],           // remaining candidates of this round
		stopped: false,
		// rounds in a row where every candidate failed: a visited network that
		// gives a roaming SIM no EN-DC at all (GDSP and other global roaming
		// cards) would otherwise cost a scan and a lock attempt per cell every
		// interval for nothing — the wait doubles, up to 8 intervals
		failed_rounds: 0,
		plmn: null,          // the registered network the learned state is for
	};
	let timer = null, weak_since = null;
	let tick, try_next;
	// lock writes strictly one at a time: a set and a release are each a
	// probe/write/read chain, and two chains interleaved could land the set
	// AFTER the release — a lock left behind, the one thing this must not do
	let lockq = [], lock_busy = false, stopping = false;
	// bumped by before_recovery: a scan or lock started before it is stale
	let round = 0;
	let do_lock;
	do_lock = (cells, cb) => {
		push(lockq, { cells: cells, cb: cb });

		if (lock_busy)
			return;

		lock_busy = true;
		let next;
		next = () => {
			let op = shift(lockq);

			if (!op) {
				lock_busy = false;
				return;
			}

			fx.lock(op.cells, (err) => {
				op.cb(err);
				next();
			});
		};
		next();
	};

	let set = (state, reason) => {
		self.state = state;
		self.since = fx.now();
		if (reason != null)
			self.reason = reason;
	};

	let block = (k, why) => {
		self.blocked[k] = { until: fx.now() + cfg.block_s, why: why };
	};

	let schedule = () => {
		if (self.stopped)
			return;
		timer?.cancel();
		// a held lock is supervised every FAST_MS: a lock on a cell that went
		// away costs data within 3 s (measured), so "clear at once" means this
		let fast = (self.state == 'locking' || self.state == 'locked' || self.state == 'verified');
		timer = fx.timer(fast ? FAST_MS : SLOW_MS, () => tick());
	};

	// release(reason, cb): clear the lock this object holds, if any. Always
	// calls back; a failed release is logged and left to cell_lock.sync at the
	// next init (and the deadline logic never re-locks on top of it).
	let release_waiters = [];

	self.release = function(reason, cb) {
		cb = cb ?? (() => null);

		// one release at a time, and a second caller waits for it: a stop()
		// that returned while the release was still on its way let the daemon
		// tear the transport down under it (Codex review)
		if (self.state == 'releasing')
			return push(release_waiters, cb);

		if (self.state != 'locking' && self.state != 'locked' && self.state != 'verified')
			return cb();

		push(release_waiters, cb);

		let t = self.target;

		log('notice', sprintf('anchor steering: releasing the lock on %s (%s)', t, reason));
		set('releasing', reason);
		do_lock([], (err) => {
			if (err)
				log('warn', sprintf('anchor steering: release of %s: %s', t, err));
			self.target = null;
			weak_since = null;
			// no new scan right after a release: a remaining candidate of this
			// round is still tried (try_next), a new round waits an interval
			self.next_scan = fx.now() + cfg.scan_interval;
			set('backoff', reason);

			let waiters = release_waiters;
			release_waiters = [];
			for (let w in waiters)
				w();
		});
	};

	// `r`: the round this continuation belongs to — a release callback from a
	// round a recovery step or a network change ended must not go on with it
	// (nor count it as failed)
	try_next = (r) => {
		if (self.stopped || stopping)
			return;

		if (r != null && r != round)
			return schedule();

		let busy = fx.busy();

		if (busy) {
			self.queue = [];
			set('idle', busy);
			return schedule();
		}

		let c = shift(self.queue);

		if (!c) {
			// the round tried every candidate and none was kept
			if (self.state == 'backoff')
				self.failed_rounds++;
			let f = (self.failed_rounds < 3) ? self.failed_rounds : 3;
			set(self.state == 'backoff' ? 'backoff' : 'idle', self.reason);
			self.next_scan = fx.now() + cfg.scan_interval * (1 << f);
			return schedule();
		}

		let k = key(c);

		log('notice', sprintf('anchor steering: locking the primary cell on %s (B%s, %d dBm, %s)',
			k, c.band ?? '?', c.rsrp, c.plmn));
		let my_round = round;

		self.target = k;
		set('locking', null);
		do_lock([ k ], (err) => {
			// overtaken by stop() or a recovery step: their release is queued
			// behind this write and clears it; nothing more happens here
			if (self.stopped || stopping || my_round != round)
				return;
			if (err) {
				block(k, sprintf('lock refused: %s', err));
				// the write may still have half-taken: clear before going on
				return self.release(sprintf('lock refused: %s', err), () => try_next(my_round));
			}
			set('locking', null);
			schedule();
		});
	};

	let start_round = () => {
		let my_round = round;

		set('scanning', null);
		fx.scan((err, cells, source) => {
			if (self.stopped || stopping)
				return;

			// a recovery step ran while scanning: the result is not acted on
			if (my_round != round) {
				set('backoff', 'a recovery step ran during the scan');
				return schedule();
			}

			self.last_scan = fx.now();
			self.scan_source = source;

			if (err) {
				self.next_scan = fx.now() + cfg.scan_interval;
				set('idle', sprintf('scan failed: %s', err));
				return schedule();
			}

			for (let c in cells)
				c.anchor = !!self.anchors[key(c)];

			self.cells = cells;

			let obs = fx.observe();
			self.queue = candidates(cells, obs.serving, fx.reg_plmn(), self.blocked, cfg);

			if (!length(self.queue)) {
				self.next_scan = fx.now() + cfg.scan_interval;
				set('idle', 'no better cell of the registered network in reach');
				return schedule();
			}

			try_next(my_round);
		});
	};

	tick = () => {
		if (self.stopped)
			return;

		let now = fx.now();

		for (let k, b in self.blocked)
			if (b.until <= now)
				delete self.blocked[k];

		let obs = fx.observe();
		let here = obs.serving ? key(obs.serving) : null;

		// a new registered network (roaming moved on): its cells and its
		// rules are not the last one's — forget what was learned there
		let plmn = fx.reg_plmn();
		if (plmn != null && plmn != self.plmn) {
			let old = self.plmn;

			self.plmn = plmn;

			if (old != null) {
				log('info', sprintf('anchor steering: registered network %s -> %s, starting over', old, plmn));
				// the round, a scan out and a lock all belong to the old network
				round++;
				self.queue = [];
				self.blocked = {};
				self.anchors = {};
				self.failed_rounds = 0;

				if (self.state == 'locking' || self.state == 'locked' || self.state == 'verified')
					return self.release('the registered network changed', () => {
						self.next_scan = fx.now() + cfg.first_scan;
						schedule();
					});

				self.next_scan = now + cfg.first_scan;
			}
		}

		if (obs.anchor && here)
			self.anchors[here] = true;

		switch (self.state) {
		case 'scanning':
		case 'releasing':
			return;   // the callback reschedules

		case 'idle':
		case 'backoff': {
			if (now < self.next_scan || !obs.registered || !obs.serving)
				break;
			if (obs.anchor) {
				self.next_scan = now + cfg.scan_interval;
				set('idle', 'the serving cell already advertises EN-DC');
				break;
			}
			let busy = fx.busy();
			if (busy) {
				set(self.state, busy);
				break;
			}
			return start_round();
		}

		case 'locking':
			if (here == self.target && obs.registered) {
				log('notice', sprintf('anchor steering: on %s', here));
				set('locked', null);
				break;
			}
			if (now - self.since >= cfg.acquire_s) {
				block(self.target, 'not acquired');
				let r = round;
				return self.release(sprintf('%s not serving within %d s', self.target, cfg.acquire_s),
					() => try_next(r));
			}
			break;

		case 'locked':
		case 'verified': {
			let lost = (here != self.target) ? sprintf('serving cell is %s', here ?? 'none')
				: (!obs.registered ? 'registration lost'
				: (obs.stalled ? 'data path stalled' : null));

			if (lost) {
				block(self.target, lost);
				return self.release(lost, () => schedule());
			}

			if (obs.serving.rsrp != null && obs.serving.rsrp < cfg.rsrp_min) {
				weak_since = weak_since ?? now;
				if (now - weak_since >= cfg.weak_s) {
					block(self.target, 'weak');
					return self.release(sprintf('RSRP %d dBm below %d for %d s', obs.serving.rsrp, cfg.rsrp_min, cfg.weak_s),
						() => schedule());
				}
			}
			else
				weak_since = null;

			if (self.state == 'locked') {
				if (obs.anchor) {
					log('notice', sprintf('anchor steering: %s advertises EN-DC — keeping the lock', here));
					self.failed_rounds = 0;
					set('verified', null);
				}
				else if (now - self.since >= cfg.anchor_s) {
					block(self.target, 'no anchor');
					let r = round;
					return self.release(sprintf('%s advertised no EN-DC within %d s', here, cfg.anchor_s),
						() => try_next(r));
				}
			}
			break;
		}
		}

		schedule();
	};

	// called by the daemon right before a recovery rung: a lock wwand set must
	// never be what the ladder is fighting
	self.before_recovery = function(cb) {
		round++;
		self.queue = [];
		self.next_scan = fx.now() + cfg.scan_interval;

		if (self.target)
			block(self.target, 'recovery');
		self.release('a recovery step is about to run', cb);
	};

	self.stop = function(cb) {
		let done_cb = cb ?? (() => null);

		stopping = true;
		timer?.cancel();
		timer = null;
		self.release('steering stopped', () => {
			self.stopped = true;
			set('off', 'stopped');
			done_cb();
		});
	};

	self.status = function() {
		let now = fx.now();
		return {
			state: self.state,
			target: self.target,
			plmn: self.plmn,
			failed_rounds: self.failed_rounds,
			since_s: now - self.since,
			reason: self.reason,
			last_scan_s: (self.last_scan != null) ? now - self.last_scan : null,
			next_scan_s: (self.state == 'idle' || self.state == 'backoff') ? ((self.next_scan > now) ? self.next_scan - now : 0) : null,
			scan_source: self.scan_source,
			cells: map(self.cells, (c) => ({ ...c, blocked: !!self.blocked[key(c)] })),
			blocked: map(keys(self.blocked), (k) => ({ cell: k, why: self.blocked[k].why,
				for_s: self.blocked[k].until - now })),
		};
	};

	self.tick = tick;
	schedule();

	return self;
};

// --- the bridge to a real modem ------------------------------------------------

// QMI cell scan first (Perform Network Scan, type 3 PCI). Refused with 70
// (InvalidOperation) or 48 (InvalidArgument) by the RG502Q-EA and the
// RG650E-EU in every state tried (2026-11-21, docs/qmi-beyond-libqmi.md); a
// refusal is remembered for the modem's lifetime and AT+QSCAN takes over.
// Neither path excludes a band from the modem's configuration: the QMI band
// mask is for the scan only, and QSCAN scans what the modem supports.
function scan_qmi(self, cb)
{
	if (self._steer_no_qmi_scan || type(self.with_nas) != 'function')
		return cb('no QMI cell scan');

	self.with_nas((nas) => {
		if (!nas)
			return cb('no NAS client');

		nas.request('NETWORK_SCAN', { network_type: 0x04, scan_type: 3 }, (e, d) => {
			if (e) {
				if (e.error == 'qmi' && (e.code == 70 || e.code == 48))
					self._steer_no_qmi_scan = true;
				return cb(sprintf('%J', e));
			}

			let pi = d?.pci_info;
			// ONE signal block for the whole set (IDL); unit per the IDL
			// signal_info type (dBm × 10 like the other NAS cell reads) —
			// not yet seen from a modem, see the schema
			let rsrp = (pi?.rsrp != null) ? int(pi.rsrp / 10) : null;
			let cells = map(pi?.cells ?? [], (c) => ({
				// pcs: the MNC has three digits (310/001 is not 310/01)
				plmn: c.plmn?.[0] ? sprintf(c.plmn[0].pcs ? '%d/%03d' : '%d/%02d',
					c.plmn[0].mcc, c.plmn[0].mnc) : null,
				earfcn: c.freq, pci: c.pci, rsrp: rsrp,
				band: (arfcn_bands.lte_band(c.freq)?.band != null)
					? +replace(arfcn_bands.lte_band(c.freq).band, /^B/, '') : null,
			}));

			cb(length(cells) ? null : 'QMI scan returned no cells', cells);
		}, { timeout: 120000, no_recovery: true });
	});
}

function scan_at(self, cb)
{
	let at = self.at;

	if (type(at?.send) != 'function' || self.cell_lock_dialect != 'quectel')
		return cb('no AT cell scan (AT+QSCAN is Quectel)');

	at.send('AT+QSCAN=1,1', (e, r) => {
		if (e)
			return cb(sprintf('AT+QSCAN: %J', e));
		cb(null, atcmd.parse_qscan(r?.lines));
	}, { timeout: 180000 });
}

// reg_plmn(self): 'mcc/mnc' the modem is registered on, from its NAS/AT
// registration (mnc_digits keeps a three-digit MNC's leading zero), or null
export function reg_plmn(self)
{
	let p = self?.reg?.plmn;

	return (p?.mcc != null && p?.mnc != null)
		? sprintf((p.mnc_digits == 3) ? '%d/%03d' : '%d/%02d', p.mcc, p.mnc) : null;
};

// modem_fx(self, deps): fx for create() on a live modem object.
//   deps.now / deps.timer   clock and uloop timers
//   deps.registered()       the daemon's registration verdict (any backend)
//   deps.stalled()          the daemon's data-stall verdict for this modem
//   deps.busy()             why the radio must not be touched now, or null
export function modem_fx(self, log, deps)
{
	return {
		now: deps.now,
		timer: deps.timer,
		busy: deps.busy ?? (() => null),

		reg_plmn: () => reg_plmn(self),

		observe: () => {
			let li = self.cells?.lte_intra;
			let srv = filter(li?.cells ?? [], (c) => c.pci == li?.serving_cell_id)[0];
			let reg = self.reg;
			return {
				serving: (li?.earfcn != null && li?.serving_cell_id != null)
					? { earfcn: li.earfcn, pci: li.serving_cell_id,
					    rsrp: (srv?.rsrp != null) ? int(srv.rsrp / 10) : null } : null,
				// the daemon's backend-neutral verdict (QMI, MBIM and NCM shape
				// their registration differently); the QMI field without it
				registered: deps.registered ? !!deps.registered() : (reg?.registration == 1),
				// an NR leg IS the anchor: the System Info flag (nr5g_state,
				// polled) lagged the leg by almost a minute on the NR7101 —
				// verified at 58 s of a 60 s deadline while QENG and the DSD
				// already showed NR5G-NSA on n1 (2026-11-21)
				anchor: (self.dsd_status?.nr || self.cells?.serving?.nr != null || self.cells?.nr5g_cell != null)
					? true : (self.nr5g_state?.nsa_available ?? null),
				stalled: !!deps.stalled?.(),
			};
		},

		scan: (cb) => scan_qmi(self, (e, cells) => {
			if (!e)
				return cb(null, cells, 'qmi');
			scan_at(self, (e2, cells2) => cb(e2 ? sprintf('%s; %s', e, e2) : null, cells2 ?? [], 'qscan'));
		}),

		lock: (cells, cb) => cell_lock.runtime_lte(self, log, cells, (err) => cb(err)),
	};
};

// enabled(cfg): steering is on for this modem config. Off with a configured
// cell lock: the user's lock wins, and two writers would undo each other.
export function enabled(cfg)
{
	if (cfg?.anchor_steering != 'auto')
		return false;
	return !length(cell_lock.wanted(cfg).lte) && !cell_lock.wanted(cfg).nr5g;
};

export function config_of(cfg)
{
	let o = {};
	let n = (v) => (v != null && match(sprintf('%s', v), /^-?[0-9]+$/)) ? +v : null;

	if (n(cfg?.steer_rsrp_min) != null)
		o.rsrp_min = n(cfg.steer_rsrp_min);
	if (n(cfg?.steer_scan_interval) != null && n(cfg.steer_scan_interval) >= 600)
		o.scan_interval = n(cfg.steer_scan_interval);

	return o;
};
