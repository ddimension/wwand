// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — SIM PLMN selector/forbidden-list codec + UIM EF read/write
// (extracted from sim.uc).
//
// Covers the TS 31.102 PLMN files: the PLMNwAcT selector lists (EF 6F60 user /
// 6F61 operator / 6F62 home), the forbidden list (EF_FPLMN 6F7B), the QMI NAS
// "preferred networks" list, and the generic transparent-EF reader used by the
// identity paths in sim.uc. All exported entry points are re-exported from
// sim.uc so consumers keep the stable sim.<name> API.

'use strict';

import * as hexmod from './codec/hex.uc';
import * as uimmod from './codec/schema/uim.uc';
import * as atcmd from './atcmd.uc';

// module-internal aliases (NOT re-exported; import codec/hex.uc directly)
const hex_to_arr = hexmod.hex_to_arr;
const arr_to_hex = hexmod.arr_to_hex;

// --- generic transparent-EF reader (shared with the identity paths) ----------

export function read_ef(modem, ef, cb, session_type)
{
	session_type = session_type ?? uimmod.SESSION_TYPE_PRIMARY_GW_PROVISIONING;

	// optional EF reads (PLMN lists, identity) that a modem rejects with
	// INVALID_ARGUMENT etc. must not climb the recovery/reboot ladder
	modem.uim.request('READ_TRANSPARENT', {
		session:   { session_type: session_type, aid: '' },
		file:      { file_id: ef.file_id, path: ef.path },
		read_info: { offset: 0, len: 0 },
	}, (err, data) => {
		if (err) {
			// MF-level files (e.g. ICCID) need the card session on some
			// modems (RG650E answers error 48 on the provisioning session)
			if (session_type == uimmod.SESSION_TYPE_PRIMARY_GW_PROVISIONING)
				return read_ef(modem, ef, cb, uimmod.SESSION_TYPE_CARD_SLOT_1);

			if (modem.log_fn)
				modem.log_fn('warn', sprintf('uim read of file %04x failed: %J', ef.file_id, err));

			return cb(null);
		}

		cb(data.data);
	}, { no_recovery: true });
};

// --- PLMN selector lists (settings editor) -----------------------------------

const EF_PLMN_USER = { file_id: 0x6F60, path: "\x00\x3F\xFF\x7F" };   // PLMNwAcT
const EF_PLMN_OPER = { file_id: 0x6F61, path: "\x00\x3F\xFF\x7F" };   // OPLMNwAcT
const EF_PLMN_HOME = { file_id: 0x6F62, path: "\x00\x3F\xFF\x7F" };   // HPLMNwAcT
const EF_FPLMN     = { file_id: 0x6F7B, path: "\x00\x3F\xFF\x7F" };   // Forbidden PLMNs

// the AcT bitmask shared by EF 6F60 and QMI NAS preferred-networks (TS 31.102):
// per-RAT bit flags for one PLMN record.
const PLMN_ACT_UTRAN = 0x8000, PLMN_ACT_EUTRAN = 0x4000, PLMN_ACT_NGRAN = 0x0800, PLMN_ACT_GSM = 0x0080;

// --- shared PLMN helpers (plain functions: hoisted module-wide, unlike the
// exported ones which are only visible after their definition) ----------------

// strip everything but decimal digits
function scrub_digits(s) { return replace(sprintf('%s', s ?? ''), /[^0-9]/g, ''); }

// a well-formed PLMN: 3-digit MCC + a 2- or 3-digit MNC
function valid_plmn(mcc, mnc) { return length(mcc) == 3 && (length(mnc) == 2 || length(mnc) == 3); }

// AcT bitmask -> per-RAT flags
function act_flags(bits)
{
	return {
		gsm:    !!(bits & PLMN_ACT_GSM),
		utran:  !!(bits & PLMN_ACT_UTRAN),
		eutran: !!(bits & PLMN_ACT_EUTRAN),
		ngran:  !!(bits & PLMN_ACT_NGRAN),
	};
}

