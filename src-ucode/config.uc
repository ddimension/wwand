// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — configuration model. parse(raw) is pure (raw = uci get_all() section
// objects) so it stays host-testable; UCI access itself lives in main.uc.
//
// Compat: stock/legacy-style qmi interfaces (proto 'wwand'|'qmi' with the
// connection carried inline, no `option modem`) are translated in-memory (parent
// netdev -> synthesized modem, interface -> context); bash-only options warn +
// are ignored. The one-shot migrator (migrate_plan) upgrades them to the
// network-native model on install.

'use strict';

const OLD_DEPRECATED = [ 'dhcp', 'autocreateif', 'customroutes', 'strongestnetwork' ];

const PDP_TYPES = { ipv4: true, ipv6: true, ipv4v6: true };

function bool_opt(v, dflt)
{
	if (v == null)
		return dflt;

	return !(v == '0' || v == 'false' || v == 'off' || v == 'no');
}

// the connection option bundle every context flavor shares (apn/auth/creds/mtu/
// cadence); flavor-specific fields stay at the call sites.
function conn_fields(s)
{
	return {
		apn: s.apn,
		auth: s.auth,
		username: s.username,
		password: s.password,
		mtu: (s.mtu != null) ? +s.mtu : null,
		use_pushed_prefix: bool_opt(s.use_pushed_prefix, false),
		settings_poll: +(s.settings_poll ?? 300),
		// on a reconnect that changes the IP, do a netifd link down->up instead of
		// an in-place renew, so dependent tunnels/xfrm re-follow the new local
		// address (netifd ignores an in-place address update for resolved host
		// dependencies). Costs the WAN's own IPv6-PD/VRF a rebuild + a brief blip;
		// default off (WireGuard doesn't need it — it follows the route).
		hard_reconnect_on_ip_change: bool_opt(s.hard_reconnect_on_ip_change, false),
	};
}

// The mux child's chosen NAME (what netifd claims). Explicit wwan0mN used as-is;
// a bare netdev + `mux_id` derives <netdev>m<mux_id> (NEVER the bare netdev — it
// would collide with the parent); no device -> given netdev, else 'wwan0'. null
// => runtime re-derives from the real netdev. Shared by both interface parsers,
// which must never drift.
function derive_mux_link(nd, device, mux_id, muxed, fallback_netdev)
{
	if (!muxed)
		return null;

	return (nd?.muxed ?? false) ? device
		: sprintf('%sm%d', nd?.netdev ?? fallback_netdev ?? 'wwan0', mux_id);
}

export function modem_defaults(over)
{
	return {
		device: null, netdev: null, usb_path: null, reset_gpio: null,
		serial: null, imei: null,   // stable identity anchors (USB iSerial / IMEI)
		repower_time: null,         // recovery power-cycle off / reset hold seconds
		pincode: null, modes: null, mcc: null, mnc: null,
		mux: 'auto', dl_datagram_max_size: 0, tty: null,
		at_init: [], location: false, delay: 0,
		at2_external: false,   // release the secondary AT port for external tools
		fcc_auth: null,        // RF unlock for laptop-SKU modems (see reference.md)
		failreboot: 100, proto_error_limit: 25, zero_rx_timeout: 21600,
		lock_4g: [], lock_5g: null, lock_persist: false,
		sim_slot: 0,
		stats_interval: 60,
		auto_correct_config: false,   // gated runtime auto-correction (default off)
		...(over ?? {}),
	};
};

export function context_defaults(over)
{
	return {
		modem: null, interface: null, mux_id: 0,
		muxed: false, mux_link: null,
		l3_name: null,   // assigned datapath netdev name (wwandN / explicit device)
		apn: null, pdp_type: 'ipv4v6', auth: null,
		username: null, password: null, profile: null,
		mtu: null, use_pushed_mtu: true,
		use_pushed_prefix: false,
		settings_poll: 300,
		auto: true,   // netifd 'auto 0' => daemon won't proactively bring it up
		...(over ?? {}),
	};
};

// apply a `config wwand_globals` section.
function apply_globals(s, result)
{
	result.globals.log_level = s.log_level ?? result.globals.log_level;

	// off-switch for the daemon writing the resolved l3 device name back onto the
	// interface section as `option device` (default on).
	if (s.write_device != null)
		result.globals.write_device = bool_opt(s.write_device, true);

	// zero-config autosetup (default on): when NO wwand_modem / proto-wwand
	// interface exists and a modem shows up, wwand creates wwmodem_auto +
	// interface wwan0 (default wan firewall zone) and later copies the
	// ICCID-matched APN defaults (apndb) into the config — one-shot.
	if (s.autosetup != null)
		result.globals.autosetup = bool_opt(s.autosetup, true);

	// opt-in adoption of the stock/legacy netifd stack (default OFF). When off,
	if (s.hold_max != null) {
		let hm = +s.hold_max;

		if (hm > 0)
			result.globals.hold_max = hm;
		else
			push(result.warnings, sprintf('invalid hold_max %J, keeping %d',
				s.hold_max, result.globals.hold_max));
	}
}

