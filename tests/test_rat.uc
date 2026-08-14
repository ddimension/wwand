// wwand tests — canonical RAT vocabulary + source mappers (codec/schema/rat.uc).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as rat from 'wwand/codec/schema/rat.uc';

// --- label() -----------------------------------------------------------------

eq(rat.label('lte'), 'LTE', 'label: bare slug');
eq(rat.label('nb-iot'), 'NB-IoT', 'label: NB-IoT slug');
eq(rat.label({ rat: 'lte-m' }), 'LTE-M', 'label: LTE-M object');
eq(rat.label({ rat: 'nr5g', mode: 'sa' }), '5G-SA', 'label: 5G-SA');
eq(rat.label({ rat: 'nr5g', mode: 'nsa' }), '5G-NSA', 'label: 5G-NSA');
eq(rat.label({ rat: 'nr5g' }), 'NR5G', 'label: NR5G no mode');
eq(rat.label({ rat: 'redcap', mode: 'sa' }), 'RedCap', 'label: RedCap');
eq(rat.label({ rat: 'nb-iot', ntn: true }), 'NB-IoT (NTN)', 'label: NTN suffix');
eq(rat.label('bogus'), null, 'label: unknown slug -> null');
eq(rat.label(null), null, 'label: null -> null');

ok(rat.is_iot('nb-iot') && rat.is_iot('lte-m') && rat.is_iot('redcap') && rat.is_iot('ntn'),
	'is_iot: IoT slugs true');
ok(!rat.is_iot('lte') && !rat.is_iot('nr5g') && !rat.is_iot('bogus'),
	'is_iot: base/unknown false');

// --- from_qmi_radio_if() -----------------------------------------------------

eq(rat.from_qmi_radio_if(4), { rat: 'gsm', mode: null, ntn: false, src: 'qmi' }, 'qmi radio_if 4 -> gsm');
eq(rat.from_qmi_radio_if(5), { rat: 'umts', mode: null, ntn: false, src: 'qmi' }, 'qmi radio_if 5 -> umts');
eq(rat.from_qmi_radio_if(8), { rat: 'lte', mode: null, ntn: false, src: 'qmi' }, 'qmi radio_if 8 -> lte');
eq(rat.from_qmi_radio_if(9), { rat: 'td-scdma', mode: null, ntn: false, src: 'qmi' }, 'qmi radio_if 9 -> td-scdma');
eq(rat.from_qmi_radio_if(12), { rat: 'nr5g', mode: null, ntn: false, src: 'qmi' }, 'qmi radio_if 12 -> nr5g');
eq(rat.from_qmi_radio_if(2), { rat: 'evdo', mode: null, ntn: false, src: 'qmi' }, 'qmi radio_if 2 -> evdo');
eq(rat.from_qmi_radio_if(99), null, 'qmi radio_if unknown -> null');

// DMS device-capability radio interface: 5GNR=10 (NOT the NAS 12)
eq(rat.from_dms_radio_if(8), { rat: 'lte', mode: null, ntn: false, src: 'dms' }, 'dms radio_if 8 -> lte');
eq(rat.from_dms_radio_if(10), { rat: 'nr5g', mode: null, ntn: false, src: 'dms' }, 'dms radio_if 10 -> nr5g');
eq(rat.from_dms_radio_if(4), { rat: 'gsm', mode: null, ntn: false, src: 'dms' }, 'dms radio_if 4 -> gsm');
eq(rat.from_dms_radio_if(12), null, 'dms radio_if 12 (NAS-only 5GNR) -> null');

// --- from_dsd() (rat + service-option mask) ----------------------------------

let SO_HSPA = 1 << 6, SO_GPRS = 1 << 7, SO_EDGE = 1 << 8;
let SO_5G_NSA = 1 << 43, SO_5G_SA = 1 << 44;

