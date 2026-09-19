// wwand tests — native-MBIM telemetry backend (mbim_backend.uc).
//
// Drives each backend op against a real mbim_client wired to the MBIM mock hub.
// The array-bearing responses (Base Stations Info, v2 Signal State) use the mock
// __raw path with hand-built InformationBuffers in the true MBIMEx ms-struct /
// ms-struct-array wire layout (encode_info can't produce them), mirroring
// test_mbim.uc build_ipcfg. Each op is asserted to produce the QMI-shaped
// self.signal / self.cells the daemon already renders.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as struct from 'struct';
import * as mbim from 'wwand/codec/mbim.uc';
import * as mbim_client from 'wwand/mbim_client.uc';
import * as mbim_mockhub from './lib/mbim_mockhub.uc';
import * as backend from 'wwand/mbim_backend.uc';
import * as bc from 'wwand/codec/mbim_schema/basic_connect.uc';
import * as ext from 'wwand/codec/mbim_schema/ms_basic_connect_ext.uc';
import * as fibocom from 'wwand/codec/mbim_schema/fibocom.uc';
import * as compal from 'wwand/codec/mbim_schema/compal.uc';

uloop.init();

function p32(v) { return chr(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff); }

// UTF-16LE of an ASCII string (no terminator), plus 4-byte padding
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

// --- InformationBuffer builders ---------------------------------------------

// MBIMEx v2 Signal State: 5 u32 fixed + RsrpSnr ms-struct-array pointer
// (offset,size) at 20 -> [count][ {Rsrp,Snr,RsrpThr,SnrThr,SystemType} x N ].
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

// one MBIMEx variable cell struct: a ProviderId string descriptor (offset+len,
// relative to struct start) then the scalar fields; string data appended.
function cell_struct(provider, scalars) {
	let fixed_len = 8 + length(scalars) * 4;   // provider desc + scalars
	let pstr = provider ? u16le(provider) : '';
	let poff = length(pstr) ? fixed_len : 0;
	let fixed = p32(poff) + p32(length(pstr));
	for (let s in scalars)
		fixed += p32(s);
	return pad4(fixed + pstr);
}

// NR serving struct has a guint64 Nci and a trailing guint64 TimingAdvance
function nr_serving_struct(provider, nci, pci, nrarfcn, tac, rsrp, rsrq, sinr) {
	let fixed_len = 8 + 8 + 4 * 6 + 8;   // provider + nci + 6 u32 + ta(u64) = 48
	let pstr = u16le(provider);
	let fixed = p32(fixed_len) + p32(length(pstr)) +
		struct.pack('<Q', nci) +
		p32(pci) + p32(nrarfcn) + p32(tac) + p32(rsrp) + p32(rsrq) + p32(sinr) +
		struct.pack('<Q', 0);
	return pad4(fixed + pstr);
}

// Base Stations Info (v3): 96-byte fixed part (SystemType, SystemSubType, then
// 11 ms-struct/array pointers) + appended data regions.
function build_base_stations() {
	let lte_serv = cell_struct('26201', [ 12345678, 1300, 42, 0x1234, -95, -10, 0 ]);
	let lte_neigh = cell_struct('', [ 0, 1300, 99, 0, -105, -14 ]);
	let nr_serv = nr_serving_struct('26201', 0x0000000100000002, 7, 632448, 0x5678, -80, -11, 25);

	let base = 96;
	let lte_serv_off = base;
	let lte_neigh_off = lte_serv_off + length(lte_serv);
	let nr_serv_off = lte_neigh_off + 4 + length(lte_neigh);

	// fixed pointer table (offset -> [off,size]); everything else zeroed
	let ptrs = {};
	ptrs[32] = [ lte_serv_off, length(lte_serv) ];          // LteServingCell
	ptrs[64] = [ lte_neigh_off, 4 + length(lte_neigh) ];    // LteNeighboringCells
	ptrs[80] = [ nr_serv_off, 4 + length(nr_serv) ];        // NrServingCells

	let fixed = '';
	for (let off = 0; off < base; off += 4) {
		if (off == 0)      fixed += p32(ext.DATA_CLASS_LTE | ext.DATA_CLASS_5G_SA); // SystemType
		else if (off == 4) fixed += p32(0);                                        // SystemSubType
		else if (ptrs[off]) fixed += p32(ptrs[off][0]) + p32(ptrs[off][1]);        // pointer lo
		else if (ptrs[off - 4]) continue;   // hi word already written by the pair
		else fixed += p32(0);
	}

	let data = lte_serv + p32(1) + lte_neigh + p32(1) + nr_serv;
	return fixed + data;
}

