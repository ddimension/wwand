// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — per-modem QMI state machine.
//
// States: ABSENT -> INIT_TRANSPORT -> INIT_SERVICES -> INIT_DATAPATH ->
//   SET_OPMODE -> SIM_UNLOCK -> CONFIGURE_NET -> REGISTERING -> READY.
//   SIM_BLOCKED terminal until config reload; any failure -> backoff retry;
//   device removal -> ABSENT.
//
// opts = { id, device, config, deps: { transport_open, log, on_event },
//          timing } — transport_open is test injection; see TIMING_DEFAULTS.

'use strict';

import * as uloop from 'uloop';
import * as fs from 'fs';
import * as transport_mod from 'wwand.transport';
import * as client_mod from 'wwand.client';
import * as sim from 'wwand.sim';
import * as netlink from 'wwand.netlink';
import * as qmi_backend from 'wwand.qmi_backend';
import * as modem_common from 'wwand.modem_common';
import * as regdetail from 'wwand.regdetail';
import * as telemetry_qmi from 'wwand.telemetry_qmi';
import * as config_check from 'wwand.config_check';
import * as modem_init_qmi from 'wwand.modem_init_qmi';
import * as ctlmod from 'wwand.codec.schema.ctl';
import * as dmsmod from 'wwand.codec.schema.dms';
import * as nasmod from 'wwand.codec.schema.nas';
import * as uimmod from 'wwand.codec.schema.uim';
import * as tmdmod from 'wwand.codec.schema.tmd';
import * as catmod from 'wwand.codec.schema.cat';
import * as pdcmod from 'wwand.codec.schema.pdc';
import * as carrier from 'wwand.carrier_config';
// loc.uc + wms.uc are lazy-loaded (require of a *_lazy shim) only when GPS /
// SMS is actually used, keeping those schemas off the heap on the common path.

const TIMING_DEFAULTS = {
	...modem_common.TIMING_BASE,   // settle/reg_timeout/backoff_min/backoff_max
	sync_retry: 1000,      // delay between CTL sync attempts
	sim_settle: 5000,      // settle after PIN verify without indication (old: sleep 5)
	card_poll: 1000,       // card-status re-poll while initializing
};


// parse_modes lives in qmi_backend.uc; re-exported for daemon/tests.
export const parse_modes = qmi_backend.parse_modes;

// unpack GSM 7-bit packed septets (LSB-first) into bytes. Latin operator names
// map 1:1 to ASCII in the default alphabet, so we emit them directly.
function gsm7_unpack(bytes)
{
	let out = '', acc = 0, bits = 0;

	for (let i = 0; i < length(bytes); i++) {
		acc |= (ord(bytes, i) << bits);
		bits += 8;

		while (bits >= 7) {
			out += chr(acc & 0x7f);
			acc >>= 7;
			bits -= 7;
		}
	}

	return out;
}

// the NAS current-PLMN description is a raw name string with no coding-scheme
// byte: RG50x/RG65x send plain ASCII, older Quectel (EG06) GSM-7-bit pack it.
// Heuristic: a plain-ASCII name is all printable; anything with a high byte
// (>=0x80) OR a control byte (<0x20) is treated as GSM-7-bit packed and
// unpacked, keeping the result only if it decodes to clean printable ASCII.
// (A packed short name can be all-low-byte — e.g. "PLAY" packs to 50 66 30 0b,
// which as raw ASCII reads "Pf0\x0b" — so the trigger must include control
// bytes, not just high bytes; issue #2.)
function decode_operator_name(s)
{
	if (s == null || s == '')
		return s;

	// drop trailing pad some modems append (NUL, CR/LF, spaces) before deciding,
	// so a clean ASCII name with a trailing NUL is not mistaken for packed data
	while (length(s) && (ord(s, length(s) - 1) == 0 || ord(s, length(s) - 1) == 0x0d ||
	                     ord(s, length(s) - 1) == 0x0a || ord(s, length(s) - 1) == 0x20))
		s = substr(s, 0, length(s) - 1);

	if (s == '')
		return s;

	let packed = false;

	for (let i = 0; i < length(s); i++) {
		let c = ord(s, i);
		if (c >= 0x80 || c < 0x20) { packed = true; break; }
	}

	if (!packed)
		return trim(s);

	let u = gsm7_unpack(s);

	while (length(u) && (ord(u, length(u) - 1) == 0 || ord(u, length(u) - 1) == 0x0d))
		u = substr(u, 0, length(u) - 1);

	for (let i = 0; i < length(u); i++)
		if (ord(u, i) < 0x20 || ord(u, i) > 0x7e)
			return s;   // not clean -> keep the original (trimmed) raw string

	return u;
}

// dsd_from_serving / dsd_from_radio moved to modem_common (shared with MBIM).

