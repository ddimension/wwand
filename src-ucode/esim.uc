// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand-esim — ES10c profile management (SGP.22) over the wwand APDU channel.
//
// Shipped as the optional wwand-esim package; the daemon loads it lazily via
// require(). Written as an exportless plain script on purpose: require()
// cannot compile ES modules (`export` is a syntax error there — see
// mbim_lazy), but imports are fine and the script returns its API object.
//
// Scope: management only (EID, profile list, enable/disable/delete). The
// SM-DP+ download runs host-side through lpac; wwand only provides the APDU
// transport.
'use strict';

import * as sim from 'wwand.sim';
import * as backend from 'wwand.backend';

import { ISDR_AID } from 'wwand.sim';
import { iccid_to_bytes, bytes_to_iccid, hex_to_arr, arr_to_hex } from 'wwand.codec.hex';

// --- minimal BER-TLV ---------------------------------------------------------

// parse one level of BER-TLV from byte array `a` starting at `pos` up to
// `end`; returns [ { tag, val (byte array) }, ... ]. Two-byte tags supported.
function ber_parse(a, pos, end)
{
	let out = [];

	pos = pos ?? 0;
	end = end ?? length(a);

	while (pos < end) {
		let tag = a[pos++];

		if ((tag & 0x1f) == 0x1f)
			tag = (tag << 8) | a[pos++];

		let len = a[pos++];

		if (len == 0x81)
			len = a[pos++];
		else if (len == 0x82) {
			len = (a[pos] << 8) | a[pos + 1];
			pos += 2;
		}

		push(out, { tag: tag, val: slice(a, pos, pos + len) });
		pos += len;
	}

	return out;
}

// encode one BER-TLV (tag up to 2 bytes, definite length)
function ber_build(tag, val)
{
	let out = [];

	if (tag > 0xff)
		push(out, tag >> 8);

	push(out, tag & 0xff);

	let n = length(val);

	if (n < 0x80)
		push(out, n);
	else if (n < 0x100)
		push(out, 0x81, n);
	else
		push(out, 0x82, n >> 8, n & 0xff);

	return [ ...out, ...val ];
}


// --- ES10 transport (STORE DATA over the ISD-R logical channel) --------------

// send a full ES10 request (byte array), collecting a chained response;
// cb(err, response_byte_array)
function es10_transceive(modem, slot, channel, req, cb)
{
	// proprietary class with the channel in it: 0x80 | n for 0-3, a further
	// CLA 0xC0 | n-4 for 4-19 (`channel & 3` put channel 4 on the basic one)
	let cla = (channel < 4) ? (0x80 | channel) : (0xc0 | (channel - 4));
	let blocks = [];

	for (let off = 0; off < length(req); off += 255)
		push(blocks, slice(req, off, off + 255));

	if (!length(blocks))
		push(blocks, []);

	let resp = [];
	let step;
	let idx = 0;

	let collect;

	collect = (hexresp) => {
		let r = hex_to_arr(hexresp);

		if (length(r) < 2)
			return cb({ error: 'short_response' }, null);

		let sw1 = r[length(r) - 2], sw2 = r[length(r) - 1];

		resp = [ ...resp, ...slice(r, 0, length(r) - 2) ];

		if (sw1 == 0x61) {
			// more response data: GET RESPONSE
			let get = sprintf('%02xc00000%02x', cla, sw2);

			return sim.apdu_send(modem, slot, channel, get, (err, hr) =>
				err ? cb(err, null) : collect(hr));
		}

		if (sw1 != 0x90)
			return cb({ error: 'sw', sw: sprintf('%02x%02x', sw1, sw2) }, null);

		cb(null, resp);
	};

	step = () => {
		let last = (idx == length(blocks) - 1);
		let blk = blocks[idx++];
		let apdu = sprintf('%02xe2%02x%02x%02x%s', cla,
			last ? 0x91 : 0x11, idx - 1, length(blk), arr_to_hex(blk));

		sim.apdu_send(modem, slot, channel, apdu, (err, hr) => {
			if (err)
				return cb(err, null);

			if (!last)
				return step();

			collect(hr);
		});
	};

	step();
}

