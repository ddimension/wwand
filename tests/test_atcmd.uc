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

// --- AT+QNWLOCK read-back parsing --------------------------------------------

let lk4 = atcmd.parse_qnwlock([ '+QNWLOCK: "common/4g",1,1300,246' ]);
eq(lk4.scope, 'common/4g', 'qnwlock: scope parsed');
eq(lk4.enabled, true, 'qnwlock: enabled flag');
eq(lk4.values, [ 1300, 246 ], 'qnwlock: earfcn/pci values');
eq(atcmd.parse_qnwlock([ '+QNWLOCK: "common/5g",0' ]).enabled, false, 'qnwlock: disabled');
eq(atcmd.parse_qnwlock([ 'OK' ]), null, 'qnwlock: no lock line -> null');

// --- AT+QENG servingcell parsing (LTE + NR5G-NSA) ----------------------------
// real lines from an RG502Q on LTE B3 + NR5G-NSA n1
let sc = atcmd.parse_qeng_servingcell([
	'+QENG: "servingcell","NOCONN"',
	'+QENG: "LTE","FDD",262,01,1C36403,246,1300,3,5,5,BFF,-93,-11,-61,21,15,100,-',
	'+QENG: "NR5G-NSA",262,01,242,-102,19,-11,431070,1,3,0',
]);
eq(sc.state, 'NOCONN', 'qeng: serving state');
eq(sc.lte, { mcc: 262, mnc: '01', cid: 29582339, tac: 3071, band: 3, earfcn: 1300,
	pci: 246, bandwidth_mhz: 20, rsrp: -93, rsrq: -11, rssi: -61, sinr: 21 },
	'qeng: LTE serving cell (dlbw idx 5 -> 20 MHz, mcc/mnc/cid/tac decoded)');
eq(sc.nr, { mode: 'NSA', mcc: 262, mnc: '01', band: 1, arfcn: 431070, pci: 242,
	bandwidth_mhz: 10, rsrp: -102, sinr: 19, rsrq: -11 },
	'qeng: NR5G-NSA carrier (dlbw idx 3 -> 10 MHz)');

eq(atcmd.parse_qeng_servingcell([ '+QENG: "servingcell","NOCONN"' ]),
	{ state: 'NOCONN', lte: null, nr: null }, 'qeng: state only, no cells');

// --- AT+QENG="neighbourcell" parsing (intra + inter) -------------------------
// metrics come out in QMI 0.1 dB units (×10). Quectel order after earfcn,pcid is
// rsrq,rsrp,rssi,sinr,srxlev.
let nb = atcmd.parse_qeng_neighbourcell([
	'+QENG: "neighbourcell intra","LTE",1300,155,-13,-99,-70,8,-4,7,0,0,0',
	'+QENG: "neighbourcell inter","LTE",100,88,-15,-105,-75,4,-8,5,0,0',
	'+QENG: "neighbourcell inter","LTE",100,91,-16,-108,-78,2,-10,5,0,0',
]);
eq(length(nb.intra), 1, 'qeng nc: one intra neighbour');
eq(nb.intra[0], { earfcn: 1300, pci: 155, rsrq: -130, rsrp: -990, rssi: -700, srxlev: -40 },
	'qeng nc: intra neighbour (metrics ×10 into 0.1 dB units)');
eq(length(nb.inter), 2, 'qeng nc: two inter neighbours');
eq(nb.inter[1], { earfcn: 100, pci: 91, rsrq: -160, rsrp: -1080, rssi: -780, srxlev: -100 },
	'qeng nc: inter neighbour parsed');
eq(atcmd.parse_qeng_neighbourcell([ 'OK' ]), { intra: [], inter: [], nr: [] }, 'qeng nc: none -> empty');

// NR5G neighbour rows (QMI carries none, so QENG is the only source). Two layouts:
// with an ARFCN (large) and without (PCI first) — told apart by magnitude.
let nrn = atcmd.parse_qeng_neighbourcell([
	'+QENG: "neighbourcell","NR5G",633984,123,-95,-11,15',   // arfcn,pci,rsrp,rsrq,sinr
	'+QENG: "neighbourcell","NR5G",300,-88,-9,20',            // pci,rsrp,rsrq,sinr (no arfcn)
]);
eq(length(nrn.nr), 2, 'qeng nc: two NR neighbours');
eq(nrn.nr[0], { arfcn: 633984, pci: 123, rsrp: -950, rsrq: -110, sinr: 15 },
	'qeng nc: NR neighbour with ARFCN (metrics ×10)');
