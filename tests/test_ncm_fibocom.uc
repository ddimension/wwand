// wwand tests — Fibocom AT+GTCAINFO serving/CA parser (telemetry_ncm.uc).
//
// The field offsets are reverse-engineered from real FM190/FM350-GL captures
// (OpenWrt forum "Fibocom/Quectel - FM190 5G/4G modem Signals") and the
// 3ginfo-lite parser, cross-checked between the GTCAINFO decimal rows and the
// GTCCINFO hex row of the same captures, plus the 3GPP band tables. These
// fixtures are the VERBATIM captures — a regression here silently shows
// garbage on the LuCI status page, so they are the authoritative anchors.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as telemetry_ncm from 'wwand/telemetry_ncm.uc';

// capture #1 (post 7 debug trace): LTE anchor B3 + NR n77, one SCC
let cap1 = [
	'+GTCAINFO:',
	'LTE PCC: 103,120,1279,75,2,1,1,1,71',
	'NR PCC: 5078,392,643296,100,2,,1,3,77',
	'LTE SCC1: 1,0,108,383,3700,50,0,1,1,6,6,56',
];

let g = telemetry_ncm.parse_gtcainfo(cap1);

ok(g != null, 'cap1 parses');

// LTE PCC: band is +100-offset, then pci/earfcn, rsrp is value+141
eq(g?.lte?.band, 3, 'cap1 lte band (103 -> 3)');
eq(g?.lte?.pci, 120, 'cap1 lte pci');
eq(g?.lte?.earfcn, 1279, 'cap1 lte earfcn');
eq(g?.lte?.rsrp, -66, 'cap1 lte rsrp (75 -> -66 dBm)');
eq(g?.lte?.rsrq, null, 'cap1 lte rsrq stays null (offset unverified)');
eq(g?.lte?.sinr, null, 'cap1 lte sinr stays null');

// NR PCC: arfcn in slot 3, band in slot 9 (direct, no offset); pci slot is
// NOT the pci (GTCCINFO disagrees) and stays null
eq(g?.nr?.band, 77, 'cap1 nr band (n77, direct)');
eq(g?.nr?.arfcn, 643296, 'cap1 nr arfcn');
eq(g?.nr?.pci, null, 'cap1 nr pci stays null (slot unverified)');
eq(g?.nr?.rsrp, -41, 'cap1 nr rsrp (100 -> -41 dBm)');

// SCC: rat,0,band+100,pci,earfcn,rsrp+141 — B8/EARFCN 3700 pair is consistent
// (3700 lies inside the B8 DL range, which pins the band+100 offset)
eq(length(g?.sccs ?? []), 1, 'cap1 one SCC');
eq(g?.sccs?.[0]?.band, 8, 'cap1 scc band (108 -> 8)');
eq(g?.sccs?.[0]?.pci, 383, 'cap1 scc pci');
eq(g?.sccs?.[0]?.earfcn, 3700, 'cap1 scc earfcn');
eq(g?.sccs?.[0]?.rsrp, -91, 'cap1 scc rsrp (50 -> -91 dBm)');

// capture #2 (post 1): LTE anchor B1
let g2 = telemetry_ncm.parse_gtcainfo([
	'+GTCAINFO:',
	'LTE PCC: 101,36,500,100,2,1,1,3,63',
	'LTE SCC1: 2,0,103,120,1450,100,0,2,1,3,6,62',
]);

eq(g2?.lte?.band, 1, 'cap2 lte band (101 -> 1)');
eq(g2?.lte?.pci, 36, 'cap2 lte pci');
eq(g2?.lte?.earfcn, 500, 'cap2 lte earfcn');
eq(g2?.lte?.rsrp, -41, 'cap2 lte rsrp (100 -> -41 dBm)');
eq(g2?.nr, null, 'cap2 no NR carrier');
eq(g2?.sccs?.[0]?.band, 3, 'cap2 scc band (103 -> 3)');
eq(g2?.sccs?.[0]?.pci, 120, 'cap2 scc pci');
eq(g2?.sccs?.[0]?.earfcn, 1450, 'cap2 scc earfcn');
eq(g2?.sccs?.[0]?.rsrp, -41, 'cap2 scc rsrp (100 -> -41 dBm)');