// The same content in the v1 layout: no SystemSubType, so every pointer after
// SystemType sits 4 bytes earlier, and there are no NR arrays at all (libmbim
// 1.32.0, mbim-service-ms-basic-connect-extensions.json vs -v3.json).
function build_base_stations_v1() {
	let lte_serv = cell_struct('26201', [ 12345678, 1300, 42, 0x1234, -95, -10, 0 ]);
	let lte_neigh = cell_struct('', [ 0, 1300, 99, 0, -105, -14 ]);

	let base = 76;   // SystemType + 4 ms-structs + 5 array pointers
	let lte_serv_off = base;
	let lte_neigh_off = lte_serv_off + length(lte_serv);

	let ptrs = {};
	ptrs[28] = [ lte_serv_off, length(lte_serv) ];        // LteServingCell
	ptrs[60] = [ lte_neigh_off, 4 + length(lte_neigh) ];  // LteNeighboringCells

	let fixed = '';
	for (let off = 0; off < base; off += 4) {
		if (off == 0)       fixed += p32(ext.DATA_CLASS_LTE);
		else if (ptrs[off]) fixed += p32(ptrs[off][0]) + p32(ptrs[off][1]);
		else if (ptrs[off - 4]) continue;
		else fixed += p32(0);
	}

	return fixed + lte_serv + p32(1) + lte_neigh;
}

// --- client harness ----------------------------------------------------------

function make_mc(schema, handlers, hooks, opts) {
	let mock = mbim_mockhub.create({ schema: schema, handlers: handlers,
		mbimex_version: opts?.mbimex_version });
	let mc = mbim_client.create(mock, hooks ?? {});
	mock.transport_open('/dev/mock', {
		on_raw: (hub, msg) => { let dec = mbim.decode(msg); if (dec) mc.on_message(dec); },
		on_gone: () => null,
	});
	return mc;
}

// --- no_recovery: an optional tunnel must not vote on the channel's health ----
//
// A vendor CID this firmware does not implement answers a non-success status,
// and mbim_client reported every one of those to the recovery hook. The
// QMI-over-MBIM passthrough is the case that bit: an RM520F-GL answers status 2
// to every request through it, once per telemetry tick, while its MBIM is
// working perfectly — and the ladder counted its way toward a repower and a
// reboot (ddimension/wwand#30).
//
// The mock answers a service/cid it knows no schema for with a non-zero status,
// which is exactly the shape of that firmware's refusal. It answers inline, so
// no timer is needed — and must not be used: the scenario chain below ends the
// uloop, and a timer racing that would simply never fire.
(function() {
	let errs = 0;
	let mc = make_mc([], {}, { on_error: () => { errs++; } });
	let unknown = '00000000-0000-0000-0000-0000000000ff';

	// chained through the REPLY callbacks, not timers: the mock delivers on the
	// next uloop iteration, and a timer would race the uloop.end() the scenario
	// chain below issues — which is how an earlier version of this simply never
	// ran and reported two fewer checks with no failures.
	mc.command_raw(unknown, 1, '', () => {
		eq(errs, 1, 'no_recovery: a plain vendor-CID failure still reports to recovery');

		mc.command_raw(unknown, 1, '', () => {
			eq(errs, 1, 'no_recovery: ...and with the flag it does not');
		}, { no_recovery: true });
	});
})();

// --- scenarios ---------------------------------------------------------------

// get_signal: RSSI index + per-RAT coded RSRP/SNR (LTE + 5G-SA)
function s_signal(next) {
	let sig_schema = { service: bc.service,
		commands: { SIGNAL_STATE_V2: bc.commands.SIGNAL_STATE_V2 } };
	let raw = build_signal(20, [   // rssi 20 -> -73 dBm
		{ rsrp: 100, snr: 60, system_type: ext.DATA_CLASS_LTE },     // -56 dBm, 7.0 dB
		{ rsrp: 90,  snr: 80, system_type: ext.DATA_CLASS_5G_SA },   // -66 dBm, 17.0 dB
	]);
	let mc = make_mc(sig_schema, { SIGNAL_STATE_V2: { __raw: raw } });

	mc.open(() => backend.get_signal(mc, (sig) => {
		ok(sig != null, 'signal: decoded');
		eq(sig.lte.rssi, -73, 'signal: lte rssi dBm (index 20)');
		eq(sig.lte.rsrp, -56, 'signal: lte rsrp dBm (coded 100)');
		eq(sig.lte.snr, 70, 'signal: lte snr 0.1 dB (coded 60)');
		eq(sig.lte.rsrq, null, 'signal: lte rsrq absent in MBIM v2');
		eq(sig.nr5g.rsrp, -66, 'signal: nr5g rsrp dBm (coded 90)');
		eq(sig.nr5g.snr, 170, 'signal: nr5g snr 0.1 dB (coded 80)');
		next();
	}));
}

