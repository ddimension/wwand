// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
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
import * as parse from 'wwand.atcmd_parse';

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
	// MeiG SLM770A (ASR): if2 DIAG, if3 AT secondary, if4 AT, if5 NMEA
	// (HW-verified on a Cudy LT300; first-ttyUSB heuristic picks the mute
	// DIAG port). 4d57 = RNDIS composition, 4d58 = ECM.
	'2dee:4d57': { '4': 'at', '3': 'at2' },
	'2dee:4d58': { '4': 'at', '3': 'at2' },
	// Fibocom FM350-GL (MediaTek T700; RNDIS compositions only — AT+GTUSBMODE
	// 40/41). AT port per the OpenWrt forum dumps + ModemManager udev rules for
	// this module: iface 4 in mode 40 (0e8d:7126), iface 6 in mode 41
	// (0e8d:7127, default). No aux AT port in either composition. Field-verified
	// on a WH3000 Pro (mode 40, iface 4: identity, dial and URCs all flow).
	// Pinned by interface number, so a wrong mapping stays contained (the
	// first-tty heuristic would land on a mute META port).
	'0e8d:7126': { '4': 'at' },
	'0e8d:7127': { '6': 'at' },
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
};

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
};

// fallback when NAS system-selection-preference keeps failing (old
// proto_qmi_reset_modes_fallback; harmless ERROR on non-Huawei modems)
export function modes_fallback_command(model)
{
	return 'AT^SYSCFGEX="00",3fffffff,1,4,7fffffffffffffff,,';
};

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
};

// vendor response parsers moved to atcmd_parse.uc — re-exported so the
// existing `atcmd.parse_*` consumers (modem backends, tests) are unchanged
export const parse_qnwlock = parse.parse_qnwlock;
export const parse_qcainfo = parse.parse_qcainfo;
export const parse_qeng_servingcell = parse.parse_qeng_servingcell;
export const parse_qeng_neighbourcell = parse.parse_qeng_neighbourcell;
export const parse_qrsrp = parse.parse_qrsrp;
export const parse_qrsrq = parse.parse_qrsrq;
export const parse_qsinr = parse.parse_qsinr;
export const branch_best = parse.branch_best;
export const parse_ceer = parse.parse_ceer;
export const parse_cesq = parse.parse_cesq;
export const parse_hcsq = parse.parse_hcsq;
export const parse_monsc = parse.parse_monsc;
export const parse_monnc = parse.parse_monnc;
export const parse_meng_servingcell = parse.parse_meng_servingcell;
export const parse_meng_neighbourcell = parse.parse_meng_neighbourcell;
export const parse_celllock = parse.parse_celllock;
export const parse_ati = parse.parse_ati;
export const parse_cops_read = parse.parse_cops_read;
export const parse_cops_scan = parse.parse_cops_scan;
export const parse_qnwinfo = parse.parse_qnwinfo;
export const parse_qcfg_iotopmode = parse.parse_qcfg_iotopmode;
export const parse_crsm = parse.parse_crsm;
export const parse_cpol = parse.parse_cpol;
export const parse_qtemp = parse.parse_qtemp;
export const parse_chiptemp = parse.parse_chiptemp;
export const parse_cpmutemp = parse.parse_cpmutemp;
export const parse_meig_temp = parse.parse_meig_temp;
export const parse_mtsm = parse.parse_mtsm;
export const parse_ethermal = parse.parse_ethermal;

// --- AT port discovery -------------------------------------------------------

const ROLE_PREFERENCE = { at: 3, at2: 2, ppp: 1 };

// PCIe / M.2 modems on the MHI bus (RG500Q-M.2, RM5xx, Foxconn T99W, SDX-class)
// expose NO USB tty siblings — their AT port is an MHI or wwan-subsystem
// character device. Probe those nodes directly (QModem probes /dev/mhi_DUN* and
// /dev/wwan*). Modern kernels expose it via the wwan subsystem (/dev/wwanNatM);
// older MHI stacks as /dev/mhi_<...>_DUN. Returns the first match or null.
export function find_mhi_at(fx)
{
	for (let pat in [ '/dev/wwan*at*', '/dev/mhi_*DUN*', '/dev/mhi_DUN*' ]) {
		let hits = sort(fx.glob(pat) ?? []);

		if (length(hits))
			return hits[0];
	}

	return null;
};

