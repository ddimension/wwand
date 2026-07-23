// wwand — per-modem state machine for NCM control (cdc_ncm / cdc_ether driver,
// AT-controlled).
//
// NCM modems have NO rich control protocol (no QMI, no MBIM): the whole modem
// is driven over an AT command channel (a ttyUSB/ttyACM serial port), and the
// datapath is a plain cdc_ncm/cdc_ether netdev (wwan0). There is therefore no
// message transport to open here — every step is an AT command over the shared
// AT engine (atcmd.uc), the same one the QMI/MBIM backends use as a side
// channel. Bring-up:
//   open AT -> identify (CGMI/CGMM/CGMR/CGSN/CIMI/CCID) -> SIM/PIN (CPIN?) ->
//   program the attach PDP context + auth from the attached context's config
//   (CGDCONT + vendor auth) -> wait for registration (CEREG?/CREG?) -> READY.
// Registration and telemetry are kept fresh by polling AT while READY.
//
// The object exposes the SAME contract as modem.uc / modem_mbim.uc (start/stop/
// state/config/info/reg/signal/at/attach_context/note_connect_*/switch_protocol
// + events) so daemon.uc, the netifd shim and ubus stay protocol-neutral.
// Contexts use context_ncm.uc, which reuses the AT builders exported here.

'use strict';

import * as uloop from 'uloop';
import * as atcmd from './atcmd.uc';
import * as modem_common from './modem_common.uc';
import * as recovery_mod from './recovery.uc';
import * as protoswitch from './protocol_switch.uc';
import * as netlink from './netlink.uc';
import * as nasmod from './codec/schema/nas.uc';

const TIMING_DEFAULTS = {
	settle: 2000,
	reg_timeout: 240000,
	reg_poll: 2000,
	backoff_min: 5000,
	backoff_max: 30000,
	at_drain: 60000,
};

// fast "watch" mode timing (mirrors modem.uc / modem_mbim.uc): while a consumer
// (the LuCI status page) polls modem_signal/modem_cells, refresh at most once a
// second and revert to the slow telemetry timer a few seconds after polling.
const WATCH_MIN_INTERVAL = 1000;
const WATCH_DECAY = 6000;

// --- AT command model (shared with context_ncm.uc) ---------------------------
//
// pdp_type -> the 3GPP PDP type string used in AT+CGDCONT and the Quectel
// AT+QICSGP <context_type> enum (1=IPv4, 2=IPv6, 3=IPv4v6).

const PDP_STR = { ipv4: 'IP', ipv6: 'IPV6', ipv4v6: 'IPV4V6' };
const CTX_TYPE = { ipv4: 1, ipv6: 2, ipv4v6: 3 };

// QICSGP / CGAUTH auth enum: 0=none, 1=PAP, 2=CHAP, 3=PAP-or-CHAP
const AUTH_ENUM = { none: 0, pap: 1, chap: 2, both: 3 };

