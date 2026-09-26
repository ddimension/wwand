// wwand tests — MBIM modem rich-telemetry integration (Phase C).
//
// Drives modem_mbim to READY over the MBIM mock hub, then asserts the rich
// telemetry the daemon surfaces — self.signal / self.cells / self.dsd_status /
// self.reg_detail — is populated in the SAME QMI-shaped structures modem.uc
// produces, sourced via the NATIVE MBIM backend (mbim_backend.uc). The mock
// answers the native CIDs (SIGNAL_STATE_V2 in Basic Connect, BASE_STATIONS_INFO
// in the MS Basic Connect Extensions service, both via __raw as in
// test_mbim_backend); the QMI-passthrough candidate loses cleanly because the
// mock knows no passthrough service, so 'mbim' wins every capability that has a
// native source. self.signal + self.cells come from the fast watch() loop,
// self.dsd_status + self.reg_detail from the slow telemetry tick.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as fs from 'fs';
import * as struct from 'struct';
import * as mbim_mockhub from './lib/mbim_mockhub.uc';
import * as fakefx from './lib/fakefx.uc';
import * as modem_mbim from 'wwand/modem_mbim.uc';
import * as qmi_mockhub from './lib/mockhub.uc';
import * as client_mod from 'wwand/client.uc';
import * as ctlmod from 'wwand/codec/schema/ctl.uc';
import * as nasmod from 'wwand/codec/schema/nas.uc';
import * as dsdmod from 'wwand/codec/schema/dsd.uc';
import * as uimmod from 'wwand/codec/schema/uim.uc';
import * as wmsmod from 'wwand/codec/schema/wms.uc';
import * as bc from 'wwand/codec/mbim_schema/basic_connect.uc';
import * as ext from 'wwand/codec/mbim_schema/ms_basic_connect_ext.uc';

uloop.init();

function p32(v) { return chr(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff); }

function u16le(s) {
	let o = '';
	for (let i = 0; i < length(s); i++)
		o += chr(ord(s, i) & 0xff, 0);
	return o;
}
function pad4(s) {
	let n = length(s);
	while (n % 4) { s += "\x00"; n++; }
	return s;
}

// --- native InformationBuffer builders (mirror test_mbim_backend) ------------

// MBIMEx v2 Signal State: 5 u32 fixed + RsrpSnr ms-struct-array (offset,size)
function build_signal(rssi, entries) {
	let count = length(entries);
	let arr_off = 28;
	let fixed = p32(rssi) + p32(0) + p32(5000) + p32(0) + p32(0) +
		p32(arr_off) + p32(4 + count * 20);
	let data = p32(count);
	for (let e in entries)
		data += p32(e.rsrp) + p32(e.snr) + p32(0) + p32(0) + p32(e.system_type);
	return fixed + data;
}

function cell_struct(provider, scalars) {
	let fixed_len = 8 + length(scalars) * 4;
	let pstr = provider ? u16le(provider) : '';
	let poff = length(pstr) ? fixed_len : 0;
	let fixed = p32(poff) + p32(length(pstr));
	for (let s in scalars)
		fixed += p32(s);
	return pad4(fixed + pstr);
}

function nr_serving_struct(provider, nci, pci, nrarfcn, tac, rsrp, rsrq, sinr) {
	let fixed_len = 8 + 8 + 4 * 6 + 8;
	let pstr = u16le(provider);
	let fixed = p32(fixed_len) + p32(length(pstr)) +
		struct.pack('<Q', nci) +
		p32(pci) + p32(nrarfcn) + p32(tac) + p32(rsrp) + p32(rsrq) + p32(sinr) +
		struct.pack('<Q', 0);
	return pad4(fixed + pstr);
}

// Base Stations Info (v3): 96-byte fixed part + appended data regions
// THE v3 LAYOUT, because that is what this session negotiates: wwand asks for
// MBIMEx 3.0 at open (mbim_client.uc) and the mock agrees, so the device
// answers v3 — SystemSubType present, pointers four bytes along, NR arrays
// carried. A modem that REFUSES the handshake answers v1 and is covered in
// test_mbim_backend.
function build_base_stations() {
	let lte_serv = cell_struct('26201', [ 12345678, 1300, 42, 0x1234, -95, -10, 0 ]);
	let lte_neigh = cell_struct('', [ 0, 1300, 99, 0, -105, -14 ]);
	// coded indices, not dB: 66 -> -90 dBm, 32 -> -11 dB, 43 -> 20 dB (libmbim
	// 1.32.0, mbimcli-ms-basic-connect-extensions.c:1410-1412)
	let nr_serv = nr_serving_struct('26201', 0x0000000100000002, 7, 632448, 0x5678, 66, 32, 43);

	let base = 96;
	let lte_serv_off = base;
	let lte_neigh_off = lte_serv_off + length(lte_serv);
	let nr_serv_off = lte_neigh_off + 4 + length(lte_neigh);

	let ptrs = {};
	ptrs[32] = [ lte_serv_off, length(lte_serv) ];
	ptrs[64] = [ lte_neigh_off, 4 + length(lte_neigh) ];
	ptrs[80] = [ nr_serv_off, 4 + length(nr_serv) ];

	let fixed = '';
	for (let off = 0; off < base; off += 4) {
		if (off == 0)      fixed += p32(ext.DATA_CLASS_LTE | ext.DATA_CLASS_5G_SA);
		else if (off == 4) fixed += p32(0);
		else if (ptrs[off]) fixed += p32(ptrs[off][0]) + p32(ptrs[off][1]);
		else if (ptrs[off - 4]) continue;
		else fixed += p32(0);
	}

	let data = lte_serv + p32(1) + lte_neigh + p32(1) + nr_serv;
	return fixed + data;
}

// --- handlers ----------------------------------------------------------------

function handlers() {
	return {
		DEVICE_CAPS: {
			device_type: 1, cellular_class: 1, voice_class: 1, sim_class: 2,
			data_class: 0x3f, sms_caps: 0, control_caps: 0, max_sessions: 8,
			custom_data_class: '', device_id: '359072060000000',
			firmware_info: 'RG650EM4G', hardware_info: 'RG650E-EU',
		},
		SUBSCRIBER_READY_STATUS: {
			ready_state: bc.READY_STATE_INITIALIZED,
			subscriber_id: '262011234567890', sim_iccid: '89490200001022832490',
			ready_info: 0, telephone_numbers_count: 0,
		},
		// THE COMMON CASE for the two MBIMEx v3 diagnostics: a firmware that
		// serves v3 layouts and has not implemented these CIDs. Status 9 is
		// MBIM_STATUS_ERROR_NO_DEVICE_SUPPORT. They are queried with
		// `no_recovery`, so this must not count against the control channel —
		// asserted in its own scenario below.
		MODEM_CONFIGURATION: { __error: 9 },
		// the native operator scan (basic_connect cid 8) — a raw buffer,
		// because the response is a ref-struct-array the field codec cannot
		// build. Two providers, decoded by the schema's own decode().
		VISIBLE_PROVIDERS: { __raw: struct.pack('<I', 0) },
		WAKE_REASON: { __error: 9 },
		// the default modem boots with its radio already on, so init must not
		// write RADIO_STATE at all — the off case is its own scenario below
		RADIO_STATE: {
			hw_radio_state: bc.RADIO_STATE_ON, sw_radio_state: bc.RADIO_STATE_ON,
		},
		REGISTER_STATE: {
			nw_error: 0, register_state: bc.REGISTER_STATE_HOME, register_mode: 1,
			available_data_classes: ext.DATA_CLASS_LTE, current_cellular_class: 1,
			// a 2-digit MNC with a leading zero: 262/01, not 262/1
			provider_id: '26201', provider_name: 'Telekom.de',
			roaming_text: '', registration_flag: 0,
		},
		PACKET_SERVICE: {
			nw_error: 0, packet_service_state: bc.PACKET_SERVICE_STATE_ATTACHED,
			highest_available_data_class: ext.DATA_CLASS_LTE,
		},
		// native telemetry CIDs (SIGNAL_STATE_V2 shares CID 11 with v1 in bc;
		// BASE_STATIONS_INFO is CID 11 in the ext service — the mock routes by
		// (service, cid) so both coexist)
		SIGNAL_STATE_V2: { __raw: build_signal(20, [
			{ rsrp: 100, snr: 60, system_type: ext.DATA_CLASS_LTE },    // -57 dBm, 6.5 dB
			{ rsrp: 90,  snr: 80, system_type: ext.DATA_CLASS_5G_SA },  // -67 dBm, 16.5 dB
		]) },
		BASE_STATIONS_INFO: { __raw: build_base_stations() },
	};
}

// --- run ---------------------------------------------------------------------

let mock = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: handlers() });
let modem = null, finished = false, guard = null;

function finish() {
	if (finished)
		return;
	finished = true;
	if (guard) guard.cancel();
	modem.stop();
	uloop.timer(1, () => { uloop.end(); });
}

// captures sim_refresh emitted by the SUBSCRIBER_READY_STATUS handler
let ready_events = [];