eq(nrn.nr[1], { arfcn: null, pci: 300, rsrp: -880, rsrq: -90, sinr: 20 },
	'qeng nc: NR neighbour without ARFCN (PCI-first layout)');

// --- per-branch AT+QRSRP?/QRSRQ?/QSINR? --------------------------------------
let qp = atcmd.parse_qrsrp([ '+QRSRP: -95,-98,-140,-140,LTE' ]);
eq(qp.mode, 'LTE', 'qrsrp: sysmode LTE');
eq(qp.branches, [ -95, -98, -140, -140 ], 'qrsrp: four Rx branches');
eq(atcmd.branch_best(qp, -200), -95, 'qrsrp: best (strongest) branch');
eq(atcmd.parse_qsinr([ '+QSINR: 24,22,16,18,NR5G' ]).mode, 'NR5G', 'qsinr: NR5G sysmode');
eq(atcmd.branch_best(atcmd.parse_qsinr([ '+QSINR: 24,22,16,18,NR5G' ]), -200), 24,
	'qsinr: best branch = 24');

// --- AT+CEER reject-cause extraction -----------------------------------------
eq(atcmd.parse_ceer([ '+CEER: EMM cause 33, requested service option not subscribed' ]),
	{ text: 'EMM cause 33, requested service option not subscribed', cause: 33 },
	'ceer: numeric cause after "cause"');
eq(atcmd.parse_ceer([ '+CEER: No cause information available' ]).cause, null,
	'ceer: free text -> no cause');

// --- AT+CESQ (3GPP-generic signal) -------------------------------------------
// +CESQ: rxlev,ber,rscp,ecno,rsrq,rsrp -> LTE rsrp=-140+n, rsrq=-19.5+n*0.5
let cq = atcmd.parse_cesq([ '+CESQ: 99,99,255,255,20,60' ]);
eq(cq.lte, { rsrq: -9.5, rsrp: -80 }, 'cesq: LTE rsrp/rsrq decoded');
eq(cq.gsm_rssi, null, 'cesq: GSM n/a (rxlev 99)');
eq(atcmd.parse_cesq([ '+CESQ: 99,99,60,30,255,255' ]).wcdma, { rscp: -60, ecno: -9.0 },
	'cesq: WCDMA rscp/ecno decoded');

// --- Huawei ^HCSQ signal (best-effort conversion) ----------------------------
let hc = atcmd.parse_hcsq([ '^HCSQ: "LTE",30,29,91,22' ]);
eq(hc.mode, 'LTE', 'hcsq: LTE mode');
eq(hc.lte, { rssi: -91, rsrp: -112, sinr: -1.8, rsrq: -8.5 },
	'hcsq: LTE rssi/rsrp/sinr/rsrq converted (v-121, v-141, v/5-20, v/2-19.5)');
// tolerates the report-config prefix seen on some firmwares
eq(atcmd.parse_hcsq([ '^HCSQ: 2,0,"LTE",63,20,68,151' ]).mode, 'LTE',
	'hcsq: numeric report-config prefix tolerated');

// --- Huawei ^MONSC serving cell (best-effort) --------------------------------
let ms = atcmd.parse_monsc([ '^MONSC: LTE,250,02,6350,1A2B3C,131,ABCD,-104,-12,-81' ]);
eq(ms.mcc, 250, 'monsc: mcc');
eq(ms.earfcn, 6350, 'monsc: earfcn');
eq(ms.pci, 131, 'monsc: pci');
eq(ms.cid, 1715004, 'monsc: cell id from hex');
eq(ms.tac, 43981, 'monsc: tac from hex');
eq(ms.rsrp, -1040, 'monsc: rsrp ×10 into 0.1 dB');
eq(ms.rsrp_dbm, -104, 'monsc: rsrp_dbm kept for self.signal');