// blank + non-numeric fields -> null (never NaN), unknown labels skipped
let g3 = telemetry_ncm.parse_gtcainfo([
	'+GTCAINFO:',
	'LTE PCC: 103,xx,1279,,2,1,1,1,71',
	'NR PCC: 5078,,643296,,2,,1,3,77',
	'WCDMA PCC: 1,2,3',
]);

eq(g3?.lte?.pci, null, 'non-numeric pci -> null');
eq(g3?.lte?.rsrp, null, 'blank lte rsrp -> null');
eq(g3?.nr?.rsrp, null, 'blank nr rsrp -> null');
eq(g3?.nr?.pci, null, 'blank nr pci slot -> null');
eq(g3?.nr?.band, 77, 'nr band parsed despite blank fields');

// bands are tolerantly decoded: a direct (< 100) report is kept as-is
let g4 = telemetry_ncm.parse_gtcainfo([ 'LTE PCC: 8,36,500,141,2,1,1,3,63' ]);

eq(g4?.lte?.band, 8, 'direct band report kept (8, no -100 offset)');
eq(g4?.lte?.rsrp, 0, 'rsrp 141 -> 0 dBm');

// T700 GTCAINFO layout (VERBATIM live capture, WH3000 Pro 2026-08-19):
// "PCC:"/"SCC n:" labels, rsrp as the SIGNED LAST field (dBm, no offset),
// 255 = no-measurement sentinels inside the SCC rows
let t7 = telemetry_ncm.parse_gtcainfo([
	'+GTCAINFO:',
	'PCC:103,272,1350,75,75,1,1,1,3,-88',
	'SCC 1:2,0,140,272,38927,100,255,0,255,0,255,-88',
	'SCC 2:2,0,101,272,150,100,255,2,255,2,255,-88',
]);

eq(t7?.lte?.band, 3, 't700 gtca: pcc band (103 -> 3)');
eq(t7?.lte?.pci, 272, 't700 gtca: pcc pci');
eq(t7?.lte?.earfcn, 1350, 't700 gtca: pcc earfcn');
eq(t7?.lte?.rsrp, -88, 't700 gtca: pcc rsrp (signed last field)');
eq(length(t7?.sccs ?? []), 2, 't700 gtca: two SCCs');
eq(t7?.sccs?.[0]?.band, 40, 't700 gtca: scc1 band (140 -> 40)');
eq(t7?.sccs?.[0]?.earfcn, 38927, 't700 gtca: scc1 earfcn');
eq(t7?.sccs?.[0]?.rsrp, -88, 't700 gtca: scc1 rsrp (signed last field)');
eq(t7?.sccs?.[1]?.band, 1, 't700 gtca: scc2 band (101 -> 1)');

// T700 0-sentinel: an unmeasurable RSRP reports 0 (VERBATIM live capture,
// WH3000 Pro 2026-08-30) — that 0 must NOT surface as a "perfect" 0 dBm
// (the status page showed full bars for an unreadably weak signal). Anything
// above the physical RSRP ceiling (-44 dBm, 3GPP TS 36.133) is a sentinel.
let t7b = telemetry_ncm.parse_gtcainfo([
	'+GTCAINFO:',
	'PCC:105,251,2460,50,50,1,1,1,1,0',
]);

eq(t7b?.lte?.rsrp, null, 't700 gtca: 0 rsrp (unmeasurable) -> null, not 0 dBm');

let t7c = telemetry_ncm.parse_gtcainfo([
	'+GTCAINFO:',
	'PCC:103,272,1350,75,75,1,1,1,3,-44',
]);

eq(t7c?.lte?.rsrp, -44, 't700 gtca: -44 dBm (physical ceiling) still a measurement');

let t7d = telemetry_ncm.parse_gtcainfo([
	'+GTCAINFO:',
	'PCC:103,272,1350,75,75,1,1,1,3,-20',
]);

eq(t7d?.lte?.rsrp, null, 't700 gtca: -20 dBm (above ceiling) -> null');

// 255 sentinels must never surface as measurements (field-seen right after a
// cell change: rsrp/rsrq slots read 255 -> garbage would latch into signal)
let t8 = telemetry_ncm.parse_gtccinfo([
	'1,4,001,01,0001,0000001,1350,272,103,75,255,52,255,255',
]);

eq(t8?.lte?.rsrp, null, 'gtccinfo: 255 rsrp -> null');
eq(t8?.lte?.rsrq, null, 'gtccinfo: 255 rsrq -> null');
eq(t8?.lte?.sinr, null, 'gtccinfo: 255 sinr -> null');
eq(t8?.lte?.band, 3, 'gtccinfo: band still parsed with 255 sentinels');