// every option the wwand_modem / wwand_sim parsers consume — used to flag
// unknown options: those are silently dead config, usually a typo ('pin'
// instead of 'pincode' cost a HW debugging session — the daemon saw "PIN
// required but none configured" and safety-blocked the SIM).
const MODEM_KNOWN_OPTS = [ 'device', 'netdev', 'path', 'usb_path', 'serial',
	'imei', 'repower_time', 'reset_gpio', 'pincode', 'modes', 'mcc', 'mnc',
	'mux', 'dl_datagram_max_size', 'tty', 'at2_external', 'fcc_auth',
	'at_init', 'location', 'delay', 'failreboot', 'proto_error_limit',
	'zero_rx_timeout', 'lock_4g', 'lock_5g', 'lock_persist', 'sim_slot',
	'stats_interval', 'auto_correct_config', 'plmn_list' ];
const SIM_KNOWN_OPTS = [ 'modem', 'iccid', 'imsi', 'pincode', 'apn', 'auth',
	'username', 'password', 'plmn_list' ];

// flag section options the parser does not consume; suggest the known option
// the unknown one is a prefix of (or vice versa) — catches pin/pincode-style
// typos. Returns the messages (also pushed onto `warnings` for the log).
function unknown_opts(s, known, warnings, label)
{
	let kmap = {};
	let out = [];

	for (let k in known)
		kmap[k] = true;

	for (let k in keys(s)) {
		if (substr(k, 0, 1) == '.' || kmap[k])
			continue;

		let hint = null;

		for (let cand in known)
			if (index(cand, k) == 0 || index(k, cand) == 0) { hint = cand; break; }

		let msg = sprintf("%s: unknown option '%s'%s (ignored)", label, k,
			hint ? sprintf(" — did you mean '%s'?", hint) : '');

		push(warnings, msg);
		push(out, msg);
	}

	return out;
}

// build a modem config from a raw `config wwand_modem` section.
function modem_from_section(s)
{
	return modem_defaults({
		device: s.device,
		netdev: s.netdev,
		// `path` is the stable USB topology anchor (named like wireless
		// `wifi-device option path`); `usb_path` is the deprecated old name.
		usb_path: s.path ?? s.usb_path,
		// stable identity anchors: `serial` (USB iSerial, matched pre-open) and
		// `imei` (matched post-open) follow the modem across re-enumeration and
		// port changes — see discovery.resolve_modem_device / daemon identity check.
		serial: s.serial,
		imei: s.imei,
		repower_time: (s.repower_time != null) ? +s.repower_time : null,
		// optional named GPIO wired to the modem RESET line; when set, recovery
		// pulses it instead of power-cycling (see board.uc / daemon repower).
		reset_gpio: s.reset_gpio,
		pincode: s.pincode,
		modes: s.modes,
		mcc: s.mcc,
		mnc: s.mnc,
		mux: s.mux ?? 'auto',
		dl_datagram_max_size: +(s.dl_datagram_max_size ?? 0),
		tty: s.tty,
		// release the secondary AT port ('at2') for external tools: wwand then
		// never opens it and runs telemetry over the control channel instead
		at2_external: bool_opt(s.at2_external, false),
		fcc_auth: s.fcc_auth,
		at_init: (type(s.at_init) == 'array') ? s.at_init :
		         (s.at_init != null ? [ s.at_init ] : []),
		location: bool_opt(s.location, false),
		delay: +(s.delay ?? 0),
		failreboot: +(s.failreboot ?? 100),
		proto_error_limit: +(s.proto_error_limit ?? 25),
		zero_rx_timeout: +(s.zero_rx_timeout ?? 21600),
		lock_4g: (type(s.lock_4g) == 'array') ? s.lock_4g :
		         (s.lock_4g != null ? [ s.lock_4g ] : []),
		lock_5g: s.lock_5g,
		lock_persist: bool_opt(s.lock_persist, false),
		sim_slot: +(s.sim_slot ?? 0),
		stats_interval: +(s.stats_interval ?? 60),
		auto_correct_config: bool_opt(s.auto_correct_config, false),
		// optional named user-PLMN list to restore before radio-on (wwand_plmnlist)
		plmn_list: (s.plmn_list != null && s.plmn_list != '') ? s.plmn_list : null,
		plmn_restore: null,   // resolved from plmn_list at the end of parse()
	});
}

// parse one `list plmn '<mccmnc> <rat>,<rat>...'` entry into the write shape.
// RAT tokens: gsm/2g, utran/3g/umts, eutran/4g/lte, ngran/5g/nr. null if the
// PLMN id is malformed.
function parse_plmn_entry(str)
{
	let f = split(trim(sprintf('%s', str ?? '')), /[ \t,]+/);
	let id = f[0] ?? '';

	if (!match(id, /^[0-9]{5,6}$/))
		return null;

	let e = { mcc: substr(id, 0, 3), mnc: substr(id, 3),
	          gsm: false, utran: false, eutran: false, ngran: false };

	for (let i = 1; i < length(f); i++) {
		let r = lc(f[i]);

		if (r == 'gsm' || r == '2g')                       e.gsm = true;
		else if (r == 'utran' || r == '3g' || r == 'umts') e.utran = true;
		else if (r == 'eutran' || r == '4g' || r == 'lte') e.eutran = true;
		else if (r == 'ngran' || r == '5g' || r == 'nr' || r == 'nr5g') e.ngran = true;
	}

	return e;
}