// resolve the auth method: explicit config wins; otherwise default to
// PAP-or-CHAP when a username/password pair is present (QMI/MBIM parity), else
// none.
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
// (optionally) reports the binding state. It is resolved PER MODEM at bring-up
// rather than hard-coded per vendor, because it varies within a vendor by
// platform: a method carrying a `probe` command is adopted only if the modem
// answers OK; the vendor's `dials` are tried in order and always fall back to
// the 3GPP CGACT dial, which every 3GPP modem supports.
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
//   AT+ECMDUP=<pdpid>,<action>  (action 1=connect, 0=disconnect)
//   AT+ECMDUP? -> +ECMDUP: <pdpid>,<v4status>,"IPV4",<v6status>,"IPV6"
const DIAL_ECMDUP = {
	name: 'ecmdup',
	probe: null,
	connect: (cid) => sprintf('AT+ECMDUP=%d,1', cid),
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

// Per-manufacturer AT recipe. Everything vendor-specific (init, the context
// definition, the auth command, the ordered `dials` to probe, the traffic
// counters) lives here so adding a manufacturer is a table entry rather than a
// code change. Recipes with concrete commands are ported from OpenWrt's
// /etc/gcom/ncm.json (the reference NCM implementation) and are authoritative;
// the ones marked "best-effort" are added from vendor docs and want a hardware
// check.
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
		dials: [ DIAL_ECMDUP, DIAL_CGACT ],
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
		modem_init: [],
		auth_cmd: null,
		dials: [ DIAL_NDISDUP, DIAL_CGACT ],
		stats: null,
		parse_stats: () => null,
	},

	// Sierra Wireless / Netgear: $QCPDPP sets auth (password THEN username);
	// !SCACT activates. Ported from ncm.json.
	sierra: {
		match: /sierra|netgear/,
		modem_init: [ 'AT+CFUN=1' ],
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

	// Fibocom (best-effort): GTRNDIS binds the RNDIS/NCM netdev. Auth via CGAUTH.
	fibocom: {
		match: /fibocom/,
		modem_init: [ 'AT+CFUN=1' ],
		auth_cmd: (cid, ctxtype, apn, cfg) => (cfg.username || cfg.password)
			? sprintf('AT+CGAUTH=%d,%d,"%s","%s"', cid, auth_value(cfg),
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
		dials: [ DIAL_TECM, DIAL_CGACT ],
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

// pick the vendor recipe from the AT+CGMI manufacturer string. The generic
// fallback is skipped in the scan (its match is null) and returned last.
export function vendor_for(manufacturer)
{
	let s = lc(manufacturer ?? '');

	for (let name, v in VENDORS)
		if (v.match && match(s, v.match))
			return v;

	return VENDORS.generic;
}

// AT command sequence to program a PDP context + auth from a context config
// (the per-connect setup, NOT the one-time modem_init). An empty/unset APN is
// intentional: it means "use the network default APN", a *blank* APN in the
// context definition (the network then assigns the default PDN), mirroring
// context.uc's attach-profile behavior. Returns [] for a '#N' pass-through APN
// (use the modem profile as-is, never rewrite it).
export function build_pdp_setup(vendor, cid, cfg)
{
	let apn = cfg.apn;

	if (apn != null && substr(apn, 0, 1) == '#')
		return [];

	let key = cfg.pdp_type ?? 'ipv4v6';
	let pdp = PDP_STR[key] ?? PDP_STR.ipv4v6;
	let ctxtype = CTX_TYPE[key] ?? CTX_TYPE.ipv4v6;
	let target_apn = apn ?? '';   // blank => network default

	let define = vendor.define ?? cgdcont;
	let cmds = [ define(cid, pdp, target_apn) ];
	let ac = vendor.auth_cmd ? vendor.auth_cmd(cid, ctxtype, target_apn, cfg) : null;

	if (ac)
		push(cmds, ac);

	return cmds;
}

// --- CGCONTRDP parsing (shared with context_ncm.uc) --------------------------
//
// AT+CGCONTRDP=<cid> reports the dynamic parameters of an active context. The
// 3GPP layout is:
//   +CGCONTRDP: <cid>,<bearer>,<apn>,<local_addr_and_subnet_mask>,<gw>,
//               <dns1>,<dns2>[,<p-cscf1>,<p-cscf2>,<im_cn>,<lipa>,<ipv4_mtu>...]
// but firmwares diverge wildly for a dual-stack (ipv4v6) context. The RG650E-EU
// crams BOTH families into ONE line with irregular comma/space separators and
// mixed field widths (verified on HW), e.g.:
//   +CGCONTRDP: 1,5,"apn","100.71.169.229","42.0.0.32.66.143.62.233...",
//     "254.128.0.0...1","139.7.30.125" "42.1.8.96...83","139.7.30.126" "42.1.8.96...1.83"
// where the local addr is a bare 4-octet IPv4 (no mask), the next 16-octet field
// is the IPv6 address, and v4 DNS + v6 DNS are interleaved.
//
// So rather than trust positions, we tokenize every dotted-decimal group in the
// line(s) (tolerating both comma and space separators), classify each by octet
// count (4/8 = IPv4[+mask], 16/32 = IPv6[+mask]), bucket per family IN ORDER,
// then map each family's tokens as [addr(+mask), gateway?, dns...]. Heuristic:
// the gateway slot is taken only when the address carried a mask (8/32 octets)
// or for IPv6 (which always advertises a link-local gateway) — an unmasked IPv4
// address (RG650E) has no gateway field, so every remaining v4 token is DNS.
// This yields the neutral { ipv4:{addr,prefix,gateway,dns[],mtu}, ipv6:{addr,
// plen,gateway,dns[]}, mtu } shape for both the merged and the one-line-per-
// family styles.

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
}

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

// +CEREG/+CREG: <n>,<stat>[,...] — registered when stat is 1 (home) or 5
// (roaming). Handles both the query echo (<n>,<stat>) and the URC (<stat>).
function parse_creg(lines)
{
	for (let l in (lines ?? [])) {
		// query form "<n>,<stat>" first, then the URC form "<stat>"
		let m = match(l, /\+CE?REG:\s*[0-9]+,([0-9]+)/) ?? match(l, /\+CE?REG:\s*([0-9]+)/);

		if (!m)
			continue;

		let stat = +m[1];

		return { stat: stat, registered: (stat == 1 || stat == 5), roaming: (stat == 5) };
	}

	return null;
}

// +CSQ: <rssi>,<ber> — rssi 0..31 coded (99 = unknown) -> dBm
function parse_csq(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /\+CSQ:\s*([0-9]+),/);

		if (m) {
			let raw = +m[1];

			return { rssi_raw: raw, rssi: (raw != 99) ? (-113 + 2 * raw) : null };
		}
	}

	return null;
}