// decode one 3-byte nibble-swapped BCD PLMN (0xF filler nibble = 2-digit MNC).
// Shared by PLMNwAcT (EF 6F60) and FPLMN (EF 6F7B).
function bcd_plmn(b)
{
	let d = [ b[0] & 0xF, b[0] >> 4, b[1] & 0xF, b[1] >> 4, b[2] & 0xF, b[2] >> 4 ];

	return {
		mcc: sprintf('%d%d%d', d[0], d[1], d[2]),
		mnc: sprintf('%d%d', d[4], d[5]) + ((d[3] == 0xF) ? '' : sprintf('%d', d[3])),
	};
}

// the backend-neutral NAS accessor (direct client on QMI, lazy QMI-over-MBIM
// passthrough on MBIM, null on NCM) — see modem.with_nas
function nas_of(modem, cb)
{
	let w = modem.with_nas ?? ((c) => c(modem.nas ?? null));
	return w(cb);
}

// decode PLMNwAcT records (TS 31.102): 5 bytes each — a 3-byte BCD PLMN + a
// 2-byte access-technology mask.
export function decode_plmn_act(bytes)
{
	let out = [];

	for (let i = 0; i + 4 < length(bytes ?? []); i += 5) {
		let b = slice(bytes, i, i + 5);

		if (b[0] == 0xFF)
			continue;   // empty slot

		let act = (b[3] << 8) | b[4];
		let e = bcd_plmn(b);

		push(out, {
			mcc: e.mcc, mnc: e.mnc, act: act,
			utran:  !!(act & PLMN_ACT_UTRAN),
			eutran: !!(act & PLMN_ACT_EUTRAN),
			ngran:  !!(act & PLMN_ACT_NGRAN),
			gsm:    !!(act & PLMN_ACT_GSM),
		});
	}

	return out;
};

// EF_FPLMN (6F7B): the forbidden-PLMN list — 3 bytes per PLMN (packed MCC/MNC
// BCD, NO access technology), 0xFF-padded. Same nibble packing as the first 3
// bytes of a PLMNwAcT record. decode -> [ { mcc, mnc } ].
export function decode_fplmn(bytes)
{
	let out = [];

	for (let i = 0; i + 2 < length(bytes ?? []); i += 3) {
		let b = slice(bytes, i, i + 3);

		if (b[0] == 0xFF)
			continue;   // empty slot

		push(out, bcd_plmn(b));
	}

	return out;
};

// pack forbidden-PLMN entries back into EF_FPLMN bytes, 0xFF-padded to at least
// min_bytes (default 12 = 4 slots, the 3GPP minimum). Skips malformed entries
// (mcc not 3 digits, mnc not 2-3 digits). Returns a byte array.
export function encode_fplmn(entries, min_bytes)
{
	let out = [];
	let dig = (s, i) => +substr(sprintf('%s', s), i, 1);

	for (let e in (entries ?? [])) {
		let mcc = scrub_digits(e.mcc), mnc = scrub_digits(e.mnc);

		if (!valid_plmn(mcc, mnc))
			continue;

		let m3 = (length(mnc) == 3) ? dig(mnc, 2) : 0xF;

		push(out, (dig(mcc, 1) << 4) | dig(mcc, 0));   // MCC2 | MCC1
		push(out, (m3 << 4) | dig(mcc, 2));            // MNC3(or F) | MCC3
		push(out, (dig(mnc, 1) << 4) | dig(mnc, 0));   // MNC2 | MNC1
	}

	while (length(out) < (min_bytes ?? 12))
		push(out, 0xFF);

	return out;
};

// read the raw EF_FPLMN (6F7B) bytes: QMI UIM READ_TRANSPARENT first, then
// AT+CRSM 176 (the only path on modems whose UIM rejects EF reads, e.g. the
// Huawei E392 — code 48). cb(bytes|null). The CRSM read is capped at the 12-byte
// (4-slot) 3GPP minimum; a UIM modem returns the whole EF, so a larger file is
// fully seen and fully rewritten (see write_fplmn).
// bring up the QMI-over-MBIM passthrough UIM on demand for the SIM-file paths.
// The slot/apdu/power paths already do this; the PLMN/FPLMN readers used to
// test modem.uim only — on MBIM modems the operator/home lists read null and
// FPLMN fell to the 12-byte AT+CRSM path although the passthrough UIM works.
function ensure_uim(modem, cb)
{
	if (modem.uim || !modem._ensure_uim)
		return cb();

	modem._ensure_uim(() => cb());
}