// a `config wwand_plmnlist <name>` section -> { type, entries } in priority
// order. `option type` selects which modem list this targets: 'nas' (QMI NAS
// preferred networks), 'user' (SIM EF 6F60 user list, via AT+CPOL) or 'fplmn'
// (SIM EF 6F7B forbidden list, via UIM/AT+CRSM); default 'nas' since that is the
// one wwand can reliably re-apply. fplmn entries carry no access technology.
function plmnlist_from_section(s)
{
	let raw = (type(s.plmn) == 'array') ? s.plmn : (s.plmn != null ? [ s.plmn ] : []);
	let entries = [];

	for (let str in raw) {
		let e = parse_plmn_entry(str);

		if (e)
			push(entries, e);
	}

	return { type: (s.type == 'user') ? 'user' : (s.type == 'fplmn') ? 'fplmn' : 'nas', entries: entries };
}

// build a per-SIM override from a `config wwand_sim` section. Matched at runtime
// to the active card by (modem, iccid); overrides the modem's pincode and,
// optionally, the carrier apn/auth/pdp for that card.
function sim_from_section(s)
{
	// the per-SIM carrier bundle: PIN + credentials. pdp_type / IP family is a
	// connection concern and stays on the interface, not the SIM.
	return {
		modem: s.modem,
		iccid: s.iccid,
		imsi: s.imsi,
		pincode: s.pincode,
		apn: s.apn,
		auth: s.auth,
		username: s.username,
		password: s.password,
		// optional per-SIM user-PLMN list (wwand_plmnlist), wins over the modem's
		plmn_list: (s.plmn_list != null && s.plmn_list != '') ? s.plmn_list : null,
		plmn_restore: null,   // resolved at the end of parse()
	};
}

// parse the network-native wwand sections (WireGuard-style typed sections in
// /etc/config/network: wwand_globals / wwand_modem / wwand_sim). The interface
// referencing a wwand_modem via `option modem` is handled in compat_translate.
function parse_network_sections(raw, result)
{
	for (let name, s in (raw.network ?? {})) {
		switch (s['.type']) {
		case 'wwand_globals':
			apply_globals(s, result);
			break;

		case 'wwand_modem':
			result.modems[name] = modem_from_section(s);
			// dead-option detection travels with the modem config so the
			// per-modem status warnings can surface it in LuCI too
			result.modems[name].config_notes = unknown_opts(s, MODEM_KNOWN_OPTS,
				result.warnings, sprintf('wwand_modem %s', name));
			break;

		case 'wwand_sim':
			if ((s.iccid == null || s.iccid == '') && (s.imsi == null || s.imsi == '')) {
				push(result.warnings, sprintf("wwand_sim %s: no iccid/imsi, ignoring", name));
				break;
			}

			result.sims[name] = sim_from_section(s);
			unknown_opts(s, SIM_KNOWN_OPTS, result.warnings, sprintf('wwand_sim %s', name));
			break;

		case 'wwand_plmnlist':
			result.plmnlists[name] = plmnlist_from_section(s);
			break;
		}
	}
}

// map a netifd device name to { netdev (parent), mux_id, muxed }.
// An explicit mN suffix always means "muxed" — including m0, which requests
// muxing with an auto-assigned channel (QMAP channel 0 is invalid) while the
// link keeps the configured name.
export function parse_netdev(device)
{
	if (device == null)
		return null;

	let m = match(device, /^(wwan[0-9]+)m([0-9]+)$/);

	if (m)
		return { netdev: m[1], mux_id: +m[2], muxed: true };

	return { netdev: device, mux_id: 0, muxed: false };
};

// merge the modem-level options a legacy-style qmi interface section
// carries into the synthesized modem (first interface wins; conflicts warn).
function merge_iface_modem_opts(modem, s, name, mkey, warnings)
{
	let scalars = { pincode: s.pincode, modes: s.modes, mcc: s.mcc, mnc: s.mnc, tty: null };

	for (let key, val in scalars) {
		if (val == null)
			continue;

		if (modem[key] == null)
			modem[key] = val;
		else if (modem[key] != val)
			push(warnings, sprintf("interface %s: conflicting %s ignored (modem %s)", name, key, mkey));
	}

	if (type(s.at_init) == 'array' && !length(modem.at_init))
		modem.at_init = s.at_init;

	// cell lock is a modem-level property; old-style configs carry it on the
	// interface sections (LuCI's "Lock this cell" writes it there)
	let l4 = (type(s.lock_4g) == 'array') ? s.lock_4g :
	         (s.lock_4g != null ? [ s.lock_4g ] : []);

	if (length(l4)) {
		if (!length(modem.lock_4g))
			modem.lock_4g = l4;
		else if (join(',', modem.lock_4g) != join(',', l4))
			push(warnings, sprintf("interface %s: conflicting lock_4g ignored (modem %s)", name, mkey));
	}

	if (s.lock_5g != null) {
		if (modem.lock_5g == null)
			modem.lock_5g = s.lock_5g;
		else if (modem.lock_5g != s.lock_5g)
			push(warnings, sprintf("interface %s: conflicting lock_5g ignored (modem %s)", name, mkey));
	}

	if (s.lock_persist != null)
		modem.lock_persist = bool_opt(s.lock_persist, false);

	if (s.sim_slot != null && !modem.sim_slot)
		modem.sim_slot = +s.sim_slot;

	if (s.location != null)
		modem.location = +s.location > 1;   // old gate: location > 1

	if (s.delay != null)
		modem.delay = +s.delay;

	if (s.failreboot != null)
		modem.failreboot = +s.failreboot;

	if (s.proto_error_limit != null)
		modem.proto_error_limit = +s.proto_error_limit;

	if (s.serial != null)
		modem.serial = s.serial;

	if (s.imei != null)
		modem.imei = s.imei;

	if (s.repower_time != null)
		modem.repower_time = +s.repower_time;

	if (s.zero_rx_timeout != null)
		modem.zero_rx_timeout = +s.zero_rx_timeout;

	if (s.stats_interval != null)
		modem.stats_interval = +s.stats_interval;
}