// --- MeiG AT+MENG serving + neighbour ----------------------------------------
// 16-field manual form (no SINR): last metric is srxlev
let mg = atcmd.parse_meng_servingcell([
	'+MENG: "servingcell",1,"LTE",1,262,03,1A2B3C4,88,1300,3,5,5,BFF,-95,-10,-65,12',
]);
eq(mg.pci, 88, 'meng: serving pci');
eq(mg.earfcn, 1300, 'meng: serving earfcn');
eq(mg.rsrp_dbm, -95, 'meng: serving rsrp dBm');
eq(mg.rsrp, -950, 'meng: serving rsrp ×10');
eq(mg.sinr, null, 'meng: 16-field form has no SINR');
eq(mg.srxlev, 120, 'meng: 16-field form srxlev');
// real SLM770A-R B.0.3 line (17 fields: SINR present, RSRQ with decimal
// fraction — the integer-only match used to null it out -> "rsrq 0.0" bug)
let mg2 = atcmd.parse_meng_servingcell([
	'+MENG: "servingcell","CONNECT","LTE","FDD",262,01,2fc9902,316,1300,3,5,5,fbe,-108,-10.5,-77,-20,19',
]);
eq(mg2.cid, 0x2fc9902, 'meng hw: cid');
eq(mg2.tac, 0xfbe, 'meng hw: tac');
eq(mg2.rsrp, -1080, 'meng hw: rsrp ×10');
eq(mg2.rsrq, -105, 'meng hw: decimal rsrq ×10');
eq(mg2.rsrq_db, -10.5, 'meng hw: rsrq_db plain');
eq(mg2.sinr, -200, 'meng hw: sinr ×10 (manual format line omits it)');
eq(mg2.sinr_db, -20, 'meng hw: sinr_db plain');
eq(mg2.srxlev, 190, 'meng hw: srxlev ×10');
let mgn = atcmd.parse_meng_neighbourcell([
	'+MENG: "neighbourcell intra","LTE",1300,155,-99,-13,-,-,-5',
	'+MENG: "neighbourcell intra","LTE",1300,341,-119,-17.5,-,-,0,0,0,4,0',
	'+MENG: "neighbourcell inter","LTE",6400,36,-93,-9.0,-,-,0,0,0,0',
]);
eq(mgn.intra[0], { earfcn: 1300, pci: 155, rsrp: -990, rsrq: -130, srxlev: -50 },
	'meng nc: intra neighbour (RSRP,RSRQ order, metrics ×10)');
eq(mgn.intra[1], { earfcn: 1300, pci: 341, rsrp: -1190, rsrq: -175, srxlev: 0 },
	'meng nc: decimal rsrq survives (real HW line)');
eq(mgn.inter[0].rsrq, -90, 'meng nc: inter decimal rsrq');

// --- MeiG AT^CELLLOCK? read-back ---------------------------------------------
let cl = atcmd.parse_celllock([
	'^CELLLOCK: 1,"LTE",1,1300,316',
	'^CELLLOCK: 0',
]);
eq(cl[0], { enabled: true, rat: 'LTE', lock_type: 1, arfcn: 1300, pci: 316 },
	'celllock: enabled LTE freq+cell lock');
eq(cl[1].enabled, false, 'celllock: disabled entry');
eq(atcmd.parse_celllock([ 'OK' ]), null, 'celllock: no lines -> null');

// --- AT+COPS? read form (network-selection idempotency guard) ----------------
eq(atcmd.parse_cops_read([ '+COPS: 0,2,"26201"' ]),
	{ mode: 0, format: 2, oper: '26201', plmn: '26201', act: null, rat: null },
	'cops read: numeric auto');
eq(atcmd.parse_cops_read([ '+COPS: 1,0,"Testnet"' ]),
	{ mode: 1, format: 0, oper: 'Testnet', plmn: null, act: null, rat: null },
	'cops read: long-format oper has no plmn digits');
eq(atcmd.parse_cops_read([ '+COPS: 0' ]),
	{ mode: 0, format: null, oper: null, plmn: null, act: null, rat: null },
	'cops read: bare mode');
// with the active access technology tail (<AcT>) — NB-IoT surfaces here
eq(atcmd.parse_cops_read([ '+COPS: 0,2,"26201",9' ]),
	{ mode: 0, format: 2, oper: '26201', plmn: '26201', act: 9, rat: 'NB-IoT' },
	'cops read: AcT 9 -> NB-IoT');
