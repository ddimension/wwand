// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — what is installed, so a log says which build produced it.
//
// There is no version constant in this tree on purpose. The package version is
// built from PKG_SOURCE_DATE, the commit and PKG_RELEASE
// ("2026.08.30~199a2f8a-r53"), so a hand-maintained constant here would be a
// second source of truth and would start lying the first time somebody forgot
// to bump it. The package database already holds the answer and nobody has to
// keep it in step.
//
// It also answers the question that actually matters on a split install: WHICH
// backends are installed. `wwand` alone has none — a box with no wwand-qmi has
// a daemon that cannot drive a QMI modem, and that has to be visible at start,
// not deduced later from a modem that never comes up.
//
// A file-deployed tree (tar over an installed package, which is how development
// works here) has no database entry for what is actually running. Say so rather
// than reporting the version of the package the files were dropped on top of.

'use strict';

import { open, access } from 'fs';

// apk (OpenWrt >= 24.10) keeps one record per package as `K:value` lines with a
// blank line between records; `P:` is the name, `V:` the version. opkg's
// status file uses `Package:` / `Version:` in the same shape, so one parser
// with two key spellings covers both.
const DBS = [
	{ path: '/lib/apk/db/installed', name: 'P:', version: 'V:' },
	{ path: '/usr/lib/opkg/status',  name: 'Package: ', version: 'Version: ' },
];

// { '<pkg>': '<version>' } for every installed package whose name starts with
// `prefix`. Returns an empty object when no database is readable — a source
// checkout, a container, an image built without a package manager.
export function installed(prefix, fx)
{
	let rd = fx?.read ?? ((p) => {
		if (!access(p))
			return null;

		let f = open(p, 'r');

		if (!f)
			return null;

		let d = f.read('all');
		f.close();

		return d;
	});

	let out = {};

	for (let db in DBS) {
		let data = rd(db.path);

		if (data == null)
			continue;

		let cur = null;

		for (let line in split(data, '\n')) {
			if (index(line, db.name) == 0) {
				let n = substr(line, length(db.name));
				cur = (index(n, prefix) == 0) ? n : null;
			}
			else if (cur != null && index(line, db.version) == 0) {
				out[cur] = substr(line, length(db.version));
				cur = null;
			}
		}

		// first database that had anything to say wins; a box does not have two
		if (length(out))
			break;
	}

	return out;
};

// One line for the log: what this daemon is, and what it can drive.
//
// `loadable` is asked of the caller rather than probed here, because probing a
// backend means REQUIRING it, and requiring it defeats the lazy loading the
// whole package split exists for. The caller knows how to ask cheaply.
export function banner(pkgs, backends, datapaths)
{
	let self_v = pkgs?.wwand;
	let parts = [ sprintf('wwand %s', self_v ?? 'unpackaged (files deployed by hand)') ];

	// backends, with the package version when there is one — on a split install
	// a base and a backend at different releases is a real and confusing state
	let be = [];

	for (let name in backends) {
		let pkg = sprintf('wwand-%s', name);
		let v = pkgs?.[pkg];

		push(be, v ? ((v == self_v) ? name : sprintf('%s (%s)', name, v)) : name);
	}

	push(parts, sprintf('backends: %s', length(be) ? join(', ', be) : 'NONE — install wwand-qmi, -mbim or -ncm'));

	if (length(datapaths))
		push(parts, sprintf('datapath: %s', join(', ', datapaths)));

	return join('; ', parts);
};
