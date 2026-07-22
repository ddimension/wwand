// wwand — AT command engine and AT port discovery.
//
// Replaces comgt/gcom: a serialized command queue over a raw tty with
// line assembly, echo filtering, OK/ERROR/+CME terminators and timeouts.
//
// The engine operates on a transport object { write(data), on_data(cb),
// drain(), close() } — open_transport() provides the real one (native
// wwand_io tty + uloop.handle), tests inject a fake.
//
// Port discovery order (find_tty):
//   1. explicit config override
//   2. board quirk table (integrated modems without usable USB ids)
//   3. atport.uc lookup: USB vid:pid + interface number -> AT role
//      (table generated from ModemManager port-type udev rules)
//   4. old heuristic: first ttyUSB sibling, sorted

'use strict';

import * as uloop from 'uloop';

// the port table (225 devices) is the largest single module — loaded lazily
// on first use so daemon startup does not pay for it when no AT port exists
let atport = null;

function atport_table()
{
	atport = atport ?? require('wwand.atport');

	return atport;
}

const DEFAULT_TIMEOUT = 5000;

// boards whose integrated modem needs a fixed AT port (old
// proto_qmi_find_primary_serial_interface hardcodes)
const BOARD_TTYS = [
	{ prefix: 'zyxel,lte3301', tty: '/dev/ttyUSB2' },
	{ prefix: 'zyxel,nr7101',  tty: '/dev/ttyUSB2' },
];

// devices missing from the generated ModemManager table (atport.uc);
// verified on real hardware
const LOCAL_PORTS = {
	// Quectel RG650E: 0 DIAG, 1 NMEA, 2 AT, 3 AT secondary
	'2c7c:0122': { '2': 'at', '3': 'at2' },
};

// model-specific init sequences (old proto_qmi_serial_init)
const MODEL_QUIRKS = [
	// enable automatic carrier config (MBN) selection; the QMI-native
	// equivalent would be the PDC service (future replacement)
	{ pattern: '^EG06|^EM06|^RG50[02]Q', commands: [ 'AT+QMBNCFG="AutoSel",1' ] },
];

export function model_init_commands(model)
{
	for (let q in MODEL_QUIRKS)
		if (match(model ?? '', regexp(q.pattern)))
			return [ ...q.commands ];

	return [];
}

// eSIM host-access quirks. On some Quectel firmwares (RG650E and relatives)
// the QMI logical channel is NOT_SUPPORTED and the modem's own LPA daemon
// holds the ISD-R exclusively, so host-side ES10 APDU access over AT
// (CCHO/CGLA) only works once the internal LPA is disabled
// (AT+QESIM="lpa_enable",0) and the modem is reset once. Verified on the
// RG650E; the CGLA payload must additionally be quoted (see sim.uc).
export function esim_quirks(model)
{
	// verified on the RG650E only. Other Quectel modems may or may not need
	// this (the RG502Q's QMI logical channel was not tested) — extend the
	// pattern once confirmed on hardware rather than resetting them blindly.
	if (match(model ?? '', /^RG65[0-9]/))
		return { lpa_disable_for_host: true };

	return {};
}

// fallback when NAS system-selection-preference keeps failing (old
// proto_qmi_reset_modes_fallback; harmless ERROR on non-Huawei modems)
export function modes_fallback_command(model)
{
	return 'AT^SYSCFGEX="00",3fffffff,1,4,7fffffffffffffff,,';
}

// Quectel cell locking (verified on RG650E). Config:
//   lock_4g:  list of 'earfcn:pci' (one entry -> common/4g, several -> 4g_ext)
//   lock_5g:  'pci:arfcn:scs:band' (SA only; NSA follows the locked LTE
//             anchor, the modem answers +CME 902 there — treated as benign)
//   lock_persist: also store the lock in modem NV (save_ctrl)
export function cell_lock_commands(cfg)
{
	let cmds = [];
	let l4 = cfg?.lock_4g ?? [];

	if (type(l4) == 'string')
		l4 = [ l4 ];

	if (length(l4) == 1) {
		let m = match(l4[0], /^([0-9]+):([0-9]+)$/);

		if (m)
			push(cmds, sprintf('AT+QNWLOCK="common/4g",1,%s,%s', m[1], m[2]));
	}
	else if (length(l4) > 1) {
		let parts = [];

		for (let entry in l4) {
			let m = match(entry, /^([0-9]+):([0-9]+)$/);

			if (m)
				push(parts, sprintf('%s,%s', m[1], m[2]));
		}

		if (length(parts))
			push(cmds, sprintf('AT+QNWLOCK="common/4g_ext",%d,%s',
				length(parts), join(',', parts)));
	}

	let l5 = cfg?.lock_5g;

	if (type(l5) == 'string') {
		let m = match(l5, /^([0-9]+):([0-9]+):([0-9]+):([0-9]+)$/);

		if (m)
			push(cmds, sprintf('AT+QNWLOCK="common/5g",%s,%s,%s,%s',
				m[1], m[2], m[3], m[4]));
	}

	if (length(cmds) && cfg?.lock_persist)
		push(cmds, 'AT+QNWLOCK="save_ctrl",1,1');

	return cmds;
}