// A modem whose SOFTWARE radio is off must be switched on during init, or it
// never registers — the case obsy reported on an EG18 (ddimension/wwand#3),
// where stopping wwand and running `umbim radio on` by hand was the only way
// to connect. The write must be conditional: the default modem in this suite
// boots with the radio on and is checked below to receive no RADIO_STATE set
// A FUNCTION ERROR on the MBIMEx version query is recoverable, and must be
// recovered from.
//
// `self.opened` in mbim_client is that CLIENT's belief, not the device's: a
// fresh client over a device a previous host session left in-session never
// sends CLOSE, and the function answers the version query with a function
// error. libmbim has a step for exactly that (an explicit CLOSE before OPEN
// when the device may still be in session, mbim-device.c:2051-2058, 1.32.0).
// Without it no version is agreed, the client falls back to the v1 layouts, and
// a modem serving v3 answers the v1 CONNECT with status 21 every single time —
// HW-reproduced on the GL-X3000/RM520N (2026-09-20), 30+ identical bring-up
// failures cleared only by restarting the daemon.
//
// A DECLINED handshake is a different thing and must NOT be retried: that is
// the modem answering, and asking again gets the same answer. Both halves are
// asserted.
function assert_version_function_error() {
	let mockv = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: handlers(),
	                                  mbimex_function_errors: 1 });
	let mv = null, mv_done = false;

	mv = modem_mbim.create({
		id: 'm_ver', device: '/dev/mock3',
		config: { apn: 'internet' },
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		datapath: { netdev: 'wwan0', fx: fakefx.create(), mux: 'auto' },
		deps: {
			transport_open: mockv.transport_open,
			log: () => null,
			on_event: (m, event) => {
				if (event != 'registered' || mv_done)
					return;

				mv_done = true;

				let vers = filter(mockv.calls, (c) => c.name == 'VERSION');

				eq(length(vers), 2, 'mbimex: a function error is retried exactly once');

				// AND THE CLOSE IS THE POINT. Reopening without closing leaves
				// the function in the session it is stuck in, so "two VERSION
				// queries and a good answer" is not enough to show the retry
				// does the thing that fixes it. The control frames, in order.
				eq(map(filter(mockv.calls, (c) => c.kind == 'control' || c.name == 'VERSION'),
					(c) => c.name),
					[ 'OPEN', 'VERSION', 'CLOSE', 'OPEN', 'VERSION' ],
					'mbimex: the retry CLOSES the channel before reopening it');

				eq(mockv.mbimex_agreed, 0x0300,
					'mbimex: ...and the second try agrees 3.0');
				eq(m.mbim?.mbimex_version, 0x0300,
					'mbimex: the client ends up on the v3 layouts, not v1');
				eq(m.state, 'READY', 'mbimex: init completes after the reopen');

				mv.stop();

				// AND A DECLINED HANDSHAKE IS NOT RETRIED. The device answered;
				// asking again would get the same answer, and the retry exists
				// for a function that could not answer at all.
				let mockd = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: handlers(),
				                                  mbimex_version: 0 });
				let md = null, md_done = false;

				md = modem_mbim.create({
					id: 'm_ver2', device: '/dev/mock4',
					config: { apn: 'internet' },
					timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
					at: { fx: { read: () => null, glob: () => [] } },
					datapath: { netdev: 'wwan0', fx: fakefx.create(), mux: 'auto' },
					deps: {
						transport_open: mockd.transport_open,
						log: () => null,
						on_event: (m2, ev2) => {
							if (ev2 != 'registered' || md_done)
								return;

							md_done = true;

							eq(length(filter(mockd.calls, (c) => c.name == 'VERSION')), 1,
								'mbimex: a declined handshake is asked once and accepted');
							eq(m2.mbim?.mbimex_version, 0,
								'mbimex: ...and the client reads the v1 layouts');

							md.stop();
						},
					},
				});

				md.start();
			},
		},
	});

	mv.start();
}

// WHAT THE MODEM IS TOLD TO TELL US (basic_connect cid 19), and the three
// indications that only earn their keep once it is.
//
// Without CID 19 a modem uses its own default event set. That set is not
// nothing — an RM520N-GL volunteers SIGNAL_STATE, REGISTER_STATE,
// PACKET_SERVICE, LTE_ATTACH_INFO and MODEM_CONFIGURATION at init (GL-X3000,
// 2026-09-20) — but it is the MODEM's choice, and a firmware with a thinner
// default leaves handlers listening to silence with nothing to say so.
//
// The list is DERIVED from the registered handlers, which is the property
// worth pinning: a hardcoded copy goes stale the first time an `on()` is added
// without it, and the failure is silence.
function assert_subscribe_list() {
	let mocks = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: handlers() });
	let ms = null, ms_done = false;

	ms = modem_mbim.create({
		id: 'm_sub', device: '/dev/mock5',
		config: { apn: 'internet' },
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		datapath: { netdev: 'wwan0', fx: fakefx.create(), mux: 'auto' },
		deps: {
			transport_open: mocks.transport_open,
			log: () => null,
			on_event: (m, event) => {
				if (event != 'registered' || ms_done)
					return;

				ms_done = true;

				let sub = mocks.subscribed;

				ok(sub != null, 'subscribe: the modem was told what to send');

				let by = {};
				for (let e in (sub ?? []))
					by[e.service] = e.cids;

				// exactly the CIDs this modem has handlers for, and no others
				eq(by[bc.service], [ 2, 3, 9, 10, 11, 12 ],
					'subscribe: the basic-connect cids wwand listens for, sorted');
				eq(by[ext.service], [ 4, 8, 16 ],
					'subscribe: LTE attach info, per-slot UICC state, carrier configuration');

				// ...INCLUDING the QMI-over-MBIM passthrough, which is where
				// deriving the list from the handlers pays for itself: nobody
				// writing a vendor service has to remember a second table, and
				// the QMI indications tunnelled over it keep arriving.
				eq(by['d1a30bc2-f97a-6e43-bf65-c7e24fb0f0d3'], [ 1 ],
					'subscribe: a vendor service is carried without a second list');

				// derived, not copied: the client is the one authority
				eq(length(m.mbim.subscribed_events()), length(sub),
					'subscribe: the list is built from the registered handlers');

				// THE RADIO KILL SWITCH. A hardware off is a switch somebody
				// moved, and wwand must say so rather than climb its recovery
				// ladder against a modem doing what it was told.
				m.mbim.handlers[sprintf('%s:%d', bc.service, 3)][0].cb(
					{ hw_radio_state: bc.RADIO_STATE_OFF, sw_radio_state: bc.RADIO_STATE_ON });
				eq(m.control_note, 'radio disabled by the hardware switch',
					'radio ind: a hardware off is reported as one');



				m.mbim.handlers[sprintf('%s:%d', bc.service, 3)][0].cb(
					{ hw_radio_state: bc.RADIO_STATE_ON, sw_radio_state: bc.RADIO_STATE_ON });
				eq(m.control_note, null, 'radio ind: ...and cleared when it comes back');

				// a note some OTHER part of the daemon set is not ours to clear
				m.control_note = 'wwand-mbim package not installed';
				m.mbim.handlers[sprintf('%s:%d', bc.service, 3)][0].cb(
					{ hw_radio_state: bc.RADIO_STATE_ON, sw_radio_state: bc.RADIO_STATE_ON });
				eq(m.control_note, 'wwand-mbim package not installed',
					'radio ind: a foreign control note is left alone');

				// the pair itself is what `status` publishes and LuCI paints
				eq(m.radio, { hw: bc.RADIO_STATE_ON, sw: bc.RADIO_STATE_ON },
					'radio ind: the state pair is recorded, not only the note');

				// AN INDICATION MISSING EITHER STATE SAYS NOTHING ABOUT EITHER
				// SWITCH. It must not overwrite the pair, and it must not be
				// read as "both on" — which is what a bare field comparison
				// does, since an absent field is not RADIO_STATE_OFF. Raised
				// by Codex review of the note_radio refactor, 2026-09-22.
				m.control_note = 'radio disabled by the hardware switch';
				m.mbim.handlers[sprintf('%s:%d', bc.service, 3)][0].cb(
					{ hw_radio_state: bc.RADIO_STATE_ON });
				eq(m.control_note, 'radio disabled by the hardware switch',
					'radio ind: a partial indication does not announce a switch-on');
				eq(m.radio, { hw: bc.RADIO_STATE_ON, sw: bc.RADIO_STATE_ON },
					'radio ind: ...nor replace the last usable reading');
				m.control_note = null;

				// PER-SLOT UICC STATE: polled until now, so a card pulled while
				// the modem runs was noticed only by the failures after it.
				m.mbim.handlers[sprintf('%s:%d', ext.service, 8)][0].cb(
					{ slot_index: 1, state: ext.UICC_SLOT_STATE_EMPTY });
				eq(m.slot_state?.['1'], ext.UICC_SLOT_STATE_EMPTY,
					'slot ind: the new state is recorded against its slot');

				// LTE ATTACH INFO, unasked. It arrives about once a minute on
				// this hardware whether anything changed or not, so the state is
				// kept every time and only a CHANGE is logged.
				m.mbim.handlers[sprintf('%s:%d', ext.service, 4)][0].cb(
					{ lte_attach_state: ext.LTE_ATTACH_STATE_ATTACHED,
					  ip_type: 3, access_string: 'internet', nw_error: 0 });
				eq(m.attach_info?.state, ext.LTE_ATTACH_STATE_ATTACHED,
					'attach ind: the state is taken from the indication');
				eq(m.attach_info?.apn, 'internet', 'attach ind: ...and the apn with it');

				m.mbim.handlers[sprintf('%s:%d', ext.service, 4)][0].cb(
					{ lte_attach_state: 0, ip_type: 3, access_string: '', nw_error: 27 });
				eq(m.attach_info?.nw_error, 27, 'attach ind: a cause is carried');
				ok(length(m.attach_info?.nw_error_text ?? '') > 0,
					'attach ind: ...and named, not left as a number');
				eq(m.attach_info?.apn, null, 'attach ind: an empty apn reads as none, not ""');

				// NATIVE NETWORK SELECTION: the provider id is mcc + mnc with
				// the requested WIDTH, and the width is the statement — 310/030
				// and 310/30 are different operators and the id carries no flag
				// to say which was meant. ucode's sprintf has no `%0*d`, which
				// is exactly how a 3-digit MNC gets silently truncated.
				m.native_register({ mcc: 310, mnc: 30, width: 3 }, () => null);
				m.native_register({ mcc: 262, mnc: 1, width: 2 }, () => null);
				m.native_register(null, () => null);

				let regs = filter(mocks.calls, (c) => c.name == 'REGISTER_STATE' && c.kind == 'set');

				eq(length(regs), 3, 'register: three sets reached the modem');
				eq(regs[0].args.provider_id, '310030',
					'register: a 3-digit mnc keeps its leading zero');
				eq(regs[0].args.register_action, bc.REGISTER_ACTION_MANUAL,
					'register: ...as a manual selection');
				eq(regs[1].args.provider_id, '26201',
					'register: a 2-digit mnc is padded to two');
				// a zero-size MBIM string reads back as absent, which is the
				// same statement: automatic names no provider
				eq(regs[2].args.provider_id, null,
					'register: automatic names no provider');
				eq(regs[2].args.register_action, bc.REGISTER_ACTION_AUTOMATIC,
					'register: ...and says automatic');

				// THE CARRIER CONFIGURATION RETRY: once per incarnation.
				//
				// The init query runs before the radio is up and a modem may
				// answer "not yet" (status 14 on the RM520N); by the time
				// registration completes it has had every chance. This mock
				// refuses it outright, so the count is what the code decided to
				// send — twice, and never again however often registration
				// comes and goes. Without the flag every re-registration asks.
				let cfg_n = () => length(filter(mocks.calls,
					(c) => c.name == 'MODEM_CONFIGURATION' && c.kind == 'query'));

				eq(cfg_n(), 2, 'carrier retry: asked at init and once more after registering');

				// a second attach cycle must not add a third. The register
				// handler only runs step_attach from REGISTERING, so the state
				// has to be put back — otherwise this drives nothing and the
				// assertion below is free.
				m.state = 'REGISTERING';
				m.mbim.handlers[sprintf('%s:%d', bc.service, 9)][0].cb({
					nw_error: 0, register_state: bc.REGISTER_STATE_HOME, register_mode: 1,
					available_data_classes: 0, current_cellular_class: 0,
					provider_id: '26201', provider_name: 'Testnet', roaming_text: '',
					registration_flags: 0,
				});
				eq(cfg_n(), 2, 'carrier retry: a later registration does not ask again');

				// NATIVE SCAN: full scan, not the cached list
				m.native_scan(() => null, 1000);

				let scans = filter(mocks.calls, (c) => c.name == 'VISIBLE_PROVIDERS');
				eq(length(scans), 1, 'scan: the native scan reached the modem');
				eq(scans[0].args.action, 0, 'scan: ...asking for a full scan, not the cache');

				ms.stop();

				// AND A MODEM THAT REFUSES CID 19 STILL COMES UP. The default
				// event set is what it had before; refusing the subscription is
				// never a reason to fail a bring-up.
				let hr = handlers();
				hr.DEVICE_SERVICE_SUBSCRIBE_LIST = { __error: 9 };

				let mockr = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: hr });
				let mr = null, mr_done = false;

				mr = modem_mbim.create({
					id: 'm_sub2', device: '/dev/mock6',
					config: { apn: 'internet' },
					timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
					at: { fx: { read: () => null, glob: () => [] } },
					datapath: { netdev: 'wwan0', fx: fakefx.create(), mux: 'auto' },
					deps: {
						transport_open: mockr.transport_open,
						log: () => null,
						on_event: (m2, ev2) => {
							if (ev2 != 'registered' || mr_done)
								return;

							mr_done = true;
							eq(m2.state, 'READY',
								'subscribe: a modem that refuses the list still reaches READY');

							// and the radio the init READ is kept, not only the
							// one an indication later reports — otherwise
							// `status` says nothing about the radio until
							// somebody flips a switch, and "not asked yet" and
							// "both on" look the same.
							eq(m2.radio, { hw: bc.RADIO_STATE_ON, sw: bc.RADIO_STATE_ON },
								'radio: the queried state is kept for status');
							mr.stop();
						},
					},
				});

				mr.start();
			},
		},
	});

	ms.start();
}

