// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — wwandctl's value formatters.
//
// Kept apart from wwandctl.uc so they can be tested. The CLI itself cannot be:
// it ends in a top-level command dispatch, so importing it RUNS it, which is
// why no suite ever touched a line of it. These three are pure — a status
// object in, a string out — and they are the part users actually read, so they
// are the part worth pinning.
//
// They have been wrong in the field before: printing `%d` of a missing mcc gave
// "(0/00)" on a daemon that reported the MBIM shape (ddimension/wwand#8).

'use strict';

import * as tlv from 'wwand.codec.tlv';

export function fmt_plmn(reg)
{
	let p = reg?.plmn;

	if (!p)
		return '-';

	// Two shapes: QMI reports mcc/mnc separately, MBIM reports one concatenated
	// ProviderId ("46015"). The daemon emits both from 1.6.2 on; an older one
	// under a newer wwandctl is a pairing people run, and printing %d of a
	// missing mcc gave "(0/00)" — reported as such (ddimension/wwand#8).
	let mcc = p.mcc, mnc = p.mnc, digits = p.mnc_digits ?? 2;

	// bound it: the padding below loops until this width, and the value comes
	// over ubus. 2 and 3 are the only MNC lengths 3GPP defines.
	if (digits != 2 && digits != 3)
		digits = 2;

	let id = sprintf('%s', p.id ?? '');

	if ((mcc == null || mnc == null) && match(id, /^[0-9]{5,6}$/)) {
		mcc = +substr(id, 0, 3);
		mnc = +substr(id, 3);
		digits = length(id) - 3;
	}

	// The NAME can be unusable — a firmware with no entry for the network emits
	// junk ("-5" for China Broadcasting Network, same over AT+COPS). Then the
	// number is the only thing that identifies the operator, so never drop it,
	// and never print a placeholder pair when there is no number either.
	let name = trim(p.description ?? '');
	// ucode's sprintf has no dynamic field width ('%0*d' is printed verbatim),
	// so pad by hand — and the width matters: 460/15 and 460/015 are different
	// networks.
	let mnc_s = (mnc != null) ? sprintf('%d', mnc) : null;

	while (mnc_s != null && length(mnc_s) < digits)
		mnc_s = '0' + mnc_s;

	let pair = (mcc != null && mnc_s != null)
		? sprintf('%d/%s', mcc, mnc_s) : null;

	if (name && pair)
		return sprintf('%s (%s)', name, pair);

	return pair ?? (length(name) ? name : '-');
};

export function fmt_sig(sig)
{
	let parts = [];
	// -32768 & friends are "not measured" sentinels, never real dBm
	let ok = (v) => v != null && v > -140;
	// whole dBm off the signal TLV, one decimal once the serving cell's own
	// measurement has been overlaid (modem_common.overlay_serving_signal) —
	// %d would print -60.9 as -60
	let dec = (v) => (v == int(v)) ? sprintf('%d', v) : sprintf('%.1f', v);

	if (ok(sig?.nr5g?.rsrp))
		push(parts, sprintf('NR rsrp %d dBm snr %.1f dB', sig.nr5g.rsrp, (sig.nr5g.snr ?? 0) / 10.0));

	if (ok(sig?.lte?.rsrp))
		push(parts, sprintf('LTE rsrp %s dBm rsrq %s dB',
			dec(sig.lte.rsrp), dec(sig.lte.rsrq ?? 0)));
	else if (ok(sig?.lte?.rssi))
		push(parts, sprintf('LTE rssi %s dBm', dec(sig.lte.rssi)));

	if (ok(sig?.wcdma?.rssi))
		push(parts, sprintf('WCDMA rssi %d dBm', sig.wcdma.rssi));

	if (!length(parts) && ok(sig?.rsrp))
		push(parts, sprintf('rsrp %d dBm', sig.rsrp));

	if (!length(parts) && ok(sig?.rssi))
		push(parts, sprintf('rssi %d dBm', sig.rssi));

	return length(parts) ? join(', ', parts) : '-';
};

