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
//   watch()               (optional) keep the cell telemetry fresh, called on
//                         every tick while a lock is pending
//   forbidden(cb)         (optional) cb([ 'mccmnc' ]): the card's forbidden
//                         networks, asked only with networks 'allowed'

'use strict';

import * as cell_lock from 'wwand.cell_lock';
import * as atcmd from 'wwand.atcmd';
import * as arfcn_bands from 'wwand.codec.arfcn_bands';
import * as sim_plmn from 'wwand.sim_plmn';

export const DEFAULTS = {
	rsrp_min: -105,          // dBm: a target weaker than this is not worth a lock
	max_drop: 20,            // dB: never trade more signal than this for an anchor
	scan_interval: 21600,    // s between discovery scans (a QSCAN costs ~16 s of data)
	first_scan: 120,         // s after enabling, so the bring-up has settled
	acquire_s: 15,           // the target must be serving and registered by then
	anchor_s: 60,            // ...and advertise EN-DC by then
	weak_s: 30,              // RSRP below rsrp_min this long on the locked cell
	block_s: 21600,          // a cell that failed is not tried again for this long
	// which networks a target may be on: 'registered' (the one the card is on)
	// or 'allowed' (any the card may use — a GDSP or other multi-network
	// roaming SIM — minus its forbidden list and networks that failed)
	networks: 'registered',
	switch_gain: 10,         // dB a target must beat an ANCHORED serving cell by
	own_bonus: 6,            // dB a cell of the registered network is preferred by:
	                         //    another network costs a re-registration
	acquire_foreign_s: 45,   // registering on another network takes longer
};

const FAST_MS = 3000, SLOW_MS = 10000;

let key = (c) => sprintf('%d:%d', c.earfcn, c.pci);
let plmn_eq = (a, b) => a != null && b != null && replace(a, '/', '') == replace(b, '/', '');
let pkey = (p) => replace(p ?? '', '/', '');

