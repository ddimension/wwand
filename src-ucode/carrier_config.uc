// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — carrier configuration (MBN) over QMI PDC.
//
// Which carrier config the modem runs, what else it has, and switching between
// them. Read-mostly: wwand selects among the blobs the vendor already shipped
// and never writes or deletes one (see the note at the end of pdc.uc).
//
// EVERY call here is token-and-indication, not request-and-response. The
// request is acknowledged nearly empty and the answer arrives later on an
// indication carrying the same token, so each op parks a waiter and a timeout.
// Reading the response as the answer yields an empty result that looks real —
// the same trap as the long-APDU path, and the reason both are written the same
// way.

'use strict';

import * as uloop from 'uloop';
import * as hexmod from 'wwand.codec.hex';
import * as pdcmod from 'wwand.codec.schema.pdc';

const OP_TIMEOUT_MS = 15000;

// A config id is an opaque blob the modem uses as a name — not text, and it
// must round-trip byte for byte. Hex is how it crosses ubus and how an operator
// names one back to us.
const arr_to_hex = hexmod.arr_to_hex;

function hex_to_arr(s)
{
	let out = [];

	for (let i = 0; i + 1 < length(s ?? ''); i += 2)
		push(out, hex(substr(s, i, 2)));

	return out;
};

// One shared waiter table per modem, keyed by token. The handlers are installed
// once when the client comes up, for the same reason the APDU ones are: an
// indication can arrive before the caller has finished reacting to the
// acknowledgement, and there has to be something listening.
export function install(modem)
{
	if (!modem.pdc || modem._pdc_waits)
		return;

	modem._pdc_waits = {};
	modem._pdc_token = 0;
	// which incarnation of this modem these waiters belong to
	modem._pdc_gen = modem._gen;

	let deliver = (data) => {
		let key = sprintf('%u', data?.token ?? 0);
		let w = modem._pdc_waits[key];

		if (!w)
			return;   // not ours, or already completed or timed out

		w.timer?.cancel();
		delete modem._pdc_waits[key];

		// PDC reports failure on the INDICATION, not on the request — a
		// non-zero result here is the operation failing, however cheerfully the
		// request was acknowledged.
		if (data.result != null && data.result != 0)
			return w.cb({ error: 'pdc', result: data.result }, null);

		w.cb(null, data);
	};

	for (let name in [ 'LIST_CONFIGS_IND', 'GET_SELECTED_CONFIG_IND',
	                   'GET_CONFIG_INFO_IND', 'SET_SELECTED_CONFIG_IND' ])
		modem.pdc.on(name, deliver);
};

// issue one token-carrying request and wait for its indication
function ask(modem, name, args, cb)
{
	if (!modem.pdc || !modem._pdc_waits)
		return cb({ error: 'no_pdc_client' }, null);

	// The client is destroyed BEFORE the table is nulled, so between those two
	// the check above still passes while every request answers `cancelled`.
	// The lifecycle generation is what distinguishes them — captured when the
	// waiters were installed, bumped first thing in teardown.
	if (modem._gen != modem._pdc_gen)
		return cb({ error: 'cancelled' }, null);

	let token = ++modem._pdc_token;
	let key = sprintf('%u', token);
	let done = false;
	let finish = (e, v) => {
		if (done)
			return;

		done = true;
		cb(e, v);
	};

	modem._pdc_waits[key] = {
		cb: finish,
		// nothing else can fail this: the answer is pushed, so a modem that
		// simply never indicates would otherwise hang the caller for good
		timer: uloop.timer(OP_TIMEOUT_MS, () => {
			delete modem._pdc_waits[key];
			finish({ error: 'pdc_timeout', op: name }, null);
		}),
	};

	modem.pdc.request(name, { ...args, token: token }, (err) => {
		// the acknowledgement failing IS terminal — no indication will follow
		if (err) {
			modem._pdc_waits[key]?.timer?.cancel();
			delete modem._pdc_waits[key];
			finish(err, null);
		}
	}, { no_recovery: true });
};

// what the modem is running now, and what is queued for the next reset
export function selected(modem, cb)
{
	ask(modem, 'GET_SELECTED_CONFIG',
		{ config_type: pdcmod.CONFIG_TYPE_DEVICE }, (err, d) => {
			if (err)
				return cb(err, null);

			cb(null, {
				active:  length(d?.active_id ?? []) ? arr_to_hex(d.active_id) : null,
				// A switch is not live until the modem resets. Reporting it as
				// active would tell an operator the change took effect when the
				// radio is still running the old one.
				pending: length(d?.pending_id ?? []) ? arr_to_hex(d.pending_id) : null,
			});
		});
};

// every carrier config on the modem, each with its description and version
export function list(modem, cb)
{
	ask(modem, 'LIST_CONFIGS',
		{ config_type: pdcmod.CONFIG_TYPE_DEVICE }, (err, d) => {
			if (err)
				return cb(err, null);

			let entries = filter(d?.configs ?? [],
				(c) => c.config_type == pdcmod.CONFIG_TYPE_DEVICE);

			// The list is hashes. Ask each one what it calls itself, because a
			// list of opaque blobs is not something anyone can choose from.
			// Sequential and best-effort: a config whose info the modem refuses
			// still appears, by id.
			let out = [], i = 0, step;

			step = () => {
				if (i >= length(entries))
					return cb(null, out);

				let c = entries[i++];

				ask(modem, 'GET_CONFIG_INFO',
					{ config: { config_type: c.config_type, id: c.id } }, (ie, info) => {
						// A timeout ends the WALK, not just this entry. A modem
						// that stops indicating would otherwise cost 15 s per
						// remaining config — ten of them is two and a half
						// minutes with the ubus caller waiting on all of it.
						// Any other error is per-config and tolerated below.
						if (ie?.error == 'pdc_timeout')
							return cb(null, out);

						// A teardown destroys the client and reports `cancelled`
						// SYNCHRONOUSLY while `self.pdc` and the waiter table are
						// still live, so stepping on submits another request into
						// the destruction. Terminal, like the timeout.
						if (ie?.error == 'cancelled' || ie?.error == 'no_pdc_client')
							return cb(ie, null);

						push(out, {
							id: arr_to_hex(c.id),
							description: ie ? null : (info?.description ?? null),
							version: ie ? null : (info?.version ?? null),
							size: ie ? null : (info?.total_size ?? null),
						});

						step();
					});
			};

			step();
		});
};

// select one. Takes effect on the next modem reset — say so rather than
// implying the radio changed underneath the caller.
export function select(modem, id_hex, cb)
{
	let id = hex_to_arr(id_hex);

	if (!length(id))
		return cb({ error: 'bad_config_id' }, null);

	ask(modem, 'SET_SELECTED_CONFIG',
		{ config: { config_type: pdcmod.CONFIG_TYPE_DEVICE, id: id } }, (err) => {
			if (err)
				return cb(err, null);

			cb(null, { selected: id_hex, apply: 'modem_reset',
			           note: 'takes effect after a modem reset' });
		});
};
