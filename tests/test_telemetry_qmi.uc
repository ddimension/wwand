// wwand tests — the QMI slow telemetry tick (telemetry_qmi.uc).
// Focus: a cell-location query the modem stopped answering. The tick backs
// off instead of warning every round, keeps doing the rest of its work, and
// returns to every round on the first answer (ddimension/wwand#72).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as tq from 'wwand/telemetry_qmi.uc';

uloop.init();

// the helper's own sequence: two plain warnings, one backoff warning, then
// quiet doubling up to the cap; an answer resets it with one info line
{
	let st = { timeouts: 0, skip: 0 };
	let to = { error: 'timeout' };
	let lv = [], skips = [];

	for (let i = 0; i < 8; i++) {
		let l = tq.cell_query_backoff(st, to);
		push(lv, l[0]);
		push(skips, st.skip);
	}

	eq(lv, [ 'warn', 'warn', 'warn', 'debug', 'debug', 'debug', 'debug', 'debug' ],
		'backoff: warns until it backs off, then only debug');
	eq(skips, [ 0, 0, 1, 2, 4, 8, 15, 15 ], 'backoff: doubles up to the cap');

	let l = tq.cell_query_backoff(st, null);
	eq(l?.[0], 'info', 'backoff: the first answer is logged once');
	eq([ st.timeouts, st.skip ], [ 0, 0 ], 'backoff: ...and resets it');
	eq(tq.cell_query_backoff(st, null), null, 'backoff: a normal answer logs nothing');

	// a rejection is a different fault: warned each time, never backed off,
	// and it ends a timeout streak — "in a row" means in a row
	let q = { error: 'qmi', result: 1, code: 71 };
	for (let i = 0; i < 4; i++)
		l = tq.cell_query_backoff(st, q);
	eq([ l[0], st.timeouts, st.skip ], [ 'warn', 0, 0 ], 'backoff: a qmi error does not count');

	for (let e in [ to, to, q, to ])
		l = tq.cell_query_backoff(st, e);
	eq([ l[0], st.timeouts, st.skip ], [ 'warn', 1, 0 ], 'backoff: a qmi error ends the streak');

	// hours of silence: the skip stays at the cap, never wraps
	for (let i = 0; i < 200; i++)
		tq.cell_query_backoff(st, to);
	eq(st.skip, 15, 'backoff: capped after 200 timeouts');
}

// the tick itself. A round is counted by the AT+CSQ floor read it makes on
// every round (self.signal is empty), so the count needs no timing: a modem
// that times out every query is asked on rounds 1, 2, 3, then 5 (one sat
// out), 8 (two) and 13 (four). It answers from round 9 on, but is not asked
// until 13 — from then on it is asked every round again.
// The rest of the round runs on the skipped ones too.
{
	let asked = [], logs = [], telemetry = [], csq = 0;

	let at;
	at = { send: (cmd, cb) => {
		if (cmd == 'AT+CSQ' && ++csq == 15)
			uloop.end();
		cb(null, { lines: [ '+CSQ: 20,99', 'OK' ] });
	} };

	let self = {
		config: { stats_interval: 0.001 },
		at: at, at_telemetry: at,
		_temp_unavail: true,
		nas: {
			request: (name, args, cb) => {
				let round = csq + 1;
				push(asked, round);
				if (round >= 9)
					cb(null, {});
				else
					cb({ error: 'timeout' }, null);
				return true;
			},
		},
	};

	let t = tq.install(self, {
		log: (lvl, msg) => push(logs, [ csq + 1, lvl ]),
		emit: () => null,
	});

	self._log_telemetry = () => push(telemetry, csq);
	self._start_telemetry();
	uloop.run();
	t.stop();

	eq(asked, [ 1, 2, 3, 5, 8, 13, 14, 15 ], 'tick: backs off, then asks every round again');
	eq(logs, [ [ 1, 'warn' ], [ 2, 'warn' ], [ 3, 'warn' ], [ 5, 'debug' ], [ 8, 'debug' ], [ 13, 'info' ] ],
		'tick: three warnings, then quiet, one line on recovery');
	eq(telemetry, [ 13, 14, 15 ], 'tick: a telemetry line only for rounds with an answer');
}

done('test_telemetry_qmi');
