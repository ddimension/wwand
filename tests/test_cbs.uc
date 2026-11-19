// wwand tests — Cell Broadcast (cbs.uc) and the inbound SMS/CB path
// (sms_rx.uc): pages, joining, repeats, PWS names, channel lists, the AT URCs
// and the QMI WMS Event Report.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as cbs from 'wwand/cbs.uc';
import * as sms_rx from 'wwand/sms_rx.uc';
import * as sms_pdu from 'wwand/sms_pdu.uc';
import * as hexmod from 'wwand/codec/hex.uc';

// a GSM CBS page (TS 23.041 §9.4.1.2): serial, id, DCS 0x0F, page n/total,
// 93 GSM7 characters padded with CR into 82 octets
function gsm_page(id, serial, n, total, text)
{
	let t = text;

	while (length(t) < 93)
		t += '\r';

	let content = sms_pdu.gsm7_pack(t);

	while (length(content) < 82)
		push(content, 0x0d);

	return [ serial >> 8, serial & 0xff, id >> 8, id & 0xff, 0x0f, (n << 4) | total, ...slice(content, 0, 82) ];
}

// --- one page ----------------------------------------------------------------

{
	let p = cbs.page(gsm_page(4370, 0x1231, 1, 1, 'Warnung: Unwetter'));

	eq([ p.id, p.gs, p.code, p.update, p.page, p.pages ], [ 4370, 0, 0x123, 1, 1, 1 ],
	   'page: id and the serial number fields (10-bit message code)');
	eq(p.text, 'Warnung: Unwetter', 'page: text without the CR padding');
	eq(cbs.page([ 1, 2, 3 ]), null, 'page: junk is no page');
}

// UMTS format: type 1, id, serial, DCS, pages, then 82 octets + used length each
{
	let c = sms_pdu.gsm7_pack('Hallo');
	let used = length(c);

	while (length(c) < 82) push(c, 0);

	let p = cbs.page([ 1, 0x11, 0x12, 0x00, 0x10, 0x0f, 1, ...c, used ]);

	eq([ p?.id, p?.text, p?.format ], [ 4370, 'Hallo', 'umts' ], 'umts: one page by its used length');
}

// --- joining, repeats ---------------------------------------------------------------

{
	let st = cbs.create_store();

	eq(cbs.receive(st, gsm_page(4371, 0x2000, 2, 2, 'zweiter'), 1000), null, 'join: page 2 first waits');

	let m = cbs.receive(st, gsm_page(4371, 0x2000, 1, 2, 'erster '), 1001);

	eq(m?.text, 'erster zweiter', 'join: the pages in their order');
	eq([ m?.kind, m?.name ], [ 'cmas', 'extreme' ], 'join: an extreme alert');
	eq(cbs.receive(st, gsm_page(4371, 0x2000, 1, 2, 'erster '), 1300), null, 'repeat: the same serial again is no new message');
	eq(cbs.receive(st, gsm_page(4371, 0x2000, 2, 2, 'zweiter'), 1301), null, 'repeat: ...nor its second page');

	let upd = cbs.receive(st, gsm_page(4371, 0x2001, 1, 1, 'Entwarnung'), 1400);

	eq(upd?.text, 'Entwarnung', 'update: a new update number is a new message');
	eq(map(st.messages, (x) => x.text), [ 'Entwarnung', 'erster zweiter' ], 'store: newest first');

	ok(cbs.receive(st, gsm_page(4371, 0x2000, 1, 1, 'again'), 1301 + 86401) != null,
	   'repeat: a day later the serial is a broadcast reissued');
}

eq(cbs.pws(4352), { kind: 'etws', name: 'earthquake' }, 'pws: ETWS earthquake');
eq(cbs.pws(4370), { kind: 'cmas', name: 'presidential' }, 'pws: EU-Alert level 1');
eq(cbs.pws(4383), { kind: 'cmas', name: 'presidential', second_language: true }, 'pws: its language variant');
eq(cbs.pws(50), null, 'pws: an ordinary channel');

eq(cbs.parse_channels([ '4370-4399', '919', 'x', '5-1' ]), [ { start: 4370, end: 4399 }, { start: 919, end: 919 } ],
   'channels: ranges and ids, junk dropped');
eq(cbs.parse_channels('4352-4359 4370'), [ { start: 4352, end: 4359 }, { start: 4370, end: 4370 } ], 'channels: a string too');
eq(cbs.cscb_mids(cbs.DEFAULT_CHANNELS), '4352-4359,4370-4399', 'channels: as +CSCB mids');

// --- AT URCs -------------------------------------------------------------------

eq(sms_rx.parse_at('+CMTI: "SM",3'), { kind: 'stored', storage: 'SM', index: 3 }, 'at: +CMTI');
eq(sms_rx.parse_at('+CBM: 88\nAABB')?.kind, 'broadcast', 'at: +CBM with its PDU');
eq(sms_rx.parse_at('+CMT: "",24\n0791')?.kind, 'sms', 'at: +CMT with its PDU');
eq(sms_rx.parse_at('+CBM: 88'), null, 'at: a header without its PDU is nothing yet');

