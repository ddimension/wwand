// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — QMI protocol backend.
//
// The QMI implementations of the protocol-neutral modem/context operations
// defined in docs/backend-interface.md. The state-machine core (modem.uc /
// context.uc) delegates the wire work here so the QMI specifics — service ids,
// CID management, TLV shapes, error codes, codec/schema imports — stay out of
// the lifecycle/policy logic. Each op takes the QMI client(s) it needs plus a
// callback and returns normalized data; it never touches modem `self` state —
// that is what lets MBIM implement the same surface without sharing any of it.

'use strict';

import * as backend from 'wwand.backend';
import * as dmsmod from 'wwand.codec.schema.dms';
import * as dsdmod from 'wwand.codec.schema.dsd';
import * as nasmod from 'wwand.codec.schema.nas';

const OPMODE = {
	online:    dmsmod.OPMODE_ONLINE,
	low_power: dmsmod.OPMODE_LOW_POWER,
	offline:   dmsmod.OPMODE_OFFLINE,
	reset:     dmsmod.OPMODE_RESET,
};

// parse a config `modes` string ('lte,nr5g' / 'all') into the NAS
// mode-preference mask; null for empty/unknown input. Exported because
// config_check.uc must judge a configured value by the same parse.
export function parse_modes(str)
{
	if (str == null || str == '')
		return null;

	if (str == 'all')
		return nasmod.MODE_ALL;

	let mask = 0;

	for (let m in split(str, /[, ]+/)) {
		if (m == '')
			continue;

		let bits = nasmod.MODE_BITS[m];

		if (bits == null)
			return null;   // unknown mode name: refuse to guess

		mask |= bits;
	}

	return mask || null;
};

// set_opmode(dms, mode, cb): mode is 'online'|'low_power'|'offline'|'reset'.
// QMI error 26 ("no effect" — already in that mode) is normalized to success.
//
// EXCEPT FOR 'reset', where there is no such thing as "already in that mode":
// NO_EFFECT there means the modem did NOT reset. Reported as success, every
// caller would believe a reset is under way while the modem sits unchanged —
// the admin reset would claim `resetting: true`, the recovery ladder would count
// a rung it never climbed, and the MBIM passthrough would skip releasing a CID
// it only drops because it expects the reset to wipe the table.
export function set_opmode(dms, mode, cb)
{
	dms.request('SET_OPERATING_MODE', { mode: OPMODE[mode] }, (err) => {
		if (err && err.error == 'qmi' && err.code == 26 && mode != 'reset')
			err = null;

		if (cb)
			cb(err);
	});
};

// FCC authentication (RF unlock): laptop-SKU modems (Lenovo/Dell/HP variants
// of Quectel EM05/EM120/EM160, Foxconn SDX55/SDX62, Dell DW5821e-class) ship
// RF-locked and stay in (persistent) low power until the host sends an FCC
// authentication message. Variants (all verified vs libqmi qmi-service-dms):
//   'dms'      DMS Set FCC Authentication 0x555F, no arguments
//   'foxconn'  DMS Foxconn Set FCC Authentication 0x5571, u8 magic (default 0)
//   'foxconn2' same id, v2 layout: magic string + u8 magic number
// no_recovery: an unsupported message on a regular modem must stay harmless.
export function fcc_auth(dms, variant, magic, cb)
{
	if (variant == 'foxconn')
		return dms.request('FOXCONN_SET_FCC_AUTHENTICATION',
			{ value: magic ?? 0 }, (err) => cb(err), { no_recovery: true });

	if (variant == 'foxconn2')
		return dms.request('FOXCONN_SET_FCC_AUTHENTICATION_V2',
			{ magic_string: magic?.string ?? '', magic_number: magic?.number ?? 0 },
			(err) => cb(err), { no_recovery: true });

	dms.request('SET_FCC_AUTHENTICATION', {}, (err) => cb(err), { no_recovery: true });
};