// open ISD-R, run `req`, close again; cb(err, parsed_top_level_tlvs)
function es10_request(modem, slot, req, cb)
{
	sim.apdu_open(modem, slot, ISDR_AID, (err, ch) => {
		if (err)
			return cb(err, null);

		es10_transceive(modem, slot, ch.channel, req, (terr, resp) => {
			sim.apdu_close(modem, slot, ch.channel, () => {
				// ISD-R selected fine, but the card refuses the ES10 STORE DATA
				// outright (SW 6985, conditions of use not satisfied): the
				// profile-management interface is not locally usable. Typical
				// for M2M eUICCs (SGP.02 — profiles are managed over-the-air
				// by the operator's SM-SR, there IS no local ES10) and for
				// vendor-locked cards. Classify so UIs can explain instead of
				// showing a bare status word (HW-hit: EMnify M2M eUICC).
				if (terr?.error == 'sw' && terr.sw == '6985')
					return cb({ error: 'es10_refused', sw: terr.sw,
					            hint: 'm2m_or_locked_euicc' }, null);

				if (terr)
					return cb(terr, null);

				cb(null, ber_parse(resp));
			});
		});
	});
}

// --- ES10c commands ----------------------------------------------------------

const TAG_GET_EID       = 0xbf3e;
const TAG_PROFILE_INFO  = 0xbf2d;
const TAG_ENABLE        = 0xbf31;
const TAG_DISABLE       = 0xbf32;
const TAG_DELETE        = 0xbf33;

const PROFILE_STATES = { '0': 'disabled', '1': 'enabled' };

function find_tag(tlvs, tag)
{
	for (let t in (tlvs ?? []))
		if (t.tag == tag)
			return t.val;

	return null;
}

function parse_profiles(tlvs)
{
	let body = find_tag(tlvs, TAG_PROFILE_INFO);

	if (body == null)
		return null;

	let out = [];
	// ProfileInfoListOk ::= [0] SEQUENCE OF ProfileInfo — tag A0
	let seq = find_tag(ber_parse(body), 0xa0) ?? [];

	for (let e in ber_parse(seq)) {
		if (e.tag != 0xe3)
			continue;

		let p = { iccid: null, state: null, nickname: null,
		          provider: null, name: null, isdp_aid: null };

		for (let f in ber_parse(e.val)) {
			switch (f.tag) {
			case 0x5a:   p.iccid = bytes_to_iccid(f.val); break;
			case 0x9f70: p.state = PROFILE_STATES[sprintf('%d', f.val[0] ?? 255)] ?? 'unknown'; break;
			case 0x90:   p.nickname = arr_to_hex(f.val); break;
			case 0x91:   p.provider = join('', map(f.val, (c) => sprintf('%c', c))); break;
			case 0x92:   p.name = join('', map(f.val, (c) => sprintf('%c', c))); break;
			case 0x4f:   p.isdp_aid = arr_to_hex(f.val); break;
			}
		}

		// nickname is UTF-8 text as well
		if (p.nickname != null)
			p.nickname = join('', map(hex_to_arr(p.nickname), (c) => sprintf('%c', c)));

		push(out, p);
	}

	return out;
}

// op result: [tag] { [0] INTEGER result } — 0 = ok
function parse_result(tlvs, tag)
{
	let body = find_tag(tlvs, tag);

	if (body == null)
		return { error: 'no_response' };

	let code = find_tag(ber_parse(body), 0x80);

	if (code == null || code[0] != 0)
		return { error: 'euicc', code: code?.[0] };

	return null;
}

