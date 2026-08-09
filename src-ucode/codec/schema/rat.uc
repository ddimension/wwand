// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — canonical radio-access-technology (RAT) vocabulary + source mappers.
//
// libqmi 1.38 and libmbim 1.32 stop at GSM/UMTS/LTE/TD-SCDMA/5G-NR (plus HSPA
// sub-bearers and the 5G NSA/SA split); NONE of NB-IoT, LTE-M (Cat-M1/eMTC),
// EC-GSM-IoT, RedCap (NR-Light) or NTN/satellite exist as constants there.
// This module defines wwand's OWN canonical RAT slugs and normalises every
// available source into one { rat, mode, ntn, src } object:
//   - QMI NAS radio interface        -> from_qmi_radio_if()
//   - QMI DSD rat + service-option    -> from_dsd()
//   - MBIM data class + v3 subclass   -> from_mbim()
//   - 3GPP TS 27.007 <AcT> (COPS/…)   -> from_at_cops_act()
//   - Quectel +QNWINFO / +QENG string -> from_qnwinfo() / from_qeng_act()
// The IoT variants are only reachable over the AT sources, so those win in
// merge(). label() renders the display string (e.g. "NB-IoT", "5G-SA",
// "RedCap", "NB-IoT (NTN)"). Read-only identification — no RAT is ever set on
// the modem from here.

'use strict';

// canonical RAT slugs and their metadata. `family` groups the fine variants
// onto their base radio family (used for coarse comparisons); `iot` marks the
// cellular-IoT / reduced-capability variants; `label` is the display string.
export const RAT = {
	none:         { family: 'none',  label: 'none',       iot: false },
	gsm:          { family: 'gsm',   label: 'GSM',        iot: false },
	gprs:         { family: 'gsm',   label: 'GPRS',       iot: false },
	edge:         { family: 'gsm',   label: 'EDGE',       iot: false },
	umts:         { family: 'umts',  label: 'UMTS',       iot: false },
	hspa:         { family: 'umts',  label: 'HSPA',       iot: false },
	'td-scdma':   { family: 'umts',  label: 'TD-SCDMA',   iot: false },
	cdma:         { family: 'cdma',  label: 'CDMA',       iot: false },
	evdo:         { family: 'cdma',  label: 'EVDO',       iot: false },
	lte:          { family: 'lte',   label: 'LTE',        iot: false },
	'lte-m':      { family: 'lte',   label: 'LTE-M',      iot: true  },
	'nb-iot':     { family: 'lte',   label: 'NB-IoT',     iot: true  },
	'ec-gsm-iot': { family: 'gsm',   label: 'EC-GSM-IoT', iot: true  },
	nr5g:         { family: 'nr5g',  label: 'NR5G',       iot: false },
	redcap:       { family: 'nr5g',  label: 'RedCap',     iot: true  },
	ntn:          { family: 'ntn',   label: 'NTN',        iot: true  },
};

export const IOT_SLUGS = [ 'lte-m', 'nb-iot', 'ec-gsm-iot', 'redcap', 'ntn' ];

// build a RAT object; drops unknown slugs to null
function mk(rat, mode, ntn, src)
{
	if (rat == null || RAT[rat] == null)
		return null;

	return { rat: rat, mode: mode ?? null, ntn: !!ntn, src: src ?? null };
};

export function is_iot(rat)
{
	return !!(rat != null && RAT[rat]?.iot);
};

// display label for a RAT object (or bare slug). Composes the 5G NSA/SA split
// and an NTN suffix.
export function label(o)
{
	let rat = (type(o) == 'string') ? o : o?.rat;

	if (rat == null || RAT[rat] == null)
		return null;

	let s = RAT[rat].label;
	let mode = (type(o) == 'object') ? o.mode : null;

	if (rat == 'nr5g')
		s = (mode == 'sa') ? '5G-SA' : (mode == 'nsa') ? '5G-NSA' : 'NR5G';

	if (type(o) == 'object' && o.ntn)
		s += ' (NTN)';

	return s;
};