// A RESPONSE LARGER THAN MaxControlTransfer ARRIVES IN FRAGMENTS.
//
// The codec skipped the 8-byte fragment header unread, so fragment 0 was handed
// up as the whole answer and every continuation — which carries only the
// message and fragment headers plus more InformationBuffer, no uuid/cid/status
// — was parsed as though those 24 bytes were a service uuid and a cid. Nothing
// errored; the data was simply short. An SMS read-all on a SIM holding enough
// PDUs lost its tail. Found by a full review, 2026-09-19.
function s_fragments(next) {
	// the handler swallows the command, so the request stays pending and we
	// can deliver the answer ourselves, in pieces
	let mc = make_mc(bc, { PACKET_SERVICE: () => null });

	let frag = (txn, total, idx, body) => {
		let payload = struct.pack('<II', total, idx) + body;

		return struct.pack('<III', mbim.MSG_COMMAND_DONE, 12 + length(payload), txn) + payload;
	};

	mc.open(() => {
		let head = '';
		for (let i = 0; i < 40; i++) head += 'A';
		let tail = '';
		for (let i = 0; i < 24; i++) tail += 'B';

		let txn = mc.next_txn;

		mc.command(bc, 'PACKET_SERVICE', 'query', {}, (err, data, info) => {
			eq(err, null, 'frag: the reassembled answer is delivered');
			eq(length(info), length(head) + length(tail),
				'frag: both fragments are in the information buffer');
			eq(substr(info, length(head)), tail,
				'frag: the continuation is appended, not parsed as its own message');
			next();
		});

		// fragment 0: full header, declaring the TOTAL information length
		mc.on_message(mbim.decode(frag(txn, 2, 0,
			mbim.uuid_bytes(bc.service) + struct.pack('<III', 3 /* cid */, 0 /* status */,
				length(head) + length(tail)) + head)));

		// AN OUT-OF-ORDER FRAGMENT MUST NOT COMPLETE THE SET. Counting
		// arrivals rather than checking the index meant fragment 2 arriving
		// where 1 was due still satisfied the total — the answer completed
		// with the wrong bytes, in arrival order. Raised by Codex review,
		// 2026-09-19.
		mc.on_message(mbim.decode(frag(txn, 2, 2, 'XX')));   // 1 was due

		// that dropped the set, so a fresh fragment 0 starts it over
		mc.on_message(mbim.decode(frag(txn, 2, 0,
			mbim.uuid_bytes(bc.service) + struct.pack('<III', 3, 0,
				length(head) + length(tail)) + head)));

		// fragment 1: headers and the rest of the buffer, nothing else
		mc.on_message(mbim.decode(frag(txn, 2, 1, tail)));
	});
}

// A DEVICE THAT DID NEGOTIATE v3 IS DECODED WITH THE v3 LAYOUT — which is
// not what wwand ships (it requests nothing), but the layout code is here for
// whoever ports that generation, so it stays covered.
//
// Nothing tells the modem the host speaks MBIMEx — deliberately, since v3
// redefines Connect and three more CIDs this client does not implement
// (mbim_client.open()) — so a spec-conforming device answers v1. And v1 has no
// SystemSubType, putting every ms-struct pointer 4 bytes earlier than the v3
// layout wwand used to decode unconditionally. That does not fail: the bounds
// checks absorb it and wwand publishes FABRICATED serving-cell PCI/TAC/RSRP
// into telemetry and LuCI. `mbimex_version` is what settles it, and without a
// request it stays 0. Found by a full review, 2026-09-19.
function s_cells_v3(next) {
	let mc = make_mc(ext, { BASE_STATIONS_INFO: { __raw: build_base_stations() } });

	mc.open(() => {
		// wwand requests no version (v3 redefines Connect and three more CIDs
		// it does not implement — see mbim_client.open()), so this is set by
		// hand: the layout code stays covered for whoever ports that generation.
		mc.mbimex_version = 0x0300;

		backend.get_cells(mc, (cells) => {
			ok(cells != null, 'cells v3: decoded');
			eq(cells.lte_intra?.serving_cell_id, 42, 'cells v3: serving pci');
			eq(cells.lte_intra?.tac, 0x1234, 'cells v3: tac');
			eq(cells.lte_intra?.earfcn, 1300, 'cells v3: earfcn');
			eq(cells.lte_intra?.cells[0]?.rsrp, -950, 'cells v3: rsrp');
			eq(length(cells.lte_intra?.cells ?? []), 2, 'cells v3: serving + 1 neighbour');
			eq(cells.nr5g_arfcn, 632448, 'cells v3: ...and the NR arrays the v1 layout does not have');
			eq(cells.nr5g_cell?.pci, 7, 'cells v3: nr pci');
			next();
		});
	});
}