// --- GetEUICCInfo2 (ES10b, BF22): what the card itself says it is ------------
//
// Field tags, bit names and enum values per the ASN.1 Wireshark's SGP.22
// dissector builds from (epan/dissectors/asn1/sgp22/RSPDefinitions.asn +
// PEDefinitions.asn, master 49c70fe1, 2026-11-08: module sgp22v2, carrying the
// tags SGP.22 v3 and SGP.32 reserve). Context tags are IMPLICIT (AUTOMATIC
// TAGS), so [11] euiccCategory INTEGER is 8B — lpac 2.3.0 (es10c_ex.c) looks
// for AB and never finds it; both eUICCs read here sent 8B (2026-11-22).

const TAG_EUICC_INFO2 = 0xbf22;
// SGP.32 ES10b GetEimConfigurationData: an IoT eUICC answers it (an empty
// list included), an SGP.22 consumer card refuses it — 6985 on the RG650E's
// and the T99W175's eUICC, both svn 2.2.x (HW-read 2026-11-22)
const TAG_EIM_CONFIG = 0xbf55;

const RSP_CAPABILITY = {
	'0': 'additionalProfile', '1': 'crlSupport', '2': 'rpmSupport', '3': 'testProfileSupport',
	'4': 'deviceInfoExtensibilitySupport', '5': 'serviceSpecificDataSupport',
	'19': 'osUpdateSupport', '26': 'iotSpecificMetadataSupport', '27': 'mslCheckSupport',
	'28': 'rspServerTestProfileAllowlistCheckSupport',
};

const UICC_CAPABILITY = [
	'contactlessSupport', 'usimSupport', 'isimSupport', 'csimSupport', 'akaMilenage', 'akaCave',
	'akaTuak128', 'akaTuak256', 'usimTestAlgorithm', 'rfu2', 'gbaAuthenUsim', 'gbaAuthenISim',
	'mbmsAuthenUsim', 'eapClient', 'javacard', 'multos', 'multipleUsimSupport', 'multipleIsimSupport',
	'multipleCsimSupport', 'berTlvFileSupport', 'dfLinkSupport', 'catTp', 'getIdentity',
	'profile-a-x25519', 'profile-b-p256', 'suciCalculatorApi', 'dns-resolution', 'scp11ac',
	'scp11c-authorization-mechanism', 's16mode', 'eaka', 'iotminimal',
];

const PPR_IDS = [ 'pprUpdateControl', 'ppr1', 'ppr2' ];
const TRE_PROPERTIES = [ 'isDiscrete', 'isIntegrated', 'usesRemoteMemory' ];
const EUICC_CATEGORY = [ 'other', 'basicEuicc', 'mediumEuicc', 'contactlessEuicc' ];

// VersionType: three binary bytes, major/minor/revision ('02 02 02' = 2.2.2)
function version_str(v)
{
	return (length(v ?? []) == 3) ? sprintf('%d.%d.%d', v[0], v[1], v[2]) : null;
}

function uint_of(v)
{
	let n = 0;

	for (let b in (v ?? []))
		n = n * 256 + b;

	return n;
}

function text_of(v)
{
	return join('', map(v ?? [], (c) => sprintf('%c', c)));
}

// A DER BIT STRING: first byte the unused bit count, then the bits, MSB first
// = bit 0. A set bit with no name is reported by number ('bit 7'), never
// dropped: a later spec version names bits this table does not know yet.
function bits_of(v, names)
{
	let out = [];

	if (!length(v ?? []))
		return out;

	let total = (length(v) - 1) * 8 - v[0];

	for (let i = 0; i < total; i++)
		if ((v[1 + (i >> 3)] >> (7 - (i & 7))) & 1)
			push(out, (type(names) == 'array' ? names[i] : names[sprintf('%d', i)]) ?? sprintf('bit %d', i));

	return out;
}

