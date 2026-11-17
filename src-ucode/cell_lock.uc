// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — cell locks: `option lock_4g` / `lock_5g` / `lock_persist` on the
// modem, through whichever command set it speaks.
//
// A cell lock is the one vendor setting every modem family spells its own
// way (ddimension/wwand#91), so it is a TABLE of dialects, not a code path
// per caller. Each entry answers the same four questions in the same
// dialect-neutral shape:
//
//   available(self)              can this modem be asked at all (an AT
//                                channel, a NAS client)?
//   read(self, cb)               cb(null, state) — or cb(err) when the modem
//                                does not know the command, which moves the
//                                search on to the next entry
//   write(self, log, want, plan, cb)
//                                set or release what `plan` names (lte, nr5g);
//                                cb(errors) — a list, empty when all went in
//   persist                      'save_ctrl' when the dialect can make a lock
//                                survive a power cycle on request (Quectel),
//                                null when the modem decides that itself
//
// state = { lte: [ 'earfcn:pci', ... ], nr5g: 'pci:arfcn:scs:band' | null,
//           nr5g_supported: bool } — the config's own spelling, so whether
// the modem already carries what the config asks for is a string compare.
//
// THE FIRST ENTRY WHOSE READ ANSWERS IS THE MODEM'S DIALECT. Nothing is ever
// written in a dialect the modem has not first answered a read in: that is
// what keeps a Quectel command off a modem that would take it for something
// else, and it is also what lets a modem without a known dialect say so
// (`lock_4g` warning "no known cell-lock command") instead of failing quietly.
//
// To add a family: a new entry with these four members, placed before `qmi`
// when its read is cheaper or more specific than the NAS one. Keep the
// state shape — sync() below and the tests only ever see that.

'use strict';

import * as atcmd from 'wwand.atcmd';
import * as nasmod from 'wwand.codec.schema.nas';

const LTE_RE = /^([0-9]+):([0-9]+)$/;
const NR_RE = /^([0-9]+):([0-9]+):([0-9]+):([0-9]+)$/;

// what the config asks for, in the state shape; malformed entries are
// dropped here exactly as atcmd.cell_lock_commands drops them. Numbers are
// normalised ('06300:246' -> '6300:246') because the modem reads them back
// as numbers: compared verbatim, a leading zero would rewrite the lock on
// every init and warn that it "is not applied".
export function wanted(cfg)
{
	let l4 = cfg?.lock_4g ?? [];

	if (type(l4) == 'string')
		l4 = [ l4 ];

	let lte = [];

	for (let e in l4) {
		let m = (type(e) == 'string') ? match(e, LTE_RE) : null;

		if (m)
			push(lte, sprintf('%d:%d', +m[1], +m[2]));
	}

	let l5 = cfg?.lock_5g;
	let m5 = (type(l5) == 'string') ? match(l5, NR_RE) : null;

	return {
		lte: lte,
		nr5g: m5 ? sprintf('%d:%d:%d:%d', +m5[1], +m5[2], +m5[3], +m5[4]) : null,
	};
};

let same_cells = (a, b) => join(',', sort([ ...(a ?? []) ])) == join(',', sort([ ...(b ?? []) ]));

// --- Quectel: AT+QNWLOCK ------------------------------------------------------
//
// The read of an unlocked modem is "common/4g",0 / "common/5g",0. A LOCKED
// 5G read has NO enable field — "common/5g",<pci>,<arfcn>,<scs>,<band>
// (RG502Q-EA, 2026-11-17), so the first number is the PCI, not a flag; the
// five-field form the Quectel note gives (<enable>,<pci>,…) is read too.
// An EG25-G, which has no 5G, answers the 5G read with a bare ERROR.

function quectel_nr5g(lines)
{
	let lk = atcmd.parse_qnwlock(lines);

	if (!lk?.enabled || length(lk.values) != 4)
		return null;

	return join(':', lk.values);
}

function quectel_lte(lines)
{
	let lk = atcmd.parse_qnwlock(lines);
	let out = [];

	if (!lk)
		return null;

	if (!lk.enabled)
		return out;

	for (let i = 0; i + 1 < length(lk.values); i += 2)
		push(out, sprintf('%d:%d', lk.values[i], lk.values[i + 1]));

	return out;
}