// -- QMI NAS radio interface (QmiNasRadioInterface) --------------------------
// 4 GSM · 5 UMTS · 8 LTE · 9 TD-SCDMA · 12 5GNR · 1 CDMA-1x · 2 CDMA-1xEVDO
export function from_qmi_radio_if(r)
{
	switch (r) {
	case 4:  return mk('gsm', null, false, 'qmi');
	case 5:  return mk('umts', null, false, 'qmi');
	case 8:  return mk('lte', null, false, 'qmi');
	case 9:  return mk('td-scdma', null, false, 'qmi');
	case 12: return mk('nr5g', null, false, 'qmi');
	case 1:  return mk('cdma', null, false, 'qmi');
	case 2:  return mk('evdo', null, false, 'qmi');
	}

	return null;
};

// -- QMI DMS device-capability radio interface (QmiDmsRadioInterface) ---------
// Same base values as NAS for GSM(4)/UMTS(5)/LTE(8) but TDS=9 and 5GNR=**10**
// (NAS uses 12). This is the authoritative "which RATs the modem supports" list
// (DMS Get Capabilities). Returns a base RAT object.
export function from_dms_radio_if(r)
{
	switch (r) {
	case 4:  return mk('gsm', null, false, 'dms');
	case 5:  return mk('umts', null, false, 'dms');
	case 8:  return mk('lte', null, false, 'dms');
	case 9:  return mk('td-scdma', null, false, 'dms');
	case 10: return mk('nr5g', null, false, 'dms');
	case 1:  return mk('cdma', null, false, 'dms');
	case 2:  return mk('evdo', null, false, 'dms');
	}

	return null;
};

// -- QMI DSD (QmiDsdRadioAccessTechnology + QmiDsd3gppSoMask) -----------------
// rat: 1 WCDMA · 2 GERAN · 3 LTE · 4 TDSCDMA · 6 5G. so_mask bits (verified vs
// libqmi qmi-flags64-dsd.h): HSPA=1<<6 GPRS=1<<7 EDGE=1<<8 5G_NSA=1<<43
// 5G_SA=1<<44. so_mask only refines the base rat (no IoT bit exists in DSD).
const SO_HSPA  = 1 << 6;
const SO_GPRS  = 1 << 7;
const SO_EDGE  = 1 << 8;
const SO_5G_NSA = 1 << 43;
const SO_5G_SA  = 1 << 44;

export function from_dsd(rat, so_mask)
{
	let m = (type(so_mask) == 'int') ? so_mask : 0;
	let slug = null, mode = null;

	switch (rat) {
	case 1: slug = (m & SO_HSPA) ? 'hspa' : 'umts'; break;
	case 2: slug = (m & SO_EDGE) ? 'edge' : (m & SO_GPRS) ? 'gprs' : 'gsm'; break;
	case 3: slug = 'lte'; break;
	case 4: slug = 'td-scdma'; break;
	case 6: slug = 'nr5g'; mode = (m & SO_5G_SA) ? 'sa' : (m & SO_5G_NSA) ? 'nsa' : null; break;
	default: return null;
	}

	// an LTE anchor carrying the 5G-NSA service option is an NSA leg
	if (slug == 'lte' && (m & SO_5G_NSA))
		return mk('nr5g', 'nsa', false, 'dsd');

	return mk(slug, mode, false, 'dsd');
};

// -- MBIM data class + v3 subclass -------------------------------------------
// MbimDataClass bits: GPRS=1<<0 EDGE=1<<1 UMTS=1<<2 HSDPA=1<<3 HSUPA=1<<4
// LTE=1<<5 5G_NSA=1<<6 5G_SA=1<<7 (MBIMEx v2). MbimDataSubclass (v3) refines
// the 5G option but does not change the coarse RAT. Picks the highest class.
const MB_GPRS  = 1 << 0;
const MB_EDGE  = 1 << 1;
const MB_UMTS  = 1 << 2;
const MB_HSDPA = 1 << 3;
const MB_HSUPA = 1 << 4;
const MB_LTE   = 1 << 5;
const MB_5G_NSA = 1 << 6;
const MB_5G_SA  = 1 << 7;

