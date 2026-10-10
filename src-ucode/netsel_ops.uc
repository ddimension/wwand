// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — settings / network-selection / operator-scan ubus operations,
// kept apart from the daemon.uc factory.
//
// install(self, o) attaches to the daemon object:
//   modem_get_settings / modem_set_settings   NAS system-selection prefs with
//                                             band-list <-> u64-mask handling
//   modem_set_network_selection               auto/manual PLMN (QMI NAS or the
//                                             AT+COPS fallback), idempotent,
//                                             quirk-aware deferred apply
//   modem_scan / modem_scan_start / modem_scan_status
//                                             sync scan + the async job the
//                                             LuCI UI polls (a scan outlives
//                                             the XHR/rpcd timeout chain)
//   modem_reattach / modem_detach / modem_attach
//                                             network-level detach/attach,
//                                             the PDN sessions stopped first
// o = { log, check_modem, reg_plmn } — the daemon's modem-ref resolver and
// protocol-neutral registered-PLMN helper stay owned by daemon.uc.

'use strict';

import * as uloop from 'uloop';
import * as quirks from 'wwand.modem_quirks';
import * as atcmd from 'wwand.atcmd';
import * as nasmod from 'wwand.codec.schema.nas';
import * as modem_common from 'wwand.modem_common';
import * as context_common from 'wwand.context_common';

// AT+COPS timeouts (netsel AT fallback): the format-set is instant, the read
// can stall on a busy modem, and a manual COPS SET legitimately runs a full
// network search (3GPP allows minutes — 30 s covers the observed worst case
// before the deferred-apply path takes over).
const COPS_FORMAT_TIMEOUT_MS = 5000;
const COPS_READ_TIMEOUT_MS = 10000;
const COPS_SET_TIMEOUT_MS = 30000;
// how long a reattach/attach over AT waits for the registration to return
// before it re-dials anyway (wait_registered)
const REGISTER_WAIT_MS = 60000;

