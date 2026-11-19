// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — USSD (TS 22.090 / 24.090): send a code, answer a network request,
// cancel the session, and report what the network sends on its own.
//
// Three transports, the first a modem has wins: QMI Voice (native, or over the
// MBIM passthrough), the native MBIM USSD service, AT+CUSD. The choice is made
// once per modem and never changed by a failure: a USSD is not idempotent —
// `*code#` may book a tariff — so a code the network may have seen is never
// sent a second time over another transport. A transport is skipped only when
// it is not there at all; one that is there and failed to come up is an error.
//
// One session per modem, as the network has it: `idle`, `active` (a request
// out, from the moment send() accepts it until its callback), `user_response`
// (the network asked a question; the next send answers it). Network-initiated
// messages are emitted as the modem event `ussd` ({ text, action_required,
// origin, via }). The session belongs to one incarnation of the modem's
// channels: a re-init ends it (sess).
//
//   send(modem, text, cb)  -> cb(err, { reply, action_required, session, via })
//   cancel(modem, cb)      -> cb(err, { session })
//   status(modem)          -> { session, via, last } | null
//   arm(modem)             -> listen for network-initiated USSD (best-effort)

'use strict';

import * as uloop from 'uloop';
import * as sms_pdu from 'wwand.sms_pdu';
import * as hexmod from 'wwand.codec.hex';

// a reply that comes as an indication or a URC (QMI Answer, MBIM and AT
// throughout) — the network's own timer is 30 s to some minutes (24.090), so
// this is generous rather than tight
const REPLY_TIMEOUT_MS = 100000;

// After a QMI Originate answer, the USSD indication that says whether the
// network wants a reply can come a moment later. Waited for this long before
// the result is handed back, so `action_required` reflects it.
const QMI_SETTLE_MS = 400;

// how long an indication/notification carrying the text just returned as the
// reply is taken for that reply's echo rather than for a new message
const ECHO_S = 5;

// CBS DCS for a USSD string (TS 23.038 §5): GSM7 no language, UCS2 no class
const DCS_GSM7 = 0x0F;
const DCS_UCS2 = 0x48;

let now = () => time();

// What the session is bound to: a re-init bumps _gen (QMI, MBIM) or reopens
// the AT channel (NCM, which has no _gen), and either way a request in flight
// will never be answered — its callback is gone with the old channel.
function token_of(modem)
{
	return [ modem._gen ?? 0, modem.at, modem.mbim ];
}

function same_token(a, b)
{
	return a[0] == b[0] && a[1] === b[1] && a[2] === b[2];
}

// THE REQUEST is one object from send() to its callback, and completes once
// (complete): every transport callback, the settle timer, a cancel, a release
// and a re-init all go through it, so a late one finds it done and is
// dropped — it can neither answer twice nor touch a newer request's session.
//   { cb, s (its session), done, waiting (acknowledged, reply still to
//     come), note (a message that arrived for it before that), timer }
// `keep` = the state to leave the session in on an error that sent nothing
// (the network's question still stands) — set before the callback runs, which
// may send the answer at once.
function complete(modem, req, err, res, keep)
{
	if (!req || req.done)
		return;

	req.done = true;
	req.timer?.cancel();

	// current = still this modem's session, on the same channels: the
	// session is replaced lazily (sess), so a callback from the old channel
	// can come before anything noticed the re-init
	let s = req.s;
	let current = (modem._ussd === s && s.req === req && same_token(s.token, token_of(modem)));

	if (current) {
		s.req = null;
		s.state = (!err && res?.action_required) ? 'user_response' : (err && keep) ? keep : 'idle';
	}
	else {
		// whatever the old channel said, success or its own error: the
		// request did not survive the re-init, and that is the answer
		err = { error: 'reinitialised' };
		res = null;
	}

	if (res)
		res.session = s.state;

	req.cb(err, err ? null : res);
}

