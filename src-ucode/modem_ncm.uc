// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — per-modem state machine for NCM control (cdc_ncm / cdc_ether driver,
// AT-controlled).
//
// NCM modems have NO rich control protocol (no QMI/MBIM): the whole modem is
// driven over an AT channel (atcmd.uc, the same engine the QMI/MBIM backends use
// as a side channel); the datapath is a plain cdc_ncm/cdc_ether netdev. There is
// no message transport to open. Bring-up:
//   open AT -> identify (CGMI/CGMM/CGMR/CGSN/CIMI/CCID) -> SIM/PIN (CPIN?) ->
//   program attach PDP context + auth (CGDCONT + vendor auth) -> wait for
//   registration (CEREG?/CREG?) -> READY. Polled while READY.
//
// Exposes the SAME contract as modem.uc / modem_mbim.uc so daemon.uc, the netifd
// shim and ubus stay protocol-neutral. Contexts use context_ncm.uc.

'use strict';

import * as uloop from 'uloop';
import * as modem_common from 'wwand.modem_common';
import * as telemetry_ncm from 'wwand.telemetry_ncm';
import * as netlink from 'wwand.netlink';
import * as sim from 'wwand.sim';
import * as ncm_vendors from 'wwand.ncm_vendors';
import * as atcmd_parse from 'wwand.atcmd_parse';

const TIMING_DEFAULTS = {
	...modem_common.TIMING_BASE,   // settle/reg_timeout/backoff_min/backoff_max
	reg_poll: 2000,
	at_drain: 60000,
	// grace period for the USB re-enumeration a slot-switch CFUN reset
	// triggers (step_simslot's watchdog). Generous on purpose: a real
	// re-enumeration must always win the race (the T700 comes back slowly),
	// and the watchdog only has to self-heal a firmware that keeps the
	// device across the reset — where nothing else would ever fire.
	reenum: 60000,
};

// The vendor model (PDP/auth builders, per-vendor dial tables + recipes,
// CGDCONT parsers) moved to ncm_vendors.uc — re-exported so the existing
// `modem_ncm.*` consumers (context_ncm, tests) are unchanged, same pattern as
// atcmd.uc re-exporting atcmd_parse.
export const vendor_for = ncm_vendors.vendor_for;
export const build_pdp_setup = ncm_vendors.build_pdp_setup;
export const parse_cgdcont = ncm_vendors.parse_cgdcont;
export const pdp_setup_matches = ncm_vendors.pdp_setup_matches;

// --- CGCONTRDP parsing (shared with context_ncm.uc) --------------------------
//
// AT+CGCONTRDP=<cid> reports the dynamic parameters of an active context. The
// 3GPP layout is:
//   +CGCONTRDP: <cid>,<bearer>,<apn>,<local_addr_and_subnet_mask>,<gw>,
//               <dns1>,<dns2>[,<p-cscf1>,<p-cscf2>,<im_cn>,<lipa>,<ipv4_mtu>...]
// but firmwares diverge wildly for a dual-stack (ipv4v6) context. HW-seen on
// RG650E-EU: BOTH families crammed into ONE line with irregular comma/space
// separators and mixed field widths, e.g.:
//   +CGCONTRDP: 1,5,"apn","192.0.2.229","32.1.13.184...",
//     "254.128.0.0...1","192.0.2.53" "32.1.72.96.72.96...136.136","192.0.2.54" "32.1.72.96.72.96...136.68"
// parse_cgcontrdp + the tokenizer moved to ncm_vendors.uc (shared with the
// per-vendor ip_config hooks); re-exported here for the existing consumers.
export const parse_cgcontrdp = ncm_vendors.parse_cgcontrdp;

// --- AT status parsers -------------------------------------------------------

// +CPIN: READY | SIM PIN | SIM PUK | ...
function parse_cpin(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /\+CPIN:\s*(.+)/);

		if (m)
			return trim(m[1]);
	}

	return null;
}

// Vendor service states (MeiG ^SRVST, manual 8.13 table 145). Numeric keys must
// be quoted in a ucode object literal and looked up via sprintf('%d', n).
const SERVICE_STATE = {
	'0': 'no service',
	'1': 'restricted service',
	'2': 'effective service',
};

// 3GPP TS 27.007 <stat>, shared by +CREG/+CGREG/+CEREG/+C5GREG:
//    0 not registered, not searching     1 registered, home
//    2 searching                         3 registration denied
//    4 unknown                           5 registered, roaming
//    6 registered, SMS only, home        7 registered, SMS only, roaming
//    8 emergency bearer services only    9 registered, CSFB not preferred, home
//   10 registered, CSFB not preferred, roaming
//   11 attached for access to RLOS (restricted local operator services)
//
// `registered` means USABLE FOR DATA, which is narrower than "attached":
//   - 9/10 ARE full data registrations — only CS fallback is deprioritised.
//     Counting them as unregistered (the old stat==1||stat==5 test) left the
//     modem polling forever on any network that signals them.
//   - 6/7 (SMS only), 8 (emergency) and 11 (RLOS) are real attachments that no
//     PDP context can live on, so they stay out of `registered` — but they are
//     reported as `restricted` so the wait can say WHY it is waiting. Observed
//     on a MeiG SLM770A: every registration cycle passes through stat 11,
//     in the same second as its ^SRVST: 1 (limited service), before settling
//     on 5. Until now the log said nothing at all for those seconds.
const REG_USABLE     = [ 1, 5, 9, 10 ];
const REG_ROAMING    = [ 5, 7, 10 ];
const REG_RESTRICTED = [ 6, 7, 8, 11 ];

// human-readable reason for a wait, for the log line only
const REG_WHY = {
	'0': 'not registered, not searching',
	'2': 'searching',
	'3': 'registration denied',
	'4': 'state unknown',
	'6': 'SMS only (home)',
	'7': 'SMS only (roaming)',
	'8': 'emergency bearer services only',
	'11': 'restricted local operator services only',
};

// Handles both the query echo (<n>,<stat>) and the URC (<stat>).
export function parse_creg(lines)
{
	for (let l in (lines ?? [])) {
		// query form "<n>,<stat>" first, then the URC form "<stat>". Group 1 is
		// the optional CE/C5G marker (ucode uses POSIX ERE — no non-capturing
		// groups), so the stat is always group 2.
		let m = match(l, /\+C(E|5G)?REG:\s*[0-9]+,([0-9]+)/) ?? match(l, /\+C(E|5G)?REG:\s*([0-9]+)/);

		if (!m)
			continue;

		let stat = +m[2];

		return {
			stat: stat,
			registered: index(REG_USABLE, stat) >= 0,
			roaming: index(REG_ROAMING, stat) >= 0,
			restricted: index(REG_RESTRICTED, stat) >= 0,
			why: REG_WHY[sprintf('%d', stat)],
		};
	}

	return null;
};