eq(atcmd.parse_cops_read([ '+COPS: 0,2,"26201",7' ]),
	{ mode: 0, format: 2, oper: '26201', plmn: '26201', act: 7, rat: 'LTE' },
	'cops read: AcT 7 -> LTE');
eq(atcmd.parse_cops_read([ 'OK' ]), null, 'cops read: no line -> null');

// --- AT+COPS=? scan parsing --------------------------------------------------

// a real-shaped +COPS=? test response: current + available + forbidden operators
// then the supported <mode>/<AcT> value-range groups (which must be skipped)
eq(atcmd.parse_cops_scan([
	'+COPS: (2,"Telekom.de","TDG","26201",7),(1,"Vodafone.de","Voda","26202",7),' +
	'(3,"o2 - de","o2","26203",2),,(0,1,2,3,4),(0,1,2)',
]), [
	{ mcc: 262, mnc: 1,  plmn: '262/01', name: 'Telekom.de',  status: 'current',   rats: [ 'LTE' ] },
	{ mcc: 262, mnc: 2,  plmn: '262/02', name: 'Vodafone.de', status: 'available',  rats: [ 'LTE' ] },
	{ mcc: 262, mnc: 3,  plmn: '262/03', name: 'o2 - de',     status: 'forbidden',  rats: [ 'UMTS' ] },
], 'cops: current/available/forbidden + AcT->RAT parsed, value-range groups skipped');

// 3-digit MNC and an operator with empty names
eq(atcmd.parse_cops_scan([ '+COPS: (1,,,"310260",7),(2,"AT&T","ATT","310410",7)' ]), [
	{ mcc: 310, mnc: 260, plmn: '310/260', name: '', status: 'available', rats: [ 'LTE' ] },
	{ mcc: 310, mnc: 410, plmn: '310/410', name: 'AT&T', status: 'current', rats: [ 'LTE' ] },
], 'cops: 3-digit mnc + nameless operator');

// AcT omitted (4-field group) -> no rat; and AcT for 2G/5G-SA
eq(atcmd.parse_cops_scan([ '+COPS: (2,"A","A","26201"),(1,"B","B","26202",0),(1,"C","C","26203",11)' ]), [
	{ mcc: 262, mnc: 1, plmn: '262/01', name: 'A', status: 'current',   rats: [] },
	{ mcc: 262, mnc: 2, plmn: '262/02', name: 'B', status: 'available', rats: [ 'GSM' ] },
	{ mcc: 262, mnc: 3, plmn: '262/03', name: 'C', status: 'available', rats: [ '5G-SA' ] },
], 'cops: AcT mapping (none/GSM/5G-SA)');

// IoT AcT values now surface distinctly instead of being folded into GSM/LTE
eq(atcmd.parse_cops_scan([ '+COPS: (1,"IoTnet","IoT","26201",8),(1,"NBnet","NB","26202",9)' ]), [
	{ mcc: 262, mnc: 1, plmn: '262/01', name: 'IoTnet', status: 'available', rats: [ 'EC-GSM-IoT' ] },
	{ mcc: 262, mnc: 2, plmn: '262/02', name: 'NBnet',  status: 'available', rats: [ 'NB-IoT' ] },
], 'cops: AcT 8/9 -> EC-GSM-IoT / NB-IoT');

eq(atcmd.parse_cops_scan([ 'OK' ]), [], 'cops: no operator line');

// --- AT+QNWINFO (active access technology; primary IoT path) -----------------
eq(atcmd.parse_qnwinfo([ '+QNWINFO: "FDD LTE","46000","LTE BAND 3",1650' ]),
	{ act: 'FDD LTE', rat: 'lte', mode: null, label: 'LTE', oper: '46000', band: 'LTE BAND 3', channel: 1650 },
	'qnwinfo: FDD LTE');
eq(atcmd.parse_qnwinfo([ '+QNWINFO: "NB-IoT","26201","LTE BAND 8",3688' ]),
	{ act: 'NB-IoT', rat: 'nb-iot', mode: null, label: 'NB-IoT', oper: '26201', band: 'LTE BAND 8', channel: 3688 },
	'qnwinfo: NB-IoT');