// at all, so a future "just always write it" cannot pass both halves.
function assert_radio_off() {
	let h3 = handlers();

	// A REAL MODEM ANSWERS THE SET WITH THE STATE AFTER IT. The query reports
	// the software radio off; the set that switches it on answers with both
	// switches on — that response is the authoritative reading and wwand threw
	// it away, so `status` kept reporting the radio off on a modem that was
	// registered and carrying traffic (obsy, ddimension/wwand#38, 2026-09-22).
	// A constant handler cannot express this, which is why the old one could
	// not catch it.
	h3.RADIO_STATE = (args, meta) => (meta.kind == 'set')
		? { hw_radio_state: bc.RADIO_STATE_ON, sw_radio_state: bc.RADIO_STATE_ON }
		: { hw_radio_state: bc.RADIO_STATE_ON, sw_radio_state: bc.RADIO_STATE_OFF };

	let mock3 = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: h3 });
	let m3 = null, m3_done = false;

	m3 = modem_mbim.create({
		id: 'm_radio', device: '/dev/mock2',
		config: { apn: 'internet' },
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		datapath: { netdev: 'wwan0', fx: fakefx.create(), mux: 'auto' },
		deps: {
			transport_open: mock3.transport_open,
			log: () => null,
			on_event: (m, event) => {
				if (event != 'registered' || m3_done)
					return;

				m3_done = true;

				let sets = filter(mock3.calls,
					(c) => c.name == 'RADIO_STATE' && c.kind == 'set');

				eq(length(sets), 1, 'radio: an off software radio is switched on once');
				eq(sets[0]?.args?.radio_state, bc.RADIO_STATE_ON,
					'radio: ...and switched ON, not cycled off first');
				ok(length(filter(mock3.calls,
					(c) => c.name == 'RADIO_STATE' && c.kind == 'query')) > 0,
					'radio: the state is READ before it is written');

				// the modem still got all the way to registration afterwards
				eq(m3.state, 'READY', 'radio: init continues to READY after the switch');

				// ...and reports the radio it now HAS, not the one it had
				eq(m3.radio, { hw: bc.RADIO_STATE_ON, sw: bc.RADIO_STATE_ON },
					'radio: the set response updates the reported state');
				eq(m3.control_note, null,
					'radio: ...and leaves no "radio disabled" note behind');

				// and the default (radio already on) instance wrote nothing
				eq(length(filter(mock.calls,
					(c) => c.name == 'RADIO_STATE' && c.kind == 'set')), 0,
					'radio: a modem already on is left alone');

				m3.stop();
				finish();
			},
		},
	});

	m3.start();
}

// PUK-locked SIM must terminal-block (SIM_BLOCKED reason puk_required), NOT
// loop PIN1-ENTER -> fail('pin_verify') -> recovery ladder (resets a SIM only
// a PUK can fix). Second modem instance: device-locked ready state + PIN query
// answering pin_type PUK1. (Defined before its caller — this ucode treats
// module-level function statements as non-hoisted under 'use strict'.)
// --- the SIM poll must not outlive the session --------------------------------
//
// A card that answers NOT_INITIALIZED puts step_sim into a poll loop. Teardown
// cancels sim_poll_timer and then destroys the client, which completes the
// in-flight query with `cancelled` — and the callback used to walk on regardless
// and re-arm the timer AFTER that cancel pass. When the new one fired,
// self.mbim was null and `self.mbim.command` threw; a throw inside a uloop
// callback ends the program (measured 2026-09-19), so the daemon dies and procd
// respawns it. Reachable on any unplug or config reload inside the cold-boot
// ready-state wait — the GL-X3000/RM520N case. Found by a full review,
// 2026-09-19.
function assert_sim_poll_teardown() {
	uloop.init();

	let h = handlers();

	h.SUBSCRIBER_READY_STATUS = {
		ready_state: bc.READY_STATE_NOT_INITIALIZED,
		subscriber_id: '', sim_iccid: '', ready_info: 0, telephone_numbers_count: 0,
	};

	let mockp = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: h });
	let mp = null, swapped = false, poll_cb = null, alive = false;

	mp = modem_mbim.create({
		id: 'm_simpoll', device: '/dev/mockp',
		config: { apn: 'internet' },
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5,
		          at_drain: 1, card_poll: 5 },
		at: { fx: { read: () => null, glob: () => [] } },
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		datapath: { netdev: 'wwan0', fx: fakefx.create(), mux: 'auto' },
		deps: {
			transport_open: mockp.transport_open,
			log: () => null,
			on_event: (m, event, data) => {
				if (event != 'state' || data?.state != 'SIM_UNLOCK' || swapped)
					return;

				swapped = true;

				// the poll wait is armed now. Swap in a client that CAPTURES
				// the query instead of answering it, so the teardown below
				// lands with a command genuinely in flight — which is the only
				// state in which the bug fires.
				mp.mbim = {
					command: (svc, name, kind, args, cb) => { poll_cb = cb; },
					destroy: () => null,
				};
			},
		},
	});

	mp.start();

	// past the poll deadline: the capturing client now holds the callback
	uloop.timer(30, () => {
		ok(poll_cb != null, 'sim-poll: a ready-state query is in flight');

		mp.stop();            // gen++, client dropped, timers cancelled

		// ...and only now does the query answer, as a cancellation
		if (poll_cb)
			poll_cb({ error: 'cancelled' });
	});

	// well past another poll interval: an unguarded re-arm fires here and
	// dereferences the null client, which ends the whole run
	uloop.timer(90, () => {
		alive = true;
		uloop.end();
	});

	uloop.run();

	ok(alive, 'sim-poll: a cancelled query does not re-arm a poll into a dead session');
	eq(mp.mbim, null, 'sim-poll: the client stayed gone');
}