function vendor_telemetry(self)
{
	return self.vendor?.telemetry ?? telemetry_ncm.GENERIC;
}

// --- vendor-serial driver bind (usb-serial new_id) ---------------------------
//
// Some modem compositions carry their AT/DIAG serial interfaces under a USB PID
// the in-kernel `option` driver does not know (its id table only covers the mode
// the vendor ships), so no ttyUSB nodes exist and open_at finds no AT port. For
// known devices, register the id at runtime: writing "vid pid" to the driver's
// new_id probes the already-present device synchronously, so the ttys appear.
//
//   'vid:pid' (lowercase hex) -> usb-serial driver name under
//   /sys/bus/usb-serial/drivers/<name>/new_id
const SERIAL_NEW_ID = {
	// MeiG SLM770A ECM composition — the kernel knows only RNDIS (2dee:4d57).
	// HW-verified on a Cudy LT300 v3.
	'2dee:4d58': 'option1',
	// NOTE: Fibocom FM350-GL (0e8d:7126/7127) is deliberately ABSENT — the
	// kernel option driver binds its serial interfaces itself (since 4.19.318,
	// ADB excepted). A blanket new_id write here would also claim the ADB
	// interface and crash-loop the card (forum-observed).
};

// bind the vendor serial driver for a known composition (netdev anchors the USB
// parent). Returns true when a new_id write was performed. No-op when the device
// is unknown, ttys already exist, or the driver module is not loaded.
export function ensure_serial_bind(fx, netdev)
{
	if (!netdev)
		return false;

	let base = sprintf('/sys/class/net/%s/device/..', netdev);
	let vid = lc(trim(fx.read(sprintf('%s/idVendor', base)) ?? ''));
	let pid = lc(trim(fx.read(sprintf('%s/idProduct', base)) ?? ''));
	let drv = SERIAL_NEW_ID[sprintf('%s:%s', vid, pid)];

	if (!drv)
		return false;

	// serial interfaces already bound? (same sibling glob open_at uses)
	if (length(fx.glob(sprintf('%s/*/tty*', base)) ?? []) > 0)
		return false;

	let node = sprintf('/sys/bus/usb-serial/drivers/%s/new_id', drv);

	if (!fx.exists(node))
		return false;

	return fx.write(node, sprintf('%s %s\n', vid, pid)) == true;
};