// The session; a stale one (the channels it was made on are gone) is ended
// first — its request told, the transport chosen again.
function sess(modem)
{
	let s = modem._ussd;

	let fresh = () => ({ state: 'idle', via: null, req: null, last: null, token: token_of(modem) });

	if (s && !same_token(s.token, token_of(modem))) {
		let r = s.req;

		s.req = null;
		s.state = 'idle';

		// the new session first: the old request's callback may well ask
		modem._ussd = fresh();
		complete(modem, r, { error: 'reinitialised' }, null);

		return modem._ussd;
	}

	if (!s)
		s = modem._ussd = fresh();

	return s;
}

function bytes_of(str)
{
	let out = [];

	for (let i = 0; i < length(str ?? ''); i++)
		push(out, ord(str, i));

	return out;
}

function str_of(arr)
{
	let s = '';

	for (let o in arr)
		s += chr(o);

	return s;
}

// --- reporting ---------------------------------------------------------------

function record(s, text, action_required, origin)
{
	s.last = { text: text, action_required: !!action_required, origin: origin, at: now() };

	return s.last;
}

// the reply that was just returned, coming once more as an indication or a
// notification: no new message — but it may say whether a reply is wanted
function is_echo(s, text)
{
	return s.last?.origin == 'reply' && s.last.text == text && now() - s.last.at <= ECHO_S;
}

// the request's answer: its text and whether the network asks back
function reply(modem, req, text, action_required, via)
{
	record(req.s, text, action_required, 'reply');
	complete(modem, req, null, { reply: text, action_required: !!action_required, via: via });
}

// A message from the network: the answer of the request that waits for one;
// parked on a request still waiting for its acknowledgement (it belongs to
// it — the MBIM set, the QMI Originate or Answer, the AT command); an echo of
// the reply just returned; or the network's own, emitted.
function deliver(modem, text, action_required, via)
{
	let s = sess(modem);
	let r = s.req;

	if (r && !r.done) {
		if (r.waiting)
			return reply(modem, r, text, action_required, via);

		r.note = { text: text, req: !!action_required };
		return;
	}

	if (is_echo(s, text)) {
		s.last.action_required = !!action_required;
		s.state = action_required ? 'user_response' : 'idle';
		return;
	}

	let last = record(s, text, action_required, 'network');

	s.state = last.action_required ? 'user_response' : 'idle';
	modem._emit?.('ussd', { text: text, action_required: last.action_required,
	                        origin: 'network', via: via });
}

// the network or the user ended the session: so ends the request with it,
// waiting or not
function end_session(modem, why)
{
	let s = sess(modem);
	let r = s.req;

	s.state = 'idle';
	complete(modem, r, { error: why }, null);
}

// acknowledged, its text still to come: from a message that arrived first
// (deliver parked it), else waited for
function after_ack(modem, req, via)
{
	if (req.done)
		return;

	if (req.note)
		return reply(modem, req, req.note.text, req.note.req, via);

	req.waiting = true;
	req.timer = uloop.timer(REPLY_TIMEOUT_MS, () => complete(modem, req, { error: 'timeout' }, null));
}

// --- QMI Voice ---------------------------------------------------------------

function qmi_text(d)
{
	if (length(d?.utf16 ?? []))
		return sms_pdu.utf16_units_text(d.utf16);

	let u = d?.uss;

	if (!u || !length(u.data ?? []))
		return null;

	// QmiVoiceUssDataCodingScheme, not the 23.038 byte: ASCII 1, 8-bit 2,
	// UCS2 3 (qmi-enums-voice.h:295-300, libqmi 1.38)
	if (u.dcs == 3)
		return sms_pdu.ucs2_decode(u.data);

	if (u.dcs == 1)
		return str_of(u.data);

	return null;
}

function qmi_encode(text)
{
	for (let i = 0; i < length(text); i++)
		if (ord(text, i) >= 0x80)
			return { dcs: 3, data: sms_pdu.ucs2_encode(text) };

	return { dcs: 1, data: bytes_of(text) };
}