// THE FOXCONN SDX55 V2 MAGIC, as ModemManager computes it
// (data/dispatcher-fcc-unlock/105b, 1.24.0): "salt" followed by the md5 hex of
// mcfg version without its last two dot fields, apps version, IMEI, "salt",
// "foxc". With "T99W175.F0.1.0.0.9.GC.004" the hashed part starts
// "T99W175.F0.1.0.0.9". `md5`: (string)->32-hex-digest, injected like the
// Fibocom sha256 (fcc_fibocom.uc) so the host suite can check it.
export function foxconn_v2_magic(mcfg, apps, imei, md5)
{
	let fw = replace(sprintf('%s', mcfg), /\.[^.]*\.[^.]*$/, '');

	return 'salt' + substr(md5(fw + apps + imei + 'salt' + 'foxc'), 0, 32);
};

// The Foxconn unlock the way ModemManager's 105b helper runs it over an MBIM
// port: v2 with the magic above and magic number 48, then v1 with 0 when v2
// cannot be built or is refused. `cfg` is `option fcc_auth`: 'foxconn:<n>'
// sends only v1 with n, 'foxconn2:<string>:<number>' only that v2. `imei`
// stands in when GET_IDS has none. cb(variant | null): the one accepted.
export function fcc_foxconn(dms, cfg, imei, md5, log, cb)
{
	let p = split(sprintf('%s', cfg ?? ''), ':');
	let v1 = (magic) => fcc_auth(dms, 'foxconn', magic, (err) => {
		if (err)
			log('info', sprintf('FCC(foxconn): v1 (magic %d) not accepted: %J', magic, err));

		cb(err ? null : 'foxconn');
	});

	if (p[0] == 'foxconn' && p[1] != null && p[1] != '')
		return v1(+p[1]);

	if (p[0] == 'foxconn2')
		return fcc_auth(dms, 'foxconn2', { string: p[1] ?? '', number: +(p[2] ?? 0) }, (err) => {
			if (err)
				log('info', sprintf('FCC(foxconn): v2 not accepted: %J', err));

			cb(err ? null : 'foxconn2');
		});

	let ver = (t, k) => dms.request('FOXCONN_GET_FIRMWARE_VERSION', { version_type: t },
		(err, d) => k(err ? null : d?.version), { no_recovery: true });

	ver(0, (mcfg) => ver(2, (apps) => dms.request('GET_IDS', {}, (ierr, ids) => {
		let id = (!ierr && ids?.imei) ? ids.imei : imei;

		if (!mcfg || !apps || !id || !md5) {
			log('info', sprintf('FCC(foxconn): no v2 magic (%s) — trying v1',
				!md5 ? 'no md5' : !mcfg ? 'no mcfg version' : !apps ? 'no apps version' : 'no IMEI'));
			return v1(0);
		}

		fcc_auth(dms, 'foxconn2', { string: foxconn_v2_magic(mcfg, apps, id, md5), number: 48 }, (err) => {
			if (!err)
				return cb('foxconn2');

			log('info', sprintf('FCC(foxconn): v2 not accepted (%J) — trying v1', err));
			v1(0);
		});
	}, { no_recovery: true })));
};

// QmiNasDLBandwidth enum -> MHz (libqmi 1.38 qmi-enums-nas.h). One enum for
// every radio: 0-5 are LTE, 6-19 and 24 NR (since libqmi 1.36), 20-23 the
// GSM/TD-SCDMA/WCDMA widths, which no carrier list here reports; 0xFF unknown.
// The CPHY CA info only ever carries the LTE values.
const CA_BW_MHZ = {
	'0': 1.4, '1': 3, '2': 5, '3': 10, '4': 15, '5': 20,
	'6': 5, '7': 10, '8': 15, '9': 20, '10': 25, '11': 30, '12': 40, '13': 50,
	'14': 60, '15': 80, '16': 90, '17': 100, '18': 200, '19': 400, '24': 70,
};

