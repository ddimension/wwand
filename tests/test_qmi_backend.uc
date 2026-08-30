// wwand tests — QMI telemetry backend (qmi_backend.uc).
//
// The QMI analogue of test_mbim_backend: each telemetry op is driven against a
// real QMI client wired to the mock hub, and the mock answers with a hand-built
// TLV block (the __raw path) in the true on-the-wire layout with libqmi-verified
// tags — NOT a re-encoded decoded object. So the schema's own decode runs: a
// wrong TLV id would decode the field to null and fail the assertion, and the
// normalisation logic (CA carrier shaping, NSA/SA derivation, reject cause,
// sentinel-free packet stats, bearer label) is pinned per function.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as struct from 'struct';
import * as mockhub from './lib/mockhub.uc';
import * as client_mod from 'wwand/client.uc';
import * as backend from 'wwand/qmi_backend.uc';
import * as nasmod from 'wwand/codec/schema/nas.uc';
import * as wdsmod from 'wwand/codec/schema/wds.uc';
import * as dsdmod from 'wwand/codec/schema/dsd.uc';
import * as uimmod from 'wwand/codec/schema/uim.uc';
import * as tlvmod from 'wwand/codec/tlv.uc';
import * as tmdmod from 'wwand/codec/schema/tmd.uc';

uloop.init();

// --- raw TLV builders (independent of the source schema) ---------------------

function u8(v)  { return chr(v & 0xff); }
function u16(v) { return struct.pack('<H', v); }
function u32(v) { return struct.pack('<I', v); }
function u64(v) { return struct.pack('<Q', v); }
function tlv(t, v) { return chr(t) + struct.pack('<H', length(v)) + v; }

const RESULT_OK = tlv(0x02, u16(0) + u16(0));   // QMI success result TLV
let raw = (payload) => ({ __raw: RESULT_OK + payload });

// --- mock wiring: each op reads a mutable response so scenarios can vary ------

let r_ca, r_dsd, r_sysinfo, r_pkt, r_bearer, r_rates;

let mock = mockhub.create({ handlers: {
	GET_LTE_CPHY_CA_INFO:               () => r_ca,
	GET_SYSTEM_STATUS:                  () => r_dsd,     // DSD service 0x2A
	GET_SYSTEM_INFO:                    () => r_sysinfo, // NAS
	GET_PACKET_STATISTICS:              () => r_pkt,     // WDS
	GET_CURRENT_DATA_BEARER_TECHNOLOGY: () => r_bearer,  // WDS
	GET_CHANNEL_RATES:                  () => r_rates,   // WDS
} });

let nas = client_mod.create(mock, nasmod.default, 5, {});
let wds = client_mod.create(mock, wdsmod.default, 6, {});
let dsd = client_mod.create(mock, dsdmod.default, 7, {});

// --- step driver (responses arrive async via uloop) --------------------------

let steps = [], si = 0, run_next;
run_next = () => { if (si >= length(steps)) return uloop.end(); steps[si++](run_next); };

// === get_ca: pcell (t=0x13) + scells array (t=0x15) ===========================
push(steps, (next) => {
	// pcell {pci,earfcn,dl_bandwidth,band}; scells {n, of{pci,earfcn,dl_bw,band,state,cell_index}}
	let pcell = tlv(0x13, u16(100) + u16(1850) + u32(5) + u16(3));
	let scells = tlv(0x15, u8(1) + u16(200) + u16(3200) + u32(3) + u16(7) + u32(2) + u8(1));
	r_ca = raw(pcell + scells);

	backend.get_ca(nas, (ca) => {
		eq(length(ca), 2, 'get_ca: pcell + one scell');
		eq(ca[0], { role: 'PCC', earfcn: 1850, pci: 100, bandwidth_mhz: 20 }, 'get_ca: pcell shaped (bw 5->20MHz)');
		eq(ca[1], { role: 'SCC', earfcn: 3200, pci: 200, bandwidth_mhz: 10, state: 2 }, 'get_ca: scell shaped (bw 3->10MHz, activated)');
		next();
	});
});

// get_ca: no CA TLVs at all -> null
push(steps, (next) => {
	r_ca = raw('');
	backend.get_ca(nas, (ca) => { eq(ca, null, 'get_ca: no pcell/scells -> null'); next(); });
});

// === get_data_mode: DSD available_systems (t=0x10) ============================
push(steps, (next) => {
	// two systems: LTE (rat=3) + 5G (rat=6) -> NSA
	let sys = u8(2) + (u32(0) + u32(dsdmod.RAT_LTE) + u64(0)) + (u32(0) + u32(dsdmod.RAT_5G) + u64(0));
	r_dsd = raw(tlv(0x10, sys));

	backend.get_data_mode(dsd, (m) => {
		eq(m, { mode: 'NSA', lte: true, nr: true }, 'get_data_mode: LTE+5G -> NSA');
		next();
	});
});