// --- AT port discovery -------------------------------------------------------

const ROLE_PREFERENCE = { at: 3, at2: 2, ppp: 1 };

export function find_tty(fx, device, tty_override)
{
	if (tty_override != null && tty_override != '')
		return tty_override;

	// board quirks first: integrated modems
	let board = trim(fx.read('/tmp/sysinfo/board_name') ?? '');

	for (let b in BOARD_TTYS)
		if (substr(board, 0, length(b.prefix)) == b.prefix)
			return b.tty;

	let name = substr(device, rindex(device, '/') + 1);
	let base = sprintf('/sys/class/usbmisc/%s/device/..', name);

	// enumerate tty siblings below the same USB device
	let tty_paths = fx.glob(sprintf('%s/*/tty*', base)) ?? [];
	let found = [];

	for (let path in tty_paths) {
		let tty = substr(path, rindex(path, '/') + 1);

		if (substr(tty, 0, 3) != 'tty')
			continue;

		let ifdir = substr(path, 0, rindex(path, '/'));
		let ifnum_raw = trim(fx.read(sprintf('%s/bInterfaceNumber', ifdir)) ?? '');

		push(found, {
			tty: tty,
			ifnum: length(ifnum_raw) ? hex('0x' + ifnum_raw) : null,
		});
	}

	if (!length(found))
		return null;

	// exact role lookup via USB ids
	let vid = lc(trim(fx.read(sprintf('%s/idVendor', base)) ?? ''));
	let pid = lc(trim(fx.read(sprintf('%s/idProduct', base)) ?? ''));
	let usbid = sprintf('%s:%s', vid, pid);
	let ports = LOCAL_PORTS[usbid] ?? atport_table()[usbid];

	if (ports) {
		let best = null, best_score = 0;

		for (let f in found) {
			let role = (f.ifnum != null) ? ports[sprintf('%d', f.ifnum)] : null;
			let score = ROLE_PREFERENCE[role] ?? 0;

			if (score > best_score) {
				best = f;
				best_score = score;
			}
		}

		if (best)
			return sprintf('/dev/%s', best.tty);
	}

	// heuristic fallback: first tty, sorted (old behavior)
	let names = sort(map(found, (f) => f.tty));

	return sprintf('/dev/%s', names[0]);
}

// find a secondary AT-capable tty (role at/at2) other than `primary` — used to
// hand lpac a free AT port for eSIM host access while wwand keeps its own.
export function find_secondary_at(fx, device, primary)
{
	let name = substr(device, rindex(device, '/') + 1);
	let base = sprintf('/sys/class/usbmisc/%s/device/..', name);

	let vid = lc(trim(fx.read(sprintf('%s/idVendor', base)) ?? ''));
	let pid = lc(trim(fx.read(sprintf('%s/idProduct', base)) ?? ''));
	let ports = LOCAL_PORTS[sprintf('%s:%s', vid, pid)] ?? atport_table()[sprintf('%s:%s', vid, pid)];

	if (!ports)
		return null;

	let cands = [];

	for (let path in (fx.glob(sprintf('%s/*/tty*', base)) ?? [])) {
		let tty = substr(path, rindex(path, '/') + 1);

		if (substr(tty, 0, 3) != 'tty')
			continue;

		let ifdir = substr(path, 0, rindex(path, '/'));
		let ifnum_raw = trim(fx.read(sprintf('%s/bInterfaceNumber', ifdir)) ?? '');
		let ifnum = length(ifnum_raw) ? hex('0x' + ifnum_raw) : null;
		let role = (ifnum != null) ? ports[sprintf('%d', ifnum)] : null;

		if ((role == 'at' || role == 'at2') && sprintf('/dev/%s', tty) != primary)
			push(cands, sprintf('/dev/%s', tty));
	}

	return length(cands) ? sort(cands)[0] : null;
}