function assert_puk_block() {
	let h2 = handlers();
	h2.SUBSCRIBER_READY_STATUS = {
		ready_state: bc.READY_STATE_DEVICE_LOCKED,
		subscriber_id: '', sim_iccid: '', ready_info: 0, telephone_numbers_count: 0,
	};
	h2.PIN = { pin_type: bc.PIN_TYPE_PUK1, pin_state: bc.PIN_STATE_LOCKED,
	           remaining_attempts: 0 };

	let mock2 = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: h2 });
	let m2 = null, m2_done = false;

	// the session datapath runs before the SIM steps, so this instance also
	// covers it: MBIM goes through the SHARED netlink.setup() (built-in `vlan`
	// backend) rather than a datapath function of its own.
	let dpfx = fakefx.create();

	m2 = modem_mbim.create({
		id: 'm_puk', device: '/dev/mock1',
		config: { apn: 'internet', pincode: '1234' },
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		datapath: { netdev: 'wwan0', fx: dpfx, mux: 'auto',
		            mux_links: [ { id: 1, name: 'wwan0.1', mtu: 1500 } ] },
		deps: {
			transport_open: mock2.transport_open,
			log: () => null,
			on_event: (m, event, data) => {
				if (event == 'sim_blocked' && !m2_done) {
					m2_done = true;
					eq(data.reason, 'puk_required', 'puk: terminal reason puk_required');
					eq(m2.state, 'SIM_BLOCKED', 'puk: state SIM_BLOCKED, no recovery ladder');
					eq(m2.pin1?.state, 1, 'puk: pin1 status populated (MBIM parity)');
					eq(m2.datapath?.backend, 'vlan',
						'datapath: mbim auto-selects the built-in vlan backend');
					eq(m2.datapath?.mux_devs, [ 'wwan0.1' ],
						'datapath: the session child is created');
					ok(dpfx.action_index('link_add_vlan wwan0.1 link wwan0 id 1') >= 0,
						'datapath: through netlink.setup(), not a private path');
					eq(dpfx.action_index('link_set wwan0 down'), -1,
						'datapath: the parent is not bounced for a VLAN mux');
					// map_ids must survive setup() into the datapath the context
					// reads — it was dropped here once, which silently disabled
					// every session-id remap a datapath can ask for
					eq(m2.datapath?.map_ids, { '1': 1 },
						'datapath: the wire-id mapping is carried onto the modem');
					m2.stop();
					assert_radio_off();
					assert_version_function_error();
					assert_subscribe_list();
				}
			},
		},
	});

	m2.start();
}


// inline NwError capture: a denied REGISTER_STATE with a reject cause must
// surface in reg_detail IMMEDIATELY (no telemetry tick involved); a clean
// re-registration clears it. The mock's query handler is switched alongside
// the indication so the re-register probe sees the same state.
function assert_inline_reject() {
	let denied = {
		nw_error: 15, register_state: bc.REGISTER_STATE_DENIED, register_mode: 1,
		available_data_classes: 0, current_cellular_class: 1,
		provider_id: '', provider_name: '', roaming_text: '', registration_flag: 0,
	};

	mock.handlers.REGISTER_STATE = denied;
	mock.indicate('REGISTER_STATE', denied);

	uloop.timer(100, function() {
		eq(modem.reg_detail?.reject_cause, 15, 'inline: NwError captured from the indication');
		eq(modem.reg_detail?.limited, true, 'inline: denied register state -> limited');
		ok(modem.reg_detail?.reject_text != null, 'inline: reject cause mapped to text');

		let home = handlers().REGISTER_STATE;

		mock.handlers.REGISTER_STATE = home;
		mock.indicate('REGISTER_STATE', home);

		uloop.timer(100, function() {
			eq(modem.reg_detail, null, 'inline: clean registration clears the cause');

			// MBIM reports the operator as ONE concatenated string; every
			// consumer was written against QMI's separate mcc/mnc, so an MBIM
			// modem showed no operator at all (ddimension/luci-app-wwand#4).
			// The pair is now emitted alongside the raw id.
			eq(modem.reg?.plmn?.id, '26201', 'plmn: the raw MBIM ProviderId is kept');
			eq(modem.reg?.plmn?.mcc, 262, 'plmn: MCC is the first three digits');
			eq(modem.reg?.plmn?.mnc, 1, 'plmn: MNC is what follows');
			eq(modem.reg?.plmn?.mnc_digits, 2,
				'plmn: ...and its DIGIT COUNT, because 260/06 and 260/060 differ');
			eq(modem.reg?.plmn?.description, 'Telekom.de', 'plmn: name unchanged');
			assert_puk_block();
		});
	});
}

function assert_telemetry() {
	// signal (fast watch loop; native SIGNAL_STATE_V2) — QMI GET_SIGNAL_INFO shape
	ok(modem.signal?.lte != null, 'signal: lte block populated via native backend');
	eq(modem.signal.lte.rssi, -73, 'signal: lte rssi dBm (index 20)');
	eq(modem.signal.lte.rsrp, -57, 'signal: lte rsrp dBm (coded 100)');
	eq(modem.signal.lte.snr, 65, 'signal: lte snr 0.1 dB (coded 60)');
	eq(modem.signal.nr5g?.rsrp, -67, 'signal: nr5g rsrp dBm (coded 90)');

	// cells (fast watch loop; native BASE_STATIONS_INFO) — QMI cell-location
	// shape, read with the v3 offsets this session negotiates.
	ok(modem.cells?.lte_intra != null, 'cells: lte_intra populated via native backend');
	eq(modem.cells.lte_intra.plmn, '262/01', 'cells: lte plmn');
	eq(modem.cells.lte_intra.earfcn, 1300, 'cells: lte earfcn');
	eq(modem.cells.lte_intra.serving_cell_id, 42, 'cells: lte serving pci');
	eq(length(modem.cells.lte_intra.cells), 2, 'cells: serving + 1 neighbour');
	eq(modem.cells.nr5g_arfcn, 632448, 'cells: nr arfcn');
	eq(modem.cells.nr5g_cell?.pci, 7, 'cells: nr pci');
	eq(modem.cells.nr5g_cell?.rsrp, -900, 'cells: nr rsrp coded 66 -> -90 dBm (x10)');
	eq(modem.cells.nr5g_cell?.snr, 200, 'cells: nr sinr coded 43 -> 20 dB (x10)');

	// data-system mode (slow tick; native register-state class mask)
	ok(modem.dsd_status != null, 'dsd_status: populated via native backend');
	eq(modem.dsd_status.mode, 'LTE', 'dsd_status: LTE-only class mask -> LTE');
	eq(modem.dsd_status.source, 'mbim', 'dsd_status: sourced from native mbim');

	// caps.rats derived natively from DEVICE_CAPS data_class (0x3f = GPRS..LTE),
	// no passthrough/AT — and the current RAT from dsd_status even with no AT port
	eq(modem.caps?.rats, [ 'gsm', 'lte', 'umts' ], 'caps: rats from native MBIM data_class (sorted)');
	eq(modem.rat_label, 'LTE', 'rat: current RAT from dsd_status (no AT needed)');

	// registration detail (slow tick; native register state)
	ok(modem.reg_detail != null, 'reg_detail: populated via native backend');
	eq(modem.reg_detail.source, 'mbim', 'reg_detail: source mbim');
	eq(modem.reg_detail.limited, false, 'reg_detail: home registration not limited');

	// the chosen backends settled on native for every capability with one
	ok(modem._sig_be == 'mbim', 'backend: signal chose native mbim');
	ok(modem._cells_be == 'mbim', 'backend: cells chose native mbim');
	ok(modem._dsd_be == 'mbim', 'backend: data_mode chose native mbim');
	ok(modem._regd_be == 'mbim', 'backend: reg_detail chose native mbim');

	// SUBSCRIBER_READY_STATUS notification (SIM hot-swap): a new iccid/imsi is
	// delivered unsolicited -> the native handler refreshes identity and emits
	// sim_refresh (parity with the QMI UIM CARD_STATUS/REFRESH path).
	eq(modem.info.iccid, '89490200099999999999', 'ready-status: iccid refreshed from notification');
	eq(modem.info.imsi, '262019999999999', 'ready-status: imsi refreshed from notification');
	eq(modem._ready_state, bc.READY_STATE_INITIALIZED, 'ready-status: state tracked');
	ok(length(filter(ready_events, function(e) { return e.event == 'sim_refresh' })) >= 1,
		'ready-status: sim_refresh emitted on identity change');

	// --- a transport that STOPS answering must be demoted, not believed --------
	//
	// Field shape (ddimension/wwand#30): on a Quectel RM520F-GL the QMI-over-MBIM
	// passthrough served telemetry for an hour, then failed every request with
	// exactly the error below. The cached choice kept dispatching to it, so signal
	// and cells froze on their last values — a flat line in LuCI for an hour — and
	// the data-mode branch stored its null, which read as `tech=none` on a modem
	// that was registered and carrying traffic the whole time.
	//
	// Driven here against the NATIVE client, which is what this modem chose; the
	// mechanism is the cache, not the transport.
	let live_mbim = modem.mbim;
	let was_mode = modem.dsd_status?.mode;

	modem.mbim = { command: (svc, cid, op, args, cb) => cb({ error: 'mbim', status: 2 }, null) };

	modem._refresh_data_mode(() => {
		eq(modem.dsd_status?.mode, was_mode,
			'demote: a failed read keeps the last known mode instead of storing null');
		eq(modem._dsd_be, 'mbim', 'demote: one failure does not drop the choice');

		modem._refresh_data_mode(() => modem._refresh_data_mode(() => {
			eq(modem._dsd_be, null,
				'demote: three consecutive failures drop it, so the ladder re-probes');

			// --- and what the ladder must land on: the serving cell ----------
			//
			// The case that reached the field (ddimension/wwand#30): an
			// RM520F-GL reporting data class CUSTOM alone (0x80000000) while
			// carrying NR5G-SA. That is a truthy answer with no mode in it, so
			// the mbim rung used to count as answering, kept the choice, and
			// the RAT stayed null — with QENG's serving cell one rung below,
			// knowing the answer. The AT rung reads state only, no port needed.
			modem.mbim = { command: (svc, cid, op, args, cb) => cb(null, {
				nw_error: 0, register_state: bc.REGISTER_STATE_HOME, register_mode: 1,
				available_data_classes: ext.DATA_CLASS_CUSTOM, current_cellular_class: 1,
				provider_id: '26201', provider_name: 'Telekom.de',
				roaming_text: '', registration_flag: 0,
			}) };
			modem.cells = modem.cells ?? {};
			modem.cells.serving = { nr: { arfcn: 504990, band: 'n41' } };
			delete modem._dsd_be;
			delete modem._dsd_be_fails;

			modem._refresh_data_mode(() => {
				eq(modem._dsd_be, 'at',
					'custom: a class that says nothing lets the ladder reach the serving cell');
				eq(modem.dsd_status?.mode, 'SA',
					'custom: ...which knows this is SA, where the mask knew nothing');
				eq(modem.dsd_status?.source, 'at', 'custom: and the source says so');

				modem.mbim = live_mbim;
				assert_inline_reject();
			});
		}));
	});
}

