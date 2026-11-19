// wwand tests — USSD (ussd.uc) over QMI Voice, native MBIM and AT, and the
// GSM text helpers it shares with Cell Broadcast (sms_pdu.uc).

'use strict';

import * as uloop from 'uloop';
import { eq, ok, done } from './lib/check.uc';
import * as ussd from 'wwand/ussd.uc';
import * as sms_pdu from 'wwand/sms_pdu.uc';
import * as mbim_backend from 'wwand/mbim_backend.uc';
import * as hexmod from 'wwand/codec/hex.uc';

uloop.init();

let scenarios = [], idx = 0;

function scenario(name, fn) { push(scenarios, { name: name, fn: fn }); }

function run_next()
{
	if (idx >= length(scenarios))
		return uloop.end();

	let s = scenarios[idx++];

	s.fn(() => uloop.timer(1, run_next));
}

const QMI_WAIT = 450;   // past ussd.uc QMI_SETTLE_MS

function str_of(arr) { let s = ''; for (let o in arr) s += chr(o); return s; }

// --- GSM text ----------------------------------------------------------------

// the network's answer to *#100# on the ME906s, packed GSM7 (the digits are
// replaced: the real ones are a subscriber's number)
eq(sms_pdu.gsm7_unpack(sms_pdu.gsm7_pack('491701234567')), '491701234567', 'gsm7: round trip');
eq(uc(hexmod.arr_to_hex(sms_pdu.gsm7_pack('*#100#'))), 'AA510C061B01', 'gsm7: *#100# packs as the ME906s took it');

// 7 characters leave 7 spare bits: CR fills them, and the decoder drops it
let seven = sms_pdu.gsm7_pack('1234567');
eq(length(seven), 7, 'gsm7 pad: seven characters fill seven octets');
eq(seven[6] >> 1, 0x0d, 'gsm7 pad: the spare bits hold CR, not @');
eq(sms_pdu.gsm7_unpack(seven), '1234567', 'gsm7 pad: the CR is not part of the text');
eq(sms_pdu.gsm7_pack('中文'), null, 'gsm7: CJK is outside the alphabet');
eq(sms_pdu.gsm7_unpack(sms_pdu.gsm7_pack('Grüße')), 'Grüße', 'gsm7: ß is in it (0x1E)');
eq(sms_pdu.gsm7_unpack(sms_pdu.gsm7_pack('Grüne Äpfel')), 'Grüne Äpfel', 'gsm7: umlauts of the default alphabet');
eq(sms_pdu.ucs2_decode(sms_pdu.ucs2_encode('Grüße €')), 'Grüße €', 'ucs2: round trip');
eq(sms_pdu.utf16_units_text([ 0x48, 0x69, 0xd83d, 0xde00 ]), 'Hi😀', 'utf16: a surrogate pair joins');

eq(sms_pdu.cbs_dcs(0x0f).alphabet, 'gsm7', 'cbs dcs: 0x0F is GSM7');
eq(sms_pdu.cbs_dcs(0x48).alphabet, 'ucs2', 'cbs dcs: 0x48 is UCS2');
eq(sms_pdu.cbs_dcs(0x01).language, 'en', 'cbs dcs: group 0 names the language');
eq(sms_pdu.cbs_dcs(0x44).alphabet, '8bit', 'cbs dcs: 0x44 is 8-bit');

// --- AT +CUSD parsing ----------------------------------------------------------

eq(ussd.parse_cusd('+CUSD: 0,"Ihr Guthaben: 5,00 EUR",15', false),
   { m: 0, text: 'Ihr Guthaben: 5,00 EUR', dcs: 15 }, 'cusd: plain text');
eq(ussd.parse_cusd('+CUSD: 0,"389C6C968BC560B4598E46C3DD1A",15', true).text, '882391104394487',
   'cusd: Huawei packed GSM7 hex (HW-seen on the ME906s)');
eq(ussd.parse_cusd('+CUSD: 0,"491701234567",15', false).text, '491701234567',
   'cusd: digits stay digits on a modem that answers in text');