// derive the data-system mode (LTE / NSA / SA) from the QENG serving detail —
// the NR line states NSA/SA directly. Mirrors modem.uc/modem_mbim.uc.
function dsd_from_serving(serving)
{
	let lte = serving?.lte != null;
	let nr  = serving?.nr != null;
	let mode = nr ? (serving.nr.mode ?? (lte ? 'NSA' : 'SA')) : (lte ? 'LTE' : null);

	return mode ? { mode: mode, lte: lte, nr: nr, source: 'at' } : null;
}

// --- per-vendor telemetry ----------------------------------------------------
//
// The telemetry AT differs per manufacturer, so each VENDORS entry carries a
// `telemetry` block instead of the loop hard-coding Quectel commands. A block
// provides best-effort steps, each taking the modem `self` + a completion cb and
// mutating self.signal / self.cells / self.reg_detail using self.at:
//   signal(self, cb)      -> self.signal      (RSSI/RSRP/RSRQ/SNR per RAT)
//   cells(self, cb)       -> self.cells        (QMI GET_CELL_LOCATION_INFO shape:
//                                               lte_intra/lte_inter/nr5g_cell + serving)
//   ca(self, cb)          -> self.cells.ca     (carrier-aggregation carriers)
//   reg_detail(self, cb)  -> self.reg_detail   ({ source, reject_cause, reject_text })
//   locks(self, cb)?      -> self.locks        (cell-lock read-back; optional)
// Every command is best-effort — an AT error is swallowed and the step keeps the
// last-known value. Vendors without a block fall back to TELEMETRY_GENERIC (a
// 3GPP-only CSQ+CESQ+CEER set). `unverified: true` blocks log a one-time warning.
//
// SCALING (matches the QMI backend so the LuCI status page renders identically):
//   - self.signal.{lte,nr5g}: rsrp/rsrq/rssi in plain dBm/dB, snr in 0.1 dB.
//   - cell-structure metrics (lte_intra/lte_inter cells, nr5g_cell): 0.1 dB units
//     (the atcmd parsers already ×10) so they render through LuCI's sig10 (÷10)
//     path exactly like the QMI GET_CELL_LOCATION_INFO set.

// merge a CSQ RSSI floor into self.signal without clobbering per-RAT metrics
function sig_csq_floor(self, s)
{
	let base = { ...(self.signal ?? {}) };

	if (s) {
		base.rssi_raw = s.rssi_raw;

		if (base.lte == null && base.nr5g == null)
			base.rssi = s.rssi;
	}

	self.signal = base;
}

