// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — human-readable text for QMI call-end / activation-failure reasons.
//
// WDS START_NETWORK (and PACKET_SERVICE_STATUS) report two things on failure:
//   call_end_reason         — a coarse WDS enum (TLV 0x10)
//   verbose_call_end {type,reason} — the actionable detail (TLV 0x11): a
//                             reason *type* plus a type-specific *reason* code.
// For type 6 (3GPP) the reason is a 3GPP TS 24.008 Session Management cause —
// this is where "user authentication failed" / "missing or unknown APN" /
// "operator determined barring" come from. We map those to text so the log and
// the status page can show why a PDP activation was refused.
//
// ucode object keys are strings, so the numeric codes below are quoted and the
// lookups convert the incoming number with sprintf('%d', ...).

'use strict';

// QMI_WDS_VERBOSE_CALL_END_REASON_TYPE
const TYPE_NAMES = {
	'1': 'Mobile IP',
	'2': 'internal',
	'3': 'call manager',
	'6': '3GPP',
	'7': 'PPP',
	'8': 'eHRPD',
	'9': 'IPv6',
	// 0x0C is beyond libqmi's type enum (which stops at 9) but is emitted:
	// a teardown caused by an inter-RAT handoff. Without it such a teardown
	// decodes as an unknown type and reads like a fault.
	'12': 'handoff',
};

// 3GPP TS 24.008 §10.5.6.6 Session Management cause values (verbose type 6).
// These are the ones a network actually returns when refusing a PDP context.
const SM_CAUSE = {
	'8':   'operator determined barring',
	'25':  'LLC or SNDCP failure',
	'26':  'insufficient resources',
	'27':  'missing or unknown APN',
	'28':  'unknown PDP address or PDP type',
	'29':  'user authentication failed',
	'30':  'activation rejected by GGSN/gateway',
	'31':  'activation rejected, unspecified',
	'32':  'service option not supported',
	'33':  'requested service option not subscribed',
	'34':  'service option temporarily out of order',
	'35':  'NSAPI already in use',
	'36':  'regular deactivation',
	'37':  'QoS not accepted',
	'38':  'network failure',
	'39':  'reactivation requested',
	'40':  'feature not supported',
	'41':  'semantic error in the TFT operation',
	'42':  'syntactical error in the TFT operation',
	'43':  'unknown PDP context',
	'44':  'semantic errors in packet filter',
	'45':  'syntactical errors in packet filter',
	'46':  'PDP context without TFT already activated',
	'50':  'PDP type IPv4 only allowed',
	'51':  'PDP type IPv6 only allowed',
	'52':  'single address bearers only allowed',
	'56':  'collision with network-initiated request',
	'60':  'bearer handling not supported',
	'65':  'maximum number of PDP contexts reached',
	'66':  'requested APN not supported in current RAT and PLMN',
	'112': 'APN restriction value incompatible with active context',
};

// QMI_WDS_CALL_END_REASON generic values (coarse TLV 0x10). The verbose reason
// (0x11) carries the actionable detail; this names the coarse enum so a drop that
// only reports the coarse code still reads as text instead of a bare number.
const GENERIC_CAUSE = {
	'1':  'unspecified',
	'2':  'client-ended',
	'3':  'no service',
	'4':  'fade (radio signal lost)',
	'5':  'released (normal)',
	'6':  'access attempt in progress',
	'7':  'access failure',
	'8':  'redirection or handoff',
	'9':  'close in progress',
	'10': 'authentication failed',
	'11': 'internal error',
};