// --- QMI WMS Event Report ----------------------------------------------------------

function mkwms(handlers)
{
	let self;

	self = {
		_ind: {}, calls: [],
		on: (ev, cb) => { self._ind[ev] = cb; },
		request: (name, args, cb) => {
			push(self.calls, [ name, args ]);

			let h = handlers[name];

			if (type(h) == 'function')
				return h(args, cb);

			cb(h?.__err ?? null, h?.data ?? {});
		},
	};

	return self;
}

{
	let events = [];
	let w = mkwms({});
	let m = { wms: w, config: {}, _emit: (e, d) => push(events, [ e, d ]) };

	sms_rx.arm(m);
	eq(w.calls[0], [ 'SET_EVENT_REPORT', { new_mt: 1 } ], 'wms: new-message reports on');
	eq(length(filter(w.calls, (c) => index(c[0], 'BROADCAST') >= 0)), 0,
	   'wms: broadcast left alone while the config says nothing');

	let page = gsm_page(4370, 0x0011, 1, 1, 'Alarm');

	w._ind.EVENT_REPORT_IND({ transfer_route: { ack_indicator: 1, transaction_id: 7, format: 7, data: page } });
	eq(events[0]?.[0], 'cell_broadcast', 'wms: a broadcast page becomes the event');
	eq([ events[0]?.[1]?.text, events[0]?.[1]?.via ], [ 'Alarm', 'qmi' ], 'wms: ...decoded');
	eq(length(filter(w.calls, (c) => c[0] == 'SEND_ACK')), 0, 'wms: no ack the modem did not ask for');

	// an SMS routed for transfer, ack requested: acknowledged, and reported
	let pdu = '000402912100002010100000000002e834';   // gsm7 "hi" (test_mbim_backend)

	w._ind.EVENT_REPORT_IND({ transfer_route: { ack_indicator: 0, transaction_id: 9, format: 6,
		data: hexmod.hex_to_arr(pdu) } });
	eq(filter(w.calls, (c) => c[0] == 'SEND_ACK')[0]?.[1], { info: { transaction_id: 9, protocol: 1, success: 1 } },
	   'wms: a transferred SMS is acknowledged when asked');
	eq([ events[1]?.[0], events[1]?.[1]?.text ], [ 'sms', 'hi' ], 'wms: ...and reported');

	// the network sends it again under the same id (an ack that got lost):
	// acknowledged again, reported once
	w._ind.EVENT_REPORT_IND({ transfer_route: { ack_indicator: 0, transaction_id: 9, format: 6,
		data: hexmod.hex_to_arr(pdu) } });
	eq(length(filter(w.calls, (c) => c[0] == 'SEND_ACK')), 2, 'wms resend: acknowledged again');
	eq(length(events), 2, 'wms resend: not reported twice');

	// one that does not decode is still reported, with its PDU
	w._ind.EVENT_REPORT_IND({ transfer_route: { ack_indicator: 0, transaction_id: 10, format: 6, data: [ 0xff ] } });
	eq([ events[2]?.[0], events[2]?.[1]?.pdu ], [ 'sms', 'ff' ], 'wms junk: reported raw, not lost');
}

// switched on from the config, read before written
{
	let w = mkwms({ GET_BROADCAST_CONFIG: { data: { config: { activated: 1,
		channels: [ { start: 4352, end: 4359, selected: 1 }, { start: 4370, end: 4399, selected: 1 } ] } } } });

	sms_rx.arm({ wms: w, config: { cell_broadcast: '1' } });
	eq(map(w.calls, (c) => c[0]), [ 'SET_EVENT_REPORT', 'GET_BROADCAST_CONFIG' ],
	   'broadcast: already as configured — nothing written');

	let w2 = mkwms({ GET_BROADCAST_CONFIG: { data: { config: { activated: 0, channels: [] } } } });

	sms_rx.arm({ wms: w2, config: { cell_broadcast: '1', cb_channels: [ '4370-4382' ] } });
	eq(map(w2.calls, (c) => c[0]), [ 'SET_EVENT_REPORT', 'GET_BROADCAST_CONFIG', 'SET_BROADCAST_CONFIG', 'SET_BROADCAST_ACTIVATION' ],
	   'broadcast: off -> channel list, then on');
	eq(w2.calls[2][1].channels, [ { start: 4370, end: 4382, selected: 1 } ], 'broadcast: the configured channels');

	let w3 = mkwms({ GET_BROADCAST_CONFIG: { data: { config: { activated: 1, channels: [] } } } });

	sms_rx.arm({ wms: w3, config: { cell_broadcast: '0' } });
	eq(w3.calls[2], [ 'SET_BROADCAST_ACTIVATION', { activation: { mode: 1, activate: 0 } } ], 'broadcast: off when the config says 0');
}

done('test_cbs');