// MbimDataSubclass -> words (libmbim 1.32.0 mbim-enums.h:1867-1872). A bitmask:
// the modem's own statement of how 5G is attached, where `m.rat` is derived
// from the shape of the cell environment.
//
// DUPLICATED ON PURPOSE, and the duplicate is named so it can be kept in step:
// luci-app-wwand `htdocs/luci-static/resources/wwand/format.js` carries the
// same two tables (DATA_SUBCLASS, FREQUENCY_RANGE) because a browser module and
// a ucode module cannot share one. The words must MATCH — a CLI and a page that
// disagree about the same value are worse than either alone, and they already
// drifted once (the CLI said "FR2 (mmWave)" where the page said "FR2 (mmWave,
// 24 GHz and above)"). Change one, change both.
const DATA_SUBCLASS = [
	[ 1, 'ENDC' ],      // 5G on an LTE anchor — non-standalone
	[ 2, '5G NR' ],     // standalone
	[ 4, 'NEDC' ],
	[ 8, 'ELTE' ],
	[ 16, 'NGENDC' ],
];

export function data_subclass(v)
{
	if (v == null || v == 0)
		return null;

	let out = [];
	let rest = v;

	for (let p in DATA_SUBCLASS)
		if (v & p[0]) {
			push(out, p[1]);
			rest &= ~p[0];
		}

	// AN UNKNOWN BIT IS REPORTED, INCLUDING BESIDE KNOWN ONES. The first
	// version only fell back to hex when NOTHING was recognised, so 0x21 came
	// back as a bare "ENDC" and the bit this table does not know was dropped
	// silently — which is the one case where saying nothing is worst, because a
	// modem setting it is telling us something new.
	if (rest)
		push(out, sprintf('0x%x', rest));

	return length(out) ? join(' + ', out) : null;
};

// FR1 is sub-6 GHz, FR2 is mmWave (3GPP TS 38.104 §5.2). Bitmask again —
// aggregation can span both.
export function frequency_range(v)
{
	if (v == null || v == 0)
		return null;

	let out = [];

	if (v & 1) push(out, 'FR1 (sub-6 GHz)');
	if (v & 2) push(out, 'FR2 (mmWave, 24 GHz and above)');

	// same rule as the subclass above: a bit outside FR1/FR2 is carried, not
	// swallowed by the two that were recognised
	let rest = v & ~3;

	if (rest)
		push(out, sprintf('0x%x', rest));

	return length(out) ? join(' + ', out) : null;
};

// The attach-time tracking area. MbimTai gives PlmnMcc and PlmnMnc as bare
// guint16 and NO digit count — so the MNC's width is not recoverable from it,
// and this is exactly where zero-padding to two would invent an operator:
// 310/030 and 310/30 are different networks. The registration's PLMN does carry
// `mnc_digits`, so when it names the same network its width is borrowed; when
// it does not, the number is printed as the modem gave it rather than padded on
// a guess.
export function tai_text(tai, plmn)
{
	// EVERY PART OR NONE. A half-filled TAI rendered as `310/0 tac 0`, which
	// looks like a tracking area and is not one — zero is not an honest stand-in
	// for a field the modem did not send.
	if (tai?.mcc == null || tai?.mnc == null || tai?.tac == null)
		return null;

	let mnc = tai.mnc;
	let digits = (plmn?.mcc == tai.mcc && plmn?.mnc == mnc) ? plmn?.mnc_digits : null;
	let txt = sprintf('%d', mnc);

	while (digits != null && length(txt) < digits)
		txt = '0' + txt;

	return sprintf('%d/%s tac %d', tai.mcc, txt, tai.tac);
};