export function create(opts)
{
	let self = {
		id: opts.id,
		device: opts.device,
		protocol: 'ncm',
		config: opts.config ?? {},
		timing: { ...TIMING_DEFAULTS, ...(opts.timing ?? {}) },

		state: 'ABSENT',
		vendor: ncm_vendors.VENDORS.generic,
		info: {},
		reg: {},
		reg_detail: null,
		signal: {},
		cells: null,
		dsd_status: null,
		locks: null,
		location: null,
		at: null,
		at_tty: null,
		datapath: null,
		counters: null,
		contexts: [],
	};

	let deps = opts.deps ?? {};
	let log = deps.log ?? ((level, msg) => warn(sprintf('%s: modem %s: %s\n', level, self.id, msg)));
	self.log_fn = log;

	let rec = modem_common.make_recovery(self, opts, log, 'ncm');

	let at_opts = opts.at ?? {};
	let retry_timer = null, reg_timer = null, reg_poll_timer = null, settle_timer = null;
	let reenum_timer = null;   // slot-switch re-enumeration watchdog (step_simslot)
	let poll_inflight = false;   // one register-poll chain at a time (URC fast-path coalescing)
	let no_c5greg = false;       // modem answered ERROR to AT+C5GREG? — stop asking
	// forward-declared: the URC handler below refreshes telemetry on a RAT
	// change, and a ucode closure captures only variables ALREADY declared when
	// it is created — a plain `let` further down reads as undeclared here
	let refresh_signal, refresh_cells, refresh_reg_detail, emit_telemetry;
	let read_operator;
	let last_reg_stat = null;    // last logged registration <stat> (log on change only)
	let poll;   // the register poll (forward-declared; the URC fast path re-runs it)

	// shared radio cycle: CFUN 0 -> settle -> CFUN 1 -> settle -> then()
	// (the recovery ladder's opmode_cycle and step_attach's re-attach both
	// use exactly this dance)
	let cfun_cycle = (then) => {
		self.at.send('AT+CFUN=0', () => {
			settle_timer = uloop.timer(self.timing.settle, () => {
				self.at.send('AT+CFUN=1', () => {
					settle_timer = uloop.timer(self.timing.settle, then);
				}, { timeout: 15000 });
			});
		}, { timeout: 15000 });
	};
	let at_drain_timer = null, telemetry_timer = null;
	let telem_watch;   // modem_common.watch_driver (adaptive fast telemetry loop)

	// protocol-neutral scaffolding (set_state / attach_context /
	// note_connect_success / trip_zero_rx on self; emit + notify_contexts here)
	let scaffold = modem_common.scaffolding(self, { deps: deps, log: log, rec: rec });

	// unsolicited result codes: the engine surfaces idle +CODE lines here
	// (field-verified on the mode-40 AT port: +CREG/+CEREG URCs arrive).
	// Registration URCs act as a fast path — an immediate re-poll instead of
	// waiting out the poll timer (polling stays the fallback; the URCs are
	// best-effort, the parse decision remains the poll's).
	// the shared handler (NITZ, +CGEV PDN) is installed by scaffolding above;
	// NCM adds the registration fast-path on top instead of re-implementing it
	let urc_shared = self.at_on_urc;

	self.at_on_urc = (line, ch) => {
		// (the line itself is logged once, with its channel, by open_at)

		// vendor service / RAT indications. Same contract as the registration
		// URCs: a hint that shortens a wait or refreshes stale telemetry, never
		// a state decision of its own — the poll stays the authority.
		let vev = self.vendor?.service_urc?.(line);

		// Recorded, not acted on: the registration URCs (+CEREG/+CREG) arrive in
		// the SAME burst as ^SRVST and already drive the registration poll, so
		// re-polling here would only be swallowed by poll_inflight. What this
		// adds is the information itself — "registered but carrying nothing" was
		// previously indistinguishable from a healthy modem.
		if (vev?.kind == 'service' && self.service_state != vev.service) {
			self.service_state = vev.service;
			log('info', sprintf('service state: %s',
				SERVICE_STATE[sprintf('%d', vev.service)] ?? sprintf('unknown (%d)', vev.service)));
		}
		else if (vev?.kind == 'mode' && self.rat_mode != vev.cell_service) {
			self.rat_mode = vev.cell_service;

			// This one is NOT redundant: signal and cells come only from the
			// stats poll, so without acting on the push the old radio is shown
			// for up to a full interval (60 s) after a RAT change.
			if (self.state == 'READY' && refresh_signal)
				refresh_signal(() => {
					if (self.state == 'READY')
						refresh_cells(() => emit_telemetry());
				});
		}

		// the vendor's own bearer notification goes to the contexts, which
		// decide what to do with it (they own the session state, not the modem)
		let sev = self.vendor?.session_urc?.(line);

		if (sev)
			scaffold.notify_contexts('session_urc', sev);

		// a registration-class URC short-circuits the REGISTERING poll interval
		if (self.state == 'REGISTERING' && poll && !self._esim_op &&
		    match(line, /^\+?(CEREG|C5GREG|CREG|CGREG|CTZV|EONSNWNAME)[:\s]/))
			poll();

		urc_shared(line, ch);
	};

	// `option sim_slot` needs a slot transport — on the AT-only backend that
	// is the vendor AT slots recipe (Fibocom AT+GTDUALSIM), resolved once the
	// manufacturer is known (the gate below at identify time). Without a
	// recipe the configured slot cannot be selected — the warning is raised
	// there, not here (the vendor is not known yet at create time).
	let emit = scaffold.emit;
	let notify_contexts = scaffold.notify_contexts;
	let sim_block = scaffold.sim_block;
	let enter_ready = scaffold.enter_ready;

	// backend-neutral NAS accessor (daemon settings / network-selection paths):
	// NCM has no QMI at all → null, so the daemon falls back to AT (AT+COPS).
	self.with_nas = function(cb) {
		cb(null);
	};

	// attach PDP context config: the first attached context (interface-bound
	// preferred) drives the modem's autonomous LTE attach, so its APN/auth is
	// what CGDCONT/QICSGP programs at bring-up. Contexts re-apply idempotently at
	// dial time (context_ncm.up).
	let attach_cfg = () => {
		let bound = null;

		for (let ctx in self.contexts) {
			if (ctx.config?.interface)
				return ctx.config;

			bound = bound ?? ctx.config;
		}

		return bound ?? self.config;
	};

	// --- recovery / failure ------------------------------------------------

	let fail = modem_common.make_fail(self, {
		log: log, timing: self.timing, emit: emit,
		set_retry_timer: (t) => retry_timer = t,
		rec: rec,
	});

	// soft recovery rungs (parity with QMI's DMS-based implementations):
	// opmode_cycle = CFUN 0 -> settle -> 1; modem_reset = self.reset (CFUN=1,1)
	modem_common.note_connect_failure_light(self, rec, {
		opmode_cycle: (done) => {
			if (!self.at)
				return done();

			log('warn', 'recovery: cycling operating mode (CFUN 0/1)');
			cfun_cycle(done);
		},
		modem_reset: (done) => {
			if (!self.at)
				return done();

			log('warn', 'recovery: resetting modem');
			self.reset((err) => done());
		},
	});


	// --- step chain --------------------------------------------------------

	let step_identify, step_resolve_dial, step_datapath, step_simslot, step_sim, step_attach, step_register, step_register_go, on_registered;

	// AT side channel: for NCM this IS the control channel (a missing port fails
	// the whole modem — there is no other transport). open_at discovers the tty,
	// opens it and runs model-init + configured at_init + cell locks.
	self.start = function() {
		if (self.at || self.state != 'ABSENT')
			return;

		self.set_state('INIT_TRANSPORT');

		// runtime driver bind for known compositions (SERIAL_NEW_ID) before AT
		// port discovery
		let bind_fx = at_opts.fx ?? netlink.default_fx((l, m) => log(l, m));

		// USB anchor for the serial bind + AT-port discovery: `device` (holds a
		// netdev name on migrated configs), else the datapath netdev — discovery
		// builds NCM modems with device = null (there is no control node), and
		// without an anchor a cold boot where the ttys appear only AFTER the
		// first resolve (runtime new_id bind, late kmodloader) can never find
		// them on retry: cfg.tty was pinned as null and find_tty bails on
		// device == null. HW-hit on the Cudy LT300/SLM770A — 7 no_at_port
		// attempts in a row while ttyUSB0-3 existed the whole time.
		let anchor = self.device ?? opts.datapath?.netdev;

		if (ensure_serial_bind(bind_fx, anchor))
			log('notice', sprintf('registered vendor serial driver id for %s (usb-serial new_id)', anchor));

		modem_common.open_at(self, {
			at_opts: at_opts,
			log: log,
			// AT is this backend's control protocol, so a port that answers —
			// OK or ERROR, the engine does not care which — is exactly the
			// "the modem answered us" the hardware-recovery gate waits for.
			// QMI and MBIM arm from their own clients; without this NCM never
			// armed at all and a genuinely wedged NCM modem could no longer
			// reach the opmode cycle, the reset or the board power-cycle.
			on_answer: () => rec.note_answer(),
			drain_interval: self.timing.at_drain,
			set_drain_timer: (t) => { at_drain_timer = t; },
			base_override: (self.device == null && anchor != null)
				? sprintf('/sys/class/net/%s/device/..', anchor) : null,
			next: () => {
				if (!self.at)
					return fail('open_at', { error: 'no_at_port', device: self.device ?? anchor });

				step_identify();
			},
		});
	};

	// identify the modem: manufacturer selects the vendor recipe; the rest is
	// best-effort (a modem that answers CGMI but not CGSN still proceeds).
	step_identify = () => {
		self.set_state('INIT_SERVICES');

		// The AT layer now routes interleaved URCs to on_urc, so a line
		// arriving here is the command's own answer. It can still be MISSING:
		// the T700 answers AT+CGMI with nothing at all while a PDN teardown is
		// in flight (field-seen: the reply carried only a +CGEV and an OK).
		// An empty answer used to yield null -> vendor_for(null) -> generic,
		// silently losing ip_config/dials/telemetry for the whole session.
		// One retry covers the transient.
		let ask;

		ask = (cmd, done, o, retried) => self.at.send(cmd, (err, res) => {
			let val = null;

			for (let line in (res?.lines ?? [])) {
				let bare = trim(line);

				// skip AT+... response prefixes ("+CGMI: ...") -> take the value
				let m = match(bare, /^\+[A-Z]+:\s*(.*)/);

				val = m ? trim(m[1]) : bare;

				if (val != '')
					break;
			}

			if (!err && (val == null || val == '') && !retried) {
				log('debug', sprintf('%s: empty reply, retrying once', cmd));
				return ask(cmd, done, o, true);
			}

			done(err ? null : val);
		}, o);

		ask('AT+CGMI', (manuf) => {
			self.info.manufacturer = manuf;

			ask('AT+CGMM', (model) => {
				self.info.model = model;

				// resolve the recipe from manufacturer AND model: the model is
				// the answer a modem does not withhold, and it keeps a missing
				// CGMI from silently degrading everything (ip_config, dials,
				// telemetry, slots, eSIM) to `generic` for the whole session.
				self.vendor = vendor_for(manuf, model);

				let vname = ncm_vendors.vendor_name(self.vendor);

				// the vendor's own URC prefixes can only be merged now: which
				// codes a modem pushes unsolicited is a property of the
				// manufacturer, and the AT port was opened before we knew it
				if (length(self.vendor.urcs ?? [])) {
					self.at?.add_urc_prefixes(self.vendor.urcs);
					self.at_telemetry?.add_urc_prefixes?.(self.vendor.urcs);
					log('debug', sprintf('vendor URC prefixes: %s', join(' ', self.vendor.urcs)));
				}

				// seed the service state: ^SRVST is pushed on CHANGE only, so a
				// modem that is already in (or already out of) service when the
				// daemon starts would otherwise report nothing at all until the
				// network next moves. Best-effort — an error just leaves it null.
				if (self.vendor.service_query && self.at)
					self.at.send(self.vendor.service_query, (serr, sres) => {
						let sv = serr ? null : self.vendor.parse_service?.(sres?.lines);

						if (sv == null)
							return;

						self.service_state = sv;
						log('info', sprintf('service state: %s',
							SERVICE_STATE[sprintf('%d', sv)] ?? sprintf('unknown (%d)', sv)));
					});

				// the recipe in use was never logged — a degraded modem looked
				// exactly like a healthy one apart from missing vendor commands
				if (vname == 'generic' && (manuf ?? '') == '')
					log('warn', sprintf('vendor recipe: generic — no manufacturer and model %s matches none; vendor IP config/dial/telemetry are NOT available',
						model ?? '?'));
				else
					log('info', sprintf('vendor recipe: %s (cgmi %s, cgmm %s)',
						vname, manuf ?? '-', model ?? '-'));

				// `option sim_slot` gate: with a vendor AT slots recipe the
				// configured slot is asserted at init (step_simslot, QMI parity);
				// without one it cannot be selected — surface a warning instead
				// of silently running the active slot
				if (+(self.config?.sim_slot ?? 0) && !self.vendor.slots) {
					self.config_warnings = self.config_warnings ?? [];
					push(self.config_warnings, {
						check: 'sim_slot', severity: 'warn',
						message: 'option sim_slot needs a vendor slot recipe on the NCM/AT backend — this modem has none (active slot left unchanged)',
						expected: sprintf('slot %d', +self.config.sim_slot), actual: null,
					});
				}

				ask('AT+CGMR', (rev) => {
					self.info.revision = rev;

					ask('AT+CGSN', (imei) => {
						self.info.imei = imei;
						self.info.device_id = imei;

						ask('AT+CIMI', (imsi) => {
							self.info.imsi = imsi;

							// ICCID command varies by vendor: Quectel AT+QCCID,
							// 3GPP-ish AT+CCID, MeiG (ASR) only AT+ICCID
							// (HW-verified on the SLM770A-R — QCCID/CCID both
							// ERROR there and the identity ended up iccid '?')
							let iccid_cmds = [ 'AT+QCCID', 'AT+CCID', 'AT+ICCID' ];
							let try_iccid;

							try_iccid = (idx, done2) => {
								if (idx >= length(iccid_cmds))
									return done2(null);

								ask(iccid_cmds[idx], (iccid) =>
									iccid ? done2(iccid) : try_iccid(idx + 1, done2));
							};

							try_iccid(0, (iccid) => {
								// strip the '+[Q]ICCID: ' echo some firmwares keep
								let m = iccid ? match(iccid, /([0-9]{18,20})/) : null;
								self.info.iccid = m ? m[1] : iccid;

								log('notice', sprintf('ncm modem %s (%s), imei %s, imsi %s, iccid %s',
									self.info.model ?? '?', self.info.manufacturer ?? '?',
									self.info.imei ?? '?', self.info.imsi ?? '?',
									self.info.iccid ?? '?'));

								// vendor FCC-lock probe (Fibocom T700 family):
								// 0 = unlocked, 1 = one-time unlock, 2 = locked at
								// every power-up. A locked modem stays silent (no
								// registration/URCs) — surface it instead of a hang.
								if (self.vendor?.fcc_probe) {
									// a locked modem stays silent — don't stall the
									// identity chain for the full default timeout
									ask(self.vendor.fcc_probe, (val) => {
										let m = val ? match(val, /([0-9]+)/) : null;

										self.fcc_lock = m ? +m[1] : null;

										if (self.fcc_lock != null && self.fcc_lock != 0)
											log('warn', sprintf('modem FCC lock active (mode %d) — registration may stay silent until unlocked', self.fcc_lock));
									}, { timeout: 2000 });
								}

								// eSIM status probes: each command runs best-effort
								// (the raw answers land in the at-debug log); the
								// last non-empty reply becomes self.esim_state
								if (self.vendor?.esims_probes) {
									let ep_idx = 0;
									let ep_next;

									ep_next = () => {
										if (ep_idx >= length(self.vendor.esims_probes)) {
											// the slot surface is known now — tell the
											// daemon (the eUICC-active case drives the
											// eSIM bring-up refresh; registration is not
											// a usable trigger on an empty eUICC)
											if (self.eslots)
												deps.on_event?.(self, 'esim_ready', { eslots: self.eslots });

											return;
										}

										let cmd = self.vendor.esims_probes[ep_idx++];

										ask(cmd, (val) => {
											if (val != null && val != '') {
												self.esim_state = val;

												if (cmd == 'AT+ESLOTSINFO?')
													self.eslots = ncm_vendors.parse_eslotsinfo([ '+ESLOTSINFO: ' + val ]);
											}

											ep_next();
										}, { timeout: 2000 });
									};

									ep_next();
								}

								// per-SIM override (config wwand_sim) — parity
								// with the QMI backend; consumed via conn_cfg
								self.active_sim = modem_common.match_sim_override(
									self.config?.sims, self.info.iccid, self.info.imsi);
								if (self.active_sim)
									log('notice', sprintf('SIM %s matched a configured wwand_sim (per-SIM pin/apn)',
										self.info.iccid ?? self.info.imsi));

								// stable-identity gate (see modem_common.check_identity)
								if (!modem_common.check_identity(self, { emit: emit, log: log }))
									return;

								step_resolve_dial();
							});
						});
					});
				});
			});
		});
	};

	// resolve the dial method ONCE per modem: try the vendor's ordered dials,
	// adopting the first whose support-probe (if any) answers OK (a probe-less
	// dial is adopted directly). The list always ends in CGACT, so self.dial is
	// always set. HW: RG650E answers ERROR to the QNETDEVCTL probe -> CGACT.
	step_resolve_dial = () => {
		let dials = self.vendor.dials ?? [ ncm_vendors.DIAL_CGACT ];
		let i = 0, tryNext;

		tryNext = () => {
			if (i >= length(dials)) {
				self.dial = ncm_vendors.DIAL_CGACT;
				log('notice', 'dial method: cgact (fallback)');
				return step_datapath();
			}

			let dm = dials[i++];

			if (!dm.probe) {
				self.dial = dm;
				log('notice', sprintf('dial method: %s', dm.name));
				return step_datapath();
			}

			self.at.send(dm.probe, (err) => {
				if (!err) {
					self.dial = dm;
					log('notice', sprintf('dial method: %s', dm.name));
					return step_datapath();
				}

				log('info', sprintf('dial method %s unsupported (%s), trying next', dm.name, dm.probe));
				tryNext();
			});
		};

		tryNext();
	};

	// --- dual-SIM slots (sim.uc dispatches here for the AT backend) ----------
	// slot_status: the vendor recipe's dual-sim query (Fibocom GTDUALSIM).
	// Only the ACTIVE card's identity is readable — the inactive slot reports
	// 'present' with null identity until a switch re-reads it at bring-up.
	self.slot_status = (cb) => {
		let sl = self.vendor?.slots;

		if (!sl)
			return cb({ error: 'unsupported' }, null);

		self.at.send(sl.query, (err, res) => {
			let st = err ? null : sl.parse(res?.lines);

			if (!st)
				return cb(err ?? { error: 'no_slot_status' }, null);

			// ESLOTSINFO enrichment (field-verified): per-slot EID/CPIN/ICCID —
			// the eUICC slot reports CPIN EMPTY_EUICC when no profile is
			// provisioned; the GTDUALSIM read-back stays the active/service
			// source and the identity fallback
			let es1 = self.eslots?.[0] ?? null;
			let es2 = self.eslots?.[1] ?? null;

			cb(null, [
				{ physical: 1, card: 'present', active: st.sub == 1,
				  logical_slot: null,
				  iccid: es1?.iccid ?? ((st.sub == 1) ? (self.info?.iccid ?? null) : null),
				  is_euicc: es1?.kind == 'euicc', eid: es1?.eid ?? null, cpin: es1?.cpin ?? null,
				  service: (st.sub == 1) ? (st.service ?? null) : null },
				{ physical: 2, card: 'present', active: st.sub == 2,
				  logical_slot: null,
				  iccid: es2?.iccid ?? ((st.sub == 2) ? (self.info?.iccid ?? null) : null),
				  is_euicc: es2?.kind == 'euicc', eid: es2?.eid ?? null, cpin: es2?.cpin ?? null,
				  service: (st.sub == 2) ? (st.service ?? null) : null },
			]);
		}, { timeout: 8000 });
	};

	// switch_slot: GTDUALSIM=<n-1> + a CFUN reset so the firmware re-reads the
	// other card deterministically (the current registration drops — the
	// daemon's reg poll follows it through deregistered/registered)
	self.switch_slot = (physical, cb) => {
		let sl = self.vendor?.slots;

		if (!sl)
			return cb({ error: 'unsupported' });

		self.at.send(sl.query, (err, res) => {
			let st = err ? null : sl.parse(res?.lines);

			if (st && st.sub == +physical)
				return cb(null, { unchanged: true });

			// a failed status read must not trigger a blind switch + CFUN —
			// the slot state is unknown, so a reset could drop a working
			// registration for nothing
			if (!st)
				return cb(err ?? { error: 'no_slot_status' });

			self.at.send(sl.switch(physical), (e2) => {
				// a rejected switch command (unsupported form, modem error) must
				// not still fire the CFUN reset — that would drop a working
				// registration for a switch that never took. Same principle as
				// the status-read guard above: no blind reset on unknown state.
				if (e2)
					return cb(e2);

				// the CFUN error must not be swallowed: the new card is only
				// re-read after the reset — without it the switch never took
				self.at.send('AT+CFUN=1,1', (f2) => cb(f2));
			}, { timeout: 8000 });
		}, { timeout: 8000 });
	};

	// datapath: a plain cdc_ncm/cdc_ether/rndis_host netdev carries no mux and
	// needs no driver format change (unlike qmi_wwan raw-ip). Just bring the
	// parent link up; the IP comes from the connection (context_ncm). Skipped
	// in host tests (no fx -> the 'cdc_ncm' label fallback).
	step_datapath = () => {
		let dp = opts.datapath;
		let drv = 'cdc_ncm';

		if (dp?.netdev && dp.fx) {
			// the real netdev driver name (rndis_host / cdc_ether / cdc_ncm) —
			// readlink the driver symlink under the netdev's sysfs dir
			let lnk = dp.fx.readlink(sprintf('/sys/class/net/%s/device/driver', dp.netdev));

			if (lnk != null && length(lnk))
				drv = substr(lnk, rindex(lnk, '/') + 1);
		}

		self.datapath = { backend: drv, netdev: dp?.netdev ?? null, fx: dp?.fx };

		if (dp?.netdev && dp.fx) {
			// RNDIS is a point-to-point hop: disable ARP so the gateway-less
			// device route (netifd default) needs no neighbour resolution —
			// the modem receives everything sent to the netdev
			dp.fx.link_set(dp.netdev, { up: true, noarp: (drv == 'rndis_host') });
			log('notice', sprintf('datapath: %s netdev %s up%s', drv, dp.netdev,
				(drv == 'rndis_host') ? ' (noarp)' : ''));

			// accept IPv6 router advertisements on the host link: on
			// IPv6-only/464XLAT setups the modem (or the network behind its
			// internal CLAT) may serve the host v6 via RA/SLAAC. A router box
			// leaves accept_ra off (forwarding=1), and the daemon's
			// settings-gated _enable_ipv6 only clears disable_ipv6 when the
			// modem reports a static v6 — so both must be set here,
			// unconditionally. accept_ra=2 accepts even with forwarding on.
			for (let k in [ 'disable_ipv6', 'accept_ra' ]) {
				let path = sprintf('/proc/sys/net/ipv6/conf/%s/%s', dp.netdev, k);

				if (dp.fx.exists(path) &&
				    !dp.fx.write(path, k == 'accept_ra' ? '2' : '0'))
					log('warn', sprintf('datapath: writing %s failed', path));
			}
		}

		step_simslot();
	};

	// assert the configured physical SIM slot (option sim_slot, 0 = leave
	// as-is) via the vendor AT slots recipe — QMI parity (a switch
	// re-initializes the SIM stack, so it runs BEFORE the SIM step). Without
	// a recipe the identify-time warning already flagged the config.
	step_simslot = () => {
		let want = +(self.config?.sim_slot ?? 0);

		if (!want || !self.vendor?.slots)
			return step_sim();

		// ONE switch attempt per modem object: the switch ends in a CFUN reset
		// that re-runs this whole chain (via the hotplug restart, or the
		// watchdog below — both reuse this object). A firmware that accepts
		// the command without ever making the slot active would otherwise
		// reset in a loop. The second pass only reports where we ended up.
		if (self._slot_switch_tried) {
			self.slot_status((serr, slots) => {
				let act = filter(slots ?? [], (s) => s.active)[0]?.physical;

				if (act != want)
					log('warn', sprintf('sim_slot %d: still not active after the switch + reset (active slot %s) — continuing there',
						want, act ?? '?'));
				else
					log('info', sprintf('sim_slot %d active after the switch', want));

				step_sim();
			});
			return;
		}

		self._slot_switch_tried = true;

		sim.switch_slot(self, want, (err, res) => {
			if (res?.unchanged) {
				// nothing was sent and nothing reset — this does not count
				// as the one attempt
				self._slot_switch_tried = false;
				log('info', sprintf('sim_slot %d already active', want));
				return step_sim();
			}

			if (err) {
				log('warn', sprintf('sim_slot %d: slot switch failed (%J), continuing on the active slot', want, err));
				return step_sim();
			}

			// the switch fired the CFUN reset — the modem re-enumerates and
			// the daemon re-runs the bring-up on the configured slot (the
			// hotplug 'add' restarts every ABSENT modem that has no AT port).
			log('notice', sprintf('sim_slot %d: switched, modem re-enumerating', want));
			self.stop();

			// ...but only IF it re-enumerates: firmwares that keep the USB
			// device across the CFUN reset fire no hotplug at all, and this
			// object would sit ABSENT forever. Resume the bring-up in place
			// once the reset has had time to settle. start() is state-guarded
			// (self.at set / state != ABSENT), so a modem the hotplug already
			// restarted is left untouched — the timer is armed AFTER stop(),
			// whose teardown() would otherwise cancel it right away.
			reenum_timer = uloop.timer(self.timing.reenum, () => {
				reenum_timer = null;

				if (self.at || self.state != 'ABSENT')
					return;   // the hotplug path already restarted us

				log('notice', sprintf('sim_slot %d: no re-enumeration after the switch, resuming the bring-up in place', want));
				self.start();
			});
		});
	};

	step_sim = () => {
		self.set_state('SIM_UNLOCK');

		self.at.send('AT+CPIN?', (err, res) => {
			let st = parse_cpin(res?.lines);

			// +CME ERROR: 10 (SIM not inserted) / other hard SIM faults
			if (err && err.error == 'cme' && err.code == '10') {
				sim_block({ reason: 'sim_absent' });
				return;
			}

			if (st == 'READY')
				return step_attach();

			if (st == 'SIM PIN') {
				let pincode = sim.effective_pincode(self);
				let block = (reason, retries) => {
					sim_block({ reason: reason, retries: retries });
				};

				if (!pincode)
					return block('pin_required_no_pin');

				// PIN-safety: query the remaining attempts (Quectel AT+QPINC="SC":
				// +QPINC: "SC",<pin_remaining>,<puk_remaining>) and refuse to
				// auto-burn the last try. Best-effort — if the modem lacks QPINC,
				// retries stays null and pin_block_reason lets it proceed.
				return self.at.send('AT+QPINC="SC"', (qerr, qres) => {
					let retries = null;

					for (let l in (qres?.lines ?? [])) {
						let m = match(l, /\+QPINC:\s*(?:"[^"]*",\s*)?([0-9]+)/);
						if (m) { retries = +m[1]; break; }
					}

					let br = sim.pin_block_reason(retries, self.pin_force);

					if (br)
						return block(br, retries);

					self.at.send(sprintf('AT+CPIN="%s"', pincode), (verr) => {
						if (verr)
							return block('verify_failed');

						log('notice', 'sim: pin accepted');
						settle_timer = uloop.timer(self.timing.settle, step_attach);
					});
				});
			}

			if (st == 'SIM PUK' || st == 'SIM PUK2') {
				sim_block({ reason: 'puk_required' });
				return;
			}

			// unknown state or query error: proceed and let registration decide
			step_attach();
		});
	};

	// program the attach PDP context (CGDCONT + vendor auth) so the modem's
	// autonomous attach uses the right APN and IP family. Best-effort: a modem
	// that rejects a command still proceeds to registration.
	//
	// Parity with QMI ensure_attach_profile / MBIM step_attach_profile: when a
	// concrete configured APN actually CHANGES context 1, the modem must re-run
	// its EPS attach — it may have auto-attached at power-on (or CFUN=1 above) on
	// the stale/provisioned context 1, and rewriting CGDCONT alone does NOT
	// re-trigger the attach. So read CGDCONT? first, and on a real change cycle
	// the radio (CFUN=0 -> CFUN=1) after the writes to force the re-attach.
	step_attach = () => {
		self.set_state('CONFIGURING');

		let cfg = attach_cfg();
		// one-time vendor init (e.g. CFUN=1) + the attach context definition/auth
		let cmds = [ ...(self.vendor.modem_init ?? []), ...build_pdp_setup(self.vendor, 1, cfg) ];

		if (!length(cmds))
			return step_register();

		log('notice', sprintf('attach context 1: apn %J (%s), pdp %s',
			cfg.apn ?? '', (cfg.apn == null || cfg.apn == '') ? 'network default' : 'configured',
			cfg.pdp_type ?? 'ipv4v6'));

		// only a concrete configured APN (not empty/network-default, not a '#N'
		// pass-through) forces a re-attach; an empty APN leaves the provisioned
		// context untouched (QMI parity — never blindly detach the network default)
		let apn = cfg.apn;
		let configured = (apn != null && apn != '' && substr(apn, 0, 1) != '#');

		self.at.send('AT+CGDCONT?', (rerr, rres) => {
			// changed = a concrete APN that context 1 does not already carry
			// (pdp_setup_matches compares pdp-type + APN; a read error => assume
			// changed and re-attach, the safe side)
			let changed = configured &&
				!ncm_vendors.pdp_setup_matches(1, cfg, rres?.lines);

			self.at.run_sequence(cmds, () => {
				if (!changed)
					return step_register();

				log('notice', 'attach context changed, cycling radio to re-attach');
				cfun_cycle(step_register);
			});
		}, { timeout: 8000 });
	};

	// registration: poll CEREG (LTE/5G) then CREG (fallback) until the modem is
	// registered home/roaming or the timeout elapses.
	step_register = () => {
		// before registering: debug-dump + restore the configured preferred list
		// (NCM has no NAS — a 'nas' list errors and is logged; a 'user' list goes
		// out over AT+CPOL). Best-effort, never blocks bring-up.
		sim.log_preradio(self, log, () => sim.restore_preferred_plmn(self, log, () => step_register_go()));
	};

	step_register_go = () => {
		self.set_state('REGISTERING');
		last_reg_stat = null;

		if (reg_timer) reg_timer.cancel();
		reg_timer = uloop.timer(self.timing.reg_timeout, () => {
			if (self.state == 'REGISTERING')
				fail('registration_timeout', { reg: self.reg, detail: self.reg_detail });
		});

		poll = () => {
			if (self.state != 'REGISTERING' || !self.at || poll_inflight)
				return;

			poll_inflight = true;

			self.at.send('AT+CEREG?', (err, res) => {
				// stale callback after a teardown/reload nulled self.at: must not
				// drive a dead modem to READY or send on a null engine
				if (self.state != 'REGISTERING' || !self.at) {
					poll_inflight = false;
					return;
				}

				let r = err ? null : parse_creg(res?.lines);

				let after = (rr) => {
					poll_inflight = false;

					if (rr?.registered)
						return on_registered(rr);

					// say WHY the wait continues, once per change of reason. A
					// registration wait used to be completely silent at notice
					// level: "not registered" for minutes, with the denial or
					// the restricted attach only visible under debug.
					if (rr?.stat != null && rr.stat != last_reg_stat) {
						last_reg_stat = rr.stat;
						log('notice', sprintf('waiting for registration: %s (stat %d)',
							rr.why ?? (rr.restricted ? 'attached, but not usable for data' : 'not registered'),
							rr.stat));
					}

					if (self.state == 'REGISTERING') {
						// the URC fast path can re-enter poll() while a timer is
						// still pending — cancel first, or both fire
						if (reg_poll_timer)
							reg_poll_timer.cancel();

						reg_poll_timer = uloop.timer(self.timing.reg_poll, poll);
					}
				};

				if (r?.registered)
					return after(r);

				// legacy CREG, the last rung of the chain
				let then_creg = (rr5) => {
					if (rr5?.registered)
						return after(rr5);

					self.at.send('AT+CREG?', (e2, r2) =>
						after((!e2 && parse_creg(r2?.lines)?.registered) ? parse_creg(r2.lines) : r));
				};

				// 5G-SA: EPS registration (CEREG) can read not-registered while the
				// device is attached via 5GS only — try C5GREG, then legacy CREG.
				//
				// A modem without 5G refuses the command for good (SLM770A, LTE
				// Cat4: plain ERROR). Latch it off on the first refusal: otherwise
				// every 2 s registration poll pays a round-trip for it AND logs a
				// warning, which on a small box is the bulk of the log while the
				// modem is searching — exactly when the log is worth reading.
				if (no_c5greg)
					return then_creg(null);

				self.at.send('AT+C5GREG?', (e5, r5) => {
					if (self.state != 'REGISTERING' || !self.at) {
						poll_inflight = false;
						return;
					}

					if (e5) {
						no_c5greg = true;
						log('info', 'AT+C5GREG? refused — no 5GS registration polling on this modem');
					}

					let r5p = e5 ? null : parse_creg(r5?.lines);

					then_creg((r5p?.registered) ? r5p : null);
				});
			});
		};

		poll();
	};

	// forward-declared above: referenced by step_register's poll closure
	// vendor command first (fast, carries the name), else the 3GPP read. COPS
	// gets a long timeout on purpose: on the SLM770A it takes over 8 seconds and
	// times out at the default, which is exactly why the vendor path is tried
	// first rather than as a fallback.
	read_operator = () => {
		if (!self.at)
			return;

		// a name-only answer (COPS format 0) carries no mcc/mnc and is still
		// worth having — the status page shows the name, which is what a human
		// reads anyway
		let store = (p) => {
			if (p?.mcc || length(p?.description ?? ''))
				self.reg.plmn = p;
		};

		if (self.vendor?.operator_query) {
			self.at.send(self.vendor.operator_query, (err, res) => {
				if (!err && self.reg)
					store(self.vendor.parse_operator?.(res?.lines));
			});

			return;
		}

		self.at.send('AT+COPS?', (err, res) => {
			if (err || !self.reg)
				return;

			let c = atcmd_parse.parse_cops_read(res?.lines);

			if (!c)
				return;

			// Both answer shapes are useful and BOTH occur in the field: the
			// 3GPP default format is 0 (long alphanumeric), so a modem left at
			// the default reports a NAME and no mcc/mnc — accepting only the
			// numeric form would silently report nothing at all on it (the
			// Fibocom FM350 documents no vendor operator command, so this
			// generic path is the only one it has).
			if (c.plmn != null && match(c.plmn, /^[0-9]{5,6}$/))
				return store({ mcc: +substr(c.plmn, 0, 3), mnc: +substr(c.plmn, 3),
				               description: null });

			if (length(c.oper ?? ''))
				store({ mcc: null, mnc: null, description: c.oper });
		}, { timeout: 20000 });
	};

	on_registered = (r) => {
		if (reg_timer) { reg_timer.cancel(); reg_timer = null; }
		if (reg_poll_timer) { reg_poll_timer.cancel(); reg_poll_timer = null; }

		self.reg = { registration: 1, roaming: r.roaming };
		self.reg_detail = null;   // registered: clear any stale reject info
		self.counters.attempts = 0;

		// who we are registered WITH. The QMI backend gets this from the serving
		// system indication (current_plmn); on the AT path nobody ever asked, so
		// every NCM modem reported an empty operator — and LuCI's status page,
		// which reads reg.plmn, showed a dash where the network name belongs.
		// Best-effort and asynchronous: a failure just leaves it unset.
		read_operator();

		log('notice', sprintf('registered (%s)', r.roaming ? 'roaming' : 'home'));
		enter_ready();

		// the 'registered' emit can run a SYNCHRONOUS config reload that tears
		// this very instance down (autosetup phase 2 writes uci and reloads;
		// close_at nulls the AT engines) — don't start telemetry on the corpse
		if (self.state != 'READY')
			return;

		let t = vendor_telemetry(self);

		// one-time warning for best-effort (unverified) telemetry recipes
		if (t.unverified && !self._tel_warned) {
			self._tel_warned = true;
			log('warn', sprintf('telemetry recipe for %s is best-effort/unverified (needs HW check)',
				self.info.manufacturer ?? '?'));
		}

		// cell-lock read-back once on entering READY (Quectel only today)
		if (t.locks)
			t.locks(self, () => null);

		self._start_telemetry();
	};

	// --- telemetry ---------------------------------------------------------
	//
	// self.signal / self.cells / self.dsd_status are populated in shapes the
	// LuCI status page understands (as the QMI/MBIM AT-fallback paths do): CSQ
	// gives an RSSI floor, AT+QENG="servingcell" the serving cell (rsrp/rsrq/
	// sinr + NR carrier), AT+QCAINFO the LTE aggregation set.

	// telemetry reads route through the vendor telemetry block, falling back to
	// the 3GPP-generic block. Each step is best-effort — an erroring command is
	// swallowed and the last-known value kept.

	refresh_signal = (cb) => {
		cb = cb ?? (() => null);

		if (!self.at)
			return cb();

		vendor_telemetry(self).signal(self, cb);
	};

	refresh_cells = (cb) => {
		cb = cb ?? (() => null);

		if (!self.at)
			return cb();

		let t = vendor_telemetry(self);

		t.cells(self, () => {
			if (!self.at)
				return cb();

			t.ca(self, cb);
		});
	};

	refresh_reg_detail = (cb) => {
		cb = cb ?? (() => null);

		if (!self.at)
			return cb();

		vendor_telemetry(self).reg_detail(self, cb);
	};

	emit_telemetry = () => emit('telemetry', { signal: self.signal, cells: self.cells, reg: self.reg });

	let log_telemetry = () => {
		log('debug', sprintf('telemetry: %s', modem_common.format_telemetry(self)));
	};

	// fast "watch" loop while a consumer polls modem_signal/modem_cells — the
	// adaptive cadence lives in modem_common.watch_driver (shared with QMI/MBIM);
	// this is just the NCM refresh body. done() is called once per cycle.
	let refresh_fast = (done) => {
		refresh_signal(() => {
			if (!self.at)
				return done();

			refresh_cells(() => {
				emit_telemetry();
				done();
			});
		});
	};

	telem_watch = modem_common.watch_driver({
		alive:   () => self.at != null,
		ready:   () => self.state == 'READY',
		refresh: refresh_fast,
	});

	self.watch = () => telem_watch.watch();

	// slow telemetry loop + registration-loss detection (no unsolicited AT
	// notifications are relied upon; a CEREG poll doubles as the liveness check)
	self._start_telemetry = function() {
		if (telemetry_timer)
			return;

		let interval = +(self.config.stats_interval ?? 60) * 1000;

		if (interval <= 0)
			return;

		let tick;

		tick = () => {
			if (!self.at || self.state != 'READY')
				return;

			// registration liveness: a lost registration suspends contexts and
			// re-enters the registration wait (parity with modem_mbim)
			self.at.send('AT+CEREG?', (err, res) => {
				let r = err ? null : parse_creg(res?.lines);

				if (r && !r.registered) {
					log('warn', 'registration lost');
					emit('deregistered', self.reg);
					self.reg = { registration: 0 };
					notify_contexts('suspend', self.reg);
					step_register();
					return;
				}

				refresh_signal(() => refresh_cells(() => refresh_reg_detail(() =>
					modem_common.collect_temperature(self, () =>
					    modem_common.probe_iot_rat(self, () => {
						if (!self.at)
							return;

						log_telemetry();
						emit_telemetry();
						telemetry_timer = uloop.timer(interval, tick);
					})))));
			});
		};

		telemetry_timer = uloop.timer(min(interval, 5000), tick);
	};

	// --- lifecycle ---------------------------------------------------------
	// (switch_protocol / protocol_switch_supported come from scaffolding)

	// the card behind the modem changed in place (eSIM switch applied via the
	// CFUN=0/1 cycle): re-read IMSI/ICCID over AT and re-resolve the per-SIM
	// override — the old card's wwand_sim must not stick. The next (re)dial
	// picks the override up via conn_cfg; CGDCONT is (re)written at dial time
	// anyway, so there is no attach-profile step here. cb optional.
	self.reapply_sim = function(cb) {
		if (!self.at)
			return cb ? cb(null) : null;

		let q = (cmd, done) => self.at.send(cmd, (err, res) => {
			if (err)
				return done(null);

			for (let l in (res?.lines ?? [])) {
				l = trim(l);
				if (length(l) && l != 'OK')
					return done(l);
			}

			done(null);
		}, { timeout: 8000 });

		q('AT+CIMI', (imsi) => {
			let mi = imsi ? match(imsi, /([0-9]{6,15})/) : null;

			if (mi)
				self.info.imsi = mi[1];

			let finish = (iccid) => {
				if (iccid)
					self.info.iccid = iccid;

				scaffold.resolve_active_sim(self.info.iccid, self.info.imsi);

				if (cb)
					cb(null);
			};

			// same vendor-varying ICCID chain as the init step
			let cmds = [ 'AT+QCCID', 'AT+CCID', 'AT+ICCID' ];
			let tryi;

			tryi = (i) => {
				if (i >= length(cmds))
					return finish(null);

				q(cmds[i], (r) => {
					let m = r ? match(r, /([0-9]{18,20})/) : null;
					m ? finish(m[1]) : tryi(i + 1);
				});
			};

			tryi(0);
		});
	};

	// admin-triggered soft modem reset (ubus modem_reset — the apply step for
	// `deferred` selection/band settings): AT+CFUN=1,1 full reboot. The modem
	// re-enumerates; hotplug/discovery rebuild it and the daemon kicks every auto
	// interface back up once it re-registers. HW-proven on this backend.
	self.reset = function(cb) {
		if (!self.at)
			return cb({ error: 'unsupported_on_backend' });

		log('warn', 'admin modem reset (AT+CFUN=1,1)');
		self.at.send('AT+CFUN=1,1', () => {
			notify_contexts('lost');
			cb(null, { resetting: true });
		}, { timeout: 8000 });
	};

	self.teardown = function() {
		for (let t in [ retry_timer, reg_timer, reg_poll_timer, settle_timer, at_drain_timer,
		                telemetry_timer, reenum_timer ])
			if (t)
				t.cancel();

		retry_timer = reg_timer = reg_poll_timer = settle_timer = at_drain_timer = null;
		telemetry_timer = reenum_timer = null;
		telem_watch.stop();

		modem_common.close_at(self);
	};

	// stop() installed by modem_common.scaffolding

	return self;
};