function read_fplmn_raw(modem, cb)
{
	ensure_uim(modem, () => {
		let via_crsm = () => {
			if (!modem.at)
				return cb(null);

			modem.at.send(sprintf('AT+CRSM=176,%d,0,0,12', EF_FPLMN.file_id), (err, res) => {
				let r = err ? null : atcmd.parse_crsm(res?.lines);
				cb((r && r.ok && r.data) ? hex_to_arr(r.data) : null);
			}, { timeout: 8000 });
		};

		if (modem.uim)
			return read_ef(modem, EF_FPLMN, (bytes) => bytes != null ? cb(bytes) : via_crsm());

		via_crsm();
	});
}

// read the forbidden-PLMN list -> cb([ { mcc, mnc } ]) or cb(null) when unreadable.
export function read_fplmn(modem, cb)
{
	read_fplmn_raw(modem, (bytes) => cb(bytes != null ? decode_fplmn(bytes) : null));
};

// write the forbidden-PLMN list (EF_FPLMN 6F7B): QMI UIM WRITE_TRANSPARENT
// first, AT+CRSM 214 fallback (E392). entries: [ { mcc, mnc } ] (no AcT). FPLMN
// update is a PIN1 operation (no ADM), unlike the operator/home selector lists.
// Reads the list back for cross-verification. NOTE the modem also manages this
// list itself (adds on EMM reject #11/#13/#15) — the daemon re-asserts the
// configured list before every radio-on.
export function write_fplmn(modem, entries, cb)
{
	// learn the current EF length first and overwrite the WHOLE file — a shorter
	// write would leave stale forbidden PLMNs in the tail slots. Falls back to
	// the 12-byte 4-slot minimum when the length is unknown.
	read_fplmn_raw(modem, (cur) => {
		let bytes = encode_fplmn(entries, max(12, length(cur ?? [])));

		let finish = () => read_fplmn(modem, (fplmn) =>
			cb(null, { ok: true, written: length(entries ?? []), fplmn: fplmn }));

		// AT+CRSM update. Firmwares disagree on the <data> argument: some want it
		// quoted ("62F2..."), some bare. Try quoted first; if the modem rejects
		// the syntax outright (no +CRSM line at all), retry bare.
		let hex = arr_to_hex(bytes);
		let crsm_write;   // forward-declared (self-referencing arrow -> ucode TDZ)
		crsm_write = (quoted, retry) => {
			if (!modem.at)
				return cb({ error: 'no_write_channel' });

			let arg = quoted ? sprintf('"%s"', hex) : hex;

			modem.at.send(sprintf('AT+CRSM=214,%d,0,0,%d,%s', EF_FPLMN.file_id, length(bytes), arg), (werr, res) => {
				let r = werr ? null : atcmd.parse_crsm(res?.lines);

				// no +CRSM line -> the modem rejected the command form; try the other
				if (r == null && retry)
					return crsm_write(!quoted, false);

				if (!r || !r.ok)
					return cb({ error: 'crsm_write',
					            note: r ? sprintf('SIM rejected FPLMN write (SW %02X%02X)', r.sw1, r.sw2)
					                    : 'no CRSM response' });

				finish();
			}, { timeout: 8000 });
		};
		let via_crsm = () => crsm_write(true, true);

		if (modem.uim)
			return modem.uim.request('WRITE_TRANSPARENT', {
				session:    { session_type: uimmod.SESSION_TYPE_PRIMARY_GW_PROVISIONING, aid: '' },
				file:       { file_id: EF_FPLMN.file_id, path: EF_FPLMN.path },
				write_data: { offset: 0, data: bytes },
			}, (err) => {
				if (!err)
					return finish();

				via_crsm();   // UIM refused (E392) -> AT+CRSM
			}, { no_recovery: true });

		via_crsm();
	});
};

// the AcT bitmask -> per-RAT flags (public wrapper over the internal act_flags).
export function plmn_act_flags(bits)
{
	return {
		gsm:    !!(bits & PLMN_ACT_GSM),
		utran:  !!(bits & PLMN_ACT_UTRAN),
		eutran: !!(bits & PLMN_ACT_EUTRAN),
		ngran:  !!(bits & PLMN_ACT_NGRAN),
	};
};

