// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — registration-detail collector (QMI backend).
//
// Extracted from the modem.uc mega-closure (maintainability audit): gathers
// WHY the modem is (not) registered by combining QMI GET_SYSTEM_INFO, AT+CEER
// and the LTE attach profile. Pure function of the modem object: reads
// self.nas / self.wds_cfg / self.at, writes self.reg_detail, calls cb(detail).

'use strict';

import * as qmi_backend from 'wwand.qmi_backend';
import * as nasmod from 'wwand.codec.schema.nas';
import * as wdsmod from 'wwand.codec.schema.wds';

// gather WHY the modem is (not) registered: the EMM reject cause and whether
// it is stuck in limited service (camped but attach rejected). QMI and AT are
// COMPLEMENTARY here, not either/or: QMI GET_SYSTEM_INFO reliably reports the
// LTE limited-service flag but many modems leave the numeric reject cause TLV
// empty (reject_valid=0), while AT+CEER carries the clear-text cause. So we
// read QMI first and, when it lacks a numeric cause, top it up with AT+CEER.
// Result -> self.reg_detail and cb. no_recovery on the QMI read: an
// unsupported message must not climb the reboot ladder.
export function collect(self, log, cb)
{
	cb = cb ?? (() => null);

	let finish = (d) => {
		if (d && d.reject_cause != null && d.reject_text == null)
			d.reject_text = nasmod.REJECT_CAUSE[sprintf('%d', d.reject_cause)] ??
				sprintf('reject cause %d', d.reject_cause);

		if (d)
			self.reg_detail = d;

		cb(d);
	};

	// attach profile (profile 1) — the APN + auth the modem uses for the
	// autonomous LTE attach. Reported on every registration probe so a reject
	// can be diagnosed against the actual attach APN (incl. the network-default
	// blank APN case). Merges into the detail; forward-declared for add_ceer.
	let add_attach;

	add_attach = (d) => {
		let wds = self.wds_cfg;

		if (!wds)
			return finish(d);

		wds.request('GET_PROFILE_SETTINGS',
			{ profile: { type: wdsmod.PROFILE_TYPE_3GPP, index: 1 } }, (err, p) => {
			// finish() here feeds the registration-timeout continuation, which
			// can go on to call fail() — behind a teardown that is already
			// tearing this modem down
			if (err?.error == 'cancelled')
				return;

			if (!err) {
				d = d ?? {};
				d.attach = {
					apn: p.apn ?? '',
					apn_kind: (p.apn == null || p.apn == '') ? 'network default' : 'configured',
					pdp_type: p.pdp_type,
					auth: p.auth,
					username: p.username ?? null,
				};
			}

			finish(d);
		}, { no_recovery: true });
	};

	// AT+CEER clear-text cause; merges into an existing (QMI) detail
	let add_ceer = (d) => {
		if (!self.at)
			return add_attach(d);

		self.at.send('AT+CEER', (err, res) => {
			if (!err) {
				for (let l in (res?.lines ?? [])) {
					let m = match(l, /\+CEER:\s*(.+)/);

					if (m && length(trim(m[1]))) {
						d = d ?? {};
						d.reject_text = trim(m[1]);
						d.source = d.source ? (d.source + '+at') : 'at';
					}
				}
			}

			add_attach(d);
		});
	};

	if (!self.nas)
		return add_ceer(null);

	qmi_backend.get_reg_detail(self.nas, (d) => {
		if (!d)
			return add_ceer(null);

		// numeric cause already present -> skip CEER; else top up from AT+CEER.
		// Either way the attach-profile detail is appended.
		if (d.reject_cause != null)
			return add_attach(d);

		add_ceer(d);
	});
};