// get_data_mode: LTE only -> LTE
push(steps, (next) => {
	r_dsd = raw(tlv(0x10, u8(1) + u32(0) + u32(dsdmod.RAT_LTE) + u64(0)));
	backend.get_data_mode(dsd, (m) => {
		eq(m, { mode: 'LTE', lte: true, nr: false }, 'get_data_mode: LTE only -> LTE');
		next();
	});
});

// get_data_mode: 5G only -> SA
push(steps, (next) => {
	r_dsd = raw(tlv(0x10, u8(1) + u32(0) + u32(dsdmod.RAT_5G) + u64(0)));
	backend.get_data_mode(dsd, (m) => {
		eq(m, { mode: 'SA', lte: false, nr: true }, 'get_data_mode: 5G only -> SA');
		next();
	});
});

// get_data_mode: no systems TLV -> null
push(steps, (next) => {
	r_dsd = raw('');
	backend.get_data_mode(dsd, (m) => { eq(m, null, 'get_data_mode: no available_systems -> null'); next(); });
});

// === get_reg_detail: NAS GET_SYSTEM_INFO (status t=0x14, sys_info t=0x19) =====
push(steps, (next) => {
	let status = tlv(0x14, u8(nasmod.SVC_STATUS_LIMITED) + u8(0));   // limited service
	// lte_sys_info: all the *_valid/value pairs 0, then reject_valid=1 domain=1 cause=15
	let sysinfo = tlv(0x19,
		u8(0) + u8(0) + u8(0) + u8(0) + u8(0) + u8(0) + u8(0) + u8(0) +   // domain/srv_cap/roaming/forbidden
		u8(0) + u16(0) +                                                 // lac_valid, lac
		u8(0) + u32(0) +                                                 // cid_valid, cid
		u8(1) + u8(1) + u8(15));                                         // reject_valid, domain, cause
	r_sysinfo = raw(status + sysinfo);

	backend.get_reg_detail(nas, (d) => {
		eq(d, { source: 'qmi', limited: true, reject_cause: 15, reject_domain: 1 },
			'get_reg_detail: limited + reject cause/domain decoded');
		next();
	});
});

// get_reg_detail: available (status 2), reject_valid=0 -> no reject fields
push(steps, (next) => {
	let status = tlv(0x14, u8(2) + u8(0));   // available
	let sysinfo = tlv(0x19,
		u8(0) + u8(0) + u8(0) + u8(0) + u8(0) + u8(0) + u8(0) + u8(0) +
		u8(0) + u16(0) + u8(0) + u32(0) +
		u8(0) + u8(0) + u8(0));              // reject_valid=0
	r_sysinfo = raw(status + sysinfo);

	backend.get_reg_detail(nas, (d) => {
		eq(d.source, 'qmi', 'get_reg_detail: source qmi');
		eq(d.limited, false, 'get_reg_detail: available -> not limited');
		eq(d.reject_cause, null, 'get_reg_detail: no reject cause when reject_valid=0');
		next();
	});
});

// === get_packet_stats: WDS (rx_packets_ok t=0x11 required) ====================
push(steps, (next) => {
	// tx_packets_ok(0x10), rx_packets_ok(0x11), tx_bytes_ok(0x19,u64), rx_bytes_ok(0x1A,u64)
	let p = tlv(0x10, u32(1000)) + tlv(0x11, u32(2000)) + tlv(0x19, u64(500000)) + tlv(0x1A, u64(900000));
	r_pkt = raw(p);

	backend.get_packet_stats(wds, (d) => {
		ok(d != null, 'get_packet_stats: returns data when rx_packets_ok present');
		eq(d.rx_packets_ok, 2000, 'get_packet_stats: rx_packets_ok decoded');
		eq(d.tx_packets_ok, 1000, 'get_packet_stats: tx_packets_ok decoded');
		eq(d.rx_bytes_ok, 900000, 'get_packet_stats: rx_bytes_ok (u64) decoded');
		next();
	});
});

// get_packet_stats: no rx_packets_ok TLV -> null (the "didn't answer" guard)
push(steps, (next) => {
	r_pkt = raw(tlv(0x10, u32(1000)));   // only tx, no rx_packets_ok
	backend.get_packet_stats(wds, (d) => { eq(d, null, 'get_packet_stats: missing rx_packets_ok -> null'); next(); });
});