// cb-free decode of the BF22 answer; null when it is not there. Every field
// is optional in the result: a card leaves out what it does not have.
function parse_euiccinfo2(tlvs)
{
	let body = find_tag(tlvs, TAG_EUICC_INFO2);

	if (body == null)
		return null;

	let i = {};
	let keys = (v) => map(ber_parse(v), (k) => arr_to_hex(k.val));

	for (let f in ber_parse(body)) {
		switch (f.tag) {
		case 0x81: i.profile_version = version_str(f.val); break;
		case 0x82: i.svn = version_str(f.val); break;
		case 0x83: i.firmware = version_str(f.val); break;
		case 0x84:   // extCardResource: ETSI TS 102 226 TLVs in an OCTET STRING
			for (let r in ber_parse(f.val)) {
				if (r.tag == 0x81) i.installed_applications = uint_of(r.val);
				if (r.tag == 0x82) i.free_nvm = uint_of(r.val);
				if (r.tag == 0x83) i.free_vm = uint_of(r.val);
			}
			break;
		case 0x85: i.uicc_capability = bits_of(f.val, UICC_CAPABILITY); break;
		case 0x86: i.ts102241_version = version_str(f.val); break;
		case 0x87: i.globalplatform_version = version_str(f.val); break;
		case 0x88: i.rsp_capability = bits_of(f.val, RSP_CAPABILITY); break;
		case 0xa9: i.ci_pkid_verification = keys(f.val); break;
		case 0xaa: i.ci_pkid_signing = keys(f.val); break;
		case 0x8b:
		case 0xab:   // what lpac 2.3.0 looks for; the ASN.1 says 8B
			i.category = EUICC_CATEGORY[uint_of(f.val)] ?? 'other'; break;
		case 0x99: i.forbidden_ppr = bits_of(f.val, PPR_IDS); break;
		case 0x04: i.pp_version = version_str(f.val); break;
		case 0x0c: i.sas_accreditation = text_of(f.val); break;
		case 0xac:
			for (let c in ber_parse(f.val)) {
				if (c.tag == 0x80) i.platform_label = text_of(c.val);
				if (c.tag == 0x81) i.discovery_base_url = text_of(c.val);
			}
			break;
		case 0x8d: i.tre_properties = bits_of(f.val, TRE_PROPERTIES); break;
		case 0x8e: i.tre_product_reference = text_of(f.val); break;
		case 0xaf: i.additional_profile_versions = map(ber_parse(f.val), (k) => version_str(k.val)); break;
		case 0x90: i.lpa_mode = uint_of(f.val); break;
		case 0xb1: i.ci_pkid_signing_v3 = keys(f.val); break;
		case 0x92: i.additional_info = arr_to_hex(f.val); break;
		case 0x93: i.highest_svn = version_str(f.val); break;
		case 0xb4: i.iot_specific_info = true; break;
		case 0x95: i.minimum_security_level = arr_to_hex(f.val); break;
		}
	}

	return i;
}

// enable/disable carry { iccid CHOICE (5A), refreshFlag BOOLEAN };
// delete carries just the iccid choice
function iccid_request(tag, iccid, refresh)
{
	let inner = ber_build(0x5a, iccid_to_bytes(iccid));

	if (refresh != null)
		inner = [ ...inner, ...ber_build(0x01, [ refresh ? 0xff : 0x00 ]) ];

	return ber_build(tag, inner);
}

// --- vendor AT backend (Quectel AT+QESIM) ------------------------------------
// Used when the modem exposes no usable QMI logical channel but has the
// AT+QESIM LPA. (Firmware-dependent: some RG650E builds return NOT_SUPPORTED
// on OPEN/LOGICAL_CHANNEL, others open the ISD-R fine but then refuse ES10c
// writes — which is why the bridge routes management writes through lpac and
// only falls back here.) Operates
// on the eUICC in the modem's active slot; profile ops address a 1-based
// index which we map from the ICCID via the profile list.

// split a +QESIM CSV line into fields, honoring double-quoted strings
function qesim_fields(line)
{
	let body = match(line, /^\+QESIM: *"[a-z_]+",(.*)$/);

	if (!body)
		return null;

	let out = [];
	let s = body[1];
	let i = 0, cur = '', q = false;

	while (i < length(s)) {
		let c = substr(s, i, 1);

		if (c == '"')
			q = !q;
		else if (c == ',' && !q) {
			push(out, cur);
			cur = '';
		}
		else
			cur += c;

		i++;
	}

	push(out, cur);

	return out;
}