// get_cells: LTE serving + 1 neighbour + NR serving
function s_cells(next) {
	// THE DEFAULT IS v1, because wwand asks for no MBIMEx version — see the
	// comment in mbim_client.open(). A host that negotiates nothing gets the
	// v1 layouts, and decoding those is the whole of what finding 24 needed.
	let mc = make_mc(ext, { BASE_STATIONS_INFO: { __raw: build_base_stations_v1() } });

	mc.open(() => backend.get_cells(mc, (cells) => {
		eq(mc.mbimex_version, 0, 'cells: nothing was negotiated, so v1 applies');
		ok(cells != null, 'cells: decoded');
		let li = cells.lte_intra;
		eq(li.plmn, '262/01', 'cells: lte plmn from provider id');
		eq(li.tac, 0x1234, 'cells: lte tac');
		eq(li.global_cell_id, 12345678, 'cells: lte global cell id');
		eq(li.earfcn, 1300, 'cells: lte earfcn');
		eq(li.serving_cell_id, 42, 'cells: lte serving pci');
		eq(length(li.cells), 2, 'cells: serving + 1 neighbour');
		eq(li.cells[0].pci, 42, 'cells: serving cell pci');
		eq(li.cells[0].rsrp, -950, 'cells: serving rsrp 0.1 dB (x10)');
		eq(li.cells[0].rsrq, -100, 'cells: serving rsrq 0.1 dB (x10)');
		eq(li.cells[0].rssi, null, 'cells: rssi unavailable in MBIM');
		eq(li.cells[1].pci, 99, 'cells: neighbour pci');
		eq(li.cells[1].rsrp, -1050, 'cells: neighbour rsrp 0.1 dB');
		// the v1 layout has no NR arrays at all — the v3 case below covers those
		eq(cells.nr5g_cell, null, 'cells: no NR cell in the v1 layout');
		eq(cells.nr5g_arfcn, null, 'cells: ...and no NR arfcn either');
		next();
	}));
}

// get_data_mode: register-state data-class mask -> LTE / NSA / SA
function reg_state(data_classes) {
	return {
		nw_error: 0, register_state: 3, register_mode: 1,
		available_data_classes: data_classes, current_cellular_class: 1,
		provider_id: '26201', provider_name: 'Telekom.de',
		roaming_text: '', registration_flag: 0,
	};
}

function s_data_mode(next) {
	let dc_nsa = ext.DATA_CLASS_LTE | ext.DATA_CLASS_5G_NSA;
	let mc = make_mc(bc, { REGISTER_STATE: reg_state(dc_nsa) });

	mc.open(() => backend.get_data_mode(mc, (dm) => {
		eq(dm.mode, 'NSA', 'data_mode: LTE+NR -> NSA');
		eq(dm.lte, true, 'data_mode: nsa lte flag');
		eq(dm.nr, true, 'data_mode: nsa nr flag');

		let mc2 = make_mc(bc, { REGISTER_STATE: reg_state(ext.DATA_CLASS_5G_SA) });
		mc2.open(() => backend.get_data_mode(mc2, (dm2) => {
			eq(dm2.mode, 'SA', 'data_mode: NR only -> SA');
			eq(dm2.lte, false, 'data_mode: sa lte flag');

			let mc3 = make_mc(bc, { REGISTER_STATE: reg_state(ext.DATA_CLASS_LTE) });
			mc3.open(() => backend.get_data_mode(mc3, (dm3) => {
				eq(dm3.mode, 'LTE', 'data_mode: LTE only -> LTE');
				eq(dm3.nr, false, 'data_mode: lte nr flag');

				// NO MODE IS NOT A MODE. An object with `mode: null` is truthy,
				// so it reads as a successful answer, the chosen backend keeps
				// the choice it won, and the RAT stays unknown forever — while
				// the rung below could have read it off the serving cell.
				//
				// CUSTOM alone is the case that reached the field: libmbim's
				// name for a class that is proprietary or not in the enum, which
				// some modems report for 5G when the extensions were never
				// negotiated. An RM520F-GL carried NR5G-SA while reporting
				// exactly 0x80000000, and wwand showed no RAT (wwand#30).
				let mc4 = make_mc(bc, { REGISTER_STATE: reg_state(ext.DATA_CLASS_CUSTOM) });
				mc4.open(() => backend.get_data_mode(mc4, (dm4) => {
					eq(dm4, null, 'data_mode: CUSTOM alone says nothing, so it answers nothing');

					// a mask with no known RAT bit at all reads the same way
					let mc5 = make_mc(bc, { REGISTER_STATE: reg_state(1 << 2) });
					mc5.open(() => backend.get_data_mode(mc5, (dm5) => {
						eq(dm5, null, 'data_mode: ...and so does any mask carrying no RAT we know');

						// a mask that carries CUSTOM BESIDE a real class is still
						// a real answer — CUSTOM is not poison, it is silence
						let mc6 = make_mc(bc, {
							REGISTER_STATE: reg_state(ext.DATA_CLASS_CUSTOM | ext.DATA_CLASS_5G_SA) });
						mc6.open(() => backend.get_data_mode(mc6, (dm6) => {
							eq(dm6?.mode, 'SA', 'data_mode: CUSTOM alongside a known class does not hide it');
							next();
						}));
					}));
				}));
			}));
		}));
	}));
}