// get_rf_bands(nas, cb): the radio interfaces in use, as
// [ { radio_if, band, channel, bandwidth_mhz }, ... ] (band = QmiNasActiveBand),
// [] when the modem answered with none, null when the request failed. The
// extended list wins over the legacy one: its channel is 32 bits wide, the
// legacy u16 cannot hold an NR-ARFCN above 65535 (n77/n78 sit at 620000+).
export function get_rf_bands(nas, cb)
{
	nas.request('GET_RF_BAND_INFO', {}, (e, d) => {
		if (e)
			return cb(null);

		let bw = {};

		for (let b in (d?.bandwidths ?? []))
			bw[sprintf('%d', b.radio_if)] = CA_BW_MHZ[sprintf('%d', b.bandwidth)] ?? null;

		cb(map(d?.bands_ext ?? d?.bands ?? [], (b) => ({
			radio_if: b.radio_if, band: b.band, channel: b.channel,
			bandwidth_mhz: bw[sprintf('%d', b.radio_if)] ?? null,
		})));
	}, { no_recovery: true });
};

// ca_with_rf(ca, rf): complete a carrier list (from get_ca or the vendor AT
// read) with the primary carrier of each leg from get_rf_bands, the way
// Android's PhysicalChannelConfig list is built from the same three NAS reads
// (CPHY CA info, RF band info, cell location). Two gaps it closes:
//   - the NR leg: no QMI message lists NR carriers (libqmi 1.38), but RF band
//     info names its band, NR-ARFCN and bandwidth — the 5G row of an NSA
//     link, the only row of an SA one;
//   - an LTE PCC when the CA info is unavailable: the T99W175 answers it with
//     InformationUnavailable while the UE is idle (HW-read 2026-11-13).
// A leg the list already carries is left alone — the Quectel QCAINFO rows are
// richer (SCCs, PCI) than what RF band info can say. PCI is not in RF band
// info; modem_common.serving_from_ca fills it from the cell location read.
// Pure; returns a new list (ca may be null).
export function ca_with_rf(ca, rf)
{
	let out = [ ...(ca ?? []) ];
	// 'PCC LTE' / 'PCC NR' too: the Fibocom AT rows name the leg in the role
	// (telemetry_ncm.uc ca_entries), and missing them doubled both PCCs
	let has = (rat) => length(filter(out, (c) => match(c?.role ?? '', /^PCC( LTE| NR)?$/) &&
		(c?.rat ?? 'lte') == rat)) > 0;
	let lte = filter(rf ?? [], (b) => b.radio_if == nasmod.RADIO_IF_LTE)[0];
	let nr = filter(rf ?? [], (b) => b.radio_if == nasmod.RADIO_IF_5GNR)[0];

	if (lte && !has('lte'))
		push(out, { rat: 'lte', role: 'PCC', earfcn: lte.channel, pci: null,
		            bandwidth_mhz: lte.bandwidth_mhz });

	if (nr && !has('nr')) {
		// the band token the way the AT producer spells it ('n78'), so the
		// page shows the modem's band rather than re-deriving it
		let m = match(nasmod.ACTIVE_BAND_NAMES[sprintf('%d', nr.band)] ?? '', /^NR (n[0-9]+)$/);

		push(out, { rat: 'nr', role: 'PCC', earfcn: nr.channel, pci: null,
		            band: m ? m[1] : null, bandwidth_mhz: nr.bandwidth_mhz });
	}

	return out;
};

