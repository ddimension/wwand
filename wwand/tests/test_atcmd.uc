// wwand tests — AT engine and AT port discovery.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as fakefx from './lib/fakefx.uc';
import * as atcmd from 'wwand/atcmd.uc';

uloop.init();

const silent = (level, msg) => null;

// --- fake transport ----------------------------------------------------------

function fake_transport()
{
	let self = {
		written: [],
		data_cb: null,
		drained: 0,
		closed: false,
	};

	self.write = (data) => { push(self.written, data); return length(data); };
	self.on_data = (cb) => { self.data_cb = cb; };
	self.drain = () => self.drained++;
	self.close = () => { self.closed = true; };
	self.reply = (text) => self.data_cb(text);

	return self;
}

// --- engine: success with echo -----------------------------------------------

let tr = fake_transport();
let at = atcmd.create(tr, { log: silent });

let got = null;

at.send('ATI', (err, res) => { got = { err: err, res: res }; });

eq(tr.written, [ "ATI\r" ], 'engine: command written with CR');

tr.reply("ATI\r\nQuectel\r\nRG502Q-EA\r\nRevision: R11\r\n\r\nOK\r\n");

eq(got.err, null, 'engine: success');
eq(got.res.lines, [ 'Quectel', 'RG502Q-EA', 'Revision: R11' ], 'engine: echo and blanks filtered');

// --- engine: chunked input ---------------------------------------------------

got = null;
at.send('AT+X', (err, res) => { got = { err: err, res: res }; });
tr.reply("AT+X\r\nva");
tr.reply("lue\r\nO");
tr.reply("K\r\n");

eq(got.err, null, 'engine: chunked ok');
eq(got.res.lines, [ 'value' ], 'engine: chunked line assembled');

// --- engine: errors ----------------------------------------------------------

got = null;
at.send('AT+FAIL', (err, res) => { got = { err: err }; });
tr.reply("\r\nERROR\r\n");
eq(got.err.error, 'ERROR', 'engine: plain error');

got = null;
at.send('AT+CPIN?', (err, res) => { got = { err: err }; });
tr.reply("+CME ERROR: 13\r\n");
eq(got.err, { error: 'cme', code: '13' }, 'engine: cme error with code');

// --- engine: queue serialization ---------------------------------------------

tr = fake_transport();
at = atcmd.create(tr, { log: silent });

let order = [];

at.send('AT+ONE', (err) => push(order, 'one'));
at.send('AT+TWO', (err) => push(order, 'two'));

eq(tr.written, [ "AT+ONE\r" ], 'queue: second command held back');

tr.reply("OK\r\n");
eq(tr.written, [ "AT+ONE\r", "AT+TWO\r" ], 'queue: second sent after first');

tr.reply("OK\r\n");
eq(order, [ 'one', 'two' ], 'queue: callbacks in order');

// --- engine: timeout ---------------------------------------------------------

tr = fake_transport();
at = atcmd.create(tr, { log: silent });

let timed = null;

at.send('AT+SLOW', (err) => { timed = err; }, { timeout: 10 });

uloop.timer(50, () => uloop.end());
uloop.run();

eq(timed.error, 'timeout', 'engine: timeout reported');

// --- engine: run_sequence ----------------------------------------------------

tr = fake_transport();
at = atcmd.create(tr, { log: silent });

let seq_done = false;

at.run_sequence([ 'AT+A', 'AT+B' ], () => { seq_done = true; });
tr.reply("OK\r\n");
tr.reply("ERROR\r\n");   // errors do not abort the sequence

eq(tr.written, [ "AT+A\r", "AT+B\r" ], 'sequence: both commands sent');
ok(seq_done, 'sequence: completion after error');

// --- model quirks ------------------------------------------------------------

