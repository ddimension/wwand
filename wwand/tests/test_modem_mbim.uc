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
import * as struct from 'struct';
import * as mbim_mockhub from './lib/mbim_mockhub.uc';
import * as modem_mbim from 'wwand/modem_mbim.uc';
import * as bc from 'wwand/codec/mbim-schema/basic_connect.uc';
import * as ext from 'wwand/codec/mbim-schema/ms_basic_connect_ext.uc';

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
function build_base_stations() {
	let lte_serv = cell_struct('26201', [ 12345678, 1300, 42, 0x1234, -95, -10, 0 ]);
	let lte_neigh = cell_struct('', [ 0, 1300, 99, 0, -105, -14 ]);
	let nr_serv = nr_serving_struct('26201', 0x0000000100000002, 7, 632448, 0x5678, -80, -11, 25);

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
		REGISTER_STATE: {
			nw_error: 0, register_state: bc.REGISTER_STATE_HOME, register_mode: 1,
			available_data_classes: ext.DATA_CLASS_LTE, current_cellular_class: 1,
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
			{ rsrp: 100, snr: 60, system_type: ext.DATA_CLASS_LTE },    // -56 dBm, 7.0 dB
			{ rsrp: 90,  snr: 80, system_type: ext.DATA_CLASS_5G_SA },  // -66 dBm, 17.0 dB
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

function assert_telemetry() {
	// signal (fast watch loop; native SIGNAL_STATE_V2) — QMI GET_SIGNAL_INFO shape
	ok(modem.signal?.lte != null, 'signal: lte block populated via native backend');
	eq(modem.signal.lte.rssi, -73, 'signal: lte rssi dBm (index 20)');
	eq(modem.signal.lte.rsrp, -56, 'signal: lte rsrp dBm (coded 100)');
	eq(modem.signal.lte.snr, 70, 'signal: lte snr 0.1 dB (coded 60)');
	eq(modem.signal.nr5g?.rsrp, -66, 'signal: nr5g rsrp dBm (coded 90)');

	// cells (fast watch loop; native BASE_STATIONS_INFO) — QMI cell-location shape
	ok(modem.cells?.lte_intra != null, 'cells: lte_intra populated via native backend');
	eq(modem.cells.lte_intra.plmn, '262/01', 'cells: lte plmn');
	eq(modem.cells.lte_intra.earfcn, 1300, 'cells: lte earfcn');
	eq(modem.cells.lte_intra.serving_cell_id, 42, 'cells: lte serving pci');
	eq(length(modem.cells.lte_intra.cells), 2, 'cells: serving + 1 neighbour');
	eq(modem.cells.nr5g_arfcn, 632448, 'cells: nr arfcn');
	eq(modem.cells.nr5g_cell?.pci, 7, 'cells: nr pci');

	// data-system mode (slow tick; native register-state class mask)
	ok(modem.dsd_status != null, 'dsd_status: populated via native backend');
	eq(modem.dsd_status.mode, 'LTE', 'dsd_status: LTE-only class mask -> LTE');
	eq(modem.dsd_status.source, 'mbim', 'dsd_status: sourced from native mbim');

	// registration detail (slow tick; native register state)
	ok(modem.reg_detail != null, 'reg_detail: populated via native backend');
	eq(modem.reg_detail.source, 'mbim', 'reg_detail: source mbim');
	eq(modem.reg_detail.limited, false, 'reg_detail: home registration not limited');

	// the chosen backends settled on native for every capability with one
	ok(modem._sig_be == 'mbim', 'backend: signal chose native mbim');
	ok(modem._cells_be == 'mbim', 'backend: cells chose native mbim');
	ok(modem._dsd_be == 'mbim', 'backend: data_mode chose native mbim');
	ok(modem._regd_be == 'mbim', 'backend: reg_detail chose native mbim');

	finish();
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
			if (event == 'registered') {
				ok(true, 'modem reached READY (OPEN->CAPS->SUBSCRIBER->REGISTER->PACKET_SERVICE)');
				// warm the fast loop (as daemon.modem_signal does), then read back
				// after the fast loop + the first slow telemetry tick have run
				m.watch();
				uloop.timer(1400, assert_telemetry);
			}
		},
	},
});

guard = uloop.timer(6000, () => { ok(false, 'timed out before telemetry populated'); finish(); });
modem.start();

uloop.run();

done('test_modem_mbim');