eq(ussd.parse_cusd('+CUSD: 1,"00480069",72', false).text, 'Hi', 'cusd: UCS2 hex under DCS 72');
eq(ussd.parse_cusd('+CUSD: 2', false).m, 2, 'cusd: terminated by the network, no text');

// --- MBIM wire -------------------------------------------------------------------

{
	let set = mbim_backend.ussd_encode_set(0, 0x0f, str_of(sms_pdu.gsm7_pack('*#100#')));

	eq(uc(hexmod.bin_to_hex(set)), '000000000F0000001000000006000000AA510C061B010000',
	   'mbim set: the layout the ME906s answered');

	let resp = hexmod.hex_to_bin('00000000010000000f000000140000000e000000389c6c968bc560b4598e46c3dd1a0000');
	let d = mbim_backend.ussd_decode(resp);

	eq([ d.response_name, d.session_state, d.dcs, length(d.payload) ], [ 'no_action_required', 1, 15, 14 ],
	   'mbim response: decoded as the ME906s sent it');
}

// --- QMI Voice -------------------------------------------------------------------

function mkvoice(handlers)
{
	let self;

	self = {
		_ind: {}, calls: [],
		on: (ev, cb) => { self._ind[ev] = cb; },
		request: (name, args, cb, opts) => {
			push(self.calls, [ name, args ]);

			let h = handlers[name];

			if (type(h) == 'function')
				return h(args, cb);

			cb(h?.__err ?? null, h?.data ?? {});
		},
	};

	return self;
}

scenario('qmi: originate answers with the network\'s text', (next) => {
	let v = mkvoice({ ORIGINATE_USSD: { data: { uss: { dcs: 1, data: [ 0x4f, 0x4b ] } } } });
	let m = { _ensure_voice: (cb) => cb(v) };

	ussd.send(m, '*100#', (err, res) => {
		eq(err, null, 'qmi originate: done');
		eq([ res.reply, res.action_required, res.session, res.via ], [ 'OK', false, 'idle', 'qmi' ],
		   'qmi originate: the reply, no question');
		eq(v.calls[0][0], 'INDICATION_REGISTER', 'qmi originate: USSD indications registered first');
		eq(v.calls[1][1].uss, { dcs: 1, data: [ 0x2a, 0x31, 0x30, 0x30, 0x23 ] }, 'qmi originate: ASCII as QMI wants it');
		next();
	});
});

// the indication that says "the network wants a reply" can come before the
// answer: it must decide the session, and must not be reported as a message
// of the network's own
scenario('qmi: the indication before the answer sets the question', (next) => {
	let emitted = [];
	let v;

	v = mkvoice({
		ORIGINATE_USSD: (args, cb) => {
			v._ind.USSD_IND({ user_action: 2, uss: { dcs: 1, data: [ 0x31, 0x3d, 0x41 ] } });
			cb(null, { uss: { dcs: 1, data: [ 0x31, 0x3d, 0x41 ] } });
		},
		ANSWER_USSD: (args, cb) => {
			cb(null, {});
			uloop.timer(5, () => v._ind.USSD_IND({ user_action: 1, utf16: [ 0x44, 0x6f, 0x6e, 0x65 ] }));
		},
	});

	let m = { _ensure_voice: (cb) => cb(v), _emit: (e, d) => push(emitted, e) };

	ussd.send(m, '*101#', (err, res) => {
		eq([ res?.reply, res?.action_required, res?.session ], [ '1=A', true, 'user_response' ],
		   'qmi question: asked');
		eq(emitted, [], 'qmi question: no network message emitted for it');

		ussd.send(m, '1', (err2, res2) => {
			eq(v.calls[length(v.calls) - 1][0], 'ANSWER_USSD', 'qmi question: the next send answers it');
			eq([ res2?.reply, res2?.session ], [ 'Done', 'idle' ], 'qmi question: the reply came as an indication');
			next();
		});
	});
});

