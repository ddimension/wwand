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
	'241': 'PDP context already in use',
};

// Return { code, type, type_name, text } or null when there is nothing to say.
// `verbose` is { type, reason }; `reason` is the coarse call_end_reason.
// verbose type 2 (internal) reason 241: "PDP context already in use" — an
// autonomously-activated context holds the CID (e.g. Zyxel RG502Q firmware
// self-activating profile 2). The QMI context reclaims it via AT+CGACT.
export const VERBOSE_TYPE_INTERNAL = 2;
export const INTERNAL_PDP_IN_USE = 241;

export function describe(reason, verbose, ext_error) {
	if (verbose != null && verbose.type != null) {
		let tname = TYPE_NAMES[sprintf('%d', verbose.type)] ?? sprintf('type %d', verbose.type);
		let text = null;
		if (verbose.type == 6)
			text = SM_CAUSE[sprintf('%d', verbose.reason)];
		else if (verbose.type == VERBOSE_TYPE_INTERNAL)
			text = INTERNAL_CAUSE[sprintf('%d', verbose.reason)];

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