export function install(self, o)
{
	let log = o.log, check_modem = o.check_modem, reg_plmn = o.reg_plmn;

	// band mask <-> band-number-list conversion. Done daemon-side on purpose:
	// u64 masks lose precision in LuCI's JS numbers (> 2^53), band lists
	// survive JSON. Bit n-1 across the mask words = band n; bit 63 of a word
	// is skipped (no such band exists, and 1<<63 goes negative in int64).
	let mask_to_bands = (masks) => {
		let out = [];

		for (let w = 0; w < length(masks); w++) {
			let m = masks[w] ?? 0;

			for (let b = 0; b < 63; b++)
				if (m & (1 << b))
					push(out, w * 64 + b + 1);
		}

		return out;
	};

	let bands_to_masks = (bands, words) => {
		let masks = [];

		for (let i = 0; i < words; i++)
			push(masks, 0);

		for (let n in bands) {
			let bit = +n - 1;
			let w = int(bit / 64);

			if (bit >= 0 && w < words && (bit % 64) < 63)
				masks[w] |= (1 << (bit % 64));
		}

		return masks;
	};

	// QmiNasNetworkStatus bits (qmi-enums-nas.h, libqmi 1.38.0):
	//   1<<0 CURRENT_SERVING  1<<1 AVAILABLE  1<<2 HOME       1<<3 ROAMING
	//   1<<4 FORBIDDEN        1<<5 NOT_FORBIDDEN  1<<6 PREFERRED  1<<7 NOT_PREFERRED
	// The four odd bits are the negations, so a flag is only meaningful when its
	// own bit is set — "not set" means the modem did not say, not "false".
	const NET_CURRENT   = 0x01;
	const NET_HOME      = 0x04;
	const NET_ROAMING   = 0x08;
	const NET_FORBIDDEN = 0x10;
	const NET_PREFERRED = 0x40;

	// QmiNasNetworkScanResult (qmi-enums-nas.h:493-495, libqmi 1.38.0). Keys are
	// quoted and looked up through sprintf because a ucode object is indexed by
	// STRING — SCAN_RESULT[0] does not find '0'.
	const SCAN_RESULT = { '0': 'success', '1': 'abort', '2': 'radio_link_failure' };

	let scan_result_name = (res) =>
		(res == null) ? null : (SCAN_RESULT[sprintf('%d', res)] ?? sprintf('result %d', res));

	// -> a coarse operator status label
	let scan_status = (bits) =>
		(bits & NET_CURRENT)   ? 'current' :
		(bits & NET_FORBIDDEN) ? 'forbidden' :
		'available';

	// normalize a NAS Network Scan response to
	//   [ { mcc, mnc, plmn, name, status, roaming, preferred, rats: [ ... ] } ]
	// The Radio Access Technology TLV (0x11) is a SEPARATE list keyed by mcc/mnc
	// — the same PLMN can appear on several RATs — so collect every RAT per PLMN
	// and attach it (what the scan actually saw, beyond just the operator name).
	let scan_operators = (data) => {
		let rats = {};   // "mcc/mnc" -> [ 'LTE', 'UMTS', ... ]

		for (let r in (data?.radio_access_technology ?? [])) {
			let name = nasmod.radio_if_name(r.radio_interface);

			if (name == null)
				continue;

			let key = sprintf('%d/%d', r.mcc, r.mnc);
			rats[key] = rats[key] ?? [];

			if (index(rats[key], name) < 0)
				push(rats[key], name);
		}

		let out = [];

		// which of these MNCs carry a third digit (TLV 0x12). Without it
		// 310/030 and 310/30 render identically and a UI choosing an entry
		// cannot say which it meant.
		let pcs = {};

		for (let e in (data?.mnc_pcs_digit ?? []))
			pcs[sprintf('%d/%d', e.mcc, e.mnc)] = e.includes_pcs_digit ? 3 : 2;

		for (let e in (data?.network_information ?? [])) {
			let bits = e.network_status ?? 0;
			let w = pcs[sprintf('%d/%d', e.mcc, e.mnc)]
				?? modem_common.mnc_width(e.mnc);

			push(out, {
				mcc: e.mcc, mnc: e.mnc, mnc_digits: w,
				plmn: sprintf('%d/%s', e.mcc, modem_common.mnc_text(e.mnc, w)),
				name: e.description ?? '',
				status: scan_status(bits),
				// extra scan flags carried in the status bitmask. PREFERRED is
				// 0x40; 0x04 is HOME, and reading that instead would report the
				// home network as "preferred" on every scan while the real bit
				// is never seen.
				roaming: (bits & NET_ROAMING) ? true : false,
				home: (bits & NET_HOME) ? true : false,
				preferred: (bits & NET_PREFERRED) ? true : false,
				rats: rats[sprintf('%d/%d', e.mcc, e.mnc)] ?? [],
			});
		}

		return out;
	};

	// current NAS system-selection preferences (settings editor, read path)
	self.modem_get_settings = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		// A vendor radio codec comes FIRST: on an AT family the settings the
		// user edits ARE that vendor's own band lists (+GTACT on Fibocom), and
		// the NAS path below would either refuse them as unsupported or hand
		// them to a client the backend does not have. The answer is already in
		// the protocol-neutral band-list shape, so it needs no conversion.
		if (entry.modem.settings_get)
			return entry.modem.settings_get((err, data) => {
				if (err)
					return cb(err);

				data.registered_plmn = reg_plmn(entry.modem);
				cb(null, data);
			});

		// protocol-neutral: QMI hands out its NAS client, MBIM the QMI-over-MBIM
		// passthrough NAS; NCM has none (null) → gracefully unsupported.
		entry.modem.with_nas((nas) => {
			if (!nas)
				return cb({ error: 'unsupported_on_backend' });

			nas.request('GET_SYSTEM_SELECTION_PREFERENCE', {}, (err, data) => {
				if (err)
					return cb({ error: 'qmi', detail: err });

				delete data._result;

				let e = data.ext_lte_band;

				data.lte_bands = mask_to_bands(e
					? [ e.mask_low, e.mask_mid_low, e.mask_mid_high, e.mask_high ]
					: [ data.lte_band_preference ?? 0 ]);

				for (let key in [ 'nr5g_sa_band', 'nr5g_nsa_band' ]) {
					let s = data[key];

					data[key + 's'] = s ? mask_to_bands([ s.m0, s.m1, s.m2, s.m3,
					                                      s.m4, s.m5, s.m6, s.m7 ]) : [];
				}

				// current network selection mode + registered operator (both
				// protocol-neutral, so the settings editor shows them for any HW)
				if (data.network_selection != null)
					data.selection_mode = (data.network_selection == 1) ? 'manual' : 'auto';

				data.registered_plmn = reg_plmn(entry.modem);

				cb(null, data);
			});
		});
	};

	// network scan (COPS=? equivalent): the visible operators. Genuinely SLOW —
	// AT+COPS=? regularly takes minutes (QMI NAS scans too, on busy bands).
	// QMI/passthrough via NAS Network Scan; AT fallback via AT+COPS=? on NCM.
	const SCAN_TIMEOUT_MS = 240000;

	self.modem_scan = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		// AT+COPS=? fallback: used when there is no QMI NAS (NCM) AND when the NAS
		// scan itself fails — some modems refuse a NAS network scan (HW-seen: the
		// EG06 rejects it over the QMI-over-MBIM passthrough with result 1), so AT
		// keeps MBIM/NCM at parity with QMI where the passthrough scan works.
		// NATIVE MBIM, below AT. MBIM has had a scan of its own all along
		// (VISIBLE_PROVIDERS, cid 8) and wwand never called it, so an MBIM
		// modem whose QMI passthrough refuses a NAS scan AND has no AT port
		// answered `unsupported_on_backend` for an operation its own protocol
		// implements. Last rung on purpose: the QMI scan carries more (band and
		// RAT per operator), and AT+COPS=? is the one every modem answers.
		// DUCK-TYPED, like sim.uc's `mbim_uicc`: the MBIM schemas ship in
		// wwand-mbim and this file is in the base package, so an import here
		// would make a QMI-only install depend on a module it does not have.
		// The MBIM modem offers the method; nobody else does.
		let mbim_scan = (extra) => {
			if (type(entry.modem.native_scan) != 'function')
				return cb({ error: 'unsupported_on_backend', ...(extra ?? {}) });

			entry.modem.native_scan((err, ops) => {
				if (err)
					return cb({ error: 'mbim', detail: err, ...(extra ?? {}) });

				cb(null, { operators: ops ?? [], ...(extra ?? {}) });
			}, SCAN_TIMEOUT_MS);
		};

		let at_scan = (extra) => {
			let at = entry.modem.at;

			if (!at)
				return mbim_scan(extra);

			at.send('AT+COPS=?', (err, res) => {
				if (err)
					return cb({ error: 'at', detail: err, ...(extra ?? {}) });

				cb(null, { operators: atcmd.parse_cops_scan(res?.lines), ...(extra ?? {}) });
			}, { timeout: SCAN_TIMEOUT_MS });
		};

		entry.modem.with_nas((nas) => {
			if (!nas)
				return at_scan();

			nas.request('NETWORK_SCAN', {}, (err, data) => {
				if (err) {
					log('info', sprintf('modem %s: NAS network scan failed (%J) — falling back to AT+COPS=?',
						ref, err));
					return at_scan();
				}

				let ops = scan_operators(data);
				let res = data?.scan_result;

				// QMI success is not scan success: an aborted scan comes back as
				// a perfectly valid response with nothing in it, which reached
				// the UI as "no operators found" — a different and much stronger
				// claim than the modem made. TLV 0x13 carries the real outcome.
				// An empty list is also worth one more try over AT, a separate
				// code path in the firmware; that is cheap next to a scan that
				// has already cost minutes, and it cannot make the answer worse.
				if (!length(ops)) {
					log('info', sprintf('modem %s: NAS network scan returned no operators (%s) — falling back to AT+COPS=?',
						ref, scan_result_name(res) ?? 'no result TLV'));
					return at_scan((res != null && res != 0)
						? { scan_result: scan_result_name(res) } : {});
				}

				cb(null, { operators: ops,
					...(res != null ? { scan_result: scan_result_name(res) } : {}) });
			}, { timeout: SCAN_TIMEOUT_MS });
		});
	};

	// async scan job: a scan outlives the LuCI→uhttpd→rpcd XHR chain (uhttpd's
	// script_timeout is 60 s by default while the scan runs minutes), so the UI
	// starts a job and polls. One job per modem; a finished job's result is kept
	// until the next start.
	//
	// `started_at` is reported so a caller can SEE when the job began; it is not
	// a duration source, and a caller must not subtract it from its own clock.
	// Two reasons, both live on this hardware: the router and the caller are
	// different machines (LuCI did exactly that and showed 624335s on the
	// NR7101, 2026-09-12 — the skew, not the scan), and this box's own clock is
	// not monotonic across the job either, since a scan that brings the modem up
	// lets NTP step time() by days mid-flight. A caller that wants elapsed time
	// measures it on the one clock it knows stands still: its own.
	self.modem_scan_start = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (entry.netscan?.running)
			return cb(null, { running: true, started: entry.netscan.started_at });

		let job = { running: true, started_at: time(), operators: null, error: null };
		entry.netscan = job;

		self.modem_scan(ref, (err, res) => {
			job.running = false;
			job.finished_at = time();
			job.error = err ?? null;
			job.operators = res?.operators;
		});

		// modem_scan can fail synchronously (no modem / no AT) — report that
		// instead of a pointless poll loop
		if (!job.running)
			return cb(job.error ?? { error: 'scan_failed' });

		cb(null, { running: true, started: job.started_at });
	};

	self.modem_scan_status = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let job = entry.netscan;

		if (!job)
			return cb(null, { running: false, idle: true });

		if (job.running)
			return cb(null, { running: true, started: job.started_at });

		cb(null, {
			running: false,
			started: job.started_at,
			finished: job.finished_at,
			...(job.error ? { error: job.error.error ?? 'scan_failed', detail: job.error } :
			                { operators: job.operators ?? [] }),
		});
	};

	// network selection: 'auto' (NAS automatic / AT+COPS=0) or 'manual' with an
	// mcc/mnc (NAS manual / AT+COPS=1,2,"mccmnc").
	//
	// Two field-driven behaviours (COPS — and sometimes its QMI equivalent —
	// can bounce the radio on several modems):
	// - idempotency guard: the SET is skipped entirely when the modem already
	//   runs the requested selection (result carries `unchanged: true`), so a
	//   LuCI "save" never disturbs a healthy registration for nothing.
	// - deferred apply: on models whose quirk table flags `netsel_deferred`,
	//   the setting is written but only takes effect at the next modem reboot;
	//   the result carries `deferred: true` + `apply: 'modem_reset'` and the
	//   CALLER decides (the LuCI page informs the user and offers the reset).
	// `mnc` may arrive as a NUMBER (the ubus policy says so) and 310/030 is not
	// 310/30 — two different operators that both become 30. So the width comes
	// either from the string form, when the caller had one, or from an explicit
	// digit count; a value of 100 or more settles itself. Everything below that
	// with no width given stays 2 digits, which is what shipped.
	// shared with the init writer and the config autocorrect — the width is a
	// property of the PLMN, not of this entry point (modem_common.uc).
	let mnc_text = modem_common.mnc_text;
	let mnc_width = modem_common.mnc_width;

	self.modem_set_network_selection = function(ref, mode, mcc, mnc, cb, mnc_digits) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (mode != 'auto' && mode != 'manual')
			return cb({ error: 'invalid_mode' });

		let manual = (mode == 'manual');

		if (manual && !(+mcc > 0 && +mnc >= 0))
			return cb({ error: 'missing_plmn' });

		let width = mnc_width(mnc, mnc_digits);

		let result = manual ? { mode: mode, mcc: +mcc, mnc: +mnc } : { mode: mode };
		let q = quirks.for_model(entry.modem.info?.model);

		let done_set = (via) => {
			log('notice', sprintf('modem %s: network selection %s%s%s%s', ref, mode,
				manual ? sprintf(' %d/%s', +mcc, mnc_text(mnc, width)) : '', via,
				q.netsel_deferred ? ' (deferred until modem reset)' : ''));

			if (q.netsel_deferred) {
				result.deferred = true;
				result.apply = 'modem_reset';
			}

			cb(null, result);
		};

		let skip_set = (via) => {
			log('info', sprintf('modem %s: network selection already %s%s%s — not touching the radio',
				ref, mode, manual ? sprintf(' %d/%s', +mcc, mnc_text(mnc, width)) : '', via));
			cb(null, { ...result, unchanged: true });
		};

		entry.modem.with_nas((nas) => {
			if (nas) {
				// idempotency: read the current preference first; for manual the
				// serving PLMN must match too (fall through to the SET whenever
				// the current state cannot be read positively)
				return nas.request('GET_SYSTEM_SELECTION_PREFERENCE', {}, (gerr, cur) => {
					let cur_manual = (!gerr && cur?.network_selection != null)
						? (cur.network_selection == 1) : null;
					let sv = entry.modem.cells?.serving?.lte;
					// THE WIDTH IS PART OF THE COMPARISON. Matching numerically
					// made serving 310/30 equal to a requested 310/030, so the
					// guard skipped the very write that would have corrected
					// it and reported `unchanged`. The serving cell carries no
					// width of its own, so a 3-digit request is never treated
					// as already-applied.
					let same = (cur_manual != null) && (cur_manual == manual) &&
						(!manual || (width == 2 && sv?.mcc != null &&
							+sv.mcc == +mcc && +sv.mnc == +mnc));

					if (same)
						return skip_set('');

					// reuse SET_SYSTEM_SELECTION_PREFERENCE's network_selection TLV
					// (mode 0 auto / 1 manual), permanent duration (survives power cycle)
					let sel = manual
						? { mode: 1, mcc: +mcc, mnc: +mnc }
						: { mode: 0 };

					// TLV 0x1A says whether the MNC in 0x16 is three digits
					// (libqmi 1.38, Set System Selection Preference input,
					// format guint8) — a plain flag here, unlike the per-entry
					// array Set Preferred Networks takes.
					// only for a MANUAL selection: on auto there is no MNC for
					// the flag to qualify, and an unnecessary TLV is one more
					// thing a firmware can refuse.
					let ssp = { network_selection: sel, change_duration: 1 };

					if (manual)
						ssp.mnc_pcs_digit = (width == 3) ? 1 : 0;

					nas.request('SET_SYSTEM_SELECTION_PREFERENCE', ssp, (err) => {
						if (err)
							return cb({ error: 'qmi', detail: err });

						done_set('');
					});
				});
			}

			// AT fallback (NCM): COPS. Manual uses numeric format (COPS mode 2).
			let at = entry.modem.at;

			if (!at) {
				// NATIVE MBIM, below AT for the same reason the scan is: MBIM's
				// REGISTER_STATE set takes a provider id and an action and
				// nothing else, where QMI carries the RAT preference and the
				// 3-digit-MNC flag with it. Duck-typed — the schemas ship in
				// wwand-mbim and this file is in the base package.
				//
				// No idempotency read here on purpose. MBIM's register mode is
				// in the same response as the registration state, so "already
				// manual on this PLMN" cannot be told apart from "manual, and
				// currently searching" without also trusting the serving cell —
				// and a redundant register is a re-register, not a radio bounce.
				if (type(entry.modem.native_register) == 'function')
					return entry.modem.native_register(manual
						? { mcc: +mcc, mnc: +mnc, width: width } : null, (err) => {
						if (err)
							return cb({ error: 'mbim', detail: err });

						done_set(' (MBIM)');
					});

				return cb({ error: 'unsupported_on_backend' });
			}

			// idempotency: numeric read-back (COPS=3,2 sets the read format only)
			at.send('AT+COPS=3,2', () => {
				at.send('AT+COPS?', (rerr, rres) => {
					let cur = rerr ? null : atcmd.parse_cops_read(rres?.lines);
					let same = cur &&
						((!manual && cur.mode == 0) ||
						 (manual && cur.mode == 1 &&
						  cur.plmn == sprintf('%d%s', +mcc, mnc_text(mnc, width))));

					if (same)
						return skip_set(' (AT)');

					// the real width, not a fixed %02d: a 3-digit MNC written two
			// digits wide names a different operator, and AT+COPS carries no
			// flag to say which was meant — the digit count IS the statement.
			let cmd = manual
				? sprintf('AT+COPS=1,2,"%d%s"', +mcc, mnc_text(mnc, width))
				: 'AT+COPS=0';

					at.send(cmd, (err) => {
						if (err)
							return cb({ error: 'at', detail: err });

						done_set(' (AT)');
					}, { timeout: COPS_SET_TIMEOUT_MS });
				}, { timeout: COPS_READ_TIMEOUT_MS });
			}, { timeout: COPS_FORMAT_TIMEOUT_MS });
		});
	};

	// REGISTERED AGAIN, NOT "COMMAND ACCEPTED". AT+COPS=0 and AT+CGATT=1 answer
	// OK as soon as the modem has taken the request, before the network
	// procedure is done (MeiG SLM770A: the dial right after COPS=0 failed in
	// the search and the one after CGATT=1 with ERROR, HW-observed
	// 2026-10-10). So the AT paths poll the registration — CEREG (LTE), then
	// CGREG (2G/3G); stat 1 home, 5 roaming (TS 27.007 §10.1.22) — every
	// 2 s for up to `ms`. cb(true) registered, cb(false) not within the
	// time: the caller goes on either way and the daemon's retries cover it.
	let arm_timer = o.timer ?? uloop.timer;
	let now_ms = o.now_ms ?? (() => context_common.mono() * 1000);
	let reg_ok = (res) => {
		for (let l in (res?.lines ?? [])) {
			let m = match(l, /\+C(E|G)REG:\s*[0-9]+,\s*([0-9]+)/);

			if (m && (m[2] == '1' || m[2] == '5'))
				return true;
		}

		return false;
	};
	let wait_registered = (at, ms, cb) => {
		// an ABSOLUTE deadline: each round also waits up to 5 s per query, so
		// counting only the 2 s pauses let "60 s" run to six minutes
		let deadline = now_ms() + ms;
		let poll;   // forward-declared (self-referencing arrow)

		poll = () => at.send('AT+CEREG?', (e1, r1) => {
			if (!e1 && reg_ok(r1))
				return cb(true);

			at.send('AT+CGREG?', (e2, r2) => {
				if (!e2 && reg_ok(r2))
					return cb(true);

				let rest = deadline - now_ms();

				if (rest <= 0)
					return cb(false);

				arm_timer(min(2000, rest), poll);
			}, { timeout: 5000 });
		}, { timeout: 5000 });

		poll();
	};

	// the backend's own detach/attach (QMI DMS low_power -> online, MBIM radio
	// off -> on), with the PDN sessions stopped first and handed back to the
	// daemon afterwards (modem_common with_sessions_released says why). Shared
	// with the daemon's radio cycle after an unanswered dial (daemon.uc, case
	// 'error').
	self.reattach_released = function(m, cb) {
		m.with_sessions_released('reattach', (done) => m.reattach(done),
			(err, res, released, failed) => cb(err, err ? null : {
				...(res ?? {}),
				contexts_released: length(released),
				contexts_failed: failed,
			}));
	};

	// force a network re-registration (deregister + re-attach) so automatic
	// selection re-scans — the fix for a modem camped on a previously-selected
	// PLMN (automatic only re-scans on a reselection trigger; this is it). NOT a
	// modem reset and NOT a PDP-config teardown: the connected sessions are
	// stopped first (release_sessions above) and re-established afterwards.
	//   - QMI/MBIM: the backend's native reattach (DMS opmode low_power ->
	//     online / MBIM radio off -> on — QMI has no pure COPS-2 detach).
	//   - else (NCM / AT modems): AT+COPS=2 (deregister) -> AT+COPS=0 (automatic),
	//     which keeps the RF on (pure registration level).
	self.modem_reattach = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let m = entry.modem;

		// a bounce is already running — don't stack a second one (it would
		// snapshot zero contexts, clear the flag mid-bounce and race the
		// daemon's reconnect)
		if (m._reattaching)
			return cb(null, { ok: true, action: 'reattach', via: m.reattach ? 'backend' : 'at',
			                  contexts_bounced: 0, contexts_failed: [], busy: true });

		if (m.reattach) {
			log('notice', sprintf('modem %s: network reattach (backend)', ref));
			return self.reattach_released(m, cb);
		}

		let at = m.at;

		if (!at)
			return cb({ error: 'unsupported_on_backend' });

		log('notice', sprintf('modem %s: network reattach (AT COPS deregister -> automatic)', ref));

		// sessions stopped first, NOT handed back to the daemon: they are
		// re-dialled right here once the modem has registered again
		// (wait_registered — COPS=0 itself answers before that). The T700
		// needs the re-dial in any case — its data path does not survive the
		// deregister/attach cycle (CGACT stays 1 while the network bearer is
		// gone, field-verified).
		m.with_sessions_released('reattach', (done) => {
			// tolerate a deregister error (already deregistered) — always re-attach
			at.send('AT+COPS=2', () => {
				at.send('AT+COPS=0', (aerr) => {
					if (aerr)
						return done({ error: 'at', detail: aerr });

					wait_registered(at, REGISTER_WAIT_MS, (reg) => {
						if (!reg)
							log('warn', sprintf('modem %s: not registered %d s after the reattach — re-dialling anyway',
								ref, REGISTER_WAIT_MS / 1000));
						done(null);
					});
				}, { timeout: COPS_SET_TIMEOUT_MS });
			}, { timeout: COPS_SET_TIMEOUT_MS });
		}, (err, res, released, failed) => {
			if (err) {
				// not registered: the daemon's reconnect waits for it
				for (let name, e in (self.contexts ?? {}))
					if (e?.wanted && index(released, e.ctx) >= 0)
						self._enter_reconnecting?.(name);

				return cb(err);
			}

			let todo = [ ...released ];
			let next_ctx;   // forward-declared (self-referencing arrow)

			next_ctx = () => {
				if (!length(todo))
					return cb(null, { ok: true, action: 'reattach', via: 'at',
					                  contexts_bounced: length(released),
					                  contexts_failed: failed });

				let c = shift(todo);

				c.up((ue) => {
					if (ue)
						push(failed, { context: c.name ?? '?', step: 'up' });

					next_ctx();
				});
			};

			next_ctx();
		}, false);
	};

	// the PS attach/detach a modem offers: its backend's own (QMI NAS Attach
	// Detach, MBIM PACKET_SERVICE), else AT+CGATT on its AT channel (NCM).
	// null when it has neither.
	let ps_attach_of = (m) => {
		if (type(m.ps_attach) == 'function')
			return m.ps_attach;

		if (!m.at)
			return null;

		// an attach is answered once the modem is registered again
		// (wait_registered), a detach at once
		return (on, cb) => m.at.send(on ? 'AT+CGATT=1' : 'AT+CGATT=0', (err) => {
			if (err)
				return cb({ error: 'at', detail: err });

			if (!on)
				return cb(null, { ok: true, via: 'at' });

			wait_registered(m.at, REGISTER_WAIT_MS, (reg) =>
				cb(null, { ok: true, via: 'at', registered: reg }));
		}, { timeout: COPS_SET_TIMEOUT_MS });
	};

	// hand a modem's wanted, idle contexts to the daemon's reconnect, which
	// waits for READY and gives up after the hold
	let reconnect_modem = (m) => {
		for (let name, e in (self.contexts ?? {}))
			if (e?.wanted && e.ctx?.modem == m && e.ctx.state == 'IDLE')
				self._enter_reconnecting?.(name);
	};

	// Operator detach (ubus modem_detach): the PDN sessions end first (down
	// reason 'admin' — the operator ended them), then the PS detach, radio on.
	// The modem STAYS detached until modem_attach: `detached` makes the lost
	// registration the expected consequence, as a parked radio's is (modem.uc
	// _update_serving and its MBIM/NCM twins), and keeps the daemon from
	// redialling (reconnect.uc retry_activate, daemon context_up). It lives on
	// the modem object. A modem reset or re-enumeration ends it together with
	// the PS detach — the modem attaches on its own, as after any start. A
	// daemon restart forgets only the MARK: the modem stays PS-detached (the
	// QMI init sends no attach; MBIM's step_attach does), so attach before
	// restarting wwand.
	self.modem_detach = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let m = entry.modem;
		let ps = ps_attach_of(m);

		if (!ps)
			return cb({ error: 'unsupported_on_backend' });

		if (m._reattaching)
			return cb({ error: 'busy', detail: 'a radio cycle, reattach, detach or attach is running' });

		log('notice', sprintf('modem %s: network detach (operator)', ref));

		m.with_sessions_released('admin', (done) => {
			// set BEFORE the detach: the registration loss it causes must
			// already read as intended
			m.detached = true;
			ps(false, done);
		}, (err, res, released, failed) => {
			if (err) {
				m.detached = false;
				log('warn', sprintf('modem %s: detach failed: %J', ref, err));
				reconnect_modem(m);
				return cb(err);
			}

			// the interfaces go down in netifd — a detached modem carries no
			// session, and an interface left up would hold stale addresses —
			// as our own re-armable give-up, which modem_attach re-arms
			for (let name, e in (self.contexts ?? {}))
				if (e?.wanted && e.ctx?.modem == m)
					self._give_up?.(name, 'modem detached by the operator');

			cb(null, { ...(res ?? {}), action: 'detach',
			           contexts_released: length(released), contexts_failed: failed });
		}, false);
	};

	// Operator attach (ubus modem_attach): PS attach, then the interfaces the
	// detach took down come back up. Not restricted to a modem wwand
	// detached — attaching an attached modem is the modem's no-op.
	self.modem_attach = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		let m = entry.modem;
		let ps = ps_attach_of(m);

		if (!ps)
			return cb({ error: 'unsupported_on_backend' });

		// one operation on the network state at a time: an attach overlapping a
		// detach (still stopping its sessions) or a reattach would leave the
		// network in whichever state the LAST modem command set
		if (m._reattaching)
			return cb({ error: 'busy', detail: 'a reattach, detach or attach is running' });

		log('notice', sprintf('modem %s: network attach (operator)', ref));

		// NOT detached from here on, before the command is answered: the
		// registration can return before the answer does (separate messages on
		// QMI and MBIM), and while `detached` stood the backend took it for
		// the intended loss and announced nothing — the interfaces would then
		// wait for an event that had already gone by
		let was = !!m.detached;

		m._reattaching = true;
		m.detached = false;

		ps(true, (err, res) => {
			m._reattaching = false;

			if (err) {
				m.detached = was;
				log('warn', sprintf('modem %s: attach failed: %J', ref, err));
				return cb(err);
			}

			// the interfaces the detach gave up come back (daemon.uc
			// rearm_giveups), the others still wanted reconnect — at once when
			// the modem is registered (again, or all along: a BG96 on GSM keeps
			// its CS registration through a PS detach and sends no event).
			// NOT while the registration is still gone (`_reg_released`, set by
			// the backends' registration-loss branch, cleared by the next
			// registration): the attach answers before the modem has registered
			// again, and a kick then dials into the search and is aborted
			// (HW-observed on the RG650E, 2026-10-10). That registration is
			// announced instead — through REGISTERING -> READY, or, with the
			// modem still READY, by `_wake_pending` as for a woken parked radio
			// — and `registered` re-arms them (daemon.uc modem_registered).
			if (!m._reg_released) {
				self.rearm_giveups?.(m);
				reconnect_modem(m);
			}
			else
				m._wake_pending = true;

			cb(null, { ...(res ?? {}), action: 'attach' });
		});
	};

	const SETTABLE_PREFS = {
		mode_preference: 'int', band_preference: 'int',
		roaming_preference: 'int', lte_band_preference: 'int',
		usage_preference: 'int',
		ext_lte_band: 'object', nr5g_sa_band: 'object', nr5g_nsa_band: 'object',
	};

	self.modem_set_settings = function(ref, settings, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		settings = { ...(settings ?? {}) };

		// A vendor radio codec comes FIRST, before any mask conversion: the
		// conversion below DELETES the band lists it consumes (they become u64
		// words), so a codec reached after it would find its input already
		// gone and answer "nothing to do" for a real edit. The codec takes
		// the lists as given — they are already in the neutral shape.
		if (entry.modem.settings_set)
			return entry.modem.settings_set(settings, (err, res) => {
				if (err)
					return cb(err);

				// the band command forgets (not NV): the edit is kept in uci
				// and re-applied at bring-up — also for an `unchanged` answer,
				// which says what the modem runs NOW, not after a power cycle
				if (res?.persistent === false)
					o.persist_bands?.(ref, settings);

				cb(null, res);
			});

		// band-number lists (LuCI-safe) are converted to masks here. Both LTE
		// band TLVs are filled so the idempotency guard below can compare
		// against whichever one the modem reports — only ONE of them is
		// actually sent (see the firmware shaping there).

		if (type(settings.lte_bands) == 'array') {
			let m = bands_to_masks(settings.lte_bands, 4);

			settings.lte_band_preference = m[0];
			settings.ext_lte_band = { mask_low: m[0], mask_mid_low: m[1],
			                          mask_mid_high: m[2], mask_high: m[3] };
			delete settings.lte_bands;
		}

		for (let key in [ 'nr5g_sa_bands', 'nr5g_nsa_bands' ]) {
			if (type(settings[key]) != 'array')
				continue;

			let m = bands_to_masks(settings[key], 8);

			settings[substr(key, 0, length(key) - 1)] = {
				m0: m[0], m1: m[1], m2: m[2], m3: m[3],
				m4: m[4], m5: m[5], m6: m[6], m7: m[7],
			};
			delete settings[key];
		}

		let args = {};

		for (let key, val in settings) {
			if (SETTABLE_PREFS[key] != type(val))
				return cb({ error: 'invalid_setting', key: key });

			args[key] = val;
		}

		if (!length(keys(args)))
			return cb({ error: 'missing_argument' });

		args.change_duration = 1;   // permanent (0 would revert on power cycle)

		let q = quirks.for_model(entry.modem.info?.model);

		// protocol-neutral: QMI's NAS, MBIM's passthrough NAS; NCM → unsupported
		entry.modem.with_nas((nas) => {
			if (!nas)
				return cb({ error: 'unsupported_on_backend' });

			// idempotency guard: read the current preference and drop every key
			// whose value already matches — NV writes (and the radio disturbance
			// some firmwares answer them with) only happen for real changes. On a
			// read error fall through and set everything as requested.
			nas.request('GET_SYSTEM_SELECTION_PREFERENCE', {}, (gerr, cur) => {
				if (!gerr && cur) {
					for (let k in filter(keys(args), (k) => k != 'change_duration')) {
						if (cur[k] != null && sprintf('%J', cur[k]) == sprintf('%J', args[k]))
							delete args[k];
					}
				}

				let changed = filter(keys(args), (k) => k != 'change_duration');

				if (!length(changed)) {
					log('info', sprintf('modem %s: system selection preference unchanged — not touching the radio', ref));
					return cb(null, { applied: [], unchanged: true });
				}

				// --- firmware shaping of the outgoing request ---------------
				// Firmwares are picky about WHICH band TLVs may travel together.
				// Both rules below are vendor-neutral (they describe what the
				// TLVs mean, not who built the modem) and HW-proven across the
				// Quectel line: RG502Q-EA (Zyxel R13) and RG650E-EU (R01)
				// behave identically. No-ops on a modem that accepts anything.

				// (1) NEVER send the legacy LTE band TLV (0x15) and the
				// extended one (0x24) in the same request — Quectel firmwares
				// answer that pair with INVALID_ARGUMENT (48), which is why
				// unchecking a single LTE band failed. A modem mirrors one into
				// the other anyway, so one is enough. Prefer the extended TLV
				// (the only one that can express bands > 64); a modem whose GET
				// reports no extended mask gets the legacy one.
				let lte_alt = null;   // the other TLV, kept for a one-shot retry

				if (args.lte_band_preference != null && args.ext_lte_band != null) {
					let sent = (!gerr && cur && cur.ext_lte_band == null)
						? 'lte_band_preference' : 'ext_lte_band';
					let spare = (sent == 'ext_lte_band')
						? 'lte_band_preference' : 'ext_lte_band';

					lte_alt = { sent: sent, spare: spare, value: args[spare] };
					delete args[spare];
					changed = filter(changed, (k) => k != spare);
				}

				// (2) An NR5G band TLV (0x2F/0x30) needs a mode preference
				// (0x11) alongside it — without one the firmware answers
				// MISSING_ARGUMENT (17). The guard above strips an unchanged
				// mode_preference, so re-add the value the modem already runs:
				// it changes nothing, hence it stays out of `changed`.
				if ((args.nr5g_sa_band != null || args.nr5g_nsa_band != null) &&
				    args.mode_preference == null &&
				    !gerr && cur?.mode_preference != null)
					args.mode_preference = cur.mode_preference;

				// A firmware that wants the OTHER LTE band TLV than the one
				// rule (1) picked is rescued by a single retry instead of
				// bubbling a bare "qmi" up to the UI — which of the two a
				// firmware accepts is not something we can probe up front.
				let send;   // forward-declared (self-referencing arrow)

				send = (payload, applied, alt) => {
					nas.request('SET_SYSTEM_SELECTION_PREFERENCE', payload, (err) => {
						if (err) {
							if (!alt)
								return cb({ error: 'qmi', detail: err });

							log('notice', sprintf('modem %s: firmware rejected %s (qmi code %s) — retrying with %s',
								ref, alt.sent, err.code ?? '?', alt.spare));

							let retry = { ...payload };

							delete retry[alt.sent];
							retry[alt.spare] = alt.value;

							return send(retry,
								map(applied, (k) => (k == alt.sent) ? alt.spare : k), null);
						}

						log('notice', sprintf('modem %s: system selection preference set: %s%s',
							ref, join(' ', applied),
							q.settings_deferred ? ' (deferred until modem reset)' : ''));

						let res = { applied: applied };

						if (q.settings_deferred) {
							res.deferred = true;
							res.apply = 'modem_reset';
						}

						cb(null, res);
					});
				};

				send(args, changed, lte_alt);
			});
		});
	};

};
