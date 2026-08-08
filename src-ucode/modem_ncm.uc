// wwand — per-modem state machine for NCM control (cdc_ncm / cdc_ether driver,
// AT-controlled).
//
// NCM modems have NO rich control protocol (no QMI/MBIM): the whole modem is
// driven over an AT channel (atcmd.uc, the same engine the QMI/MBIM backends use
// as a side channel); the datapath is a plain cdc_ncm/cdc_ether netdev. There is
// no message transport to open. Bring-up:
//   open AT -> identify (CGMI/CGMM/CGMR/CGSN/CIMI/CCID) -> SIM/PIN (CPIN?) ->
//   program attach PDP context + auth (CGDCONT + vendor auth) -> wait for
//   registration (CEREG?/CREG?) -> READY. Polled while READY.
//
// Exposes the SAME contract as modem.uc / modem_mbim.uc so daemon.uc, the netifd
// shim and ubus stay protocol-neutral. Contexts use context_ncm.uc.

'use strict';

import * as uloop from 'uloop';
import * as atcmd from './atcmd.uc';
import * as modem_common from './modem_common.uc';
import * as telemetry_ncm from './telemetry_ncm.uc';
import * as recovery_mod from './recovery.uc';
import * as protoswitch from './protocol_switch.uc';
import * as netlink from './netlink.uc';
import * as nasmod from './codec/schema/nas.uc';
import * as sim from './sim.uc';