function compat_translate(raw, result)
{
	for (let name, s in (raw.network ?? {})) {
		// `wwand` is the ONLY proto wwand manages. A stock `proto qmi` interface
		// belongs to uqmi and is never adopted, so exactly one stack owns a given
		// interface and its control device — netifd sources every handler in
		// /lib/netifd/proto, and two of them claiming `qmi` would be settled by
		// load order, which no package can control. Moving an interface over is an
		// explicit act that rewrites it to `proto wwand`: the LuCI modem list,
		// /usr/libexec/wwand/migrate, or the example uci-defaults script.
		// Device blocklist: a non-wwand interface OWNS the device it names, and
		// wwand must not touch it — two dialers on one control node is the one
		// failure the coexistence model has to prevent, and packaging cannot
		// express it. Collected here, logged once at start, enforced when a
		// modem binds and when autosetup considers claiming a device.
		//
		// A DISABLED interface is skipped: netifd never brings it up, so it owns
		// nothing — a stale section must not block a device forever. `@name`
		// references an interface, not a device, so it is skipped too.
		if (s['.type'] == 'interface' && s.proto != 'wwand' &&
		    !bool_opt(s.disabled, false)) {
			for (let opt in [ 'device', 'ifname', 'ctldevice' ]) {
				let dev = s[opt];

				if (dev == null || dev == '' || substr(dev, 0, 1) == '@')
					continue;

				// first claimant wins the attribution; the device is blocked
				// either way
				result.blocked[dev] ??= { interface: name, proto: s.proto ?? '?' };

				// `device` is not always a device NAME. modemmanager's proto
				// takes a sysfs path there ("validate sysfs path given in
				// config" — modemmanager.sh), which would never match a
				// /dev node or a netdev name, so it also has to be recorded
				// as a path-shaped claim. Keyed on the /sys/ prefix: a
				// modemmanager `device` may instead be an mmcli index or a
				// D-Bus path, and neither names hardware we could resolve.
				// (comgt's 3g and directip use `device:device`, a real device
				// node, and are covered by the name above.)
				if (substr(dev, 0, 5) == '/sys/')
					result.blocked_paths[dev] ??= { interface: name,
						proto: s.proto ?? '?', opt: opt };
			}

			// PATH-shaped claims. The stock handlers bind hardware two ways and
			// only one of them is a device name: uqmi and umbim take `devpath`
			// (an absolute sysfs path used as a glob base) and wwan.sh takes
			// `bus` (a USB bus id) — wwan.sh declares no `device` option at all.
			// Those are exactly the configurations a careful user writes, so
			// they must not be the ones that slip through. Kept raw here;
			// config.uc stays filesystem-free, the daemon resolves them.
			for (let opt in [ 'devpath', 'bus' ]) {
				let raw = s[opt];

				if (raw == null || raw == '')
					continue;

				result.blocked_paths[raw] ??= { interface: name, proto: s.proto ?? '?', opt: opt };
			}
		}

		if (s['.type'] != 'interface' || s.proto != 'wwand')
			continue;

		// a disabled interface is not brought up by netifd; don't synthesize a
		// context (nor link one) for it, so the daemon doesn't manage/kick it
		if (bool_opt(s.disabled, false))
			continue;

		// network-native model: references a wwand_modem via `option modem`; the
		// connection (apn/pdp/auth/mux/…) is carried inline on the interface (the
		// old `context` folded in). Radio/SIM options live on the wwand_modem.
		if (s.modem != null) {
			if (!result.modems[s.modem]) {
				push(result.warnings, sprintf("interface %s references unknown modem '%s'", name, s.modem));
				continue;
			}

			let nd = parse_netdev(s.device);
			// mux channel: an explicit `option mux_id` wins (the 2-field UX), else
			// it is derived from a wwan0mN device name.
			let mux_id = (s.mux_id != null) ? +s.mux_id : (nd?.mux_id ?? 0);
			let muxed = (mux_id > 0) || (nd?.muxed ?? false);
			// accept both pdp_type (preferred) and the legacy proto-js pdptype
			let pdp_in = s.pdp_type ?? s.pdptype;

			if (pdp_in != null && !PDP_TYPES[pdp_in])
				push(result.warnings, sprintf("interface %s: invalid pdp_type '%s', using ipv4v6", name, pdp_in));

			result.contexts[name] = context_defaults({
				...conn_fields(s),
				modem: s.modem,
				interface: name,
				mux_id: mux_id,
				muxed: muxed,
				mux_link: derive_mux_link(nd, s.device, mux_id, muxed,
					result.modems[s.modem]?.netdev),
				// explicit `option device` pins the L3 name; a path
				// (/dev/...) is a control device, never an L3 name — and a
				// BARE parent netdev on a muxed context is not one either
				// (the child must never shadow the parent): those fall back
				// to the auto wwandN assignment.
				l3_name: (s.device != null && s.device != '' &&
				          substr(s.device, 0, 1) != '/' &&
				          (!muxed || (nd?.muxed ?? false))) ? s.device : null,
				pdp_type: PDP_TYPES[pdp_in] ? pdp_in : 'ipv4v6',
				profile: (s.profile != null) ? +s.profile : null,
				use_pushed_mtu: bool_opt(s.use_pushed_mtu, true),
				auto: bool_opt(s.auto, true),
				// autosetup marker: this interface was created by the
				// zero-config autosetup and still awaits its one-shot
				// ICCID->APN fill-in (cleared by the daemon afterwards)
				autosetup: bool_opt(s.autosetup, false),
			});

			continue;
		}

		// --- inline/legacy-style interface (no `option modem`) ----

		for (let opt in OLD_DEPRECATED)
			if (s[opt] != null && s[opt] != '' && s[opt] != '0')
				push(result.warnings, sprintf("interface %s: option '%s' is no longer supported, ignoring", name, opt));

		let dev = s.device;

		if (dev != null && substr(dev, 0, 1) == '@') {
			push(result.warnings, sprintf("interface %s: indirect device reference '%s' is not supported, skipping", name, dev));
			continue;
		}

		let nd = parse_netdev(dev);

		if (!nd && s.ctldevice == null) {
			push(result.warnings, sprintf("interface %s: no device/ctldevice option, skipping", name));
			continue;
		}

		// one synthesized modem per parent netdev (or control device)
		let mkey = nd ? sprintf('compat_%s', nd.netdev) : sprintf('compat_%s', s.ctldevice);
		let modem = result.modems[mkey];

		if (!modem) {
			modem = result.modems[mkey] = modem_defaults({
				device: s.ctldevice,
				netdev: nd?.netdev,
			});
		}

		merge_iface_modem_opts(modem, s, name, mkey, result.warnings);

		// context-level options
		let v4 = bool_opt(s.ipv4, true);
		let v6 = bool_opt(s.ipv6, true);
		let pdp = (v4 && v6) ? 'ipv4v6' : (v6 ? 'ipv6' : 'ipv4');

		if (!v4 && !v6) {
			push(result.warnings, sprintf("interface %s: both ipv4 and ipv6 disabled, defaulting to ipv4v6", name));
			pdp = 'ipv4v6';
		}

		// 'pdptype' variant seen in deployed configs wins over the flags
		if (PDP_TYPES[s.pdptype])
			pdp = s.pdptype;

		// mux channel: same rule as the native path — explicit `option mux_id`
		// wins, else derived from a wwan0mN device name.
		let cmux_id = (s.mux_id != null) ? +s.mux_id : (nd?.mux_id ?? 0);
		let cmuxed = (cmux_id > 0) || (nd?.muxed ?? false);

		result.contexts[name] = context_defaults({
			...conn_fields(s),
			modem: mkey,
			interface: name,
			mux_id: cmux_id,
			muxed: cmuxed,
			mux_link: derive_mux_link(nd, dev, cmux_id, cmuxed, null),
			// same explicit-device rule as the native parser (see there)
			l3_name: (dev != null && dev != '' && substr(dev, 0, 1) != '/' &&
			          (!cmuxed || (nd?.muxed ?? false))) ? dev : null,
			pdp_type: pdp,
			use_pushed_mtu: bool_opt(s.use_pushed_mtu, false),   // old default: off
			auto: bool_opt(s.auto, true),
		});
	}
}