// candidates(scan, cur, reg_plmn, blocked, o, ctx): the cells worth a lock,
// best first. With o.networks 'registered' never another PLMN's cell: a hosted
// cell of another PLMN carries that operator's settings, and is what the
// modem is usually stuck on. With 'allowed' (a card that may use several
// networks) any PLMN the card does not have as forbidden (ctx.forbidden, EF
// FPLMN) and that has not failed here (ctx.blocked_plmn). A cell whose PLMN
// the source does not name (AT$QCRSRP) ranks after every known one; locked, a
// foreign one is not acquired and ends up blocked.
// ctx.anchored: the serving cell already offers EN-DC — then only a target at
// least o.switch_gain stronger is worth the move.
// Never the current serving cell (what we leave), never a blocked one.
// Ranked by: seen with an anchor, PLMN known, RSRP (+own_bonus for the
// registered network's cells: another network costs a re-registration).
export function candidates(scan, cur, reg_plmn, blocked, o, ctx)
{
	ctx = ctx ?? {};

	let floor = o.rsrp_min, drop = o.max_drop;
	let here = cur ? key(cur) : null;
	let allowed = (o.networks == 'allowed');
	let own = (c) => plmn_eq(c.plmn, reg_plmn);
	let ok_plmn = (c) => c.plmn == null || own(c) ||
		(allowed && !ctx.forbidden?.[pkey(c.plmn)] && !ctx.blocked_plmn?.[pkey(c.plmn)]);
	let out = filter(scan ?? [], (c) =>
		c.earfcn != null && c.pci != null && c.rsrp != null &&
		ok_plmn(c) && key(c) != here && !blocked[key(c)] &&
		c.rsrp >= floor && (cur?.rsrp == null || c.rsrp >= cur.rsrp - drop) &&
		(!ctx.anchored || (cur?.rsrp != null && c.rsrp >= cur.rsrp + (o.switch_gain ?? 10))));
	let known = (c) => (c.plmn != null) ? 1 : 0;
	let score = (c) => c.rsrp + (own(c) ? (o.own_bonus ?? 0) : 0);

	return sort(out, (a, b) => ((b.anchor ? 1 : 0) - (a.anchor ? 1 : 0)) ||
		(known(b) - known(a)) || (score(b) - score(a)));
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
		blocked_plmn: {},    // network -> { until, why }: a move onto it failed
		target_plmn: null,   // the network of the cell being locked
		left_plmn: null,     // the network a move onto another one started from
		acquire_lim: cfg.acquire_s,
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
			self.target_plmn = null;
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
			k, c.band ?? '?', c.rsrp, c.plmn ?? 'network unknown'));
		let my_round = round;

		let reg = fx.reg_plmn();
		let foreign = (c.plmn != null && reg != null && !plmn_eq(c.plmn, reg));

		self.target = k;
		self.target_plmn = c.plmn;
		self.acquire_lim = foreign ? cfg.acquire_foreign_s : cfg.acquire_s;
		// only a move has a network it started from: a lock on the own
		// network must not count as one (moving() would shield it)
		self.left_plmn = foreign ? reg : null;
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

			let choose = (forbidden) => {
				if (self.stopped || stopping || my_round != round)
					return;

				let obs = fx.observe();
				let bp = {};

				for (let n, b in self.blocked_plmn)
					bp[n] = true;

				self.queue = candidates(cells, obs.serving, fx.reg_plmn(), self.blocked, cfg,
					{ forbidden: forbidden, blocked_plmn: bp, anchored: !!obs.anchor });

				if (!length(self.queue)) {
					self.next_scan = fx.now() + cfg.scan_interval;
					set('idle', obs.anchor
						? sprintf('the serving cell offers EN-DC and no cell is %d dB stronger', cfg.switch_gain)
						: 'no better cell in reach');
					return schedule();
				}

				try_next(my_round);
			};

			// the card's forbidden networks matter only when other networks may be chosen
			if (cfg.networks != 'allowed' || type(fx.forbidden) != 'function')
				return choose({});

			fx.forbidden((list) => {
				let f = {};
				for (let p in (list ?? []))
					f[pkey(p)] = true;
				choose(f);
			});
		});
	};

	tick = () => {
		if (self.stopped)
			return;

		let now = fx.now();

		for (let k, b in self.blocked)
			if (b.until <= now)
				delete self.blocked[k];

		for (let k, b in self.blocked_plmn)
			if (b.until <= now)
				delete self.blocked_plmn[k];

		// a pending lock is judged on FRESH cells: telemetry refreshes them
		// only while someone watches (modem_cells), otherwise on its slow loop,
		// and the 15/60 s deadlines then read a cell list from before the
		// lock. The T99W175 moved within 2 s but was released for "not
		// serving within 15 s" — nobody was watching (2026-11-21). watch()
		// decays after 6 s, so one call per FAST_MS tick keeps it running.
		if (self.state == 'locking' || self.state == 'locked')
			fx.watch?.();

		let obs = fx.observe();
		let here = obs.serving ? key(obs.serving) : null;

		// a new registered network. Steering's own moves are not one: onto the
		// target's network while locking it, or back to the one it left after
		// a failed attempt. Anything else (roaming moved on) ends the round and
		// any lock, and a scan follows soon; what was learned about cells and
		// networks is kept — a blocked cell is still not worth a second try.
		let plmn = fx.reg_plmn();
		if (plmn != null && plmn != self.plmn) {
			let old = self.plmn;
			let held = (self.state == 'locking' || self.state == 'locked' || self.state == 'verified');
			let ours = held && plmn_eq(plmn, self.target_plmn);
			let back = plmn_eq(plmn, self.left_plmn);

			self.plmn = plmn;

			if (back)
				self.left_plmn = null;

			if (old != null && !ours && !back) {
				log('info', sprintf('anchor steering: registered network %s -> %s, starting over', old, plmn));
				round++;
				self.queue = [];
				self.failed_rounds = 0;
				self.left_plmn = null;

				if (held)
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
			// with one network, an anchor is the end of it; with several, a
			// clearly stronger cell elsewhere may still be worth the move
			if (obs.anchor && cfg.networks != 'allowed') {
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
			// a move is acquired once the REGISTRATION is on the target's
			// network too: the cell list can show the target first, and a
			// "locked" move would stop being moving() while the session it
			// ends is still being torn down (Codex review)
			if (here == self.target && obs.registered &&
			    (self.left_plmn == null || plmn_eq(fx.reg_plmn(), self.target_plmn))) {
				log('notice', sprintf('anchor steering: on %s', here));
				set('locked', null);
				break;
			}
			if (now - self.since >= self.acquire_lim) {
				block(self.target, 'not acquired');
				// another network that would not take the card: not again soon
				if (self.target_plmn != null && self.left_plmn != null)
					self.blocked_plmn[pkey(self.target_plmn)] = { until: now + cfg.block_s,
						why: sprintf('%s not acquired', self.target) };
				let r = round;
				return self.release(sprintf('%s not serving within %d s', self.target, self.acquire_lim),
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
					// the move is done: a later change back is a real one
					self.left_plmn = null;
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

	// moving(): a lock onto ANOTHER network is being acquired. That move ends
	// the data session by design (a re-registration), and the daemon reports
	// the end as a connection failure — releasing on it aborted every move a
	// second after it began (X3000, Vodafone -> Telekom 6400:13, 2026-11-21).
	// While moving, the acquire_foreign_s deadline decides, not the failure.
	self.moving = function() {
		return self.state == 'locking' && self.left_plmn != null && self.target_plmn != null;
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
			networks: cfg.networks,
			target_plmn: self.target_plmn,
			failed_rounds: self.failed_rounds,
			since_s: now - self.since,
			reason: self.reason,
			last_scan_s: (self.last_scan != null) ? now - self.last_scan : null,
			next_scan_s: (self.state == 'idle' || self.state == 'backoff') ? ((self.next_scan > now) ? self.next_scan - now : 0) : null,
			scan_source: self.scan_source,
			cells: map(self.cells, (c) => ({ ...c, blocked: !!self.blocked[key(c)] })),
			blocked: map(keys(self.blocked), (k) => ({ cell: k, why: self.blocked[k].why,
				for_s: self.blocked[k].until - now })),
			blocked_networks: map(keys(self.blocked_plmn), (k) => ({ plmn: k,
				why: self.blocked_plmn[k].why, for_s: self.blocked_plmn[k].until - now })),
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

	if (self._steer_no_qscan || type(at?.send) != 'function' || self.cell_lock_dialect != 'quectel')
		return cb('no AT cell scan (AT+QSCAN is Quectel)');

	at.send('AT+QSCAN=1,1', (e, r) => {
		// a Quectel without it (EG06-E, BG96: ERROR, 2026-11-21) is not asked again
		if (e?.error == 'ERROR' || e?.error == 'cme')
			self._steer_no_qscan = true;
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

// The third source: what a Qualcomm modem measures by itself (AT$QCRSRP?),
// answered by every Qualcomm modem here, the T99W175 included, which has no
// cell scan at all (2026-11-21). No data gap, but no PLMN per cell, and only
// the layers the network lets the modem measure — a hosted cell that ranks
// its own layer above the others hides exactly the cells steering looks for,
// which is why it comes after the two scans. A refusal is remembered.
function scan_qcrsrp(self, cb)
{
	let at = self.at;

	if (self._steer_no_qcrsrp || type(at?.send) != 'function')
		return cb('no AT$QCRSRP');

	at.send('AT$QCRSRP?', (e, r) => {
		let cells = e ? [] : atcmd.parse_qcrsrp(r?.lines);

		if (!length(cells)) {
			// only the modem's own refusal (non-Qualcomm AT: ERROR) is
			// remembered — a timeout or a busy port says nothing about support
			if (e?.error == 'ERROR' || e?.error == 'cme')
				self._steer_no_qcrsrp = true;
			return cb(e ? sprintf('AT$QCRSRP?: %J', e) : 'AT$QCRSRP? lists no cell');
		}

		cb(null, map(cells, (c) => ({
			plmn: null, earfcn: c.earfcn, pci: c.pci, rsrp: c.rsrp,
			band: (arfcn_bands.lte_band(c.earfcn)?.band != null)
				? +replace(arfcn_bands.lte_band(c.earfcn).band, /^B/, '') : null,
		})));
	}, { probe: true });
}

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
		// the fast telemetry, as a modem_cells poll starts it
		watch: () => self.watch?.(),
		// the card's forbidden networks (EF FPLMN) as 'mccmnc', [] when unreadable
		forbidden: (cb) => sim_plmn.read_fplmn(self, (l) => cb(map(l ?? [], (e) => e.mcc + e.mnc))),

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

		// QMI PCI scan, else AT+QSCAN (Quectel), else the measured cells
		scan: (cb) => scan_qmi(self, (e, cells) => {
			if (!e)
				return cb(null, cells, 'qmi');
			scan_at(self, (e2, cells2) => {
				if (!e2)
					return cb(null, cells2 ?? [], 'qscan');
				scan_qcrsrp(self, (e3, cells3) => cb(e3 ? sprintf('%s; %s; %s', e, e2, e3) : null,
					cells3 ?? [], 'qcrsrp'));
			});
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
	if (cfg?.steer_networks == 'allowed')
		o.networks = 'allowed';

	return o;
};