modem = modem_mbim.create({
	id: 'm_tele', device: '/dev/mock0',
	config: { apn: 'internet', mux_id: 0, stats_interval: 1 },   // slow tick at ~1s
	timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
	at: { fx: { read: () => null, glob: () => [] } },   // no AT tty in tests
	deps: {
		transport_open: mock.transport_open,
		log: () => null,
		on_event: (m, event, data) => {
			if (event == 'sim_refresh')
				push(ready_events, { event: event, data: data });
			if (event == 'registered') {
				ok(true, 'modem reached READY (OPEN->CAPS->SUBSCRIBER->REGISTER->PACKET_SERVICE)');

				// warm the fast loop (as daemon.modem_signal does), then read back
				// after the fast loop + the first slow telemetry tick have run
				m.watch();
				// simulate a SIM hot-swap: unsolicited ready-status with a new
				// iccid/imsi -> exercises the native SUBSCRIBER_READY_STATUS handler
				mock.indicate('SUBSCRIBER_READY_STATUS', {
					ready_state: bc.READY_STATE_INITIALIZED,
					subscriber_id: '262019999999999', sim_iccid: '89490200099999999999',
					ready_info: 0, telephone_numbers_count: 0,
				});
				uloop.timer(1400, assert_telemetry);
			}
		},
	},
});

guard = uloop.timer(6000, () => { ok(false, 'timed out before telemetry populated'); finish(); });
modem.start();

uloop.run();

// its own loop, because the main one above has ended
assert_sim_poll_teardown();

// --- a reattach interrupted by teardown must stop, not switch transport ------
// reattach is radio OFF, wait, radio ON — half-finished at every await. A
// teardown landing in the middle used to read as "this transport declined, try
// the other one": the cancelled passthrough allocation fell through to via_radio
// and sent a NATIVE MBIM RADIO_STATE_OFF into the teardown. The QMI client
// refuses further requests by itself now, but MBIM is a different transport and
// still reaches the modem. Worse, the settle timers were armed unconditionally
// from those callbacks — teardown cancels its timers BEFORE destroying the
// clients whose callbacks arm them, so such a timer is never cancelled, and by
// the time it fires `self.mbim` is null and the command throws.
(() => {
	let mock3 = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: handlers() });
	let m3 = modem_mbim.create({
		id: 'm_reattach', device: '/dev/mock3',
		config: { apn: 'internet' },
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		deps: { transport_open: mock3.transport_open, log: () => null,
		        on_event: () => null },
	});

	// no MBIM client and no passthrough: the honest answer is "this backend
	// cannot do it", and that must stay distinct from a cancellation
	let plain = 'unset';
	m3._ensure_pt = (cb) => cb(false);
	m3.reattach((err) => plain = err?.error);
	eq(plain, 'unsupported_on_backend', 'reattach: no mbim client is unsupported, not cancelled');

	// Now the race, driven by hand so it is exact: hold the passthrough
	// callback, tear the session down, then let the callback land — which is
	// precisely what a destroy does, synchronously, from inside teardown.
	let got = 'unset', armed = false, pending = null;
	// teardown destroys the client, so the fake needs the shape the real one has
	m3.mbim = { command: () => { armed = true; }, destroy: () => null };
	m3._ensure_pt = (cb) => { pending = cb; };
	m3.reattach((err) => got = err?.error);

	m3.teardown();
	pending(false);   // the passthrough answers after the session is gone

	eq(got, 'cancelled', 'reattach: a teardown mid-flight ends it as cancelled');
	eq(armed, false, 'reattach: ...and no radio command is sent into the teardown');

	// the teardown depth make_fail reads before arming a retry
	// (modem_common.uc). It must come back to zero, or every later retry on
	// this object is silently refused. Review follow-up, 2026-09-19.
	eq(m3._teardown_depth, 0,
		'reattach: the teardown depth is balanced, so retries still work');

	// ...and it stays balanced when a client destroy pays a callback that
	// throws. Destroying a client runs its pending callbacks synchronously
	// (client.uc:217, mbim_client.uc:267) and those are not ours; an unguarded
	// throw would skip the decrement and leave the depth raised for the life of
	// the object, after which make_fail refuses every retry. Review follow-up,
	// 2026-09-19.
	let m4 = modem_mbim.create({
		id: 'teardown-throw', device: '/dev/mock3', config: {},
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		deps: { log: () => null, on_event: () => null },
	});

	m4.mbim = { destroy: () => die('a client callback that throws'), command: () => null };
	m4.teardown();

	eq(m4._teardown_depth, 0,
		'teardown: a throwing client callback still leaves the depth balanced');
	eq(m4.mbim, null, 'teardown: ...and the client is dropped anyway');

	// ...and one throwing cleanup must not skip the ones after it. A single
	// catch around the whole passthrough block let the first bad destroy strand
	// the remaining clients and the shim, after which `self.pt = null` dropped
	// the only handle to a shim still open with clients on it
	// (qmi_over_mbim.uc:110). Raised by review, 2026-09-19.
	let m5 = modem_mbim.create({
		id: 'teardown-partial', device: '/dev/mock4', config: {},
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		deps: { log: () => null, on_event: () => null },
	});

	let destroyed = [], shim_closed = false;

	m5.pt = {
		ctl: { destroy: () => die('the FIRST cleanup throws') },
		nas: { destroy: () => push(destroyed, 'nas') },
		dsd: { destroy: () => push(destroyed, 'dsd') },
		shim: { close: () => { shim_closed = true; } },
	};

	m5.teardown();

	eq(destroyed, [ 'nas', 'dsd' ], 'teardown: the cleanups after a throwing one still run');
	eq(shim_closed, true, 'teardown: ...and the shim is still closed, not stranded');
	eq(m5.pt, null, 'teardown: the passthrough handle is dropped');
	eq(m5._teardown_depth, 0, 'teardown: and the depth is balanced');

	// BOTH passthrough clients go with the shim. ensure_pt_client caches into
	// self[field] and short-circuits when it is set, so a wms left behind
	// survived a teardown+retry on the same object and every later SMS op used
	// a client bound to a shim that is gone — failing forever and feeding the
	// proto-error counter, which eventually power-cycles a healthy modem.
	// Found by a full review, 2026-09-19.
	let m7 = modem_mbim.create({
		id: 'teardown-wms', device: '/dev/mock6', config: {},
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		deps: { log: () => null, on_event: () => null },
	});

	m7.uim = { destroy: () => null };
	m7.wms = { destroy: () => null };
	m7.teardown();

	eq(m7.uim, null, 'teardown: the passthrough UIM client is dropped');
	eq(m7.wms, null, 'teardown: ...and so is the WMS one');
})();