export function plmn_act_bits(e)
{
	return (e.gsm ? PLMN_ACT_GSM : 0) | (e.utran ? PLMN_ACT_UTRAN : 0) |
	       (e.eutran ? PLMN_ACT_EUTRAN : 0) | (e.ngran ? PLMN_ACT_NGRAN : 0);
};

function read_plmn_lists_inner(modem, cb)
{
	let out = { user: null, nas: null, operator: null, home: null, fplmn: null };

	// map a QMI NAS preferred-networks array to the display shape
	let map_nas = (arr) => map(arr ?? [], (e) => {
		let f = plmn_act_flags(e.rat);
		return { mcc: sprintf('%d', e.mcc),
		         mnc: (e.mnc >= 100) ? sprintf('%d', e.mnc) : sprintf('%02d', e.mnc),
		         gsm: f.gsm, utran: f.utran, eutran: f.eutran, ngran: f.ngran };
	});

	// AT fallback for the USER list: some modems reject a UIM EF read of 6F60
	// (HW-seen: Huawei E392 / EG06 return err 48) or have no UIM (NCM), yet
	// expose the list over AT+CPOL (AT+CPLS=0 selects it, AT+CPOL? dumps it).
	let at_user = (done) => {
		let at = modem.at;

		if (!at)
			return done();

		at.send('AT+CPLS=0', () => {
			at.send('AT+CPOL?', (err, res) => {
				if (!err) {
					let recs = atcmd.parse_cpol(res?.lines) ?? [];

					out.user = map(recs, (r) => ({ mcc: r.mcc, mnc: r.mnc,
						gsm: r.gsm, utran: r.utran, eutran: r.eutran, ngran: r.ngran }));
				}

				done();
			}, { timeout: 8000 });
		}, { timeout: 5000 });
	};

	// user list via the UIM EF, then AT
	let user_via_uim_at = (done) => {
		if (!modem.uim)
			return at_user(done);

		read_ef(modem, EF_PLMN_USER, (u) => {
			out.user = (u != null) ? decode_plmn_act(u) : null;

			if (out.user == null)
				return at_user(done);

			done();
		});
	};

	// NAS is a direct client on QMI (self.nas), only the async with_nas() lazy
	// passthrough on MBIM (and null on NCM) — go through with_nas for parity.
	let with_nas = (cb) => nas_of(modem, cb);

	// the QMI NAS "preferred networks" list — a SEPARATE list from the SIM
	// EF 6F60 user list (on some modems they even differ: E392 shows 33 via NAS
	// vs 85 via AT+CPOL). Kept in out.nas so the two are managed independently.
	let read_nas = (done) => {
		with_nas((nas) => {
			if (!nas)
				return done();

			nas.request('GET_PREFERRED_NETWORKS', {}, (err, data) => {
				if (!err && data?.preferred_networks != null)
					out.nas = map_nas(data.preferred_networks);

				done();
			});
		});
	};

	// operator + home come only from the UIM EFs (no NAS/AT equivalent)
	let read_op_home = (done) => {
		if (!modem.uim)
			return done();

		read_ef(modem, EF_PLMN_OPER, (o) => {
			out.operator = (o != null) ? decode_plmn_act(o) : null;

			read_ef(modem, EF_PLMN_HOME, (h) => {
				out.home = (h != null) ? decode_plmn_act(h) : null;
				done();
			});
		});
	};

	// forbidden list (EF 6F7B) via UIM, else AT+CRSM
	let read_fpl = (done) => read_fplmn(modem, (f) => { out.fplmn = f; done(); });

	// user list (EF 6F60) via UIM/AT, NAS via NAS Get, operator/home, forbidden
	user_via_uim_at(() => read_nas(() => read_op_home(() => read_fpl(() => cb(out)))));
}

export function read_plmn_lists(modem, cb)
{
	// MBIM: bring up the passthrough UIM first — operator/home/user EF reads
	// need it, and the AT-only fallbacks are lossy (no operator/home at all)
	ensure_uim(modem, () => read_plmn_lists_inner(modem, cb));
};

