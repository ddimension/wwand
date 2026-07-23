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
import * as bc from 'wwand/codec/mbim-schema/basic_connect.uc';
import * as ext from 'wwand/codec/mbim-schema/ms_basic_connect_ext.uc';

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

// --- client harness ----------------------------------------------------------

function make_mc(schema, handlers) {
	let mock = mbim_mockhub.create({ schema: schema, handlers: handlers });
	let mc = mbim_client.create(mock, {});
	mock.transport_open('/dev/mock', {
		on_raw: (hub, msg) => { let dec = mbim.decode(msg); if (dec) mc.on_message(dec); },
		on_gone: () => null,
	});
	return mc;
}

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

// get_cells: LTE serving + 1 neighbour + NR serving
function s_cells(next) {
	let mc = make_mc(ext, { BASE_STATIONS_INFO: { __raw: build_base_stations() } });

	mc.open(() => backend.get_cells(mc, (cells) => {
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
		eq(cells.nr5g_arfcn, 632448, 'cells: nr arfcn');
		eq(cells.nr5g_cell.plmn, '262/01', 'cells: nr plmn');
		eq(cells.nr5g_cell.pci, 7, 'cells: nr pci');
		eq(cells.nr5g_cell.global_cell_id, 0x0000000100000002, 'cells: nr nci');
		eq(cells.nr5g_cell.rsrp, -800, 'cells: nr rsrp 0.1 dB');
		eq(cells.nr5g_cell.rsrq, -110, 'cells: nr rsrq 0.1 dB');
		eq(cells.nr5g_cell.snr, 250, 'cells: nr snr 0.1 dB (sinr x10)');
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
				next();
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

// --- runner ------------------------------------------------------------------

let scenarios = [ s_signal, s_cells, s_data_mode, s_reg_detail ];
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

done('test_mbim_backend');