eq(rat.from_dsd(1, 0), { rat: 'umts', mode: null, ntn: false, src: 'dsd' }, 'dsd WCDMA -> umts');
eq(rat.from_dsd(1, SO_HSPA), { rat: 'hspa', mode: null, ntn: false, src: 'dsd' }, 'dsd WCDMA+HSPA -> hspa');
eq(rat.from_dsd(2, 0), { rat: 'gsm', mode: null, ntn: false, src: 'dsd' }, 'dsd GERAN -> gsm');
eq(rat.from_dsd(2, SO_EDGE), { rat: 'edge', mode: null, ntn: false, src: 'dsd' }, 'dsd GERAN+EDGE -> edge');
eq(rat.from_dsd(2, SO_GPRS), { rat: 'gprs', mode: null, ntn: false, src: 'dsd' }, 'dsd GERAN+GPRS -> gprs');
eq(rat.from_dsd(3, 0), { rat: 'lte', mode: null, ntn: false, src: 'dsd' }, 'dsd LTE -> lte');
eq(rat.from_dsd(3, SO_5G_NSA), { rat: 'nr5g', mode: 'nsa', ntn: false, src: 'dsd' }, 'dsd LTE+5G_NSA -> nr5g nsa');
eq(rat.from_dsd(4, 0), { rat: 'td-scdma', mode: null, ntn: false, src: 'dsd' }, 'dsd TDSCDMA -> td-scdma');
eq(rat.from_dsd(6, 0), { rat: 'nr5g', mode: null, ntn: false, src: 'dsd' }, 'dsd 5G -> nr5g');
eq(rat.from_dsd(6, SO_5G_SA), { rat: 'nr5g', mode: 'sa', ntn: false, src: 'dsd' }, 'dsd 5G+SA -> nr5g sa');
eq(rat.from_dsd(6, SO_5G_NSA), { rat: 'nr5g', mode: 'nsa', ntn: false, src: 'dsd' }, 'dsd 5G+NSA -> nr5g nsa');
eq(rat.from_dsd(0, 0), null, 'dsd unknown -> null');

// --- from_mbim() -------------------------------------------------------------

eq(rat.from_mbim(1 << 5, 0), { rat: 'lte', mode: null, ntn: false, src: 'mbim' }, 'mbim LTE -> lte');
eq(rat.from_mbim(1 << 6, 0), { rat: 'nr5g', mode: 'nsa', ntn: false, src: 'mbim' }, 'mbim 5G_NSA -> nr5g nsa');
eq(rat.from_mbim(1 << 7, 0), { rat: 'nr5g', mode: 'sa', ntn: false, src: 'mbim' }, 'mbim 5G_SA -> nr5g sa');
eq(rat.from_mbim(1 << 2, 0), { rat: 'umts', mode: null, ntn: false, src: 'mbim' }, 'mbim UMTS -> umts');
eq(rat.from_mbim(1 << 3, 0), { rat: 'hspa', mode: null, ntn: false, src: 'mbim' }, 'mbim HSDPA -> hspa');
eq(rat.from_mbim(1 << 0, 0), { rat: 'gprs', mode: null, ntn: false, src: 'mbim' }, 'mbim GPRS -> gprs');
eq(rat.from_mbim(0, 0), null, 'mbim none -> null');
// highest class wins: LTE + 5G_SA -> 5G_SA
eq(rat.from_mbim((1 << 5) | (1 << 7), 0), { rat: 'nr5g', mode: 'sa', ntn: false, src: 'mbim' }, 'mbim LTE+5G_SA -> nr5g sa');

// --- families_from_mbim() (caps.rats base) -----------------------------------

eq(rat.families_from_mbim((1 << 2) | (1 << 5), null), ['umts', 'lte'], 'mbim caps UMTS+LTE');
eq(rat.families_from_mbim((1 << 5) | (1 << 7), null), ['lte', 'nr5g'], 'mbim caps LTE+5G_SA');
eq(rat.families_from_mbim(0, null), [], 'mbim caps none -> empty');
// RM520N: base bits = CUSTOM|UMTS|HSDPA|HSUPA|LTE (no 5G bit), custom = "5G/TDS"
eq(rat.families_from_mbim(0x8000003C, '5G/TDS'), ['umts', 'lte', 'nr5g'], 'mbim caps CUSTOM 5G/TDS -> +nr5g');
// CUSTOM bit but no/empty string -> base bits only (no phantom 5G)
eq(rat.families_from_mbim(0x8000003C, ''), ['umts', 'lte'], 'mbim caps CUSTOM empty string -> base only');
eq(rat.families_from_mbim(0x8000003C, null), ['umts', 'lte'], 'mbim caps CUSTOM null string -> base only');
// custom string can add classes the base bits omit entirely
eq(rat.families_from_mbim(0x80000020, '5G'), ['lte', 'nr5g'], 'mbim caps CUSTOM|LTE + "5G" -> lte,nr5g');
// custom string ignored when CUSTOM bit not set
eq(rat.families_from_mbim(1 << 5, '5G'), ['lte'], 'mbim caps no-CUSTOM ignores custom string');