// get_reg_detail: reject cause + limited service from a denied registration
function s_reg_detail(next) {
	let denied = reg_state(0);
	denied.register_state = bc.REGISTER_STATE_DENIED;   // 6
	denied.nw_error = 33;                                // service option not subscribed
	let mc = make_mc(bc, { REGISTER_STATE: denied });

	mc.open(() => backend.get_reg_detail(mc, (rd) => {
		ok(rd != null, 'reg_detail: decoded');
		eq(rd.source, 'mbim', 'reg_detail: source mbim');
		eq(rd.reject_cause, 33, 'reg_detail: nw_error -> reject cause');
		eq(rd.limited, true, 'reg_detail: denied -> limited service');
		next();
	}));
}

// multi-slot: SYS_CAPS count -> DEVICE_SLOT_MAPPINGS active -> per-slot
// SLOT_INFO_STATUS; then a slot switch whose raw SET must carry the exact
// ref-struct-array layout (MapCount + [offset,size] pair + MbimSlot struct).
function s_slots(next) {
	let mock = mbim_mockhub.create({ schema: ext, handlers: {
		SYS_CAPS: { number_of_executors: 1, number_of_slots: 2, concurrency: 1, modem_id: 0 },
		// query: MapCount=1, ref pair [offset=12,size=4], MbimSlot{Slot=0}
		DEVICE_SLOT_MAPPINGS: (args, meta) =>
			(meta.kind == 'set') ? {} : { __raw: p32(1) + p32(12) + p32(4) + p32(0) },
		// slot 0: eSIM with active profile (7); slot 1: plain active card (5)
		SLOT_INFO_STATUS: (args) => ({ slot_index: args.slot_index, state: args.slot_index ? 5 : 7 }),
	} });
	let mc = mbim_client.create(mock, {});
	mock.transport_open('/dev/mock', {
		on_raw: (hub, msg) => { let dec = mbim.decode(msg); if (dec) mc.on_message(dec); },
		on_gone: () => null,
	});

	mc.open(() => backend.slot_status(mc, (err, slots) => {
		eq(err, null, 'slots: no error');
		eq(length(slots), 2, 'slots: SYS_CAPS slot count');
		eq(slots[0], { physical: 1, card: 'present', active: true, logical_slot: 1,
			iccid: null, is_euicc: true, eid: null }, 'slots: slot 1 = active eSIM (state 7)');
		eq(slots[1], { physical: 2, card: 'present', active: false, logical_slot: null,
			iccid: null, is_euicc: false, eid: null }, 'slots: slot 2 = inactive plain card (state 5)');

		backend.slot_switch(mc, 1, (serr, sres) => {
			ok(sres?.unchanged, 'slot-switch: active slot -> unchanged, no SET sent');

			backend.slot_switch(mc, 2, (serr2) => {
				eq(serr2, null, 'slot-switch: SET ok');

				let sets = filter(mock.calls_for('DEVICE_SLOT_MAPPINGS'), (c) => c.kind == 'set');
				eq(length(sets), 1, 'slot-switch: exactly one SET');
				eq(sets[0].info, p32(1) + p32(12) + p32(4) + p32(1),
					'slot-switch: MapCount=1 + [off=12,size=4] + slot index 1');
				next();
			});
		});
	}));
}

// AT over MBIM: Fibocom vendor CID tunnels a raw AT line as a SET; the reply
// blob parses into the same `lines` the tty engine yields (echo + OK stripped),
// and an ERROR reply surfaces as an error.
function s_at_over_mbim(next) {
	let mock = mbim_mockhub.create({ schema: fibocom, handlers: {
		AT_COMMAND: (args, meta) =>
			(meta.count == 1) ? { __raw: "\r\nFibocom Wireless\r\n\r\nOK\r\n" }
			                  : { __raw: "\r\nERROR\r\n" },
	} });
	let mc = mbim_client.create(mock, {});
	mock.transport_open('/dev/mock', {
		on_raw: (hub, msg) => { let dec = mbim.decode(msg); if (dec) mc.on_message(dec); },
		on_gone: () => null,
	});

	mc.open(() => {
		let eng = backend.make_at_engine(mc, 'fibocom');

		eng.send('AT+CGMI', (err, res) => {
			eq(err, null, 'at-mbim: CGMI ok');
			eq(res.lines, [ 'Fibocom Wireless' ], 'at-mbim: reply lines (echo + OK stripped)');

			let c = mock.calls_for('AT_COMMAND')[0];
			eq(c.kind, 'set', 'at-mbim: Fibocom issues a SET');
			eq(c.info, "AT+CGMI\r", 'at-mbim: request is the CR-terminated AT line');

			eng.send('AT+BOGUS', (err2) => {
				eq(err2, { error: 'ERROR' }, 'at-mbim: ERROR reply surfaces as an error');
				next();
			});
		});
	});
}