// no PCC lines at all -> null (caller keeps last-known cells)
eq(telemetry_ncm.parse_gtcainfo([ '+GTCAINFO:', '', 'OK' ]), null, 'empty read -> null');
eq(telemetry_ncm.parse_gtcainfo(null), null, 'null lines -> null');

// partial row with empty earfcn/pci slots (cell change) — must stay null,
// never 0 (the empty-token guards in parse_gtccinfo)
let t9 = telemetry_ncm.parse_gtccinfo([
	'1,4,001,01,0001,0000001,,,103,75,13,52,52,18',
]);

eq(t9?.lte?.earfcn, null, 'gtccinfo: empty earfcn -> null (never 0)');
eq(t9?.lte?.pci, null, 'gtccinfo: empty pci -> null (never 0)');
eq(t9?.lte?.band, 3, 'gtccinfo: band still parsed with empty earfcn/pci');

// 255 = no-measurement sentinel on the FM190 GTCAINFO paths too (a 255 rsrp
// slot must not render +114 dBm, a 255 band must not render 155)
let t10 = telemetry_ncm.parse_gtcainfo([
	'LTE PCC: 103,120,1279,255,2,1,1,1,71',
	'LTE SCC1: 1,0,108,383,3700,255,0,1,1,6,6,56',
]);

eq(t10?.lte?.rsrp, null, 'fm190 gtca: 255 rsrp -> null (not +114)');
eq(t10?.sccs?.[0]?.rsrp, null, 'fm190 gtca: 255 scc rsrp -> null');

let t11 = telemetry_ncm.parse_gtcainfo([ 'LTE PCC: 255,36,500,100,2,1,1,3,63' ]);

eq(t11?.lte?.band, null, 'fm190 gtca: 255 band -> null (not 155)');

// 255 band sentinel in GTCCINFO
let t12 = telemetry_ncm.parse_gtccinfo([
	'1,4,001,01,0001,0000001,1350,272,255,75,13,52,52,18',
]);

eq(t12?.lte?.band, null, 'gtccinfo: 255 band -> null');

// pure-digit HEX earfcn (some FM190 firmwares): the band cross-check must pick
// the hex reading when only that lands in the reported band — 0x500 = 1280 is
// B3, while decimal 500 is B1 (the old string/number compare never fired and
// always returned the decimal reading)
let t13 = telemetry_ncm.parse_gtccinfo([
	'1,4,001,01,0001,0000001,500,78,103,75,2,71,71,16',
]);

eq(t13?.lte?.earfcn, 0x500, 'gtccinfo: pure-digit hex earfcn via band cross-check');
eq(t13?.lte?.band, 3, 'gtccinfo: band intact on the hex-earfcn row');

// --- GTCCINFO (the T700 row format — VERBATIM live capture from a
// WH3000 Pro, 2026-08-19; RSRP 54 -> -87 dBm matches the CSQ read at the same
// moment, band 140 -> 40 cross-checks with EARFCN 38927 = B40 DL range)
let g5 = telemetry_ncm.parse_gtccinfo([
	'+GTCCINFO:',
	'1,4,001,01,0001,0000001,38927,272,140,100,13,54,54,12',
]);

eq(g5?.lte?.mcc, 1, 'gtccinfo: mcc');
eq(g5?.lte?.mnc, 1, 'gtccinfo: mnc');
eq(g5?.lte?.tac, 1, 'gtccinfo: tac');
eq(g5?.lte?.cid, 1, 'gtccinfo: cid');
eq(g5?.lte?.earfcn, 38927, 'gtccinfo: earfcn (decimal on the T700)');
eq(g5?.lte?.pci, 272, 'gtccinfo: pci');
eq(g5?.lte?.band, 40, 'gtccinfo: band (140 -> 40)');
eq(g5?.lte?.rsrp, -87, 'gtccinfo: rsrp (54 -> -87 dBm)');
ok(g5?.lte?.rsrq == -14, 'gtccinfo: rsrq ((12-34)/2-3)');
eq(g5?.lte?.sinr, 6.5, 'gtccinfo: sinr (13/2)');
eq(g5?.lte?.bw_mhz, 20.0, 'gtccinfo: bw (100/5 -> 20 MHz)');
eq(g5?.nr, null, 'gtccinfo: no NR row');