// The MBIMEx extras as one line, or null when there is nothing to say — which
// is every non-MBIMEx backend, so the caller prints no row at all rather than a
// placeholder.
//
// THE DECISION LIVES HERE, not in the printf. wwandctl.uc is a script with a
// top-level dispatch and no seam a test can reach; everything in it that judges
// rather than prints belongs in this module, which is where reg_text and
// fmt_sig already are. A row whose logic sits in the unreachable half is a row
// nothing can hold shut — reverting it would have left every test green.
export function packet_service_text(ps, plmn)
{
	// a scalar here is not a packet-service object, and reading a property off
	// one THROWS in ucode — which would abort the CLI mid-status
	if (type(ps) != 'object')
		return null;

	let bits = [];
	let fr = frequency_range(ps.frequency_range);

	if (fr)
		push(bits, fr);

	let tai = tai_text(ps.tai, plmn);

	if (tai)
		push(bits, sprintf('attach TAI %s', tai));

	return length(bits) ? join(' · ', bits) : null;
};

export function reg_text(m)
{
	let r = m.registration;

	if (m.state == 'SIM_BLOCKED')
		return sprintf('SIM blocked: %s%s', m.sim_block?.reason ?? '?',
			m.sim_block?.retries != null ? sprintf(' (%d retries left)', m.sim_block.retries) : '');

	if (r?.registration == 1 || (type(r?.radio_ifs) == 'array' && length(r.radio_ifs))) {
		// the modem's own word for how 5G is attached, beside the derived one
		let sub = data_subclass(m.packet_service?.data_subclass);

		return sprintf('%s%s%s%s', fmt_plmn(r), r.roaming ? ', roaming' : '',
			m.rat ? sprintf(', %s', m.rat) : '',
			sub ? sprintf(' · %s', sub) : '');
	}

	// WHY IT IS NOT REGISTERED, and the attach is a second, independent answer
	// to that: a wrong attach APN registers the radio and never attaches, so the
	// reject cause is empty and only the attach carries the reason. The CLI said
	// a bare "not registered" in exactly the case somebody runs it to find out.
	let why = [];

	if (m.registration_detail?.reject_text)
		push(why, m.registration_detail.reject_text);

	let ai = m.attach_info;

	if (ai?.nw_error_text)
		push(why, sprintf('attach: %s', ai.nw_error_text));
	else if (ai?.ceer_text)
		push(why, sprintf('attach: %s', ai.ceer_text));
	else if (ai?.state_text)
		push(why, sprintf('attach: %s', ai.state_text));

	return length(why)
		? sprintf('not registered: %s', join(' · ', why))
		: 'not registered';
};

// --- collectd exec feed ------------------------------------------------------

// The cadence floor, and the reason for it. `modem_signal` keeps wwand's
// adaptive fast-telemetry loop warm (daemon.uc calls modem.watch()); that loop
// polls the modem at 1 Hz and decays 6 s after the last request
// (modem_common.uc:702-703). One sample therefore costs ~6 s of 1 Hz modem
// traffic, so the duty cycle is 6/interval: 10 % at 60 s, 20 % at 30 s, 60 % at
// 10 s — and at 6 s or below the loop NEVER decays and the modem is polled
// around the clock. A global `Interval 10` in collectd.conf would do exactly
// that without anyone noticing, so it is raised rather than obeyed.
export const COLLECTD_MIN_INTERVAL = 30;

// The recovery ladder in one line, or null when there is nothing to say (armed
// and no failed attempts). `ubus call wwand status` has carried this since the
// arming gate existed, but the CLI people paste into issues never printed it —
// so a reporter told to "look at wwandctl status" for `unarmed_reset` found no
// such line (evidence: ddimension/wwand#40). The unarmed case names the ONE
// thing that can still happen on its own and when, because "not armed" alone
// reads as "nothing will ever happen", which on a board with a reset line is
// no longer true.
export function recovery_text(r)
{
	if (type(r) != 'object')
		return null;

	let n = +(r.attempts ?? 0);

	if (r.armed) {
		if (!n)
			return null;

		let nx = r.next;

		return sprintf('armed · %d failed attempt%s%s', n, (n == 1) ? '' : 's',
			nx ? sprintf(' · next: %s at %d%s', nx.action, nx.at,
			             nx.in ? sprintf(' (in %d)', nx.in) : '') : '');
	}

	let at = null;

	for (let rg in (r.rungs ?? []))
		if (rg.action == 'usb_repower')
			at = rg.at;

	let tail = (r.unarmed_reset == 'available')
		? ((at != null && n < at)
			? sprintf(' · reset-line pulse at attempt %d (in %d)', at, at - n)
			: (at != null)
				// past the threshold and not yet used — a restored counter can
				// land here — so it fires on the NEXT failure, not "at 24"
				? ' · reset-line pulse on the next failed attempt'
				: ' · reset-line pulse available')
		: (r.unarmed_reset == 'spent')
			? ' · reset-line pulse already used this outage'
			: ' · nothing physical until the control channel answers';

	return sprintf('NOT armed (never answered in this protocol) · %d failed attempt%s%s',
		n, (n == 1) ? '' : 's', tail);
};