// mirror serving-cell metrics into self.signal.{lte,nr5g} only where a more
// authoritative source (per-branch QRSRP/QRSRQ/QSINR, ^HCSQ, CESQ) left a gap
function fill_signal_from_serving(self, serving)
{
	let sig = { ...(self.signal ?? {}) };

	if (serving?.lte) {
		let cur = { ...(sig.lte ?? {}) };

		cur.rssi = cur.rssi ?? sig.rssi;
		cur.rsrp = cur.rsrp ?? serving.lte.rsrp;
		cur.rsrq = cur.rsrq ?? serving.lte.rsrq;

		if (cur.snr == null && serving.lte.sinr != null)
			cur.snr = serving.lte.sinr * 10;   // QMI snr is 0.1 dB

		sig.lte = cur;
	}

	if (serving?.nr) {
		let cur = { ...(sig.nr5g ?? {}) };

		cur.rsrp = cur.rsrp ?? serving.nr.rsrp;
		cur.rsrq = cur.rsrq ?? serving.nr.rsrq;

		if (cur.snr == null && serving.nr.sinr != null)
			cur.snr = serving.nr.sinr * 10;

		sig.nr5g = cur;
	}

	self.signal = sig;
}

// group a flat inter-frequency neighbour list into { freqs:[{earfcn,cells:[]}] }
// (numeric keys are quoted per the ucode object-key gotcha, looked up via %d)
function group_inter(list)
{
	let byf = {}, order = [];

	for (let c in (list ?? [])) {
		let k = sprintf('%d', c.earfcn ?? -1);

		if (!byf[k]) {
			byf[k] = { earfcn: c.earfcn, cells: [] };
			push(order, k);
		}

		push(byf[k].cells, { pci: c.pci, rsrp: c.rsrp, rsrq: c.rsrq,
		                     rssi: c.rssi, srxlev: c.srxlev });
	}

	if (!length(order))
		return null;

	let freqs = [];

	for (let k in order)
		push(freqs, byf[k]);

	return { freqs: freqs };
}

// build the QMI lte_intra/lte_inter/nr5g_cell shape from a parsed serving cell
// (parse_qeng_servingcell/parse_monsc/parse_meng_servingcell) + a neighbour set
// ({ intra:[], inter:[] } already in 0.1 dB units). `sc` carries mcc/mnc/cid/tac/
// earfcn/pci and dBm rsrp/rsrq (via rsrp_dbm/rsrq_db or serving.lte.*).
function assemble_cells(self, serving, neigh, dsd)
{
	if (!serving || (!serving.lte && !serving.nr))
		return;   // keep last-known cells

	let ca = self.cells?.ca;
	let cells = { serving: serving };
	let sl = serving.lte;

	if (sl) {
		let scells = [];

		// the serving cell is the lte_intra entry whose pci == serving_cell_id
		if (sl.pci != null)
			push(scells, {
				pci: sl.pci,
				rsrp: (sl.rsrp != null) ? sl.rsrp * 10 : null,
				rsrq: (sl.rsrq != null) ? sl.rsrq * 10 : null,
				rssi: (sl.rssi != null) ? sl.rssi * 10 : null,
				srxlev: null,
			});

		for (let c in (neigh?.intra ?? []))
			if (c.pci != sl.pci)
				push(scells, c);

		cells.lte_intra = {
			plmn: (sl.mcc != null && sl.mnc != null) ? sprintf('%d/%s', sl.mcc, sl.mnc) : null,
			tac: sl.tac, global_cell_id: sl.cid, earfcn: sl.earfcn,
			serving_cell_id: sl.pci, cells: scells,
		};

		let inter = group_inter(neigh?.inter);

		if (inter)
			cells.lte_inter = inter;
	}

	let sn = serving.nr;

	if (sn) {
		cells.nr5g_arfcn = sn.arfcn;
		cells.nr5g_cell = {
			plmn: (sn.mcc != null && sn.mnc != null) ? sprintf('%d/%s', sn.mcc, sn.mnc) : null,
			tac: sn.tac, global_cell_id: sn.cid, pci: sn.pci,
			rsrp: (sn.rsrp != null) ? sn.rsrp * 10 : null,
			rsrq: (sn.rsrq != null) ? sn.rsrq * 10 : null,
			snr: (sn.sinr != null) ? sn.sinr * 10 : null,
		};
	}

	if (ca != null)
		cells.ca = ca;

	self.cells = cells;
	self.dsd_status = dsd ?? dsd_from_serving(serving);
	fill_signal_from_serving(self, serving);
}