// QMI_WDS_VERBOSE_CALL_END_REASON_INTERNAL (verbose type 2) — libqmi
// qmi-enums-wds.h. These come from the modem's own stack, not the network.
// Verbose type 2 (internal) — the modem's own reasons. Generated from libqmi
// 1.38's `QmiWdsVerboseCallEndReason` (qmi-enums-wds.h, LGPL-2.1+), which is the
// only complete public list; the wording of the entries we had written by hand
// is kept. It used to stop at 220, so everything the modem said above that —
// including 243 thermal mitigation, 245/246 data settings disabled and 255 no
// data while roaming — logged as a bare number and fed the recovery ladder the
// same nothing as a genuine failure.
const INTERNAL_CAUSE = {
	'201': 'internal error',
	'202': 'call ended',
	'203': 'unknown internal cause',
	'204': 'unknown cause code',
	'205': 'close in progress',
	'206': 'network-initiated termination',
	'207': 'app preempted',
	'208': 'PDN IPv4 call disallowed',
	'209': 'PDN IPv4 call throttled',
	'210': 'PDN IPv6 call disallowed',
	'211': 'PDN IPv6 call throttled',
	'212': 'modem restart',
	'213': 'PDP PPP not supported',
	'214': 'unpreferred RAT',
	'215': 'physical link close in progress',
	'216': 'APN pending handover',
	'217': 'profile bearer incompatible',
	'218': 'card event (SIM refresh/removal)',
	'219': 'low power mode or power down',
	'220': 'APN disabled',
	'221': 'mpit expired',
	'222': 'IPv6 address transfer failed',
	'223': 'trat swap failed',
	'224': 'ehrpd to hrpd fallback',
	'225': 'mandatory APN disabled',
	'226': 'MIP config failure',
	'227': 'PDN inactivity timer expired',
	'228': 'max v4 connections',
	'229': 'max v6 connections',
	'230': 'APN mismatch',
	'231': 'ip version mismatch',
	'232': 'dun call disallowed',
	'233': 'invalid profile',
	'234': 'epc nonepc transition',
	'235': 'invalid profile id',
	'236': 'call already present',
	'237': 'interface in use',
	'238': 'ip PDP mismatch',
	'239': 'APN disallowed on roaming',
	'240': 'APN parameter change',
	'241': 'interface in use, config matches an existing call',
	'242': 'null APN disallowed',
	'243': 'thermal mitigation',
	'244': 'subs id mismatch',
	'245': 'data settings disabled',
	'246': 'data roaming settings disabled',
	'247': 'APN format invalid',
	'248': 'dds call abort',
	'249': 'validation failure',
	'251': 'profiles not compatible',
	'252': 'null resolved APN no match',
	'253': 'invalid APN name',
	'254': 'dds switch in progress',
	'255': 'call disallowed in roaming',
	'256': 'mo exceptional not supported',
	'257': 'non ip not supported',
	'258': 'error PDN non ip call throttled',
	'259': 'error PDN non ip call disallowed',
	'261': 'error non ip type mismatch',
	'262': 'error max nb PDN reached',
	'263': 'invalid APN',
	'264': 'slice not allowed',
	'265': 'routing fail',
	'266': 'routing changed',
	'267': 'local area data network data network name not available',
	'268': 'APN type mismatch',
};

