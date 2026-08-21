// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — NCM/AT vendor model: the PDP/auth AT command builders, the
// per-vendor dial-method tables and bring-up recipes (VENDORS), and the
// CGDCONT parsers. Pure data + stateless helpers, extracted from
// modem_ncm.uc; shared by modem_ncm.uc and context_ncm.uc (via the
// re-exports modem_ncm keeps for its existing consumers).

'use strict';

import * as telemetry_ncm from 'wwand.telemetry_ncm';
import * as context_common from 'wwand.context_common';

// --- AT command model (shared with context_ncm.uc) ---------------------------
// pdp_type -> the 3GPP PDP type string used in AT+CGDCONT and the Quectel
// AT+QICSGP <context_type> enum (1=IPv4, 2=IPv6, 3=IPv4v6).

const PDP_STR = { ipv4: 'IP', ipv6: 'IPV6', ipv4v6: 'IPV4V6' };
const CTX_TYPE = { ipv4: 1, ipv6: 2, ipv4v6: 3 };

// QICSGP / CGAUTH auth enum: 0=none, 1=PAP, 2=CHAP, 3=PAP-or-CHAP
const AUTH_ENUM = { none: 0, pap: 1, chap: 2, both: 3 };

// explicit config wins; else PAP-or-CHAP when username/password present
// (QMI/MBIM parity), else none. (Must precede AUTH_CGAUTH — ucode does not
// hoist function declarations, the arrow below resolves it at call time.)
function auth_value(cfg)
{
	if (cfg.auth != null)
		return AUTH_ENUM[cfg.auth] ?? AUTH_ENUM.both;

	return (cfg.username && cfg.password) ? AUTH_ENUM.both : AUTH_ENUM.none;
}