// --- transport ---------------------------------------------------------------

// real tty transport; kept separate so the engine stays host-testable
export function open_transport(path, baud, log)
{
	// deferred import: wwand_io is a native module, tests never load it
	let qmit = require('wwand_io');

	let handle = qmit.open_tty(path, baud ?? 115200);

	if (!handle) {
		if (log)
			log('warn', sprintf('cannot open %s: %s', path, qmit.last_error()));

		return null;
	}

	let self = { closed: false };
	let data_cb = null;

	let uhandle = uloop.handle(handle.fileno(), (events) => {
		while (true) {
			let chunk = handle.read();

			if (chunk === null || chunk === false)
				break;

			if (data_cb)
				data_cb(chunk);
		}
	}, uloop.ULOOP_READ);

	self.write = (data) => handle.write(data);
	self.on_data = (cb) => { data_cb = cb; };
	self.drain = () => {
		while (true) {
			let chunk = handle.read();

			if (chunk === null || chunk === false)
				break;
		}
	};
	self.close = () => {
		if (self.closed)
			return;

		self.closed = true;

		if (uhandle)
			uhandle.delete();

		handle.close();
	};

	return self;
}

// --- engine ------------------------------------------------------------------

export function create(transport, opts)
{
	let log = opts?.log ?? ((level, msg) => warn(sprintf('%s: at: %s\n', level, msg)));

	let self = {
		queue: [],
		current: null,
		buffer: '',
	};

	let finish, next;

	finish = (err, lines) => {
		let cur = self.current;

		if (!cur)
			return;

		self.current = null;

		if (cur.timer)
			cur.timer.cancel();

		if (cur.cb)
			cur.cb(err, { lines: lines });

		next();
	};

	next = () => {
		if (self.current || !length(self.queue))
			return;

		let cur = self.current = shift(self.queue);

		self.buffer = '';
		cur.lines = [];

		cur.timer = uloop.timer(cur.timeout, () => {
			log('warn', sprintf('timeout waiting for reply to %s', cur.cmd));
			finish({ error: 'timeout' }, cur.lines);
		});

		transport.write(cur.cmd + '\r');
	};

	transport.on_data((chunk) => {
		let cur = self.current;

		if (!cur) {
			// unsolicited data outside a command: discard
			return;
		}

		self.buffer += chunk;

		let idx;

		while ((idx = index(self.buffer, '\n')) >= 0) {
			let line = trim(substr(self.buffer, 0, idx));

			self.buffer = substr(self.buffer, idx + 1);

			if (line == '' || line == cur.cmd)   // skip blanks and echo
				continue;

			if (line == 'OK')
				return finish(null, cur.lines);

			if (line == 'ERROR' || line == 'COMMAND NOT SUPPORT')
				return finish({ error: 'ERROR' }, cur.lines);

			let m = match(line, /^\+(CME|CMS) ERROR: *(.*)$/);

			if (m)
				return finish({ error: lc(m[1]), code: m[2] }, cur.lines);

			push(cur.lines, line);
		}
	});

	self.send = function(cmd, cb, o) {
		push(self.queue, {
			cmd: cmd,
			cb: cb,
			timeout: o?.timeout ?? DEFAULT_TIMEOUT,
		});

		next();
	};

	// run a list of commands sequentially, best-effort (errors logged only)
	self.run_sequence = function(cmds, done) {
		let idx = 0;
		let step;

		step = () => {
			if (idx >= length(cmds))
				return done ? done() : null;

			let cmd = cmds[idx++];

			self.send(cmd, (err, res) => {
				if (err)
					log('warn', sprintf('%s failed: %J', cmd, err));
				else
					log('info', sprintf('%s ok', cmd));

				step();
			});
		};

		step();
	};

	// discard pending serial noise (old M9200B empty_serial_buffers quirk)
	self.drain = function() {
		if (!self.current && transport.drain)
			transport.drain();
	};

	self.close = function() {
		if (self.current?.timer)
			self.current.timer.cancel();

		self.current = null;
		self.queue = [];
		transport.close();
	};

	return self;
}