export function collectd_interval(want)
{
	let n = +(want ?? 0);

	if (n != n || n <= 0)          // absent or unparsable -> collectd's own default
		return 60;

	return (n < COLLECTD_MIN_INTERVAL) ? COLLECTD_MIN_INTERVAL : int(n);
};

// One modem's PUTVAL lines.
//
// Types checked against collectd 5.12.0 types.db:
//   signal_power   GAUGE U:0    dBm/dB, always <= 0   (rsrp, rscp, rssi, rsrq, ecio)
//   temperature    GAUGE U:U
//   gauge          GAUGE U:U
// SINR is deliberately NOT `signal_quality` (min 0, would drop every negative
// reading) and NOT `signal_power` (max 0, would drop every positive one): it
// runs roughly -20..+30 dB, so either bound silently discards half its range.
//
// `-32768` is the i16 "not measured" sentinel, filtered on the RAW value with
// the codec's own rule rather than a dBm floor — snr is in 0.1 dB, so a genuine
// -15 dB is -150 and a display heuristic like fmt_sig's `> -140` would throw it
// away. A sentinel reaching RRD is worse than no value at all: it is a real
// data point at -32768 that flattens every graph sharing its scale.
// carrier_counts(cells): aggregated carriers and their summed bandwidth, per
// leg -> { lte: {n, mhz}, nr: {n, mhz} }.
//
// THE SAME RULE THE LuCI GRAPH DRAWS (luci-app-wwand format.js carrierSample),
// deliberately, because a number in an RRD and the line on the status page
// disagreeing is worse than either being absent: an SCC that is configured but
// not activated carries nothing and is not counted; a modem that reports no
// carrier list at all still has its serving cell; and the 5G leg counts only
// while it is actually serving, since a 5G-capable modem parked on LTE still
// reports the NR band it can see (HW-observed on an RG502QEA, 2026-09-12).
export function carrier_counts(cells)
{
	let out = { lte: { n: 0, mhz: 0, have_mhz: false },
	            nr:  { n: 0, mhz: 0, have_mhz: false } };
	let srv = cells?.serving ?? {};

	for (let c in (cells?.ca ?? [])) {
		// `rat` where the producer sets it; the role text is the fallback,
		// because the Fibocom telemetry has said 'PCC NR' in the role since
		// before there was a `rat` field and an installed base still answers
		// that way. Same two-step in the LuCI graph, deliberately.
		let leg = out[(c?.rat == 'nr' ||
		               (c?.rat == null && index(uc(c?.role ?? ''), 'NR') >= 0)) ? 'nr' : 'lte'];

		if (c?.role == 'SCC' && c?.state != null && c.state != 2)
			continue;

		leg.n++;

		if (c?.bandwidth_mhz != null) {
			leg.mhz += c.bandwidth_mhz;
			leg.have_mhz = true;
		}
	}

	if (!out.lte.n && srv.lte) {
		out.lte.n = 1;

		if (srv.lte.bandwidth_mhz != null) {
			out.lte.mhz = srv.lte.bandwidth_mhz;
			out.lte.have_mhz = true;
		}
	}

	if (!out.nr.n && srv.nr && cells?.dsd?.nr) {
		out.nr.n = 1;

		if (srv.nr.bandwidth_mhz != null) {
			out.nr.mhz = srv.nr.bandwidth_mhz;
			out.nr.have_mhz = true;
		}
	}

	return out;
};

