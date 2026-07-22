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

import * as sim from './sim.uc';

const ISDR_AID = 'a0000005591010ffffffff8900000100';

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

// ICCID digits <-> nibble-swapped BCD bytes (same coding as on the SIM)
const NIBBLES = '0123456789abcdef';

function iccid_to_bytes(iccid)
{
	let out = [];
	let s = lc(iccid ?? '');

	if (length(s) % 2)
		s += 'f';

	for (let i = 0; i < length(s); i += 2) {
		let lo = index(NIBBLES, substr(s, i, 1));
		let hi = index(NIBBLES, substr(s, i + 1, 1));

		push(out, ((hi < 0 ? 0xf : hi) << 4) | (lo < 0 ? 0xf : lo));
	}

	return out;
}

function bytes_to_iccid(b)
{
	let s = '';

	for (let x in (b ?? []))
		s += sprintf('%x%x', x & 0xf, x >> 4);

	return replace(s, /f+$/, '');
}

// --- ES10 transport (STORE DATA over the ISD-R logical channel) --------------

// send a full ES10 request (byte array), collecting a chained response;
// cb(err, response_byte_array)
function es10_transceive(modem, slot, channel, req, cb)
{
	let cla = 0x80 | (channel & 0x03);
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
		let r = sim.hex_to_arr(hexresp);

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
			last ? 0x91 : 0x11, idx - 1, length(blk), sim.arr_to_hex(blk));

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
			case 0x90:   p.nickname = sim.arr_to_hex(f.val); break;
			case 0x91:   p.provider = join('', map(f.val, (c) => sprintf('%c', c))); break;
			case 0x92:   p.name = join('', map(f.val, (c) => sprintf('%c', c))); break;
			case 0x4f:   p.isdp_aid = sim.arr_to_hex(f.val); break;
			}
		}

		// nickname is UTF-8 text as well
		if (p.nickname != null)
			p.nickname = join('', map(sim.hex_to_arr(p.nickname), (c) => sprintf('%c', c)));

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

// enable/disable carry { iccid CHOICE (5A), refreshFlag BOOLEAN };
// delete carries just the iccid choice
function iccid_request(tag, iccid, refresh)
{
	let inner = ber_build(0x5a, iccid_to_bytes(iccid));

	if (refresh != null)
		inner = [ ...inner, ...ber_build(0x01, [ refresh ? 0xff : 0x00 ]) ];

	return ber_build(tag, inner);
}

// --- public API --------------------------------------------------------------

return {
	// exposed for the unit tests
	_ber_parse: ber_parse,
	_ber_build: ber_build,
	_parse_profiles: parse_profiles,
	_iccid_request: iccid_request,
	_bytes_to_iccid: bytes_to_iccid,

	get_eid: (modem, slot, cb) => {
		// GetEuiccDataRequest: tag list 5C requesting 5A (EID)
		es10_request(modem, slot, ber_build(TAG_GET_EID, ber_build(0x5c, [ 0x5a ])), (err, tlvs) => {
			if (err)
				return cb(err, null);

			let body = find_tag(tlvs, TAG_GET_EID);
			let eid = body ? find_tag(ber_parse(body), 0x5a) : null;

			cb(null, { eid: eid ? sim.arr_to_hex(eid) : null });
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