const QUECTEL = {
	name: 'quectel',
	persist: 'save_ctrl',

	available: (self) => type(self.at?.send) == 'function',

	read: (self, cb) => {
		// a probe: on another vendor's modem the bare ERROR is the expected
		// answer that hands the search to the next entry, not a warning
		self.at.send('AT+QNWLOCK="common/4g"', (e4, r4) => {
			if (e4)
				return cb(e4);

			// a bare OK is no answer: a modem that acks what it does not know
			// would otherwise be taken for a Quectel and get QNWLOCK writes
			let lte = quectel_lte(r4?.lines);

			if (lte == null)
				return cb({ error: 'no_answer', detail: 'no +QNWLOCK line' });

			self.at.send('AT+QNWLOCK="common/5g"', (e5, r5) => cb(null, {
				lte: lte,
				nr5g: e5 ? null : quectel_nr5g(r5?.lines),
				nr5g_supported: !e5,
			}), { probe: true });
		}, { probe: true });
	},

	write: (self, log, want, plan, cb) => {
		let cmds = [];
		let released = false;

		if (plan.lte) {
			if (length(want.lte))
				push(cmds, ...atcmd.cell_lock_commands({ lock_4g: want.lte }));
			else {
				push(cmds, 'AT+QNWLOCK="common/4g",0');
				released = true;
			}
		}

		if (plan.nr5g) {
			if (want.nr5g)
				push(cmds, ...atcmd.cell_lock_commands({ lock_5g: want.nr5g }));
			else {
				push(cmds, 'AT+QNWLOCK="common/5g",0');
				released = true;
			}
		}

		// save_ctrl stores the CURRENT lock state in NV. It follows a lock
		// only when `lock_persist` asks, and always follows a release: the
		// lock being cleared may have been saved by an EARLIER config, and
		// without it a power cycle restores it (HW-verified on the NR7101).
		if (length(cmds) && (released || want.persist))
			push(cmds, 'AT+QNWLOCK="save_ctrl",1,1');

		let errs = [];
		let step;

		step = (i) => {
			if (i >= length(cmds))
				return cb(errs);

			self.at.send(cmds[i], (e) => {
				if (e)
					push(errs, { command: cmds[i], error: e });

				step(i + 1);
			});
		};

		step(0);
	},
};

// --- Qualcomm NAS: SET/GET_CELL_CONFIG, the NR5G pair ---------------------------
//
// codec/schema/nas.uc has the messages and what was measured. The LTE read
// tries the u32 generation first and falls back to the deprecated u16 one;
// whichever answered is the one written, so a modem never gets a message it
// has just refused. The NR pair is separate: the RG650E-EU answers the LTE
// reads and refuses the NR one (94), the RG502Q-EA the other way round for
// the u32 LTE pair.

function nas_of(self, cb)
{
	if (type(self.with_nas) != 'function')
		return cb(null);

	self.with_nas(cb);
}

function nr5g_string(d)
{
	if (d?.type == null || d.type == 2)
		return null;

	// an ARFCN list (1) or several PCIs (3): set by something else, and not a
	// lock this config can express — named, so a release still sees it
	if (d.type != 0 || !d.cell_identity)
		return sprintf('type%d', d.type);

	let c = d.cell_identity;
	let khz = null, band = null;

	for (let k in nasmod.NR5G_SCS)
		if (nasmod.NR5G_SCS[k] == c.scs)
			khz = k;

	for (let w = 0; w < 8 && band == null; w++) {
		let v = c[sprintf('band%d', w + 1)] ?? 0;

		for (let b = 0; b < 64; b++)
			if ((v >> b) & 1) {
				band = w * 64 + b + 1;
				break;
			}
	}

	return sprintf('%d:%d:%s:%s', c.pci, c.arfcn, khz ?? '?', band ?? '?');
}