// partial row during a cell change: empty tac/cid slots -> null, never 0
// (hex('0x') would read 0 in ucode and the zero would latch into the serving
// cell via the enrichment). Empty mcc/mnc reject the whole row (the mcc/mnc
// groups require digits) — the caller then keeps the last-known cell.
let g6b = telemetry_ncm.parse_gtccinfo([
	'1,4,001,01,,,1350,272,103,75,13,52,52,18',
]);

eq(g6b?.lte?.mcc, 1, 'gtccinfo: mcc still parsed');
eq(g6b?.lte?.mnc, 1, 'gtccinfo: mnc still parsed');
eq(g6b?.lte?.tac, null, 'gtccinfo: empty tac -> null (never 0)');
eq(g6b?.lte?.cid, null, 'gtccinfo: empty cid -> null (never 0)');
eq(g6b?.lte?.earfcn, 1350, 'gtccinfo: earfcn still parsed');
eq(g6b?.lte?.band, 3, 'gtccinfo: band still parsed');
eq(telemetry_ncm.parse_gtccinfo([ '1,4,,,,,1350,272,103,75,13,52,52,18' ]), null,
	'gtccinfo: empty mcc/mnc rejects the row (last-known kept)');

// FM190 LTE row — the same layout with HEX earfcn/pci tokens
let g6 = telemetry_ncm.parse_gtccinfo([
	'1,4,001,01,0001,0000001,4FF,78,103,75,2,71,71,16',
]);

eq(g6?.lte?.earfcn, 1279, 'gtccinfo: hex earfcn (4FF -> 1279)');
eq(g6?.lte?.pci, 120, 'gtccinfo: pci (78)');
eq(g6?.lte?.band, 3, 'gtccinfo: band (103 -> 3)');
eq(g6?.lte?.rsrp, -70, 'gtccinfo: rsrp (71 -> -70 dBm)');
eq(g6?.lte?.tac, 1, 'gtccinfo: tac');
eq(g6?.lte?.cid, 1, 'gtccinfo: cid');

// FM190 NR row: identity (mcc/mnc/tac/cid) + arfcn/pci/band; the trailing
// metrics carry the NR scales (cross-validated on the T700 EN-DC rows below —
// the +5000 band offset holds for both vendors)
let g7 = telemetry_ncm.parse_gtccinfo([
	'1,9,001,01,,,9D0E0,188,5078,100,67,84,84,64',
]);

eq(g7?.nr?.arfcn, 643296, 'gtccinfo: nr arfcn (9D0E0)');
eq(g7?.nr?.pci, 188, 'gtccinfo: nr pci');
eq(g7?.nr?.mcc, 1, 'gtccinfo: nr mcc');
eq(g7?.nr?.band, 78, 'gtccinfo: nr band (5078 -> 78)');
eq(g7?.lte, null, 'gtccinfo: lte null on a pure NR row');

// --- EN-DC (NR NSA) rows — VERBATIM live capture shape (anonymized identity):
// the T700 reports the NR carrier FIRST (band +5000 offset: 5041 = n41) and
// the GTCCINFO NR row carries EMPTY mcc/mnc + all-F identity placeholders —
// the parser must surface it, not reject/drop it (patrakov finding: wwandctl
// showed LTE-only while the network was NR-NSA)
let t14 = telemetry_ncm.parse_gtcainfo([
	'+GTCAINFO:',
	'PCC:5041,770,532002,300,300,3,1,3,1,-87',
	'PCC:103,272,1775,75,75,1,1,1,3,-85',
]);

eq(t14?.nr?.band, 41, 'en-dc gtca: nr band (5041 -> 41)');
eq(t14?.nr?.pci, 770, 'en-dc gtca: nr pci');
eq(t14?.nr?.arfcn, 532002, 'en-dc gtca: nr arfcn (n41)');
eq(t14?.nr?.rsrp, -87, 'en-dc gtca: nr rsrp (signed last field)');
eq(t14?.lte?.band, 3, 'en-dc gtca: lte anchor band still parsed');
eq(t14?.lte?.pci, 272, 'en-dc gtca: lte anchor pci');
eq(t14?.lte?.earfcn, 1775, 'en-dc gtca: lte anchor earfcn');
eq(t14?.lte?.rsrp, -85, 'en-dc gtca: lte anchor rsrp');