scenario('qmi: a network-initiated USSD is emitted; a release ends a wait', (next) => {
	let emitted = [];
	let v = mkvoice({ ANSWER_USSD: {} });
	let m = { _ensure_voice: (cb) => cb(v), _emit: (e, d) => push(emitted, [ e, d ]) };

	ussd.arm(m);
	v._ind.USSD_IND({ user_action: 2, uss: { dcs: 3, data: [ 0x00, 0x3f ] } });
	eq(emitted[0], [ 'ussd', { text: '?', action_required: true, origin: 'network', via: 'qmi' } ],
	   'qmi network: emitted');
	eq(ussd.status(m).session, 'user_response', 'qmi network: the session waits for an answer');

	ussd.send(m, 'x', (err) => {
		eq(err?.error, 'terminated_by_network', 'qmi release: the waiting answer ends');
		eq(ussd.status(m).session, 'idle', 'qmi release: idle again');
		next();
	});
	uloop.timer(5, () => v._ind.RELEASE_USSD_IND({}));
});

// a code the network may have seen goes out once: a failed QMI originate is
// the result, not a reason to try AT
scenario('qmi: a failure never falls back to another transport', (next) => {
	let at = [];
	let v = mkvoice({ ORIGINATE_USSD: { __err: { error: 'qmi', code: 3 }, data: {} } });
	let m = { _ensure_voice: (cb) => cb(v), at: { send: (c, cb) => { push(at, c); cb(null, {}); } } };

	ussd.send(m, '*100#', (err) => {
		eq(err?.error, 'qmi', 'qmi failure: reported');
		eq(at, [], 'qmi failure: AT never sends the code again');
		next();
	});
});

// --- native MBIM ---------------------------------------------------------------

scenario('mbim: initiate, a question, continue', (next) => {
	let sets = [];
	let answers = [
		{ response: 1, response_name: 'action_required', dcs: 15, payload: str_of(sms_pdu.gsm7_pack('1=Saldo')) },
		{ response: 0, response_name: 'no_action_required', dcs: 15, payload: str_of(sms_pdu.gsm7_pack('5 EUR')) },
	];
	let m = { mbim_ussd: { offered: () => true,
		set: (a, dcs, p, cb) => { push(sets, [ a, dcs ]); cb(null, shift(answers)); } } };

	ussd.send(m, '*100#', (err, res) => {
		eq([ res?.reply, res?.action_required, res?.via ], [ '1=Saldo', true, 'mbim' ], 'mbim: the question');

		ussd.send(m, '1', (err2, res2) => {
			eq(sets, [ [ 0, 15 ], [ 1, 15 ] ], 'mbim: INITIATE, then CONTINUE, both GSM7');
			eq([ res2?.reply, res2?.session ], [ '5 EUR', 'idle' ], 'mbim: the final answer');
			next();
		});
	});
});

scenario('mbim: not supported by the network is an error', (next) => {
	let m = { mbim_ussd: { offered: () => true,
		set: (a, dcs, p, cb) => cb(null, { response: 4, response_name: 'operation_not_supported', dcs: 0, payload: '' }) } };

	ussd.send(m, '*100#', (err) => {
		eq(err?.error, 'operation_not_supported', 'mbim refused: named');
		eq(ussd.status(m).session, 'idle', 'mbim refused: idle');
		next();
	});
});

// --- AT --------------------------------------------------------------------------

scenario('at: the reply is the +CUSD URC after OK; Huawei in hex', (next) => {
	let sent = [];
	let m = { info: { manufacturer: 'Huawei Technologies Co., Ltd.' },
		at: { send: (c, cb) => { push(sent, c); cb(null, {}); } } };

	ussd.send(m, '*#100#', (err, res) => {
		eq(sent[0], 'AT+CUSD=1,"AA510C061B01",15', 'at huawei: the code as packed GSM7 hex');
		eq([ res?.reply, res?.via ], [ '882391104394487', 'at' ], 'at huawei: the URC answers it');
		next();
	});

	uloop.timer(5, () => m._ussd_note('at', '+CUSD: 0,"389C6C968BC560B4598E46C3DD1A",15'));
});