// === get_bearer: WDS current (t=0x01) rat_mask label =========================
// RAT_LTE bit 5 = 32, RAT_5GNR bit 10 = 1024
let bearer_case = (mask, want, label) => push(steps, (next) => {
	r_bearer = raw(tlv(0x01, u8(8) + u32(mask) + u32(0)));   // network_type,u8 + rat_mask,u32 + so_mask,u32
	backend.get_bearer(wds, (b) => { eq(b, want, label); next(); });
});
bearer_case(32,   'LTE',       'get_bearer: LTE only');
bearer_case(1024, '5G NR',     'get_bearer: 5G NR only');
bearer_case(1056, 'LTE + 5G',  'get_bearer: LTE + 5G (NSA)');
bearer_case(4,    'other',     'get_bearer: unknown RAT -> other');
bearer_case(0,    null,        'get_bearer: no RAT bits -> null');

// === get_channel_rates: WDS rates (t=0x01) ===================================
push(steps, (next) => {
	r_rates = raw(tlv(0x01, u32(50000) + u32(150000) + u32(75000) + u32(300000)));
	backend.get_channel_rates(wds, (r) => {
		eq(r, { tx_rate: 50000, rx_rate: 150000, max_tx_rate: 75000, max_rx_rate: 300000 },
			'get_channel_rates: current + max tx/rx decoded');
		next();
	});
});

// error path: an errored request -> null (not a throw)
push(steps, (next) => {
	r_rates = { __error: 0x0001 };
	backend.get_channel_rates(wds, (r) => { eq(r, null, 'get_channel_rates: error -> null'); next(); });
});

let guard = uloop.timer(5000, () => { ok(false, 'test_qmi_backend timed out'); uloop.end(); });
run_next();
uloop.run();
guard.cancel();

// QmiNasActiveBand decode (table generated from libqmi 1.38 qmi-enums-nas.h;
// the enum is non-contiguous — EUTRAN_20 is 145, not 139)
eq(nasmod.active_band_name(127), 'LTE B8', 'active band: 127 = LTE B8');
eq(nasmod.active_band_name(145), 'LTE B20', 'active band: 145 = LTE B20 (non-contiguous)');
eq(nasmod.active_band_name(269), 'NR n78', 'active band: 269 = NR n78');
eq(nasmod.active_band_name(45), 'GSM 900', 'active band: 45 = GSM 900');
eq(nasmod.active_band_name(9999), 'band 9999', 'active band: unknown value passthrough');

// --- UIM card diagnostics: the four indications EVENTS_WANTED arms -----------
// Hand-built wire buffers, decoded through the schema itself, because these are
// exactly the decoders where a wrong tag or width produces plausible garbage
// rather than an error. Each was previously invisible: the card would simply
// stop answering and the recovery ladder would count protocol errors at a modem
// that was telling us what was wrong.

let U = uimmod.default.messages;

// SESSION_CLOSED (0x0043). `cause` is FOUR bytes in the IDL even though every
// defined value fits in one — decoding it as u8 would swallow the file_id TLV
// that follows and say nothing about it.
let sc = tlvmod.unpack(U.SESSION_CLOSED_IND.ind,
	tlv(0x01, u8(1)) + tlv(0x11, u8(2)) + tlv(0x12, u8(0)) +
	tlv(0x13, u32(11)) + tlv(0x14, u16(0x6F07)));
eq(sc.slot, 1, 'uim ind: session closed slot');
eq(sc.channel_id, 2, 'uim ind: logical channel id');
eq(sc.cause, 11, 'uim ind: cause decoded from a 4-byte field');
eq(sc.file_id, 0x6F07, 'uim ind: the missing file is named (EF_IMSI)');
eq(uimmod.SESSION_CLOSE_CAUSES[sprintf('%d', sc.cause)], 'mandatory file missing',
	'uim ind: ...and the cause has a name');
eq(uimmod.SESSION_CLOSE_CAUSES['4'], 'card removed', 'uim ind: card removed named');
eq(uimmod.SESSION_CLOSE_CAUSES['7'], 'internal card recovery', 'uim ind: recovery named');

// a session we closed ourselves must not read as a fault
eq(uimmod.SESSION_CLOSE_CAUSES['1'], 'client request', 'uim ind: our own close is named as such');

// SIM_BUSY (0x004A): one byte per slot, array with a u8 count
let sb = tlvmod.unpack(U.SIM_BUSY_STATUS_IND.ind, tlv(0x10, u8(2) + u8(0) + u8(1)));
eq(sb.busy, [ 0, 1 ], 'uim ind: sim busy is per-slot, slot 2 busy');

// RECOVERY (0x0050): the card recovered internally, everything cached is stale
let rc = tlvmod.unpack(U.RECOVERY_IND.ind, tlv(0x01, u8(2)));
eq(rc.slot, 2, 'uim ind: recovery names the slot');

// CARD_ACTIVATION (0x0055): slot 1 byte, status 4 bytes
let ca2 = tlvmod.unpack(U.CARD_ACTIVATION_STATUS_IND.ind,
	tlv(0x01, u8(1)) + tlv(0x02, u32(2)));
