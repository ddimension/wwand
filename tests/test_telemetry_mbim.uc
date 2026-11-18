// wwand tests — the MBIM telemetry's AT cells rung (telemetry_mbim.uc).
//
// An MBIM modem with neither the QMI passthrough nor MBIMEx Base Stations Info
// reads its serving cell over AT, and that read is vendor AT. Sent the Quectel
// AT+QENG, a Huawei ME906s answers ERROR; the AT rung, probed by "a port
// exists", was then demoted on every read and picked again by the next probe,
// and the log said "re-probing the ladder" every 2-3 s (2026-11-18).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as telemetry_mbim from 'wwand/telemetry_mbim.uc';

// a modem `self` with an AT side channel that records what it is asked and
// answers from `answers` (command -> lines, or 'ERROR')
function mk(manufacturer, answers) {
	let asked = [];
	let logs = [];
	let at = {
		send: (cmd, cb) => {
			push(asked, cmd);
			let a = answers[cmd] ?? 'ERROR';
			(a == 'ERROR') ? cb({ error: 'ERROR' }, null) : cb(null, { lines: a });
		},
	};
	let self = {
		info: { manufacturer: manufacturer },
		at: at, at_telemetry: at,
		mbim: null,
		_ensure_pt: (cb) => cb(false),
	};

	telemetry_mbim.install(self, {
		log: (lvl, msg) => push(logs, msg),
		emit: () => null,
	});

	return { self: self, asked: asked, logs: logs };
}

let reprobes = (logs) => length(filter(logs, (l) => index(l, 're-probing') >= 0));

// Huawei on LTE: ^MONSC, a serving cell, and a rung that stays chosen
let monsc_lte = [ '^MONSC: LTE,262,02,1300,2E1A00,42,20B,-95,-11,-65', 'OK' ];
let h = mk('Huawei Technologies Co., Ltd.', { 'AT^MONSC': monsc_lte });

for (let i = 0; i < 6; i++)
	h.self._refresh_cells();

eq(length(filter(h.asked, (c) => index(c, 'QENG') >= 0)), 0, 'cells at: a Huawei is never asked the Quectel QENG');
ok(length(filter(h.asked, (c) => c == 'AT^MONSC')) >= 6, 'cells at: ...it is asked ^MONSC');
eq(h.self._cells_be, 'at', 'cells at: the AT rung is chosen');
eq(reprobes(h.logs), 0, 'cells at: and it is not demoted, read after read');
eq(h.self.cells?.serving?.lte?.pci, 42, 'cells at: the serving cell is read');

// Huawei on GSM: ^MONSC names a GSM cell, which is an answer without an LTE cell
let g = mk('Huawei Technologies Co., Ltd.', { 'AT^MONSC': [ '^MONSC: GSM,262,02,1,5,27,2E1A,20B,-91,,', 'OK' ] });

for (let i = 0; i < 6; i++)
	g.self._refresh_cells();

eq(reprobes(g.logs), 0, 'cells at: a GSM answer is an answer, not a dead transport');

// ...and it ends the LTE cell read before it: the modem left LTE
let lg = mk('Huawei Technologies Co., Ltd.', { 'AT^MONSC': monsc_lte });
lg.self._refresh_cells();
eq(lg.self.cells?.serving?.lte?.pci, 42, 'cells at: on LTE first');
lg.self.at_telemetry.send = (cmd, cb) => cb(null, { lines: [ '^MONSC: GSM,262,02,1,5,27,2E1A,20B,-91,,', 'OK' ] });
lg.self._refresh_cells();
eq(lg.self.cells, null, 'cells at: a GSM answer clears the stale LTE cell');

// an empty OK says nothing and keeps the last reading
let le = mk('Huawei Technologies Co., Ltd.', { 'AT^MONSC': monsc_lte });
le.self._refresh_cells();
le.self.at_telemetry.send = (cmd, cb) => cb(null, { lines: [ 'OK' ] });
le.self._refresh_cells();
eq(le.self.cells?.serving?.lte?.pci, 42, 'cells at: an empty answer keeps the last cell');

// Quectel keeps QENG
let q = mk('Quectel', { 'AT+QENG="servingcell"': [
	'+QENG: "servingcell","NOCONN","LTE","FDD",262,01,2E1A00,42,1300,3,5,5,20B,-95,-11,-65,10,-', 'OK' ] });
q.self._refresh_cells();
ok(length(filter(q.asked, (c) => c == 'AT+QENG="servingcell"')) >= 1, 'cells at: a Quectel is asked QENG');

// a named vendor with no known read: no AT rung, and nothing sent after the walk
let f = mk('Foxconn', {});

for (let i = 0; i < 6; i++)
	f.self._refresh_cells();

eq(length(f.asked), 0, 'cells at: a vendor with no known serving-cell read is asked nothing');
eq(f.self._cells_be == 'at', false, 'cells at: ...and gets no AT rung');

done('test_telemetry_mbim');