function at_send(modem, cmd, cb)
{
	if (!modem.at)
		return cb({ error: 'no_at_port' }, null);

	modem.at.send(cmd, (err, res) => cb(err, res?.lines ?? []));
}

function at_eid(modem, cb)
{
	at_send(modem, 'AT+QESIM="eid"', (err, lines) => {
		if (err)
			return cb(err, null);

		for (let l in lines) {
			let f = qesim_fields(l);

			if (f)
				return cb(null, { eid: f[0] });
		}

		cb({ error: 'no_eid' }, null);
	});
}

// list profiles with their 1-based index (needed for enable/disable/delete)
function at_profiles(modem, cb)
{
	at_send(modem, 'AT+QESIM="profile_brief"', (err, lines) => {
		if (err)
			return cb(err, null);

		let count = 0;

		for (let l in lines) {
			let f = qesim_fields(l);

			if (f)
				count = +f[0];
		}

		let out = [];
		let idx = 0;
		let step;

		step = () => {
			if (idx >= count) {
				return cb(null, { profiles: out });
			}

			let i = ++idx;

			at_send(modem, sprintf('AT+QESIM="profile_detail",%d', i), (e2, dl) => {
				if (!e2) {
					for (let l in dl) {
						let f = qesim_fields(l);

						// iccid,state,nickname,provider,name,class
						if (f && length(f) >= 6)
							push(out, {
								index: i,
								iccid: f[0],
								state: (f[1] == '1') ? 'enabled' : 'disabled',
								nickname: f[2],
								provider: f[3],
								name: f[4],
							});
					}
				}

				step();
			});
		};

		step();
	});
}

// modem-internal download (AT+QESIM="download"). The modem itself does the
// HTTPS to the SM-DP+ over its own network attach — no host data path, no
// configured WAN APN (matches MikroTik's esim-channel=at behaviour). Accepts
// a full activation code "LPA:1$smdp$matchingid[$oid[$cc]]" or bare smdp +
// matching id; result arrives as +QESIM:"download",<ret> (0 = ok).
// NOTE: exact QESIM download arg order is firmware-specific — verify against
// one real activation code on the RG650E before relying on it.
function at_download(modem, activation_code, confirmation, cb)
{
	let smdp = null, mid = null;

	let m = match(activation_code ?? '', /^LPA:1\$([^$]+)\$([^$]*)/);

	if (m) {
		smdp = m[1];
		mid = m[2];
	}
	else {
		// allow "smdp,matchingid" too
		let parts = split(activation_code ?? '', ',');
		smdp = trim(parts[0] ?? '');
		mid = trim(parts[1] ?? '');
	}

	if (!length(smdp))
		return cb({ error: 'bad_activation_code' });

	let cmd = sprintf('AT+QESIM="download","%s","%s"', smdp, mid ?? '');

	if (length(confirmation ?? ''))
		cmd += sprintf(',"%s"', confirmation);

	// the port is gone while the modem re-initialises (see sim.uc
	// apdu_transport_gone)
	if (!modem.at)
		return cb({ error: 'no_at_port' });

	// the download is a full network transaction; give it a long window and
	// read the +QESIM:"download",<ret> result line
	modem.at.send(cmd, (err, res) => {
		if (err)
			return cb({ error: 'at', detail: err });

		let ret = null;

		for (let l in (res?.lines ?? [])) {
			let f = qesim_fields(l);

			if (f && match(l, /"download"/))
				ret = +f[0];
		}

		if (ret == null || ret == 0)
			cb(null, { ret: ret ?? 0 });
		else
			cb({ error: 'download_failed', ret: ret });
	}, { timeout: 180000 });
}