// AT over MBIM (Compal): same engine, but the vendor CID is a QUERY.
function s_at_over_mbim_compal(next) {
	let mock = mbim_mockhub.create({ schema: compal, handlers: {
		AT_COMMAND: { __raw: "\r\n+CGMI: Compal\r\n\r\nOK\r\n" },
	} });
	let mc = mbim_client.create(mock, {});
	mock.transport_open('/dev/mock', {
		on_raw: (hub, msg) => { let dec = mbim.decode(msg); if (dec) mc.on_message(dec); },
		on_gone: () => null,
	});

	mc.open(() => {
		let eng = backend.make_at_engine(mc, 'compal');

		eng.send('AT+CGMI', (err, res) => {
			eq(err, null, 'at-mbim compal: ok');
			eq(res.lines, [ '+CGMI: Compal' ], 'at-mbim compal: reply line');
			eq(mock.calls_for('AT_COMMAND')[0].kind, 'query', 'at-mbim compal: issues a QUERY');
			next();
		});
	});
}

// --- runner ------------------------------------------------------------------

let scenarios = [ s_signal, s_cells, s_cells_v3, s_fragments, s_data_mode, s_reg_detail, s_slots,
	s_at_over_mbim, s_at_over_mbim_compal ];
let i = 0;

function run_next() {
	if (i >= length(scenarios)) {
		uloop.end();
		return;
	}
	scenarios[i++](run_next);
}

let guard = uloop.timer(3000, () => { ok(false, 'timed out'); uloop.end(); });

run_next();
uloop.run();
guard.cancel();

// --- native MBIM MS UICC Low Level Access (eSIM/APDU) ------------------------
// direct command_raw mock: capture the request InformationBuffer, return a canned
// response buffer, and assert both the encoded request and the decoded result.
function h2b(h) { let o = ''; for (let i = 0; i + 1 < length(h); i += 2) o += chr(hex(substr(h, i, 2))); return o; }
function mkuicc(resp_for) {
	return { last: null,
		command_raw: function(svc, cid, info, cb) { this.last = { svc: svc, cid: cid, info: info }; cb(null, resp_for(cid, info)); } };
}

// OPEN_CHANNEL: request layout [len, offset=16, p2=0, group=1] + AppId
let aid = 'a0000005591010ffffffff8900000100';   // ISD-R (16 bytes)
// response [status=0, channel=3, respLen=3, respOff=16] + 3 select bytes
let openc = mkuicc((cid, info) => p32(0) + p32(3) + p32(3) + p32(16) + h2b('6f5aa5'));
backend.uicc_open_channel(openc, aid, (err, r) => {
	ok(!err, 'uicc-open: no error');
	eq(openc.last.cid, 2, 'uicc-open: CID 2');
	eq(openc.last.info, p32(16) + p32(16) + p32(0) + p32(1) + h2b(aid), 'uicc-open: request buffer [len,off=16,p2=0,grp=1]+aid');
	eq(r.channel, 3, 'uicc-open: channel from response');
	eq(r.select_response, '6f5aa5', 'uicc-open: select response bytes');
});

// APDU: request [channel, secure=0, class=1, len, offset=20] + command; the
// response status is the SW word (0x0090 == SW 90 00), appended as SW1 SW2.
let apducmd = '80e2910006bf3e035c015a';   // an ES10 STORE DATA-ish command
// MBIM status word 0x0090 == card SW1SW2 "90 00" (SW1 low byte, SW2 high byte)
let apduc = mkuicc((cid, info) => p32(0x0090) + p32(2) + p32(12) + h2b('abcd'));
backend.uicc_apdu(apduc, 3, apducmd, (err, resp) => {
	ok(!err, 'uicc-apdu: no error');
	eq(apduc.last.cid, 4, 'uicc-apdu: CID 4');
	let cmd = h2b(apducmd);
	eq(substr(apduc.last.info, 0, 20), p32(3) + p32(0) + p32(1) + p32(length(cmd)) + p32(20), 'uicc-apdu: fixed header');
	eq(substr(apduc.last.info, 20, length(cmd)), cmd, 'uicc-apdu: command bytes appended');
	eq(resp, 'abcd9000', 'uicc-apdu: data + SW1SW2 (status word 9000)');
});

// CLOSE_CHANNEL: [channel, group=1]
let closec = mkuicc(() => p32(0));
backend.uicc_close_channel(closec, 3, (err) => {
	ok(!err, 'uicc-close: no error');
	eq(closec.last.cid, 3, 'uicc-close: CID 3');
	eq(closec.last.info, p32(3) + p32(1), 'uicc-close: [channel,group=1]');
});