// the indications, once per Voice client: a client allocated again after a
// re-init needs them again, which is why the mark sits on the client
function qmi_arm(modem, voice)
{
	if (voice._ussd_armed)
		return;

	voice._ussd_armed = true;

	voice.on('USSD_IND', (d) => deliver(modem, qmi_text(d), d?.user_action == 2, 'qmi'));
	voice.on('RELEASE_USSD_IND', () => end_session(modem, 'terminated_by_network'));

	voice.request('INDICATION_REGISTER', { ussd: 1 }, () => null, { no_recovery: true });
}

function qmi_send(modem, voice, req, text, answering)
{
	let uss = qmi_encode(text);

	// USS Data counts its octets in a u8 (qmi-service-voice.json, libqmi
	// 1.38): one character outside ASCII makes the whole string UCS2, twice
	// the octets
	if (length(uss.data) > 255)
		return complete(modem, req, { error: 'too_long' }, null, answering ? 'user_response' : null);

	qmi_arm(modem, voice);

	if (answering)
		return voice.request('ANSWER_USSD', { uss: uss }, (err) => {
			if (err)
				return complete(modem, req, { error: 'qmi', detail: err }, null);

			// the network's next message comes as a USSD indication — which
			// may have come before this acknowledgement did
			after_ack(modem, req, 'qmi');
		}, { timeout: REPLY_TIMEOUT_MS, no_recovery: true });

	voice.request('ORIGINATE_USSD', { uss: uss }, (err, d) => {
		if (err)
			return complete(modem, req, { error: 'qmi', detail: err, failure_cause: d?.failure_cause }, null);

		let text = qmi_text(d);

		// the request stays open through the settle: the indication that goes
		// with the answer, before it or during this, lands on req.note
		uloop.timer(QMI_SETTLE_MS, () =>
			reply(modem, req, text ?? req.note?.text, req.note?.req ?? false, 'qmi'));
	}, { timeout: REPLY_TIMEOUT_MS, no_recovery: true });
}

// --- native MBIM ---------------------------------------------------------------

function mbim_text(d)
{
	if (!length(d?.payload ?? ''))
		return null;

	return sms_pdu.cbs_text(d.dcs ?? DCS_GSM7, bytes_of(d.payload)).text;
}

// response/notification -> { text, req } or { error } (a terminal one)
function mbim_result(d)
{
	let name = d?.response_name;

	if (name == 'no_action_required' || name == 'action_required')
		return { text: mbim_text(d), req: (name == 'action_required') };

	return { error: name ?? 'mbim' };
}

function mbim_encode(text)
{
	let p = sms_pdu.gsm7_pack(text);

	return (p != null) ? { dcs: DCS_GSM7, payload: str_of(p) }
	                   : { dcs: DCS_UCS2, payload: str_of(sms_pdu.ucs2_encode(text)) };
}

function mbim_send(modem, req, text, answering)
{
	let e = mbim_encode(text);

	if (length(e.payload) > 160)
		return complete(modem, req, { error: 'too_long' }, null, answering ? 'user_response' : null);

	// CONTINUE answers the network's question, INITIATE starts a session
	modem.mbim_ussd.set(answering ? 1 : 0, e.dcs, e.payload, (err, d) => {
		if (err)
			return complete(modem, req, { error: 'mbim', detail: err }, null);

		let r = mbim_result(d);

		if (r.error)
			return complete(modem, req, { error: r.error }, null);

		// the text may come in the answer, in a notification that came first
		// (req.note), or in one still to come
		if (r.text == null)
			return after_ack(modem, req, 'mbim');

		reply(modem, req, r.text, r.req, 'mbim');
	});
}

// --- AT ------------------------------------------------------------------------