// --- the slow tick must read the serving cell BEFORE choosing a data mode ----
//
// Not a style point, a trap: the data-mode ladder's last rung probes
// `self.cells.serving`, and backend.choose caches a 'none' verdict PERMANENTLY.
// Walked first, on a modem's very first tick, every rung declines — passthrough
// dead, native MBIM reporting a class that says nothing, serving not read yet —
// and that modem is marked as having no data-mode backend for the rest of its
// life, though QENG answers a moment later in the same tick.
//
// Pinned against the source because the consequence is not reachable from this
// harness: it has no AT port, so `_refresh_serving` cannot populate anything
// here, and the cold start cannot be staged. Reverting the order leaves every
// other check in this file green — which is exactly why this one exists.
{
	let src = fs.readfile('../src-ucode/telemetry_mbim.uc') ?? '';
	let line = '';

	for (let l in split(src, '\n'))
		if (index(l, '_refresh_signal(() =>') >= 0 && index(l, '_refresh_data_mode') >= 0)
			line = l;

	ok(line != '', 'tick order: found the slow-tick chain');
	ok(index(line, '_refresh_serving') < index(line, '_refresh_data_mode'),
		'tick order: the serving cell is read before the data-mode ladder is walked');
	ok(index(line, '_refresh_cells') < index(line, '_refresh_serving'),
		'tick order: ...and the cells before the serving detail that hangs off them');
}

// --- the passthrough gives its CIDs back -------------------------------------
//
// reattach and reset each ALLOCATE a DMS client out of the MODEM's client table
// for the duration of one call, and nothing in the passthrough released
// anything — not on success, not on error, not on cancellation. The table is
// finite and small on some stacks (the E182E class has room for a handful), so
// a scripted reattach loop walked it down and then took passthrough UIM and WMS
// with it. modem.uc has released its clients since :296; the MBIM passthrough
// never did. Found by a full review, 2026-09-19.

function assert_passthrough_releases_cid(after) {
	let qmock = qmi_mockhub.create({ handlers: { SET_OPERATING_MODE: {} } });
	let pthub = qmock.transport_open('/dev/ptmock', {});
	let ctl = client_mod.create(pthub, ctlmod.default, 0);

	// stand in for a negotiated QMI-over-MBIM passthrough: the mock hub IS the
	// shim as far as client.uc is concerned (send/register/unregister)
	modem.pt = { shim: pthub, ctl: ctl };
	modem._ensure_pt = (cb) => cb(true);

	modem.reattach((err, res) => {
		eq(err, null, 'pt-release: the passthrough reattach succeeded');
		eq(res?.via, 'qmi_passthrough', 'pt-release: it really took the passthrough path');

		let alloc = filter(qmock.calls, (c) => c.name == 'ALLOCATE_CID');
		let rel = filter(qmock.calls, (c) => c.name == 'RELEASE_CID');

		eq(length(alloc), 1, 'pt-release: one DMS client was allocated for the call');
		eq(length(rel), 1, 'pt-release: and the CID is given back when it ends');
		eq(rel[0]?.args?.release?.cid, alloc[0] ? qmock.next_cid - 1 : null,
			'pt-release: the CID released is the one allocated');

		after();
	});
}

assert_passthrough_releases_cid(() => uloop.end());
uloop.run();

// --- teardown releases the session-long passthrough CIDs ---------------------
//
// pt.nas / pt.dsd were destroyed and uim / wms were not even that, and none of
// the four was ever RELEASED — client.destroy() deliberately does not
// (client.uc:201). Closing the HOST's MBIM session is not shown to reset the
// modem's embedded QMI client table, so every daemon reload leaked up to four
// CIDs out of a table that has room for a handful on the E182E class. The
// native side has done this burst since modem.uc:1409. Raised by Codex review,
// 2026-09-19.

function assert_teardown_releases_pt_cids() {
	let qmock = qmi_mockhub.create({ handlers: {} });
	let pthub = qmock.transport_open('/dev/ptmock2', {});
	let ctl = client_mod.create(pthub, ctlmod.default, 0);

	modem.pt = {
		shim: pthub, ctl: ctl,
		nas: client_mod.create(pthub, nasmod.default, 11, {}),
		dsd: client_mod.create(pthub, dsdmod.default, 12, {}),
	};
	modem.uim = client_mod.create(pthub, uimmod.default, 13, {});
	modem.wms = client_mod.create(pthub, wmsmod.default, 14, {});

	modem.teardown();

	let rel = filter(qmock.calls, (c) => c.name == 'RELEASE_CID');
	let cids = map(rel, (c) => c.args?.release?.cid);

	eq(length(rel), 4, 'pt-teardown: all four session clients are released');

	for (let want in [ 11, 12, 13, 14 ])
		ok(index(cids, want) >= 0,
			sprintf('pt-teardown: cid %d given back', want));
}

assert_teardown_releases_pt_cids();

// --- a passthrough that stopped answering is rebuilt, not trusted -----------
//
// The modem can drop the QMI clients it handed out over the passthrough while
// the MBIM session stays up: an RM520N answered every passthrough request with
// MBIM_STATUS_FAILURE (2) for ten hours after the network ended its session and
// it re-applied its carrier configuration, and _ensure_pt kept handing the
// ladder the same dead stack (evidence: ddimension/wwand#30). A fake modem side
// that knows which CIDs it has handed out, and can forget them all.
import * as qmux_c from 'wwand/codec/qmux.uc';
import * as tlv_c from 'wwand/codec/tlv.uc';

function passthrough_modem() {
	let pm = { valid: {}, next: 20, sync: 0, calls: [] };
	let ok_result = struct.pack('<BHHH', 0x02, 4, 0, 0);

	pm.command_raw = function(su, cid, frame, cb, opts) {
		let d = qmux_c.decode(frame);

		push(pm.calls, [ d.service, d.msg_id, d.cid ]);

		let answer = (msg, obj) => uloop.timer(0, () => cb(null,
			qmux_c.encode(d.service, d.cid, d.txn, msg.id, ok_result + tlv_c.pack(msg.resp ?? {}, obj ?? {}), 'response')));

		if (d.service == 0) {
			let ctl = ctlmod.default.messages;

			if (d.msg_id == 0x0027) { pm.sync++; return; }
			if (d.msg_id == ctl.GET_VERSION_INFO.id && pm.hold) {
				push(pm.held, () => pm.refuse
					? cb({ error: 'mbim', status: 2 })
					: answer(ctl.GET_VERSION_INFO, { services: [ { service: 3, major: 1, minor: 25 } ] }));
				return;
			}
			if (d.msg_id == ctl.GET_VERSION_INFO.id && pm.refuse)
				return uloop.timer(0, () => cb({ error: 'mbim', status: 2 }));
			if (d.msg_id == ctl.GET_VERSION_INFO.id)
				return answer(ctl.GET_VERSION_INFO, { services: [ { service: 3, major: 1, minor: 25 } ] });
			if (d.msg_id == ctl.ALLOCATE_CID.id) {
				let a = tlv_c.unpack(ctl.ALLOCATE_CID.req, d.tlvs);
				let c = pm.next++;

				pm.valid[sprintf('%d:%d', a.service, c)] = true;
				return answer(ctl.ALLOCATE_CID, { allocation: { service: a.service, cid: c } });
			}
			if (d.msg_id == ctl.RELEASE_CID.id)
				return uloop.timer(0, () => cb({ error: 'mbim', status: 2 }));
		}

		// a client the modem does not know: MBIM_STATUS_FAILURE, as on the RM520N
		if (!pm.valid[sprintf('%d:%d', d.service, d.cid)])
			return uloop.timer(0, () => cb({ error: 'mbim', status: 2 }));

		if (pm.swallow)
			return;   // a request the modem never answers: it stays pending

		answer(nasmod.default.messages.GET_SIGNAL_INFO,
			{ lte_signal: { rssi: -60, rsrq: -10, rsrp: -90, snr: 100 } });
	};
	pm.ons = 0;
	pm.on = function() { pm.ons++; };
	pm.destroy = function() {};
	pm.forget = () => { pm.valid = {}; };
	pm.refuse = false;   // GET_VERSION_INFO refused: a stack caught mid-reset
	pm.hold = false;     // GET_VERSION_INFO answered only when released
	pm.held = [];
	pm.swallow = false;  // NAS requests never answered
	pm.count = (svc, id) => length(filter(pm.calls, (c) => c[0] == svc && c[1] == id));

	return pm;
}