eq(ca2.slot, 1, 'uim ind: activation slot');
eq(ca2.status, uimmod.CARD_ACTIVATION_END_FAILURE, 'uim ind: activation failed');
eq(uimmod.CARD_ACTIVATION_STATES['2'], 'failed', 'uim ind: activation state named');

// REFRESH (0x0033) now carries the enforcement mask as well — u64, and reading
// it as u32 would leave four bytes that decode as the head of the next TLV
let rf = tlvmod.unpack(U.REFRESH_IND.ind,
	tlv(0x10, u8(0) + u8(1) + u8(0)) + tlv(0x11, u64(2)));
eq(rf.event.stage, uimmod.REFRESH_STAGE_WAIT_FOR_OK, 'uim ind: refresh asks first');
ok((rf.enforcement & uimmod.REFRESH_ENFORCE_DATA_CALL) != 0,
	'uim ind: ...and says it will interrupt a data call');

// the event mask we actually arm
ok((uimmod.EVENTS_WANTED & uimmod.EVENT_CARD_STATUS) != 0,
	'uim events: card status stays armed (PIN readiness depends on it)');
for (let b in [ uimmod.EVENT_SESSION_CLOSE, uimmod.EVENT_SIM_BUSY,
                uimmod.EVENT_RECOVERY_COMPLETE, uimmod.EVENT_CARD_ACTIVATION ])
	ok((uimmod.EVENTS_WANTED & b) != 0, sprintf('uim events: bit %d armed', b));
eq(uimmod.EVENTS_WANTED & uimmod.EVENT_SAP_CONNECTION, 0,
	'uim events: nothing armed that has no decoder');

// REFRESH_OK exists at the id the open sources attest, with the vote TLV that
// makes it reachable — the pair libqmi models neither half of
eq(U.REFRESH_OK.id, 0x002B, 'uim: refresh-ok message id');
eq(U.REFRESH_REGISTER_ALL.req.vote.t, 0x10, 'uim: vote-for-init is TLV 0x10');

// --- TMD: is the modem throttling itself ------------------------------------
// Everything here is citable from the GPL kernel, and the one wire trap is the
// string encoding: a mitigation device id is a QMI_STRING nested in a struct,
// so it carries a 1-byte length and NO trailing NUL. Reading it as a bare
// string would consume the max_level byte behind it, and the level of a device
// called "pa" would silently become part of its name.
let T = tmdmod.default.messages;
let lstr = (v) => u8(length(v)) + v;

let dl = tlvmod.unpack(T.GET_MITIGATION_DEVICE_LIST.resp,
	tlv(0x10, u8(2) + lstr('pa') + u8(3) + lstr('modem') + u8(4)));
eq(length(dl.devices), 2, 'tmd: both mitigation devices decoded');
eq(dl.devices[0].dev_id, 'pa', 'tmd: nested string carries its own length');
eq(dl.devices[0].max_level, 3, 'tmd: ...and the level behind it survives');
eq(dl.devices[1].dev_id, 'modem', 'tmd: second device id');
eq(dl.devices[1].max_level, 4, 'tmd: second max level');

// current vs requested: they differ while a change is in flight, and a
// persistent gap means the modem declined what was asked of it
let ml = tlvmod.unpack(T.GET_MITIGATION_LEVEL.resp, tlv(0x10, u8(2)) + tlv(0x11, u8(3)));
eq(ml.current, 2, 'tmd: current level');
eq(ml.requested, 3, 'tmd: requested level is a separate field');

// the push
let mi = tlvmod.unpack(T.MITIGATION_LEVEL_REPORT_IND.ind,
	tlv(0x01, lstr('pa')) + tlv(0x02, u8(3)));
eq(mi.device.dev_id, 'pa', 'tmd ind: device id');
eq(mi.level, 3, 'tmd ind: new level');

// the request side has to encode the same way round
let req = tlvmod.pack(T.GET_MITIGATION_LEVEL.req, { device: { dev_id: 'pa' } });
eq(req, tlv(0x01, lstr('pa')), 'tmd: request re-encodes the nested string identically');

eq(tmdmod.default.service, 0x18, 'tmd: service id');
eq(tmdmod.device_label('pa'), 'power amplifier', 'tmd: device labels are readable');
eq(tmdmod.device_label('something_new'), 'something_new',
	'tmd: an unknown device passes through rather than vanishing');

// SET_MITIGATION_LEVEL is deliberately absent — wwand reports thermal state,
// it does not impose it. Pinned so a later "completeness" patch has to argue.
eq(T.SET_MITIGATION_LEVEL, null, 'tmd: wwand never commands mitigation');

done('test_qmi_backend');