export function collectd_lines(host, modem, sig, m, interval, cells)
{
	let out = [];

	// THE SENTINEL TYPE IS PER FIELD, not per struct. QMI decodes the LTE/WCDMA/
	// GSM RSSI and the LTE RSRQ as i8 (sentinel -128) and rsrp/snr/ecio/
	// nr5g_rsrq as i16 (sentinel -32768) — see codec/schema/nas.uc:108-112. A
	// blanket i16 test therefore lets an unavailable -128 through as a genuine
	// -128 dBm reading, which is the exact failure this filter exists to
	// prevent. (-128 is below any real RSSI floor, so the i8 test costs nothing
	// on the AT/MBIM paths where the value was parsed from text rather than
	// decoded from a TLV.)
	// The widths, straight from codec/schema/nas.uc: GET_SIGNAL_INFO decodes the
	// LTE block as { rssi i8, rsrq i8, rsrp i16, snr i16 } (:110), WCDMA as
	// { rssi i8, ecio i16 } (:109), gsm_rssi as i8 (:108), and everything 5G as
	// i16 (:112 and the NR cell blocks). Guessing with a fallback does not work
	// — an i8 sentinel of -128 passes the i16 test and comes out as a reading.
	const WIDTH = {
		lte:   { rssi: 'i8',  rsrq: 'i8',  rsrp: 'i16', snr: 'i16', ecio: 'i16' },
		wcdma: { rssi: 'i8',  rsrq: 'i8',  rsrp: 'i16', snr: 'i16', ecio: 'i16' },
		nr5g:  { rssi: 'i16', rsrq: 'i16', rsrp: 'i16', snr: 'i16', ecio: 'i16' },
	};

	let val = (v, w) => tlv.is_unavailable(v, w ?? 'i16') ? null : v;

	let put = (type, inst, v) => {
		if (v == null)
			return;

		push(out, sprintf('PUTVAL "%s/wwand-%s/%s-%s" interval=%d N:%s',
			host, modem, type, inst, interval, sprintf('%.3f', v)));
	};

	// one series per radio technology, never a single line that changes meaning
	// when the modem switches — the same rule the LuCI graph follows
	let tagged = 0;

	for (let rat, b in { lte: sig?.lte, nr5g: sig?.nr5g, wcdma: sig?.wcdma }) {
		if (!b)
			continue;

		let w = WIDTH[rat] ?? {};

		put('signal_power', sprintf('rsrp_%s', rat), val(b.rsrp, w.rsrp) ?? val(b.rscp, w.rsrp));
		put('signal_power', sprintf('rsrq_%s', rat), val(b.rsrq, w.rsrq));
		put('signal_power', sprintf('ecio_%s', rat), val(b.ecio, w.ecio));

		let rssi = val(b.rssi, w.rssi);

		if (rssi != null) {
			put('signal_power', sprintf('rssi_%s', rat), rssi);
			tagged++;
		}

		let snr = val(b.snr, w.snr);

		if (snr != null)
			put('gauge', sprintf('sinr_%s', rat), snr / 10.0);
	}

	// 2G has no struct of its own — just a band RSSI beside the others
	let gsm = val(sig?.gsm_rssi, 'i8');

	if (gsm != null) {
		put('signal_power', 'rssi_gsm', gsm);
		tagged++;
	}

	// the untagged band RSSI, and only when NO radio claimed one — counted
	// rather than spot-checked against two RATs, so a technology added later
	// cannot let the same measurement land in two files under two names
	if (!tagged)
		put('signal_power', 'rssi', val(sig?.rssi, 'i8'));

	// NR RSRQ arrives top-level on some firmware rather than inside nr5g
	put('signal_power', 'rsrq_nr5g', val(sig?.nr5g_rsrq, 'i16'));

	// aggregation, so the RRD carries what the live graph only keeps for the
	// minutes a browser is open — the long-term half of ddimension/wwand#14.
	// `cells` is optional: a caller that does not fetch it simply records no
	// aggregation, rather than recording a zero that would read as "stopped
	// aggregating".
	if (cells != null) {
		let ca = carrier_counts(cells);

		for (let leg, v in ca) {
			if (v.n)
				put('gauge', sprintf('carriers_%s', leg), v.n);

			if (v.have_mhz)
				put('gauge', sprintf('bandwidth_%s', leg), v.mhz);
		}
	}

	// from status(), which costs no modem traffic at all
	put('temperature', 'modem', m?.temperature?.celsius);
	put('gauge', 'registered', (m?.state == 'READY') ? 1 : 0);
	put('gauge', 'attempts', +(m?.attempts ?? 0));
	put('gauge', 'proto_errors', +(m?.proto_errors ?? 0));

	return out;
};