// stable L3 device names: every context's datapath netdev gets a deterministic
// name. Explicit interface `option device` wins (any non-path name); everything
// else is auto-assigned wwand0..wwand100 in config order — one flat namespace
// independent of the modem. Raw netdevs are RENAMED to this by the daemon; QMAP
// mux children are created/renamed under it (mux_link unified onto the same name).
function assign_l3_names(result)
{
	let used = {};

	for (let name, c in result.contexts)
		if (c.l3_name)
			used[c.l3_name] = true;

	let next = 0;

	for (let name, c in result.contexts) {
		if (c.l3_name == null) {
			while (used[sprintf('wwand%d', next)])
				next++;

			if (next > 100)
				push(result.warnings, sprintf(
					'interface %s: more than 100 auto-named L3 devices (wwand%d)', name, next));

			c.l3_name = sprintf('wwand%d', next);
			used[c.l3_name] = true;
		}

		// the mux child is claimed by netifd under exactly this name
		if (c.muxed)
			c.mux_link = c.l3_name;
	}
}

function validate(result)
{
	// a wwand_sim is matched at runtime by the active card's ICCID; the modem
	// binding is OPTIONAL — an unbound sim applies to every modem, a bound one
	// only to that modem. A binding to a modem that does not exist is a typo →
	// warn + drop.
	for (let name, sim in result.sims) {
		if (sim.modem != null && !result.modems[sim.modem]) {
			push(result.warnings, sprintf("wwand_sim %s: unknown modem '%s', ignoring", name, sim.modem));
			delete result.sims[name];
		}
	}

	// give each modem the sims it could match (unbound, or bound to it); the
	// daemon then picks the one whose ICCID equals the inserted card's.
	for (let mname, m in result.modems)
		for (let sname, sim in result.sims)
			if (sim.modem == null || sim.modem == mname) {
				m.sims = m.sims ?? [];
				push(m.sims, sim);
			}

	for (let name, ctx in result.contexts) {
		if (ctx.modem == null) {
			push(result.warnings, sprintf("interface %s: no modem reference, ignoring", name));
			delete result.contexts[name];
			continue;
		}

		if (!result.modems[ctx.modem]) {
			push(result.warnings, sprintf("interface %s: unknown modem '%s', ignoring", name, ctx.modem));
			delete result.contexts[name];
			continue;
		}

		if (ctx.mux_id > 0 && result.modems[ctx.modem].mux == 'none') {
			push(result.warnings, sprintf("interface %s: mux_id set but modem '%s' has mux disabled", name, ctx.modem));
			ctx.mux_id = 0;
		}
	}

	for (let name, modem in result.modems) {
		if (modem.device == null && modem.netdev == null && modem.usb_path == null) {
			push(result.warnings, sprintf("modem %s: no device/netdev/usb_path, ignoring", name));
			delete result.modems[name];
		}
	}

	// with QMAP active the parent device only carries mux frames — when any
	// context of a modem is muxed, every other context needs a channel too.
	// Contexts named "...m0" request muxing but need a real channel assigned
	// (QMAP channel 0 is invalid on kernel and modem side).
	let used = {}, needs_id = {}, has_mux = {};

	for (let name, ctx in result.contexts) {
		if (ctx.muxed)
			has_mux[ctx.modem] = true;

		if (ctx.mux_id > 0) {
			used[ctx.modem] = used[ctx.modem] ?? {};
			used[ctx.modem][sprintf('%d', ctx.mux_id)] = true;
		}
		else {
			needs_id[ctx.modem] = needs_id[ctx.modem] ?? [];
			push(needs_id[ctx.modem], name);
		}
	}

	for (let modem, names in needs_id) {
		if (!has_mux[modem])
			continue;

		used[modem] = used[modem] ?? {};

		for (let name in names) {
			let ctx = result.contexts[name];
			let id = 1;

			while (used[modem][sprintf('%d', id)])
				id++;

			used[modem][sprintf('%d', id)] = true;
			ctx.mux_id = id;

			if (!ctx.muxed) {
				ctx.muxed = true;
				push(result.warnings, sprintf(
					"interface %s: modem '%s' uses muxing, auto-assigned mux id %d", name, modem, id));
			}
		}
	}
}