// --- Quectel / Qualcomm telemetry (primary; verified command syntax) ---------

function tel_quectel_signal(self, cb)
{
	modem_common.telemetry_at(self).send('AT+CSQ', (err, res) => {
		sig_csq_floor(self, err ? null : parse_csq(res?.lines));

		// per-branch QRSRP/QRSRQ/QSINR: authoritative rsrp/rsrq/snr (antenna aim)
		modem_common.telemetry_at(self).send('AT+QRSRP?', (e1, r1) => {
			let rp = e1 ? null : atcmd.parse_qrsrp(r1?.lines);

			modem_common.telemetry_at(self).send('AT+QRSRQ?', (e2, r2) => {
				let rq = e2 ? null : atcmd.parse_qrsrq(r2?.lines);

				modem_common.telemetry_at(self).send('AT+QSINR?', (e3, r3) => {
					let sn = e3 ? null : atcmd.parse_qsinr(r3?.lines);

					let mode = rp?.mode ?? rq?.mode ?? sn?.mode;

					if (mode) {
						let sig = { ...(self.signal ?? {}) };
						let slot = (index(mode, 'NR') >= 0) ? 'nr5g' : 'lte';
						let cur = { ...(sig[slot] ?? {}) };
						let rsrp = atcmd.branch_best(rp, -200);
						let rsrq = atcmd.branch_best(rq, -200);
						let sinr = atcmd.branch_best(sn, -200);

						if (rsrp != null) cur.rsrp = rsrp;
						if (rsrq != null) cur.rsrq = rsrq;
						if (sinr != null) cur.snr = sinr * 10;
						if (slot == 'lte' && cur.rssi == null) cur.rssi = sig.rssi;

						sig[slot] = cur;
						self.signal = sig;
					}

					cb();
				});
			});
		});
	});
}

function tel_quectel_cells(self, cb)
{
	modem_common.telemetry_at(self).send('AT+QENG="servingcell"', (err, res) => {
		let serving = err ? null : atcmd.parse_qeng_servingcell(res?.lines);

		modem_common.telemetry_at(self).send('AT+QENG="neighbourcell"', (e2, r2) => {
			let neigh = e2 ? null : atcmd.parse_qeng_neighbourcell(r2?.lines);

			assemble_cells(self, serving, neigh);
			cb();
		});
	});
}

function tel_quectel_ca(self, cb)
{
	modem_common.telemetry_at(self).send('AT+QCAINFO', (err, res) => {
		if (!err && self.cells)
			self.cells.ca = atcmd.parse_qcainfo(res?.lines);

		cb();
	});
}

// cell-lock read-back: expose whether a 4G/5G lock is currently armed so the
// status / settings pages can show it (mirrors nothing in QMI, but useful)
function tel_quectel_locks(self, cb)
{
	modem_common.telemetry_at(self).send('AT+QNWLOCK="common/4g"', (e1, r1) => {
		let l4 = e1 ? null : atcmd.parse_qnwlock(r1?.lines);

		modem_common.telemetry_at(self).send('AT+QNWLOCK="common/5g"', (e2, r2) => {
			let l5 = e2 ? null : atcmd.parse_qnwlock(r2?.lines);
			let locks = {};

			if (l4) locks.lte = { enabled: l4.enabled, values: l4.values };
			if (l5) locks.nr5g = { enabled: l5.enabled, values: l5.values };

			self.locks = length(locks) ? locks : null;
			cb();
		});
	});
}

// --- generic 3GPP telemetry (always-available fallback) ----------------------