scenario('at: text elsewhere, and a quote never reaches the command', (next) => {
	let sent = [];
	let m = { info: { manufacturer: 'Quectel' }, at: { send: (c, cb) => { push(sent, c); cb(null, {}); } } };

	ussd.send(m, '*1"#', (err) => {
		eq(err?.error, 'unsupported_text', 'at: a quote is refused');

		ussd.send(m, '*100#', (err2, res) => {
			eq(sent, [ 'AT+CUSD=1,"*100#",15' ], 'at: the code as text');
			eq(res?.reply, 'Guthaben 1 EUR', 'at: the reply');
			next();
		});
		uloop.timer(5, () => m._ussd_note('at', '+CUSD: 0,"Guthaben 1 EUR",15'));
	});
});

scenario('at: busy while a request is out', (next) => {
	let m = { at: { send: (c, cb) => cb(null, {}) } };

	ussd.send(m, '*100#', () => null);
	ussd.send(m, '*101#', (err) => {
		eq(err?.error, 'busy', 'busy: a second request is refused');
		m._ussd_note('at', '+CUSD: 2');
		eq(ussd.status(m).session, 'idle', 'busy: a termination frees it');
		next();
	});
});

// busy from the first call on: the Voice allocation is asynchronous, and a
// second send accepted meanwhile went out too — over AT
scenario('busy while the transport is still being chosen', (next) => {
	let at = [], waiting = [];
	let v = mkvoice({ ORIGINATE_USSD: { data: { uss: { dcs: 1, data: [ 0x4f, 0x4b ] } } } });
	let m = { _ensure_voice: (cb) => push(waiting, cb), at: { send: (c, cb) => { push(at, c); cb(null, {}); } } };

	ussd.send(m, '*100#', (err, res) => {
		eq(res?.via, 'qmi', 'choosing: the first send goes over QMI');
		eq(at, [], 'choosing: nothing over AT');
		next();
	});
	ussd.send(m, '*100#', (err) => eq(err?.error, 'busy', 'choosing: the second is refused at once'));
	waiting[0](v);
});

scenario('a Voice that fails to come up is an error, not AT', (next) => {
	let at = [];
	let m = { _ensure_voice: (cb) => cb(null, { error: 'voice_unavailable' }),
		at: { send: (c, cb) => { push(at, c); cb(null, {}); } } };

	ussd.send(m, '*100#', (err) => {
		eq(err?.error, 'voice_unavailable', 'voice down: reported');
		eq(at, [], 'voice down: AT does not send the code');
		eq(ussd.status(m).session, 'idle', 'voice down: idle');
		next();
	});
});

scenario('a re-init ends the session and its wait', (next) => {
	let m = { _gen: 1, at: { send: (c, cb) => cb(null, {}) } };

	ussd.send(m, '*100#', (err) => {
		eq(err?.error, 'reinitialised', 're-init: the wait ends');
		eq(ussd.status(m).session, 'idle', 're-init: a fresh session');
		next();
	});

	uloop.timer(5, () => { m._gen = 2; m.at = { send: (c, cb) => cb(null, {}) }; ussd.status(m); });
});

// the answer can come as a notification/URC before the request's own
// acknowledgement: it is the reply, not a message of the network's own
scenario('a reply ahead of its acknowledgement', (next) => {
	let emitted = [];
	let m;

	m = { _emit: (e) => push(emitted, e),
		mbim_ussd: { offered: () => true, set: (a, dcs, p, cb) => {
			m._ussd_note('mbim', { response_name: 'no_action_required', dcs: 15,
				payload: str_of(sms_pdu.gsm7_pack('early')) });
			cb(null, { response_name: 'no_action_required', dcs: 15, payload: '' });
		} } };

	ussd.send(m, '*100#', (err, res) => {
		eq(res?.reply, 'early', 'early mbim: the notification is the reply');
		eq(emitted, [], 'early mbim: not emitted as network-initiated');

		// and the same text once more right after, as an echo
		m._ussd_note('mbim', { response_name: 'no_action_required', dcs: 15,
			payload: str_of(sms_pdu.gsm7_pack('early')) });
		eq(emitted, [], 'echo mbim: the repeat is no new message');
		next();
	});
});