// Write the USER-controlled preferred PLMN list (EF 6F60 / PLMNwAcT) via the
// standard 3GPP AT interface — backend-neutral (every backend has an AT side
// channel), avoiding a modem-specific QMI/UIM record-write. entries is the
// desired list IN PRIORITY ORDER: [ { mcc, mnc, gsm, utran, eutran, ngran } ].
//
// Sequence (27.007 §7.19): AT+CPLS=0 selects the user list; read the current
// records (AT+CPOL?), delete them (highest index first so lower indices don't
// shift), then write the new list at explicit indices 1..N. Per record the AcT
// flags are GSM,GSM-compact,UTRAN,E-UTRAN[,NG-RAN]; the 5th (NG-RAN) field is
// only emitted when 5G is requested, since LTE-only firmwares reject it.
// On success reads the list BACK through the QMI/UIM path (read_plmn_lists) so
// the caller can cross-verify the AT write actually landed in the SIM EF.
export function write_user_plmn(modem, entries, cb)
{
	let at = modem.at;
	let list = entries ?? [];
	let esc = scrub_digits;

	// forward-declared: write_at / del_existing / try_write recurse (self-
	// referencing let arrows hit the ucode TDZ otherwise — see CLAUDE.md)
	let finish, write_at, del_existing, try_write, at_path;

	finish = () => {
		// cross-verify via the independent QMI/UIM read path (best-effort:
		// NCM modems without a UIM client just return null)
		read_plmn_lists(modem, (lists) => cb(null, { ok: true, written: length(list), user: lists.user }));
	};

	// AcT-field arities to try, in order: 5 fields (GSM,GSM-compact,UTRAN,E-UTRAN,
	// NG-RAN — Rel-15 / 5G modems), 4 (no NG-RAN — LTE modems), 0 (numeric-only,
	// oldest firmwares). The first arity a modem accepts is remembered so the rest
	// of the list writes without re-probing.
	let ACT_ARITIES = [ 5, 4, 0 ];
	let arity_i = 0;

	let acts_for = (e, arity) => {
		if (arity == 0)
			return '';

		let f = [ e.gsm ? 1 : 0, 0, e.utran ? 1 : 0, e.eutran ? 1 : 0 ];   // GSM,GSMc,UTRAN,E-UTRAN

		if (arity == 5)
			push(f, e.ngran ? 1 : 0);

		return ',' + join(',', f);
	};

	try_write = (i, plmn, ai) => {
		if (ai >= length(ACT_ARITIES))
			return cb({ error: 'cpol_write', at_index: i, plmn: plmn,
			            note: 'rejected at every AcT arity — SIM may be write-protected (ADM)' });

		at.send(sprintf('AT+CPOL=%d,2,"%s"%s', i + 1, plmn, acts_for(list[i], ACT_ARITIES[ai])), (werr) => {
			if (werr)
				return try_write(i, plmn, ai + 1);   // step down the AcT arity

			arity_i = ai;   // remember the arity this modem accepts
			write_at(i + 1);
		}, { timeout: 5000 });
	};

	write_at = (i) => {
		if (i >= length(list))
			return finish();

		let plmn = esc(list[i].mcc) + esc(list[i].mnc);

		if (!match(plmn, /^[0-9]{5,6}$/))
			return cb({ error: 'invalid_plmn', at_index: i, plmn: plmn });

		try_write(i, plmn, arity_i);
	};

	del_existing = (indices, k) => {
		if (k < 0)
			return write_at(0);

		// tolerate a delete error (record may already be empty)
		at.send(sprintf('AT+CPOL=%d', indices[k]), () => del_existing(indices, k - 1),
			{ timeout: 5000 });
	};

	// the AT+CPOL path (fallback / NCM): select the user list (some modems lack
	// AT+CPLS — tolerate), read the current records, clear them, write the new
	// order.
	at_path = () => {
		if (!at)
			return cb({ error: 'no_write_channel' });

		at.send('AT+CPLS=0', () => {
			at.send('AT+CPOL?', (err, res) => {
				let cur = err ? [] : (atcmd.parse_cpol(res?.lines) ?? []);
				let indices = sort(map(cur, (e) => e.index), (a, b) => a - b);

				del_existing(indices, length(indices) - 1);
			}, { timeout: 8000 });
		}, { timeout: 5000 });
	};

	// the EF 6F60 user list is written over AT+CPOL (UIM record write is refused
	// by the modems on hand); the QMI NAS "preferred networks" list is a separate
	// type written by write_nas_plmn().
	at_path();
};