// get_ca(nas, cb): active LTE carrier aggregation, normalized to
// [ { role, earfcn, pci, bandwidth_mhz, state? }, ... ]. Band/frequency are
// derived from earfcn in the UI. QmiNasScellState: 0 deconfigured,
// 1 deactivated, 2 activated.
//
// AN EMPTY LIST AND A NULL MEAN DIFFERENT THINGS: [] is a modem that ANSWERED
// and is not aggregating right now, null is a request that failed. A renderer
// need not tell them apart, but the backend ladder judges the transport by its
// answer — collapsed, it would retire a healthy QMI CA read after a few
// ordinary non-aggregated polls (evidence: ddimension/wwand#30).
export function get_ca(nas, cb)
{
	// an optional read — modems that reject it (old stacks: Invalid QMI
	// command) must not feed the recovery counter
	nas.request('GET_LTE_CPHY_CA_INFO', {}, (e, d) => {
		if (e)
			return cb(null);

		if (!d?.pcell && !d?.scells)
			return cb([]);

		let out = [];

		// The PCC is the serving cell; its dl_bandwidth is a vendor-neutral
		// serving-cell BANDWIDTH source (telemetry fills serving.lte.bandwidth_mhz
		// from it on ANY QMI/MBIM modem). The raw `band` TLV is the QMI ActiveBand
		// enum (EUTRAN_1=120…, non-linearly mapped) — NOT the 3GPP band number, and
		// LuCI derives the band from the (disjoint) EARFCN anyway, so it is not
		// surfaced here to avoid a misleading value.
		// `rat` is stated rather than left out: this message is LTE-only, but the
		// AT producer of the same list carries both legs, and a consumer should
		// not have to know which producer it is reading to tell them apart.
		if (d.pcell)
			push(out, { rat: 'lte', role: 'PCC', earfcn: d.pcell.earfcn, pci: d.pcell.pci,
			            bandwidth_mhz: CA_BW_MHZ[sprintf('%d', d.pcell.dl_bandwidth)] ?? null });

		for (let s in (d.scells ?? []))
			push(out, { rat: 'lte', role: 'SCC', earfcn: s.earfcn, pci: s.pci,
			            bandwidth_mhz: CA_BW_MHZ[sprintf('%d', s.dl_bandwidth)] ?? null,
			            state: s.state });

		cb(out);
	}, { no_recovery: true });
};

// data_mode_from_systems(available_systems): map a DSD available-systems list
// (from either GET_SYSTEM_STATUS or the SYSTEM_STATUS_IND) to { mode, lte, nr }
// with mode LTE / NSA / SA — or null when the list is absent. 5G present with LTE
// = NSA (NR anchored on LTE); 5G alone = SA; LTE alone = LTE. Shared by the poll
// and the indication so both derive the mode identically.
export function data_mode_from_systems(available_systems)
{
	if (available_systems == null)
		return null;

	let rats = {};

	for (let s in available_systems)
		if (s.rat == dsdmod.RAT_LTE) rats.lte = true;
		else if (s.rat == dsdmod.RAT_5G) rats.nr = true;

	let mode = rats.nr ? (rats.lte ? 'NSA' : 'SA') : (rats.lte ? 'LTE' : null);

	return { mode: mode, lte: !!rats.lte, nr: !!rats.nr };
};

// get_data_mode(dsd, cb): data-system mode from the DSD service, polled — see
// data_mode_from_systems for the return shape. null on error/unavailable.
export function get_data_mode(dsd, cb)
{
	dsd.request('GET_SYSTEM_STATUS', {}, (e, d) => {
		if (e)
			return cb(null);
		cb(data_mode_from_systems(d?.available_systems));
	});
};

// get_reg_detail(nas, cb): why (not) registered, from QMI GET_SYSTEM_INFO —
// { source:'qmi', limited?, reject_cause?, reject_domain? } or null on error.
// The clear-text mapping + the AT+CEER top-up are the core's job (protocol-
// neutral). no_recovery: an unsupported message must not climb the reboot ladder.
export function get_reg_detail(nas, cb)
{
	nas.request('GET_SYSTEM_INFO', {}, (err, data) => {
		if (err)
			return cb(null);

		let d = { source: 'qmi' };
		let ss = data.lte_service_status?.status;

		if (ss != null)
			d.limited = (ss == nasmod.SVC_STATUS_LIMITED ||
			             ss == nasmod.SVC_STATUS_LIMITED_REGIONAL);

		let ri = data.lte_sys_info;

		if (ri?.reject_valid && ri.reject_cause) {
			d.reject_cause = ri.reject_cause;
			d.reject_domain = ri.reject_domain;
		}

		cb(d);
	}, { no_recovery: true });
};

// --- context (WDS) operations ------------------------------------------------

