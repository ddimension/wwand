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

// Values that cannot survive interpolation into a QUOTED AT string. A quoted AT
// argument has no escape mechanism at all, so a `"` ends the argument early and
// the modem answers ERROR; a control character would split the command, which
// atcmd refuses at its choke point.
//
// Either way the command does not take effect — and the setup sequence is
// best-effort, so it steps on and DIALS. The modem then connects with whatever
// PDP profile was already programmed: not the configured APN, no error to the
// user, and a session that looks established. Hence a refusal before the first
// write rather than a warning after it.
export function unsendable_conn(cfg)
{
	for (let f in [ 'apn', 'username', 'password' ]) {
		let v = cfg?.[f];

		if (type(v) != 'string')
			continue;

		if (index(v, '"') >= 0)
			return f;

		// byte-wise: ucode regexes stop at a NUL, so a control byte behind one
		// would read as clean (same reasoning as atcmd's ctrl_at)
		for (let i = 0; i < length(v); i++) {
			let c = ord(v, i);

			if (c < 0x20 || c == 0x7f)
				return f;
		}
	}

	return null;
};

// standard 3GPP context definition — the default `define` for most vendors.
// `alloc` is <IPv4AddrAlloc>, the 7th parameter (3GPP TS 27.007 +CGDCONT:
// 0 = NAS signalling, 1 = DHCP), sent only when the interface asked for one:
// the parameters between are left at their defaults ("" address, 0, 0), and a
// modem that never saw the field keeps its own default.
function cgdcont(cid, pdp, apn, alloc)
{
	if (alloc != null)
		return sprintf('AT+CGDCONT=%d,"%s","%s","",0,0,%d', cid, pdp, apn, alloc);

	return sprintf('AT+CGDCONT=%d,"%s","%s"', cid, pdp, apn);
}

// `address_allocation` (config.uc) as the <IPv4AddrAlloc> number
const ADDR_ALLOC = { nas: 0, dhcp: 1 };

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

// "+CPIN: READY" -> "READY". A token that carries its own AT response header
// is the wire format leaking into a value; anything after the first colon of a
// leading "+NAME:" is the value. A token without one is returned unchanged, so
// a modem that answers properly is not touched.
function strip_at_prefix(tok)
{
	let t = trim(tok ?? '');
	let m = match(t, /^\+[A-Za-z0-9]+:\s*(.*)$/);

	return (m ? trim(m[1]) : t) || null;
}

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
				// THE MODEM PUTS AN AT RESPONSE INSIDE A FIELD. The FM350-GL
				// writes "+CPIN: READY" / "+CPIN: EMPTY_EUICC" where the token
				// is supposed to be the state alone, and it was stored verbatim
				// — so the ubus payload, and the status page under it, printed
				// the wire format at the reader (reported by obsy, 2026-09-12,
				// ddimension/wwand#21). parse_cpin strips exactly this prefix
				// for the modem's own PIN flow; the per-slot field simply never
				// went through it.
				cpin: strip_at_prefix(toks[b]),
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

// --- Fibocom +GTACT: RAT and BAND selection ---------------------------------
// +GTACT is the only band control on the Fibocom T700/Qualcomm families
// (FM350-GL, FM150), so it is what a `band_lte` / `band_nr` option has to
// speak on an AT/NCM modem. It is also the most parser-sensitive command in
// the whole AT surface. The AT manual (V2.10 §11.1.14) documents the
// parameters but not the parser; the rules below were established by
// experiment on an FM350-GL, firmware 81600.0000.00.19.11.17 (evidence:
// ddimension/wwand#43, 2026-09-26):
//
//   read:  AT+GTACT?   ->  +GTACT: <rat>,<act1>,<act2>,<band>...
//   test:  AT+GTACT=?  ->  +GTACT: (rat...),(act1...),(act2...),(gsm...),
//                               (umts...),(lte...),(cdma...),(evdo...),(nr...)
//
// 1. THE FIRST BAND TOKEN IS READ AS A UMTS BAND. The bands after the ACT
//    triple are read in the =? order — umts, lte, cdma, evdo, nr — and a
//    token that is not legal where the parser is aborts the ENTIRE command.
//    Every write the firmware accepted led with a UMTS group:
//      AT+GTACT=20,6,3,1,2,4,5,8,101,103,107,120,128,503,507,5020,5028,5078  OK
//      AT+GTACT=4,3,3,1,2,4,5,8,103          (a single-band B3 lock)       OK
//    and the NR/LTE tuple's OWN read-back, re-sent verbatim, was refused:
//      AT+GTACT=17,3,6,101,103,107,120,128,503,507,5020,5028,5078        ERROR
//    So a band list is written only for the tuples it was proven on
//    (GTACT_WRITABLE); any other tuple is refused with a reason instead of
//    being sent a command its own read-back shows the parser rejects.
//
// 2. THE ACT TRIPLE IS NOT FREE-FORM. A write that omits or contradicts it is
//    refused, so the tuple is PRESERVED here, never synthesised: this codec
//    reads it and writes back exactly what the modem had.
//
// 3. THE WRITE IS NOT NV. The manual's attribute table says Persistent: No,
//    and the mask was field-observed to revert across a power cycle even
//    when the write returned OK. The daemon therefore keeps a band edit in
//    uci and modem_ncm re-applies it at every bring-up — the same survival a
//    QMI band edit gets from the modem's own NV (change_duration permanent).
//
// TRANSPORT SUCCESS IS NOT STATE CHANGE, so every write is verified with a
// read-back before it is reported applied. Applying a mask costs a
// re-registration (20-30 s measured), so an `unchanged` verdict must never
// reach the radio at all.