// RESET (CID 6): [PassThroughAction=0 (disable)] — the SIM hot-reset "apply"
// after an eSIM profile switch on pure-MBIM firmware
let resetc = mkuicc(() => p32(1));
backend.uicc_reset(resetc, (err) => {
	ok(!err, 'uicc-reset: no error');
	eq(resetc.last.cid, 6, 'uicc-reset: CID 6');
	eq(resetc.last.info, p32(0), 'uicc-reset: [passthrough=disable]');
});

// --- native MBIM SMS Read parsing (layout confirmed on the EG06) ------------
// Response: Format(u32) MessagesCount(u32), then N [offset,size] ref pairs, each
// to a record { index, status, pduOffset, pduSize }; PDU bytes at pduOffset.
(function () {
	let PDU = '000402912100002010100000000002e834';   // gsm7 "hi"
	let pdu_bytes = '';
	for (let i = 0; i < length(PDU); i += 2)
		pdu_bytes += chr(hex(substr(PDU, i, 2)));

	// [0..8] format=0,count=1 ; [8..16] pair(recOff=16,recSize=16) ;
	// [16..32] record(index=5,status=1,pduOff=32,pduSize=17) ; [32..] pdu
	let resp = p32(0) + p32(1) + p32(16) + p32(16) +
		p32(5) + p32(1) + p32(32) + p32(length(pdu_bytes)) + pdu_bytes;

	let seen = null;
	let fake_mc = { command_raw: (uuid, cid, info, cb) => { seen = { uuid, cid, info }; cb(null, resp); } };

	backend.sms_read_all(fake_mc, (err, recs) => {
		eq(err, null, 'sms-read: no error');
		eq(seen.cid, 2, 'sms-read: CID 2 (SMS Read)');
		eq(seen.info, p32(0) + p32(0) + p32(0), 'sms-read: query [PDU,ALL,index0]');
		eq(length(recs), 1, 'sms-read: one record');
		eq(recs[0].index, 5, 'sms-read: message index');
		eq(recs[0].status, 1, 'sms-read: message status');
		eq(recs[0].pdu, PDU, 'sms-read: extracted PDU hex');
	});

	// delete by index -> CID 4, [flag=INDEX(1), index]
	let delseen = null;
	backend.sms_delete({ command_raw: (u, c, i, cb) => { delseen = { c, i }; cb(null); } }, 7, () => {});
	eq(delseen.c, 4, 'sms-delete: CID 4');
	eq(delseen.i, p32(1) + p32(7), 'sms-delete: [flag=INDEX, index=7]');
})();

// --- MS BCE slot CIDs: wire decodes ------------------------------------------
// ref-struct-array response: MapCount=2, pairs at 4/12, 4-byte structs at 20/24
eq(ext.decode_device_slot_mappings(
	p32(2) + p32(20) + p32(4) + p32(24) + p32(4) + p32(1) + p32(0)),
	{ slots: [ 1, 0 ] }, 'slot-mappings: two-executor decode');
eq(ext.decode_device_slot_mappings(p32(0)), { slots: [] }, 'slot-mappings: empty');
// count larger than the buffer: the in-range pair yields null (struct out of
// range), the rest is dropped — no reads past the buffer
eq(ext.decode_device_slot_mappings(p32(3) + p32(28) + p32(4)),
	{ slots: [ null ] }, 'slot-mappings: truncated buffer stays bounded');

// SYS_CAPS with no slots -> clean unsupported, no per-slot queries
backend.slot_status({ command: (schema, name, kind, args, cb) =>
	cb(null, { number_of_executors: 1, number_of_slots: 0 }) }, (err) =>
	eq(err?.error, 'unsupported', 'slots: zero slots -> unsupported'));

// --- LTE ATTACH CONFIG (CID 3): hand-built wire buffers ----------------------
// Verified vs libmbim 1.32 (MbimLteAttachConfiguration / MbimMsSetLteAttachConfig):
// service UUID + CID 3, 44-byte struct head (IpType,Roaming,Source,3×str
// off/size,Compression,AuthProtocol), in-struct string offsets relative to the
// struct start, ref-struct-array offsets relative to the information-buffer start
// (past Operation+Count), each struct DWORD-padded, LE, Operation=0="overwrite".
// APN 'ims' -> UTF-16LE (6 bytes) padded to 8; struct = 44 + 8 = 52 bytes.
const APN16 = "i" + chr(0) + "m" + chr(0) + "s" + chr(0) + chr(0) + chr(0);
// one context struct head (ip_type varies), APN='ims', empty user/pass.
function attach_ctx_bytes(ip_type) {
	return p32(ip_type) + p32(0) + p32(0) +   // ip_type, roaming, source
	       p32(44) + p32(6) +                 // access_string off(=HEAD), size
	       p32(0) + p32(0) +                  // user_name off/size (empty)
	       p32(0) + p32(0) +                  // password off/size (empty)
	       p32(0) + p32(0) +                  // compression, auth_protocol
	       APN16;
}

