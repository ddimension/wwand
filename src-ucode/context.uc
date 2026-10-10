// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — per-PDP-context state machine.
//
// IDLE -> PREPARING -> ACTIVATING -> CONNECTED (MONITORING) -> IDLE
//
// Each context owns up to two fresh WDS clients (IPv4/IPv6, like the old
// cid_4/cid_6 split). Preserved behaviors:
// - fresh WDS CID per attempt, never reused (stale-CID hangs)
// - IPv4 failure is fatal, IPv6 failure degrades to v4-only
// - profile modify retried with roaming_disallowed=no, errors ignored
// - pdp-type written to the modem profile only when it differs
// - apn '#N' selects modem profile N untouched
// - double stop-network attempt on teardown
//
// opts = {
//   name, modem,
//   config: { apn, pdp_type ('ipv4'|'ipv6'|'ipv4v6'), auth, username,
//             password, profile, mux_id, mtu, use_pushed_mtu },
//   deps: { log, on_event (ctx, event, data) },
// }

'use strict';

import * as qmi_backend from 'wwand.qmi_backend';
import * as context_common from 'wwand.context_common';
import * as context_monitor_qmi from 'wwand.context_monitor_qmi';
import * as wdsmod from 'wwand.codec.schema.wds';
import { ENDPOINT_TYPE_HSUSB } from 'wwand.codec.schema.wda';
import * as callend from 'wwand.callend';
import * as cfgmod from 'wwand.config';

// START_NETWORK can legitimately take a long time (network attach + bearer
// setup on a congested cell); only then declare the activation dead.
const START_NETWORK_TIMEOUT_MS = 120000;

// AT+CGDCONT on the old sticks that need the fallback below can take seconds to
// answer, and the answer is not what decides success anyway.
const AT_DEFINE_TIMEOUT_MS = 10000;

// QMI_PROTOCOL_ERROR_NO_EFFECT (libqmi 1.38, qmi-errors.json) — the request
// asked for a state the modem is already in. sim.uc keeps its own copy.
const QMI_ERR_NO_EFFECT = 26;

const wds_schema = wdsmod.default;

const AUTH_MAP = {
	none: wdsmod.AUTH_NONE,
	pap:  wdsmod.AUTH_PAP,
	chap: wdsmod.AUTH_CHAP,
	both: wdsmod.AUTH_BOTH,
};

const PDP_MAP = {
	ipv4:   wdsmod.PDP_TYPE_IPV4,
	ipv6:   wdsmod.PDP_TYPE_IPV6,
	ipv4v6: wdsmod.PDP_TYPE_IPV4V6,
};

// The optional settings an interface may put into the modem profile it dials.
// Each is a stored 3GPP profile setting — WDS Modify Profile input and Get
// Profile Settings output, both since libqmi 1.36 (qmi-service-wds.json:
// 372-377 Address Allocation Preference, 417-422 CLAT Enabled, 424-428 IPv6
// Prefix Delegation; libqmi 1.38). All TRI-STATE in the config: an option
// left unset leaves whatever the profile holds, because the write goes to
// modem NV and a user who never asked should not get one. `key` is the schema
// field (wds.uc), `opt` the interface option (config.uc), `v6` limits a flag to
// a connection that carries IPv6, `map` turns a word option into the enum.
const PROFILE_FLAGS = [
	{ key: 'prefix_delegation', opt: 'ipv6_pd', label: 'IPv6 prefix delegation', v6: true },
	// 464XLAT in the modem (RFC 6877) — only an IPv6 bearer has something to
	// translate onto
	{ key: 'clat', opt: 'clat', label: 'CLAT', v6: true },
	// QmiWdsAddressAllocationPreference (qmi-enums-wds.h:2107-2110, 1.38):
	// how the IPv4 address reaches the UE — in the PDN setup (NAS) or by DHCP
	// over the bearer afterwards
	{ key: 'address_allocation', opt: 'address_allocation', label: 'address allocation',
	  map: { nas: 0, dhcp: 1 } },
];

// The same three PDP types as PDP_MAP, spelled the way 3GPP TS 27.007 AT+CGDCONT
// wants them. Used only by the AT fallback below. (Deliberately a local copy and
// not an import of ncm_vendors' PDP_STR: that module ships in wwand-ncm, this
// one in wwand-qmi, and a QMI-only install must not need it.)
const AT_PDP_STR = {
	ipv4:   'IP',
	ipv6:   'IPV6',
	ipv4v6: 'IPV4V6',
};

const netmask_to_prefix = context_common.netmask_to_prefix;