function nr5g_identity(spec)
{
	let m = match(spec, NR_RE);
	let scs = m ? nasmod.NR5G_SCS[m[3]] : null;
	let band = m ? +m[4] : 0;

	// the fields are u16 / u32: a value they cannot hold makes the encoder
	// throw, and sync would then never call back (see the LTE list below)
	if (scs == null || band < 1 || band > 512 || +m[1] > 0xffff || +m[2] > 0xffffffff)
		return null;

	let id = { pci: +m[1], scs: scs, arfcn: +m[2] };

	for (let w = 1; w <= 8; w++)
		id[sprintf('band%d', w)] = 0;

	id[sprintf('band%d', ((band - 1) >> 6) + 1)] = 1 << ((band - 1) & 63);

	return id;
}

const QMI = {
	name: 'qmi',
	persist: null,

	available: (self) => type(self.with_nas) == 'function',

	read: (self, cb) => nas_of(self, (nas) => {
		if (!nas)
			return cb({ error: 'no_nas' });

		let nr = (lte) => nas.request('GET_NR5G_CELL_CONFIG', {}, (en, dn) => cb(null, {
			lte: lte,
			nr5g: en ? null : nr5g_string(dn),
			nr5g_supported: !en,
		}), { no_recovery: true });

		let cells = (d) => map(d?.cell_list ?? [], (c) => sprintf('%d:%d', c.freq, c.pci));

		nas.request('GET_CELL_CONFIG', {}, (e, d) => {
			if (!e) {
				self._cell_lock_qmi = 'SET_CELL_CONFIG';
				return nr(cells(d));
			}

			nas.request('GET_CELL_LOCK_CONFIG', {}, (e2, d2) => {
				if (e2)
					return cb(e2);

				self._cell_lock_qmi = 'SET_CELL_LOCK_CONFIG';
				nr(cells(d2));
			}, { no_recovery: true });
		}, { no_recovery: true });
	}),

	write: (self, log, want, plan, cb) => nas_of(self, (nas) => {
		let errs = [];

		if (!nas)
			return cb([ { error: { error: 'no_nas' } } ]);

		let do_nr = () => {
			if (!plan.nr5g)
				return cb(errs);

			let args = { type: 2 };

			if (want.nr5g) {
				let id = nr5g_identity(want.nr5g);

				if (!id) {
					push(errs, { command: 'SET_NR5G_CELL_CONFIG', error: { error: 'invalid',
						detail: 'the PCI must fit 16 bits, the ARFCN 32, the scs be 15/30/60/120/240 kHz and the band 1..512' } });
					return cb(errs);
				}

				args = { type: 0, cell_identity: id };
			}

			nas.request('SET_NR5G_CELL_CONFIG', args, (e) => {
				if (e)
					push(errs, { command: 'SET_NR5G_CELL_CONFIG', error: e });

				cb(errs);
			}, { no_recovery: true });
		};

		if (!plan.lte)
			return do_nr();

		let msg = self._cell_lock_qmi ?? 'SET_CELL_CONFIG';
		let list = map(want.lte, (s) => {
			let m = match(s, LTE_RE);
			return { pci: +m[2], freq: +m[1] };
		});

		// A value its field cannot hold is refused here, not sent: the TLV
		// encoder (struct.pack) THROWS on it rather than truncating, so a
		// typo like '6300:65536' would abort the bring-up without sync ever
		// calling back (host ucode, 2026-11-17). The u16 generation takes
		// EARFCNs up to 65535 only — an LTE band 66 cell does not fit it.
		let fmax = (msg == 'SET_CELL_LOCK_CONFIG') ? 0xffff : 0xffffffff;

		if (length(filter(list, (c) => c.freq > fmax || c.pci > 0xffff))) {
			push(errs, { command: msg, error: { error: 'invalid',
				detail: sprintf('a PCI must fit 16 bits and an EARFCN %d bits on this modem', fmax == 0xffff ? 16 : 32) } });
			return do_nr();
		}

		nas.request(msg, { cell_list: list, enforce: 1 }, (e) => {
			if (e)
				push(errs, { command: msg, error: e });

			do_nr();
		}, { no_recovery: true });
	}),
};

export const DIALECTS = [ QUECTEL, QMI ];