function merge_cesq_signal(self, c)
{
	let sig = { ...(self.signal ?? {}) };

	if (c.lte && (c.lte.rsrp != null || c.lte.rsrq != null)) {
		let cur = { ...(sig.lte ?? {}) };

		cur.rssi = cur.rssi ?? sig.rssi;
		if (c.lte.rsrp != null) cur.rsrp = cur.rsrp ?? c.lte.rsrp;
		if (c.lte.rsrq != null) cur.rsrq = cur.rsrq ?? c.lte.rsrq;
		sig.lte = cur;
	}

	if (c.wcdma && c.wcdma.rscp != null)
		sig.wcdma = { rssi: sig.rssi, rscp: c.wcdma.rscp, ecio: c.wcdma.ecno };

	if (c.gsm_rssi != null)
		sig.gsm_rssi = c.gsm_rssi;

	self.signal = sig;
}

function tel_generic_signal(self, cb)
{
	modem_common.telemetry_at(self).send('AT+CSQ', (err, res) => {
		sig_csq_floor(self, err ? null : parse_csq(res?.lines));

		modem_common.telemetry_at(self).send('AT+CESQ', (e2, r2) => {
			let c = e2 ? null : atcmd.parse_cesq(r2?.lines);

			if (c)
				merge_cesq_signal(self, c);

			cb();
		});
	});
}

// generic 3GPP has no portable serving-cell command -> keep last-known cells
function tel_noop(self, cb) { cb(); }

// AT+CEER reject-cause -> reg_detail (mapped through the QMI REJECT_CAUSE table).
// Only populated when a numeric cause is present (a benign "no cause" reply must
// not masquerade as a rejection; on_registered clears reg_detail outright).
function tel_ceer_reg_detail(self, cb)
{
	modem_common.telemetry_at(self).send('AT+CEER', (err, res) => {
		let c = err ? null : atcmd.parse_ceer(res?.lines);

		if (c && c.cause != null)
			self.reg_detail = {
				source: 'at',
				reject_cause: c.cause,
				reject_text: nasmod.REJECT_CAUSE[sprintf('%d', c.cause)] ?? c.text,
			};

		cb();
	});
}

// --- Huawei telemetry (BEST-EFFORT — see atcmd parser notes) -----------------

function tel_huawei_signal(self, cb)
{
	modem_common.telemetry_at(self).send('AT+CSQ', (err, res) => {
		sig_csq_floor(self, err ? null : parse_csq(res?.lines));

		modem_common.telemetry_at(self).send('AT^HCSQ?', (e2, r2) => {
			let h = e2 ? null : atcmd.parse_hcsq(r2?.lines);

			if (h?.lte) {
				let sig = { ...(self.signal ?? {}) };
				let cur = { ...(sig.lte ?? {}) };

				cur.rssi = (h.lte.rssi != null) ? h.lte.rssi : (cur.rssi ?? sig.rssi);
				if (h.lte.rsrp != null) cur.rsrp = h.lte.rsrp;
				if (h.lte.rsrq != null) cur.rsrq = h.lte.rsrq;
				if (h.lte.sinr != null) cur.snr = h.lte.sinr * 10;
				sig.lte = cur;
				self.signal = sig;
			}

			cb();
		});
	});
}

// wrap a parse_monsc/parse_meng_servingcell descriptor as a serving object with
// dBm rsrp/rsrq for fill_signal_from_serving + assemble_cells
function sc_to_serving(sc)
{
	return { lte: {
		band: sc.band, earfcn: sc.earfcn, pci: sc.pci, mcc: sc.mcc, mnc: sc.mnc,
		cid: sc.cid, tac: sc.tac, rsrp: sc.rsrp_dbm, rsrq: sc.rsrq_db, sinr: null,
	} };
}

function tel_huawei_cells(self, cb)
{
	modem_common.telemetry_at(self).send('AT^MONSC', (err, res) => {
		let sc = err ? null : atcmd.parse_monsc(res?.lines);

		modem_common.telemetry_at(self).send('AT^MONNC', (e2, r2) => {
			let nc = e2 ? null : atcmd.parse_monnc(r2?.lines);

			if (sc) {
				let serving = sc_to_serving(sc);
				// serving.lte.rsrp is dBm; assemble_cells ×10 for the intra entry
				assemble_cells(self, serving, { intra: nc ?? [], inter: [] },
					{ mode: 'LTE', lte: true, nr: false, source: 'at' });
			}

			cb();
		});
	});
}