// resolve ICCID -> index, then run `verb` (enable_profile/…)
function at_profile_op(modem, iccid, verb, cb)
{
	at_profiles(modem, (err, res) => {
		if (err)
			return cb(err);

		let hit = filter(res.profiles, (p) => p.iccid == iccid)[0];

		if (!hit)
			return cb({ error: 'no_such_profile', iccid: iccid });

		at_send(modem, sprintf('AT+QESIM="%s",%d', verb, hit.index), (e2) => cb(e2 ?? null));
	});
}

// pick the eSIM backend: prefer the QMI logical channel, fall back to the
// vendor AT LPA. cb('qmi' | 'at' | null). Re-probed per op — the ISD-R is
// only free in a window right after a SIM slot switch (the modem's internal
// LPA re-claims it; field-verified on the FM350-GL), so a stale 'at' cache
// would mask a usable channel.
function backend_of(modem, slot, cb)
{
	backend.forget(modem, '_esim_be');

	backend.choose(modem, '_esim_be', [
		// QMI ES10c over the logical channel: probe by opening the ISD-R
		{ name: 'qmi', probe: (ok) => sim.apdu_open(modem, slot, ISDR_AID, (err, ch) => {
			if (err)
				return ok(false);
			sim.apdu_close(modem, slot, ch.channel, () => {});
			ok(true);
		}) },
		{ name: 'at', probe: (ok) => ok(!!modem.at) },
	], cb);
}

// --- public API --------------------------------------------------------------

let qmi = {

	get_eid: (modem, slot, cb) => {
		// GetEuiccDataRequest: tag list 5C requesting 5A (EID)
		es10_request(modem, slot, ber_build(TAG_GET_EID, ber_build(0x5c, [ 0x5a ])), (err, tlvs) => {
			if (err)
				return cb(err, null);

			let body = find_tag(tlvs, TAG_GET_EID);
			let eid = body ? find_tag(ber_parse(body), 0x5a) : null;

			cb(null, { eid: eid ? arr_to_hex(eid) : null });
		});
	},

	// The card's own description (GetEUICCInfo2), its EID, and whether it is
	// an SGP.32 IoT eUICC. cb(err, { eid, svn, …, sgp32 }) — `sgp32` is true
	// when GetEimConfigurationData answers, false when the card refuses it —
	// unless its EUICCInfo2 carries iotSpecificInfo [20], which only an SGP.32
	// card does (one whose own IPA keeps ES10b to itself refuses the probe) —
	// and null when the probe failed for another reason (`sgp32_error`).
	info: (modem, slot, cb) => {
		es10_request(modem, slot, ber_build(TAG_EUICC_INFO2, []), (err, tlvs) => {
			if (err)
				return cb(err, null);

			let info = parse_euiccinfo2(tlvs);

			if (info == null)
				return cb({ error: 'no_response', detail: 'no EUICCInfo2 in the answer' }, null);

			es10_request(modem, slot, ber_build(TAG_GET_EID, ber_build(0x5c, [ 0x5a ])), (eerr, etlvs) => {
				let body = eerr ? null : find_tag(etlvs, TAG_GET_EID);
				let eid = body ? find_tag(ber_parse(body), 0x5a) : null;

				info.eid = eid ? arr_to_hex(eid) : null;

				es10_request(modem, slot, ber_build(TAG_EIM_CONFIG, []), (perr, ptlvs) => {
					let sw = perr?.sw;

					if (!perr) {
						info.sgp32 = (find_tag(ptlvs, TAG_EIM_CONFIG) != null);
						let list = info.sgp32 ? find_tag(ber_parse(find_tag(ptlvs, TAG_EIM_CONFIG)), 0xa0) : null;
						info.eim_count = (list != null) ? length(ber_parse(list)) : null;
					}
					// "not this command / not now" from the card is its no
					else if (sw == '6985' || sw == '6a88' || sw == '6d00' || sw == '6a80' || sw == '6e00')
						info.sgp32 = !!info.iot_specific_info;
					else {
						info.sgp32 = null;
						info.sgp32_error = perr.error;
					}

					cb(null, info);
				});
			});
		});
	},

	profiles: (modem, slot, cb) => {
		es10_request(modem, slot, ber_build(TAG_PROFILE_INFO, []), (err, tlvs) => {
			if (err)
				return cb(err, null);

			cb(null, { profiles: parse_profiles(tlvs) ?? [] });
		});
	},

	enable: (modem, slot, iccid, cb) => {
		es10_request(modem, slot, iccid_request(TAG_ENABLE, iccid, true), (err, tlvs) =>
			cb(err ?? parse_result(tlvs, TAG_ENABLE), { iccid: iccid }));
	},

	disable: (modem, slot, iccid, cb) => {
		es10_request(modem, slot, iccid_request(TAG_DISABLE, iccid, true), (err, tlvs) =>
			cb(err ?? parse_result(tlvs, TAG_DISABLE), { iccid: iccid }));
	},

	del: (modem, slot, iccid, cb) => {
		es10_request(modem, slot, iccid_request(TAG_DELETE, iccid, null), (err, tlvs) =>
			cb(err ?? parse_result(tlvs, TAG_DELETE), { iccid: iccid }));
	},
};

