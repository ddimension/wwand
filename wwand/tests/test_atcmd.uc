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

// eSIM host-access quirk: verified on the RG650E only
eq(atcmd.esim_quirks('RG650E-EU').lpa_disable_for_host, true, 'esim-quirk: RG650E');
eq(atcmd.esim_quirks('RG502Q-EA').lpa_disable_for_host, null, 'esim-quirk: RG502Q not (untested)');
eq(atcmd.esim_quirks('E392').lpa_disable_for_host, null, 'esim-quirk: none for huawei');
eq(atcmd.esim_quirks(null).lpa_disable_for_host, null, 'esim-quirk: null model');
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

// --- AT+QCAINFO parsing ------------------------------------------------------

eq(atcmd.parse_qcainfo([ '+QCAINFO: "PCC",6300,50,"LTE BAND 20",1,409,-94,-10,-65,4' ]),
	[ { role: 'PCC', earfcn: 6300, rb: 50, bandwidth_mhz: 10, band: 20, pci: 409 } ],
	'qcainfo: PCC single carrier, 50 RB -> 10 MHz');

eq(atcmd.parse_qcainfo([
	'+QCAINFO: "PCC",1300,100,"LTE BAND 3",1,246,-90,-9,-60,10',
	'+QCAINFO: "SCC",6300,50,"LTE BAND 20","DECONFIGURED",0',
	'+QCAINFO: "SCC",1450,75,"LTE BAND 3","ACTIVE",111,-95,-11,-70,6',
]), [
	{ role: 'PCC', earfcn: 1300, rb: 100, bandwidth_mhz: 20, band: 3, pci: 246 },
	{ role: 'SCC', earfcn: 6300, rb: 50, bandwidth_mhz: 10, band: 20, pci: 0 },
	{ role: 'SCC', earfcn: 1450, rb: 75, bandwidth_mhz: 15, band: 3, pci: 111 },
], 'qcainfo: PCC + two SCC, RB->MHz across widths');

eq(atcmd.parse_qcainfo([ 'OK', '' ]), [], 'qcainfo: no carrier lines');

// --- AT+QENG servingcell parsing (LTE + NR5G-NSA) ----------------------------
// real lines from an RG502Q on LTE B3 + NR5G-NSA n1
let sc = atcmd.parse_qeng_servingcell([
	'+QENG: "servingcell","NOCONN"',
	'+QENG: "LTE","FDD",262,01,1C36403,246,1300,3,5,5,BFF,-93,-11,-61,21,15,100,-',
	'+QENG: "NR5G-NSA",262,01,242,-102,19,-11,431070,1,3,0',
]);
eq(sc.state, 'NOCONN', 'qeng: serving state');
eq(sc.lte, { band: 3, earfcn: 1300, pci: 246, bandwidth_mhz: 20, rsrp: -93, rsrq: -11, sinr: 21 },
	'qeng: LTE serving cell (dlbw idx 5 -> 20 MHz)');
eq(sc.nr, { mode: 'NSA', band: 1, arfcn: 431070, pci: 242, bandwidth_mhz: 10, rsrp: -102, sinr: 19, rsrq: -11 },
	'qeng: NR5G-NSA carrier (dlbw idx 3 -> 10 MHz)');

eq(atcmd.parse_qeng_servingcell([ '+QENG: "servingcell","NOCONN"' ]),
	{ state: 'NOCONN', lte: null, nr: null }, 'qeng: state only, no cells');

// --- AT+COPS=? scan parsing --------------------------------------------------

// a real-shaped +COPS=? test response: current + available + forbidden operators
// then the supported <mode>/<AcT> value-range groups (which must be skipped)
eq(atcmd.parse_cops_scan([
	'+COPS: (2,"Telekom.de","TDG","26201",7),(1,"Vodafone.de","Voda","26202",7),' +
	'(3,"o2 - de","o2","26203",2),,(0,1,2,3,4),(0,1,2)',
]), [
	{ mcc: 262, mnc: 1,  name: 'Telekom.de',  status: 'current' },
	{ mcc: 262, mnc: 2,  name: 'Vodafone.de', status: 'available' },
	{ mcc: 262, mnc: 3,  name: 'o2 - de',     status: 'forbidden' },
], 'cops: current/available/forbidden parsed, value-range groups skipped');

// 3-digit MNC and an operator with empty names
eq(atcmd.parse_cops_scan([ '+COPS: (1,,,"310260",7),(2,"AT&T","ATT","310410",7)' ]), [
	{ mcc: 310, mnc: 260, name: '', status: 'available' },
	{ mcc: 310, mnc: 410, name: 'AT&T', status: 'current' },
], 'cops: 3-digit mnc + nameless operator');

eq(atcmd.parse_cops_scan([ 'OK' ]), [], 'cops: no operator line');

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