// --- MeiG (ASR) telemetry (BEST-EFFORT — AT+MENG, MeiG's QENG analogue) -------

function tel_meig_cells(self, cb)
{
	modem_common.telemetry_at(self).send('AT+MENG="servingcell"', (err, res) => {
		let sc = err ? null : atcmd.parse_meng_servingcell(res?.lines);

		modem_common.telemetry_at(self).send('AT+MENG="neighbourcell"', (e2, r2) => {
			let nc = e2 ? null : atcmd.parse_meng_neighbourcell(r2?.lines);

			if (sc) {
				let serving = sc_to_serving(sc);
				assemble_cells(self, serving, nc ?? { intra: [], inter: [] },
					{ mode: 'LTE', lte: true, nr: false, source: 'at' });
			}

			cb();
		});
	});
}

const TELEMETRY_QUECTEL = {
	signal: tel_quectel_signal, cells: tel_quectel_cells,
	ca: tel_quectel_ca, reg_detail: tel_ceer_reg_detail, locks: tel_quectel_locks,
};

const TELEMETRY_HUAWEI = {
	signal: tel_huawei_signal, cells: tel_huawei_cells,
	ca: tel_noop, reg_detail: tel_ceer_reg_detail, unverified: true,
};

const TELEMETRY_MEIG = {
	signal: tel_generic_signal, cells: tel_meig_cells,
	ca: tel_noop, reg_detail: tel_ceer_reg_detail, unverified: true,
};

const TELEMETRY_GENERIC = {
	signal: tel_generic_signal, cells: tel_noop,
	ca: tel_noop, reg_detail: tel_ceer_reg_detail,
};

// attach the telemetry blocks to their vendor recipes (kept out of the VENDORS
// literal so the const ordering stays simple). Vendors without an entry inherit
// TELEMETRY_GENERIC via vendor_telemetry().
VENDORS.quectel.telemetry = TELEMETRY_QUECTEL;
VENDORS.meig.telemetry    = TELEMETRY_MEIG;
VENDORS.huawei.telemetry  = TELEMETRY_HUAWEI;
VENDORS.generic.telemetry = TELEMETRY_GENERIC;