scenario('at: the URC before OK', (next) => {
	let m;

	m = { info: { manufacturer: 'Quectel' }, at: { send: (c, cb) => {
		m._ussd_note('at', '+CUSD: 0,"fast",15');
		cb(null, {});
	} } };

	ussd.send(m, '*100#', (err, res) => {
		eq(res?.reply, 'fast', 'at early: the URC answers it');
		next();
	});
});

// a release before the acknowledgement ends the request too, and the
// acknowledgement that comes later answers nobody
scenario('a release ends a request still waiting for its acknowledgement', (next) => {
	let held = null, calls = 0;
	let v = mkvoice({ ORIGINATE_USSD: (args, cb) => { held = cb; } });
	let m = { _ensure_voice: (cb) => cb(v) };

	ussd.send(m, '*100#', (err) => {
		calls++;
		eq(err?.error, 'terminated_by_network', 'release early: the send ends with it');
		held(null, { uss: { dcs: 1, data: [ 0x4f, 0x4b ] } });
		uloop.timer(QMI_WAIT, () => {
			eq(calls, 1, 'release early: the late acknowledgement answers nobody');
			eq(ussd.status(m).session, 'idle', 'release early: idle');
			next();
		});
	});
	v._ind.RELEASE_USSD_IND({});
});

// the Originate answer without text, the text in the indication during the
// settle: that is the reply
scenario('qmi: the reply in an indication during the settle', (next) => {
	let v;

	v = mkvoice({ ORIGINATE_USSD: (args, cb) => {
		cb(null, {});
		uloop.timer(50, () => v._ind.USSD_IND({ user_action: 2, uss: { dcs: 1, data: [ 0x3f ] } }));
	} });

	let m = { _ensure_voice: (cb) => cb(v) };

	ussd.send(m, '*100#', (err, res) => {
		eq([ res?.reply, res?.action_required, res?.session ], [ '?', true, 'user_response' ],
		   'settle: the indication\'s text and question');
		next();
	});
});

// a callback from before a re-init must not finish the new session's request
scenario('a stale acknowledgement does not touch the new session', (next) => {
	let held = null, sent = 0;
	let m = { _gen: 1, at: { send: (c, cb) => { sent++; if (sent == 1) held = cb; else cb(null, {}); } } };

	ussd.send(m, '*100#', (err) => eq(err?.error, 'reinitialised', 'stale: the old request is reinitialised'));
	m._gen = 2;
	m.at = { send: (c, cb) => cb(null, {}) };

	ussd.send(m, '*101#', (err, res) => {
		eq(res?.reply, 'new', 'stale: the new request gets its own answer');
		next();
	});

	held(null, {});   // the old channel's OK, late
	eq(ussd.status(m).session, 'active', 'stale: the new request is still out');
	m._ussd_note('at', '+CUSD: 0,"new",15');
});

scenario('qmi: a UCS2 string longer than QMI can count is refused', (next) => {
	let v = mkvoice({});
	let m = { _ensure_voice: (cb) => cb(v) };
	let t = '';

	for (let i = 0; i < 130; i++) t += 'a';

	ussd.send(m, t + 'é', (err) => {
		eq(err?.error, 'too_long', 'qmi length: refused, not thrown');
		eq(length(filter(v.calls, (c) => c[0] == 'ORIGINATE_USSD')), 0, 'qmi length: nothing sent');
		next();
	});
});

// refused before sending, the question still stands — already when the
// caller hears it, which may send the answer at once
scenario('at: a refused answer leaves the question open for the next', (next) => {
	let sent = [];
	let m = { info: { manufacturer: 'Quectel' }, at: { send: (c, cb) => { push(sent, c); cb(null, {}); } } };

	ussd.arm(m);
	m._ussd_note('at', '+CUSD: 1,"1=A 2=B",15');
	ussd.send(m, 'ä', (err) => {
		eq([ err?.error, ussd.status(m).session ], [ 'unsupported_text', 'user_response' ],
		   'at refused: the question still stands in the callback');
		next();
	});
});

uloop.timer(1, run_next);
uloop.run();

done('test_ussd');