eq(atcmd.model_init_commands('EG06'), [ 'AT+QMBNCFG="AutoSel",1' ], 'quirks: EG06');
eq(atcmd.model_init_commands('RG502Q-EA'), [ 'AT+QMBNCFG="AutoSel",1' ], 'quirks: RG502Q');
eq(atcmd.model_init_commands('RG500Q-GL'), [ 'AT+QMBNCFG="AutoSel",1' ], 'quirks: RG500Q');
eq(atcmd.model_init_commands('E392'), [], 'quirks: no init for huawei');
eq(atcmd.model_init_commands(null), [], 'quirks: null model');
ok(index(atcmd.modes_fallback_command('E392'), 'AT^SYSCFGEX') == 0, 'quirks: syscfgex fallback');

// --- cell lock commands ------------------------------------------------------

eq(atcmd.cell_lock_commands({ lock_4g: '1300:246' }),
	[ 'AT+QNWLOCK="common/4g",1,1300,246' ], 'lock: single 4g string');
eq(atcmd.cell_lock_commands({ lock_4g: [ '1300:246' ], lock_persist: true }),
	[ 'AT+QNWLOCK="common/4g",1,1300,246', 'AT+QNWLOCK="save_ctrl",1,1' ],
	'lock: 4g + persist');
eq(atcmd.cell_lock_commands({ lock_4g: [ '1300:246', '1444:100' ] }),
	[ 'AT+QNWLOCK="common/4g_ext",2,1300,246,1444,100' ], 'lock: 4g cell list');
eq(atcmd.cell_lock_commands({ lock_5g: '242:431070:15:1' }),
	[ 'AT+QNWLOCK="common/5g",242,431070,15,1' ], 'lock: 5g sa');
eq(atcmd.cell_lock_commands({}), [], 'lock: nothing configured');
eq(atcmd.cell_lock_commands({ lock_4g: 'garbage' }), [], 'lock: malformed ignored');
eq(atcmd.cell_lock_commands({ lock_persist: true }), [], 'lock: persist alone is no-op');

// --- find_tty ----------------------------------------------------------------

const BASE = '/sys/class/usbmisc/cdc-wdm0/device/..';

function quectel_fx(over)
{
	return fakefx.create({
		files: {
			[sprintf('%s/idVendor', BASE)]: "2c7c\n",
			[sprintf('%s/idProduct', BASE)]: "0800\n",
			[sprintf('%s/1-1.2:1.2/bInterfaceNumber', BASE)]: "02\n",
			[sprintf('%s/1-1.2:1.3/bInterfaceNumber', BASE)]: "03\n",
			...(over?.files ?? {}),
		},
		globs: {
			[sprintf('%s/*/tty*', BASE)]: [
				sprintf('%s/1-1.2:1.3/ttyUSB3', BASE),
				sprintf('%s/1-1.2:1.2/ttyUSB2', BASE),
			],
			...(over?.globs ?? {}),
		},
	});
}

// exact lookup: RG502Q AT port is interface 2 -> ttyUSB2
eq(atcmd.find_tty(quectel_fx(), '/dev/cdc-wdm0', null), '/dev/ttyUSB2', 'find: atport lookup');

// config override wins
eq(atcmd.find_tty(quectel_fx(), '/dev/cdc-wdm0', '/dev/ttyACM7'), '/dev/ttyACM7', 'find: override wins');

// board quirk wins over lookup
let bfx = quectel_fx({ files: { '/tmp/sysinfo/board_name': "zyxel,nr7101\n" } });
eq(atcmd.find_tty(bfx, '/dev/cdc-wdm0', null), '/dev/ttyUSB2', 'find: board quirk');

// unknown usb id: heuristic fallback, first sorted tty
let ufx = quectel_fx({ files: { [sprintf('%s/idVendor', BASE)]: "dead\n" } });
eq(atcmd.find_tty(ufx, '/dev/cdc-wdm0', null), '/dev/ttyUSB2', 'find: heuristic first sorted');

// no ttys at all
let nfx = fakefx.create();
eq(atcmd.find_tty(nfx, '/dev/cdc-wdm0', null), null, 'find: none present');

// local override for devices missing in the generated table (RG650E)
let rg650 = quectel_fx({ files: { [sprintf('%s/idProduct', BASE)]: "0122\n" } });
eq(atcmd.find_tty(rg650, '/dev/cdc-wdm0', null), '/dev/ttyUSB2', 'find: RG650E local override');

done('test_atcmd');