function assert_stale_passthrough_is_rebuilt() {
	let logs = [];
	let m = modem_mbim.create({
		id: 'pt-stale', device: '/dev/mock-pt', config: {},
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		deps: { log: (lvl, msg) => push(logs, msg), on_event: () => null },
	});
	let pm = passthrough_modem();

	m.mbim = pm;

	let first_cid = null, sig = [];
	let step;

	let ask;
	ask = (n, done) => {
		if (n == 0)
			return done();

		m.pt.nas.request('GET_SIGNAL_INFO', {}, (e) => { push(sig, e == null); ask(n - 1, done); },
			{ no_recovery: true });
	};

	step = [
		// the first bring-up
		(next) => m._ensure_pt((up) => {
			eq(up, true, 'pt-stale: the passthrough comes up');
			first_cid = m.pt?.nas?.cid;
			next();
		}),
		// the modem forgets its clients; one failure alone changes nothing
		(next) => {
			pm.forget();
			ask(1, () => m._ensure_pt((up) => {
				eq(m.pt?.nas?.cid, first_cid, 'pt-stale: a single failure keeps the stack');
				next();
			}));
		},
		// failures that an answer interrupts are not a dead stack: an answered
		// request resets the count, and four failures after it keep the stack
		(next) => {

			pm.valid[sprintf('%d:%d', 3, first_cid)] = true;
			sig = [];
			ask(1, () => {
				pm.forget();
				ask(4, () => m._ensure_pt(() => {
					eq(m.pt?.nas?.cid, first_cid, 'pt-stale: an answer in between resets the count');
					sig = [];
					next();
				}));
			});
		},
		// nothing gets through any more: the next ensure rebuilds
		(next) => ask(4, () => {
			eq(sig, [ false, false, false, false ], 'pt-stale: every request fails against forgotten clients');
			m.uim = { cid: 99, service: 11, destroy: () => null };
			// a rebuild caught mid-reset fails, and must not write the
			// passthrough off for good
			pm.refuse = true;
			m._ensure_pt((up0) => {
			eq(up0, false, 'pt-stale: a rebuild the modem refuses fails');
			ok(!m._pt_failed, 'pt-stale: ...without writing the passthrough off');
			pm.refuse = false;
			m._ensure_pt((up) => {
				eq(up, true, 'pt-stale: the rebuilt passthrough is up');
				ok(m.pt?.nas?.cid != null && m.pt.nas.cid != first_cid, 'pt-stale: with a freshly allocated NAS client');
				eq(m.uim, null, 'pt-stale: a client of the dead stack goes with it');
				ok(!m._pt_failed, 'pt-stale: and the passthrough is not written off');
				ok(length(filter(logs, (l) => index(l, 'rebuilding its QMI clients') >= 0)) == 1,
					'pt-stale: the rebuild is logged');
				// the default log keeps notices: when QMI went away and what the
				// modem answered, once per run rather than per request
				let runs = length(filter(logs, (l) => index(l, 'passthrough request failed (svc 3 msg 0x004f') >= 0));
				let errs = length(filter(logs, (l) => index(l, 'passthrough error ') >= 0));
				ok(runs >= 1 && runs * 4 < errs,
					'pt-stale: the first failure of a run is a notice naming the request — once per run, not per request');
				eq(length(filter(logs, (l) => index(l, 'passthrough rebuilt — QMI answering again') >= 0)), 1,
					'pt-stale: ...and the rebuild that took is logged, not only the attempt');
				ok(length(filter(logs, (l) => index(l, 'rebuilding the passthrough failed') >= 0)) == 1,
					'pt-stale: as is the one that did not');
				next();
			});
			});
		}),
		// a cached client on a stack that stopped answering is not handed out:
		// _ensure_uim goes through the rebuild and allocates a new one
		(next) => {
			let cid_before = m.pt.nas.cid;

			pm.forget();
			ask(5, () => {
				m.uim = { cid: 98, service: 11, destroy: () => null };
				m._ensure_uim((u) => {
					ok(u != null && u.cid != 98, 'pt-stale: _ensure_uim does not hand out the dead stack\'s client');
					ok(m.pt?.nas?.cid != cid_before, 'pt-stale: ...it went through the rebuild');
					next();
				});
			});
		},
		(next) => {
			sig = [];
			ask(1, () => {
				eq(sig, [ true ], 'pt-stale: requests are answered again');
				eq(pm.sync, 0, 'pt-stale: no CTL SYNC ever reached the modem');
				next();
			});
		},
	];

	let run_step;
	run_step = (i) => (i < length(step)) ? step[i](() => run_step(i + 1)) : uloop.end();
	run_step(0);
	uloop.run();
}

assert_stale_passthrough_is_rebuilt();

// ...and the bring-up is one, however many callers arrive while it runs: every
// probe of a telemetry tick can reach _ensure_pt before the first finishes, and
// each running its own would allocate CIDs of which only the last stay
// reachable. A callback of the stack being dropped that asks again (destroy()
// pays pending callbacks synchronously) must not start a second one either.
function assert_passthrough_bringup_is_single() {
	let plogs = [];
	let m = modem_mbim.create({
		id: 'pt-single', device: '/dev/mock-pt2', config: {},
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		deps: { log: (lvl, msg) => push(plogs, msg), on_event: () => null },
	});
	let pm = passthrough_modem();
	let ctl = ctlmod.default.messages;
	let answers = [];

	m.mbim = pm;
	pm.hold = true;
	m._ensure_pt((up) => push(answers, up));
	m._ensure_pt((up) => push(answers, up));
	pm.hold = false;

	uloop.timer(5, () => {
		eq(pm.count(0, ctl.GET_VERSION_INFO.id), 1, 'pt-single: two callers, one GET_VERSION_INFO');
		for (let f in pm.held) f();

		uloop.timer(20, () => {
			eq(answers, [ true, true ], 'pt-single: both callers get the one stack');
			eq(pm.count(0, ctl.ALLOCATE_CID.id), 1, 'pt-single: one NAS client allocated, not two');

			// a pending request of the stack being dropped asks again from its
			// cancellation callback
			let reentered = null;

			pm.swallow = true;
			m.pt.nas.request('GET_SIGNAL_INFO', {}, () => {
				m._ensure_pt((up) => { reentered = up; });
			}, { no_recovery: true, timeout: 60000 });
			pm.swallow = false;
			m.pt.shim.failures = 5;

			let versions = pm.count(0, ctl.GET_VERSION_INFO.id);
			let releases = pm.count(0, ctl.RELEASE_CID.id);
			let rebuilt = null;

			m._ensure_pt((up) => { rebuilt = up; });

			uloop.timer(20, () => {
				eq(rebuilt, true, 'pt-single: the rebuild succeeds');
				eq(reentered, true, 'pt-single: the re-entering callback waits for it instead of dropping again');
				eq(pm.count(0, ctl.GET_VERSION_INFO.id) - versions, 1, 'pt-single: one rebuild, not two');
				eq(pm.count(0, ctl.RELEASE_CID.id) - releases, 1,
					'pt-single: the dropped NAS client is released once, not again from the re-entering callback');
				eq(length(filter(plogs, (l) => index(l, 'rebuilding its QMI clients') >= 0)), 1,
					'pt-single: the re-entering callback does not drop the stack a second time');
				uloop.end();
			});
		});
	});
	uloop.run();
}

assert_passthrough_bringup_is_single();

// A modem whose passthrough worked once keeps trying: however many rebuilds a
// stack caught mid-reset refuses, none of them writes the passthrough off
// (a second refusal used to latch it for the session). A teardown during a
// bring-up remembers nothing about the modem either. And a rebuild must not
// leave an indication handler behind: mc.on has no off.
function assert_passthrough_rebuild_edges() {
	let mk = (id) => {
		let m = modem_mbim.create({
			id: id, device: '/dev/' + id, config: {},
			timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
			at: { fx: { read: () => null, glob: () => [] } },
			recovery: { fx: fakefx.create(), state_dir: '/state' },
			deps: { log: () => null, on_event: () => null },
		});
		let pm = passthrough_modem();

		m.mbim = pm;
		return [ m, pm ];
	};
	let seq = [];

	// two refused rebuilds in a row
	let m1_p1 = mk('pt-edge1'), m1 = m1_p1[0], p1 = m1_p1[1];

	push(seq, (next) => m1._ensure_pt(() => {
		p1.forget();
		p1.refuse = true;
		m1.pt.shim.failures = 5;
		m1._ensure_pt((a) => m1._ensure_pt((b) => {
			eq([ a, b ], [ false, false ], 'pt-edge: two rebuilds refused in a row fail');
			ok(!m1._pt_failed, 'pt-edge: ...and the second does not write the passthrough off either');
			p1.refuse = false;
			m1._ensure_pt((c) => {
				eq(c, true, 'pt-edge: the next one, once the modem answers, succeeds');
				eq(p1.ons, 1, 'pt-edge: three bring-ups, one indication handler');
				next();
			});
		}));
	}));

	// a first bring-up that a teardown overtakes: answered after it, and refused after it
	let m2_p2 = mk('pt-edge2'), m2 = m2_p2[0], p2 = m2_p2[1];

	push(seq, (next) => {
		let got = null;

		p2.hold = true;
		m2._ensure_pt((up) => { got = up; });
		p2.hold = false;
		m2.teardown();
		for (let f in p2.held) f();
		p2.held = [];

		uloop.timer(20, () => {
			eq(got, false, 'pt-edge: a bring-up finished after a teardown reports no stack');
			eq(m2.pt, null, 'pt-edge: ...and publishes none into the new session');

			let m3_p3 = mk('pt-edge3'), m3 = m3_p3[0], p3 = m3_p3[1];

			p3.hold = true;
			m3._ensure_pt(() => null);
			p3.hold = false;
			m3.teardown();
			p3.refuse = true;
			for (let f in p3.held) f();

			uloop.timer(20, () => {
				ok(!m3._pt_failed, 'pt-edge: a failure caused by a teardown does not write the passthrough off');
				next();
			});
		});
	});

	// telemetry on a cached 'qmi' rung across a dropped stack: no throw
	let m4_p4 = mk('pt-edge4'), m4 = m4_p4[0], p4 = m4_p4[1];

	push(seq, (next) => m4._ensure_pt(() => {
		m4._dsd_be = 'qmi';
		m4._sig_be = 'qmi';
		p4.forget();
		p4.refuse = true;
		m4.pt.shim.failures = 5;

		let threw = null;

		try {
			m4._refresh_signal(() => {
				ok(true, 'pt-edge: signal on a cached qmi rung completes while the stack is being rebuilt');
				try {
					m4._refresh_data_mode(() => {
						ok(true, 'pt-edge: data mode likewise');
						next();
					});
				} catch (e) { threw = e; next(); }
			});
		} catch (e) { threw = e; next(); }

		uloop.timer(30, () => eq(threw, null, 'pt-edge: telemetry never dereferences a dropped stack'));
	}));

	let run;
	run = (i) => (i < length(seq)) ? seq[i](() => run(i + 1)) : uloop.timer(50, () => uloop.end());
	run(0);
	uloop.run();
}