// Huawei firmware takes and gives the USSD string as packed-GSM7 hex, under
// any +CSCS: the plain text was refused (cme UNKNOWN) and the hex answered,
// with the reply in the same form (HW-seen on an ME906s, 11.617.00.00.11,
// 2026-11-19). Others take the text as it is.
function at_hex(modem)
{
	return !!match(modem.info?.manufacturer ?? modem.info?.model ?? '', /huawei/i);
}

// `+CUSD: <m>[,"<str>"[,<dcs>]]` -> { m, text, dcs }
export function parse_cusd(line, hex_mode)
{
	// no (?:) in ucode's regex: the optional groups capture, hence 3 and 5
	let r = match(line ?? '', /^\+CUSD:[ ]*([0-9]+)[ ]*(,[ ]*"([^"]*)"[ ]*(,[ ]*([0-9]+))?)?/);

	if (!r)
		return null;

	let str = r[3], dcs = (r[5] != null) ? +r[5] : DCS_GSM7;
	let text = str;

	if (str != null && match(str, /^([0-9A-Fa-f][0-9A-Fa-f])+$/)) {
		let d = sms_pdu.cbs_dcs(dcs);

		// UCS2 is hex under any +CSCS but UCS2 itself; GSM7 only in the
		// firmware that does it (at_hex) — a reply of digits alone is
		// valid hex too and must stay the digits elsewhere
		if (d.alphabet == 'ucs2' || hex_mode)
			text = sms_pdu.cbs_text(dcs, hexmod.hex_to_arr(str)).text;
	}

	return { m: +r[1], text: text, dcs: dcs };
};

const CUSD_M = [ 'no_action_required', 'action_required', 'terminated_by_network',
	'other_local_client', 'operation_not_supported', 'network_timeout' ];

function at_note(modem, line)
{
	let c = parse_cusd(line, at_hex(modem));

	if (!c)
		return;

	// m 0/1 with no text is still the answer: a request out takes it (an
	// empty reply), an idle session only learns whether a reply is wanted
	if (c.m == 0 || c.m == 1) {
		let s = sess(modem);

		if (c.text == null && !s.req) {
			s.state = (c.m == 1) ? 'user_response' : 'idle';
			return;
		}

		return deliver(modem, c.text, c.m == 1, 'at');
	}

	end_session(modem, CUSD_M[c.m] ?? 'at');
}