// find_tty(fx, device, tty_override, base_override):
//   device        a cdc-wdm control device ('/dev/cdc-wdmN'); the USB parent is
//                 derived from it. May be null when base_override is supplied.
//   base_override an explicit sysfs USB-device base to enumerate tty siblings
//                 under (used by discovery.uc for NCM/PPP modems, which have no
//                 cdc-wdm to anchor on — the base is the netdev's or usb_path's
//                 USB device dir).
export function find_tty(fx, device, tty_override, base_override)
{
	if (tty_override != null && tty_override != '')
		return tty_override;

	// board quirks first: integrated modems
	let board = trim(fx.read('/tmp/sysinfo/board_name') ?? '');

	for (let b in BOARD_TTYS)
		if (substr(board, 0, length(b.prefix)) == b.prefix)
			return b.tty;

	let base = base_override;

	if (base == null) {
		if (device == null)
			return null;   // no cdc-wdm anchor and no explicit base

		let name = substr(device, rindex(device, '/') + 1);
		base = sprintf('/sys/class/usbmisc/%s/device/..', name);
	}

	// enumerate tty siblings below the same USB device
	let tty_paths = fx.glob(sprintf('%s/*/tty*', base)) ?? [];

	// an NCM modem's `device` is a netdev name (no cdc-wdm) — when the usbmisc
	// anchor yields nothing, anchor on the net class instead. This matters for
	// the RETRY path: at first resolve the ttys may not exist yet (runtime
	// new_id bind), and the re-kick must be able to find them from scratch.
	if (!length(tty_paths) && base_override == null && device != null) {
		let name = substr(device, rindex(device, '/') + 1);
		let nbase = sprintf('/sys/class/net/%s/device/..', name);
		let npaths = fx.glob(sprintf('%s/*/tty*', nbase)) ?? [];

		if (length(npaths)) {
			base = nbase;
			tty_paths = npaths;
		}
	}

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

	// no USB tty siblings: on a PCIe/MHI modem the AT port is an MHI/wwan char
	// device instead — probe those before giving up
	if (!length(found))
		return find_mhi_at(fx);

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
};

// find_at_channels: the primary AT port (find_tty) plus a DEDICATED secondary
// AT channel (port role 'at2') when the modem exposes one. Running telemetry
// polls on the secondary keeps them from serializing behind dial / cell-lock /
// user (modem_at) commands on the control channel — the AT queue is per-tty.
// Returns { primary, telemetry }; telemetry is null when there is no distinct
// second AT port (the caller then reuses the primary). Only an explicitly
// role-tagged 'at2' port is used — never a guessed one, which could hang.
export function find_at_channels(fx, device, tty_override, base_override)
{
	let primary = find_tty(fx, device, tty_override, base_override);

	if (!primary)
		return { primary: null, telemetry: null };

	// resolve the USB-device dir to enumerate sibling ttys for the 'at2' role:
	// explicit base, else the cdc-wdm device, else the primary tty's own USB
	// parent. The old single-shot logic died on NCM modems: `device` is the
	// NETDEV name there (usb0), so the usbmisc-derived path never resolves and
	// the tty fallback was unreachable (HW-verified on the SLM770A/LT300 — at2
	// silently absent).
	let tn = substr(primary, rindex(primary, '/') + 1);
	let candidates = [];

	if (base_override != null)
		push(candidates, base_override);

	if (device != null) {
		let name = substr(device, rindex(device, '/') + 1);
		push(candidates, sprintf('/sys/class/usbmisc/%s/device/..', name));
	}

	// tty -> usb-serial port -> INTERFACE (1-1:1.x) -> DEVICE (1-1):
	// idVendor/idProduct live on the device, two levels up
	push(candidates, sprintf('/sys/class/tty/%s/device/../..', tn));

	let base = null, vid = '', pid = '';

	for (let c in candidates) {
		let v = lc(trim(fx.read(sprintf('%s/idVendor', c)) ?? ''));

		if (!length(v))
			continue;

		base = c;
		vid = v;
		pid = lc(trim(fx.read(sprintf('%s/idProduct', c)) ?? ''));
		break;
	}

	if (base == null)
		return { primary: primary, telemetry: null };

	let ports = LOCAL_PORTS[sprintf('%s:%s', vid, pid)] ?? atport_table()[sprintf('%s:%s', vid, pid)];

	if (!ports)
		return { primary: primary, telemetry: null };

	for (let path in (fx.glob(sprintf('%s/*/tty*', base)) ?? [])) {
		let tty = substr(path, rindex(path, '/') + 1);

		if (substr(tty, 0, 3) != 'tty')
			continue;

		let ifdir = substr(path, 0, rindex(path, '/'));
		let ifnum_raw = trim(fx.read(sprintf('%s/bInterfaceNumber', ifdir)) ?? '');
		let ifnum = length(ifnum_raw) ? hex('0x' + ifnum_raw) : null;
		let role = (ifnum != null) ? ports[sprintf('%d', ifnum)] : null;

		if (role == 'at2') {
			let dev = sprintf('/dev/%s', tty);

			if (dev != primary)
				return { primary: primary, telemetry: dev };
		}
	}

	return { primary: primary, telemetry: null };
};

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
};