const TIMING_DEFAULTS = {
	...modem_common.TIMING_BASE,   // settle/reg_timeout/backoff_min/backoff_max
	reg_poll: 2000,
	at_drain: 60000,
};

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
const DIAL_CGACT = {
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
const VENDORS = {
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

// --- CGCONTRDP parsing (shared with context_ncm.uc) --------------------------
//
// AT+CGCONTRDP=<cid> reports the dynamic parameters of an active context. The
// 3GPP layout is:
//   +CGCONTRDP: <cid>,<bearer>,<apn>,<local_addr_and_subnet_mask>,<gw>,
//               <dns1>,<dns2>[,<p-cscf1>,<p-cscf2>,<im_cn>,<lipa>,<ipv4_mtu>...]
// but firmwares diverge wildly for a dual-stack (ipv4v6) context. HW-seen on
// RG650E-EU: BOTH families crammed into ONE line with irregular comma/space
// separators and mixed field widths, e.g.:
//   +CGCONTRDP: 1,5,"apn","100.71.169.229","42.0.0.32.66.143.62.233...",
//     "254.128.0.0...1","139.7.30.125" "42.1.8.96...83","139.7.30.126" "42.1.8.96...1.83"
// where the local addr is a bare 4-octet IPv4 (no mask), the next 16-octet field
// is the IPv6 address, and v4 DNS + v6 DNS are interleaved.
//
// So rather than trust positions, tokenize every dotted-decimal group (comma OR
// space separated), classify by octet count (4/8 = IPv4[+mask], 16/32 =
// IPv6[+mask]), bucket per family IN ORDER, then map each as [addr(+mask),
// gateway?, dns...]. The gateway slot is taken only for a masked IPv4 (8/32
// octets) or for IPv6 (always advertises a link-local gw) — an unmasked IPv4
// (RG650E) has no gateway field, so every remaining v4 token is DNS.

const NETMASK_BITS = {
	'255': 8, '254': 7, '252': 6, '248': 5,
	'240': 4, '224': 3, '192': 2, '128': 1, '0': 0,
};

function mask_to_prefix(octets)
{
	let bits = 0;

	for (let o in octets) {
		let b = NETMASK_BITS[o];

		if (b == null)
			return null;

		bits += b;
	}

	return bits;
}

// join 16 decimal byte strings into an IPv6 literal (uncompressed but valid)
function bytes_to_ipv6(bytes)
{
	let hextets = [];

	for (let i = 0; i < 16; i += 2)
		push(hextets, sprintf('%x', (+bytes[i] & 0xff) * 256 + (+bytes[i + 1] & 0xff)));

	return join(':', hextets);
}

// assign an ordered list of dotted-octet tokens (each an array of octet strings)
// for one family to { addr, prefix/plen, gateway, dns[] }
function assign_family(tokens, is_v6)
{
	if (!length(tokens))
		return null;

	let t0 = tokens[0];
	let out = { addr: null, gateway: null, dns: [] };
	let has_mask;

	if (is_v6) {
		has_mask = (length(t0) == 32);
		out.addr = bytes_to_ipv6(slice(t0, 0, 16));
		out.plen = has_mask ? mask_to_prefix(slice(t0, 16, 32)) : 64;
	}
	else {
		has_mask = (length(t0) == 8);
		out.addr = join('.', slice(t0, 0, 4));
		out.prefix = has_mask ? mask_to_prefix(slice(t0, 4, 8)) : null;
	}

	let idx = 1;
	let render = (t) => is_v6 ? bytes_to_ipv6(slice(t, 0, 16)) : join('.', slice(t, 0, 4));

	// gateway slot: present for IPv6 (link-local gw) or a masked IPv4 address
	if ((is_v6 || has_mask) && idx < length(tokens))
		out.gateway = render(tokens[idx++]);

	for (; idx < length(tokens); idx++)
		push(out.dns, render(tokens[idx]));

	return out;
}

export function parse_cgcontrdp(lines)
{
	let v4 = [], v6 = [];

	for (let l in (lines ?? [])) {
		let m = match(l, /\+CGCONTRDP:\s*(.*)/);

		if (!m)
			continue;

		// tokenize on comma AND whitespace (RG650E mixes them), strip quotes,
		// keep only dotted-decimal groups (skips cid/bearer ints and the apn)
		let clean = replace(m[1], /"/g, '');

		for (let tok in split(clean, /[, \t]+/)) {
			if (!match(tok, /^[0-9]+(\.[0-9]+)+$/))
				continue;

			let parts = split(tok, '.');
			let n = length(parts);

			if (n == 4 || n == 8)
				push(v4, parts);
			else if (n == 16 || n == 32)
				push(v6, parts);
		}
	}

	return { ipv4: assign_family(v4, false), ipv6: assign_family(v6, true) };
};

// --- AT status parsers -------------------------------------------------------

// +CPIN: READY | SIM PIN | SIM PUK | ...
function parse_cpin(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /\+CPIN:\s*(.+)/);

		if (m)
			return trim(m[1]);
	}

	return null;
}

// +CEREG/+C5GREG/+CREG: <n>,<stat>[,...] — registered when stat is 1 (home) or
// 5 (roaming). Handles both the query echo (<n>,<stat>) and the URC (<stat>).
export function parse_creg(lines)
{
	for (let l in (lines ?? [])) {
		// query form "<n>,<stat>" first, then the URC form "<stat>". Group 1 is
		// the optional CE/C5G marker (ucode uses POSIX ERE — no non-capturing
		// groups), so the stat is always group 2.
		let m = match(l, /\+C(E|5G)?REG:\s*[0-9]+,([0-9]+)/) ?? match(l, /\+C(E|5G)?REG:\s*([0-9]+)/);

		if (!m)
			continue;

		let stat = +m[2];

		return { stat: stat, registered: (stat == 1 || stat == 5), roaming: (stat == 5) };
	}

	return null;
};



// per-vendor telemetry blocks (telemetry_ncm.uc) wired onto the VENDORS recipes;
// vendors without an entry inherit TELEMETRY_GENERIC via vendor_telemetry().
VENDORS.quectel.telemetry = telemetry_ncm.QUECTEL;
VENDORS.meig.telemetry    = telemetry_ncm.MEIG;
VENDORS.huawei.telemetry  = telemetry_ncm.HUAWEI;
VENDORS.generic.telemetry = telemetry_ncm.GENERIC;

function vendor_telemetry(self)
{
	return self.vendor?.telemetry ?? telemetry_ncm.GENERIC;
}

// --- vendor-serial driver bind (usb-serial new_id) ---------------------------
//
// Some modem compositions carry their AT/DIAG serial interfaces under a USB PID
// the in-kernel `option` driver does not know (its id table only covers the mode
// the vendor ships), so no ttyUSB nodes exist and open_at finds no AT port. For
// known devices, register the id at runtime: writing "vid pid" to the driver's
// new_id probes the already-present device synchronously, so the ttys appear.
//
//   'vid:pid' (lowercase hex) -> usb-serial driver name under
//   /sys/bus/usb-serial/drivers/<name>/new_id
const SERIAL_NEW_ID = {
	// MeiG SLM770A ECM composition — the kernel knows only RNDIS (2dee:4d57).
	// HW-verified on a Cudy LT300 v3.
	'2dee:4d58': 'option1',
};

// bind the vendor serial driver for a known composition (netdev anchors the USB
// parent). Returns true when a new_id write was performed. No-op when the device
// is unknown, ttys already exist, or the driver module is not loaded.
export function ensure_serial_bind(fx, netdev)
{
	if (!netdev)
		return false;

	let base = sprintf('/sys/class/net/%s/device/..', netdev);
	let vid = lc(trim(fx.read(sprintf('%s/idVendor', base)) ?? ''));
	let pid = lc(trim(fx.read(sprintf('%s/idProduct', base)) ?? ''));
	let drv = SERIAL_NEW_ID[sprintf('%s:%s', vid, pid)];

	if (!drv)
		return false;

	// serial interfaces already bound? (same sibling glob open_at uses)
	if (length(fx.glob(sprintf('%s/*/tty*', base)) ?? []) > 0)
		return false;

	let node = sprintf('/sys/bus/usb-serial/drivers/%s/new_id', drv);

	if (!fx.exists(node))
		return false;

	return fx.write(node, sprintf('%s %s\n', vid, pid)) == true;
};

export function create(opts)
{
	let self = {
		id: opts.id,
		device: opts.device,
		protocol: 'ncm',
		config: opts.config ?? {},
		timing: { ...TIMING_DEFAULTS, ...(opts.timing ?? {}) },

		state: 'ABSENT',
		vendor: VENDORS.generic,
		info: {},
		reg: {},
		reg_detail: null,
		signal: {},
		cells: null,
		dsd_status: null,
		locks: null,
		location: null,
		at: null,
		at_tty: null,
		datapath: null,
		counters: null,
		contexts: [],
	};

	let deps = opts.deps ?? {};
	let log = deps.log ?? ((level, msg) => warn(sprintf('%s: modem %s: %s\n', level, self.id, msg)));
	self.log_fn = log;

	let rec = recovery_mod.create({
		id: opts.id,
		failreboot: (opts.config ?? {}).failreboot,
		proto_error_limit: (opts.config ?? {}).proto_error_limit,
		fx: opts.recovery?.fx ?? netlink.default_fx((l, m) => log(l, m)),
		state_dir: opts.recovery?.state_dir,
		reboot_delay: opts.recovery?.reboot_delay,
		// board-provided modem repower (power-cycle or reset-gpio pulse); replaces usb-repower
		repower: opts.recovery?.repower,
		log: (l, m) => log(l, m),
	});

	rec.load();
	self.counters = rec.counters;
	self.recovery = rec;

	let at_opts = opts.at ?? {};
	let retry_timer = null, reg_timer = null, reg_poll_timer = null, settle_timer = null;
	let at_drain_timer = null, telemetry_timer = null;
	let telem_watch;   // modem_common.watch_driver (adaptive fast telemetry loop)

	// protocol-neutral scaffolding (set_state / attach_context /
	// note_connect_success / trip_zero_rx on self; emit + notify_contexts here)
	let scaffold = modem_common.scaffolding(self, { deps: deps, log: log, rec: rec });
	let emit = scaffold.emit;
	let notify_contexts = scaffold.notify_contexts;

	// backend-neutral NAS accessor (daemon settings / network-selection paths):
	// NCM has no QMI at all → null, so the daemon falls back to AT (AT+COPS).
	self.with_nas = function(cb) {
		cb(null);
	};

	// attach PDP context config: the first attached context (interface-bound
	// preferred) drives the modem's autonomous LTE attach, so its APN/auth is
	// what CGDCONT/QICSGP programs at bring-up. Contexts re-apply idempotently at
	// dial time (context_ncm.up).
	let attach_cfg = () => {
		let bound = null;

		for (let ctx in self.contexts) {
			if (ctx.config?.interface)
				return ctx.config;

			bound = bound ?? ctx.config;
		}

		return bound ?? self.config;
	};

	// --- recovery / failure ------------------------------------------------

	let fail = modem_common.make_fail(self, {
		log: log, timing: self.timing, emit: emit,
		set_retry_timer: (t) => retry_timer = t,
	});

	modem_common.note_connect_failure_light(self, rec);


	// --- step chain --------------------------------------------------------

	let step_identify, step_resolve_dial, step_datapath, step_sim, step_attach, step_register, on_registered;

	// AT side channel: for NCM this IS the control channel (a missing port fails
	// the whole modem — there is no other transport). open_at discovers the tty,
	// opens it and runs model-init + configured at_init + cell locks.
	self.start = function() {
		if (self.at || self.state != 'ABSENT')
			return;

		self.set_state('INIT_TRANSPORT');

		// runtime driver bind for known compositions (SERIAL_NEW_ID) before AT
		// port discovery
		let bind_fx = at_opts.fx ?? netlink.default_fx((l, m) => log(l, m));

		if (ensure_serial_bind(bind_fx, self.device))
			log('notice', sprintf('registered vendor serial driver id for %s (usb-serial new_id)', self.device));

		modem_common.open_at(self, {
			at_opts: at_opts,
			log: log,
			drain_interval: self.timing.at_drain,
			set_drain_timer: (t) => { at_drain_timer = t; },
			next: () => {
				if (!self.at)
					return fail('open_at', { error: 'no_at_port', device: self.device });

				step_identify();
			},
		});
	};

	// identify the modem: manufacturer selects the vendor recipe; the rest is
	// best-effort (a modem that answers CGMI but not CGSN still proceeds).
	step_identify = () => {
		self.set_state('INIT_SERVICES');

		let ask = (cmd, done) => self.at.send(cmd, (err, res) => {
			let val = null;

			for (let line in (res?.lines ?? [])) {
				// skip AT+... response prefixes ("+CGMI: ...") -> take the value
				let m = match(line, /^\+[A-Z]+:\s*(.*)/);

				val = m ? trim(m[1]) : trim(line);

				if (val != '')
					break;
			}

			done(err ? null : val);
		});

		ask('AT+CGMI', (manuf) => {
			self.info.manufacturer = manuf;
			self.vendor = vendor_for(manuf);

			ask('AT+CGMM', (model) => {
				self.info.model = model;

				ask('AT+CGMR', (rev) => {
					self.info.revision = rev;

					ask('AT+CGSN', (imei) => {
						self.info.imei = imei;
						self.info.device_id = imei;

						ask('AT+CIMI', (imsi) => {
							self.info.imsi = imsi;

							// ICCID command varies by vendor: Quectel AT+QCCID,
							// 3GPP-ish AT+CCID, MeiG (ASR) only AT+ICCID
							// (HW-verified on the SLM770A-R — QCCID/CCID both
							// ERROR there and the identity ended up iccid '?')
							let iccid_cmds = [ 'AT+QCCID', 'AT+CCID', 'AT+ICCID' ];
							let try_iccid;

							try_iccid = (idx, done2) => {
								if (idx >= length(iccid_cmds))
									return done2(null);

								ask(iccid_cmds[idx], (iccid) =>
									iccid ? done2(iccid) : try_iccid(idx + 1, done2));
							};

							try_iccid(0, (iccid) => {
								// strip the '+[Q]ICCID: ' echo some firmwares keep
								let m = iccid ? match(iccid, /([0-9]{18,20})/) : null;
								self.info.iccid = m ? m[1] : iccid;

								log('notice', sprintf('ncm modem %s (%s), imei %s, imsi %s, iccid %s',
									self.info.model ?? '?', self.info.manufacturer ?? '?',
									self.info.imei ?? '?', self.info.imsi ?? '?',
									self.info.iccid ?? '?'));

								// per-SIM override (config wwand_sim) — parity
								// with the QMI backend; consumed via conn_cfg
								self.active_sim = modem_common.match_sim_override(
									self.config?.sims, self.info.iccid, self.info.imsi);
								if (self.active_sim)
									log('notice', sprintf('SIM %s matched a configured wwand_sim (per-SIM pin/apn)',
										self.info.iccid ?? self.info.imsi));

								// stable-identity gate (see modem_common.check_identity)
								if (!modem_common.check_identity(self, { emit: emit, log: log }))
									return;

								step_resolve_dial();
							});
						});
					});
				});
			});
		});
	};

	// resolve the dial method ONCE per modem: try the vendor's ordered dials,
	// adopting the first whose support-probe (if any) answers OK (a probe-less
	// dial is adopted directly). The list always ends in CGACT, so self.dial is
	// always set. HW: RG650E answers ERROR to the QNETDEVCTL probe -> CGACT.
	step_resolve_dial = () => {
		let dials = self.vendor.dials ?? [ DIAL_CGACT ];
		let i = 0, tryNext;

		tryNext = () => {
			if (i >= length(dials)) {
				self.dial = DIAL_CGACT;
				log('notice', 'dial method: cgact (fallback)');
				return step_datapath();
			}

			let dm = dials[i++];

			if (!dm.probe) {
				self.dial = dm;
				log('notice', sprintf('dial method: %s', dm.name));
				return step_datapath();
			}

			self.at.send(dm.probe, (err) => {
				if (!err) {
					self.dial = dm;
					log('notice', sprintf('dial method: %s', dm.name));
					return step_datapath();
				}

				log('info', sprintf('dial method %s unsupported (%s), trying next', dm.name, dm.probe));
				tryNext();
			});
		};

		tryNext();
	};

	// datapath: a plain cdc_ncm/cdc_ether netdev carries no mux and needs no
	// driver format change (unlike qmi_wwan raw-ip). Just bring the parent link
	// up; the IP comes from the connection (context_ncm). Skipped in host tests.
	step_datapath = () => {
		let dp = opts.datapath;

		self.datapath = { backend: 'cdc_ncm', netdev: dp?.netdev ?? null };

		if (dp?.netdev && dp.fx) {
			dp.fx.link_set(dp.netdev, { up: true });
			log('notice', sprintf('datapath: cdc_ncm netdev %s up', dp.netdev));
		}

		step_sim();
	};

	step_sim = () => {
		self.set_state('SIM_UNLOCK');

		self.at.send('AT+CPIN?', (err, res) => {
			let st = parse_cpin(res?.lines);

			// +CME ERROR: 10 (SIM not inserted) / other hard SIM faults
			if (err && err.error == 'cme' && err.code == '10') {
				self.set_state('SIM_BLOCKED', { reason: 'sim_absent' });
				emit('sim_blocked', { reason: 'sim_absent' });
				notify_contexts('sim_blocked', {});
				return;
			}

			if (st == 'READY')
				return step_attach();

			if (st == 'SIM PIN') {
				let pincode = sim.effective_pincode(self);
				let block = (reason, retries) => {
					self.set_state('SIM_BLOCKED', { reason: reason, retries: retries });
					emit('sim_blocked', { reason: reason, retries: retries });
					notify_contexts('sim_blocked', {});
				};

				if (!pincode)
					return block('pin_required_no_pin');

				// PIN-safety: query the remaining attempts (Quectel AT+QPINC="SC":
				// +QPINC: "SC",<pin_remaining>,<puk_remaining>) and refuse to
				// auto-burn the last try. Best-effort — if the modem lacks QPINC,
				// retries stays null and pin_block_reason lets it proceed.
				return self.at.send('AT+QPINC="SC"', (qerr, qres) => {
					let retries = null;

					for (let l in (qres?.lines ?? [])) {
						let m = match(l, /\+QPINC:\s*(?:"[^"]*",\s*)?([0-9]+)/);
						if (m) { retries = +m[1]; break; }
					}

					let br = sim.pin_block_reason(retries, self.pin_force);

					if (br)
						return block(br, retries);

					self.at.send(sprintf('AT+CPIN="%s"', pincode), (verr) => {
						if (verr)
							return block('verify_failed');

						log('notice', 'sim: pin accepted');
						settle_timer = uloop.timer(self.timing.settle, step_attach);
					});
				});
			}

			if (st == 'SIM PUK' || st == 'SIM PUK2') {
				self.set_state('SIM_BLOCKED', { reason: 'puk_required' });
				emit('sim_blocked', { reason: 'puk_required' });
				notify_contexts('sim_blocked', {});
				return;
			}

			// unknown state or query error: proceed and let registration decide
			step_attach();
		});
	};

	// program the attach PDP context (CGDCONT + vendor auth) so the modem's
	// autonomous attach uses the right APN and IP family. Best-effort: a modem
	// that rejects a command still proceeds to registration.
	step_attach = () => {
		self.set_state('CONFIGURING');

		let cfg = attach_cfg();
		// one-time vendor init (e.g. CFUN=1) + the attach context definition/auth
		let cmds = [ ...(self.vendor.modem_init ?? []), ...build_pdp_setup(self.vendor, 1, cfg) ];

		if (!length(cmds))
			return step_register();

		log('notice', sprintf('attach context 1: apn %J (%s), pdp %s',
			cfg.apn ?? '', (cfg.apn == null || cfg.apn == '') ? 'network default' : 'configured',
			cfg.pdp_type ?? 'ipv4v6'));

		self.at.run_sequence(cmds, step_register);
	};

	// registration: poll CEREG (LTE/5G) then CREG (fallback) until the modem is
	// registered home/roaming or the timeout elapses.
	step_register = () => {
		self.set_state('REGISTERING');

		if (reg_timer) reg_timer.cancel();
		reg_timer = uloop.timer(self.timing.reg_timeout, () => {
			if (self.state == 'REGISTERING')
				fail('registration_timeout', { reg: self.reg });
		});

		let poll;

		poll = () => {
			if (self.state != 'REGISTERING' || !self.at)
				return;

			self.at.send('AT+CEREG?', (err, res) => {
				// stale callback after a teardown/reload nulled self.at: must not
				// drive a dead modem to READY or send on a null engine
				if (self.state != 'REGISTERING' || !self.at)
					return;

				let r = err ? null : parse_creg(res?.lines);

				let after = (rr) => {
					if (rr?.registered)
						return on_registered(rr);

					if (self.state == 'REGISTERING')
						reg_poll_timer = uloop.timer(self.timing.reg_poll, poll);
				};

				if (r?.registered)
					return after(r);

				// 5G-SA: EPS registration (CEREG) can read not-registered while the
				// device is attached via 5GS only — try C5GREG, then legacy CREG.
				self.at.send('AT+C5GREG?', (e5, r5) => {
					if (self.state != 'REGISTERING' || !self.at)
						return;

					let rr5 = (!e5 && parse_creg(r5?.lines)?.registered) ? parse_creg(r5.lines) : null;

					if (rr5?.registered)
						return after(rr5);

					self.at.send('AT+CREG?', (e2, r2) =>
						after((!e2 && parse_creg(r2?.lines)?.registered) ? parse_creg(r2.lines) : r));
				});
			});
		};

		poll();
	};

	// forward-declared above: referenced by step_register's poll closure
	on_registered = (r) => {
		if (reg_timer) { reg_timer.cancel(); reg_timer = null; }
		if (reg_poll_timer) { reg_poll_timer.cancel(); reg_poll_timer = null; }

		self.reg = { registration: 1, roaming: r.roaming };
		self.reg_detail = null;   // registered: clear any stale reject info
		self.counters.attempts = 0;

		log('notice', sprintf('registered (%s)', r.roaming ? 'roaming' : 'home'));
		self.set_state('READY');
		emit('registered', self.reg);
		notify_contexts('ready');

		// the 'registered' emit can run a SYNCHRONOUS config reload that tears
		// this very instance down (autosetup phase 2 writes uci and reloads;
		// close_at nulls the AT engines) — don't start telemetry on the corpse
		if (self.state != 'READY')
			return;

		let t = vendor_telemetry(self);

		// one-time warning for best-effort (unverified) telemetry recipes
		if (t.unverified && !self._tel_warned) {
			self._tel_warned = true;
			log('warn', sprintf('telemetry recipe for %s is best-effort/unverified (needs HW check)',
				self.info.manufacturer ?? '?'));
		}

		// cell-lock read-back once on entering READY (Quectel only today)
		if (t.locks)
			t.locks(self, () => null);

		self._start_telemetry();
	};

	// --- telemetry ---------------------------------------------------------
	//
	// self.signal / self.cells / self.dsd_status are populated in shapes the
	// LuCI status page understands (as the QMI/MBIM AT-fallback paths do): CSQ
	// gives an RSSI floor, AT+QENG="servingcell" the serving cell (rsrp/rsrq/
	// sinr + NR carrier), AT+QCAINFO the LTE aggregation set.

	// telemetry reads route through the vendor telemetry block, falling back to
	// the 3GPP-generic block. Each step is best-effort — an erroring command is
	// swallowed and the last-known value kept.
	let refresh_signal, refresh_cells, refresh_reg_detail;

	refresh_signal = (cb) => {
		cb = cb ?? (() => null);

		if (!self.at)
			return cb();

		vendor_telemetry(self).signal(self, cb);
	};

	refresh_cells = (cb) => {
		cb = cb ?? (() => null);

		if (!self.at)
			return cb();

		let t = vendor_telemetry(self);

		t.cells(self, () => {
			if (!self.at)
				return cb();

			t.ca(self, cb);
		});
	};

	refresh_reg_detail = (cb) => {
		cb = cb ?? (() => null);

		if (!self.at)
			return cb();

		vendor_telemetry(self).reg_detail(self, cb);
	};

	let emit_telemetry = () => emit('telemetry', { signal: self.signal, cells: self.cells, reg: self.reg });

	let log_telemetry = () => {
		log('notice', sprintf('telemetry: %s', modem_common.format_telemetry(self)));
	};

	// fast "watch" loop while a consumer polls modem_signal/modem_cells — the
	// adaptive cadence lives in modem_common.watch_driver (shared with QMI/MBIM);
	// this is just the NCM refresh body. done() is called once per cycle.
	let refresh_fast = (done) => {
		refresh_signal(() => {
			if (!self.at)
				return done();

			refresh_cells(() => {
				emit_telemetry();
				done();
			});
		});
	};

	telem_watch = modem_common.watch_driver({
		alive:   () => self.at != null,
		ready:   () => self.state == 'READY',
		refresh: refresh_fast,
	});

	self.watch = () => telem_watch.watch();

	// slow telemetry loop + registration-loss detection (no unsolicited AT
	// notifications are relied upon; a CEREG poll doubles as the liveness check)
	self._start_telemetry = function() {
		if (telemetry_timer)
			return;

		let interval = +(self.config.stats_interval ?? 60) * 1000;

		if (interval <= 0)
			return;

		let tick;

		tick = () => {
			if (!self.at || self.state != 'READY')
				return;

			// registration liveness: a lost registration suspends contexts and
			// re-enters the registration wait (parity with modem_mbim)
			self.at.send('AT+CEREG?', (err, res) => {
				let r = err ? null : parse_creg(res?.lines);

				if (r && !r.registered) {
					log('warn', 'registration lost');
					emit('deregistered', self.reg);
					self.reg = { registration: 0 };
					notify_contexts('suspend', self.reg);
					step_register();
					return;
				}

				refresh_signal(() => refresh_cells(() => refresh_reg_detail(() =>
					modem_common.collect_temperature(self, () => {
						if (!self.at)
							return;

						log_telemetry();
						emit_telemetry();
						telemetry_timer = uloop.timer(interval, tick);
					}))));
			});
		};

		telemetry_timer = uloop.timer(min(interval, 5000), tick);
	};

	// --- lifecycle ---------------------------------------------------------

	self.switch_protocol = function(target, cb) {
		protoswitch.switch_protocol(self, target, (err, res) => {
			if (!err && res.resetting) {
				emit('protocol_switch', { target: target });
				notify_contexts('lost');
				self.teardown();
				self.set_state('ABSENT');
			}

			cb(err, res);
		});
	};

	self.protocol_switch_supported = function() {
		return protoswitch.supported(self.info?.model);
	};

	// the card behind the modem changed in place (eSIM switch applied via the
	// CFUN=0/1 cycle): re-read IMSI/ICCID over AT and re-resolve the per-SIM
	// override — the old card's wwand_sim must not stick. The next (re)dial
	// picks the override up via conn_cfg; CGDCONT is (re)written at dial time
	// anyway, so there is no attach-profile step here. cb optional.
	self.reapply_sim = function(cb) {
		if (!self.at)
			return cb ? cb(null) : null;

		let q = (cmd, done) => self.at.send(cmd, (err, res) => {
			if (err)
				return done(null);

			for (let l in (res?.lines ?? [])) {
				l = trim(l);
				if (length(l) && l != 'OK')
					return done(l);
			}

			done(null);
		}, { timeout: 8000 });

		q('AT+CIMI', (imsi) => {
			let mi = imsi ? match(imsi, /([0-9]{6,15})/) : null;

			if (mi)
				self.info.imsi = mi[1];

			let finish = (iccid) => {
				if (iccid)
					self.info.iccid = iccid;

				self.active_sim = modem_common.match_sim_override(
					self.config?.sims, self.info.iccid, self.info.imsi);
				log('notice', sprintf('sim reapply: iccid %s imsi %s%s',
					self.info.iccid ?? '?', self.info.imsi ?? '?',
					self.active_sim ? ' (matched a configured wwand_sim)' : ''));
				emit('sim_refresh', { iccid: self.info.iccid, imsi: self.info.imsi });

				if (cb)
					cb(null);
			};

			// same vendor-varying ICCID chain as the init step
			let cmds = [ 'AT+QCCID', 'AT+CCID', 'AT+ICCID' ];
			let tryi;

			tryi = (i) => {
				if (i >= length(cmds))
					return finish(null);

				q(cmds[i], (r) => {
					let m = r ? match(r, /([0-9]{18,20})/) : null;
					m ? finish(m[1]) : tryi(i + 1);
				});
			};

			tryi(0);
		});
	};

	// admin-triggered soft modem reset (ubus modem_reset — the apply step for
	// `deferred` selection/band settings): AT+CFUN=1,1 full reboot. The modem
	// re-enumerates; hotplug/discovery rebuild it and the daemon kicks every auto
	// interface back up once it re-registers. HW-proven on this backend.
	self.reset = function(cb) {
		if (!self.at)
			return cb({ error: 'unsupported_on_backend' });

		log('warn', 'admin modem reset (AT+CFUN=1,1)');
		self.at.send('AT+CFUN=1,1', () => {
			notify_contexts('lost');
			cb(null, { resetting: true });
		}, { timeout: 8000 });
	};

	self.teardown = function() {
		for (let t in [ retry_timer, reg_timer, reg_poll_timer, settle_timer, at_drain_timer,
		                telemetry_timer ])
			if (t)
				t.cancel();

		retry_timer = reg_timer = reg_poll_timer = settle_timer = at_drain_timer = null;
		telemetry_timer = null;
		telem_watch.stop();

		modem_common.close_at(self);
	};

	// stop() installed by modem_common.scaffolding

	return self;
};