export function from_mbim(dataclass, subclass)
{
	let c = (type(dataclass) == 'int') ? dataclass : 0;

	if (c & MB_5G_SA)  return mk('nr5g', 'sa', false, 'mbim');
	if (c & MB_5G_NSA) return mk('nr5g', 'nsa', false, 'mbim');
	if (c & MB_LTE)    return mk('lte', null, false, 'mbim');
	if (c & (MB_HSDPA | MB_HSUPA)) return mk('hspa', null, false, 'mbim');
	if (c & MB_UMTS)   return mk('umts', null, false, 'mbim');
	if (c & MB_EDGE)   return mk('edge', null, false, 'mbim');
	if (c & MB_GPRS)   return mk('gprs', null, false, 'mbim');

	return null;
};

// -- 3GPP TS 27.007 <AcT> (COPS / CxREG) -------------------------------------
// 0 GSM · 1 GSM-Compact · 2 UTRAN · 3 GSM/EGPRS · 4 UTRAN-HSDPA · 5 UTRAN-HSUPA
// · 6 UTRAN-HSPA · 7 E-UTRAN (LTE) · 8 EC-GSM-IoT · 9 E-UTRAN-NB-S1 (NB-IoT) ·
// 10 E-UTRA-5GCN · 11 NR-5GCN (SA) · 12 NG-RAN · 13 E-UTRA-NR DC (NSA). This is
// the one standardised path to NB-IoT / EC-GSM-IoT.
export function from_at_cops_act(n)
{
	switch (n) {
	case 0: case 1: return mk('gsm', null, false, 'at');
	case 3:         return mk('edge', null, false, 'at');
	case 2:         return mk('umts', null, false, 'at');
	case 4: case 5: case 6: return mk('hspa', null, false, 'at');
	case 7: case 10: return mk('lte', null, false, 'at');
	case 8:         return mk('ec-gsm-iot', null, false, 'at');
	case 9:         return mk('nb-iot', null, false, 'at');
	case 11: case 12: return mk('nr5g', 'sa', false, 'at');
	case 13:        return mk('nr5g', 'nsa', false, 'at');
	}

	return null;
};

