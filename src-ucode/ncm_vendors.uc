// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — NCM/AT vendor model: the PDP/auth AT command builders, the
// per-vendor dial-method tables and bring-up recipes (VENDORS), and the
// CGDCONT parsers. Pure data + stateless helpers, extracted from
// modem_ncm.uc; shared by modem_ncm.uc and context_ncm.uc (via the
// re-exports modem_ncm keeps for its existing consumers).

'use strict';

import * as telemetry_ncm from './telemetry_ncm.uc';

// --- AT command model (shared with context_ncm.uc) ---------------------------
// pdp_type -> the 3GPP PDP type string used in AT+CGDCONT and the Quectel
// AT+QICSGP <context_type> enum (1=IPv4, 2=IPv6, 3=IPv4v6).

const PDP_STR = { ipv4: 'IP', ipv6: 'IPV6', ipv4v6: 'IPV4V6' };
const CTX_TYPE = { ipv4: 1, ipv6: 2, ipv4v6: 3 };

// QICSGP / CGAUTH auth enum: 0=none, 1=PAP, 2=CHAP, 3=PAP-or-CHAP
const AUTH_ENUM = { none: 0, pap: 1, chap: 2, both: 3 };

// explicit config wins; else PAP-or-CHAP when username/password present
// (QMI/MBIM parity), else none.
function auth_value(cfg)
{
	if (cfg.auth != null)
		return AUTH_ENUM[cfg.auth] ?? AUTH_ENUM.both;

	return (cfg.username && cfg.password) ? AUTH_ENUM.both : AUTH_ENUM.none;
}

// standard 3GPP context definition — the default `define` for most vendors
function cgdcont(cid, pdp, apn)
{
	return sprintf('AT+CGDCONT=%d,"%s","%s"', cid, pdp, apn);
}

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
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT+CGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
				cfg.username ?? '', cfg.password ?? '')
			: null,
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
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT+CGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
				cfg.username ?? '', cfg.password ?? '')
			: null,
		dials: [ DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Spreadtrum/UNISOC: opaque +SPTZCMD blobs (verbatim from ncm.json).
	spreadtrum: {
		match: /spreadtrum|unisoc|spreadtr/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT+CGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
				cfg.username ?? '', cfg.password ?? '')
			: null,
		dials: [ DIAL_SPTZCMD, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Fibocom (best-effort): GTRNDIS binds the RNDIS/NCM netdev. Auth is the
	// Fibocom-specific +MGAUTH (FM150/FM350 reject/ignore +CGAUTH).
	fibocom: {
		match: /fibocom/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT+MGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
				cfg.username ?? '', cfg.password ?? '')
			: null,
		dials: [ DIAL_GTRNDIS, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Telit (best-effort): #ECM binds the ECM netdev. Auth via CGAUTH.
	telit: {
		match: /telit/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT+CGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
				cfg.username ?? '', cfg.password ?? '')
			: null,
		dials: [ DIAL_TECM, DIAL_ICMAUTOCONN, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// SIMCom (best-effort): $QCRMCALL brings the Qualcomm rmnet/ncm call up.
	simcom: {
		match: /simcom/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT+CGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
				cfg.username ?? '', cfg.password ?? '')
			: null,
		dials: [ DIAL_QCRMCALL, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Gosuncn / ZTE ME-series: +ZECMCALL data call, CGAUTH auth.
	gosuncn: {
		match: /gosuncn/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT+CGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
				cfg.username ?? '', cfg.password ?? '')
			: null,
		dials: [ DIAL_ZECMCALL, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Neoway (Unisoc): $MYUSBNETACT data call, CGAUTH auth.
	neoway: {
		match: /neoway/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT+CGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
				cfg.username ?? '', cfg.password ?? '')
			: null,
		dials: [ DIAL_MYUSBNETACT, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// 3GPP-standard fallback: define+auth via CGDCONT/CGAUTH, CGACT dial.
	generic: {
		match: null,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT+CGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
				cfg.username ?? '', cfg.password ?? '')
			: null,
		dials: [ DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},
};

// pick the vendor recipe from the AT+CGMI manufacturer string; generic (match
// null) is skipped in the scan and returned last.
export function vendor_for(manufacturer)
{
	let s = lc(manufacturer ?? '');

	for (let name, v in VENDORS)
		if (v.match && match(s, v.match))
			return v;

	return VENDORS.generic;
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

	let ac = vendor.auth_cmd ? vendor.auth_cmd(cid, ctxtype, target_apn, cfg) : null;

	if (ac)
		push(cmds, ac);

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
VENDORS.generic.telemetry = telemetry_ncm.GENERIC;