// Verbose type 3 (call manager). This table did not exist at all, so EVERY
// type-3 reason printed as "call manager cause N" — including the ones that say
// plainly that retrying is pointless (520/521 access blocked, 523 thermal
// emergency, 524 origination throttled, 1010 PLMN not allowed, 1017 access
// class barred). Same source and licence as above.
const CM_CAUSE = {
	'500': 'CDMA lock',
	'501': 'intercept',
	'502': 'reorder',
	'503': 'release so reject',
	'504': 'incoming call',
	'505': 'alert stop',
	'506': 'activation',
	'507': 'max access probes',
	'508': 'ccs not supported by bs',
	'509': 'no response from bs',
	'510': 'rejected by bs',
	'511': 'incompatible',
	'512': 'already in tc',
	'513': 'user call originated during gps',
	'514': 'user call originated during sms',
	'515': 'no CDMA service',
	'516': 'mc abort',
	'517': 'psist ng',
	'518': 'UIM not present',
	'519': 'retry order',
	'520': 'access block',
	'521': 'access block all',
	'522': 'is707b max access probes',
	'523': 'thermal emergency',
	'524': 'call origination throttled',
	'525': 'user call originated',
	'1000': 'conference failed',
	'1001': 'incoming rejected',
	'1002': 'no gateway service',
	'1003': 'no GPRS context',
	'1004': 'illegal ms',
	'1005': 'illegal me',
	'1006': 'GPRS and non GPRS services not allowed',
	'1007': 'GPRS services not allowed',
	'1008': 'ms identity not derived by the network',
	'1009': 'implicitly detached',
	'1010': 'PLMN not allowed',
	'1011': 'la not allowed',
	'1012': 'GPRS services not allowed in PLMN',
	'1013': 'PDP duplicate',
	'1014': 'ue RAT change',
	'1015': 'congestion',
	'1016': 'no PDP context activated',
	'1017': 'access class DSAC rejection',
	'1018': 'PDP activate max retry failed',
	'1019': 'rab failure',
	'1020': 'eps service not allowed',
	'1021': 'tracking area not allowed',
	'1022': 'roaming not allowed in tracking area',
	'1023': 'no suitable cells in tracking area',
	'1024': 'not authorized closed subscriber group',
	'1025': 'ESM unknown eps bearer context',
	'1026': 'DRB released at RRC',
	'1027': 'NAS signal connection released',
	'1028': 'EMM detached',
	'1029': 'EMM attach failed',
	'1030': 'EMM attach started',
	'1031': 'LTE NAS service request failed',
	'1032': 'ESM active dedicated bearer reactivated by nw',
	'1033': 'ESM lower layer failure',
	'1034': 'ESM sync up with nw',
	'1035': 'ESM nw activated dedicated bearer with id of default bearer',
	'1036': 'ESM bad ota message',
	'1037': 'ESM ds rejected call',
	'1038': 'ESM context transferred due to irat',
	'1039': 'ds explicit deact',
	'1040': 'ESM local cause none',
	'1041': 'LTE NAS service request failed no throttle',
	'1042': 'acl failure',
	'1043': 'LTE NAS service request failed ds disallow',
	'1044': 'EMM t3417 expired',
	'1045': 'EMM t3417 ext expired',
	'1046': 'LTE RRC ul data confirmation failure txn',
	'1047': 'LTE RRC ul data confirmation failure handover',
	'1048': 'LTE RRC ul data confirmation failure conn rel',
	'1049': 'LTE RRC ul data confirmation failure rlf',
	'1050': 'LTE RRC ul data confirmation failure ctrl not conn',
	'1051': 'LTE RRC connection establishment failure',
	'1052': 'LTE RRC connection establishment failure aborted',
	'1053': 'LTE RRC connection establishment failure access barred',
	'1054': 'LTE RRC connection establishment failure cell reselection',
	'1055': 'LTE RRC connection establishment failure config failure',
	'1056': 'LTE RRC connection establishment failure timer expired',
	'1057': 'LTE RRC connection establishment failure link failure',
	'1058': 'LTE RRC connection establishment failure not camped',
	'1059': 'LTE RRC connection establishment failure si failure',
	'1060': 'LTE RRC connection establishment failure rejected',
	'1061': 'LTE RRC connection release normal',
	'1062': 'LTE RRC connection release rlf',
	'1063': 'LTE RRC connection release cre failure',
	'1064': 'LTE RRC connection release oos during cre',
	'1065': 'LTE RRC connection release aborted',
	'1066': 'LTE RRC connection release sib read error',
	'1067': 'detach with reattach LTE nw detach',
	'1068': 'detach without reattach LTE nw detach',
	'1069': 'ESM proc timeout',
	'1070': 'invalid connection id',
	'1071': 'invalid nsapi',
	'1072': 'invalid pri nsapi',
	'1073': 'invalid field',
	'1074': 'radio access bearer setup failure',
	'1075': 'PDP establish max timeout',
	'1076': 'PDP modify max timeout',
	'1077': 'PDP inactive max timeout',
	'1078': 'PDP lowerlayer error',
	'1079': 'ppd unknown reason',
	'1080': 'PDP modify collision',
	'1081': 'PDP mbms request collision',
	'1082': 'mbms duplicate',
	'1083': 'sm ps detached',
	'1084': 'sm no radio available',
	'1085': 'sm abort service not available',
	'1086': 'message exceeds max l2 limit',
	'1087': 'sm NAS service request failure',
	'1088': 'RRC connection establishment failure request error',
	'1089': 'RRC connection establishment failure tai change',
	'1090': 'RRC connection establishment failure rf unavailable',
	'1091': 'RRC connection release aborted inter RAT success',
	'1092': 'RRC connection release rlf sec not active',
	'1093': 'RRC connection release inter RAT to LTE aborted',
	'1094': 'RRC connection release inter RAT from LTE to geran cco success',
	'1095': 'RRC connection release inter RAT from LTE to geran cco aborted',
	'1096': 'imsi unknown in home subscriber server',
	'1097': 'imei not accepted',
	'1098': 'eps services and non eps services not allowed',
	'1099': 'eps services not allowed in PLMN',
	'1100': 'msc temporarily not reachable',
	'1101': 'cs domain not available',
	'1102': 'ESM failure',
	'1103': 'mac failure',
	'1104': 'synchronization failure',
	'1105': 'ue security capabilities mismatch',
	'1106': 'security mode reject unspecified',
	'1107': 'non eps auth unacceptable',
	'1108': 'cs fallback call establishment not allowed',
	'1109': 'no eps bearer context activated',
	'1110': 'EMM invalid state',
	'1111': 'NAS layer failure',
	'1112': 'multi PDN not allowed',
	'1113': 'embms not enabled',
	'1114': 'pending redial call cleanup',
	'1115': 'embms regular deactivation',
	'1116': 'tlb regular deactivation',
	'1117': 'lower layer registration failure',
	'1118': 'detach eps services not allowed',
	'1119': 'sm internal PDP deactivation',
	'1500': 'connection deny general or busy',
	'1501': 'connection deny billing or authentication failure',
	'1502': 'hdr change',
	'1503': 'hdr exit',
	'1504': 'hdr no session',
	'1505': 'hdr origination during gps fix',
	'1506': 'hdr connection setup timeout',
	'1507': 'hdr released by cm',
	'1508': 'hdr collocated acquisition failed',
	'1509': 'otasp commit in progress',
	'1510': 'hdr no hybrid service',
	'1511': 'hdr no lock granted',
	'1512': 'hold other in progress',
	'1513': 'hdr fade',
	'1514': 'hdr access failure',
	'1515': 'unsupported 1x prev',
	'2000': 'client end',
	'2001': 'no service',
	'2002': 'fade',
	'2003': 'release normal',
	'2004': 'access attempt in progress',
	'2005': 'access failure',
	'2006': 'redirection or handoff',
	'2500': 'offline',
	'2501': 'emergency mode',
	'2502': 'phone in use',
	'2503': 'invalid mode',
	'2504': 'invalid SIM state',
	'2505': 'no collocated hdr',
	'2506': 'call control rejected',
	'2507': 'EMM detached psm',
	'2508': 'dual switch',
	'2509': 'call manager',
	'2510': 'invalid class3 APN',
	'2511': 'mplmn in progress',
};