// -- Quectel +QNWINFO / +QENG access-technology string -----------------------
// Normalises the vendor access-tech string. QNWINFO Act values include:
//   GSM/GPRS/EDGE/WCDMA/HSDPA/HSUPA/HSPA+/TDSCDMA/CDMA/EVDO/FDD LTE/TDD LTE/
//   eMTC/NB-IoT/NR5G-NSA/NR5G-SA. QENG "servingcell" uses the same vocabulary
//   (plus CAT-M / NB-IoT). RedCap is not a distinct string on stock firmware
//   (it reports NR5G-SA) — only mapped when a firmware/model hint supplies it.
function normalize_act(str, src)
{
	if (str == null)
		return null;

	// upper-case, drop quotes/whitespace and separators so "NR5G-SA",
	// "NR5G_SA", "nr5g sa" all collapse to a comparable token
	let s = uc(trim(sprintf('%s', str)));
	s = replace(s, /["' \t]/g, '');
	let k = replace(s, /[-_]/g, '');

	switch (k) {
	case 'NONE':                       return mk('none', null, false, src);
	case 'GSM':                        return mk('gsm', null, false, src);
	case 'GPRS':                       return mk('gprs', null, false, src);
	case 'EGPRS': case 'EDGE':         return mk('edge', null, false, src);
	case 'WCDMA': case 'UMTS':         return mk('umts', null, false, src);
	case 'HSDPA': case 'HSUPA': case 'HSPA': case 'HSPA+': case 'HSPAP':
	                                   return mk('hspa', null, false, src);
	case 'TDSCDMA':                    return mk('td-scdma', null, false, src);
	case 'CDMA': case 'CDMA1X': case '1XRTT': return mk('cdma', null, false, src);
	case 'EVDO': case 'HDR':           return mk('evdo', null, false, src);
	case 'LTE': case 'FDDLTE': case 'TDDLTE': case 'LTEFDD': case 'LTETDD':
	                                   return mk('lte', null, false, src);
	case 'EMTC': case 'LTEM': case 'CATM': case 'CATM1': case 'LTECATM1':
	                                   return mk('lte-m', null, false, src);
	case 'NBIOT': case 'NB1': case 'NBS1': case 'CATNB1': case 'CATNB2':
	                                   return mk('nb-iot', null, false, src);
	case 'ECGSMIOT': case 'ECGSM':     return mk('ec-gsm-iot', null, false, src);
	case 'NR5GNSA': case 'NRNSA':      return mk('nr5g', 'nsa', false, src);
	case 'NR5GSA': case 'NRSA':        return mk('nr5g', 'sa', false, src);
	case 'NR5G': case 'NR':            return mk('nr5g', null, false, src);
	case 'REDCAP': case 'NRREDCAP': case 'NR5GREDCAP':
	                                   return mk('redcap', 'sa', false, src);
	}

	return null;
};

export function from_qnwinfo(str)
{
	return normalize_act(str, 'qnwinfo');
};

export function from_qeng_act(str)
{
	return normalize_act(str, 'qeng');
};

// -- merge sources -----------------------------------------------------------
// Combine a coarse base (QMI/MBIM structured) with a finer source (AT/QNWINFO/
// QENG). The finer source WINS when it identifies something more specific — in
// particular the IoT variants, which only AT can see. Ties go to `fine` (the
// later/more specific source). Carries over an NTN flag from either side.
function score(o)
{
	if (o == null || o.rat == null)
		return -1;

	return (RAT[o.rat]?.iot ? 8 : 0) +
	       (o.mode != null ? 2 : 0) +
	       (o.ntn ? 1 : 0) +
	       ((o.rat != 'none') ? 1 : 0);
};

export function merge(base, fine)
{
	if (base == null) return fine;
	if (fine == null) return base;

	let win = (score(fine) >= score(base)) ? fine : base;
	let ntn = base.ntn || fine.ntn;

	if (win.ntn != ntn)
		win = mk(win.rat, win.mode, ntn, win.src);

	return win;
};

// -- capability summary (read-only, best-effort) -----------------------------
// caps_from(opts): a modest, honest summary of which RATs a modem supports, for
// status display. Every input is optional:
//   opts.modes      base RAT-family slugs the mode-preference allows (gsm/umts/
//                   lte/nr5g), e.g. derived from QmiNasRatModePreference bits
//   opts.iot_modes  IoT slugs the modem is set to search (Quectel QCFG iotopmode)
//   opts.observed   canonical RAT slugs actually seen in telemetry
//   opts.model      model string, for variants no query/observation reveals yet
// Returns { rats, iot_modes, ntn }. Not authoritative — a union of hints.
export function caps_from(opts)
{
	opts = opts ?? {};
	let set = {};
	let add = (s) => { if (s != null && RAT[s] != null) set[s] = true; };

	for (let s in (opts.modes ?? [])) add(s);
	for (let s in (opts.observed ?? [])) add(s);
	for (let s in (opts.iot_modes ?? [])) add(s);

	// model-string hints for variants no query/observation reveals yet
	let model = uc(sprintf('%s', opts.model ?? ''));
	if (match(model, /RG255|REDCAP|NR-?LIGHT/)) { add('nr5g'); add('redcap'); }
	if (match(model, /NTN|SATELL/)) add('ntn');

	let rats = sort(keys(set));

	return {
		rats: rats,
		iot_modes: filter(rats, (s) => RAT[s]?.iot),
		ntn: set.ntn ? true : false,
	};
};