export function create(opts)
{
	let self = {
		id: opts.id,
		device: opts.device,
		config: opts.config ?? {},
		timing: { ...TIMING_DEFAULTS, ...(opts.timing ?? {}) },
		protocol: 'qmi',   // MBIM/NCM parity (status/datapath read it)

		state: 'ABSENT',
		hub: null,
		ctl: null,
		dms: null,
		nas: null,
		uim: null,
		wda: null,
		wds_cfg: null,     // config-scope wds client (profiles)
		datapath: null,    // { backend, urb_size, mux_devs, ep_id } after INIT_DATAPATH
		at: null,          // AT engine, best-effort
		at_tty: null,
		loc: null,         // LOC client when config.location is set
		location: null,    // last position report
		cells: null,       // last cell location info (telemetry collector)
		active_sim: null,  // matched per-SIM override (config wwand_sim) for the
		                   // inserted card: overrides pincode + apn/auth/pdp
		pin1: null,        // SIM PIN-lock state { state, retries, enabled }
		// what the card last told us about ITSELF, from the UIM indications
		// armed in _install_uim_refresh. Both are diagnostics, not state the
		// machine acts on: a busy card explains failing reads, and sim_note
		// carries the last named card-side event (session closed and why, an
		// internal recovery, an activation that failed).
		sim_busy: false,
		sim_note: null,
		// we asked for low power (option lowpower) and the radio is off. The
		// deregistration that follows is expected, and an ifup wakes it.
		lowpower_parked: false,
		active_slot: null,  // which physical slot holds the card in use (slot status)
		cat: null,          // toolkit client, alive only while cat_mode is applied
		pdc: null,          // carrier-config client, when the modem has PDC
		tmd: null,          // thermal-mitigation client, when the modem has TMD
		thermal: null,      // { devices: [{id,label,max,level}], mitigated, level }
		// Lifecycle generation. Bumped by teardown, so any callback still in
		// flight can tell it belongs to a previous incarnation of this modem and
		// stop, rather than writing into state that was rebuilt underneath it or
		// issuing requests on a destroyed client. The retry path REUSES this
		// object, which is what makes the distinction necessary.
		_gen: 0,

		services: {},      // service id (string) -> { major, minor }
		info: {},          // model, revision, imei, ...
		reg: {},           // registration snapshot
		reg_detail: null,  // why (not) registered: reject cause, limited service
		config_warnings: null,  // runtime "modem doesn't match config/spec" checks
		signal: {},        // last signal info

		counters: null,    // shared with the recovery instance below
		contexts: [],
	};

	let deps = opts.deps ?? {};
	let transport_open = deps.transport_open ?? transport_mod.open;
	let log = deps.log ?? ((level, msg) => warn(sprintf('%s: modem %s: %s\n', level, self.id, msg)));

	let rec = modem_common.make_recovery(self, opts, log, 'qmi');

	// shared one-shot timer holder; teardown cancels whatever is pending.
	let tm = { retry: null, reg: null, settle: null, at_drain: null, probe: null };

	// protocol-neutral scaffolding (sets set_state/attach_context/… on self)
	let scaffold = modem_common.scaffolding(self, { deps: deps, log: log, rec: rec });
	let emit = scaffold.emit;
	let notify_contexts = scaffold.notify_contexts;
	let enter_ready = scaffold.enter_ready;

	// hooks shared by all clients: feed the recovery error counter.
	let client_hooks = {
		on_error: (client, kind, msg) => {
			let act = rec.on_proto_error();
			// a SYNC-wedged modem never reaches the attempt ladder, so escalate
			// the proto-error path itself: a hardware reset first, reboot only if
			// that fails to clear the wedge (see recovery.on_proto_error).
			if (act == 'usb_repower')
				rec.usb_repower();
			else if (act == 'reboot')
				rec.reboot('qmi error limit reached');

			log('debug', sprintf('qmi error (%s) svc %d %s, counter %d',
				kind, client.service, msg ?? '?', self.counters.proto_errors));
		},
		on_success: (client) => {
			rec.on_proto_success();
		},
		// Weaker than on_success and asked a different question: did the modem
		// answer QMI at all? A service error answers it just as well as a
		// result-0 response, and arming the hardware ladder on success alone
		// would strand a modem that talks to us but refuses what we ask.
		on_answer: (client) => rec.note_answer(),
	};

	self.alloc = function(schema, cb) {
		self.ctl.request('ALLOCATE_CID', { service: schema.service }, (err, data) => {
			if (err || !data?.allocation) {
				// ClientIdsExhausted (CTL error 5): the modem's client table
				// is full. Old stacks keep a tiny table (~5 slots) and a failed
				// attempt can leak a slot, so plain retries only burn attempts
				// — reset the modem stack instead: AT+CFUN=1,1 re-initializes
				// the protocol stack and the table (HW-verified on the Huawei
				// E1820, 2026-08-31: the modem re-enumerates and comes back
				// with a fresh table). Fire-and-forget; the retry runs anyway.
				if (err?.code == 5)
					self._reset_stack_at();

				return cb(err ?? { error: 'proto', detail: 'no allocation tlv' }, null);
			}

			log('debug', sprintf('allocated cid %d for service %d',
				data.allocation.cid, schema.service));
			cb(null, client_mod.create(self.hub, schema, data.allocation.cid, client_hooks));
		});
	};

	self.release = function(client, cb) {
		if (!client)
			return cb ? cb(null) : null;

		client.destroy();

		if (!self.hub || self.hub.closed)
			return cb ? cb(null) : null;

		self.ctl.request('RELEASE_CID',
			{ release: { service: client.service, cid: client.cid } },
			(err) => cb ? cb(err) : null, { timeout: 3000 });
	};

	// backend-neutral NAS accessor. cb(nas|null).
	self.with_nas = function(cb) {
		cb(self.nas ?? null);
	};

	// backend-neutral WMS (SMS) accessor. cb(wms|null).
	self.with_wms = function(cb) {
		cb(self.wms ?? null);
	};

	// lazily allocate the WMS (SMS) client on first use — the wms schema is
	// require()d (via the *_lazy shim) so it stays off the heap until SMS is
	// used. `_wms_tried` gates the one-shot (self.wms null = unavailable or client).
	self._ensure_wms = function(cb) {
		if (self._wms_tried)
			return cb();

		self._wms_tried = true;

		let wmsmod = require('wwand.codec.schema.wms_lazy').s;

		if (!self.services[sprintf('%d', wmsmod.default.service)]) {
			self.wms = null;
			return cb();
		}

		self.alloc(wmsmod.default, (ew, wms) => {
			if (ew)
				log('warn', 'wms allocation failed, SMS unavailable');
			self.wms = ew ? null : wms;
			cb();
		});
	};

	// --- step chain --------------------------------------------------------

	let dp = opts.datapath ?? {};
	let at_opts = opts.at ?? {};

	// one-shot modem stack reset over the AT port (ClientIdsExhausted). Runs
	// at alloc time, before the init chain's own open_at — so the reset goes
	// through modem_common.reset_stack_at, which opens a RAW transport and
	// writes AT+CFUN=1,1 without any of the daemon's AT engines (they may not
	// be opened yet, and the failure path tears the modem object down right
	// after — the reset must already be on the wire by then).
	self._reset_stack_at = function() {
		if (self._reset_stack_sent)
			return;

		self._reset_stack_sent = true;
		modem_common.reset_stack_at(self, at_opts, log);
	};


	let fail = modem_common.make_fail(self, {
		log: log, timing: self.timing, emit: emit,
		set_retry_timer: (t) => tm.retry = t,
		rec: rec,
	});

	// QMI bring-up chain (modem_init_qmi.uc); chain.begin() is the start() entry.
	let chain = modem_init_qmi.install(self, {
		log: log, emit: emit, notify_contexts: notify_contexts,
		sim_block: scaffold.sim_block,
		fail: fail, dp: dp, at_opts: at_opts, tm: tm,
	});

	// record a failed connection cycle and run the resulting ladder action; also
	// called by the daemon on context-activation failure. QMI-side rungs run
	// against the live clients, so this happens before teardown.
	self.note_connect_failure = function(done) {
		done = done ?? ((action) => null);

		let action = rec.on_attempt();

		switch (action) {
		case 'reboot':
			rec.reboot('connection attempt limit reached');
			return done(action);

		case 'usb_repower':
			rec.usb_repower();
			return done(action);

		case 'opmode_cycle':
			if (!self.dms)
				return done(action);

			log('warn', 'recovery: cycling operating mode');
			qmi_backend.set_opmode(self.dms, 'low_power', () => {
				tm.settle = uloop.timer(self.timing.settle, () => {
					qmi_backend.set_opmode(self.dms, 'online', () => {
						tm.settle = uloop.timer(self.timing.settle, () => done(action));
					});
				});
			});
			return;

		case 'modem_reset':
			if (!self.dms)
				return done(action);

			log('warn', 'recovery: resetting modem');
			qmi_backend.set_opmode(self.dms, 'offline', () => {
				qmi_backend.set_opmode(self.dms, 'reset', () => done(action));
			});
			return;

		default:
			return done(action);
		}
	};


	// admin-triggered soft modem reset (ubus modem_reset — the apply step for
	// `deferred` selection/band settings): DMS offline -> reset. The modem
	// re-enumerates; discovery rebuilds it and re-kicks the auto interfaces.
	self.reset = function(cb) {
		if (!self.dms)
			return cb({ error: 'unsupported_on_backend' });

		log('warn', 'admin modem reset (DMS offline -> reset)');
		qmi_backend.set_opmode(self.dms, 'offline', () => {
			qmi_backend.set_opmode(self.dms, 'reset', () => {
				notify_contexts('lost');
				cb(null, { resetting: true });
			});
		});
	};

	// admin-triggered network re-attach (ubus modem_reattach): a QMI RF bounce
	// (DMS low_power -> online) makes the modem deregister and re-register, so
	// automatic selection re-scans a network it's camped on. Unlike self.reset it
	// does NOT reboot the modem, and unlike a PDP teardown it does not touch the
	// context config — the daemon re-activates the same context on re-registration
	// (data blips during the brief RF-off window). QMI has no pure COPS-2 detach,
	// so this opmode bounce is the native equivalent.
	self.reattach = function(cb) {
		cb = cb ?? (() => null);

		if (!self.dms)
			return cb({ error: 'unsupported_on_backend' });

		log('notice', 'network reattach (DMS low_power -> online)');
		qmi_backend.set_opmode(self.dms, 'low_power', () => {
			uloop.timer(self.timing.settle, () => {
				qmi_backend.set_opmode(self.dms, 'online', (err) => {
					cb(err ? { error: 'qmi', detail: err } : null,
						{ ok: true, action: 'reattach', via: 'qmi' });
				});
			});
		});
	};

	// switch_protocol / protocol_switch_supported come from
	// modem_common.scaffolding (shared across all three backends)



	self._read_info = function(next) {
		qmi_backend.read_info(self.dms, (info) => {
			for (let k, v in info)
				self.info[k] = v;

			// …/device is the USB *interface* dir (1-1:1.3); one level up is
			// the USB device (1-1) carrying the descriptor strings (two would
			// be the hub — "xHCI Host Controller")
			let base = '/sys/class/usbmisc/' + substr(self.device, 5) + '/device/..';
			let sf = (f) => trim(fs.readfile(base + '/' + f) ?? '');

			let vid = sf('idVendor'), pid = sf('idProduct'), prod = sf('product');

			if (length(vid))
				self.info.usb = sprintf('%s:%s%s', vid, pid,
					length(prod) ? ' ' + prod : '');

			// some firmwares return junk from DMS GET_MODEL (old Huawei
			// sticks literally answer "0") — fall back to the USB device
			// descriptor strings so status/LuCI show a usable name; once the
			// AT channel opens, ATI (which such sticks answer properly)
			// upgrades this further (step_at -> _ati_info).
			let bogus = (s) => (s == null || trim(s) == '' || trim(s) == '0');

			if (bogus(self.info.model)) {
				self._model_generic = true;

				if (length(prod))
					self.info.model = prod;

				if (bogus(self.info.manufacturer)) {
					let manu = sf('manufacturer');

					if (length(manu))
						self.info.manufacturer = manu;
				}
			}

			let c = info.capabilities;

			if (c)
				log('info', sprintf('capabilities: max tx %d rx %d kbps, radio ifs [%s]',
					c.max_tx_rate, c.max_rx_rate, join(' ', c.radio_ifs ?? [])));

			log('notice', sprintf('%s %s, revision %s, imei %s',
				self.info.manufacturer ?? '?', self.info.model,
				self.info.revision, self.info.imei));

			// stable-identity gate: halt before SIM/context if the pinned IMEI
			// does not match this physical modem.
			if (!modem_common.check_identity(self, { emit: emit, log: log }))
				return;

			next();
		});
	};








	// shared wwand_sim matcher (modem_common — parity across all backends)
	let match_sim_override = (iccid, imsi) =>
		modem_common.match_sim_override(self.config?.sims, iccid, imsi);






	// live-config validation (config_check.uc); kept as a method for the init
	// chain + ubus revalidation.
	self.validate_config = function(cb) {
		config_check.validate(self, log, cb);
	};



	// the card changed in place (eSIM profile switch via SIM hot-reset, or a UIM
	// REFRESH): re-read identity, RE-RESOLVE the per-SIM override (the old card's
	// wwand_sim must not stick) and re-program the LTE attach profile — without
	// tearing the modem down. cb(changed) optional.
	self.reapply_sim = function(cb) {
		sim.read_identity(self, (id) => {
			let changed = (id.iccid != self.info.iccid || id.imsi != self.info.imsi);

			self.info.imsi = id.imsi ?? self.info.imsi;
			self.info.iccid = id.iccid ?? self.info.iccid;
			self.info.msisdn = id.msisdn ?? self.info.msisdn;

			scaffold.resolve_active_sim(id.iccid, id.imsi);

			let ctx = self.contexts[0];

			if (!ctx?.ensure_attach_profile || !self.dms)
				return cb ? cb(changed) : null;

			ctx.ensure_attach_profile(1, (ch) => {
				if (!ch)
					return cb ? cb(changed) : null;

				log('notice', 'attach profile changed after sim reapply, cycling radio to re-attach');
				qmi_backend.set_opmode(self.dms, 'low_power', () => {
					tm.settle = uloop.timer(self.timing.settle, () => {
						qmi_backend.set_opmode(self.dms, 'online', () => {
							if (cb)
								cb(changed);
						});
					});
				});
			});
		});
	};

	// register for SIM/eUICC refresh notifications so a network-/LPA-initiated
	// refresh (eSIM profile switch, SIM OTA update) makes wwand re-read identity.
	// On some modems (e.g. RG650E) UIM logical-channel ops are unsupported and the
	// register is refused — best-effort, no_recovery.
	self._install_uim_refresh = function() {
		if (!self.uim || self._uim_refresh_armed)
			return;
		self._uim_refresh_armed = true;

		let session = () => ({
			session_type: uimmod.SESSION_TYPE_PRIMARY_GW_PROVISIONING, aid: '',
		});

		self.uim.on('REFRESH_IND', (data) => {
			let stage = data?.event?.stage;
			let enf = data?.enforcement;

			// What the card is prepared to interrupt to get this through. Worth
			// logging because DATA_CALL means our WAN is about to be pulled and
			// nothing else would explain it.
			let forced = (enf != null && (enf & uimmod.REFRESH_ENFORCE_DATA_CALL))
				? ' (will interrupt an active data call)' : '';

			log('info', sprintf('sim refresh (stage %d)%s', stage ?? -1, forced));

			// WAIT_FOR_OK: the card is ASKING and is now waiting for an answer.
			// wwand does not ASK to be asked (see the registration below), but a
			// card can reach this stage for its own reasons, and then the only
			// safe thing is to answer — a card waiting on a terminal response is
			// a card that can stall.
			if (stage == uimmod.REFRESH_STAGE_WAIT_FOR_OK) {
				self.uim.request('REFRESH_OK', {
					session: session(), ok: { ok_to_refresh: 1 },
				}, (e) => {
					if (e)
						log('warn', sprintf('refresh-ok refused (%s) — the card may stall until its own timeout',
							e.error ?? '?'));
				}, { no_recovery: true });

				return;
			}

			// full reapply only once the refresh completed successfully
			if (stage == uimmod.REFRESH_STAGE_END_SUCCESS)
				self.reapply_sim();
		});

		// Diagnostics. Each of these was previously invisible: the card would
		// simply stop answering, and the ladder would count protocol errors at a
		// modem that was telling us exactly what was wrong.
		self.uim.on('SESSION_CLOSED_IND', (data) => {
			let cause = data?.cause;
			let name = uimmod.SESSION_CLOSE_CAUSES[sprintf('%d', cause ?? 0)]
				?? sprintf('unknown (%d)', cause ?? -1);
			let file = (data?.file_id != null)
				? sprintf(' (file %04X)', data.file_id) : '';

			log('warn', sprintf('uim session closed: %s%s', name, file));
			self.sim_note = sprintf('session closed: %s', name);
			emit('sim_session_closed', { cause: cause, cause_text: name,
			                             file_id: data?.file_id ?? null });
		});

		self.uim.on('SIM_BUSY_STATUS_IND', (data) => {
			// One byte per slot; report the one we are actually using.
			// `active_slot` comes from the slot status, which is the only thing
			// that knows — the configured `sim_slot` is often unset and is never
			// updated by a runtime slot switch, so indexing with it reported
			// another slot's card, or none.
			//
			// And when NOTHING knows yet, do not guess. A single-entry
			// indication is unambiguous whatever the slot is called; a
			// multi-entry one without a known active slot is dropped, because
			// naming slot 1 there is a coin toss that reaches the status page
			// as a fact.
			let list = data?.busy ?? [];
			let slot = +(self.active_slot ?? self.config?.sim_slot ?? 0) || 0;

			if (!slot && length(list) != 1)
				return;

			// (a slot we cannot attribute is dropped, not guessed — see above)

			let busy = (length(list) == 1 && !slot) ? list[0] : list[slot - 1];

			if (busy == null || !!self.sim_busy == !!busy)
				return;

			self.sim_busy = !!busy;
			log(busy ? 'warn' : 'info',
				sprintf('sim card %s', busy ? 'busy (reads will fail until it clears)' : 'no longer busy'));
			emit('sim_busy', { busy: !!busy });
		});

		self.uim.on('RECOVERY_IND', (data) => {
			// the card recovered internally: sessions, logical channels and
			// anything read from it are stale. Re-read rather than trust.
			log('warn', sprintf('sim card recovered internally (slot %d) — re-reading identity',
				data?.slot ?? -1));
			self.sim_note = 'card recovered';
			emit('sim_recovery', { slot: data?.slot ?? null });
			self.reapply_sim();
		});

		self.uim.on('CARD_ACTIVATION_STATUS_IND', (data) => {
			let st = data?.status;
			let name = uimmod.CARD_ACTIVATION_STATES[sprintf('%d', st ?? 0)]
				?? sprintf('unknown (%d)', st ?? -1);

			// the window where a card is present but not yet usable, which
			// otherwise reads as a broken SIM
			log(st == uimmod.CARD_ACTIVATION_END_FAILURE ? 'warn' : 'info',
				sprintf('card activation %s (slot %d)', name, data?.slot ?? -1));
			self.sim_note = (st == uimmod.CARD_ACTIVATION_END_SUCCESS)
				? null : sprintf('card activation %s', name);
			emit('sim_activation', { slot: data?.slot ?? null,
			                         status: st, status_text: name });
		});

		// Long-APDU reassembly: installed here, with the other UIM handlers, so
		// a response chunk cannot arrive before something is listening for it.
		sim.install_apdu_reassembly(self);

		// Arm the mask. Best-effort as a whole: a modem that refuses the extra
		// bits gets one more try with card-status alone, because losing the
		// PIN-readiness indication to gain diagnostics would be a bad trade.
		//
		// The retry needs a guard, and it is the same lesson as the CAT release:
		// a teardown while this request is pending destroys the client, which
		// reports `cancelled` to this callback SYNCHRONOUSLY. Read as a refusal,
		// that fired the fallback down a client mid-destruction — a send that
		// escapes teardown, and a timer that outlives the pending table it was
		// supposed to be cancelled with. `cancelled` is teardown, not "no".
		let gen = self._gen;
		let uim = self.uim;

		uim.request('REGISTER_EVENTS', { mask: uimmod.EVENTS_WANTED }, (e) => {
			if (!e)
				return;

			// not a refusal: the modem never got a chance to answer
			if (e.error == 'cancelled' || self._gen != gen || self.uim != uim)
				return;

			log('debug', 'uim event registration refused for the full mask, falling back to card status');
			uim.request('REGISTER_EVENTS', { mask: uimmod.EVENT_CARD_STATUS },
				(e2) => null, { no_recovery: true });
		}, { no_recovery: true });

		self.uim.request('REFRESH_REGISTER_ALL', {
			session:  session(),
			register: { register_flag: 1 },
			// vote_for_init is DELIBERATELY not sent. Voting asks the card to
			// consult us before it refreshes, which sounds strictly better —
			// until the reply does not happen. Then the card waits out its own
			// timeout instead of refreshing immediately, and every way the reply
			// can be lost (the request failing, the client being torn down and
			// rebuilt mid-refresh) turns a brief session interruption into a
			// stall. Not voting is the status quo: the card refreshes at once
			// and may pull the session, which is worse in one narrow case and
			// better in every failure case. The TLV stays modelled, and the
			// WAIT_FOR_OK handler above stays, so a card that asks anyway still
			// gets an answer.
		}, (e) => {
			if (e)
				log('debug', 'uim refresh register failed (sim-refresh notifications unavailable)');
		}, { no_recovery: true });
	};

	// DMS event report: observe + log an EXTERNAL operating-mode / PIN change
	// (airplane toggled via AT / another tool / a hardware switch) wwand did not
	// initiate. The state machine still reacts via its own serving-system path.
	self._install_dms_handlers = function() {
		self.dms.on('EVENT_REPORT_IND', (data) => {
			if (data?.operating_mode != null && data.operating_mode != self._dms_opmode) {
				let prev = self._dms_opmode;
				self._dms_opmode = data.operating_mode;
				// skip the very first report (baseline, not a change)
				if (prev != null)
					log('notice', sprintf('operating mode changed externally: %s',
						dmsmod.OPMODE_NAMES[sprintf('%d', data.operating_mode)] ??
						sprintf('mode %d', data.operating_mode)));
			}
			if (data?.pin1_status?.current_status != null)
				self._dms_pin1 = data.pin1_status;
		});

		self.dms.request('SET_EVENT_REPORT',
			{ operating_mode: 1, pin_state: 1, uim_state: 1 }, (e) => {
				if (e)
					log('debug', 'dms set-event-report failed (external opmode watch unavailable)');
			}, { no_recovery: true });
	};

	// Carrier configuration (MBN) over PDC. Read-only at init: bring the client
	// up and subscribe, so `modem_carrier_config` can answer without a round of
	// setup on every call. Nothing is selected here — switching is an explicit
	// operator action, because it only takes effect after a modem reset.
	//
	// This is the protocol-native form of the Quectel-only `AT+QMBNCFG` quirk,
	// which stays where it is: that one asks the modem to AUTO-select on every
	// boot, which is a different thing from reporting what it chose, and it is
	// the only lever on firmware without PDC.
	self._install_pdc = function(cb) {
		cb = cb ?? (() => null);

		if (!self.services[sprintf('%d', pdcmod.default.service)])
			return cb();

		let gen = self._gen;

		self.alloc(pdcmod.default, (err, pdc) => {
			if (err || !pdc)
				return cb();

			if (self._gen != gen)
				return self.release(pdc);

			self.pdc = pdc;
			carrier.install(self);

			// without this the modem accepts every PDC request and indicates
			// nothing, which reads exactly like a modem that has no PDC
			pdc.request('REGISTER', { enable: 1 }, (rerr) => {
				if (rerr)
					log('debug', 'pdc registration refused — carrier config unavailable');

				cb();
			}, { no_recovery: true });
		});
	};

	// SIM toolkit routing. Only ever runs when `option cat_mode` says so — the
	// default is to leave the modem exactly as the vendor configured it, because
	// changing toolkit behaviour unasked can break a working deployment in ways
	// that show up on one operator's network and nowhere else.
	//
	// What it is FOR: a headless CPE has no UI. In a phone-shaped mode the modem
	// advertises a terminal profile promising to render SETUP MENU and DISPLAY
	// TEXT, an operator OTA campaign takes it at its word, and the card then
	// waits on a response nothing here will ever send. `cat_mode 'disabled'`
	// stops routing toolkit to a control point at all.
	self._apply_cat_mode = function(cb) {
		cb = cb ?? (() => null);

		let want = catmod.MODES[self.config?.cat_mode ?? ''];

		if (want == null || !self.services[sprintf('%d', catmod.default.service)])
			return cb();

		// This one IS on the critical path — it is one or two requests, and the
		// toolkit configuration should be settled before the card is used. That
		// makes teardown safety the whole problem: a teardown mid-request
		// destroys the client, the callback fires with `cancelled`, and without
		// a guard it would release a CID through a destroyed CTL and then
		// resume init on a modem that no longer exists.
		//
		// `self.cat` exists so teardown destroys the client with the others;
		// `gen` is what stops the continuation.
		let gen = self._gen;

		// every exit from here goes through this: it continues init exactly
		// once, and never after a teardown
		let finish = (client) => {
			if (self._gen != gen) {
				// teardown already destroyed it and CTL with it; releasing the
				// CID is not possible and not ours to do any more
				self.cat = null;
				return;
			}

			self.cat = null;

			// The generation has to be re-checked INSIDE the release callback,
			// not only before starting it. RELEASE_CID is asynchronous, and a
			// teardown that begins while it is in flight destroys CTL first —
			// which reports `cancelled` to this very callback, synchronously.
			// Continuing there resumed the old init chain into _read_info()
			// while teardown was still tearing down, and could schedule work
			// after teardown's timer-cancellation pass, overlapping the retry.
			// Checking once at the top of finish() is not enough: the
			// continuation escapes behind it.
			if (client)
				return self.release(client, () => {
					if (self._gen == gen)
						cb();
				});

			cb();
		};

		self.alloc(catmod.default, (err, cat) => {
			if (err || !cat)
				return finish(null);

			if (self._gen != gen) {
				self.release(cat);
				return;
			}

			self.cat = cat;

			// read before write: the tree's rule everywhere else, and here it
			// also avoids re-announcing a terminal profile to a card mid-session
			cat.request('GET_CONFIGURATION', {}, (ge, gd) => {
				if (self._gen != gen)
					return finish(null);

				let have = ge ? null : gd?.mode;

				// release(), not destroy(): destroy() drops our local client and
				// leaves the CID allocated ON THE MODEM. This runs once per
				// init, and an init can repeat — a modem has a finite CID pool.
				if (have == want) {
					log('debug', sprintf('sim toolkit already %s', catmod.mode_name(want)));
					return finish(cat);
				}

				cat.request('SET_CONFIGURATION', { mode: want }, (se) => {
					if (self._gen != gen)
						return finish(null);

					if (se)
						log('warn', sprintf('sim toolkit: cannot set %s (%s)',
							catmod.mode_name(want), se.error ?? '?'));
					else
						log('notice', sprintf('sim toolkit routing: %s -> %s',
							have != null ? catmod.mode_name(have) : 'unknown',
							catmod.mode_name(want)));

					finish(cat);
				}, { no_recovery: true });
			}, { no_recovery: true });
		});
	};

	// TMD — the modem's own thermal mitigation. Answers a question nothing else
	// here can: throughput that collapsed while the signal bars stayed put is
	// usually the modem cutting its own transmit power, and until now that was
	// indistinguishable from a bad cell. Read-only by design (see the schema:
	// SET_MITIGATION_LEVEL is deliberately not modelled — the modem's thermal
	// management is the authority, and a host that overrides it can cook the
	// hardware). Entirely best-effort: cb() runs whatever happens.
	self._install_thermal = function(cb) {
		cb = cb ?? (() => null);

		if (!self.services[sprintf('%d', tmdmod.default.service)])
			return cb();

		// NOT on the critical path. A modem has ~30 mitigation devices (28 on
		// the RG650E) and the walk below is one request pair each; at the
		// default 10 s timeout a modem that goes quiet part-way would hold
		// bring-up for over nine minutes. Nothing about the connection depends
		// on knowing the thermal state, so init continues immediately and the
		// walk fills `self.thermal` in the background.
		cb();

		// Generation guard: teardown bumps `_gen`, so a callback that arrives
		// after a teardown — or after a retry has rebuilt this modem — finds a
		// stale generation and stops instead of dereferencing a nulled
		// `self.thermal` or issuing requests on a dead client.
		let gen = self._gen;
		let alive = () => (self._gen == gen && self.tmd != null && self.thermal != null);

		self.alloc(tmdmod.default, (err, tmd) => {
			if (err || !tmd)
				return;

			if (self._gen != gen)
				return self.release(tmd);   // torn down while allocating

			self.tmd = tmd;

			tmd.on('MITIGATION_LEVEL_REPORT_IND', (data) => {
				let id = data?.device?.dev_id;
				let lvl = data?.level;

				if (id == null || lvl == null || !alive())
					return;

				for (let d in (self.thermal?.devices ?? []))
					if (d.id == id) {
						if (d.level == lvl)
							return;   // re-report of a level we already hold

						d.level = lvl;
					}

				let was = self.thermal?.mitigated;

				self._refresh_thermal();

				// Per-device changes go to debug. A modem has ~30 mitigation
				// devices (28 on the RG650E), several of them 0..255 fine-grained
				// backoff counters, and logging every step of those at notice
				// would drown the log the moment the box gets warm.
				log('debug', sprintf('thermal: %s level %d', id, lvl));

				// What is worth saying out loud is the TRANSITION: this modem
				// started, or stopped, holding itself back at all.
				// only an RF-class transition is worth a line; an environmental
				// device crossing zero is not news
				if (!!was != !!self.thermal.mitigated && tmdmod.is_rf_device(id))
					log(self.thermal.mitigated ? 'warn' : 'notice',
						self.thermal.mitigated
							? sprintf('thermal mitigation active: %s at level %d — the modem is throttling itself',
								tmdmod.device_label(id), lvl)
							: 'thermal mitigation cleared');
			});

			tmd.request('GET_MITIGATION_DEVICE_LIST', {}, (le, ld) => {
				// Teardown destroys this client, which reports `cancelled` to
				// this callback SYNCHRONOUSLY — and by then CTL is gone too, so
				// a release() from here could never complete. Check first.
				if (self._gen != gen || self.tmd == null)
					return;

				let list = le ? [] : (ld?.devices ?? []);

				if (!length(list)) {
					// the service exists but names no devices — nothing to
					// watch. Release rather than drop: the CID is allocated on
					// the modem until we hand it back.
					//
					// And do NOT call cb(): init was already continued at the
					// top of this function. Calling it here advanced the state
					// machine a SECOND time, on an empty list or a list timeout
					// alike — the hazard of moving work off the critical path
					// while leaving its continuation behind.
					let dead = self.tmd;
					self.tmd = null;
					return self.release(dead);
				}

				self.thermal = {
					devices: map(list, (d) => ({
						id: d.dev_id, label: tmdmod.device_label(d.dev_id),
						max: d.max_level, level: null,
					})),
					mitigated: false,
				};

				log('info', sprintf('thermal mitigation devices: %s',
					join(', ', map(self.thermal.devices,
						(d) => sprintf('%s (0..%d)', d.id, d.max)))));

				// initial level per device, then subscribe. Sequential rather
				// than parallel: these are cheap and a modem that dislikes one
				// of them should not lose the rest.
				//
				// Bounded as a whole, not just per request: a modem that stops
				// answering half-way would otherwise spend one timeout per
				// remaining device. The first timeout ends the walk — whatever
				// was already read stays, and the subscriptions already placed
				// keep working.
				let i = 0, step;

				step = () => {
					if (!alive())
						return;   // torn down mid-walk

					if (i >= length(self.thermal.devices))
						return self._refresh_thermal();

					let d = self.thermal.devices[i++];

					tmd.request('GET_MITIGATION_LEVEL',
						{ device: { dev_id: d.id } }, (ge, gd) => {
							if (!alive())
								return;

							if (ge?.error == 'timeout') {
								log('debug', 'thermal: modem stopped answering, ending the device walk');
								return self._refresh_thermal();
							}

							if (!ge && gd?.current != null)
								d.level = gd.current;

							tmd.request('REGISTER_NOTIFICATION',
								{ device: { dev_id: d.id } },
								(re) => step(), { no_recovery: true });
						}, { no_recovery: true });
				};

				step();
			}, { no_recovery: true });
		});
	};

	// roll the per-device levels up into the one fact the rest of the system
	// cares about: is this modem currently holding itself back at all?
	self._refresh_thermal = function() {
		if (!self.thermal || !length(self.thermal.devices ?? []))
			return;

		let worst = 0;

		// Only RF-class devices set the headline. An environmental one — the
		// modem noting that it is cold, or a battery/charge limit — uses the
		// same interface but costs no throughput, and HW-observed on the NR7101
		// `cpr_cold` sits at level 1 permanently on a healthy modem.
		for (let d in self.thermal.devices)
			if ((d.level ?? 0) > worst && tmdmod.is_rf_device(d.id))
				worst = d.level;

		self.thermal.mitigated = worst > 0;
		self.thermal.level = worst;

		// What status() reports: the roll-up plus ONLY the devices actually
		// holding back. The full list is init-log material — a status page that
		// polls does not want thirty rows of "level 0" on every request, and the
		// interesting case is always the short list.
		// ...but `active` lists EVERYTHING holding back, each saying which class
		// it is in. The environmental ones are still worth seeing — "this modem
		// is cold" explains a slow start on a winter rooftop — they just must
		// not raise an alarm.
		self.thermal.active = map(
			filter(self.thermal.devices, (d) => (d.level ?? 0) > 0),
			(d) => ({ ...d, rf: tmdmod.is_rf_device(d.id) }));
	};

	self._install_nas_handlers = function() {
		self.nas.on('SERVING_SYSTEM_IND', (data) => self._update_serving(data));
		self.nas.on('SIGNAL_INFO_IND', (data) => {
			self.signal = data;
		});
		// Network Time / NITZ (operator-pushed UTC clock): store for status and
		// hand epoch+tz to the daemon, which decides whether to apply it (only
		// when the system clock is clearly unset). tz offset is signed 15-min units.
		self.nas.on('NETWORK_TIME_IND', (data) => {
			let epoch = modem_common.nitz_epoch(data?.universal_time);
			if (epoch == null)
				return;
			let tz_min = (data.timezone_offset != null) ? data.timezone_offset * 15 : null;
			self.network_time = { epoch: epoch, tz_offset_min: tz_min, dst: data.dst_adjustment };
			log('info', sprintf('network time (NITZ): %d utc, tz %s',
				epoch, tz_min != null ? sprintf('%+d min', tz_min) : '?'));
			if (deps.set_clock)
				deps.set_clock(epoch, tz_min);
		});
		// NAS event report — live RF band changes (band-steer / CA reshuffle)
		// pushed instead of waiting for the next cell poll. Stored on self.rf_bands.
		self.nas.on('EVENT_REPORT_IND', (data) => {
			if (data?.rf_band_info == null)
				return;
			let bands = map(data.rf_band_info, (b) => b.band);
			let key = join(',', bands);
			if (key != self._rf_band_key) {
				self._rf_band_key = key;
				// decode the QmiNasActiveBand values ("LTE B20" instead of 145)
				let names = join(', ', map(bands, nasmod.active_band_name));
				log('info', sprintf('rf band change: %s', length(names) ? names : 'none'));
			}
			self.rf_bands = map(data.rf_band_info, (b) =>
				({ ...b, name: nasmod.active_band_name(b.band) }));
		});
	};

	// enable the NAS event report (RF band + reject reason). Separate from
	// REGISTER_INDICATIONS; best-effort — some modems reject it.
	self._arm_nas_event_report = function() {
		if (!self.nas || self._nas_evt_armed)
			return;
		self._nas_evt_armed = true;
		self.nas.request('SET_EVENT_REPORT', { rf_band_info: 1, reject_reason: 1 }, (e) => {
			if (e)
				log('debug', 'nas set-event-report failed (rf-band push unavailable)');
		}, { no_recovery: true });
	};

	// registration-detail collector (regdetail.uc); kept as a method for
	// daemon/status callers.
	// Backend operation `set_opmode` (docs/backend-interface.md): online /
	// low_power / offline / reset. Documented as part of the contract and never
	// actually exposed as a modem method — the recovery ladder reached past it
	// straight to qmi_backend. `option lowpower` is the first caller that has to
	// be protocol-neutral, so here it is.
	self.set_opmode = function(mode, cb) {
		cb = cb ?? (() => null);

		if (!self.dms)
			return cb({ error: 'unsupported', detail: 'no dms client' });

		qmi_backend.set_opmode(self.dms, mode, (err) => {
			// remember that WE parked it: the registration that follows is a
			// consequence, and the supervisor above must not treat it as a fault
			if (!err)
				self.lowpower_parked = (mode == 'low_power');

			cb(err ?? null);
		});
	};

	self.collect_regdetail = function(cb) {
		regdetail.collect(self, log, cb);
	};

	self._update_serving = function(data) {
		let ss = data.serving_system;

		if (!ss)
			return;

		if (data.current_plmn?.description != null)
			data.current_plmn.description = decode_operator_name(data.current_plmn.description);

		// an incremental SERVING_SYSTEM_IND (e.g. on cell reselection) may omit the
		// OPTIONAL Current-PLMN / roaming TLVs — carry the last-known values forward
		// instead of wiping them, so operator name + roaming don't blink out.
		let prev = self.reg ?? {};

		self.reg = {
			registration: ss.registration,
			radio_ifs: ss.radio_ifs,
			roaming: (data.roaming != null) ? (data.roaming == 0) : prev.roaming,
			plmn: data.current_plmn ?? prev.plmn,
		};

		emit('serving_system', self.reg);

		// serving-system update while connected: the network may have re-issued IP
		// config (prefix/DNS/MTU). Nudge contexts to re-check in place (they diff +
		// rate-limit; no-op if unchanged).
		if (ss.registration == nasmod.REG_REGISTERED && self.state == 'READY')
			notify_contexts('serving_change');

		if (ss.registration == nasmod.REG_REGISTERED) {
			if (self.state == 'REGISTERING') {
				if (tm.reg) {
					tm.reg.cancel();
					tm.reg = null;
				}

				self.counters.attempts = 0;
				self.reg_detail = null;   // registered: clear any stale reject info
				log('notice', sprintf('registered: plmn %J, roaming %J, radio [%s]',
					self.reg.plmn ? sprintf('%d/%02d (%s)', self.reg.plmn.mcc, self.reg.plmn.mnc,
						trim(self.reg.plmn.description ?? '')) : null,
					self.reg.roaming, join(' ', self.reg.radio_ifs ?? [])));
				enter_ready(() => {
					self._start_loc();
					self._start_telemetry();
				});
			}
		}
		else if (self.state == 'READY') {
			// PARKED: we asked for low power ourselves, so losing registration
			// is the expected consequence, not a fault. Re-entering the
			// registration chain here would fight the parking, fail, and walk
			// the recovery ladder into an op-mode cycle and a power-cycle — for
			// a modem doing exactly what it was told.
			if (self.lowpower_parked) {
				log('info', 'registration released (radio parked)');
				emit('deregistered', self.reg);
				notify_contexts('suspend', self.reg);
				return;
			}

			log('warn', sprintf('registration lost (%d)', ss.registration));
			emit('deregistered', self.reg);
			notify_contexts('suspend', self.reg);
			chain.register();
		}
	};

	// start the LOC positioning session once (best-effort)
	self._start_loc = function() {
		if (self.loc || !self.config.location)
			return;

		// lazy-load the LOC schema only now (GPS enabled) — see the top-of-file note
		let locmod = require('wwand.codec.schema.loc_lazy').s;

		if (!self.services[sprintf('%d', locmod.default.service)]) {
			log('info', 'location requested but loc service unavailable');
			return;
		}

		self.alloc(locmod.default, (err, loc) => {
			if (err) {
				log('warn', sprintf('loc allocation failed: %J', err));
				return;
			}

			self.loc = loc;

			loc.on('POSITION_REPORT_IND', (data) => {
				if (data.status != locmod.SESSION_STATUS_SUCCESS &&
				    data.status != locmod.SESSION_STATUS_IN_PROGRESS)
					return;

				if (data.latitude == null)
					return;

				self.location = {
					latitude: data.latitude,
					longitude: data.longitude,
					altitude: data.altitude,
					speed: data.h_speed,
					heading: data.heading,
					uncertainty: data.h_uncertainty,
					hdop: data.dop?.hdop,
					technology: data.technology,
					utc_ms: data.utc_ms,
				};

				emit('location', self.location);
			});

			loc.request('REGISTER_EVENTS', { mask: locmod.EVENT_POSITION_REPORT }, (e2) => {
				if (e2)
					return log('warn', sprintf('loc register events failed: %J', e2));

				loc.request('START', {
					session_id: 1,
					intermediate_reports: 1,
					min_interval_ms: 1000,
				}, (e3) => {
					if (e3)
						log('warn', sprintf('loc start failed: %J', e3));
					else
						log('notice', 'location session started');
				});
			});
		});
	};

	// telemetry subsystem (fast watch loop, CA, data-mode, slow log tick) —
	// telemetry_qmi.uc attaches watch/_start_telemetry/… methods
	let telem = telemetry_qmi.install(self, { log: log, emit: emit });

	// --- lifecycle ---------------------------------------------------------

	self.start = function() {
		if (self.hub)
			return;

		self.hub = transport_open(self.device, {
			on_gone: () => self._device_gone(),
			on_unhandled: (hub, dec) => {
				if (dec.msg_id != null)
					log('debug', sprintf('unhandled message svc %d cid %d msg 0x%04x %s',
						dec.service, dec.cid, dec.msg_id, dec.kind));
			},
		});

		if (!self.hub)
			return fail('open', { error: 'open', device: self.device });

		self.ctl = client_mod.create(self.hub, ctlmod.default, 0, client_hooks);

		let begin = chain.begin;

		// old 'delay' option: wait before touching the modem
		if (+(self.config.delay ?? 0) > 0)
			tm.settle = uloop.timer(+self.config.delay * 1000, begin);
		else
			begin();
	};

	self.teardown = function() {
		for (let t in values(tm))
			if (t)
				t.cancel();

		tm.retry = tm.reg = tm.settle = tm.at_drain = null;
		telem.stop();

		modem_common.close_at(self);

		// Anything still in flight belongs to the incarnation we are ending.
		// Bump FIRST, so a callback that fires during the destroys below already
		// sees a stale generation.
		self._gen++;

		// RELEASE the service clients on the modem (CTL RELEASE_CID) while the
		// transport is still up, rather than only dropping them here. A
		// destroyed-but-not-released client stays in the MODEM's client table
		// until its stack resets, and on a stack with a tiny table (the E1820
		// class) a few failed attempts exhaust it. self.release() destroys the
		// client locally as well, so this replaces the bare destroy rather than
		// adding to it. Fire-and-forget: the release frame is written
		// synchronously, and destroying ctl just below cancels the answers we do
		// not need. ctl goes LAST, and is only destroyed — it is the implicit
		// client (cid 0) and it is what carries RELEASE_CID for all the others.
		for (let c in [ self.dms, self.nas, self.uim, self.wda, self.loc, self.wds_cfg,
		               self.dsd, self.tmd, self.cat, self.wms, self.pdc ]) {
			if (!c)
				continue;

			if (self.hub && !self.hub.closed)
				self.release(c, (e) => { if (e) log('debug', 'release failed'); });
			else
				c.destroy();
		}

		self.ctl?.destroy();

		self.ctl = self.dms = self.nas = self.uim = self.wda = self.loc = self.wds_cfg = null;
		self.dsd = self.tmd = self.cat = self.wms = self.pdc = null;

		// fail any PDC operation still waiting on an indication that will now
		// never come, and clear the table so a rebuild can install again
		for (let key, w in (self._pdc_waits ?? {})) {
			w.timer?.cancel();
			w.cb({ error: 'cancelled', detail: 'modem torn down' }, null);
		}

		self._pdc_waits = null;
		// the readings belong to the client that is going away; keeping them
		// would show a stale mitigation level for a modem we no longer talk to
		self.thermal = null;

		// The UIM handlers are installed ON THE CLIENT, so a new client needs
		// them installed again. This flag is what says "already done", and
		// leaving it set meant a modem that tore down and retried came back with
		// NONE of the card diagnostics, the refresh handling or the long-APDU
		// reassembly attached — silently, because everything still worked except
		// the things that only fire when something goes wrong.
		self._uim_refresh_armed = false;

		// card-side diagnostics belong to the card we were talking to. A
		// transient busy left set would otherwise survive the reconnect and
		// keep claiming the reads are failing long after they stopped.
		self.sim_busy = false;
		self.sim_note = null;
		self.active_slot = null;

		// The same class of bug, and older than the UIM work: both of these
		// guard an install ON A CLIENT that teardown destroys. Leaving them set
		// meant a modem that tore down and retried never re-sent the NAS event
		// report (so RF-band and reject-reason pushes stopped for good) and
		// never re-registered the DSD indication (so the data-system mode fell
		// back to polling) — for the whole remaining life of the daemon, with
		// nothing in the log to say so.
		self._nas_evt_armed = false;
		self._dsd_ind_armed = false;
		// ...and WMS, which is worse than the other two: it is allocated lazily
		// on the first SMS op and cached. Left set, a retry handed every later
		// SMS the OLD client — bound to a hub that is closed — and never
		// allocated a replacement, so SMS stayed broken with no way back.
		self._wms_tried = false;

		// Fail any long-APDU reassembly still waiting instead of leaving its
		// caller on a 30 s timer for a client that no longer exists. Clearing
		// the map is also what lets install_apdu_reassembly() run again.
		for (let key, w in (self._apdu_long ?? {})) {
			w.timer?.cancel();
			w.cb({ error: 'cancelled', detail: 'modem torn down' }, null);
		}

		self._apdu_long = null;

		if (self.hub) {
			self.hub.close();
			self.hub = null;
		}
	};

	// stop() + _device_gone() installed by modem_common.scaffolding

	return self;
};