// --- engine ------------------------------------------------------------------

// GENERIC (3GPP / V.250) unsolicited result codes. Kept HERE as the single
// source of truth: the same list used to live (in two slightly different
// spellings) in modem_ncm's identify filter and its URC handler, so a prefix
// added to one was silently missing from the other.
//
// Vendor-specific codes do NOT belong here — a prefix in this list is filtered
// out of the responses of EVERY modem, so a wrong entry breaks parsing on
// hardware it was never meant for. They live on the vendor recipe (ncm_vendors
// `urcs`) and are merged in via at.add_urc_prefixes() once identify has
// resolved the manufacturer.
//
// A prefix in this list is only treated as unsolicited when it differs from the
// running command's OWN prefix — AT+CEREG? legitimately answers "+CEREG:", and
// its answer must not be mistaken for the URC of the same name.
export const DEFAULT_URC_PREFIXES = [
	'CREG', 'CGREG', 'CEREG', 'C5GREG',   // registration
	'CGEV',                                // PDP/PDN lifecycle
	'CTZV', 'CTZE', 'NITZ',                // time zone
	'CSCON',                               // signalling connection
	'ESIMS', 'CIREPI', 'CNEMIU', 'EONSNWNAME',
	'CMTI', 'CMT', 'CDS', 'CBM',           // SMS delivery
	'CUSD', 'CIEV',
];

// Unsolicited codes that carry NO prefix at all (V.250 call progress). They
// matter because a bare answer — AT+CGMI's "Fibocom", AT+CGMM's "FM350-GL",
// the IMEI/IMSI digits — is taken verbatim by its caller: without this list a
// stray RING landing in that window would become the manufacturer. No identify
// value can collide with them, so matching the whole line exactly is safe.
export const DEFAULT_URC_BARE = [
	'RING', 'NO CARRIER', 'BUSY', 'NO ANSWER', 'NO DIALTONE', 'RING 1',
];

// the result-code prefix a command answers with: AT+CEREG? -> CEREG,
// AT+CGACT=1,1 -> CGACT. Commands whose answer is a bare value (AT+CGMI)
// still resolve to their own name, which simply never appears in the reply.
function cmd_prefix(cmd)
{
	let m = match(cmd ?? '', /^AT[+^$]([A-Z0-9]+)/i);

	return m ? uc(m[1]) : null;
};

