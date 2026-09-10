// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — wwandctl's value formatters.
//
// Extracted from wwandctl.uc so they can be tested. The CLI itself cannot be:
// it ends in a top-level command dispatch, so importing it RUNS it, which is
// why no suite ever touched a line of it. These three are pure — a status
// object in, a string out — and they are the part users actually read, so they
// are the part worth pinning.
//
// They have been wrong in the field before: printing `%d` of a missing mcc gave
// "(0/00)" on a daemon that reported the MBIM shape (ddimension/wwand#8).

'use strict';

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
}

export function fmt_sig(sig)
{
	let parts = [];
	// -32768 & friends are "not measured" sentinels, never real dBm
	let ok = (v) => v != null && v > -140;

	if (ok(sig?.nr5g?.rsrp))
		push(parts, sprintf('NR rsrp %d dBm snr %.1f dB', sig.nr5g.rsrp, (sig.nr5g.snr ?? 0) / 10.0));

	if (ok(sig?.lte?.rsrp))
		push(parts, sprintf('LTE rsrp %d dBm rsrq %d dB', sig.lte.rsrp, sig.lte.rsrq ?? 0));
	else if (ok(sig?.lte?.rssi))
		push(parts, sprintf('LTE rssi %d dBm', sig.lte.rssi));

	if (ok(sig?.wcdma?.rssi))
		push(parts, sprintf('WCDMA rssi %d dBm', sig.wcdma.rssi));

	if (!length(parts) && ok(sig?.rsrp))
		push(parts, sprintf('rsrp %d dBm', sig.rsrp));

	if (!length(parts) && ok(sig?.rssi))
		push(parts, sprintf('rssi %d dBm', sig.rssi));

	return length(parts) ? join(', ', parts) : '-';
}

export function reg_text(m)
{
	let r = m.registration;

	if (m.state == 'SIM_BLOCKED')
		return sprintf('SIM blocked: %s%s', m.sim_block?.reason ?? '?',
			m.sim_block?.retries != null ? sprintf(' (%d retries left)', m.sim_block.retries) : '');

	if (r?.registration == 1 || (type(r?.radio_ifs) == 'array' && length(r.radio_ifs)))
		return sprintf('%s%s%s', fmt_plmn(r), r.roaming ? ', roaming' : '',
			m.rat ? sprintf(', %s', m.rat) : '');

	return m.registration_detail?.reject_text
		? sprintf('not registered: %s', m.registration_detail.reject_text)
		: 'not registered';
}