export function create(opts)
{
	let self = {
		name: opts.name,
		modem: opts.modem,
		config: opts.config ?? {},

		state: 'IDLE',
		families: {},      // '4' | '6' -> { client, pdh, settings }
		settings: null,
		last_error: null,  // { stage, text, code, type, ... } from the last failure
		stats: null,       // cumulative data counters (bytes/packets/errors) since connect
		connected_since: null,
		channel_rate: null, // { tx_rate, rx_rate, max_tx_rate, max_rx_rate } bits/sec
		bearer: null,       // RAT carrying data ('LTE' / '5G NR' / 'LTE + 5G'), pushed by the WDS event report
		dormancy: null,     // 1 = dormant (idle), 2 = active — from the WDS event report
	};


	let deps = opts.deps ?? {};
	let log = deps.log ?? ((level, msg) => warn(sprintf('%s: interface %s: %s\n', level, self.name, msg)));

	// log an assigned family IP config at 'notice' only the FIRST time (at
	// connect — you want to see what the link came up with); every re-log drops
	// to 'debug'. A modem re-pushes settings every few minutes, and an IPv6
	// privacy address rotates its host bits each time (same /64, gw, dns) — a
	// real "change" that is nonetheless routine noise, so it must not stay at
	// notice. netifd still gets the update via the idempotent renew; this is
	// purely the human log line.
	let log_family_config = (fam, msg) => {
		log(fam._logsig == null ? 'notice' : 'debug', msg);
		fam._logsig = msg;
	};

	let up_cb = null;
	// bumped by every up(); guards the async activation flow against late
	// replies after an attempt was aborted (registration lost mid-attempt)
	let up_gen = 0;

	// wire-op steps forward-declared BEFORE the monitor/scaffolding arrows
	// that capture them (ucode resolves lexical refs only for bindings
	// already declared at definition time)
	let prepare, check_pdp_type, activate_family, fetch_settings, release_family;
	let at_define_context;

	// A teardown destroys the WDS config client and reports `cancelled` to every
	// pending callback SYNCHRONOUSLY, with the hub still live. Every callback in
	// the profile paths below either issues another request or calls a
	// continuation, and both are wrong then: the request lands on a client
	// mid-destruction — and these are NV PROFILE WRITES, not reads — while the
	// continuation resumes the context or the modem init chain behind the very
	// teardown meant to stop them.
	//
	// One helper rather than a check per site: there are seven, and the eighth
	// will be written by someone who has not read this comment. It also catches
	// the client being REPLACED, which a retry does.
	//
	// Declared HERE, next to the forward declarations, because a `let` further
	// down is not hoisted in ucode — the arrows above would capture a name that
	// does not exist yet and fail at call time, not at parse time.
	let torn_down = (err, wds) => (err?.error == 'cancelled' ||
	                               self.modem.wds_cfg != wds);
	let mon;   // context_monitor_qmi handle (stats sampler + settings refresh)

	// shared emit/set_state/fail_finish (context_common.ctx_scaffolding)
	let sc = context_common.ctx_scaffolding(self, {
		deps: deps, log: log, stop_stats: () => mon.stop(),
	});
	let emit = sc.emit, set_state = sc.set_state;

	// while-CONNECTED monitoring — extracted to context_monitor_qmi.uc:
	// packet-stats sampler (zero-rx watchdog, netdev fallback, channel rates)
	// and the live settings refresh (event-driven + slow poll)
	mon = context_monitor_qmi.install(self, {
		log: log, emit: emit, timing: opts.timing,
		fetch: (family, done) => fetch_settings(family, done),
	});

	let wanted_families = () => {
		let pdp = context_common.effective_pdp(self);
		let fams = [];

		if (pdp == 'ipv4' || pdp == 'ipv4v6')
			push(fams, 4);

		if (pdp == 'ipv6' || pdp == 'ipv4v6')
			push(fams, 6);

		return fams;
	};

	// per-SIM override (wwand_sim by ICCID) wins over the interface value;
	// shared resolver, see context_common.conn_cfg. Attach profile still
	// falls back to the modem-provisioned APN below.
	let cfg = (field) => context_common.conn_cfg(self, field);

	let resolve_profile = () => {
		let apn = cfg('apn');

		// '#N': use modem profile N as-is
		if (apn != null && substr(apn, 0, 1) == '#')
			return { index: +substr(apn, 1), modify: false };

		let index = +(self.config.profile ?? 0);
		// `option profile` (or `apn '#N'` above) is the operator NAMING a
		// profile; anything else is us picking one to write the APN into.
		let named = (index > 0);

		if (!index)
			index = +(self.config.mux_id ?? 0) || 1;

		return { index: index, named: named, modify: (apn != null && apn != '') };
	};

	// --- PREPARING ---------------------------------------------------------

	prepare = (profile, done) => {
		let wds = self.modem.wds_cfg;

		if (!profile.modify)
			return check_pdp_type(profile, done);

		let base = {
			profile: { type: wdsmod.PROFILE_TYPE_3GPP, index: profile.index },
			profile_name: 'default',
			apn: cfg('apn'),
			apn_disabled: 0,
		};

		if (cfg('auth') != null)
			base.auth = AUTH_MAP[cfg('auth')] ?? wdsmod.AUTH_BOTH;
		else if (cfg('username') && cfg('password'))
			base.auth = wdsmod.AUTH_BOTH;   // preserved default

		if (cfg('username'))
			base.username = cfg('username');

		if (cfg('password'))
			base.password = cfg('password');

		let do_write = () => wds.request('MODIFY_PROFILE', base, (err) => {
			if (torn_down(err, wds))
				return;

			if (err) {
				log('warn', sprintf('profile modify failed: %J', err));

				// INVALID_PROFILE (QMI protocol error 10, libqmi 1.38
				// libqmi-glib/qmi-errors.h:240) SUGGESTS this index does not exist in the
				// modem's WDS profile namespace — a 2009-era stack may have no
				// profile management. Provisional only: on the Huawei E182E the
				// very next step reads the same index back without complaint
				// (HW-observed on the sponsor box, 2026-09-09), i.e. error 10
				// there reports "I do not do profile WRITES", not an absent
				// index. check_pdp_type() revokes the flag when the read
				// succeeds; see the comment there.
				if (err.error == 'qmi' && err.code == 10)
					profile.invalid = profile.write_refused = true;
			}

			// preserved: retry including roaming_disallowed=no, ignore result —
			// except for INVALID_PROFILE, which is a fact about the modem and
			// not about this write. The first attempt can fail for an unrelated
			// reason and the retry be the one that reports the index does not
			// exist; dropping it there left `profile.invalid` unset and sent the
			// invented index to START_NETWORK after all.
			wds.request('MODIFY_PROFILE', { ...base, roaming_disallowed: 0 },
				(e2) => {
					if (torn_down(e2, wds))
						return;

					if (e2?.error == 'qmi' && e2.code == 10)
						profile.invalid = profile.write_refused = true;

					// The QMI write bounced, so the APN never reached the modem
					// and dialling that index would use whatever preset it
					// carries. AT+CGDCONT still lands on this hardware — that is
					// what finally connected the E182E (sponsor box,
					// 2026-09-09). Nothing else changes: the dial still uses
					// profile.index, which is why the fallback writes THAT cid.
					at_define_context(profile, () => check_pdp_type(profile, done));
				});
		});

		// idempotency guard: skip both NV writes when the profile already
		// matches. Credentials cannot be read back — configured username/
		// password always write.
		if (base.username != null || base.password != null)
			return do_write();

		wds.request('GET_PROFILE_SETTINGS', {
			profile: { type: wdsmod.PROFILE_TYPE_3GPP, index: profile.index },
		}, (gerr, curp) => {
			// a cancelled read is not "the profile differs, write it"
			if (torn_down(gerr, wds))
				return;

			let same = !gerr && curp &&
				lc(curp.apn ?? '') == lc(base.apn ?? '') &&
				(curp.apn_disabled ?? 0) == 0 &&
				(curp.roaming_disallowed ?? 0) == 0 &&
				(base.auth == null || curp.auth == base.auth);

			if (same) {
				log('debug', sprintf('profile %d unchanged (apn/auth/roaming) — skipping modify',
					profile.index));
				return check_pdp_type(profile, done, curp);
			}

			do_write();
		});
	};

	// --- AT fallback for the APN ---------------------------------------------
	//
	// A modem that answers MODIFY_PROFILE with INVALID_PROFILE (10) does not
	// take APN writes over QMI at all. Its WDS profiles are still READ- and
	// dial-able, so wwand keeps using the index (see check_pdp_type) — but the
	// index carries whatever the vendor preset says, not the configured APN, and
	// START_NETWORK's inline APN TLV is not honoured by such a stack: the Huawei
	// E182E (Qualcomm 8200A, firmware 2009-11-13) failed every dial with call
	// end reason 11 until the APN was actually IN the context, and connected
	// immediately afterwards (sponsor box, HW-observed 2026-09-09).
	//
	// AT+CGDCONT is the other way in, and the one thing that matters here is
	// that it writes THE SAME index the dial will ask for: `profile.index` goes
	// to START_NETWORK as profile_3gpp, so the cid written here is that number
	// and nothing else. Defining cid 1 and dialling profile 2 would configure a
	// context nobody uses.
	//
	// Best effort by construction: no AT port, or a modem that rejects the
	// command, simply leaves things as they were — the dial then fails the way
	// it did before, which is no worse. The reply is NOT waited on for a verdict
	// either: this stack answers so late that wwand books the answer as a URC
	// and the send reports a timeout even though the write landed (visible in
	// the field log as `urc[at]: +CGDCONT: 1,...` with the new APN).
	at_define_context = (profile, done) => {
		let apn = cfg('apn');

		if (!profile.write_refused || !self.modem?.at || apn == null || apn == '')
			return done();

		let pdp = AT_PDP_STR[context_common.effective_pdp(self)] ?? 'IP';
		let cmd = sprintf('AT+CGDCONT=%d,"%s","%s"', profile.index, pdp, apn);

		log('notice', sprintf('qmi profile write refused — defining context %d over AT instead: %s %s',
			profile.index, pdp, apn));

		self.modem.at.send(cmd, (err) => {
			// A timeout here is not evidence of failure on this hardware, so it
			// is logged and stepped over rather than treated as an error.
			if (err)
				log('debug', sprintf('at context definition returned %J (continuing)', err));

			done();
		}, { timeout: AT_DEFINE_TIMEOUT_MS });
	};

	// The profile flag wanted for IPv6 prefix delegation: 1/0, or null for
	// "leave it". An IPv4-only connection has no prefix to delegate, so the
	// flag is not touched there either way.
	// The optional profile flags this connection asks for (PROFILE_FLAGS),
	// as [ { key, label, want } ] — only the ones set, and only those that
	// apply to the connection's IP family.
	let flags_wanted = () => {
		let v6 = (context_common.effective_pdp(self) != 'ipv4');
		let out = [];

		for (let f in PROFILE_FLAGS) {
			let v = self.config?.[f.opt];

			if (v == null || (f.v6 && !v6))
				continue;

			push(out, { key: f.key, label: f.label, want: f.map ? f.map[v] : (v ? 1 : 0) });
		}

		return filter(out, (f) => f.want != null);
	};

	// The prefix-delegation flag alone: 1/0, or null when not asked for.
	let pd_wanted = () => {
		for (let f in flags_wanted())
			if (f.key == 'prefix_delegation')
				return f.want;

		return null;
	};

	check_pdp_type = (profile, done, pre) => {
		let wds = self.modem.wds_cfg;
		let want = PDP_MAP[context_common.effective_pdp(self)];

		let evaluate = (err, data) => {
			if (torn_down(err, wds))
				return;

			if (err) {
				log('warn', sprintf('get profile settings failed: %J', err));
				return done();
			}

			// The read settles what MODIFY_PROFILE could only suggest: this
			// index is readable, so it EXISTS and may be dialled with, whatever
			// the failed write claimed. Revoking the flag here costs no extra
			// traffic — the request is the one prepare() already had to make —
			// and it is what keeps the E182E dialling: dropping 3gpp-profile
			// from START_NETWORK makes that modem answer "internal error".
			// A read that FAILS leaves the flag as the write set it.
			if (profile.invalid) {
				profile.invalid = false;
				log('notice', sprintf('profile %d is readable — keeping the index despite the rejected write',
					profile.index));
			}

			let req = { profile: { type: wdsmod.PROFILE_TYPE_3GPP, index: profile.index } };

			if (data.pdp_type == want)
				log('debug', sprintf('profile pdp type %d unchanged', want));
			else {
				log('notice', sprintf('changing profile %d pdp type %J -> %d',
					profile.index, data.pdp_type, want));
				req.pdp_type = want;
			}

			// An absent TLV in the read is compared as "differs": a stack that
			// does not report the flag cannot be shown to hold it already.
			let flags = flags_wanted();

			for (let f in flags) {
				if (data[f.key] !== f.want) {
					log('notice', sprintf('changing profile %d %s %J -> %d',
						profile.index, f.label, data[f.key], f.want));
					req[f.key] = f.want;
				}
				else
					log('debug', sprintf('profile %s %d unchanged', f.label, f.want));
			}

			let sent = filter(flags, (f) => req[f.key] != null);

			if (req.pdp_type == null && !length(sent))
				return done();

			let write;
			write = (r) => wds.request('MODIFY_PROFILE', r, (e2) => {
				if (torn_down(e2, wds))
					return;

				// A stack that predates a TLV may refuse the whole message for
				// it. The pdp type is what the dial depends on, so it gets a
				// second write of its own; the flags are reported, not retried
				// one by one — which of them it was, the answer does not say.
				if (e2 && length(filter(sent, (f) => r[f.key] != null))) {
					log('warn', sprintf('profile %d: %s not accepted: %J', profile.index,
						join(', ', map(sent, (f) => f.label)), e2));

					if (r.pdp_type == null)
						return done();

					return write({ profile: r.profile, pdp_type: r.pdp_type });
				}

				if (e2)
					log('warn', sprintf('pdp type change failed: %J', e2));

				done();
			});

			write(req);
		};

		// reuse the profile data the guard in prepare() already fetched
		if (pre)
			return evaluate(null, pre);

		wds.request('GET_PROFILE_SETTINGS', {
			profile: { type: wdsmod.PROFILE_TYPE_3GPP, index: profile.index },
		}, evaluate);
	};

	// Program the LTE attach profile (profile <index>, normally 1) from this
	// context's config so the modem's *autonomous* attach uses the right APN and
	// IP family. The modem attaches before wwand activates its data session, so a
	// stale attach profile (e.g. IPv4-only where the subscription needs IPv4v6)
	// gets the whole attach rejected (EMM #33 "service option not subscribed")
	// and we never reach activation. Called at modem init, before REGISTERING;
	// invokes done(changed) so the caller re-attaches when it changed. The data
	// path still re-applies the same settings via prepare/check_pdp_type at
	// activation time — this only fixes the *attach* that happens earlier.
	self.ensure_attach_profile = function(index, done) {
		let wds = self.modem.wds_cfg;
		let mc = self.modem.config ?? {};

		// The INITIAL-ATTACH bearer, when the network wants a different one from
		// the data connection. The attach happens before wwand activates any
		// session, and some networks want their own APN and credentials for it —
		// an IMS or admin bearer — while the data connection uses another.
		//
		// `init_apn` unset means "the same as the interface", which is what
		// every deployment did before these options existed and stays the
		// default. Credentials come along only with an APN: applying them to
		// whatever APN the profile already held would be a change nobody asked
		// for (config.uc warns about that combination).
		let init = (mc.init_apn != null && mc.init_apn != '');
		let apn = init ? mc.init_apn : cfg('apn');

		// '#N' means "use modem profile N as-is" — never rewrite it
		if (!wds || !index || (apn != null && substr(apn, 0, 1) == '#'))
			return done(false);

		let want_pdp = PDP_MAP[context_common.effective_pdp(self)];
		let prof = { type: wdsmod.PROFILE_TYPE_3GPP, index: index };

		wds.request('GET_PROFILE_SETTINGS', { profile: prof }, (err, data) => {
			// continuing here resumes the MODEM INIT chain behind a teardown
			if (torn_down(err, wds))
				return;

			if (err) {
				log('warn', sprintf('attach profile %d read failed: %J', index, err));
				return done(false);
			}

			// The attach profile carries what the CONFIG says, always: an unset
			// APN is written as an empty one (the network's default), never left
			// as whatever profile 1 happened to hold. Keeping a "provisioned" APN
			// sounds careful and is not: profile 1 survives a modem's previous
			// life, and an MC7710 out of another box attached a Telekom card
			// with its old APN, got limited service and flapped, while an APN
			// set afterwards changed nothing (deborah-3, 2026-10-04). NCM
			// already writes the configured APN, empty included, at every dial
			// (context_ncm.uc). ('#N' handled above; IP family enforced below.)
			let card_apn = data.apn ?? '';
			let want_apn = apn ?? '';
			let configured = (want_apn != '');

			self.effective_apn = want_apn;

			// rewrite whenever the profile differs from the config — an empty
			// config clears a stale APN just as a set one replaces it
			let need_apn = (card_apn != want_apn);
			let need_pdp = (want_pdp != null && data.pdp_type != want_pdp);

			// The attach bearer's credentials come from wherever its APN does:
			// the modem's init_* with an init_apn, otherwise the connection's
			// own (conn_cfg: the card's wwand_sim, then the interface) — an
			// APN whose network demands CHAP rejects an attach without it
			// ("EMM attach failed" while data calls with the same APN and
			// login worked: HW-seen on the RG650E with a CHAP-only M2M card,
			// 2026-09-27). Only with a configured APN: credentials applied to
			// whatever APN the card provisioned would be a change nobody asked
			// for (config.uc warns about init_user without init_apn).
			// Read back for comparison where the modem returns them — the
			// password never is.
			let c_auth = init ? mc.init_auth : (configured ? cfg('auth') : null);
			let c_user = init ? mc.init_user : (configured ? cfg('username') : null);
			let c_pass = init ? mc.init_pass : (configured ? cfg('password') : null);
			let creds = init || configured;
			let want_auth = (creds && c_auth != null)
				? (AUTH_MAP[c_auth] ?? wdsmod.AUTH_BOTH) : null;
			// A password can never be read back, so it cannot be compared — and
			// comparing nothing means "always differs". Left that way it wrote
			// the attach profile on EVERY bring-up, which during an outage is
			// once per retry: an NV write per retry, against a tree whose rule
			// everywhere else is read-before-write precisely to avoid that.
			//
			// So a configured password is written once per VALUE and modem
			// object: a reconnect loop does not rewrite it, and a password
			// changed live (a wwand_sim edit, which no longer rebuilds the
			// modem) still lands.
			let pass_pending = creds && c_pass != null && self.modem._attach_pass !== c_pass;

			let need_auth = creds && ((want_auth != null && data.auth != want_auth) ||
			                          (c_user != null && data.username != c_user) ||
			                          pass_pending);

			// When the attach profile is the data profile (no init_apn), the
			// data bearer IS the one brought up at attach, before wwand dials:
			// a profile flag (PROFILE_FLAGS) written only at dial time reaches
			// the network at the NEXT attach. Written here it rides the
			// re-attach this function already triggers.
			let flags = init ? [] : filter(flags_wanted(), (f) => data[f.key] !== f.want);

			if (!need_apn && !need_pdp && !need_auth && !length(flags)) {
				log('debug', sprintf('attach profile %d up to date (apn %J pdp %J)',
					index, data.apn, data.pdp_type));
				return done(false);
			}

			let mod = { profile: prof };

			if (need_apn) {
				mod.apn = want_apn;
				mod.apn_disabled = 0;
			}

			if (need_auth) {
				if (want_auth != null)
					mod.auth = want_auth;

				if (c_user != null)
					mod.username = c_user;

				if (c_pass != null)
					mod.password = c_pass;
			}

			if (want_pdp != null)
				mod.pdp_type = want_pdp;

			for (let f in flags)
				mod[f.key] = f.want;

			log('notice', sprintf('attach profile %d: apn %s%s, pdp %J->%J%s%s',
				index, need_apn
					? sprintf('%s (was %s)', want_apn == '' ? '(network default)' : sprintf('%J', want_apn),
						card_apn == '' ? '(network default)' : sprintf('%J', card_apn))
					: sprintf('%J', card_apn),
				init ? ' (init_apn — distinct from the data APN)' : '',
				data.pdp_type, want_pdp,
				need_auth ? sprintf(', auth %J%s', c_auth ?? '(kept)', c_user != null ? sprintf(' user %J', c_user) : '') : '',
				join('', map(flags, (f) => sprintf(', %s %J->%d', f.label, data[f.key], f.want)))));

			let write;
			write = (m) => wds.request('MODIFY_PROFILE', m, (e2) => {
				if (torn_down(e2, wds))
					return;

				// the flags must not cost the attach its APN: a stack that
				// refuses one of the TLVs gets the same write again without them
				if (e2 && length(filter(flags, (f) => m[f.key] != null))) {
					log('warn', sprintf('attach profile %d: %s not accepted: %J', index,
						join(', ', map(flags, (f) => f.label)), e2));
					let rest = { ...m };

					for (let f in flags)
						delete rest[f.key];

					if (length(rest) == 1)
						return done(false);

					return write(rest);
				}

				if (e2)
					log('warn', sprintf('attach profile %d modify failed: %J', index, e2));
				else if (m.password != null)
					// Latch only on SUCCESS. Set before the answer, a rejected
					// or cancelled write suppressed the password on every later
					// retry with this modem object — the credential would then
					// never reach the profile at all.
					self.modem._attach_pass = m.password;

				done(!e2);
			});

			write(mod);
		});
	};

	// --- ACTIVATING --------------------------------------------------------

	// `live()` says whether the attempt that asked is still the current one.
	// The CID allocation is the one step whose answer can land AFTER a
	// suspend abort has already emptied self.families: the client it hands
	// back then belongs to nobody, and the next attempt overwrites
	// families['4'] with its own — one WDS CID lost per abort, until the
	// modem runs out (HW-observed on an MC7710, SWI9200X_03.05.29,
	// 2026-10-04: held 1:[8,17,21,25,27] after five aborted dials).
	activate_family = (family, profile, done, live) => {
		// fresh WDS CID per attempt (preserved)
		self.modem.alloc(wds_schema, (err, client) => {
			if (err)
				return done({ stage: 'alloc', err: err });

			if (live && !live()) {
				log('info', sprintf('ipv%d attempt aborted while allocating, releasing wds client %d',
					family, client.cid));
				return self.modem.release(client);
			}

			let fam = { client: client, pdh: null, settings: null };
			self.families[sprintf('%d', family)] = fam;

			client.on('PACKET_SERVICE_STATUS_IND', (data) => {
				if (data.status?.status == wdsmod.CONN_DISCONNECTED)
					self._connection_lost(family, data);
			});

			// WDS event report: bearer + dormancy pushed live (not polled).
			// Both families report the same modem-wide bearer (last-writer-wins).
			// Only current tx/rx is carried (no max), so the channel_rate poll stays.
			client.on('EVENT_REPORT_IND', (data) => {
				if (data.current_bearer?.rat_mask != null) {
					let b = qmi_backend.bearer_label(data.current_bearer.rat_mask);
					if (b)
						self.bearer = b;
				}
				if (data.dormancy != null)
					self.dormancy = data.dormancy;
				// keep the live tx/rx fresh between channel-rate polls (max preserved)
				if (data.channel_rates) {
					self.channel_rate ??= {};
					self.channel_rate.tx_rate = data.channel_rates.tx_rate;
					self.channel_rate.rx_rate = data.channel_rates.rx_rate;
				}
			});

			client.request('SET_EVENT_REPORT',
				{ current_data_bearer: 1, dormancy: 1 }, (e) => null, { no_recovery: true });

			let start_activation;

			// muxed context: bind this wds client to its QMAP channel first.
			// `effective` is 0 where an AUTO channel was not built because the
			// modem cannot carry QMAP — then this context runs on the plain
			// parent, which is exactly what auto promises. A PINNED channel
			// keeps its number and still fails below, because the operator
			// asked for that channel and getting a different datapath silently
			// is worse than being told.
			let dp = self.modem.datapath;
			let mux_id = cfgmod.effective_mux_id(self.config, dp);

			if (mux_id > 0) {
				// an unmuxed datapath (raw_ip, or the 802.3 ethernet mode) has
				// nothing to bind a QMAP channel to
				if (!dp || dp.backend == 'raw_ip' || dp.backend == 'ethernet')
					return done({ stage: 'mux', err: 'mux_unavailable' });

				if (dp.ep_id == null)
					return done({ stage: 'mux', err: 'endpoint_unknown' });

				let orig_start = () => start_activation();

				// The QMAP id on the WIRE is not always the config's channel
				// number: a datapath that ADOPTS a driver's own children
				// inherits that driver's numbering (qmi_wwan_q starts at 0x81),
				// and binding the session to the config number instead makes
				// the driver drop every downlink frame as an unknown mux id.
				// netlink.setup() reports the mapping; equal for every datapath
				// that creates its own children.
				let map_id = dp.map_ids?.[sprintf('%d', mux_id)] ?? mux_id;

				client.request('BIND_MUX_DATA_PORT', {
					endpoint: { type: dp.ep_type ?? ENDPOINT_TYPE_HSUSB, iface: dp.ep_id },
					mux_id: map_id,
					client_type: 1,   // QMI_WDS_CLIENT_TYPE_TETHERED
				}, (berr) => {
					if (berr)
						return done({ stage: 'bind_mux', err: berr });

					orig_start();
				});
			}

			start_activation = () => client.request('SET_IP_FAMILY', {
				preference: (family == 6) ? wdsmod.IP_FAMILY_IPV6 : wdsmod.IP_FAMILY_IPV4,
			}, (e2) => {
				// The worst place in this file to carry on through a
				// cancellation: the next step is START_NETWORK, i.e. bringing a
				// DATA SESSION UP. `lost` destroys the family clients before it
				// moves the context to IDLE, so the destroy reports `cancelled`
				// here while the attempt still looks active — and the session
				// would be started on the way down, with nothing left to own it.
				if (e2?.error == 'cancelled')
					return done({ stage: 'cancelled', err: e2 });

				if (e2)
					log('warn', sprintf('set ip family %d failed: %J', family, e2));

				// apn/auth also passed here (old behavior): several contexts
				// may share a profile index, the request TLVs take precedence.
				let start_args = {};

				// SET_IP_FAMILY (WDS 0x004D) is a separate command an old stack
				// need not implement: the Huawei E182E answers it with
				// INVALID_QMI_COMMAND (71), and relying on it alone starts the
				// session with no family preference at all — the modem then
				// fails START_NETWORK with an internal error. Start Network
				// carries its own "IP Family Preference" TLV for exactly this
				// (0x19; libqmi 1.38, qmi-service-wds.json:787,842), and the
				// bash dialer wwand replaces always passed it as `ip-type=4`.
				//
				// Only when the command actually failed, so a modem that
				// accepts SET_IP_FAMILY keeps receiving exactly the request it
				// receives today.
				if (e2)
					start_args.ip_family = (family == 6) ? wdsmod.IP_FAMILY_IPV6
					                                     : wdsmod.IP_FAMILY_IPV4;

				// The profile index is sent unless the modem has just told us it
				// does not exist. NOTE the earlier claim here — that the bash
				// dialer only sent an index the operator had configured — was a
				// misreading: it sets `profile=1` in every branch, so
				// `${profile:+...}` always expands. The index is dropped only on
				// a modem that answered MODIFY_PROFILE with INVALID_PROFILE
				// (protocol error 10), where asking for it cannot help; a NAMED
				// one is always sent, so a wrong `option profile` still fails
				// loudly instead of being silently ignored.
				if (profile.named || !profile.invalid)
					start_args.profile_3gpp = profile.index;

				if (profile.modify) {
					start_args.apn = cfg('apn');

					if (cfg('auth') != null)
						start_args.auth = AUTH_MAP[cfg('auth')] ?? wdsmod.AUTH_BOTH;

					if (cfg('username')) {
						start_args.username = cfg('username');
						start_args.password = cfg('password');
					}
				}

				// adopt a session the modem already runs — the same path a
				// NO_EFFECT answer takes (below), for a modem that never sends
				// one: an MC7710 (SWI9200X_03.05.29) acknowledges STOP_NETWORK
				// but keeps the LTE default bearer up (the same pdh, the same
				// address, packet status `connected` after the stop), and then
				// answers no START_NETWORK at all until a radio cycle
				// (deborah-3, 2026-10-04). Asked first, the next dial adopts it
				// in a second. Only alone on the modem and unmuxed: with more
				// than one session the status could be another context's.
				let adopt_running = () => {
					fam.pdh = null;
					fam.adopted = true;
					log('notice', sprintf('ipv%d already connected — adopting the running session (no handle of our own to stop later)',
						family));
					done(null);
				};

				let dial = () => {
					log('notice', sprintf('starting ipv%d: apn \'%s\', %s',
						family, cfg('apn') ?? '(profile default)',
						(start_args.profile_3gpp != null)
							? sprintf('profile %d', profile.index)
							: 'no profile (the modem rejected the index — inline apn)'));

					client.request('START_NETWORK', start_args, (e3, d3) => {
						// NO_EFFECT: the session is ALREADY up. A modem with
						// autoconnect dials before anyone asks it to, so the first
						// START_NETWORK of a fresh bring-up can land on a call that
						// exists (ddimension/wwand#18, reported on a RUT956/EC25).
						//
						// THE HANDLE IS NOT OURS AND MUST NOT BE FAKED. Measured on
						// an RG650E: the NO_EFFECT reply carries a pdh TLV of 0, and
						// 0 is not null — so clearing the error and falling through
						// to the `d3?.pdh == null` guard below stores 0 as the
						// handle. wwand then believes it owns a session it never
						// started, logs "pdh 0", and on teardown sends STOP_NETWORK
						// with handle 0, which the modem refuses.
						//
						// A null handle is the truth and the code already knows what
						// to do with it: _close_family releases the client and skips
						// the stop. The settings come from GET_CURRENT_SETTINGS,
						// which asks the client, not the handle.
						//
						// The error still ticks the proto-error counter on its way
						// here (client.uc:176 — no `no_recovery` on the dial, and
						// there must not be: a dial that genuinely fails has to
						// climb). That is deliberate and harmless: the very next
						// successful request zeroes it (recovery.uc:462-463), and
						// the same is already true of the NO_EFFECT that
						// qmi_backend.set_opmode normalises.
						// (a family is registered with pdh null BEFORE the dial,
						// so null alone cannot tell "adopted" from "still
						// dialling" — adopt_running sets `adopted` for the monitor)
						if (e3?.error == 'qmi' && e3.code == QMI_ERR_NO_EFFECT)
							return adopt_running();

						if (e3 || d3?.pdh == null) {
							return done({
								stage: 'start_network',
								err: e3,
								call_end_reason: d3?.call_end_reason,
								verbose: d3?.verbose_call_end,
								ext_error: d3?.ext_error,
							});
						}

						fam.pdh = d3.pdh;
						log('notice', sprintf('ipv%d up, pdh %d (cid %d)', family, fam.pdh, client.cid));
						done(null);
					}, { timeout: START_NETWORK_TIMEOUT_MS });
				};

				let alone = (mux_id == 0) && !length(filter(self.modem.contexts ?? [],
					(c) => c !== self && c.state == 'CONNECTED'));

				if (!alone)
					return dial();

				client.request('GET_PACKET_SERVICE_STATUS', {}, (es, ds) => {
					if (es?.error == 'cancelled')
						return done({ stage: 'cancelled', err: es });

					if (!es && ds?.status == wdsmod.CONN_CONNECTED)
						return adopt_running();

					dial();
				}, { timeout: 5000, no_recovery: true });
			});

			if (mux_id == 0)
				start_activation();
		});
	};

	// The prefix the network DELEGATED to this PDN, as the modem holds it
	// (wds.uc GET_DELEGATED_PREFIX, vendor message 0x00AC). Not a DHCPv6
	// exchange of the router's own: on these modems the bearer's DHCPv6 is the
	// modem's business, and a Solicit with IA_PD from the host on the rmnet
	// link went unanswered for as long as anyone watched (31 sent, 0 back,
	// RM520N-GL on a PD APN, 2026-10-09). Read on every settings fetch, so a
	// prefix the network hands out later — or takes back — reaches netifd
	// through the ordinary settings-change renew.
	//
	// ONLY when the interface asked for PD (`ipv6_pd '1'`). INTERNAL (3) is
	// the modem's "no prefix on this PDN", not a fault; INVALID_QMI_COMMAND
	// (71) means the modem has no such message, remembered per modem object
	// so it is asked once. Neither feeds the recovery ladder. `bearer` is the
	// modem's own address for the PDN (TLV 0x25), which is what its apps side
	// passes. cb(err) with err only for a cancelled read, which the settings
	// poll must see (context_monitor_qmi.uc refresh_settings).
	let read_delegated = (fam, bearer, cb) => {
		if (pd_wanted() != 1 || !bearer || self.modem._pd_unsupported)
			return cb(null);

		fam.client.request('GET_DELEGATED_PREFIX', { requestor: bearer }, (err, data) => {
			if (err?.error == 'cancelled')
				return cb(err);

			let p = (!err && data?.prefix?.addr && data.prefix.plen)
				? sprintf('%s/%d', data.prefix.addr, data.prefix.plen) : null;

			if (err?.error == 'qmi' && err.code == 71) {
				self.modem._pd_unsupported = true;
				log('info', 'IPv6 prefix delegation: this modem cannot report a delegated prefix (no QMI WDS 0x00AC) — only the profile flag is set');
			}
			else if (err && !(err.error == 'qmi' && err.code == 3))
				log('debug', sprintf('delegated prefix read failed: %J', err));

			if (p != fam._pd_last) {
				if (p)
					log('notice', sprintf('ipv6 delegated prefix %s', p));
				else if (fam._pd_last)
					log('notice', sprintf('ipv6 delegated prefix %s withdrawn', fam._pd_last));

				fam._pd_last = p;
			}
			// the first answer of a call is logged even when it is "none" —
			// otherwise a working read and a read that never happened look
			// the same on the device
			else if (!fam._pd_read && !p && !self.modem._pd_unsupported)
				log('debug', 'ipv6 delegated prefix: none on this PDN (the network delegated nothing)');

			fam._pd_read = true;

			if (p)
				fam.settings.delegated = p;

			cb(null);
		}, { no_recovery: true, timeout: 10000 });
	};

	fetch_settings = (family, done) => {
		let fam = self.families[sprintf('%d', family)];

		fam.client.request('GET_CURRENT_SETTINGS', {
			requested: wdsmod.REQ_SETTINGS_DEFAULT,
		}, (err, data) => {
			if (err)
				return done({ stage: 'settings', err: err });

			if (family == 4) {
				// always /32 point-to-point (old behavior) unless the pushed
				// prefix is explicitly requested via use_pushed_prefix
				// (shared rule in context_common)
				let pushed_prefix = netmask_to_prefix(data.netmask);
				let prefix = context_common.v4_prefix(self.config, pushed_prefix, log);

				fam.settings = {
					addr: data.ipv4,
					netmask: data.netmask,
					prefix: prefix,
					pushed_prefix: pushed_prefix,
					gateway: data.gateway,
					dns: filter([ data.dns1, data.dns2 ], (d) => d != null),
					mtu: data.mtu,
				};

				log_family_config(fam, sprintf('ipv4 config: %s/%d gw %s dns [%s] mtu %J',
					fam.settings.addr, fam.settings.prefix, fam.settings.gateway,
					join(' ', fam.settings.dns), fam.settings.mtu));
			}
			else {
				fam.settings = {
					addr: context_common.apply_iface_id(data.ipv6?.addr,
					                                    cfg('ip6ifaceid')),
					plen: data.ipv6?.plen,
					gateway: data.ipv6_gateway?.addr,
					dns: filter([ data.ipv6_dns1, data.ipv6_dns2 ], (d) => d != null),
					mtu: data.mtu,
				};

				log_family_config(fam, sprintf('ipv6 config: %s/%d gw %s dns [%s] mtu %J',
					fam.settings.addr, fam.settings.plen, fam.settings.gateway,
					join(' ', fam.settings.dns), fam.settings.mtu));

				return read_delegated(fam, data.ipv6?.addr,
					(cerr) => done(cerr ? { stage: 'settings', err: cerr } : null));
			}

			done(null);
		});
	};

	release_family = (family, cb) => {
		let key = sprintf('%d', family);
		let fam = self.families[key];

		if (!fam)
			return cb ? cb() : null;

		delete self.families[key];

		let release = () => {
			log('notice', sprintf('released ipv%d wds client %d', family, fam.client.cid));
			self.modem.release(fam.client, () => cb ? cb() : null);
		};

		if (fam.pdh == null)
			return release();

		qmi_backend.stop_network(fam.client, fam.pdh, (err, second) => {
			log(err ? 'warn' : 'notice',
				sprintf('stopped ipv%d connection, pdh %d%s', family, fam.pdh,
					err ? sprintf(' (failed: %J)', err) : (second ? ' (2nd attempt)' : '')));
			release();
		});
	};

	// --- public API --------------------------------------------------------

	// stale-PDP reclaim (QMI internal cause 241, "interface in use, config
	// match"): a call nobody owns holds our profile — some carrier firmwares
	// (e.g. the Zyxel RG502Q) auto-activate their PDP profiles at boot, which
	// blocks START_NETWORK forever. Deactivating the PDP context on our
	// profile index over AT frees it; the caller then retries the family ONCE.
	let is_stale_pdp = (err) =>
		err?.stage == 'start_network' &&
		err.verbose?.type == callend.VERBOSE_TYPE_INTERNAL &&
		err.verbose?.reason == callend.INTERNAL_PDP_IN_USE &&
		self.modem.at != null;

	let reclaim_stale_pdp = (profile, on_done) => {
		log('warn', sprintf(
			'profile %d is in use on the modem, deactivating stale PDP context',
			profile.index));

		self.modem.at.send(sprintf('AT+CGACT=0,%d', profile.index), (aerr) => {
			if (aerr)
				log('warn', sprintf('AT+CGACT=0,%d failed: %J', profile.index, aerr));

			on_done();
		}, { timeout: 15000 });
	};

	self.up = function(cb) {
		if (self.state != 'IDLE')
			return cb({ error: 'busy', state: self.state });

		if (self.modem.state != 'READY')
			return cb({ error: 'modem_not_ready', modem_state: self.modem.state });

		up_cb = cb;

		let gen = ++up_gen;
		let profile = resolve_profile();
		let fams = wanted_families();

		set_state('PREPARING');

		prepare(profile, () => {
			if (gen != up_gen || self.state != 'PREPARING')
				return;   // attempt aborted while preparing — drop the late reply

			set_state('ACTIVATING');

			let idx = 0;
			let got_any = false;
			let reclaimed = {};
			let next, finish;

			next = () => {
				if (idx >= length(fams))
					return finish();

				let family = fams[idx++];

				activate_family(family, profile, (err) => {
					if (gen != up_gen || self.state != 'ACTIVATING')
						return;   // attempt aborted — drop the late reply

					if (err) {
						release_family(family);

						// stale-PDP reclaim (see is_stale_pdp above), once per family
						if (is_stale_pdp(err) && !reclaimed[family]) {
							reclaimed[family] = true;
							return reclaim_stale_pdp(profile, () => {
								if (gen != up_gen || self.state != 'ACTIVATING')
									return;   // attempt aborted while deactivating

								idx--;
								next();
							});
						}

						// preserved: v4 fatal, v6 degrades
						if (family == 4 || !got_any && idx >= length(fams))
							return self._fail(err);

						let cdesc = callend.describe(err?.call_end_reason, err?.verbose, err?.ext_error);
						log('warn', sprintf('ipv%d activation failed, continuing: %s%J', family,
							cdesc?.text ? sprintf('%s (%s%s) ', cdesc.text,
								cdesc.type_name ? cdesc.type_name + ' ' : '', cdesc.code) : '',
							err));
						return next();
					}

					got_any = true;

					fetch_settings(family, (serr) => {
						if (gen != up_gen || self.state != 'ACTIVATING')
							return;   // attempt aborted — drop the late reply

						if (serr) {
							release_family(family);

							// SAME RULE AS THE ACTIVATION FAILURE ABOVE: v4 is
							// fatal, and so is v6 when nothing is left to carry
							// the interface. `got_any` cannot answer that here
							// — it was set for THIS family a few lines up,
							// before the settings were read — so ask what
							// actually survived. Without this a `pdp_type
							// 'ipv6'` context whose settings read failed
							// reached CONNECTED with no families, no settings
							// and a monitor that never re-arms
							// (its settings refresh returns at context_monitor_qmi.uc:299-300 on an
							// empty family set), and sat there until
							// an operator ifdown.
							if (family == 4 ||
							    (!length(keys(self.families)) && idx >= length(fams)))
								return self._fail(serr);

							return next();
						}

						next();
					});
				}, () => gen == up_gen && self.state == 'ACTIVATING');
			};

			finish = () => {
				// `got_any` records that a family DIALLED; the families map
				// records the ones that also got their settings. Both must
				// hold, or the interface goes up owning nothing.
				if (!got_any)
					return self._fail({ stage: 'activate', err: 'no family connected' });

				if (!length(keys(self.families)))
					return self._fail({ stage: 'activate', err: 'no family kept its settings' });

				self.settings = {
					ipv4: self.families['4']?.settings,
					ipv6: self.families['6']?.settings,
					mtu: self.families['4']?.settings?.mtu ?? self.families['6']?.settings?.mtu,
				};

				set_state('CONNECTED');
				self.last_error = null;   // a good connection clears the last failure
				mon.start();
				mon.schedule();
				emit('up', self.settings);

				let cb2 = up_cb;
				up_cb = null;

				if (cb2)
					cb2(null, self.settings);
			};

			next();
		});
	};

	// `reason` lands in the 'down' event ('admin' when not given): 'reattach'
	// is a stop the modem's detach follows (netsel_ops release_sessions)
	self.down = function(cb, reason) {
		let was = self.state;

		mon.stop();
		set_state('IDLE');
		self.settings = null;

		release_family(4, () => {
			release_family(6, () => {
				if (was != 'IDLE')
					emit('down', { reason: reason ?? 'admin' });

				if (cb)
					cb(null);
			});
		});
	};

	self._fail = function(err) {
		// derive a human-readable cause from the QMI call-end / verbose reason
		// (3GPP SM cause etc.) and retain it so the log and the status page can
		// explain *why* activation failed — bad password, forbidden APN, ...
		let desc = callend.describe(err?.call_end_reason, err?.verbose, err?.ext_error);

		// the shim only relays a top-level `error` string to netifd's log —
		// without it every failure shows up as "connection failed: unknown"
		if (err != null && err.error == null)
			err.error = desc?.text ?? sprintf('%s failed', err.stage ?? 'activation');

		self.last_error = {
			stage: err?.stage,
			text:  desc?.text,
			code:  desc?.code,
			type:  desc?.type_name,
			call_end_reason: err?.call_end_reason,
			ext_error: err?.ext_error,
		};

		if (desc?.text)
			log('err', sprintf('activation failed: %s (%s%s)', desc.text,
				desc.type_name ? desc.type_name + ' ' : '', desc.code));
		else
			log('err', sprintf('bring-up failed: %J', err));

		mon.stop();

		let cb = up_cb;
		up_cb = null;

		release_family(4, () => {
			release_family(6, () => sc.fail_finish(err, cb));
		});
	};

	self._connection_lost = function(family, data) {
		if (self.state != 'CONNECTED')
			return;

		// decode the WDS call-end cause: prefer the verbose reason (TLV 0x11,
		// the actionable 3GPP/IPv6/PPP detail) over the coarse code (0x10).
		let cause = callend.describe(data.call_end_reason, data.verbose_call_end);
		log('warn', sprintf('ipv%d connection lost: %s', family,
			cause ? cause.text : sprintf('call-end reason %d', data.call_end_reason ?? 0)));
		mon.stop();
		set_state('IDLE');
		self.settings = null;

		release_family(4, () => {
			release_family(6, () => {
				emit('down', { reason: 'disconnected', family: family, data: data });
			});
		});
	};

	self.modem_event = function(event, data) {
		switch (event) {
		case 'ready':
			emit('modem_ready', {});
			break;

		case 'serving_change':
			// the modem's serving system changed while we are connected — the
			// network may have pushed a new prefix/DNS/MTU; refresh in place
			mon.refresh();
			break;

		case 'lost':
			// device gone: no QMI cleanup possible
			mon.stop();

			for (let key in keys(self.families)) {
				let fam = self.families[key];
				delete self.families[key];
				fam.client.destroy();
			}

			if (self.state != 'IDLE') {
				set_state('IDLE');
				self.settings = null;
				emit('down', { reason: 'modem_lost' });
			}

			if (up_cb) {
				let cb = up_cb;
				up_cb = null;
				cb({ error: 'modem_lost' });
			}

			break;

		case 'suspend':
			log('warn', 'modem lost registration');

			// an in-flight activation cannot succeed without registration and
			// its failure would climb the recovery ladder — abort it. The
			// daemon requeues the request until the modem re-registers.
			if (self.state == 'PREPARING' || self.state == 'ACTIVATING') {
				log('info', 'aborting activation until registration returns');

				let cb = up_cb;
				up_cb = null;

				set_state('IDLE');
				self.settings = null;

				release_family(4, () => {
					release_family(6, () => {
						if (cb)
							cb({ error: 'suspended' });
					});
				});
			}

			emit('suspend', data);
			break;

		case 'sim_blocked':
			if (up_cb) {
				let cb = up_cb;
				up_cb = null;
				cb({ error: 'sim_blocked', detail: data });
			}

			break;
		}
	};

	self.status = function() {
		return {
			name: self.name,
			state: self.state,
			settings: self.settings,
			last_error: self.last_error,
			uptime: (self.state == 'CONNECTED' && self.connected_since) ? (context_common.mono() - self.connected_since) : null,
			stats: (self.state == 'CONNECTED') ? self.stats : null,
			channel_rate: (self.state == 'CONNECTED') ? self.channel_rate : null,
			bearer: (self.state == 'CONNECTED') ? self.bearer : null,
			dormancy: (self.state == 'CONNECTED') ? self.dormancy : null,
			families: map(keys(self.families), (k) => ({
				family: +k,
				cid: self.families[k].client?.cid,
				pdh: self.families[k].pdh,
				adopted: self.families[k].adopted ? true : null,
			})),
		};
	};

	self.modem.attach_context(self);

	return self;
};