eq(atcmd.parse_qnwinfo([ '+QNWINFO: "eMTC","26201","LTE BAND 20",6300' ]),
	{ act: 'eMTC', rat: 'lte-m', mode: null, label: 'LTE-M', oper: '26201', band: 'LTE BAND 20', channel: 6300 },
	'qnwinfo: eMTC -> LTE-M');
eq(atcmd.parse_qnwinfo([ '+QNWINFO: "NR5G-SA","26201","NR N78",636666' ]),
	{ act: 'NR5G-SA', rat: 'nr5g', mode: 'sa', label: '5G-SA', oper: '26201', band: 'NR N78', channel: 636666 },
	'qnwinfo: NR5G-SA');
eq(atcmd.parse_qnwinfo([ '+QNWINFO: No Service' ]), null, 'qnwinfo: No Service -> null');
eq(atcmd.parse_qnwinfo([ 'OK' ]), null, 'qnwinfo: no line -> null');
eq(atcmd.parse_qnwinfo([ '+QNWINFO: "GARBAGE","x","y",0' ]), null, 'qnwinfo: unknown act -> null');

// --- AT+QCFG="iotopmode" (IoT search-mode capability) ------------------------
eq(atcmd.parse_qcfg_iotopmode([ '+QCFG: "iotopmode",0' ]), [ 'lte-m' ], 'iotopmode 0 -> lte-m');
eq(atcmd.parse_qcfg_iotopmode([ '+QCFG: "iotopmode",1' ]), [ 'nb-iot' ], 'iotopmode 1 -> nb-iot');
eq(atcmd.parse_qcfg_iotopmode([ '+QCFG: "iotopmode",2' ]), [ 'lte-m', 'nb-iot' ], 'iotopmode 2 -> both');
eq(atcmd.parse_qcfg_iotopmode([ 'OK' ]), null, 'iotopmode: no line -> null');

// --- AT+CRSM (restricted SIM access; FPLMN read/write) -----------------------
eq(atcmd.parse_crsm([ '+CRSM: 144,0,"212F810FFFFFFFFFFFFFFFFF"' ]),
	{ sw1: 144, sw2: 0, data: '212F810FFFFFFFFFFFFFFFFF', ok: true },
	'crsm: read success with data');
eq(atcmd.parse_crsm([ '+CRSM: 144,0' ]),
	{ sw1: 144, sw2: 0, data: null, ok: true }, 'crsm: update success, no data');
eq(atcmd.parse_crsm([ '+CRSM: 98,8' ]),
	{ sw1: 98, sw2: 8, data: null, ok: false }, 'crsm: security-status failure (0x98)');
eq(atcmd.parse_crsm([ '+CRSM: 145,20,"deadBEEF"' ]),
	{ sw1: 145, sw2: 20, data: 'DEADBEEF', ok: true }, 'crsm: 0x91 proactive-cmd ok, hex upper-cased');
eq(atcmd.parse_crsm([ 'OK' ]), null, 'crsm: no line -> null');

// --- parse_cpol (preferred PLMN list read) -----------------------------------
let cpol = atcmd.parse_cpol([
	'+CPOL: 1,2,"26201",1,0,1,1,0',   // GSM + UTRAN + E-UTRAN, no NG-RAN
	'+CPOL: 2,2,"310260",0,0,0,1,1',  // E-UTRAN + NG-RAN, 3-digit mnc
	'+CPOL: 3,0,"Telekom.de"',        // alpha format (no numeric plmn)
	'OK',
]);
eq(length(cpol), 3, 'cpol: three records');
eq(cpol[0], { index: 1, format: 2, oper: '26201', mcc: '262', mnc: '01',
	gsm: true, utran: true, eutran: true, ngran: false }, 'cpol: numeric record + AcT flags');
eq(cpol[1].mnc, '260', 'cpol: 3-digit mnc');
eq(cpol[1].ngran, true, 'cpol: NG-RAN flag');
eq(cpol[2].mcc, null, 'cpol: alpha format has no numeric mcc/mnc');
eq(atcmd.parse_cpol([ 'OK' ]), [], 'cpol: empty');

// --- temperature parsers (QModem-derived) ------------------------------------