// Write the QMI NAS "preferred networks" list (NAS Set Preferred Networks) —
// a separate list from the EF 6F60 user list (write_user_plmn). Via with_nas()
// so MBIM's QMI-over-MBIM passthrough has parity with QMI; NCM (no NAS) errors.
// entries: [ { mcc, mnc, gsm, utran, eutran, ngran } ]. Reads back via NAS Get.
export function write_nas_plmn(modem, entries, cb)
{
	let list = entries ?? [];
	let esc = scrub_digits;
	let with_nas = (cb) => nas_of(modem, cb);

	with_nas((nas) => {
		if (!nas)
			return cb({ error: 'no_nas_client' });

		let pn = [];

		for (let e in list) {
			let mcc = +esc(e.mcc), mnc = +esc(e.mnc);

			if (!(mcc >= 100 && mcc <= 999) || !(mnc >= 0 && mnc <= 999))
				return cb({ error: 'invalid_plmn', plmn: esc(e.mcc) + esc(e.mnc) });

			push(pn, { mcc: mcc, mnc: mnc, rat: plmn_act_bits(e) });
		}

		nas.request('SET_PREFERRED_NETWORKS',
			{ preferred_networks: pn, clear_previous: 1 }, (err) => {
				if (err)
					return cb({ error: 'nas_set', detail: err });

				// read back the NAS list for cross-verification
				read_plmn_lists(modem, (lists) => cb(null, { ok: true, written: length(list), nas: lists.nas }));
			});
	});
};

// backend-neutral write dispatcher: route to the writer for `list_type`
// ('nas'|'fplmn'|'user', default user). The single place that maps a list type
// to its writer — used by the ubus ops and the pre-radio restore hook.
export function write_plmn(modem, list_type, entries, cb)
{
	if (list_type == 'nas')
		return write_nas_plmn(modem, entries, cb);
	if (list_type == 'fplmn')
		return write_fplmn(modem, entries, cb);

	return write_user_plmn(modem, entries, cb);
};

// pre-radio-on DEBUG dump (called by every backend right before it enables the
// radio): the current NAS preferred-networks list + the SIM/network state to
// the debug log. Never stalls bring-up (always cb()).
export function log_preradio(modem, log, cb)
{
	let with_nas = (cb) => nas_of(modem, cb);

	log('debug', sprintf('pre-radio: sim/network imsi=%s iccid=%s reg=%J',
		modem.info?.imsi ?? '?', modem.info?.iccid ?? '?',
		modem.reg ?? modem.registration ?? null));

	with_nas((nas) => {
		if (!nas)
			return cb();

		nas.request('GET_PREFERRED_NETWORKS', {}, (err, data) => {
			let pn = err ? null : (data?.preferred_networks ?? []);

			log('debug', (pn == null) ? 'pre-radio: nas preferred networks unavailable'
				: sprintf('pre-radio: nas preferred networks = %d record(s) %J', length(pn), pn));

			cb();
		});
	});
};

// the effective configured PLMN list to restore: a per-SIM list (matched active
// card, wwand_sim option plmn_list) wins over the modem's (wwand_modem option
// plmn_list). { type, entries } or null.
export function effective_plmn_restore(modem)
{
	return modem.active_sim?.plmn_restore ?? modem.config?.plmn_restore ?? null;
};

// restore the configured user/NAS preferred list (run after SIM unlock, before
// registration — so a per-SIM list resolves). Logs any failure so a write-
// protected SIM / rejecting modem is visible. Always cb().
export function restore_preferred_plmn(modem, log, cb)
{
	let r = effective_plmn_restore(modem);

	if (type(r) != 'object' || type(r.entries) != 'array' || !length(r.entries))
		return cb();

	let kind = (r.type == 'nas') ? 'nas' : (r.type == 'fplmn') ? 'fplmn' : 'user';

	write_plmn(modem, kind, r.entries, (err, res) => {
		if (err)
			log('err', sprintf('%s list restore FAILED: %J', kind, err));
		else
			log('notice', sprintf('restored %d %s list record(s) from config', res.written, kind));

		cb();
	});
};