export function parse(raw)
{
	let result = {
		// hold_max: seconds the daemon holds a lost interface up while
		// reconnecting in place before giving up and downing it (netifd teardown)
		globals: { log_level: 'info', hold_max: 90, write_device: true, autosetup: true },
		// devices owned by a non-wwand interface -> { interface, proto }
		blocked: {},
		// path-shaped claims (devpath/bus) -> { interface, proto, opt }; resolved
		// against a modem's hardware path by the daemon, which has the fs access
		blocked_paths: {},
		modems: {},
		contexts: {},
		sims: {},
		plmnlists: {},
		warnings: [],
	};

	parse_network_sections(raw ?? {}, result);
	compat_translate(raw ?? {}, result);
	assign_l3_names(result);

	// resolve each modem's optional plmn_list -> the entries to restore before
	// radio-on; warn on a dangling reference.
	for (let mname, m in result.modems) {
		if (m.plmn_list == null)
			continue;

		let pl = result.plmnlists[m.plmn_list];

		if (pl)
			m.plmn_restore = { type: pl.type, entries: pl.entries };
		else
			push(result.warnings, sprintf("wwand_modem %s: unknown plmn_list '%s', ignoring", mname, m.plmn_list));
	}

	// same for the per-SIM plmn_list (wins over the modem's at runtime, resolved
	// when the active card matches — see the daemon's active_sim handling)
	for (let sname, sm in result.sims) {
		if (sm.plmn_list == null)
			continue;

		let pl = result.plmnlists[sm.plmn_list];

		if (pl)
			sm.plmn_restore = { type: pl.type, entries: pl.entries };
		else
			push(result.warnings, sprintf("wwand_sim %s: unknown plmn_list '%s', ignoring", sname, sm.plmn_list));
	}

	validate(result);

	return result;
};

// --- migration to the network-native model -----------------------------------
// migrate_plan(raw): ordered uci changes converting OLD configs to the
// network-native model, all in /etc/config/network. Stock `proto mbim`/`ncm`
// BREAK once wwand-mbim/-ncm replace the stock handler, so they are converted to
// `proto wwand`; legacy inline `proto qmi` and `proto modemmanager` too (a
// `proto qmi` already carrying
// `option modem` just gets its proto upgraded in place; `proto wwand` skipped).
// Each change is [ op, 'network', section, option|null, value ] with op
// add|set|add_list|delete. Pure + host-testable.

// radio/SIM/hardware options -> the wwand_modem section. NOTE: `usb_path`/`path`
// is deliberately NOT here — the stable USB anchor is optional and not migrated;
// the modem is anchored on the old netdev name instead (put in `device`, which
// discovery resolves as a netdev when it is not a /dev node).
const MIGRATE_MODEM_OPTS = [ 'device', 'netdev', 'serial', 'imei', 'tty', 'mux',
	'dl_datagram_max_size', 'sim_slot', 'pincode', 'modes', 'mcc', 'mnc',
	'lock_4g', 'lock_5g', 'lock_persist', 'at_init', 'location', 'delay',
	'failreboot', 'proto_error_limit', 'zero_rx_timeout', 'stats_interval',
	'repower_time' ];