let at = {
	get_eid: (modem, slot, cb) => at_eid(modem, cb),
	profiles: (modem, slot, cb) => at_profiles(modem, cb),
	// the vendor LPA (AT+QESIM) has no ES10b; there is nothing to read
	info: (modem, slot, cb) => cb({ error: 'unsupported_on_backend',
	                                detail: 'the modem\'s own LPA (AT) does not pass ES10b through' }, null),
	enable:  (modem, slot, iccid, cb) => at_profile_op(modem, iccid, 'enable_profile',  (e) => cb(e, { iccid: iccid })),
	disable: (modem, slot, iccid, cb) => at_profile_op(modem, iccid, 'disable_profile', (e) => cb(e, { iccid: iccid })),
	del:     (modem, slot, iccid, cb) => at_profile_op(modem, iccid, 'delete_profile',  (e) => cb(e, { iccid: iccid })),
};

// dispatch each op to the selected backend (QMI ES10c or vendor AT+QESIM)
function dispatch(op, args)
{
	let modem = args[0], slot = args[1];
	let cb = args[length(args) - 1];

	backend_of(modem, slot, (be) => {
		if (!be)
			return cb({ error: 'no_esim_backend' }, null);

		(be == 'qmi' ? qmi : at)[op](...args);
	});
}

return {
	// backend detection is exposed so callers can report which path is used
	backend: (modem, slot, cb) => backend_of(modem, slot, cb),

	// clear the cached backend (call on SIM slot switch — removable eUICCs)
	reset_backend: (modem) => backend.reset(modem, '_esim_be'),

	// modem-internal download (AT backend only; the QMI/lpac host path is
	// driven from the daemon glue). cb(err, {ret})
	download_at: (modem, activation_code, confirmation, cb) =>
		at_download(modem, activation_code, confirmation, cb),

	// exposed for the unit tests (QMI ES10c internals + AT parser)
	_ber_parse: ber_parse,
	_ber_build: ber_build,
	_parse_profiles: parse_profiles,
	_iccid_request: iccid_request,
	_bytes_to_iccid: bytes_to_iccid,
	_qesim_fields: qesim_fields,
	_parse_euiccinfo2: parse_euiccinfo2,

	get_eid: (modem, slot, cb)        => dispatch('get_eid', [ modem, slot, cb ]),
	info: (modem, slot, cb)           => dispatch('info', [ modem, slot, cb ]),
	profiles: (modem, slot, cb)       => dispatch('profiles', [ modem, slot, cb ]),
	enable: (modem, slot, iccid, cb)  => dispatch('enable', [ modem, slot, iccid, cb ]),
	disable: (modem, slot, iccid, cb) => dispatch('disable', [ modem, slot, iccid, cb ]),
	del: (modem, slot, iccid, cb)     => dispatch('del', [ modem, slot, iccid, cb ]),
};