// the AT argument for `text`, or null when this modem cannot carry it
function at_arg(modem, text)
{
	if (at_hex(modem)) {
		let p = sms_pdu.gsm7_pack(text);

		return (p != null) ? uc(hexmod.arr_to_hex(p)) : null;   // upper case, as the ME906s took it
	}

	// the characters that would end or break the quoted argument, and
	// anything a +CSCS "IRA" modem cannot carry
	return (match(text, /["\r\n]/) || match(text, /[^\x20-\x7e]/)) ? null : text;
}

function at_send(modem, req, text)
{
	// the reply is the +CUSD URC, normally after OK — or, on a fast network,
	// before it (deliver parks it on req.note)
	modem.at.send(sprintf('AT+CUSD=1,"%s",15', req.at_arg), (err) => {
		if (err)
			return complete(modem, req, { error: 'at', detail: err }, null);

		after_ack(modem, req, 'at');
	});
}

// --- transport -----------------------------------------------------------------

// cb(be, voice?, err?) with be 'qmi' | 'mbim' | 'at' | null. Decided once per
// session (a re-init decides again). A modem that has Voice and failed to
// bring it up answers err — not the next transport.
function backend(modem, cb)
{
	let s = sess(modem);

	let rest = () => {
		if (modem.mbim_ussd?.offered?.())
			s.via = 'mbim';
		else if (modem.at)
			s.via = 'at';

		cb(s.via);
	};

	if (s.via != null && s.via != 'qmi')
		return cb(s.via);

	if (type(modem._ensure_voice) != 'function')
		return (s.via == 'qmi') ? cb(null) : rest();

	modem._ensure_voice((v, verr) => {
		if (verr)
			return cb(null, null, verr);

		if (!v)
			return (s.via == 'qmi') ? cb(null) : rest();

		s.via = 'qmi';
		cb('qmi', v);
	});
}

// --- public API ----------------------------------------------------------------

// the hook the MBIM notification and the AT URC call (modem_mbim / modem_common)
export function attach(modem)
{
	modem._ussd_note = (src, d) => {
		if (src == 'at')
			return at_note(modem, d);

		if (src == 'mbim') {
			let r = mbim_result(d);

			if (r.error)
				return end_session(modem, r.error);

			// textless is still the answer to a request out (as on AT); on
			// an idle session it only says whether a reply is wanted
			let s = sess(modem);

			if (r.text == null && !s.req) {
				s.state = r.req ? 'user_response' : 'idle';
				return;
			}

			deliver(modem, r.text, r.req, 'mbim');
		}
	};
};

// network-initiated USSD are noticed from here on: the hook for MBIM and AT,
// and on QMI the Voice client with its indications. Best-effort and quiet: a
// Voice allocation that fails now is tried again at the next registration.
export function arm(modem)
{
	attach(modem);

	if (type(modem._ensure_voice) == 'function')
		modem._ensure_voice((v) => { if (v) qmi_arm(modem, v); });
};

export function send(modem, text, cb)
{
	text = trim(sprintf('%s', text ?? ''));

	if (!length(text) || length(text) > 182)
		return cb({ error: 'invalid_argument', detail: 'a USSD string is 1-182 characters' }, null);

	let s = sess(modem);

	if (s.req)
		return cb({ error: 'busy', detail: 'a USSD request is still out' }, null);

	// the request exists from HERE, before the transport is even chosen:
	// choosing is asynchronous (a Voice allocation), and a second send
	// accepted in that gap would go out as well — possibly elsewhere
	let answering = (s.state == 'user_response');
	let req = { cb: cb, s: s, done: false, waiting: false, note: null, timer: null };

	s.req = req;
	s.state = 'active';
	attach(modem);

	backend(modem, (be, voice, verr) => {
		if (req.done)
			return;

		if (verr)
			return complete(modem, req, verr, null);

		if (be == 'qmi')
			return qmi_send(modem, voice, req, text, answering);
		if (be == 'mbim')
			return mbim_send(modem, req, text, answering);
		if (be == 'at') {
			req.at_arg = at_arg(modem, text);

			// refused before anything is sent: the question, if there was
			// one, still stands
			if (req.at_arg == null)
				return complete(modem, req, { error: 'unsupported_text',
					detail: at_hex(modem) ? 'not in the GSM 7-bit alphabet' : 'AT carries printable ASCII only' },
					null, answering ? 'user_response' : null);

			return at_send(modem, req, text);
		}

		complete(modem, req, { error: 'unsupported_on_backend' }, null);
	});
};

export function cancel(modem, cb)
{
	let done = (err) => {
		if (!err)
			end_session(modem, 'cancelled');
		cb(err, err ? null : { session: 'idle' });
	};

	backend(modem, (be, voice, verr) => {
		if (verr)
			return cb(verr, null);
		if (be == 'qmi')
			return voice.request('CANCEL_USSD', {}, (err) =>
				done(err ? { error: 'qmi', detail: err } : null), { no_recovery: true });
		if (be == 'mbim')
			return modem.mbim_ussd.set(2, 0, '', (err) => done(err ? { error: 'mbim', detail: err } : null));
		if (be == 'at')
			return modem.at.send('AT+CUSD=2', (err) => done(err ? { error: 'at', detail: err } : null));

		cb({ error: 'unsupported_on_backend' }, null);
	});
};

export function status(modem)
{
	if (!modem?._ussd)
		return null;

	let s = sess(modem);

	return { session: s.state, via: s.via, last: s.last };
};