// Quectel AT+QTEMP: sensor-name digits skipped, first in-range value wins
eq(atcmd.parse_qtemp([ '+QTEMP: "cpu0-0-usr","35"', '+QTEMP: "pa1","120"' ]), 35, 'qtemp: quoted sensor,val');
eq(atcmd.parse_qtemp([ '+QTEMP: 42' ]), 42, 'qtemp: bare value');
eq(atcmd.parse_qtemp([ '+QTEMP: "modem-ambient","5"' ]), null, 'qtemp: below floor -> null');
eq(atcmd.parse_qtemp([ 'OK' ]), null, 'qtemp: no line -> null');

// Huawei ^CHIPTEMP: first plausible sensor across the CSV
eq(atcmd.parse_chiptemp([ '^CHIPTEMP: 0,38,41,45' ]), 38, 'chiptemp: first in-range (0 skipped)');
eq(atcmd.parse_chiptemp([ 'OK' ]), null, 'chiptemp: none -> null');

// SIMCom AT+CPMUTEMP: single Celsius value
eq(atcmd.parse_cpmutemp([ '+CPMUTEMP: 47' ]), 47, 'cpmutemp: single value');

// MeiG AT+TEMP: quoted sensor, milli-Celsius on Unisoc (soc-thmzone) -> /1000
eq(atcmd.parse_meig_temp([ '+TEMP: "soc-thmzone","38500"' ]), 38, 'meig temp: milli soc-thmzone /1000');
eq(atcmd.parse_meig_temp([ '+TEMP: "cpu0-0-usr","44"' ]), 44, 'meig temp: plain cpu sensor');
eq(atcmd.parse_meig_temp([ '+TEMP: "board","39"' ]), 39, 'meig temp: fallback first plausible');
eq(atcmd.parse_meig_temp([ 'OK' ]), null, 'meig temp: none -> null');

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

// PCIe/MHI modem: no USB tty siblings -> AT port is a wwan/MHI char device
let mhi_fx = fakefx.create({
	globs: {
		[sprintf('%s/*/tty*', BASE)]: [],           // no USB ttys under the modem
		'/dev/wwan*at*': [ '/dev/wwan0at0' ],
	},
});
eq(atcmd.find_tty(mhi_fx, '/dev/cdc-wdm0', null), '/dev/wwan0at0', 'find: MHI/wwan AT char-dev fallback');

// direct find_mhi_at: wwan subsystem preferred, then legacy mhi_DUN, else null
eq(atcmd.find_mhi_at(fakefx.create({ globs: { '/dev/mhi_*DUN*': [ '/dev/mhi_0306_00.01.00_DUN' ] } })),
	'/dev/mhi_0306_00.01.00_DUN', 'find_mhi_at: legacy mhi_DUN node');
eq(atcmd.find_mhi_at(fakefx.create({})), null, 'find_mhi_at: no MHI node -> null');

// NCM: `device` is a netdev name (no usbmisc anchor) — the net-class fallback
// must find the ttys, incl. the LOCAL_PORTS role pick (MeiG SLM770A ECM: if4).
// This is the retry path after a runtime new_id bind created the ttys late.
const NBASE = '/sys/class/net/usb0/device/..';

let ncm_tty_fx = fakefx.create({
	files: {
		[sprintf('%s/idVendor', NBASE)]: "2dee\n",
		[sprintf('%s/idProduct', NBASE)]: "4d58\n",
		[sprintf('%s/1-1:1.2/bInterfaceNumber', NBASE)]: "02\n",
		[sprintf('%s/1-1:1.4/bInterfaceNumber', NBASE)]: "04\n",
	},
	globs: {
		[sprintf('%s/*/tty*', NBASE)]: [
			sprintf('%s/1-1:1.2/ttyUSB0', NBASE),
			sprintf('%s/1-1:1.4/ttyUSB2', NBASE),
		],
	},
});
eq(atcmd.find_tty(ncm_tty_fx, 'usb0', null), '/dev/ttyUSB2', 'find: netdev-anchored lookup (NCM)');

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