// the modem's dialect and its current state: cb(dialect, state), or
// cb(null, null) when no entry's read answers
export function probe(self, cb, dialects)
{
	let list = dialects ?? DIALECTS;
	let next;

	next = (i) => {
		if (i >= length(list))
			return cb(null, null);

		let d = list[i];

		if (!d.available(self))
			return next(i + 1);

		d.read(self, (err, st) => err ? next(i + 1) : cb(d, st));
	};

	next(0);
};

// Bring the modem's locks to what the config asks for — read first, write
// only what differs, read back. Both directions: a configured lock is set, and
// a lock the config does not ask for is RELEASED. That second half is not
// tidiness: a lock nothing configures keeps the modem searching for a cell
// that may not be there, and with lock_persist it sits in NV and survives
// reboots — found on an NR7101 locked to EARFCN 1300 / PCI 246, a cell not
// receivable there: permanent "servingcell","SEARCH", never attached
// (2026-09-11); releasing it attached within seconds on EARFCN 6300.
//
// add(check, severity, message, expected, actual) reports what did not take;
// cb() always comes, once, and nothing here fails a bring-up.
export function sync(self, log, add, cb, dialects)
{
	let want = { ...wanted(self.config), persist: !!self.config?.lock_persist };

	probe(self, (d, cur) => {
		self.cell_lock_dialect = d?.name;

		if (!d) {
			if (length(want.lte))
				add('lock_4g', 'warn',
					sprintf('configured 4G cell lock [%s] is not applied: no known cell-lock command for this modem', join(',', want.lte)),
					want.lte, null);

			if (want.nr5g)
				add('lock_5g', 'warn',
					sprintf('configured 5G cell lock %s is not applied: no known cell-lock command for this modem', want.nr5g),
					want.nr5g, null);

			return cb();
		}

		let plan = {
			lte: !same_cells(want.lte, cur.lte),
			nr5g: cur.nr5g_supported && want.nr5g != cur.nr5g,
		};

		if (want.nr5g && !cur.nr5g_supported)
			add('lock_5g', 'warn',
				sprintf('configured 5G cell lock %s is not applied: the modem has no 5G lock (%s)', want.nr5g, d.name),
				want.nr5g, null);

		if (want.persist && !d.persist && (length(want.lte) || want.nr5g))
			add('lock_persist', 'info',
				sprintf('lock_persist has no effect with the %s cell-lock commands: whether a lock survives a power cycle is the modem\'s own setting', d.name),
				true, null);

		if (!plan.lte && !plan.nr5g)
			return cb();

		if (plan.lte && !length(want.lte))
			log('notice', 'modem reports a 4G cell lock the config does not ask for — releasing it (a lock nothing configured keeps the modem searching for a cell that may not be there)');

		if (plan.nr5g && !want.nr5g)
			log('notice', 'modem reports a 5G cell lock the config does not ask for — releasing it (a lock nothing configured keeps the modem searching for a cell that may not be there)');

		d.write(self, log, want, plan, (errs) => {
			for (let e in errs)
				log('warn', sprintf('cell lock (%s): %s failed: %J', d.name, e.command ?? '?', e.error));

			d.read(self, (err, now) => {
				now = err ? { lte: [], nr5g: null } : now;

				if (plan.lte && length(want.lte) && !same_cells(want.lte, now.lte))
					add('lock_4g', 'warn',
						sprintf('configured 4G cell lock [%s] is not applied on the modem', join(',', want.lte)),
						want.lte, length(now.lte) ? 'set' : 'off');

				if (plan.lte && !length(want.lte) && length(now.lte))
					add('lock_4g', 'warn',
						sprintf('a 4G cell lock is set on the modem and could not be released: %s', join(',', now.lte)),
						'released', 'still set');

				if (plan.nr5g && want.nr5g && now.nr5g != want.nr5g)
					add('lock_5g', 'warn',
						sprintf('configured 5G cell lock %s is not applied on the modem', want.nr5g),
						want.nr5g, now.nr5g ? 'set' : 'off');

				if (plan.nr5g && !want.nr5g && now.nr5g)
					add('lock_5g', 'warn',
						sprintf('a 5G cell lock is set on the modem and could not be released: %s', now.nr5g),
						'released', 'still set');

				cb();
			});
		});
	}, dialects);
};