// options only stripped OFF the interface (moved to nowhere): the optional USB
// anchor and legacy per-family flags/junk have no place on the interface.
const MIGRATE_STRIP_IFACE = [ 'usb_path', 'path', 'ctldevice', 'dhcp',
	'ipv4', 'ipv6', 'mode', 'strongestnetwork', 'autocreateif', 'customroutes' ];
// connection options (apn/auth/username/password/profile/mtu/use_pushed_*/
// settings_poll) simply stay on the interface, so they need no explicit list.

// --- ModemManager (`proto modemmanager`) translation --------------------------
// MM's option set maps mostly 1:1; what has no wwand home is stripped and
// documented (reference.md): preferredmode (wwand has only the allowed set),
// sourcefilter/lowpower/allow_roaming/force_connection (MM runtime behaviors),
// and the init_* attach-bearer group (wwand programs the LTE attach profile
// from the connection's apn/pdp_type). apn/username/password/metric stay.
const MM_MODE_MAP = { '2g': 'gsm', '3g': 'umts', '4g': 'lte', '5g': 'nr5g' };
const MIGRATE_STRIP_IFACE_MM = [ 'device', 'allowedauth', 'allowedmode',
	'preferredmode', 'pincode', 'iptype', 'plmn', 'signalrate', 'sourcefilter',
	'lowpower', 'allow_roaming', 'force_connection', 'init_epsbearer',
	'init_iptype', 'init_allowedauth', 'init_user', 'init_password', 'init_apn' ];