assert_passthrough_rebuild_edges();

// --- the failure line a human actually reads ---------------------------------
//
// mbim_client hands the command name and the MBIM_STATUS_ERROR to on_error
// (proven in test_mbim_backend); this asserts what modem_mbim then WRITES, and
// it is worth asserting separately because a wrong sprintf produces a line that
// looks fine and says nothing — which is the exact failure this change exists
// to remove. The QMI counterpart is "qmi error (qmi) svc N NAME, counter M"
// (modem.uc); this must read the same way, plus the decoded status.
function assert_error_line_names_the_command() {
	uloop.init();

	let h = handlers();

	// status 21 = MBIM_STATUS_ERROR_INVALID_PARAMETERS (libmbim 1.32.0) — the
	// RM520N-GL answer to a v1-shaped CONNECT while it serves MBIMEx v3
	h.SUBSCRIBER_READY_STATUS = { __error: 21 };
	// a refused ready-state sends init down the PIN path, which the default
	// handler set does not answer — say "no PIN" so the run reaches the
	// assertions instead of dying in the mock
	h.PIN = { pin_type: bc.PIN_TYPE_PIN1, pin_state: bc.PIN_STATE_UNLOCKED,
	          remaining_attempts: 3 };

	let mocke = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: h });
	let lines = [];

	let me = modem_mbim.create({
		id: 'm_errline', device: '/dev/mocke',
		config: { apn: 'internet' },
		timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5,
		          at_drain: 1, card_poll: 5 },
		at: { fx: { read: () => null, glob: () => [] } },
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		datapath: { netdev: 'wwan0', fx: fakefx.create(), mux: 'auto' },
		deps: {
			transport_open: mocke.transport_open,
			log: (level, msg) => push(lines, sprintf('%s %s', level, msg)),
			on_event: () => null,
		},
	});

	me.start();

	uloop.timer(60, () => { me.stop(); uloop.end(); });
	uloop.run();

	let errs = filter(lines, (l) => index(l, 'mbim error') >= 0);

	ok(length(errs) > 0, 'error line: a refused command is logged');

	let l = errs[0] ?? '';

	ok(index(l, 'debug ') == 0, 'error line: at debug, like the QMI counterpart');
	ok(index(l, 'mbim error (mbim)') >= 0, 'error line: names the kind');
	ok(index(l, 'basic_connect/SUBSCRIBER_READY_STATUS') >= 0,
		'error line: names the service and the command');
	ok(index(l, 'status 21 (InvalidParameters)') >= 0,
		'error line: the status, decoded — not a bare number');
	ok(index(l, 'counter ') >= 0, 'error line: and the recovery counter, as QMI does');
	// the formatting trap this guards: an unnamed status must not print the
	// empty parentheses that a naive sprintf would leave behind
	ok(index(l, '()') < 0, 'error line: no empty parentheses anywhere');
}

assert_error_line_names_the_command();

// --- a registration that lands DURING the attach diagnostic must not fail ----
//
// The registration timeout now asks LTE Attach Info (and AT+CEER) before it
// reports the failure, which is the point — but asking costs up to seven
// seconds, and the modem can register inside them. The state test that guards
// the timer is a statement about when it FIRED, not about now, so the callback
// has to look again. Reporting a timeout for a modem that had just registered
// would tear down a working session: a far worse bug than the missing
// diagnostic the query adds. Raised by review, 2026-09-20.
function assert_late_registration_survives_the_diagnostic() {
	uloop.init();

	let h = handlers();

	// never registers on its own — the test drives the indication by hand
	h.REGISTER_STATE = { nw_error: 0, register_state: bc.REGISTER_STATE_SEARCHING,
		register_mode: 1, available_data_classes: 0, current_cellular_class: 1,
		provider_id: '', provider_name: '', roaming_text: '', registration_flag: 0 };

	// ...and the attach query is SWALLOWED, so the callback stays outstanding
	// while the registration arrives. That is the window under test.
	h.LTE_ATTACH_INFO = () => null;   /* answered by nobody: the mock swallows it */

	let mock = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: h });
	let failures = [], states = [];
	let m;

	m = modem_mbim.create({
		id: 'm_latereg', device: '/dev/mocklate',
		config: { apn: 'internet' },
		timing: { settle: 1, reg_timeout: 40, backoff_min: 1000, backoff_max: 1000,
		          at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		datapath: { netdev: 'wwan0', fx: fakefx.create(), mux: 'auto' },
		deps: {
			transport_open: mock.transport_open,
			log: () => null,
			on_event: (mm, event, data) => {
				if (event == 'state')
					push(states, data?.state);
				if (event == 'error')
					push(failures, data?.stage ?? '?');
			},
		},
	});

	m.start();

	// past reg_timeout: the timer has fired and the attach query is in flight
	uloop.timer(90, () => {
		// ...and NOW the network answers. Drive the indication the modem would
		// have received, which takes it out of REGISTERING.
		mock.indicate('REGISTER_STATE', { nw_error: 0,
			register_state: bc.REGISTER_STATE_HOME, register_mode: 1,
			available_data_classes: 0x8000, current_cellular_class: 1,
			provider_id: '26201', provider_name: 'Telekom.de',
			roaming_text: '', registration_flag: 0 });
	});

	// well past the attach query's own budget
	uloop.timer(400, () => { m.stop(); uloop.timer(20, () => uloop.end()); });
	uloop.run();

	eq(length(filter(failures, (f) => f == 'registration_timeout')), 0,
		'late-reg: a registration that lands during the diagnostic is not failed');
	ok(index(states, 'REGISTERING') >= 0, 'late-reg: ...and the modem really did wait in REGISTERING');
}

assert_late_registration_survives_the_diagnostic();

// --- the attach cause comes from AT+CEER when MBIM has none ------------------
//
// And that is the normal case, not the exception: MBIM reports the attach
// STATE reliably and leaves NwError empty on most firmware. An RM520N-GL
// answers this query with `detached` and no cause, which tells a reader
// nothing they could not already see — the status page said "searching" and
// "detached" and stopped there. The modem's own extended error report carries
// the reason; asking for it is the same complementarity regdetail.uc already
// relies on for the registration cause (HW-confirmed with a deliberately wrong
// attach APN: "Requested service option not subscribed", 2026-09-20).
function assert_attach_cause_from_ceer(ceer_line, want_text, want_cause, label) {
	uloop.init();

	let h = handlers();

	// the v3 layout with NwError ZERO — present but saying nothing, which is
	// what the hardware does
	h.LTE_ATTACH_INFO = { lte_attach_state: 0, nw_error: 0, ip_type: 1,
		access_string: 'internet', user_name: '', password: '',
		compression: 0, auth_protocol: 0 };

	let mock = mbim_mockhub.create({ schemas: [ bc, ext ], handlers: h });
	let asked = [], got = null, done_ = false;
	let m;

	m = modem_mbim.create({
		id: 'm_ceer', device: '/dev/mockceer',
		config: { apn: 'internet' },
		timing: { settle: 1, reg_timeout: 5000, backoff_min: 1, backoff_max: 5, at_drain: 1 },
		at: { fx: { read: () => null, glob: () => [] } },
		recovery: { fx: fakefx.create(), state_dir: '/state' },
		datapath: { netdev: 'wwan0', fx: fakefx.create(), mux: 'auto' },
		deps: {
			transport_open: mock.transport_open,
			log: () => null,
			on_event: (mm, event) => {
				if (event != 'registered' || done_)
					return;

				done_ = true;

				// an AT channel that answers CEER and nothing else
				m.at = {
					send: (cmd, cb) => {
						push(asked, cmd);

						return cb(null, { lines: ceer_line ? [ ceer_line ] : [] });
					},
					close: () => null,
				};

				m._read_attach_info((e, info) => {
					got = info;
					uloop.timer(10, () => uloop.end());
				});
			},
		},
	});

	m.start();
	uloop.timer(3000, () => uloop.end());
	uloop.run();

	ok(index(asked, 'AT+CEER') >= 0, label + ': the modem was asked for its error report');
	eq(got?.state_text, 'detached', label + ': the MBIM attach state is kept');
	eq(got?.apn, 'internet', label + ': ...and the profile it used');
	eq(got?.ceer_text, want_text, label + ': the extended error report is recorded');
	eq(got?.nw_error, want_cause, label + ': ...and a numeric cause only when there is one');
}

// free text: stands on its own, no cause invented for it
assert_attach_cause_from_ceer('+CEER: Requested service option not subscribed',
	'Requested service option not subscribed', null, 'ceer/text');

// a cause number in the text maps through the same 3GPP table the registration
// reject uses
assert_attach_cause_from_ceer('+CEER: EMM cause 33', 'EMM cause 33', 33, 'ceer/cause');

// ...and a modem with nothing to say leaves both null rather than inventing
assert_attach_cause_from_ceer(null, null, null, 'ceer/silent');

done('test_modem_mbim');