// The band groups a WRITE carries for each tuple, in parser order. Only the
// two tuples a write was accepted for on hardware (rule 1). Reading is
// tuple-independent: a token's range says which RAT it belongs to.
const GTACT_WRITABLE = {
	'4': [ 'umts', 'lte' ],        // LTE/UMTS
	'20': [ 'umts', 'lte', 'nr' ], // NR-RAN/WCDMA/LTE
};

function gtact_number(v)
{
	let s = trim(sprintf('%s', v ?? ''));

	if (!match(s, /^[0-9]+$/))
		return null;

	return +s;
};

// A band token's RAT group and its 3GPP band number. The encodings are the
// manual's: UMTS directly, LTE as 100+band, NR as 500+band for n1..n9,
// 5000+band for n10..n99 and 50000+band above (50512 is the last it names).
// GSM/CDMA/EVDO have no token here at all — their =? groups answer ().
function gtact_classify(n)
{
	if (n == null || n <= 0)
		return null;

	if (n >= 1 && n <= 10)
		return { rat: 'umts', band: n };
	if (n >= 101 && n <= 171)
		return { rat: 'lte', band: n - 100 };
	if (n >= 501 && n <= 509)
		return { rat: 'nr', band: n - 500 };
	if (n >= 5010 && n <= 5099)
		return { rat: 'nr', band: n - 5000 };
	if (n >= 50100 && n <= 50512)
		return { rat: 'nr', band: n - 50000 };

	return null;
};

// 3GPP band -> +GTACT token, or null when the band has no encoding. NR is
// written in the compact width the module's own read-back uses (500+n up to
// n9, 5000+n up to n99): another documented width risks a value the parser
// rejects or, worse, reads as a different band.
function gtact_token(group, b)
{
	let n = gtact_number(b);

	if (n == null)
		return null;

	if (group == 'umts')
		return (n >= 1 && n <= 10) ? sprintf('%d', n) : null;

	if (group == 'lte')
		return (n >= 1 && n <= 71) ? sprintf('%d', 100 + n) : null;

	if (n < 1 || n > 512)
		return null;

	return sprintf('%d', (n <= 9) ? 500 + n : (n <= 99) ? 5000 + n : 50000 + n);
};

// Order-insensitive set compare: the modem answers its bands in its own
// order, which need not match the order they were configured in.
function same_band_list(a, b)
{
	let key = (l) => join(',', sort(map(l ?? [], (n) => +n), (x, y) => x - y));

	return key(a) == key(b);
};

// QMI MODE_BITS equivalent for the tuples the manual names, so the settings
// editor — which thinks in mode_preference — can show the current RAT choice.
// Read-only metadata: a write preserves the modem's tuple rather than
// translating a QMI bitmask into one.
function fm350_rat_mask(rat)
{
	switch (+rat) {
	case 2:  return 1 << 4;                          // LTE
	case 4:  return (1 << 4) | (1 << 3);             // LTE/UMTS
	case 14: return 1 << 6;                          // NR
	case 16: return (1 << 6) | (1 << 3);             // NR/WCDMA
	case 17: return (1 << 6) | (1 << 4);             // NR/LTE
	case 20: return (1 << 6) | (1 << 3) | (1 << 4);  // NR/WCDMA/LTE
	default: return null;
	}
};

// Band tokens -> { umts, lte, nr } 3GPP band lists; a token no range claims
// (the `0` "automatic", a GSM value) is skipped.
function gtact_bands(tokens)
{
	let out = { umts: [], lte: [], nr: [] };

	for (let t in tokens) {
		let c = gtact_classify(gtact_number(t));

		if (c != null)
			push(out[c.rat], c.band);
	}

	return out;
};