// --- ATI parse (model-identity fallback) -------------------------------------
let ati1 = atcmd.parse_ati([ 'Manufacturer: huawei', 'Model: E398', 'Revision: 11.810.09.04.00', 'IMEI: 861234567890123', 'OK' ]);
eq(ati1.model, 'E398', 'ati: labeled model');
eq(ati1.manufacturer, 'huawei', 'ati: labeled manufacturer');
eq(ati1.revision, '11.810.09.04.00', 'ati: labeled revision');

let ati2 = atcmd.parse_ati([ 'Quectel', 'RG650E-EU', 'Revision: RG650EEUAAR11A05M8G', 'OK' ]);
eq(ati2.model, 'RG650E-EU', 'ati: bare model (line 2)');
eq(ati2.manufacturer, 'Quectel', 'ati: bare manufacturer (line 1)');
eq(ati2.revision, 'RG650EEUAAR11A05M8G', 'ati: labeled revision wins over bare');

let ati3 = atcmd.parse_ati([ '^RSSI:26', 'Manufacturer: huawei', '^LTERSRP:-87,-12', 'Model: E398', '+CSQ: 26,99', 'OK' ]);
eq(ati3.model, 'E398', 'ati: URC/+ noise ignored');

eq(atcmd.parse_ati([ '^RSSI:26', 'OK' ]), null, 'ati: nothing useful -> null');

// --- parse_monnc / parse_qrsrq gap fill --------------------------------------

let monnc = atcmd.parse_monnc([ '^MONNC: LTE,1300,155,-99,-13,0,8',
                                '^MONNC: LTE,100,88,-105,-15', 'garbage', 'OK' ]);
eq(length(monnc), 2, 'monnc: two neighbour lines parsed');
eq(monnc[0], { earfcn: 1300, pci: 155, rsrp: -990, rsrq: -130 },
	'monnc: metrics in 0.1 dB units');
eq(monnc[1].pci, 88, 'monnc: second line pci');
eq(atcmd.parse_monnc([ 'OK' ]), [], 'monnc: no lines -> empty list');

let qrsrq = atcmd.parse_qrsrq([ '+QRSRQ: -11,-12,-20,-20,LTE' ]);
eq(qrsrq.branches, [ -11, -12, -20, -20 ], 'qrsrq: all rx branches');
eq(atcmd.branch_best(qrsrq, -19), -11, 'qrsrq: branch_best picks strongest above floor');
eq(atcmd.branch_best({ branches: [ -140, -140 ] }, -139), null,
	'branch_best: all-sentinel branches -> null');

// --- robustness: no vendor parser may throw on garbage -----------------------
// Feed every lines-taking parser hostile input (ERROR, binary junk, truncated
// reports, huge line). A parser that throws would kill the telemetry tick.
let hostile = [
	[ 'ERROR' ],
	[ '+CME ERROR: 100' ],
	[ '\x00\x01\xffbinary\x7f' ],
	[ '+QENG: "servingcell"' ],           // truncated: no payload
	[ '^MONSC: LTE' ],                    // truncated
	[ '+MENG: "servingcell"' ],           // truncated
	[ '^HCSQ: "LTE"' ],                   // no values
	[ '+CEER:' ],
	[ sprintf('+QCAINFO: %s', substr('x' + 'y', 0, 1)) ],
	[ '1,2,3,4,5,6,7,8,9' ],              // bare numbers, no prefix
	[],
	null,
];
let parsers = [ 'parse_qnwlock', 'parse_qcainfo', 'parse_qeng_servingcell',
	'parse_qeng_neighbourcell', 'parse_qrsrp', 'parse_qrsrq', 'parse_qsinr',
	'parse_ceer', 'parse_cesq', 'parse_hcsq', 'parse_monsc', 'parse_monnc',
	'parse_meng_servingcell', 'parse_meng_neighbourcell', 'parse_celllock',
	'parse_ati', 'parse_cops_read', 'parse_cops_scan', 'parse_qnwinfo', 'parse_crsm', 'parse_qtemp',
	'parse_chiptemp', 'parse_cpmutemp', 'parse_meig_temp' ];
let threw = [];
for (let name in parsers)
	for (let input in hostile)
		try { atcmd[name](input); }
		catch (e) { push(threw, sprintf('%s(%J)', name, input)); }
eq(threw, [], 'robustness: no parser throws on hostile input');

done('test_atcmd');