// encode: single context -> Operation(0)+Count(1)+[off=16,size=52]+struct.
eq(ext.encode_set_lte_attach_config(
	[ { ip_type: 3, roaming: 0, source: 0, access_string: 'ims',
	    user_name: '', password: '', compression: 0, auth_protocol: 0 } ],
	ext.ATTACH_OP_DEFAULT),
	p32(0) + p32(1) + p32(16) + p32(52) + attach_ctx_bytes(3),
	'lte-attach: encode single context');

// encode: real 3-context Set (home/partner/non-partner), Operation defaults to 0.
// ref-array offsets progress 32,84,136 (8+8*3, then +52 each) from buffer start.
eq(ext.encode_set_lte_attach_config([
		{ ip_type: 1, roaming: ext.ROAMING_HOME,        source: ext.CONTEXT_SOURCE_ADMIN, access_string: 'ims' },
		{ ip_type: 1, roaming: ext.ROAMING_PARTNER,     source: ext.CONTEXT_SOURCE_ADMIN, access_string: 'ims' },
		{ ip_type: 1, roaming: ext.ROAMING_NON_PARTNER, source: ext.CONTEXT_SOURCE_ADMIN, access_string: 'ims' },
	]),
	p32(0) + p32(3) +
	p32(32) + p32(52) + p32(84) + p32(52) + p32(136) + p32(52) +
	(p32(1) + p32(0) + p32(0) + p32(44) + p32(6) + p32(0) + p32(0) + p32(0) + p32(0) + p32(0) + p32(0) + APN16) +
	(p32(1) + p32(1) + p32(0) + p32(44) + p32(6) + p32(0) + p32(0) + p32(0) + p32(0) + p32(0) + p32(0) + APN16) +
	(p32(1) + p32(2) + p32(0) + p32(44) + p32(6) + p32(0) + p32(0) + p32(0) + p32(0) + p32(0) + p32(0) + APN16),
	'lte-attach: encode 3-context set (roaming enums, offset progression)');

// decode: INFO buffer (no Operation) Count(1)+[off=12,size=52]+struct.
eq(ext.decode_lte_attach_config(
	p32(1) + p32(12) + p32(52) + attach_ctx_bytes(2)),
	{ contexts: [ { ip_type: 2, roaming: 0, source: 0, access_string: 'ims',
	                user_name: '', password: '', compression: 0, auth_protocol: 0 } ] },
	'lte-attach: decode single context');

eq(ext.decode_lte_attach_config(p32(0)), { contexts: [] }, 'lte-attach: decode empty');

// decode robustness: a pair whose struct runs past the buffer is dropped, no OOB.
eq(ext.decode_lte_attach_config(p32(1) + p32(12) + p32(52)),
	{ contexts: [] }, 'lte-attach: decode truncated struct stays bounded');

// --- on_answer: what counts as "the modem answered MBIM" ---------------------
// The hardware-recovery gate asks whether this endpoint speaks the protocol we
// chose, not whether the command worked. A FUNCTION_ERROR carrying OUR
// transaction id settles that as firmly as a COMMAND_DONE does — the function
// parsed our frame and rejected it — and leaving it out would let a modem that
// answers only function errors stay unarmed for good.
let fe_answers = 0;
let fe_errs = [];
let fec = mbim_client.create({ send_raw: () => true, register: () => null,
	unregister: () => null },
	{ on_answer: () => fe_answers++, on_error: (c, k) => push(fe_errs, k) });

// a pending request, then a function error naming its transaction
let fe_cb = 'unset';
fec.raw_send('', 7, (err) => { fe_cb = err; });
fec.on_message({ type: mbim.MSG_FUNCTION_ERROR, txn: 7, error: 3 });
eq(fe_answers, 1, 'on_answer: a MATCHED function error is the modem answering MBIM');
eq(fe_cb?.error, 'function_error', 'on_answer: the caller still gets its error');

// ...and one that matches nothing is not our modem answering us: it may not
// even be a reply to this client
fec.on_message({ type: mbim.MSG_FUNCTION_ERROR, txn: 4242, error: 3 });
eq(fe_answers, 1, 'on_answer: an UNMATCHED function error arms nothing');

// an indication is unsolicited, and deliberately not counted either — the
// criterion is a frame answering a transaction of ours
fec.on_message({ type: mbim.MSG_INDICATE_STATUS, service: 'x', cid: 1, info: '' });
eq(fe_answers, 1, 'on_answer: an indication is not an answer to anything we asked');

done('test_mbim_backend');