// MM `device` is a FULL sysfs path (/sys/devices/…), possibly down to an
// interface component — wwand's modem `path` is the same anchor relative to
// /sys/devices (wireless-style; discovery also accepts a bare '1-1.2' id).
function mm_path(dev)
{
	let p = replace(dev, /^\/sys\/devices\//, '');

	// drop a trailing USB interface component ("…/1-1:1.4" -> "…/1-1")
	return replace(p, /:[0-9]+\.[0-9]+$/, '');
}

// MM allowedauth is a list (or space/comma string) of pap/chap/mschap*/eap;
// wwand knows none|pap|chap|both. mschap*/eap have no equivalent -> null.
function mm_auth(v)
{
	let items = (type(v) == 'array') ? v : split(sprintf('%s', v ?? ''), /[ ,|]+/);
	let pap = false, chap = false;

	for (let a in items) {
		if (a == 'pap') pap = true;
		else if (a == 'chap') chap = true;
	}

	return (pap && chap) ? 'both' : pap ? 'pap' : chap ? 'chap' : null;
}

// MM allowedmode '4g|5g' -> wwand modes 'lte,nr5g'; 'any'/empty -> null (=all)
function mm_modes(v)
{
	if (v == null || v == '' || v == 'any')
		return null;

	let out = [];

	for (let m in split(sprintf('%s', v), /[|,]/)) {
		let w = MM_MODE_MAP[trim(m)];

		if (w)
			push(out, w);
	}

	return length(out) ? join(',', out) : null;
}

// MM plmn '26201' -> { mcc: '262', mnc: '01' } (mnc kept as string so the
// leading zero survives); malformed -> null
function mm_plmn(v)
{
	let s = sprintf('%s', v ?? '');

	if (!match(s, /^[0-9]{5,6}$/))
		return null;

	return { mcc: substr(s, 0, 3), mnc: substr(s, 3) };
}

export function migrate_plan(raw)
{
	let net = raw?.network ?? {};
	let changes = [];
	let modem_by_ident = {};   // modem identity -> wwand_modem section name

	// allocate `wwmodemN` section names that do NOT collide with sections
	// already present in the config — a box may already carry wwand_modem
	// sections (an existing wwand modem, or a prior partial migration), and
	// reusing `wwmodem0` would silently overwrite one. Skip every existing
	// section name, not just wwand_modem, to be safe.
	let seq = 0;
	let next_modem_name = () => {
		let name = sprintf('wwmodem%d', seq++);

		while (net[name] != null)
			name = sprintf('wwmodem%d', seq++);

		return name;
	};

	let put = (section, opt, val) => {
		if (type(val) == 'array') {
			for (let v in val)
				push(changes, [ 'add_list', 'network', section, opt, sprintf('%s', v) ]);
		}
		else {
			push(changes, [ 'set', 'network', section, opt,
				(type(val) == 'bool') ? (val ? '1' : '0') : sprintf('%s', val) ]);
		}
	};

	// create (once per identity) a wwand_modem section from an interface's radio/
	// SIM options; return its name.
	let ensure_modem = (ident, s) => {
		if (modem_by_ident[ident])
			return modem_by_ident[ident];

		let name = next_modem_name();
		modem_by_ident[ident] = name;
		push(changes, [ 'add', 'network', name, null, 'wwand_modem' ]);

		for (let k in MIGRATE_MODEM_OPTS) {
			let v = s[k];

			// legacy interface `device` is a NETDEV name (wwan0 / wwan0mN), not a
			// control /dev node. Anchor the modem on it in `device` — for a muxed
			// child use the PARENT netdev (mN is the connection's mux channel).
			// discovery resolves a non-/dev `device` as a netdev name; a real
			// /dev/... path is kept as-is.
			if (k == 'device' && v != null && v != '') {
				let nd = (substr(v, 0, 1) == '/') ? null : parse_netdev(v);
				put(name, 'device', (nd && nd.muxed) ? nd.netdev : v);
				continue;
			}

			// stock ncm uses `mode` for the RAT restriction
			if (k == 'modes' && (v == null || v == ''))
				v = s.mode;

			if (v != null && v != '')
				put(name, k, v);
		}

		return name;
	};

	for (let name, s in net) {
		if (s['.type'] != 'interface')
			continue;

		let proto = s.proto;

		if (proto != 'wwand' && proto != 'qmi' && proto != 'mbim' &&
		    proto != 'ncm' && proto != 'modemmanager')
			continue;

		// already network-native: skip a `proto wwand` interface outright; a
		// `proto qmi` one (older wwand) just needs its proto name upgraded.
		if (s.modem != null) {
			if (proto == 'qmi')
				push(changes, [ 'set', 'network', name, 'proto', 'wwand' ]);

			continue;
		}

		// --- ModemManager interface --------------------------------------
		// MM's `device` is a full sysfs path — the ONLY anchor the section
		// carries (no netdev, no /dev node). It maps to the modem's `path`
		// (the wireless-style sysfs anchor discovery resolves), a deliberate
		// deviation from the netdev-anchor rule below; the control protocol
		// needs no option at all (discovery reads the driver binding).
		if (proto == 'modemmanager') {
			if (s.device == null || s.device == '')
				continue;

			let ident = 'mm:' + s.device;
			let modem = modem_by_ident[ident];

			if (!modem) {
				modem = next_modem_name();
				modem_by_ident[ident] = modem;
				push(changes, [ 'add', 'network', modem, null, 'wwand_modem' ]);
				put(modem, 'path', mm_path(s.device));

				if (s.pincode != null && s.pincode != '')
					put(modem, 'pincode', s.pincode);

				let modes = mm_modes(s.allowedmode);
				if (modes)
					put(modem, 'modes', modes);

				let plmn = mm_plmn(s.plmn);
				if (plmn) {
					put(modem, 'mcc', plmn.mcc);
					put(modem, 'mnc', plmn.mnc);
				}

				if (s.signalrate != null && s.signalrate != '')
					put(modem, 'stats_interval', s.signalrate);
			}

			put(name, 'proto', 'wwand');
			put(name, 'modem', modem);

			// values are identical (ipv4/ipv6/ipv4v6) — a straight rename
			if (s.iptype != null && s.iptype != '')
				put(name, 'pdp_type', s.iptype);

			let auth = mm_auth(s.allowedauth);
			if (auth)
				put(name, 'auth', auth);

			for (let k in MIGRATE_STRIP_IFACE_MM)
				if (s[k] != null)
					push(changes, [ 'delete', 'network', name, k, null ]);

			continue;
		}

		// the modem identity: for a wwan0mN device the PARENT netdev is the modem
		// (the mN is the connection's mux channel), so several muxed interfaces
		// share one wwand_modem. option-context configs (radio/SIM in
		// /etc/config/wwand) are left to the compat layer.
		let nd0 = parse_netdev(s.device);
		let ident = (nd0 ? nd0.netdev : null) ?? s.netdev ?? s.usb_path ?? s.ctldevice;

		if (s.context != null || ident == null)
			continue;

		let modem = ensure_modem(ident, s);
		let nd = parse_netdev(s.device);

		// interface: proto -> wwand, reference the modem, keep the connection
		// options (apn/auth/…) that are ALREADY on the interface in place.
		// (a bare legacy `proto qmi` reaches here too and is upgraded to wwand.)
		put(name, 'proto', 'wwand');

		put(name, 'modem', modem);

		if (nd?.muxed)
			put(name, 'mux_id', nd.mux_id);

		// pdp_type: prefer an explicit pdp_type/pdptype; otherwise DERIVE it from
		// the legacy ipv4/ipv6 boolean flags. Without this last step, dropping
		// those flags below would silently widen an ipv4-only (or ipv6-only)
		// interface to the ipv4v6 default — a real behaviour change on carriers
		// pinned to one family (seen migrating a Telekom ipv4-only wan).
		if (s.pdp_type != null && s.pdp_type != '') {
			put(name, 'pdp_type', s.pdp_type);
		}
		else if (s.pdptype != null && s.pdptype != '') {
			put(name, 'pdp_type', s.pdptype);
			push(changes, [ 'delete', 'network', name, 'pdptype', null ]);
		}
		else if (s.ipv4 != null || s.ipv6 != null) {
			let v4 = bool_opt(s.ipv4, true), v6 = bool_opt(s.ipv6, true);
			put(name, 'pdp_type', (v4 && v6) ? 'ipv4v6' : (v6 ? 'ipv6' : 'ipv4'));
		}

		// the radio/SIM options moved to the wwand_modem -> drop them here;
		// plus the optional USB anchor and stock junk that have no place on the
		// interface (the anchor is not migrated onto the modem either).
		for (let k in [ ...MIGRATE_MODEM_OPTS, ...MIGRATE_STRIP_IFACE ])
			if (s[k] != null)
				push(changes, [ 'delete', 'network', name, k, null ]);
	}

	return changes;
};

// find the context serving a given netifd interface
export function context_for_interface(result, interface)
{
	for (let name, ctx in result.contexts)
		if (ctx.interface == interface)
			return name;

	return null;
};