// Return { code, type, type_name, text } or null when there is nothing to say.
// `verbose` is { type, reason }; `reason` is the coarse call_end_reason.
// Verbose type 2 (internal) reason 241 is libqmi's INTERFACE_IN_USE_CONFIG_MATCH:
// an autonomously-activated context whose configuration matches ours holds the
// CID (HW-observed on Zyxel RG502Q firmware self-activating profile 2). The QMI
// context reclaims it via AT+CGACT.
//
// The TRIGGER is right — 241 is what that hardware reports — but the label was
// not: this table used to call 241 "PDP context already in use", which is the
// meaning of 236 (CALL_ALREADY_PRESENT). Two different conditions, and the one
// we act on is the config-match case, not the generic one.
export const VERBOSE_TYPE_INTERNAL = 2;
export const VERBOSE_TYPE_CM = 3;
export const INTERNAL_PDP_IN_USE = 241;

export function describe(reason, verbose, ext_error) {
	if (verbose != null && verbose.type != null) {
		let tname = TYPE_NAMES[sprintf('%d', verbose.type)] ?? sprintf('type %d', verbose.type);
		let text = null;
		if (verbose.type == 6)
			text = SM_CAUSE[sprintf('%d', verbose.reason)];
		else if (verbose.type == VERBOSE_TYPE_INTERNAL)
			text = INTERNAL_CAUSE[sprintf('%d', verbose.reason)];
		else if (verbose.type == VERBOSE_TYPE_CM)
			text = CM_CAUSE[sprintf('%d', verbose.reason)];

		return {
			code:      verbose.reason,
			type:      verbose.type,
			type_name: tname,
			ext_error: ext_error,
			text:      text ?? sprintf('%s cause %d', tname, verbose.reason),
		};
	}

	if (reason != null)
		return {
			code: reason,
			text: GENERIC_CAUSE[sprintf('%d', reason)] ?? sprintf('call ended (reason %d)', reason),
		};

	if (ext_error != null)
		return { code: ext_error, text: sprintf('activation failed (ext error %d)', ext_error) };

	return null;
};