export function create(transport, opts)
{
	let log = opts?.log ?? ((level, msg) => warn(sprintf('%s: at: %s\n', level, msg)));

	let self = {
		queue: [],
		current: null,
		// ONE buffer for the whole byte stream. The modem sends a single
		// stream; splitting it per command state used to tear a line that
		// straddled a command boundary into two buffers — its head was
		// dropped and the tail was pushed into the NEXT command's lines as
		// if it were an answer (a bare-value command like AT+CGMI would
		// have taken that fragment as the manufacturer).
		buffer: '',
		on_urc: opts?.on_urc ?? null,
		// prefixes that are unsolicited on this port. A URC is framed exactly
		// like a result code (manual 2.4.3: <CR><LF>…<CR><LF>), so it always
		// arrives as a WHOLE line and can be classified per line — but it may
		// land between the lines of a multi-line response, which is why every
		// line is classified, not just the first.
		urc_prefixes: opts?.urc_prefixes ?? DEFAULT_URC_PREFIXES,
		urc_bare: opts?.urc_bare ?? DEFAULT_URC_BARE,
	};

	let finish, next;

	// never log credentials: auth commands carry username+password in their
	// argument list — mask every quoted argument (covers the user/pass
	// positions in all quoted forms: CGAUTH/MGAUTH/QICSGP/QCPDPP/NDISDUP),
	// and the trailing comma fields for the unquoted AT^AUTHDATA form.
	// CPIN/CPUK (PIN/PUK entry) mask everything after the '='. The prefix
	// class must cover AT+/AT^/AT$ — Huawei/MeiG/Sierra use ^/$.
	let redact = (cmd) => {
		let cls = match(cmd, /^AT[+^$](CGAUTH|MGAUTH|QICSGP|AUTHDATA|QCPDPP|NDISDUP|CPIN|CPUK)\s*=/);

		if (!cls)
			return cmd;

		if (cls[1] == 'CPIN' || cls[1] == 'CPUK')
			return replace(cmd, /^(AT\+(CPIN|CPUK)\s*=\s*).*$/, '$1***');

		cmd = replace(cmd, /"([^"]*)"/g, '"***"');

		// unquoted AUTHDATA carries the credentials as the last two comma
		// fields — either may be empty (one-credential forms exist), so
		// requiring two non-empty fields leaked them into the log
		return replace(cmd, /(,[^,"]*)(,[^,"]*)$/, ',***,***');
	};

	// prefix-less call-progress codes (RING, NO CARRIER, ...): compared as a
	// WHOLE line so a bare identify value can never be swallowed by a substring
	// match. Shared by both recognition paths.
	let is_bare_urc = (line) => {
		let u = uc(trim(line));

		for (let b in self.urc_bare)
			if (u == b)
				return true;

		return false;
	};

	// does this line LOOK like a result code at all? Used by the idle path,
	// where there is no command to confuse it with, so anything code-shaped is
	// surfaced rather than dropped — an unknown vendor code stays visible.
	//
	// The prefix class MUST match is_urc_line's: Huawei, MeiG and Sierra emit
	// their codes with ^ and $. It did not, and the whole huawei `urcs:` list
	// is ^-prefixed — so those reached on_urc only when a command happened to
	// be running, and were dropped the rest of the time, which is most of it.
	let looks_unsolicited = (line) =>
		match(line, /^\s*[+^$][A-Z]/) != null || is_bare_urc(line);

	// is this line an unsolicited code rather than `cur`'s answer? A URC is
	// framed exactly like a result code, so the decision is per LINE. The
	// running command's own prefix always wins: AT+CEREG? answers "+CEREG:",
	// and that answer must stay an answer.
	let is_urc_line = (line, own) => {
		// prefixed form. The prefix class covers AT+/AT^/AT$ — Huawei, MeiG
		// and Sierra emit vendor URCs with ^ and $.
		let m = match(line, /^[+^$]([A-Z0-9]+)[:\s]/);

		if (m) {
			if (own != null && m[1] == own)
				return false;   // the running command's own answer

			for (let p in self.urc_prefixes)
				if (m[1] == p)
					return true;

			return false;
		}

		return is_bare_urc(line);
	};

	let emit_urc = (line) => {
		if (self.on_urc)
			self.on_urc(line);
		else
			log('debug', sprintf('urc: %s', line));
	};

	// drain complete lines while NO command is running: URCs arrive while idle
	// AND buffered BEHIND a finished command (the T700's first +CTZV lands
	// right after AT+CTZR=1's OK, a +CGEV right after a dial read) — surface
	// URC-looking lines, discard the rest. The partial tail stays in the
	// buffer: it is the head of a line whose rest has not arrived yet, and
	// dropping it is how a URC used to get lost across a command boundary.
	let drain_urcs = () => {
		let idx;

		while ((idx = index(self.buffer, '\n')) >= 0) {
			let line = trim(substr(self.buffer, 0, idx));

			self.buffer = substr(self.buffer, idx + 1);

			if (line == '' || !looks_unsolicited(line))
				continue;

			emit_urc(line);
		}
	};

	// drain leftover URCs BEFORE the callback — it may synchronously queue
	// the next command
	let dispatch_urcs = () => drain_urcs();

	finish = (err, lines) => {
		let cur = self.current;

		if (!cur)
			return;

		self.current = null;

		if (cur.timer)
			cur.timer.cancel();

		// drain leftover URCs BEFORE the callback — it may synchronously queue
		// the next command, which resets the buffer
		dispatch_urcs();

		// every exchange at debug level, raw response lines included — the
		// field-analysis gold (CGCONTRDP/CGPADDR dotted tokens, GTDNS, …).
		// Errors log at warn so a silent line-drop never hides a failure.
		// Auth commands are redacted — never log credentials.
		log(err ? 'warn' : 'debug', sprintf('%s -> %s', redact(cur.cmd),
			err ? sprintf('error: %s', err.error ?? '?') : join(' | ', lines ?? [])));

		if (cur.cb)
			cur.cb(err, { lines: lines });

		next();
	};

	next = () => {
		if (self.current || !length(self.queue))
			return;

		let cur = self.current = shift(self.queue);

		// the buffer is NOT cleared: it belongs to the byte stream, not to a
		// command. Anything still in it is either a partial line whose rest is
		// on the way, or idle noise the line loop below skips.
		cur.lines = [];
		cur.prefix = cmd_prefix(cur.cmd);

		cur.timer = uloop.timer(cur.timeout, () => {
			log('warn', sprintf('timeout waiting for reply to %s', redact(cur.cmd)));
			finish({ error: 'timeout' }, cur.lines);
		});

		transport.write(cur.cmd + '\r');
	};

	transport.on_data((chunk) => {
		let cur = self.current;

		self.buffer += chunk;

		if (!cur) {
			// unsolicited data outside a command: surface URC-looking lines
			// (+CODE...), discard the rest
			drain_urcs();
			return;
		}

		// PDU-prompt commands (AT+CMGS=<len>): the modem answers with a bare
		// '> ' prompt (NO newline) and then waits for the payload + Ctrl-Z. Send
		// it once the prompt appears, before the line loop (which needs '\n').
		if (cur.payload != null && !cur.payload_sent) {
			let p = index(self.buffer, '>');

			if (p >= 0) {
				cur.payload_sent = true;
				// consume only THROUGH the prompt — wiping the whole buffer
				// would also drop anything the modem already sent behind it
				self.buffer = substr(self.buffer, p + 1);
				transport.write(cur.payload + '\x1a');
			}
		}

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

			// a URC that lands between the lines of a response is NOT part of
			// the answer: route it to the state machine instead of letting it
			// pose as a reply line (it used to be pushed here and never
			// reached on_urc at all — every PDN/registration event arriving
			// inside a command window was lost).
			if (is_urc_line(line, cur.prefix)) {
				emit_urc(line);
				continue;
			}

			push(cur.lines, line);
		}
	});

	// The URC set is extended AFTER the port is open: which vendor URCs a modem
	// emits is only known once identify has run, and identify runs over this very
	// engine. Merged, never replaced — the 3GPP defaults always apply.
	self.add_urc_prefixes = function(list) {
		let seen = {};

		for (let p in self.urc_prefixes)
			seen[p] = true;

		for (let p in (list ?? [])) {
			// a prefix is stored without its sigil; tolerate '+QIND' / '^RSSI'
			let u = uc(trim(replace(trim(p), /^[+^$]/, '')));

			if (u != '' && !seen[u]) {
				seen[u] = true;
				push(self.urc_prefixes, u);
			}
		}

		return self.urc_prefixes;
	};

	self.send = function(cmd, cb, o) {
		push(self.queue, {
			cmd: cmd,
			cb: cb,
			timeout: o?.timeout ?? DEFAULT_TIMEOUT,
		});

		next();
	};

	// two-phase prompt command (AT+CMGS PDU mode): send `cmd`, wait for the '>'
	// prompt, then write `payload` + Ctrl-Z. cb gets the final reply lines (e.g.
	// "+CMGS: <ref>"). Longer default timeout — sending includes an OTA round trip.
	self.send_pdu = function(cmd, payload, cb, o) {
		push(self.queue, {
			cmd: cmd,
			payload: payload,
			cb: cb,
			timeout: o?.timeout ?? 60000,
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
					log('warn', sprintf('%s failed: %J', redact(cmd), err));
				else
					log('info', sprintf('%s ok', redact(cmd)));

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
};
