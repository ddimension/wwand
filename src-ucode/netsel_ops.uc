// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — settings / network-selection / operator-scan ubus operations
// (extracted from the daemon.uc factory).
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
// o = { log, check_modem, reg_plmn } — the daemon's modem-ref resolver and
// protocol-neutral registered-PLMN helper stay owned by daemon.uc.

'use strict';

import * as quirks from 'wwand.modem_quirks';
import * as atcmd from 'wwand.atcmd';
import * as nasmod from 'wwand.codec.schema.nas';

// AT+COPS timeouts (netsel AT fallback): the format-set is instant, the read
// can stall on a busy modem, and a manual COPS SET legitimately runs a full
// network search (3GPP allows minutes — 30 s covers the observed worst case
// before the deferred-apply path takes over).
const COPS_FORMAT_TIMEOUT_MS = 5000;
const COPS_READ_TIMEOUT_MS = 10000;
const COPS_SET_TIMEOUT_MS = 30000;

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

	// QmiNasNetworkStatus bits -> a coarse operator status label
	let scan_status = (bits) =>
		(bits & 0x01) ? 'current' :        // NET_STATUS_CURRENT_SERVING (bit 0)
		(bits & 0x10) ? 'forbidden' :      // NET_STATUS_FORBIDDEN (bit 4)
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

		for (let e in (data?.network_information ?? [])) {
			let bits = e.network_status ?? 0;

			push(out, {
				mcc: e.mcc, mnc: e.mnc,
				plmn: sprintf('%d/%02d', e.mcc, e.mnc),
				name: e.description ?? '',
				status: scan_status(bits),
				// extra scan flags carried in the status bitmask
				roaming: (bits & 0x08) ? true : false,   // NET_STATUS_ROAMING (bit 3)
				preferred: (bits & 0x04) ? true : false, // NET_STATUS_PREFERRED (bit 2)
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
		let at_scan = () => {
			let at = entry.modem.at;

			if (!at)
				return cb({ error: 'unsupported_on_backend' });

			at.send('AT+COPS=?', (err, res) => {
				if (err)
					return cb({ error: 'at', detail: err });

				cb(null, { operators: atcmd.parse_cops_scan(res?.lines) });
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

				cb(null, { operators: scan_operators(data) });
			}, { timeout: SCAN_TIMEOUT_MS });
		});
	};

	// async scan job: a scan outlives the LuCI→uhttpd→rpcd XHR chain (uhttpd's
	// script_timeout is 60 s by default while the scan runs minutes), so the UI
	// starts a job and polls. One job per modem; a finished job's result is kept
	// until the next start.
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
	self.modem_set_network_selection = function(ref, mode, mcc, mnc, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (mode != 'auto' && mode != 'manual')
			return cb({ error: 'invalid_mode' });

		let manual = (mode == 'manual');

		if (manual && !(+mcc > 0 && +mnc >= 0))
			return cb({ error: 'missing_plmn' });

		let result = manual ? { mode: mode, mcc: +mcc, mnc: +mnc } : { mode: mode };
		let q = quirks.for_model(entry.modem.info?.model);

		let done_set = (via) => {
			log('notice', sprintf('modem %s: network selection %s%s%s%s', ref, mode,
				manual ? sprintf(' %d/%02d', +mcc, +mnc) : '', via,
				q.netsel_deferred ? ' (deferred until modem reset)' : ''));

			if (q.netsel_deferred) {
				result.deferred = true;
				result.apply = 'modem_reset';
			}

			cb(null, result);
		};

		let skip_set = (via) => {
			log('info', sprintf('modem %s: network selection already %s%s%s — not touching the radio',
				ref, mode, manual ? sprintf(' %d/%02d', +mcc, +mnc) : '', via));
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
					let same = (cur_manual != null) && (cur_manual == manual) &&
						(!manual || (sv?.mcc != null && +sv.mcc == +mcc && +sv.mnc == +mnc));

					if (same)
						return skip_set('');

					// reuse SET_SYSTEM_SELECTION_PREFERENCE's network_selection TLV
					// (mode 0 auto / 1 manual), permanent duration (survives power cycle)
					let sel = manual
						? { mode: 1, mcc: +mcc, mnc: +mnc }
						: { mode: 0 };

					nas.request('SET_SYSTEM_SELECTION_PREFERENCE',
						{ network_selection: sel, change_duration: 1 }, (err) => {
						if (err)
							return cb({ error: 'qmi', detail: err });

						done_set('');
					});
				});
			}

			// AT fallback (NCM): COPS. Manual uses numeric format (COPS mode 2).
			let at = entry.modem.at;

			if (!at)
				return cb({ error: 'unsupported_on_backend' });

			// idempotency: numeric read-back (COPS=3,2 sets the read format only)
			at.send('AT+COPS=3,2', () => {
				at.send('AT+COPS?', (rerr, rres) => {
					let cur = rerr ? null : atcmd.parse_cops_read(rres?.lines);
					let same = cur &&
						((!manual && cur.mode == 0) ||
						 (manual && cur.mode == 1 && cur.plmn == sprintf('%d%02d', +mcc, +mnc)));

					if (same)
						return skip_set(' (AT)');

					let cmd = manual ? sprintf('AT+COPS=1,2,"%d%02d"', +mcc, +mnc) : 'AT+COPS=0';

					at.send(cmd, (err) => {
						if (err)
							return cb({ error: 'at', detail: err });

						done_set(' (AT)');
					}, { timeout: COPS_SET_TIMEOUT_MS });
				}, { timeout: COPS_READ_TIMEOUT_MS });
			}, { timeout: COPS_FORMAT_TIMEOUT_MS });
		});
	};

	// force a network re-registration (deregister + re-attach) so automatic
	// selection re-scans — the fix for a modem camped on a previously-selected
	// PLMN (automatic only re-scans on a reselection trigger; this is it). NOT a
	// modem reset and NOT a PDP-config teardown: the daemon re-activates the same
	// context once the modem re-registers (data blips meanwhile).
	//   - QMI: the backend's native reattach (DMS opmode low_power -> online, a
	//     brief RF bounce — QMI has no pure COPS-2 detach).
	//   - else (NCM / AT modems): AT+COPS=2 (deregister) -> AT+COPS=0 (automatic),
	//     which keeps the RF on (pure registration level).
	self.modem_reattach = function(ref, cb) {
		let entry = check_modem(ref, cb);

		if (!entry)
			return;

		if (entry.modem.reattach) {
			log('notice', sprintf('modem %s: network reattach (backend)', ref));
			return entry.modem.reattach(cb);
		}

		let at = entry.modem.at;

		if (!at)
			return cb({ error: 'unsupported_on_backend' });

		// a bounce is already running — don't stack a second one (it would
		// snapshot zero contexts, clear the flag mid-bounce and race the
		// daemon's reconnect)
		if (entry.modem._reattaching)
			return cb(null, { ok: true, action: 'reattach', via: 'at',
			                  contexts_bounced: 0, contexts_failed: [], busy: true });

		// arm the guard NOW, before the two AT round trips: the daemon's
		// 'down' handler must stay calm during the whole deregister window
		// (the flag also blocks a second reattach invocation)
		entry.modem._reattaching = true;

		log('notice', sprintf('modem %s: network reattach (AT COPS deregister -> automatic)', ref));

		// tolerate a deregister error (already deregistered) — always re-attach
		at.send('AT+COPS=2', () => {
			at.send('AT+COPS=0', (aerr) => {
				if (aerr) {
					entry.modem._reattaching = false;
					return cb({ error: 'at', detail: aerr });
				}

				// the T700's data path does NOT survive the deregister/attach
				// cycle (CGACT stays 1 while the network bearer is gone —
				// field-verified): bounce every connected context so the PDP
				// re-establishes; the re-registration + settings refresh run
				// on their own. QMI/MBIM keep their native reattach.
				// The modem-level flag stops the daemon's own 'down' handler
				// from racing the bounce with enter_reconnecting.
				// snapshot once: a bounced context is CONNECTED again when its
				// up() returns — rescanning would loop it forever
				let todo = [];

				for (let c in (entry.modem.contexts ?? []))
					if (c.state == 'CONNECTED')
						push(todo, c);

				let bounced = 0;
				let failed = [];
				let next_ctx;   // forward-declared (self-referencing arrow)

				next_ctx = () => {
					if (!length(todo)) {
						entry.modem._reattaching = false;

						return cb(null, { ok: true, action: 'reattach', via: 'at',
						                  contexts_bounced: bounced,
						                  contexts_failed: failed });
					}

					let c = shift(todo);

					c.down((de) => {
						if (de) {
							push(failed, { context: c.name ?? '?', step: 'down' });

							return next_ctx();
						}

						bounced++;   // count only successful downs
						c.up((ue) => {
							if (ue)
								push(failed, { context: c.name ?? '?', step: 'up' });

							next_ctx();
						});
					});
				};

				next_ctx();
			}, { timeout: COPS_SET_TIMEOUT_MS });
		}, { timeout: COPS_SET_TIMEOUT_MS });
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

		// band-number lists (LuCI-safe) are converted to masks here. Both LTE
		// band TLVs are filled so the idempotency guard below can compare
		// against whichever one the modem reports — only ONE of them is
		// actually sent (see the firmware shaping there).
		settings = { ...(settings ?? {}) };

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