// --- from_at_cops_act() (3GPP TS 27.007 <AcT>) -------------------------------

eq(rat.from_at_cops_act(0), { rat: 'gsm', mode: null, ntn: false, src: 'at' }, 'AcT 0 -> gsm');
eq(rat.from_at_cops_act(3), { rat: 'edge', mode: null, ntn: false, src: 'at' }, 'AcT 3 -> edge');
eq(rat.from_at_cops_act(2), { rat: 'umts', mode: null, ntn: false, src: 'at' }, 'AcT 2 -> umts');
eq(rat.from_at_cops_act(6), { rat: 'hspa', mode: null, ntn: false, src: 'at' }, 'AcT 6 -> hspa');
eq(rat.from_at_cops_act(7), { rat: 'lte', mode: null, ntn: false, src: 'at' }, 'AcT 7 -> lte');
eq(rat.from_at_cops_act(8), { rat: 'ec-gsm-iot', mode: null, ntn: false, src: 'at' }, 'AcT 8 -> EC-GSM-IoT (was mis-mapped GSM)');
eq(rat.from_at_cops_act(9), { rat: 'nb-iot', mode: null, ntn: false, src: 'at' }, 'AcT 9 -> NB-IoT (was mis-mapped LTE)');
eq(rat.from_at_cops_act(11), { rat: 'nr5g', mode: 'sa', ntn: false, src: 'at' }, 'AcT 11 -> nr5g sa');
eq(rat.from_at_cops_act(12), { rat: 'nr5g', mode: 'sa', ntn: false, src: 'at' }, 'AcT 12 -> nr5g sa');
eq(rat.from_at_cops_act(13), { rat: 'nr5g', mode: 'nsa', ntn: false, src: 'at' }, 'AcT 13 -> nr5g nsa');
eq(rat.from_at_cops_act(99), null, 'AcT unknown -> null');

// --- from_qnwinfo() / from_qeng_act() ----------------------------------------

eq(rat.from_qnwinfo('eMTC'), { rat: 'lte-m', mode: null, ntn: false, src: 'qnwinfo' }, 'qnwinfo eMTC -> lte-m');
eq(rat.from_qnwinfo('NB-IoT'), { rat: 'nb-iot', mode: null, ntn: false, src: 'qnwinfo' }, 'qnwinfo NB-IoT -> nb-iot');
eq(rat.from_qnwinfo('NR5G-SA'), { rat: 'nr5g', mode: 'sa', ntn: false, src: 'qnwinfo' }, 'qnwinfo NR5G-SA -> nr5g sa');
eq(rat.from_qnwinfo('NR5G-NSA'), { rat: 'nr5g', mode: 'nsa', ntn: false, src: 'qnwinfo' }, 'qnwinfo NR5G-NSA -> nr5g nsa');
eq(rat.from_qnwinfo('FDD LTE'), { rat: 'lte', mode: null, ntn: false, src: 'qnwinfo' }, 'qnwinfo FDD LTE -> lte');
eq(rat.from_qnwinfo('"TDD LTE"'), { rat: 'lte', mode: null, ntn: false, src: 'qnwinfo' }, 'qnwinfo quoted TDD LTE -> lte');
eq(rat.from_qnwinfo('WCDMA'), { rat: 'umts', mode: null, ntn: false, src: 'qnwinfo' }, 'qnwinfo WCDMA -> umts');
eq(rat.from_qnwinfo('HSPA+'), { rat: 'hspa', mode: null, ntn: false, src: 'qnwinfo' }, 'qnwinfo HSPA+ -> hspa');
eq(rat.from_qnwinfo('NONE'), { rat: 'none', mode: null, ntn: false, src: 'qnwinfo' }, 'qnwinfo NONE -> none');
eq(rat.from_qnwinfo('RedCap'), { rat: 'redcap', mode: 'sa', ntn: false, src: 'qnwinfo' }, 'qnwinfo RedCap -> redcap');
eq(rat.from_qnwinfo('garbage'), null, 'qnwinfo junk -> null');
eq(rat.from_qeng_act('NR5G-SA'), { rat: 'nr5g', mode: 'sa', ntn: false, src: 'qeng' }, 'qeng NR5G-SA -> nr5g sa (src qeng)');
eq(rat.from_qeng_act('CAT-M'), { rat: 'lte-m', mode: null, ntn: false, src: 'qeng' }, 'qeng CAT-M -> lte-m');