// Cell/frequency lock read-back for the CLI, mirroring luci-app-wwand's
// fmt.fmtLocks (format.js:645) so the two surfaces spell the same thing.
//
// The CLI printed `%J` of whatever the daemon held, which on an EC200A came out
// as `locks lte={ "enabled": false, "values": [ 0, 0 ] }` — raw JSON at the
// user, and worse, a lock reported on a modem that is not locked to anything
// (ddimension/wwand#19). A DISARMED lock is not a lock: "locks" should not list
// something the modem is not locked to.
//
// Daemon shape: { lte: { enabled, values: [earfcn, pci, …] },
//                 nr5g: { enabled, values: [pci, arfcn, scs, band, …] } }
// Rendered in the colon spelling the lock editor accepts. Returns null when
// nothing is armed, so the caller can omit the line entirely.
//
// The fidelity claim is about THE SHAPES THE DAEMON EMITS, not about matching
// JavaScript's string coercion for shapes that cannot arrive: a review noted
// that a composite inside `values` would print `[ 1, 2 ]` here and `1,2` there,
// and an object `{ }` against `[object Object]`. Both are unreachable over
// ubus/JSON from this producer, and reproducing `[object Object]` would be
// faithful to JS while being worse to read. Not done on purpose.
export function fmt_locks(locks)
{
	// a lock container is an object; a scalar here is not "no locks", it is a
	// caller error, and reading locks.lte off it would throw rather than say so
	if (!locks || type(locks) != 'object')
		return null;

	let out = [];

	let group = (l, width, label) => {
		if (!l)
			return;

		// NOTE the object test comes first: unlike the JS this mirrors, ucode
		// THROWS on a property read off ANY scalar — boolean, integer, double,
		// string — so `l.enabled` on the bare `{ lte: true }` shape is not
		// merely undefined, it ends the process.
		//
		// The check itself is loose on purpose: the daemon emits a real boolean
		// today, but an `enabled: 0` from a future producer must skip too.
		if (type(l) == 'object' && l.enabled != null && !l.enabled)
			return;

		// the payload arrives in more shapes than { values: [...] }; reading
		// only `.values` would render every other one as a bare "armed" and
		// silently drop what the lock actually holds.
		let v;

		if (l === true)
			v = [];
		else if (type(l) == 'array')
			v = l;
		else if (type(l) != 'object')
			v = [ l ];
		else if (type(l.values) == 'array')
			v = l.values;
		else if (l.values != null)
			v = [ l.values ];
		else {
			v = [];
			for (let kk, vv in l)
				if (kk != 'enabled')
					push(v, sprintf('%s=%s', kk, vv));
			width = 0;   // k=v pairs are not positional
		}

		let items = [];

		if (width && length(v) && length(v) % width == 0)
			for (let i = 0; i < length(v); i += width)
				push(items, join(':', slice(v, i, i + width)));
		else if (length(v))
			push(items, join(', ', v));

		push(out, length(items) ? sprintf('%s %s', label, join(', ', items))
		                        : sprintf('%s armed', label));
	};

	group(locks.lte, 2, 'LTE');
	group(locks.nr5g, 4, 'NR5G');

	// anything the daemon grows later is shown rather than silently dropped,
	// just without a specific spelling
	for (let k, v in locks)
		if (k != 'lte' && k != 'nr5g')
			group(v, 0, k);

	return length(out) ? join(' · ', out) : null;
};