// the standard 3GPP AT+CGAUTH auth command — shared by every vendor whose
// firmware takes the stock form (vendor-specific variants like QICSGP/
// AUTHDATA/QCPDPP stay in their tables)
const AUTH_CGAUTH = (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
	? sprintf('AT+CGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
		cfg.username ?? '', cfg.password ?? '')
	: null;

// standard 3GPP context definition — the default `define` for most vendors
function cgdcont(cid, pdp, apn)
{
	return sprintf('AT+CGDCONT=%d,"%s","%s"', cid, pdp, apn);
}

// --- CGCONTRDP / CGPADDR parsers (shared with the per-vendor ip_config hooks) -

// +CGCONTRDP=<cid> field positions are NOT uniform across firmwares: some put
// the local addr as a bare 4-octet IPv4 (no mask) and interleave v4/v6 DNS.
// So rather than trust positions, tokenize every dotted-decimal group (comma OR
// space separated), classify by octet count (4/8 = IPv4[+mask], 16/32 =
// IPv6[+mask]), bucket per family IN ORDER, then map each as [addr(+mask),
// gateway?, dns...]. The gateway slot is taken only for a masked IPv4 (8/32
// octets) or for IPv6 (always advertises a link-local gw) — an unmasked IPv4
// (RG650E) has no gateway field, so every remaining v4 token is DNS.
const mask_to_prefix = context_common.mask_octets_to_prefix;

// join 16 decimal byte strings into an IPv6 literal (uncompressed but valid)
function bytes_to_ipv6(bytes)
{
	let hextets = [];

	for (let i = 0; i < 16; i += 2)
		push(hextets, sprintf('%x', (+bytes[i] & 0xff) * 256 + (+bytes[i + 1] & 0xff)));

	return join(':', hextets);
}

// the T700's embedded-IPv4 form (field-seen on the v6-only PDP): a 16-octet
// token <0×8, 0,1, 0,0><v4> — the network serves IPv4 inside the IPv6-only
// bearer. Return the trailing 4-octet slice, else null.
function embedded_v4(parts)
{
	if (length(parts) != 16)
		return null;

	for (let i = 0; i < 8; i++)
		if (+parts[i] != 0)
			return null;

	return ((+parts[8] == 0) && (+parts[9] == 1) &&
	        (+parts[10] == 0) && (+parts[11] == 0))
		? slice(parts, 12, 16)
		: null;
}

// classify one token of a CGCONTRDP/GTDNS/CGPADDR payload: null when it is not
// a dotted-decimal group, else { n, parts, ev4 } (ev4 = the embedded-v4 form —
// 16 octets that encode an IPv4, resolved once so every consumer skips it the
// same way). Shared by parse_cgcontrdp, dns_from_gt and the v6_real scan.
function dotted_group(tok)
{
	if (!match(tok, /^[0-9]+(\.[0-9]+)+$/))
		return null;

	let parts = split(tok, '.');
	let n = length(parts);

	return { n: n, parts: parts, ev4: (n == 16) ? embedded_v4(parts) : null };
}

// assign an ordered token list for one family to { addr, prefix/plen, gateway,
// dns[] }. Each entry is { p: <octet strings>, a: <came from an address slot> }.
//
// `a` is the whole point: only 3GPP fields 3 (<local_addr and subnet_mask>) and
// 4 (<gw_addr>) can hold an address. A token from field 5 and beyond is a DNS
// or P-CSCF server and must NEVER become the interface address — that is how a
// carrier resolver ended up on the WAN (and, via RFC 7278, its /64 on the LAN)
// whenever the modem answered with empty local/gateway slots.
function assign_family(tokens, is_v6)
{
	if (!length(tokens))
		return null;

	let out = { addr: null, gateway: null, dns: [] };
	let render = (t) => is_v6 ? bytes_to_ipv6(slice(t, 0, 16)) : join('.', slice(t, 0, 4));
	let has_mask = false;
	let idx = 0;

	if (tokens[0].a) {
		let t0 = tokens[0].p;

		has_mask = is_v6 ? (length(t0) == 32) : (length(t0) == 8);
		out.addr = render(t0);
		idx = 1;
	}

	if (is_v6)
		out.plen = (out.addr != null && has_mask) ? mask_to_prefix(slice(tokens[0].p, 16, 32)) : 64;
	else
		out.prefix = (out.addr != null && has_mask) ? mask_to_prefix(slice(tokens[0].p, 4, 8)) : null;

	// gateway slot: only meaningful once an address was taken — it is the token
	// that follows it (IPv6 always carries a link-local gateway; IPv4 only when
	// the address came masked). Without an address there is nothing to gateway,
	// and the remaining tokens are all resolvers.
	if (out.addr != null && (is_v6 || has_mask) && idx < length(tokens))
		out.gateway = render(tokens[idx++].p);

	for (; idx < length(tokens); idx++)
		push(out.dns, render(tokens[idx].p));

	return out;
}

export function parse_cgcontrdp(lines)
{
	let v4 = [], v6 = [];

	for (let l in (lines ?? [])) {
		let m = match(l, /\+CGCONTRDP:\s*(.*)/);

		if (!m)
			continue;

		// Split on COMMAS FIRST so the 3GPP field index survives (empty fields
		// included) — the old single-pass /[, \t]+/ tokenizer collapsed the
		// separators and lost it, which is what let a DNS server slide into the
		// address position. Only then split each field on whitespace: some
		// firmwares pack a v4 AND a v6 token into ONE field, space-separated
		// (RG650E, field-seen), so the family bucket below still has to sort
		// them out.
		//
		//   field 3 = <local_addr and subnet_mask>   \ the only slots that
		//   field 4 = <gw_addr>                      / can carry an address
		//   field 5+ = <DNS_prim>, <DNS_sec>, <P-CSCF...>
		let fields = split(replace(m[1], /"/g, ''), ',');

		for (let i = 0; i < length(fields); i++) {
			let addr_slot = (i == 3 || i == 4);

			for (let tok in split(trim(fields[i]), /[ \t]+/)) {
				let g = dotted_group(trim(tok));

				if (!g)
					continue;

				// the embedded-v4 form is 16 octets but a V4 address — extract it
				// BEFORE the family bucket, or it would corrupt the v6 assignment
				// (first token wins) when its line precedes the real v6 line
				if (g.ev4)
					push(v4, { p: g.ev4, a: addr_slot });
				else if (g.n == 4 || g.n == 8)
					push(v4, { p: g.parts, a: addr_slot });
				else if (g.n == 16 || g.n == 32)
					push(v6, { p: g.parts, a: addr_slot });
			}
		}
	}

	return { ipv4: assign_family(v4, false), ipv6: assign_family(v6, true) };
};

// +CGPADDR: <cid>,"<v4>","<v6>" (quoted or bare) -> { addr, v6 } or null.
// The T700 reuses the CGCONTRDP dotted-decimal encoding in the v4 slot:
//   - <0×8, 0,1, 0,0><v4>  — an EMBEDDED IPv4: the network serves v4 even on
//     the ipv6 PDP (field-verified: 13/14.x pool (anonymized), ping 3/3 through the address)
//   - any other 16-octet token — a dotted-decimal IPv6 (decoded)
//   - exactly 4 octets — a plain IPv4
// The second (v6) slot is taken verbatim only as a plain colon-hex address;
// dotted-decimal 32-octet addr+mask tokens are deliberately NOT decoded
// (IPv6 stays untested on this device — no live v6 session was ever observed).
// Passing an embedded/decoded token through as "ipv4" printed garbage on the
// status page and routed nothing.
export function parse_cgpaddr(lines)
{
	let v4 = null, v6 = null;

	for (let l in (lines ?? [])) {
		let m = match(l, /\+CGPADDR:\s*[0-9]+\s*,\s*"?([0-9a-fA-F:.]+)"?(\s*,\s*"?([0-9a-fA-F:.]*)"?)?/);

		if (!m)
			continue;

		// a colon-hex v6 in the v4 slot (never field-seen on the T700 — the
		// firmware always uses the dotted-decimal encoding — but the wide slot
		// regex must not drop the whole line on one)
		if (index(m[1], ':') >= 0) {
			v6 = m[1];
		}
		else {
			let t1 = split(m[1], '.');

			if (length(t1) == 4 && match(m[1], /^[0-9]+\.[0-9.]+$/)) {
				v4 = m[1];
			}
			else {
				let ev4 = embedded_v4(t1);

				if (ev4)
					v4 = join('.', ev4);
				else if (length(t1) == 16)
					v6 = bytes_to_ipv6(slice(t1, 0, 16));
			}
		}

		// the second (v6) slot is optional — 3GPP allows a single address on a
		// single-family PDP (v4-only), where the two-slot regex used to fail
		// the whole line
		if (match(m[3] ?? '', /^[0-9a-fA-F:]+$/))
			v6 = m[3];
	}

	return (v4 || v6) ? { addr: v4, v6: v6 } : null;
};

// parse AT+ESLOTSINFO? — per-slot [cpin, present, kind, atr, eid, iccid]
// (field-verified on the FM350-GL: field 5 carries the EID on the eUICC slot
// and is empty on the USIM slot; the eUICC reports CPIN EMPTY_EUICC when no
// profile is provisioned)
export function parse_eslotsinfo(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /^\+ESLOTSINFO:\s*([0-9]+)\s*,\s*(.*)$/);

		if (!m)
			continue;

		let n = +m[1];
		let toks = split(replace(m[2], /"/g, ''), /,\s*/);
		let slots = [];

		for (let i = 0; i < n && (i + 1) * 6 <= length(toks); i++) {
			let b = i * 6;

			push(slots, {
				cpin: trim(toks[b] ?? '') || null,
				present: trim(toks[b + 1] ?? '') == '1',
				kind: trim(toks[b + 2] ?? '') == '1' ? 'euicc' : 'usim',
				atr: trim(toks[b + 3] ?? '') || null,
				eid: trim(toks[b + 4] ?? '') || null,
				iccid: trim(toks[b + 5] ?? '') || null,
			});
		}

		return slots;
	}

	return null;
};


// --- dial methods (per-modem resolved at bring-up) ---------------------------
//
// A "dial method" binds/unbinds the cdc_ncm netdev to the active bearer and
// (optionally) reports the binding state. Resolved PER MODEM at bring-up (it
// varies within a vendor by platform): a method carrying a `probe` command is
// adopted only if the modem answers OK; the vendor's `dials` are tried in order
// and always fall back to the 3GPP CGACT dial, which every 3GPP modem supports.
//
// >>> HW (RG650E-EU): AT+QNETDEVCTL=? -> ERROR. The Quectel RG5xx/SDX 5G modems
//     do NOT implement QNETDEVCTL, so they resolve to CGACT. QNETDEVCTL stays
//     the preferred method for the (older/LTE) Quectel modems that do have it.
//
//   probe:                     support-probe command (OK => supported); null = always
//   connect(cid, cfg) / disconnect(cid, cfg)
//   status / status_state(lines, cid)  -> 1 up / 0 down / null unknown

// 3GPP-standard dial: activate/deactivate the PDP context. Universal fallback.
//   AT+CGACT=<state>,<cid>   ;  AT+CGACT? -> +CGACT: <cid>,<state> (state 1=active)
export const DIAL_CGACT = {
	name: 'cgact',
	probe: null,
	connect: (cid) => sprintf('AT+CGACT=1,%d', cid),
	disconnect: (cid) => sprintf('AT+CGACT=0,%d', cid),
	status: 'AT+CGACT?',
	status_state: (lines, cid) => {
		for (let l in (lines ?? [])) {
			let m = match(l, /\+CGACT:\s*([0-9]+),([0-9]+)/);

			if (m && +m[1] == cid)
				return +m[2];
		}
		return null;
	},
};

// Quectel QNETDEVCTL (older/LTE Quectel; NOT the RG5xx/SDX 5G modems).
//   AT+QNETDEVCTL=<op>,<cid>,<urc>  (op 1=connect, 0=disconnect)
//   AT+QNETDEVCTL? -> +QNETDEVCTL: <op>,<cid>,<urc>,<state> (state 1=bound)
const DIAL_QNETDEVCTL = {
	name: 'qnetdevctl',
	probe: 'AT+QNETDEVCTL=?',
	connect: (cid) => sprintf('AT+QNETDEVCTL=1,%d,1', cid),
	disconnect: (cid) => sprintf('AT+QNETDEVCTL=0,%d,0', cid),
	status: 'AT+QNETDEVCTL?',
	status_state: (lines, cid) => {
		for (let l in (lines ?? [])) {
			let m = match(l, /\+QNETDEVCTL:\s*([0-9]+),([0-9]+),([0-9]+),([0-9]+)/);

			if (m && +m[2] == cid)
				return +m[4];
		}
		return null;
	},
};

// MeiG ECMDUP dial.
//   AT+ECMDUP=<pdpid>,<action>[,<pdp_type>]  (action 1=connect, 0=disconnect;
//   pdp_type 0=IPv4, 1=IPv6, 2=IPv4v6 — omitting it dials IPv4 only, so pass
//   it explicitly; HW-verified on SLM770A-R)
//   AT+ECMDUP? -> +ECMDUP: <pdpid>,<v4status>,"IPV4",<v6status>,"IPV6"
const ECMDUP_TYPE = { ipv4: 0, ipv6: 1, ipv4v6: 2 };

const DIAL_ECMDUP = {
	name: 'ecmdup',
	probe: null,
	connect: (cid, cfg) => sprintf('AT+ECMDUP=%d,1,%d', cid,
		ECMDUP_TYPE[cfg?.pdp_type ?? 'ipv4v6'] ?? 2),
	disconnect: (cid) => sprintf('AT+ECMDUP=%d,0', cid),
	status: 'AT+ECMDUP?',
	status_state: (lines, cid) => {
		for (let l in (lines ?? [])) {
			let m = match(l, /\+ECMDUP:\s*([0-9]+),([0-9]+),"IPV4",([0-9]+),"IPV6"/);

			if (m && +m[1] == cid)
				return (+m[2] == 1 || +m[3] == 1) ? 1 : 0;
		}
		return null;
	},
};

// Huawei ^NDISDUP (carries apn/auth inline); ^NDISSTATQRY reports status.
const DIAL_NDISDUP = {
	name: 'ndisdup',
	probe: null,
	connect: (cid, cfg) => {
		let apn = cfg.apn ?? '';

		if (cfg.username || cfg.password)
			return sprintf('AT^NDISDUP=%d,1,"%s","%s","%s",%d', cid, apn,
				cfg.username ?? '', cfg.password ?? '', auth_value(cfg));

		return sprintf('AT^NDISDUP=%d,1,"%s"', cid, apn);
	},
	disconnect: (cid) => sprintf('AT^NDISDUP=%d,0', cid),
	status: 'AT^NDISSTATQRY?',
	status_state: (lines) => {
		for (let l in (lines ?? [])) {
			let m = match(l, /\^NDISSTAT[A-Z]*:\s*([0-9]+)/);

			if (m)
				return +m[1];   // 1 = connected
		}
		return null;
	},
};

// Sierra !SCACT dial.
const DIAL_SCACT = {
	name: 'scact',
	probe: null,
	connect: (cid) => sprintf('AT!SCACT=1,%d', cid),
	disconnect: (cid) => sprintf('AT!SCACT=0,%d', cid),
	status: 'AT!SCACT?',
	status_state: (lines, cid) => {
		for (let l in (lines ?? [])) {
			let m = match(l, /!SCACT:\s*([0-9]+),([0-9]+)/);

			if (m && +m[1] == cid)
				return +m[2];
		}
		return null;
	},
};

// Sony *ENAP dial.
const DIAL_ENAP = {
	name: 'enap',
	probe: null,
	connect: (cid) => sprintf('AT*ENAP=1,%d', cid),
	disconnect: () => 'AT*ENAP=0',
	status: 'AT*ENAP?',
	status_state: (lines) => {
		for (let l in (lines ?? [])) {
			let m = match(l, /\*ENAP:\s*([0-9]+)/);

			if (m)
				return +m[1];
		}
		return null;
	},
};

// Samsung attach dial (CGATT); no per-context status.
const DIAL_CGATT = {
	name: 'cgatt',
	probe: null,
	connect: () => 'AT+CGATT=1',
	disconnect: () => 'AT+CGATT=0',
	status: null,
	status_state: () => null,
};

// ZTE/Marvell ZGACT (by profile id).
const DIAL_ZGACT = {
	name: 'zgact',
	probe: null,
	connect: (cid) => sprintf('AT+ZGACT=1,%d', cid),
	disconnect: (cid) => sprintf('AT+ZGACT=0,%d', cid),
	status: null,
	status_state: () => null,
};

// MikroTik ZGACT (by context TYPE, not profile id).
const DIAL_ZGACT_TYPE = {
	name: 'zgact_type',
	probe: null,
	connect: (cid, cfg) => sprintf('AT+ZGACT=1,%d', CTX_TYPE[cfg.pdp_type ?? 'ipv4v6'] ?? 3),
	disconnect: () => 'AT+ZGACT=0,1',
	status: null,
	status_state: () => null,
};

// Spreadtrum/UNISOC: opaque connmanctl ndisdial blobs (verbatim from ncm.json).
const DIAL_SPTZCMD = {
	name: 'sptzcmd',
	probe: null,
	connect: () => 'AT+SPTZCMD="Y29ubm1hbmN0bCBuZGlzZGlhbCBBVF5ORElTRFVOPSJ1c2IwIiwxLDE="',
	disconnect: () => 'AT+SPTZCMD="Y29ubm1hbmN0bCBuZGlzZGlhbCBBVF5ORElTRFVOPSJ1c2IwIiwwLDE="',
	status: null,
	status_state: () => null,
};

// Fibocom GTRNDIS (best-effort).
const DIAL_GTRNDIS = {
	name: 'gtrndis',
	probe: 'AT+GTRNDIS=?',
	connect: (cid) => sprintf('AT+GTRNDIS=1,%d', cid),
	disconnect: (cid) => sprintf('AT+GTRNDIS=0,%d', cid),
	status: 'AT+GTRNDIS?',
	status_state: (lines, cid) => {
		for (let l in (lines ?? [])) {
			let m = match(l, /\+GTRNDIS:\s*([0-9]+),([0-9]+)/);

			if (m && +m[2] == cid)
				return +m[1];
		}
		return null;
	},
};

// Telit #ECM (best-effort).
const DIAL_TECM = {
	name: 'ecm',
	probe: null,
	connect: (cid) => sprintf('AT#ECM=%d,0', cid),
	disconnect: () => 'AT#ECMD=0',
	status: null,
	status_state: () => null,
};

// SIMCom $QCRMCALL (best-effort).
const DIAL_QCRMCALL = {
	name: 'qcrmcall',
	probe: null,
	connect: (cid) => sprintf('AT$QCRMCALL=1,%d', cid),
	disconnect: (cid) => sprintf('AT$QCRMCALL=0,%d', cid),
	status: null,
	status_state: () => null,
};

// Meig (Qualcomm platform): 5-arg $QCRMCALL rmnet/ncm data call.
const DIAL_QCRMCALL_MEIG = {
	name: 'qcrmcall_meig',
	probe: null,
	connect: (cid) => sprintf('AT$QCRMCALL=1,0,3,2,%d', cid),
	disconnect: (cid) => sprintf('AT$QCRMCALL=0,0,3,2,%d', cid),
	status: null,
	status_state: () => null,
};

// Gosuncn / ZTE ME-series: +ZECMCALL brings the ECM data call up (no cid arg).
const DIAL_ZECMCALL = {
	name: 'zecmcall',
	probe: null,
	connect: (cid) => 'AT+ZECMCALL=1',
	disconnect: (cid) => 'AT+ZECMCALL=0',
	status: null,
	status_state: () => null,
};

// Neoway (Unisoc): $MYUSBNETACT toggles the usbnet data call.
const DIAL_MYUSBNETACT = {
	name: 'myusbnetact',
	probe: null,
	connect: (cid) => 'AT$MYUSBNETACT=0,1',
	disconnect: (cid) => 'AT$MYUSBNETACT=0,0',
	status: null,
	status_state: () => null,
};

// Telit (Qualcomm): #ICMAUTOCONN drives the IPCM auto-connect data call.
const DIAL_ICMAUTOCONN = {
	name: 'icmautoconn',
	probe: null,
	connect: (cid) => sprintf('AT#ICMAUTOCONN=1,%d', cid),
	disconnect: (cid) => sprintf('AT#ICMAUTOCONN=0,%d', cid),
	status: null,
	status_state: () => null,
};

// Per-manufacturer AT recipe. Recipes with concrete commands are ported from
// OpenWrt's /etc/gcom/ncm.json (the reference NCM implementation) and are
// authoritative; the ones marked "best-effort" come from vendor docs and want a
// hardware check.
//
//   modem_init:               commands run ONCE at modem bring-up (e.g. CFUN=1)
//   define(cid, pdp, apn)     -> the context-definition command (default CGDCONT)
//   auth_cmd(cid, ctxtype, apn, cfg) -> the command carrying username/password
//                                       (or null when the dial/define carries it)
//   auth_cmds(...)            -> same, but a LIST: a best-effort auth chain (the
//                                setup sequence is error-tolerant, so a vendor
//                                whose platforms disagree on the auth command
//                                offers both and the firmware takes the one it
//                                knows). Precedence over auth_cmd.
//   ip_config(modem, cid, cfg, cb)  -> optional: cb(err, rdp) with the
//                                parse_cgcontrdp shape for the assigned IP —
//                                vendors whose CGCONTRDP does not carry the
//                                address supply their own reader (default:
//                                generic AT+CGCONTRDP read)
//   dials:                    ordered dial methods to resolve (probed at bring-up)
//   stats / parse_stats(lines)  -> { tx_bytes, rx_bytes } (or null)
export const VENDORS = {
	// Quectel: QICSGP carries apn+user+pass+auth. Prefer QNETDEVCTL, fall back
	// to CGACT for the RG5xx/SDX 5G modems (RG650E) that lack it. QGDCNT counters.
	quectel: {
		match: /quectel/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => sprintf(
			'AT+QICSGP=%d,%d,"%s","%s","%s",%d', cid, ctxtype, apn,
			cfg.username ?? '', cfg.password ?? '', auth_value(cfg)),
		dials: [ DIAL_QNETDEVCTL, DIAL_CGACT ],
		stats: 'AT+QGDCNT?',
		parse_stats: (lines) => {
			for (let l in (lines ?? [])) {
				let m = match(l, /\+QGDCNT:\s*([0-9]+),([0-9]+)/);

				if (m)
					return { tx_bytes: +m[1], rx_bytes: +m[2] };
			}
			return null;
		},
	},

	// MeiG Smart SLM7xx / SLM8xx (ASR platform). Its own dial + auth commands
	// (verified against the SLM770A AT manual — NOT Quectel-compatible):
	//   AT^AUTHDATA=<cid>,<auth>,<PLMN>,<password>,<username>   (auth 0/1/2)
	//   AT^DSFLOWQRY  -> ^DSFLOWQRY: <ds_time>,<tx>,<rx>,<tot_time>,<tot_tx>,<tot_rx>
	//                    (all fields HEXADECIMAL)
	meig: {
		match: /meig/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => {
			if (!cfg.username && !cfg.password)
				return null;

			// AUTHDATA auth enum is 0/1/2 (no combined PAP-or-CHAP); clamp
			let a = auth_value(cfg);

			if (a > 2)
				a = 1;   // "both" -> PAP (most widely accepted)

			// order: <cid>,<auth>,<PLMN(empty)>,<password>,<username>
			return sprintf('AT^AUTHDATA=%d,%d,,%s,%s', cid, a,
				cfg.password ?? '', cfg.username ?? '');
		},
		dials: [ DIAL_ECMDUP, DIAL_QCRMCALL_MEIG, DIAL_CGACT ],
		stats: 'AT^DSFLOWQRY',
		parse_stats: (lines) => {
			for (let l in (lines ?? [])) {
				// six hex fields; totals are fields 5 (tx) and 6 (rx)
				let m = match(l, /\^DSFLOWQRY:\s*[0-9a-fA-F]+,[0-9a-fA-F]+,[0-9a-fA-F]+,[0-9a-fA-F]+,([0-9a-fA-F]+),([0-9a-fA-F]+)/);

				if (m)
					return { tx_bytes: hex(m[1]), rx_bytes: hex(m[2]) };
			}
			return null;
		},
	},

	// Huawei: ^NDISDUP carries apn/auth inline.
	huawei: {
		match: /huawei/,
		// disable the modem's internal auto-dialer so it does not connect behind
		// wwand's back (best-effort; modems without it just warn). QModem disables
		// it in the hangup path — we do it once at init so it never races the
		// daemon-owned context (parity with the RG502Q autoconnect reclaim).
		modem_init: [ 'AT^SETAUTODIAL=0' ],
		auth_cmd: null,
		dials: [ DIAL_NDISDUP, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Sierra Wireless / Netgear: $QCPDPP sets auth (password THEN username);
	// !SCACT activates. Ported from ncm.json.
	sierra: {
		match: /sierra|netgear/,
		// Sierra gates ALL vendor `AT!` commands (USBCOMP / SCACT / BAND / SELRAT)
		// behind a service unlock — without it every `AT!` returns ERROR and the
		// dial/mode/band config silently fails. "A710" is the common factory
		// password (QModem's default); best-effort at init.
		modem_init: [ 'AT!ENTERCND="A710"', 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT$QCPDPP=%d,%d,"%s","%s"', cid, auth_value(cfg),
				cfg.password ?? '', cfg.username ?? '')
			: sprintf('AT$QCPDPP=%d,0', cid),
		dials: [ DIAL_SCACT, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Sony: *EIAAUW sets auth; *ENAP activates. Ported from ncm.json.
	sony: {
		match: /sony/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => sprintf(
			'AT*EIAAUW=%d,1,"%s","%s",%d', cid,
			cfg.username ?? '', cfg.password ?? '', auth_value(cfg)),
		dials: [ DIAL_ENAP, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Samsung: attach-based (CGATT). Ported from ncm.json (init trimmed to CFUN=1).
	samsung: {
		match: /samsung/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: AUTH_CGAUTH,
		dials: [ DIAL_CGATT, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// ZTE / Marvell: ZGDCONT defines, ZGPCOAUTH sets auth, ZGACT activates.
	// Ported from ncm.json.
	zte: {
		match: /zte|marvell/,
		modem_init: [ 'AT+CFUN=1' ],
		define: (cid, pdp, apn) => sprintf('AT+ZGDCONT=%d,"%s","%s","",0,0', cid, pdp, apn),
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT+ZGPCOAUTH=%d,"%s","%s",%d', cid,
				cfg.username ?? '', cfg.password ?? '', auth_value(cfg))
			: null,
		dials: [ DIAL_ZGACT, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// MikroTik integrated (R11e-LTE etc.): ZGDCONT + ZGACT on the context TYPE.
	// Ported from ncm.json (CFUN=4/CFUN=1 wrap dropped — set via at_init if needed).
	mikrotik: {
		match: /mikrotik/,
		modem_init: [ 'AT+CFUN=1' ],
		define: (cid, pdp, apn) => sprintf('AT+ZGDCONT=%d,"%s","%s",0', cid, pdp, apn),
		auth_cmd: null,
		dials: [ DIAL_ZGACT_TYPE, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// MediaTek (mtk1 in ncm.json): plain CGACT bring-up (the M-* data call is an
	// MBIM/PPP handoff, out of scope for the cdc_ncm datapath).
	mediatek: {
		match: /mediatek|mtk/,
		modem_init: [ 'AT+CFUN=1' ],
		define: (cid, pdp, apn) => sprintf('AT+CGDCONT=%d,"%s","%s",0,0', cid, pdp, apn),
		auth_cmd: AUTH_CGAUTH,
		dials: [ DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Spreadtrum/UNISOC: opaque +SPTZCMD blobs (verbatim from ncm.json).
	spreadtrum: {
		match: /spreadtrum|unisoc|spreadtr/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: AUTH_CGAUTH,
		dials: [ DIAL_SPTZCMD, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Fibocom (best-effort): GTRNDIS binds the RNDIS/NCM netdev. Auth is the
	// Fibocom-specific +MGAUTH on the Qualcomm platforms (FM150/FM350 reject/
	// ignore +CGAUTH) — the MediaTek T700 module (FM350-GL, RNDIS compositions
	// only) does not document it, so offer BOTH in sequence: the setup sequence
	// is error-tolerant and whichever the firmware knows sticks, the other logs
	// a warn. NOTE the FM350-GL lacks GTRNDIS entirely — its +GTRNDIS=? probe
	// errors and the CGACT fallback dials (forum-verified recipe).
	//
	// ip_config: the FM350-GL (T700) leaves the CGCONTRDP local/subnet fields
	// EMPTY (gateway+dns only) — the real address comes from CGPADDR. Gate on
	// the RAW line (two adjacent empty quoted fields) BEFORE the position-
	// tolerant parser misreads the gateway as the local address. The static
	// path keeps the /32 p2p model: address from CGPADDR, NO gateway — the
	// netifd default is a plain device route, and the daemon disables ARP on
	// the rndis_host netdev so no neighbour resolution is needed (field-
	// verified). IPv6 keeps whatever CGCONTRDP/CGPADDR reported (parity).
	// Qualcomm FM150/FM350 fill CGCONTRDP and take the generic path — no
	// CGPADDR is sent there.
	fibocom: {
		match: /fibocom/,
		modem_init: [ 'AT+CFUN=1',
			// unsolicited registration/network events (the T700's intended
			// dial model — see mrhaav/atc + the FM350 forum thread). Field-
			// verified on the mode-40 AT port; the modem_ncm on_urc handler
			// wires them into the state machine (register fast-path, +CGEV
			// pokes, +CTZV NITZ).
			'AT+CREG=3;+CGREG=3;+CEREG=3;+C5GREG=3;+CGEREP=2,1',
			'AT+CTZR=1' ],
		// 0 = unlocked, 1 = one-time, 2 = locked at every power-up (fm350_fcc_unlock.sh)
		fcc_probe: 'AT+GTFCCEFFSTATUS?',
		// eSIM surface probes (FM350 AT manual V2.10 + MTK RIL field
		// evidence): +SIMTYPE? 0=USIM 1=ESIM; +ESLOTSINFO? per-slot
		// CPIN/present/EID (undocumented but field-verified on FM350s);
		// +EID fallback. NOTE: +ESIMS is NOT an eSIM command — it is the
		// legacy MTK SIM-presence query (0/1 = SIM inserted; its set form
		// only toggles the URC, and =? rejects with CME ERROR by design).
		esims_probes: [ 'AT+SIMTYPE?', 'AT+ESLOTSINFO?', 'AT+EID' ],
		auth_cmds: (cid, ctxtype, apn, cfg) => {
			if (!cfg.username && !cfg.password)
				return [];

			// MGAUTH then CGAUTH (the T700 takes both; the stock 3GPP form
			// goes through the shared builder — never restate it inline)
			return [
				sprintf('AT+MGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
					cfg.username ?? '', cfg.password ?? ''),
				AUTH_CGAUTH(cid, ctxtype, apn, cfg),
			];
		},
		ip_config: (modem, cid, cfg, cb) => {
			// best-effort resolver read from the T700's canonical DNS query
			// (AT+GTDNS=<cid> — mrhaav/forum field notes recommend it over
			// CGCONTRDP on this module family). Any 4-octet v4, colon-hex v6
			// or 16/32-octet dotted v6 token in the reply counts.
			let dns_from_gt = (done) => {
				modem.at.send(sprintf('AT+GTDNS=%d', cid), (e3, r3) => {
					if (e3 || !r3?.lines)
						return done(null);

					// Split BY FAMILY. GTDNS (manual 12.2.17) answers
					// <cid>,<Primary_DNS_addr>,<Secondary_DNS_addr> for whichever
					// families the PDP carries, and the flat list this used to
					// return was assigned wholesale to ipv4.dns — which is how
					// two IPv6 resolvers ended up in the v4 bucket on the live
					// WH3000.
					let v4 = [], v6 = [];

					for (let l in r3.lines) {
						for (let tok in split(replace(l, /"/g, ''), /[, \t]+/)) {
							let g = dotted_group(tok);

							if (g) {
								// an embedded-v4 token is never a resolver —
								// skip it rather than decoding a garbage v6
								if (g.ev4)
									continue;

								if (g.n == 4)
									push(v4, tok);
								else if (g.n == 16 || g.n == 32)
									push(v6, bytes_to_ipv6(slice(g.parts, 0, 16)));
							}
							else if (tok != '::' &&
							         match(tok, /^[0-9a-fA-F:]+:[0-9a-fA-F:]+$/) && index(tok, '.') < 0)
								push(v6, tok);
						}
					}

					done((length(v4) || length(v6)) ? { v4: v4, v6: v6 } : null);
				}, { timeout: 8000 });
			};

			// Assemble the final buckets. Resolvers come from GTDNS (documented,
			// NAMED per family) and fall back to the CGCONTRDP DNS slots of the
			// same family — never across families, and never from an address
			// slot. A v6-DNS-only bucket keeps its resolvers so the shim can
			// push them without inventing an address.
			let finish_dns = (v4, v6, rdp, v6_pair) => dns_from_gt((gdns) => {
				let d4 = (length(gdns?.v4 ?? []) ? gdns.v4 : null) ?? (rdp.ipv4?.dns ?? []);
				let d6 = (length(gdns?.v6 ?? []) ? gdns.v6 : null)
					?? (length(rdp.ipv6?.dns ?? []) ? rdp.ipv6.dns : null)
					?? (v6_pair ?? []);

				if (v4)
					v4.dns = d4;

				if (v6)
					v6.dns = d6;

				// a v4-only bucket must not lose the v6 resolvers the network
				// advertised: with no v6 bucket to carry them they ride along
				// (netifd sorts DNS by family when it installs them)
				if (v4 && !v6 && length(d6))
					v4.dns = [ ...d4, ...d6 ];

				cb(null, { ipv4: v4, ipv6: v6 });
			});

			modem.at.send(sprintf('AT+CGCONTRDP=%d', cid), (err, res) => {
				if (err)
					return cb(err);

				let rdp = parse_cgcontrdp(res?.lines);

				// 3GPP-correct (verified against atc.sh + patrakov's review):
				// an ipv6-only PDP carries NO host v4. The T700's embedded
				// <0×8, 0,1, 0,0><v4> CGPADDR form is the modem-CLAT artifact
				// and must not be assigned — host v4 on such networks comes
				// from the separate 464xlat package (jool, wan_4).
				if (cfg.pdp_type == 'ipv6')
					rdp.ipv4 = null;

				// the empty-local form: the two fields right after the APN
				// (local, subnet) are empty. Match POSITIONALLY — the modem's
				// quoting varies (""…"" normally, BARE empty fields right
				// after a CFUN cycle — field-seen, where the old quote-regex
				// gate slipped and the gateway token became the address) and
				// a bare `,,` scan would false-hit the trailing empty slots
				// every line carries. Only the CGCONTRDP data line counts:
				// wrapped continuation lines (no cid prefix) have empty
				// fields 3/4 and would hijack the static path on a FILLED
				// response.
				let is_empty_local = (l) => {
					let parts = split(replace(l, /"/g, ''), /\s*,\s*/);

					if (!match(trim(parts[0] ?? ''), /^\+CGCONTRDP:\s*[0-9]+$/))
						return false;

					return (trim(parts[3] ?? '') == '' && trim(parts[4] ?? '') == '');
				};

				// the pair-in-addr-slots form (field-seen right after a
				// PDP-type change — the modem settles on the empty-local form
				// a minute later): fields 3+4 hold the gateway+DNS tokens —
				// two same-length dotted tokens (4 = the v4 gw+dns pair,
				// 16 = the DNS64 pair) and NOTHING follows them (field 5
				// empty — a real v6 assignment carries dns tokens behind its
				// addr+gateway pair; a real v4 assignment is a masked
				// 8-octet addr token in field 3).
				let is_pair_form = (l) => {
					let parts = split(replace(l, /"/g, ''), /\s*,\s*/);

					if (!match(trim(parts[0] ?? ''), /^\+CGCONTRDP:\s*[0-9]+$/))
						return false;

					if (trim(parts[5] ?? '') != '')
						return false;

					let t3 = split(trim(parts[3] ?? ''), '.');
					let t4 = split(trim(parts[4] ?? ''), '.');

					if (length(t3) != length(t4) || !match(parts[3] ?? '', /^[0-9.]+$/) ||
					    !match(parts[4] ?? '', /^[0-9.]+$/))
						return false;

					return (length(t3) == 4 || length(t3) == 16);
				};

				// one pass over the raw lines: the empty-local/pair forms
				// (both take the static CGPADDR path), AND — for lines
				// WITHOUT them — whether they carry a real 16/32-octet v6
				// assignment (v6 tokens OUTSIDE those lines are an address;
				// tokens ON them are the DNS pair — field-analyzed)
				let static_path = false;
				let v6_real = false;
				let pair_line = false;

				for (let l in (res?.lines ?? [])) {
					if (is_empty_local(l) || is_pair_form(l)) {
						static_path = true;
						pair_line = pair_line || is_pair_form(l);
						continue;
					}

					for (let tok in split(replace(l, /"/g, ''), /[, \t]+/)) {
						let g = dotted_group(tok);

						if (g && (g.n == 16 || g.n == 32))
							v6_real = true;
					}
				}

				// On an ipv6-only PDP the CGCONTRDP v6 tokens are NEVER a host
				// assignment — host v6 arrives via the modem's RA/SLAAC
				// (field-verified twice).
				if (cfg.pdp_type == 'ipv6')
					v6_real = false;

				// The address slot decides, not a heuristic: parse_cgcontrdp
				// only fills `addr` from 3GPP fields 3/4, so an empty local
				// slot now yields addr == null instead of promoting a resolver.
				// CGPADDR (manual 12.2.5) is the documented address source and
				// is asked whenever CGCONTRDP carried none.
				let need_cgpaddr = static_path || cfg.pdp_type == 'ipv6' ||
				                   rdp.ipv4?.addr == null;

				// the pair-in-address-slots transient (field-seen right after a
				// PDP-type change): fields 3+4 hold the resolver PAIR, not an
				// address. The parser cannot tell — those ARE the address slots
				// — so the vendor hands the two tokens on as DNS instead.
				let v6_pair = pair_line
					? filter([ rdp.ipv6?.addr, rdp.ipv6?.gateway ], (x) => x != null)
					: [];

				if (!need_cgpaddr)
					return finish_dns(rdp.ipv4, v6_real ? rdp.ipv6 : null, rdp, v6_pair);

				modem.at.send(sprintf('AT+CGPADDR=%d', cid), (e2, r2) => {
					if (e2)
						return cb(e2);

					let a = parse_cgpaddr(r2?.lines);

					// The CGPADDR v6 slot is the network-assigned INTERFACE
					// IDENTIFIER with a zeroed prefix (3GPP: the /64 arrives by
					// RA) — "0:0:0:0:4682:5956:c6d6:e2c5" on the live FM350. It
					// is never a host address, so it is not one here either;
					// only a real field-3 assignment counts.
					let v6 = v6_real ? rdp.ipv6
						: ((cfg.pdp_type == 'ipv6' || length(rdp.ipv6?.dns ?? []))
							? { addr: null, plen: null, gateway: null, dns: [] }
							: null);

					let v4 = null;

					if (cfg.pdp_type != 'ipv6' && (a?.addr ?? rdp.ipv4?.addr))
						v4 = {
							addr: a?.addr ?? rdp.ipv4.addr,
							prefix: null,   // /32 p2p, gateway-less (NOARP device route)
							gateway: null,
							dns: [],   // filled below
							mtu: null,
						};

					finish_dns(v4, v6, rdp, v6_pair);
				}, { timeout: 8000 });
			}, { timeout: 15000 });
		},
		// dual-SIM surface (field-verified): SUB1 = the physical SIM,
		// SUB2 = the built-in eSIM; AT+GTDUALSIM=<0|1> switches the active
		// card (the current registration drops, the modem re-reads the SIM)
		slots: {
			query: 'AT+GTDUALSIM?',
			parse: (lines) => {
				for (let l in (lines ?? [])) {
					let m = match(l, /\+GTDUALSIM\s*:\s*([0-9]+)\s*,\s*"SUB([0-9]+)"\s*,\s*"([^"]*)"/);

					if (m)
						return { active: +m[1], sub: +m[2], service: m[3] };
				}
				return null;
			},
			switch: (n) => sprintf('AT+GTDUALSIM=%d', n - 1),
		},
		dials: [ DIAL_GTRNDIS, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Telit (best-effort): #ECM binds the ECM netdev. Auth via CGAUTH.
	telit: {
		match: /telit/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: AUTH_CGAUTH,
		dials: [ DIAL_TECM, DIAL_ICMAUTOCONN, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// SIMCom (best-effort): $QCRMCALL brings the Qualcomm rmnet/ncm call up.
	simcom: {
		match: /simcom/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: AUTH_CGAUTH,
		dials: [ DIAL_QCRMCALL, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Gosuncn / ZTE ME-series: +ZECMCALL data call, CGAUTH auth.
	gosuncn: {
		match: /gosuncn/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: AUTH_CGAUTH,
		dials: [ DIAL_ZECMCALL, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Neoway (Unisoc): $MYUSBNETACT data call, CGAUTH auth.
	neoway: {
		match: /neoway/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: AUTH_CGAUTH,
		dials: [ DIAL_MYUSBNETACT, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// 3GPP-standard fallback: define+auth via CGDCONT/CGAUTH, CGACT dial.
	generic: {
		match: null,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: AUTH_CGAUTH,
		dials: [ DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},
};

// AT+CGMM model families that identify a vendor on their own. The manufacturer
// string is the primary key, but it is the one identify answer a modem may
// withhold (the T700 returns an empty AT+CGMI while a PDN teardown is running).
// The model is answered reliably in the same chain, and these families are
// unambiguous — so a missing/unknown manufacturer falls back to them instead of
// silently degrading the modem to `generic` for the rest of the session.
const MODEL_VENDORS = [
	[ /^(fm[0-9]|fg[0-9]|nl6|l8[0-9][0-9])/, 'fibocom' ],
	[ /^(ec[0-9]|eg[0-9]|em[0-9]|ep[0-9]|rg[0-9]|rm[0-9]|bg[0-9]|ag[0-9]|ux[0-9])/, 'quectel' ],
	[ /^slm[0-9]/, 'meig' ],
	[ /^(me9|mu[0-9]|ms2|brovi|e35|e36|e37)/, 'huawei' ],
	[ /^(le9|ln9|lm9|fn9|he9)/, 'telit' ],
	[ /^sim[0-9]/, 'simcom' ],
	[ /^(em7|em9|mc7|rc7|em06|wp7)/, 'sierra' ],
	[ /^(ml[0-9]|mf[0-9])/, 'zte' ],
];

// pick the vendor recipe from the AT+CGMI manufacturer string, falling back to
// the AT+CGMM model when the manufacturer is empty or unrecognised; generic
// (match null) is skipped in the scan and returned last.
export function vendor_for(manufacturer, model)
{
	let s = lc(manufacturer ?? '');

	// fibocom FIRST: the FM350 family is a MediaTek T700 module, and units
	// whose CGMI reports the die vendor ("MediaTek") instead of the brand
	// must still resolve to the fibocom recipe (its ip_config/slots/eSIM
	// paths), never to the bare mediatek one.
	if (s != '' && VENDORS.fibocom.match && match(s, VENDORS.fibocom.match))
		return VENDORS.fibocom;

	if (s != '')
		for (let name, v in VENDORS)
			if (v.match && match(s, v.match))
				return v;

	let m = lc(model ?? '');

	if (m != '')
		for (let e in MODEL_VENDORS)
			if (match(m, e[0]))
				return VENDORS[e[1]];

	return VENDORS.generic;
};

// recipe -> its key, for logging (the recipes carry no name of their own)
export function vendor_name(v)
{
	for (let name, cand in VENDORS)
		if (cand == v)
			return name;

	return '?';
};

// AT command sequence to program a PDP context + auth from a context config
// (the per-connect setup, NOT the one-time modem_init). An empty/unset APN is
// intentional: a *blank* APN => network default PDN (mirrors context.uc's
// attach-profile behavior). Returns [] for a '#N' pass-through APN (use the
// modem profile as-is, never rewrite it).
export function build_pdp_setup(vendor, cid, cfg)
{
	let apn = cfg.apn;

	if (apn != null && substr(apn, 0, 1) == '#')
		return [];

	let key = cfg.pdp_type ?? 'ipv4v6';
	let pdp = PDP_STR[key] ?? PDP_STR.ipv4v6;
	let ctxtype = CTX_TYPE[key] ?? CTX_TYPE.ipv4v6;
	let target_apn = apn ?? '';   // blank => network default

	// ALWAYS define the standard 3GPP context (AT+CGDCONT) first, so the generic
	// AT+CGACT dial fallback (last entry of every vendor's `dials`) has a valid
	// context to activate even on modems whose vendor define uses a proprietary
	// table (ZTE/MikroTik AT+ZGDCONT). A vendor `define` is then layered ON TOP as
	// an extension (extra columns / vendor NV), not as a replacement.
	let cmds = [ cgdcont(cid, pdp, target_apn) ];

	if (vendor.define)
		push(cmds, vendor.define(cid, pdp, target_apn));

	let acs = vendor.auth_cmds
		? vendor.auth_cmds(cid, ctxtype, target_apn, cfg)
		: null;

	if (acs) {
		for (let c in acs)
			push(cmds, c);
	}
	else {
		let ac = vendor.auth_cmd ? vendor.auth_cmd(cid, ctxtype, target_apn, cfg) : null;

		if (ac)
			push(cmds, ac);
	}

	return cmds;
};

// AT+CGDCONT? read-back: '+CGDCONT: <cid>,"<type>","<apn>",...' per line.
export function parse_cgdcont(lines)
{
	let out = [];

	for (let l in (lines ?? [])) {
		let m = match(l, /\+CGDCONT:\s*([0-9]+)\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"/);

		if (m)
			push(out, { cid: +m[1], pdp_type: m[2], apn: m[3] });
	}

	return out;
};

// dial-time idempotency guard: true when PDP context <cid> already carries
// exactly the configured pdp-type + APN, so the CGDCONT/auth NV writes can be
// skipped. Only usable with no username/password (auth cannot be read back).
export function pdp_setup_matches(cid, cfg, lines)
{
	let want_pdp = PDP_STR[cfg.pdp_type ?? 'ipv4v6'] ?? PDP_STR.ipv4v6;
	let want_apn = lc(cfg.apn ?? '');

	for (let e in parse_cgdcont(lines)) {
		if (e.cid != cid)
			continue;

		return uc(e.pdp_type) == want_pdp && lc(e.apn) == want_apn;
	}

	return false;
};

// per-vendor telemetry blocks (telemetry_ncm.uc) wired onto the VENDORS recipes;
// vendors without an entry inherit the generic block (vendor_telemetry() in
// modem_ncm.uc falls back to telemetry_ncm.GENERIC).
VENDORS.quectel.telemetry = telemetry_ncm.QUECTEL;
VENDORS.meig.telemetry    = telemetry_ncm.MEIG;
VENDORS.huawei.telemetry  = telemetry_ncm.HUAWEI;
VENDORS.fibocom.telemetry = telemetry_ncm.FIBOCOM;
VENDORS.generic.telemetry = telemetry_ncm.GENERIC;