// --- merge() -----------------------------------------------------------------

// AT/QNWINFO IoT finding wins over a coarse QMI LTE base
eq(rat.merge(rat.from_qmi_radio_if(8), rat.from_qnwinfo('NB-IoT')),
	{ rat: 'nb-iot', mode: null, ntn: false, src: 'qnwinfo' }, 'merge: NB-IoT (AT) beats LTE (QMI)');
// a 5G-SA fine reading refines a coarse nr5g base (mode wins)
eq(rat.merge(rat.from_qmi_radio_if(12), rat.from_qnwinfo('NR5G-SA')),
	{ rat: 'nr5g', mode: 'sa', ntn: false, src: 'qnwinfo' }, 'merge: 5G-SA refines bare NR5G');
eq(rat.merge(null, rat.from_qnwinfo('eMTC')),
	{ rat: 'lte-m', mode: null, ntn: false, src: 'qnwinfo' }, 'merge: null base -> fine');
eq(rat.merge(rat.from_qmi_radio_if(8), null),
	{ rat: 'lte', mode: null, ntn: false, src: 'qmi' }, 'merge: null fine -> base');
// NTN carries over from the losing base onto the (finer) winner
eq(rat.merge({ rat: 'lte', mode: null, ntn: true, src: 'hint' }, rat.from_qnwinfo('NB-IoT')),
	{ rat: 'nb-iot', mode: null, ntn: true, src: 'qnwinfo' }, 'merge: NTN flag carried onto finer winner');

// --- caps_from() -------------------------------------------------------------

eq(rat.caps_from({ modes: [ 'gsm', 'lte', 'nr5g' ] }),
	{ rats: [ 'gsm', 'lte', 'nr5g' ], iot_modes: [], ntn: false },
	'caps: base modes, no IoT');
eq(rat.caps_from({ modes: [ 'lte' ], iot_modes: [ 'lte-m', 'nb-iot' ] }),
	{ rats: [ 'lte', 'lte-m', 'nb-iot' ], iot_modes: [ 'lte-m', 'nb-iot' ], ntn: false },
	'caps: iotopmode adds lte-m/nb-iot');
eq(rat.caps_from({ modes: [ 'nr5g' ], model: 'RG255C-GL' }),
	{ rats: [ 'nr5g', 'redcap' ], iot_modes: [ 'redcap' ], ntn: false },
	'caps: RG255 model hint -> redcap');
eq(rat.caps_from({ observed: [ 'nb-iot' ], model: 'BG770A-SN NTN' }),
	{ rats: [ 'nb-iot', 'ntn' ], iot_modes: [ 'nb-iot', 'ntn' ], ntn: true },
	'caps: observed nb-iot + NTN model hint');
eq(rat.caps_from({}), { rats: [], iot_modes: [], ntn: false }, 'caps: empty input');
// bogus slugs are dropped
eq(rat.caps_from({ modes: [ 'lte', 'bogus' ], observed: [ 'lte' ] }),
	{ rats: [ 'lte' ], iot_modes: [], ntn: false }, 'caps: dedup + drop unknown');

done('test_rat');