// AT+GTACT? -> { rat, act1, act2, umts_bands, lte_bands, nr_bands, raw },
// or null when no line parses.
export function parse_gtact(lines)
{
	for (let line in (lines ?? [])) {
		let m = match(trim(line), /^\+GTACT:\s*(.*)$/i);

		if (!m)
			continue;

		// NOT map(…, trim): a bare builtin as a map callback is handed the
		// index as its second argument and misreads it, silently.
		let f = map(split(replace(m[1], /"/g, ''), ','), (v) => trim(v));

		if (length(f) < 3)
			return null;

		let rat = gtact_number(f[0]);
		let act1 = gtact_number(f[1]);
		let act2 = gtact_number(f[2]);

		if (rat == null || act1 == null || act2 == null)
			return null;

		let b = gtact_bands(slice(f, 3));

		return {
			rat: rat, act1: act1, act2: act2,
			umts_bands: b.umts, lte_bands: b.lte, nr_bands: b.nr,
			raw: join(',', f),
		};
	}

	return null;
};

// AT+GTACT=? -> { rats, umts, lte, nr } (3GPP band lists the module
// accepts), or null. Each parenthesised group is a comma list; a range
// `a-b` is expanded too, in case another firmware answers in that form.
export function parse_gtact_test(lines)
{
	for (let line in (lines ?? [])) {
		let m = match(trim(line), /^\+GTACT:\s*(.*)$/i);

		if (!m)
			continue;

		let groups = map(match(m[1], /\(([^)]*)\)/g) ?? [], (g) => {
			let toks = [];

			for (let t in split(g[1], ',')) {
				let r = match(trim(t), /^([0-9]+)-([0-9]+)$/);

				if (r && +r[2] >= +r[1] && +r[2] - +r[1] <= 1000)
					for (let n = +r[1]; n <= +r[2]; n++)
						push(toks, sprintf('%d', n));
				else if (trim(t) != '')
					push(toks, trim(t));
			}

			return toks;
		});

		// rat, act1, act2, gsm, umts, lte, cdma, evdo, nr
		if (length(groups) < 9)
			return null;

		return {
			rats: map(groups[0], (t) => +t),
			umts: gtact_bands(groups[4]).umts,
			lte: gtact_bands(groups[5]).lte,
			nr: gtact_bands(groups[8]).nr,
		};
	}

	return null;
};

// The write for a tuple and its RESOLVED groups ({ umts, lte, nr }, every
// group the tuple carries, non-empty): 'AT+GTACT=…', or null when the tuple
// is not one a write is proven for, a group is empty (rule 1: the parser
// needs the UMTS group in front, and an empty group would let the next
// group's tokens be read as its members) or a band has no encoding.
export function build_gtact(state, groups)
{
	let order = GTACT_WRITABLE[sprintf('%d', state?.rat ?? -1)];

	if (order == null || state.act1 == null || state.act2 == null)
		return null;

	let out = [ sprintf('%d', state.rat), sprintf('%d', state.act1), sprintf('%d', state.act2) ];

	for (let g in order) {
		if (!length(groups?.[g] ?? []))
			return null;

		for (let b in groups[g]) {
			let t = gtact_token(g, b);

			if (t == null)
				return null;

			push(out, t);
		}
	}

	return 'AT+GTACT=' + join(',', out);
};

// +GTACT is Fibocom-wide, but the band write is verified only on the T700
// parts; keep the guard to what was actually tested and let anything else
// fall through to the backend's "unsupported" answer. A property of the
// MODEL: an FM350 between two bring-ups (no AT engine) still is one, and
// must not be reported as a modem without a band command.
function gtact_capable(modem)
{
	return match(lc(sprintf('%s', modem?.info?.model ?? '')),
	             /^(fm350|fm150)([ -].*)?$/) != null;
};

// The settings keys that carry each writable group.
const GTACT_KEYS = {
	umts: [ 'umts_bands' ],
	lte: [ 'lte_bands' ],
	nr: [ 'nr5g_sa_bands', 'nr5g_nsa_bands' ],
};

// A band list as the module answers it: numbers, ascending, each once —
// every write accepted on hardware had that shape, and a duplicate would
// make the de-duplicated read-back fail the verify after the radio was
// already disturbed. null when an entry is not a band number.
function band_set(list)
{
	let seen = {}, out = [];

	for (let b in list) {
		let n = gtact_number(b);

		if (n == null)
			return null;

		if (!seen[sprintf('%d', n)]) {
			seen[sprintf('%d', n)] = true;
			push(out, n);
		}
	}

	return sort(out, (x, y) => x - y);
};

function gtact_get(modem, cb)
{
	if (!gtact_capable(modem))
		return cb({ error: 'unsupported_on_backend' });

	// between two bring-ups: the next one applies the configured lists
	if (!modem.at)
		return cb({ error: 'modem_not_ready' });

	let answer = (st) => {
		let caps = modem._gtact_caps;
		let order = GTACT_WRITABLE[sprintf('%d', st.rat)];
		let settable = [];

		for (let g in (order ?? []))
			push(settable, ...GTACT_KEYS[g]);

		cb(null, {
			mode_preference: fm350_rat_mask(st.rat),
			rat: st.rat, act1: st.act1, act2: st.act2,
			umts_bands: st.umts_bands,
			lte_bands: st.lte_bands,
			// ONE NR list, surfaced through both wwand NR lists — the
			// marker keeps a caller from assuming two independent ones
			nr5g_sa_bands: st.nr_bands,
			nr5g_nsa_bands: st.nr_bands,
			nr_bands_shared: true,
			// what a set may carry: band lists only, and none at all on a
			// tuple rule 1 forbids — the editor renders exactly this
			settable: settable,
			settable_note: order ? null :
				sprintf('band lists can be written only while the modem runs RAT tuple 4 (LTE/UMTS) or 20 (NR/WCDMA/LTE); this one runs %d', st.rat),
			supported: caps ? { umts_bands: caps.umts, lte_bands: caps.lte, nr_bands: caps.nr } : null,
			// kept by the daemon in uci, re-applied at bring-up (rule 3)
			persistent: false,
			gtact: st.raw,
		});
	};

	modem.at.send('AT+GTACT?', (err, res) => {
		if (err)
			return cb({ error: 'at', detail: err });

		let st = parse_gtact(res?.lines);

		if (!st)
			return cb({ error: 'invalid_response',
			            detail: 'AT+GTACT? carried no parseable +GTACT line' });

		// the module's band catalogue does not change while it runs, so one
		// good answer is kept; a failed read (a timeout, a firmware without
		// =?) is asked again next time rather than turning off "all bands"
		// and the catalogue check for the life of the modem
		if (modem._gtact_caps || !modem.at)
			return answer(st);

		modem.at.send('AT+GTACT=?', (terr, tres) => {
			modem._gtact_caps = terr ? null : parse_gtact_test(tres?.lines);
			answer(st);
		}, { timeout: 10000 });
	}, { timeout: 10000 });
};

// settings: the keys gtact_get names in `settable` (an absent key leaves that RAT alone; an
// EMPTY list means every band the module supports — the settings editor's
// "nothing ticked = all bands"), plus a mode_preference only if it equals
// the running tuple. cb(err) or cb(null, { applied, unchanged?, verified,
// persistent: false, gtact }).
function gtact_set(modem, settings, cb)
{
	if (!gtact_capable(modem))
		return cb({ error: 'unsupported_on_backend' });

	settings = { ...(settings ?? {}) };

	// +GTACT has ONE NR list, so two distinct wwand NR lists cannot be
	// represented; refuse rather than silently keep one of them.
	if (type(settings.nr5g_sa_bands) == 'array' && type(settings.nr5g_nsa_bands) == 'array' &&
	    !same_band_list(settings.nr5g_sa_bands, settings.nr5g_nsa_bands))
		return cb({ error: 'invalid_setting', key: 'nr5g_bands',
		            detail: 'Fibocom +GTACT exposes one shared NR band list' });

	// The RAT tuple is the operator's, not ours (rule 2): a mode_preference
	// that disagrees with what the modem runs is reported, not translated.
	let want_mode = settings.mode_preference;
	delete settings.mode_preference;

	let want = {};

	for (let key, val in settings) {
		let g = (key == 'lte_bands') ? 'lte'
		      : (key == 'nr5g_sa_bands' || key == 'nr5g_nsa_bands') ? 'nr'
		      : (key == 'umts_bands') ? 'umts' : null;

		if (g == null)
			return cb({ error: 'invalid_setting', key: key,
			            detail: 'Fibocom +GTACT supports band lists only; other NAS preferences stay backend-specific' });

		let set = (type(val) == 'array') ? band_set(val) : null;

		if (set == null)
			return cb({ error: 'invalid_setting', key: key, detail: 'a band list is an array of 3GPP band numbers' });

		want[g] = set;
	}

	if (!length(keys(want)))
		return cb(null, { applied: [], unchanged: true, verified: true, persistent: false });

	gtact_get(modem, (gerr, cur) => {
		if (gerr)
			return cb(gerr);

		if (want_mode != null && want_mode != cur.mode_preference)
			return cb({ error: 'invalid_setting', key: 'mode_preference',
			            detail: '+GTACT writes preserve the modem RAT/preferred-RAT tuple',
			            requested: want_mode, actual: cur.mode_preference });

		let order = GTACT_WRITABLE[sprintf('%d', cur.rat)];

		if (order == null)
			return cb({ error: 'unsupported_tuple', rat: cur.rat, detail: cur.settable_note });

		// a group the tuple does not carry cannot be written — refused, not
		// dropped: an ignored list would be reported unchanged, kept in uci
		// and go live unannounced the day the tuple changes
		for (let g in keys(want))
			if (index(order, g) < 0)
				return cb({ error: 'unsupported_tuple', rat: cur.rat, key: GTACT_KEYS[g][0],
				            detail: sprintf('RAT tuple %d has no %s band group', cur.rat, uc(g)) });

		let now = { umts: cur.umts_bands, lte: cur.lte_bands, nr: cur.nr5g_sa_bands };
		let caps = modem._gtact_caps;
		let target = {};

		for (let g in order) {
			// requested → as given; requested empty → all supported; not
			// requested → what the modem runs (a partial edit must not drop
			// the other RATs' bands), or all supported if it runs none
			let t = (want[g] != null && length(want[g])) ? want[g]
			      : (want[g] == null && length(now[g] ?? [])) ? band_set(now[g])
			      : band_set(caps?.[g] ?? []);

			if (!length(t ?? []))
				return cb({ error: 'invalid_setting', key: g + '_bands',
				            detail: 'the module did not name its supported bands (AT+GTACT=?), so "all bands" cannot be written' });

			// a band the module does not list aborts the whole command
			// (rule 1) — say which one instead of sending it
			if (caps?.[g] != null)
				for (let b in t)
					if (index(map(caps[g], (n) => +n), +b) < 0)
						return cb({ error: 'invalid_setting', key: g + '_bands', band: +b,
						            detail: sprintf('band %s is not one this module supports', b) });

			target[g] = t;
		}

		let changed = filter(order, (g) => want[g] != null && !same_band_list(target[g], now[g]));

		// idempotency: never disturb the radio for a mask it already runs
		if (!length(changed))
			return cb(null, { applied: [], unchanged: true, verified: true,
			                  persistent: false, gtact: cur.gtact });

		// torn down while the read ran: the NCM teardown nulls modem.at
		// without failing what was in flight (see context_ncm read_rdp_once)
		if (!modem.at)
			return cb({ error: 'modem_gone' });

		let cmd = build_gtact(cur, target);

		if (!cmd)
			return cb({ error: 'invalid_setting',
			            detail: 'band list cannot be encoded for this RAT tuple' });

		// Deliberately no reset and no reconnect here: the manual says the
		// write takes effect immediately, and on the tested module it costs
		// exactly one re-registration. The bearer re-establishes itself and
		// wwand's monitor re-adopts the session.
		modem.at.send(cmd, (werr) => {
			if (werr)
				return cb({ error: 'at', detail: werr, command: cmd });

			// verify — transport OK is not state change
			gtact_get(modem, (verr, live) => {
				if (verr)
					return cb({ error: 'verify_read', detail: verr, command: cmd });

				let got = { umts: live.umts_bands, lte: live.lte_bands, nr: live.nr5g_sa_bands };

				for (let g in order)
					if (!same_band_list(target[g], got[g]))
						return cb({ error: 'verify_failed', command: cmd, group: g,
						            expected: target[g], actual: got[g], gtact: live.gtact });

				cb(null, { applied: changed, verified: true, persistent: false,
				           gtact: live.gtact });
			});
		}, { timeout: 10000 });
	});
};

// Per-manufacturer AT recipe. Recipes with concrete commands are ported from
// OpenWrt's /etc/gcom/ncm.json (the reference NCM implementation) and are
// authoritative; the ones marked "best-effort" come from vendor docs and want a
// hardware check.
//
//   modem_init:               commands run ONCE at modem bring-up (e.g. CFUN=1)
//   urcs:                     vendor-specific UNSOLICITED result-code prefixes,
//                             merged into the AT engine's generic 3GPP set once
//                             identify resolves the manufacturer. Only list a
//                             code the modem really pushes on its own: a prefix
//                             here is filtered OUT of that modem's command
//                             responses. A code that shares its name with a
//                             query answer is safe either way (the running
//                             command's own prefix always wins), but one that
//                             names a DIFFERENT command's answer is not.
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
//   settings_capable(modem)  -> true when settings_get/_set can drive THIS
//                               model (the codec's own tested-model guard)
//   settings_get(modem, cb) / settings_set(modem, settings, cb)
//                            -> the vendor's radio/band command, in the NAS
//                               settings shape (see the +GTACT codec above)

export const VENDORS = {
	// Quectel: QICSGP carries apn+user+pass+auth. Prefer QNETDEVCTL, fall back
	// to CGACT for the RG5xx/SDX 5G modems (RG650E) that lack it. QGDCNT counters.
	quectel: {
		match: /quectel/,
		// +QIND carries SMS-full / SIM / PB-done notifications; +QUSIM is pushed
		// on SIM (re)initialisation. Both are notification-only names.
		urcs: [ '+QIND', '+QUSIM' ],
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => sprintf(
			'AT+QICSGP=%d,%d,"%s","%s","%s",%d', cid, ctxtype, apn,
			cfg.username ?? '', cfg.password ?? '', auth_value(cfg)),
		dials: [ DIAL_QNETDEVCTL, DIAL_CGACT ],
		// AT+QIP6CFG: the same profile flag as QMI WDS TLV 0xDF (both
		// directions HW-verified on the RG650E, 2026-10-08), and the prefix
		// the modem holds for <cid>. "::/0" is its untouched default buffer,
		// i.e. none (format strings from the RG650E firmware, read 2026-10-09;
		// answers seen on the RG650E and RM520N-GL).
		pd: {
			read: (cid) => sprintf('AT+QIP6CFG="PD_enable",%d', cid),
			parse: (lines, cid) => {
				for (let l in (lines ?? [])) {
					let m = match(l, /\+QIP6CFG:\s*([0-9]+)\s*,\s*([01])/);

					if (m && +m[1] == cid)
						return +m[2];
				}
				return null;
			},
			write: (cid, v) => sprintf('AT+QIP6CFG="PD_enable",%d,%d', cid, v),
			addr: (cid) => sprintf('AT+QIP6CFG="PD_addr",%d', cid),
			parse_addr: (lines) => {
				for (let l in (lines ?? [])) {
					let m = match(l, /"PD_addr"\s*,\s*[0-9]+\s*,\s*([0-9A-Fa-f:]+)\/([0-9]+)/);

					if (m && +m[2] > 0 && m[1] != '::')
						return sprintf('%s/%d', m[1], +m[2]);
				}
				return null;
			},
		},
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
		// From the SLM770A AT manual's own URC table (AT^CURCEX bit->code map):
		// ^SRVST service state, ^MODE network mode, ^SIMST SIM state,
		// ^SMMEMFULL SMS storage full, ^HCSQ signal quality. Plus the two the
		// manual lists as "active reporting": ^DSFLOWRPT (traffic) and
		// ^RRCSTAT (RRC state changes).
		//
		// ^DSFLOWRPT is the notification; the recipe's stats poll uses
		// AT^DSFLOWQRY, whose answer is ^DSFLOWQRY — a different name, so
		// exact matching keeps the two apart (same shape as Huawei's
		// ^NDISSTAT vs ^NDISSTATQRY). MeiG shares the ^ dialect with Huawei,
		// which is why four of these appear in that recipe too.
		urcs: [ '^SRVST', '^MODE', '^SIMST', '^SMMEMFULL', '^HCSQ',
		        '^DSFLOWRPT', '^RRCSTAT',
		        // the bearer notifications (manual 10.10). Listing them matters
		        // for the window right after AT+ECMDUP, where ^DCONN arrives
		        // INSIDE the command and would otherwise be filed as a response
		        // line and never reach the URC handler. Safe to list: nothing
		        // parses them out of a command's answer (the dial status reads
		        // +ECMDUP:, a different name).
		        '^DCONN', '^DEND' ],
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
		// ^SRVST / ^MODE: the service state and the RAT, pushed. Values from the
		// manual (8.13 table 145, 8.7 table 133):
		//   ^SRVST: 0 = no service, 1 = restricted service, 2 = effective service
		//     (a Cudy LT300 also emits an undocumented 3 in passing, 2026-08-23)
		//   ^MODE: <sys_mode>,<cell_service> — sys 0 = no service, 3 = GSM,
		//     5 = WCDMA, 9 = LTE; cell 71 = FDD LTE, 72 = TDD LTE, 0 = none
		//
		// ^SRVST: 1 is the vendor's own word for the state that shows up as
		// registration <stat> 11 — both were emitted in the same second on every
		// registration cycle observed on the LT300, which is what confirmed the
		// reading of that stat.
		service_urc: (line) => {
			// ONE field only: the push is `^SRVST: <service_status>`, while the
			// answer to AT^SRVST? is `^SRVST: <enable>,<service_status>`. A
			// loose match would read that answer's ENABLE flag as the service
			// state. (The engine files a command's own answer as a response
			// rather than a URC, so this is belt and braces — but the two forms
			// share a name, which is exactly how ^CELLLOCK-class bugs start.)
			let m = match(line, /\^SRVST:\s*(-?[0-9]+)\s*$/);

			if (m)
				return { kind: 'service', service: +m[1] };

			m = match(line, /\^MODE:\s*(-?[0-9]+),\s*(-?[0-9]+)/);

			if (m)
				return { kind: 'mode', sys_mode: +m[1], cell_service: +m[2] };

			return null;
		},

		// the registered operator. AT+COPS? also works but is SLOW on this
		// firmware (>8 s, seen timing out at that limit) and carries no name;
		// ^EONS answers instantly with both names and the SPN. It is a SET
		// command — a bare AT^EONS is a syntax error (CME 4) — and without a
		// <plmn_id> it reports the network currently registered:
		//   ^EONS: 1,26202,"Vodafone.de","Vodafone",0,"DATA ONLY"
		operator_query: 'AT^EONS=1',
		parse_operator: (lines) => {
			for (let l in (lines ?? [])) {
				let m = match(l, /\^EONS:\s*[0-9]+,\s*([0-9]{5,6})\s*,\s*"([^"]*)"(\s*,\s*"([^"]*)")?/);

				if (!m)
					continue;

				let id = m[1];

				// 5 digits = 2-digit MNC, 6 = 3-digit (the split is positional,
				// there is no separator in the PLMN id)
				return {
					mcc: +substr(id, 0, 3),
					mnc: +substr(id, 3),
					description: (length(m[2]) ? m[2] : null) ?? m[4],
				};
			}

			return null;
		},

		// the startup value of the service state: the URC only fires on a CHANGE,
		// so without this read the state stays unknown until the network moves.
		// Second field — see the warning in service_urc.
		service_query: 'AT^SRVST?',
		parse_service: (lines) => {
			for (let l in (lines ?? [])) {
				let m = match(l, /\^SRVST:\s*-?[0-9]+,\s*(-?[0-9]+)/);

				if (m)
					return +m[1];
			}

			return null;
		},

		// ^DCONN/^DEND: <pdpid>,<status>,<pdp_type> — the modem announcing its
		// own bearer coming up / going down (manual 10.10, table 195;
		// <status> 0 = disconnect, 1 = established). Field-seen on a Cudy
		// LT300: ^DEND 21:05:54, ^DCONN 21:05:59 — the modem re-established
		// the session by itself five seconds later, which is why the context
		// treats this as a hint to VERIFY rather than a verdict to act on.
		session_urc: (line) => {
			let m = match(line, /\^(DCONN|DEND):\s*([0-9]+),([0-9]+)/);

			return m ? { cid: +m[2], up: (+m[3] == 1) } : null;
		},
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
		// ^NDISSTAT is the dial-status notification pushed after ^NDISDUP. It is
		// a DIFFERENT name from ^NDISSTATQRY, the answer to the status query at
		// DIAL_NDISDUP.status — exact-name matching keeps the two apart.
		//
		// What the E3372H actually pushes (21.200, field-observed over the wdm
		// AT channel, 2026-08-30): ^RSSI + ^HCSQ (signal, in the query formats
		// the telemetry poll already parses — the poll stays the authority, no
		// event is derived from these), ^NDISSTAT (the bearer push, parsed as
		// session_urc below) and ^DSFLOWRPT every ~2 s (the traffic report —
		// 7 hex fields, tx/rx totals in fields 5/6; listed here so an
		// interleaved answer never carries it, NOT parsed: the stats poll is
		// the counter source, and this firmware's ^DSFLOWQRY read is untested).
		// ^MODE/^SRVST/^SIMST do NOT exist on this firmware — their QUERIES
		// all answer bare ERROR — so no parser is built on them; the prefix
		// list only keeps such pushes out of command responses should another
		// huawei firmware emit them.
		urcs: [ '^NDISSTAT', '^RSSI', '^HCSQ', '^DSFLOWRPT', '^MODE', '^SIMST', '^SRVST' ],

		// ^RSSI / ^HCSQ are pushed on every signal change (21.200 pushes them
		// on a ~5 s cadence, field-observed). NOT parsed here — the telemetry
		// poll's parsers stay the authority — but the push triggers a signal
		// refresh, so a change shows within a poll instead of after a full
		// stats interval. The same hint contract as ^MODE above.
		service_urc: (line) => {
			if (match(line, /\^HCSQ:\s*"[^"]+",/) || match(line, /\^RSSI:\s*[0-9]+/))
				return { kind: 'signal' };

			return null;
		},
		// disable the modem's internal auto-dialer so it does not connect behind
		// wwand's back (best-effort; modems without it just warn). QModem disables
		// it in the hangup path — we do it once at init so it never races the
		// daemon-owned context (parity with the RG502Q autoconnect reclaim).
		modem_init: [ 'AT^SETAUTODIAL=0' ],
		auth_cmd: null,
		dials: [ DIAL_NDISDUP, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
		// ^NDISSTAT is the bearer push (the ^NDISSTATQRY ANSWER is a different
		// name — exact-match filtered apart). Field-seen on the E3372H
		// (2026-08-30): one line per family, dual-stack pushes two:
		//   ^NDISSTAT:1,,,"IPV4"      up: <conn> 1, the reason fields empty
		//   ^NDISSTAT:0,36,,"IPV4"    down: <conn> 0, <reason> = the 3GPP
		//     deactivation cause (36 = regular deactivation, TS 24.008 — a
		//     normal NDISDUP=1,0 teardown reports exactly this)
		// A hint to verify, like every session_urc: the context confirms via
		// the ^NDISSTATQRY status query (DIAL_NDISDUP.status) before tearing
		// anything down. No cid in the event — the push names no PDP id, and
		// this modem class runs a single NDIS session, so every context owns
		// it (the consumer's cid filter passes a null cid through).
		session_urc: (line) => {
			let m = match(line, /^\^NDISSTAT:\s*/);

			if (!m)
				return null;

			// <conn>,<r1>,<r2>,"IPV4"[,...] — newer firmware folds both
			// families into ONE line; the walk covers both shapes (a family
			// token follows its block three fields after the conn state)
			let f = split(replace(substr(line, length(m[0])), /"/g, ''), /\s*,\s*/);
			let up = false;

			for (let i = 0; i + 3 < length(f); i++) {
				let fam = f[i + 3];

				if (fam == 'IPV4' || fam == 'IPV6')
					up = up || (+f[i] == 1);
			}

			return { up: up };
		},
		// ip_config: the E3372H on stick firmware 21.200 (HW-observed on the
		// WH3000 Pro, 2026-08-30) does NOT implement CGCONTRDP or GTDNS (both
		// answer bare ERROR); its PDP address comes from CGPADDR, which is
		// also empty until the dial has actually bound the bearer. No gateway
		// and no DNS over AT then — the /32 p2p model needs no gateway (the
		// shim pushes a plain device route), and DNS is whatever the operator
		// configured on the interface. Firmware that FILLS CGCONTRDP takes the
		// generic path and never reaches CGPADDR.
		ip_config: (modem, cid, cfg, cb) => {
			modem.at.send(sprintf('AT+CGCONTRDP=%d', cid), (err, res) => {
				if (!err) {
					let rdp = parse_cgcontrdp(res?.lines);

					if (rdp.ipv4?.addr || rdp.ipv6?.addr)
						return cb(null, rdp);
				}

				modem.at.send(sprintf('AT+CGPADDR=%d', cid), (e2, r2) => {
					if (e2)
						return cb(e2);

					let a = parse_cgpaddr(r2?.lines);

					// the CGPADDR v6 slot is an interface identifier, never a host
					// assignment (see the fibocom note); v6 arrives via the
					// dhcpv6 subinterface (RA) like on every NCM modem
					let v4 = (a?.addr && cfg.pdp_type != 'ipv6')
						? { addr: a.addr, prefix: null, gateway: null, dns: [], mtu: null }
						: null;

					if (!v4 && cfg.pdp_type != 'ipv6')
						return cb(err ?? 'no address assigned');

					cb(null, { ipv4: v4, ipv6: null });
				}, { timeout: 8000 });
			}, { timeout: 15000 });
		},
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
		define: (cid, pdp, apn, alloc) => (alloc != null)
			? sprintf('AT+CGDCONT=%d,"%s","%s",0,0,0,%d', cid, pdp, apn, alloc)
			: sprintf('AT+CGDCONT=%d,"%s","%s",0,0', cid, pdp, apn),
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
		// +GTACT is the only band control on this family, and the codec
		// owns the parser's positional rules — see the +GTACT section above.
		settings_capable: gtact_capable,
		settings_get: gtact_get,
		settings_set: gtact_set,
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
			// GTDUALSIM IS REFUSED UNTIL THIS IS SET. The FM350-GL answers
			// ERROR to AT+GTDUALSIM=1 while GTESIMCFG is 0,1,0, and accepts it
			// at 0,0,0 — so every slot switch failed on that module and the
			// explanation lived in a 4pda thread rather than anywhere a wwand
			// user would look (ddimension/wwand#27, #28; traced and confirmed
			// in both directions by the reporter on firmware
			// 81600.0000.00.29.23.24, 2026-09-13). Sent before the switch, and
			// its own error ignored: older Fibocom firmware has no GTESIMCFG.
			switch_prepare: 'AT+GTESIMCFG=0,0,0',
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
// The identity of a device by its USB id, for a modem that refuses CGMI/CGMM
// and has no earlier bring-up to carry the answer over from. Only ids this tree
// has field evidence for: the FM350-GL's two compositions, whose AT interface
// atcmd.uc LOCAL_PORTS already maps (mode 40 = 7126, mode 41 = 7127), with
// the strings the module itself answers (`cgmi Fibocom Wireless Inc., cgmm
// FM350-GL`, reporter log ddimension/wwand#45, 2026-09-29).
export const USB_IDENTITY = {
	'0e8d:7126': { manufacturer: 'Fibocom Wireless Inc.', model: 'FM350-GL' },
	'0e8d:7127': { manufacturer: 'Fibocom Wireless Inc.', model: 'FM350-GL' },
};

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
	let alloc = ADDR_ALLOC[cfg.address_allocation];
	let cmds = [ cgdcont(cid, pdp, target_apn, alloc) ];

	// `alloc` goes to the vendor define as well: one that rewrites the same
	// CGDCONT (MediaTek) would otherwise reset the preference just written
	if (vendor.define)
		push(cmds, vendor.define(cid, pdp, target_apn, alloc));

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

// AT+CGDCONT? read-back: '+CGDCONT: <cid>,"<type>","<apn>",<addr>,<d_comp>,
// <h_comp>,<IPv4AddrAlloc>,...' per line. `alloc` is null where the line
// stops before the 7th field (older firmware) — unknown, not 0.
export function parse_cgdcont(lines)
{
	let out = [];

	for (let l in (lines ?? [])) {
		let m = match(l, /\+CGDCONT:\s*([0-9]+)\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"/);

		if (!m)
			continue;

		// the address may be quoted (and contain dots) or empty; the next
		// three fields are plain numbers
		let t = match(l, /\+CGDCONT:[^,]*,[^,]*,"[^"]*"\s*,\s*("[^"]*"|[^,]*)\s*,\s*[0-9]*\s*,\s*[0-9]*\s*,\s*([0-9]+)/);

		push(out, { cid: +m[1], pdp_type: m[2], apn: m[3], alloc: t ? +t[2] : null });
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

		// an allocation preference that was asked for must be held too; an
		// unreadable one counts as "differs", like an absent QMI TLV
		let want_alloc = ADDR_ALLOC[cfg.address_allocation];

		return uc(e.pdp_type) == want_pdp && lc(e.apn) == want_apn &&
			(want_alloc == null || e.alloc === want_alloc);
	}

	return false;
};

// --- IPv6 prefix delegation on an AT modem ------------------------------------
//
// Only a vendor with a `pd` recipe has it (Quectel: AT+QIP6CFG); there is no
// 3GPP AT command for it. `send(cmd, cb(err, lines))` is the caller's AT send.

// sync_pd: read the flag of <cid>, write it only when it differs from `want`
// (0/1; null = leave it). cb(changed).
export function sync_pd(vendor, send, cid, want, log, cb)
{
	let pd = vendor?.pd;

	if (!pd || want == null)
		return cb(false);

	send(pd.read(cid), (err, lines) => {
		// an unread flag is not "differs": read-before-write means no write
		// on a failed read (QMI writes on an ABSENT TLV, where the read itself
		// succeeded — a different case)
		if (err)
			return cb(false);

		let cur = pd.parse(lines, cid);

		if (cur === want)
			return cb(false);

		log('notice', sprintf('profile %d: IPv6 prefix delegation %J -> %d', cid, cur, want));

		send(pd.write(cid, want), (e2) => {
			if (e2)
				log('warn', sprintf('profile %d: IPv6 prefix delegation not accepted: %J', cid, e2));

			cb(!e2);
		});
	});
};

// read_pd_prefix: the prefix delegated to <cid>, "addr/len", or null for none,
// no recipe or an error. cb(prefix).
export function read_pd_prefix(vendor, send, cid, cb)
{
	let pd = vendor?.pd;

	if (!pd?.addr)
		return cb(null);

	send(pd.addr(cid), (err, lines) => cb(err ? null : pd.parse_addr(lines)));
};

// per-vendor telemetry blocks (telemetry_ncm.uc) wired onto the VENDORS recipes;
// vendors without an entry inherit the generic block (vendor_telemetry() in
// modem_ncm.uc falls back to telemetry_ncm.GENERIC).
VENDORS.quectel.telemetry = telemetry_ncm.QUECTEL;
VENDORS.meig.telemetry    = telemetry_ncm.MEIG;
VENDORS.huawei.telemetry  = telemetry_ncm.HUAWEI;
VENDORS.fibocom.telemetry = telemetry_ncm.FIBOCOM;
VENDORS.generic.telemetry = telemetry_ncm.GENERIC;