function vendor_telemetry(self)
{
	return self.vendor?.telemetry ?? TELEMETRY_GENERIC;
}

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
		fx: opts.recovery?.fx ?? netlink.default_fx((l, m) => log(l, m)),
		state_dir: opts.recovery?.state_dir,
		reboot_delay: opts.recovery?.reboot_delay,
		log: (l, m) => log(l, m),
	});

	rec.load();
	self.counters = rec.counters;
	self.recovery = rec;

	let at_opts = opts.at ?? {};
	let retry_timer = null, reg_timer = null, reg_poll_timer = null, settle_timer = null;
	let at_drain_timer = null, telemetry_timer = null;
	let watch_decay_timer = null, fast_timer = null;
	let watch_active = false, fast_running = false;

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

	// the attach PDP context config: the first attached context (interface-bound
	// preferred) drives the modem's autonomous LTE attach, so its APN/auth is
	// what CGDCONT/QICSGP programs at bring-up. Contexts re-apply the same
	// settings idempotently at dial time (context_ncm.up).
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

	// AT side channel: for NCM this IS the control channel. open_at discovers
	// the tty, opens it and runs model-init + configured at_init + cell locks.
	// Non-fatal only in the sense that a missing port fails the whole modem —
	// there is no other transport.
	self.start = function() {
		if (self.at || self.state != 'ABSENT')
			return;

		self.set_state('INIT_TRANSPORT');

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

							ask('AT+QCCID', (iccid) => {
								self.info.iccid = iccid;

								log('notice', sprintf('ncm modem %s (%s), imei %s, imsi %s, iccid %s',
									self.info.model ?? '?', self.info.manufacturer ?? '?',
									self.info.imei ?? '?', self.info.imsi ?? '?',
									self.info.iccid ?? '?'));

								step_resolve_dial();
							});
						});
					});
				});
			});
		});
	};

	// resolve the dial method ONCE per modem: try the vendor's ordered dials,
	// adopting the first whose support-probe (if any) answers OK. A dial without
	// a probe is adopted directly; the list always ends in CGACT (universal), so
	// self.dial is always set. Verified need: the RG650E answers ERROR to the
	// QNETDEVCTL probe and resolves to CGACT.
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
	// up so it is ready to carry traffic once the modem dials; the IP comes from
	// the connection (context_ncm). Skipped gracefully in host tests (no fx).
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
				let pincode = self.config.pincode;

				if (!pincode) {
					self.set_state('SIM_BLOCKED', { reason: 'pin_required_no_pin' });
					emit('sim_blocked', { reason: 'pin_required_no_pin' });
					notify_contexts('sim_blocked', {});
					return;
				}

				return self.at.send(sprintf('AT+CPIN="%s"', pincode), (verr) => {
					if (verr) {
						self.set_state('SIM_BLOCKED', { reason: 'verify_failed' });
						emit('sim_blocked', { reason: 'verify_failed' });
						notify_contexts('sim_blocked', {});
						return;
					}

					log('notice', 'sim: pin accepted');
					settle_timer = uloop.timer(self.timing.settle, step_attach);
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
				let r = err ? null : parse_creg(res?.lines);

				let after = (rr) => {
					if (rr?.registered)
						return on_registered(rr);

					if (self.state == 'REGISTERING')
						reg_poll_timer = uloop.timer(self.timing.reg_poll, poll);
				};

				// fall back to CREG when CEREG is unavailable/not registered
				if (!r?.registered)
					self.at.send('AT+CREG?', (e2, r2) =>
						after((!e2 && parse_creg(r2?.lines)?.registered) ? parse_creg(r2.lines) : r));
				else
					after(r);
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

		let t = vendor_telemetry(self);

		// one-time warning for best-effort (unverified) vendor telemetry recipes,
		// mirroring how the dial table flags its best-effort methods
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

	// telemetry reads route through the modem's vendor telemetry block (its own
	// AT command set), falling back to the 3GPP-generic block. Each step is
	// best-effort — a command that errors is swallowed and the last-known value
	// is kept — so a modem answering only a subset still degrades gracefully.
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
		log('notice', sprintf('telemetry: roaming=%s rssi=%s dBm mode=%s cells=%s',
			self.reg.roaming ? 'yes' : 'no',
			(self.signal?.lte?.rssi ?? self.signal?.rssi) ?? '?',
			self.dsd_status?.mode ?? '?', self.cells ? 'yes' : 'no'));
	};

	// fast "watch" loop while a consumer polls modem_signal/modem_cells
	let fast_tick;
	fast_tick = () => {
		fast_timer = null;

		if (!watch_active || self.state != 'READY' || !self.at) {
			fast_running = false;
			return;
		}

		fast_running = true;

		refresh_signal(() => {
			if (!self.at) { fast_running = false; return; }

			refresh_cells(() => {
				emit_telemetry();

				if (watch_active && self.at)
					fast_timer = uloop.timer(WATCH_MIN_INTERVAL, fast_tick);
				else
					fast_running = false;
			});
		});
	};

	self.watch = function() {
		watch_active = true;

		if (watch_decay_timer)
			watch_decay_timer.cancel();

		watch_decay_timer = uloop.timer(WATCH_DECAY, () => {
			watch_active = false;
			watch_decay_timer = null;
		});

		if (!fast_running && self.state == 'READY' && self.at)
			fast_tick();
	};

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

				refresh_signal(() => refresh_cells(() => refresh_reg_detail(() => {
					if (!self.at)
						return;

					log_telemetry();
					emit_telemetry();
					telemetry_timer = uloop.timer(interval, tick);
				})));
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

	self.teardown = function() {
		for (let t in [ retry_timer, reg_timer, reg_poll_timer, settle_timer, at_drain_timer,
		                telemetry_timer, watch_decay_timer, fast_timer ])
			if (t)
				t.cancel();

		retry_timer = reg_timer = reg_poll_timer = settle_timer = at_drain_timer = null;
		telemetry_timer = watch_decay_timer = fast_timer = null;
		watch_active = fast_running = false;

		modem_common.close_at(self);
	};

	self.stop = function() {
		self.teardown();
		self.set_state('ABSENT');
	};

	return self;
}