let g14 = telemetry_ncm.parse_gtccinfo([
	'+GTCCINFO:',
	'1,4,001,01,0001,0000001,1775,272,103,75,17,55,55,21',
	'1,9,,,FFFFFFF,00FFFFFFF,532002,770,5041,300,28,69,69,65',
]);

eq(g14?.lte?.mcc, 1, 'en-dc gtcc: lte mcc');
eq(g14?.lte?.earfcn, 1775, 'en-dc gtcc: lte earfcn');
eq(g14?.lte?.band, 3, 'en-dc gtcc: lte band');
eq(g14?.lte?.rsrp, -86, 'en-dc gtcc: lte rsrp (55 -> -86)');
eq(g14?.nr?.band, 41, 'en-dc gtcc: nr band (5041 -> 41)');
eq(g14?.nr?.pci, 770, 'en-dc gtcc: nr pci');
eq(g14?.nr?.arfcn, 532002, 'en-dc gtcc: nr arfcn');
eq(g14?.nr?.rsrp, -86.5, 'en-dc gtcc: nr rsrp (69/2-121 -> -86.5, matches the PCC row)');
eq(g14?.nr?.rsrq, -11.0, 'en-dc gtcc: nr rsrq ((65-87)/2 — the 3ginfo FM350 formula)');
eq(g14?.nr?.sinr, 14.0, 'en-dc gtcc: nr sinr (28/2)');
eq(g14?.nr?.bw_mhz, 60.0, 'en-dc gtcc: nr bw (300/5 -> 60 MHz n41, the convert_bw table)');
eq(g14?.nr?.mcc, null, 'en-dc gtcc: nr mcc empty -> null (not a reject)');
eq(g14?.nr?.tac, null, 'en-dc gtcc: all-F tac placeholder -> null');
eq(g14?.nr?.cid, null, 'en-dc gtcc: all-F cid placeholder -> null');

// SHORT all-F identity values are legitimate (TAC 0xFF, ECI 0xFFFFFF) — only
// the long 7+-digit placeholders are nulled (small-operator/lab networks)
let g15 = telemetry_ncm.parse_gtccinfo([
	'1,4,001,01,FF,FFFFFF,1350,272,103,75,13,52,52,18',
]);

eq(g15?.lte?.tac, 255, 'gtccinfo: TAC 0xFF is a real TAC, not a placeholder');
eq(g15?.lte?.cid, 16777215, 'gtccinfo: ECI 0xFFFFFF is a real ECI, not a placeholder');

// --- the CA/carrier table from the EN-DC reads --------------------------------
// the two primary carriers (LTE anchor + NR carrier) feed the status page's
// carrier table, GTCCINFO-enriched (rsrq/sinr/bw) — 0.1 dB scale like the QMI
// backend, bandwidth in MHz from the GTCCINFO bw field (v/5, the 3ginfo
// convert_bw table for both rats)
let tca = telemetry_ncm.ca_entries(
	{ lte: { earfcn: 1775, band: 3, pci: 272, rsrp: -85, rsrq: -9.0, bw_mhz: 15 },
	  nr:  { arfcn: 532002, band: 41, pci: 770, rsrp: -86, rsrq: -11.0, bw_mhz: 60 } },
	[ { earfcn: 150, band: 1, pci: 300, rsrp: -95 } ]);

eq(length(tca), 3, 'ca: both PCC carriers + one SCC');
eq(tca[0]?.role, 'PCC LTE', 'ca: lte carrier role');
eq(tca[0]?.earfcn, 1775, 'ca: lte carrier earfcn');
eq(tca[0]?.rsrp, -850, 'ca: lte rsrp x10');
eq(tca[0]?.rsrq, -90.0, 'ca: lte rsrq x10 (GTCCINFO-enriched)');
eq(tca[0]?.bandwidth_mhz, 15, 'ca: lte bandwidth_mhz');
eq(tca[1]?.role, 'PCC NR', 'ca: nr carrier role (the renderer keys on the NR marker)');
eq(tca[1]?.earfcn, 532002, 'ca: nr carrier arfcn');
eq(tca[1]?.band, 41, 'ca: nr band');
eq(tca[1]?.rsrp, -860, 'ca: nr rsrp x10');
eq(tca[1]?.rsrq, -110.0, 'ca: nr rsrq x10 (GTCCINFO-enriched)');
eq(tca[1]?.bandwidth_mhz, 60, 'ca: nr bandwidth_mhz');
eq(tca[2]?.role, 'SCC', 'ca: scc entry');

done('test_ncm_fibocom');
