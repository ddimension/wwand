// wwand tests — protocol switching recipes.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as ps from 'wwand/protocol_switch.uc';

uloop.init();

// fake AT engine: scripted responses keyed by command prefix
function fake_at(responses)
{
	let self = { sent: [] };

	self.send = function(cmd, cb, opts) {
		push(self.sent, cmd);

		let lines = [];

		for (let prefix, resp in responses)
			if (substr(cmd, 0, length(prefix)) == prefix)
				lines = resp;

		uloop.timer(1, () => cb(lines === false ? { error: 'link' } : null, { lines: lines }));
	};

	return self;
}

function fake_modem(model, responses)
{
	return {
		info: { model: model },
		log_fn: (l, m) => null,
		at: fake_at(responses),
	};
}

// --- supported detection -----------------------------------------------------

eq(ps.supported('RG650E-EU'), true, 'supported: Quectel RG650E');
eq(ps.supported('EG06-E'), true, 'supported: Quectel EG06');
eq(ps.supported('SomeRandomModem'), false, 'supported: unknown model');

// --- switch QMI -> MBIM ------------------------------------------------------

let results = [];
let m = fake_modem('RG650E-EU', {
	'AT+QCFG="usbnet"': [ '+QCFG: "usbnet",0' ],   // currently QMI
	'AT+CFUN': [ 'OK' ],
});

ps.switch_protocol(m, 'mbim', (err, res) => push(results, { err: err, res: res }));

uloop.timer(20, () => uloop.end());
uloop.run();

eq(length(results), 1, 'switch: completed');
eq(results[0].err, null, 'switch: no error');
eq(results[0].res.changed, true, 'switch: changed');
eq(results[0].res.resetting, true, 'switch: resetting');
ok(index(m.at.sent, 'AT+QCFG="usbnet",2') >= 0, 'switch: set mbim value 2');
ok(index(m.at.sent, 'AT+CFUN=1,1') >= 0, 'switch: reset issued');

// --- already in target mode -> no change/reset -------------------------------

uloop.init();
results = [];
m = fake_modem('RG650E-EU', { 'AT+QCFG="usbnet"': [ '+QCFG: "usbnet",2' ] });  // already MBIM
ps.switch_protocol(m, 'mbim', (err, res) => push(results, { err: err, res: res }));

uloop.timer(20, () => uloop.end());
uloop.run();

eq(results[0].res.changed, false, 'noop: no change when already in target');
eq(results[0].res.resetting, false, 'noop: no reset');
eq(index(m.at.sent, 'AT+QCFG="usbnet",2'), -1, 'noop: set not issued');

// --- errors ------------------------------------------------------------------

uloop.init();
results = [];
ps.switch_protocol(fake_modem('RG650E-EU', {}), 'ecm',
	(err) => push(results, err));
eq(results[0].error, 'invalid_target', 'error: invalid target');

results = [];
ps.switch_protocol(fake_modem('NokiaX', {}), 'mbim',
	(err) => push(results, err));
eq(results[0].error, 'unsupported_model', 'error: unsupported model');

results = [];
ps.switch_protocol({ info: { model: 'RG650E' }, log_fn: (l,m)=>null }, 'mbim',
	(err) => push(results, err));
eq(results[0].error, 'no_at_port', 'error: no AT port');

done('test_protoswitch');
