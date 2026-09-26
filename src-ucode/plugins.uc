// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// Optional daemon plugins: features that ship in their own packages and hook
// into the daemon without the core knowing them.
//
// A plugin is a plain script at /usr/share/ucode/wwand/plugins/<name>.uc
// (require()d, like the backend shims) that returns
//
//   { name,
//     options: [ ... ],      // wwand_modem options it reads. They are passed
//                            // to it raw as entry.ext, never warned about as
//                            // unknown, and never restart the modem on reload.
//     create(deps) -> {      // all hooks optional
//       tick(ref, ext),                 // every 10 s, per modem
//       esim_guard(ref, op, ext),       // -> null, or { reason } to refuse a
//                                       //    card-changing modem_esim op
//       ops: { <op>: (ref, ext, args, cb) },   // ubus modem_plugin
//       read_ops: [ 'status', ... ],           // ...and which of them the
//                                              // read-only twin may call
//     } }
//
// Why a registry and not direct imports: the core must not depend on a
// feature package, and a plugin must not need a core change to exist. What a
// plugin needs from the daemon comes in through deps (see install below);
// nothing reaches into daemon internals.

'use strict';

import * as fs from 'fs';

const PLUGIN_DIR = '/usr/share/ucode/wwand/plugins';

let found = null;

// Scan once per process. main.uc needs the option names before the daemon
// exists (to parse the config) and the daemon needs the same modules later;
// both import this module, so they share the one scan. A plugin that fails to
// load is skipped with a note rather than taking the daemon down: it is an
// optional package, and the core runs without it.
export function list(dir, req, notes)
{
	if (found != null && dir == null)
		return found;

	let out = [];
	let d = dir ?? PLUGIN_DIR;
	let load = req ?? ((n) => require(sprintf('wwand.plugins.%s', n)));

	for (let f in sort(fs.lsdir(d) ?? [])) {
		let m = match(f, /^([a-z0-9_]+)\.uc$/);

		if (!m)
			continue;

		let mod = null;

		try { mod = load(m[1]); }
		catch (e) { push(notes ?? [], sprintf('plugin %s: failed to load (%s)', m[1], e)); }

		if (type(mod?.create) == 'function')
			push(out, { name: mod.name ?? m[1], options: mod.options ?? [], mod: mod });
	}

	if (dir == null)
		found = out;

	return out;
};

// every wwand_modem option some installed plugin reads
export function option_names(plugins)
{
	let out = [];

	for (let p in (plugins ?? list()))
		for (let o in p.options)
			if (index(out, o) < 0)
				push(out, o);

	return out;
};

// Hook the plugins into the daemon object. o: { log, plugins (list()), deps }
// where deps is what every plugin's create() receives besides log.
export function install(self, o)
{
	let log = o.log;
	let instances = null;

	let active = () => {
		if (instances == null) {
			instances = [];

			for (let p in (o.plugins ?? list())) {
				let inst = null;

				try { inst = p.mod.create({ ...o.deps, log: log }); }
				catch (e) { log('warn', sprintf('plugin %s: create failed (%s)', p.name, e)); }

				if (inst)
					push(instances, { name: p.name, inst: inst });
			}
		}

		return instances;
	};

	let ext_of = (ref) => self.modems[ref]?.ext ?? {};

	self.plugins_tick = function() {
		for (let name, entry in self.modems)
			for (let p in active())
				if (type(p.inst.tick) == 'function')
					p.inst.tick(name, entry?.ext ?? {});
	};

	// Rows plugins add to a modem's status: [ { plugin, label, text, level } ],
	// level 'ok' | 'warn' | 'error'. A plugin's optional `status(ref, ext)`
	// returns one row, an array of them, or null. SYNCHRONOUS AND CHEAP:
	// status() is what LuCI polls every second. A plugin that throws costs its
	// own row, not the status answer — and is logged once, not every second.
	let status_failed = {};

	self.plugins_status = function(ref) {
		let out = [];

		for (let p in active()) {
			if (type(p.inst.status) != 'function')
				continue;

			let r = null;

			try { r = p.inst.status(ref, ext_of(ref)); }
			catch (e) {
				if (!status_failed[p.name])
					log('warn', sprintf('plugin %s: status failed (%s)', p.name, e));
				status_failed[p.name] = true;
				continue;
			}

			for (let row in ((type(r) == 'array') ? r : (r ? [ r ] : [])))
				if (type(row) == 'object' && row.label != null && row.text != null)
					push(out, { plugin: p.name, label: sprintf('%s', row.label),
					            text: sprintf('%s', row.text),
					            level: (index([ 'ok', 'warn', 'error' ], row.level) >= 0) ? row.level : 'ok' });
		}

		return out;
	};

	// Where the modem's active card really is, when a plugin put it there:
	// `card_source(ref, ext)` -> a place name (a reader), or null. The SIM
	// inventory files a remote card under it instead of the modem's slot.
	self.plugins_card_source = function(ref) {
		for (let p in active()) {
			if (type(p.inst.card_source) != 'function')
				continue;

			let r = null;

			try { r = p.inst.card_source(ref, ext_of(ref)); } catch (e) { r = null; }

			if (type(r) == 'string' && length(r))
				return r;
		}

		return null;
	};

	// The first plugin that manages this card for this operation, or null.
	// Loading the plugins here is deliberate: a guard that answers "free"
	// because nothing happened to load them yet would let a change through.
	self.esim_guard = function(ref, op) {
		for (let p in active()) {
			if (type(p.inst.esim_guard) != 'function')
				continue;

			let g = p.inst.esim_guard(ref, op, ext_of(ref));

			if (g)
				return { by: p.name, reason: g.reason };
		}

		return null;
	};

	// ubus modem_plugin { modem, plugin, op, args } — and the read-only twin,
	// which passes read_only and may only reach a plugin's read_ops
	self.modem_plugin = function(ref, plugin, op, args, cb, read_only) {
		let p = filter(active(), (x) => x.name == plugin)[0];

		if (!p)
			return cb({ error: 'no_such_plugin', plugin: plugin });

		let fn = p.inst.ops?.[op];

		if (type(fn) != 'function')
			return cb({ error: 'invalid_op', op: op });

		if (read_only && index(p.inst.read_ops ?? [], op) < 0)
			return cb({ error: 'permission_denied', detail: sprintf('%s is not a read operation', op) });

		if (!self.modems[ref]?.modem)
			return cb({ error: 'no_such_modem', ref: ref });

		fn(ref, ext_of(ref), args ?? {}, cb);
	};
};