const RAT_LTE = (1 << 5), RAT_5GNR = (1 << 10);
const STATS_MASK = 0x3FF;

// get_channel_rates(wds, cb): current + max tx/rx link rate (bits/sec) or null.
export function get_channel_rates(wds, cb)
{
	wds.request('GET_CHANNEL_RATES', {}, (err, data) => cb((!err && data?.rates) ? data.rates : null));
};

// bearer_label(rat_mask): map a WDS data-bearer RAT mask to a label ('LTE' /
// '5G NR' / 'LTE + 5G' / 'other') or null. Shared by the polled get_bearer and
// the WDS EVENT_REPORT current-bearer indication so both derive it identically.
export function bearer_label(rat_mask)
{
	if (rat_mask == null)
		return null;

	let lte = (rat_mask & RAT_LTE) != 0, nr = (rat_mask & RAT_5GNR) != 0;
	return nr ? (lte ? 'LTE + 5G' : '5G NR') : (lte ? 'LTE' : (rat_mask ? 'other' : null));
};

// get_bearer(wds, cb): the RAT actually carrying this session's data, as a
// label ('LTE' / '5G NR' / 'LTE + 5G' / 'other') or null.
export function get_bearer(wds, cb)
{
	wds.request('GET_CURRENT_DATA_BEARER_TECHNOLOGY', {}, (err, data) =>
		cb(bearer_label((!err) ? data?.current?.rat_mask : null)));
};

// get_packet_stats(wds, cb): raw per-call packet counters, or null when the
// modem didn't answer (the caller aggregates across families + masks sentinels).
export function get_packet_stats(wds, cb)
{
	wds.request('GET_PACKET_STATISTICS', { mask: STATS_MASK }, (err, data) =>
		cb((err || data?.rx_packets_ok == null) ? null : data));
};

// stop_network(client, pdh, cb): tear down a started WDS data call. Preserves
// the double STOP_NETWORK attempt (some modems drop the first). cb(err, second)
// — err is the final attempt's error (null on success), second is true when the
// retry ran, so the caller can log "(2nd attempt)". The family-flavored logging
// stays in the context (it holds the family/pdh context).
export function stop_network(client, pdh, cb)
{
	client.request('STOP_NETWORK', { pdh: pdh }, (err) => {
		if (!err)
			return cb(null, false);

		client.request('STOP_NETWORK', { pdh: pdh }, (e2) => cb(e2, true));
	}, { timeout: 10000 });
};

// read_info(dms, cb): identity + capabilities.
// cb(info) with { manufacturer?, model?, revision?, imei?, meid?, capabilities? }
// (fields the modem didn't answer are simply absent).
export function read_info(dms, cb)
{
	let info = {};

	// strictly sequential, because the five getters share one control channel;
	// a failed getter leaves its field unset and must not stop the rest — a
	// modem that refuses GET_REVISION (asked earlier) is no reason to lose its IMEI
	backend.run_seq([
		(next) => dms.request('GET_MANUFACTURER', {}, (e, d) => {
			if (!e) info.manufacturer = d.manufacturer;
			next();
		}),
		(next) => dms.request('GET_MODEL', {}, (e, d) => {
			if (!e) info.model = d.model;
			next();
		}),
		(next) => dms.request('GET_REVISION', {}, (e, d) => {
			if (!e) info.revision = d.revision;
			next();
		}),
		(next) => dms.request('GET_IDS', {}, (e, d) => {
			if (!e) {
				// old stacks pad the field past the 15-digit IMEI with
				// uninitialised bytes (field-seen on the 2011-era E182E) —
				// take the leading 15 digits; anything else is not an IMEI
				info.imei = match(d.imei ?? '', /^[0-9]{15}/)?.[0] ?? null;
				info.meid = d.meid;
			}
			next();
		}),
		(next) => dms.request('GET_CAPABILITIES', {}, (e, d) => {
			if (!e && d.capabilities) info.capabilities = d.capabilities;
			next();
		}),
	], () => cb(info));
};
