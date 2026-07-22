// wwand — configuration model.
//
// parse(raw) is pure: it receives plain section objects (as returned by
// uci cursor.get_all()) and produces the internal model. UCI access itself
// happens in main.uc so this stays host-testable.
//
// raw = {
//   wwand:    sections of /etc/config/wwand    (may be null),
//   network: sections of /etc/config/network (may be null),
// }
//
// result = {
//   globals:  { log_level },
//   modems:   { name: { device?, netdev?, usb_path?, pincode?, modes?, mcc?,
//                       mnc?, mux, dl_datagram_max_size, tty?, at_init[],
//                       location, delay, failreboot, zero_rx_timeout } },
//   contexts: { name: { modem, interface?, mux_id, apn?, pdp_type, auth?,
//                       username?, password?, profile?, mtu?, use_pushed_mtu } },
//   warnings: [ ... ],
// }
//
// Compat: network sections with proto 'qmi' and no 'context' option are
// old-style qmi-advanced interfaces and get translated in-memory: the parent
// netdev becomes a synthesized modem, the interface becomes a context.
// Options that only made sense in the old bash implementation are reported
// as deprecation warnings and ignored.

'use strict';

const OLD_DEPRECATED = [ 'dhcp', 'autocreateif', 'customroutes', 'strongestnetwork' ];

// options handled by netifd itself; silently left alone
const NETIFD_OPTS = [ 'defaultroute', 'peerdns', 'metric', 'ip4table', 'ip6table' ];

const PDP_TYPES = { ipv4: true, ipv6: true, ipv4v6: true };

function bool_opt(v, dflt)
{
	if (v == null)
		return dflt;

	return !(v == '0' || v == 'false' || v == 'off' || v == 'no');
}

export function modem_defaults(over)
{
	return {
		device: null, netdev: null, usb_path: null,
		pincode: null, modes: null, mcc: null, mnc: null,
		mux: 'auto', dl_datagram_max_size: 0, tty: null,
		at_init: [], location: false, delay: 0,
		failreboot: 100, zero_rx_timeout: 21600,
		lock_4g: [], lock_5g: null, lock_persist: false,
		stats_interval: 60,
		...(over ?? {}),
	};
}

export function context_defaults(over)
{
	return {
		modem: null, interface: null, mux_id: 0,
		muxed: false, mux_link: null,
		apn: null, pdp_type: 'ipv4v6', auth: null,
		username: null, password: null, profile: null,
		mtu: null, use_pushed_mtu: true,
		use_pushed_prefix: false,
		settings_poll: 300,
		...(over ?? {}),
	};
}

function parse_wwand_sections(raw, result)
{
	for (let name, s in (raw.wwand ?? {})) {
		switch (s['.type']) {
		case 'wwand':
			result.globals.log_level = s.log_level ?? result.globals.log_level;
			break;

		case 'modem':
			result.modems[name] = modem_defaults({
				device: s.device,
				netdev: s.netdev,
				usb_path: s.usb_path,
				pincode: s.pincode,
				modes: s.modes,
				mcc: s.mcc,
				mnc: s.mnc,
				mux: s.mux ?? 'auto',
				dl_datagram_max_size: +(s.dl_datagram_max_size ?? 0),
				tty: s.tty,
				at_init: (type(s.at_init) == 'array') ? s.at_init :
				         (s.at_init != null ? [ s.at_init ] : []),
				location: bool_opt(s.location, false),
				delay: +(s.delay ?? 0),
				failreboot: +(s.failreboot ?? 100),
				zero_rx_timeout: +(s.zero_rx_timeout ?? 21600),
				lock_4g: (type(s.lock_4g) == 'array') ? s.lock_4g :
				         (s.lock_4g != null ? [ s.lock_4g ] : []),
				lock_5g: s.lock_5g,
				lock_persist: bool_opt(s.lock_persist, false),
				stats_interval: +(s.stats_interval ?? 60),
			});
			break;

		case 'context':
			if (s.pdp_type != null && !PDP_TYPES[s.pdp_type])
				push(result.warnings, sprintf("context %s: invalid pdp_type '%s', using ipv4v6", name, s.pdp_type));

			result.contexts[name] = context_defaults({
				modem: s.modem,
				mux_id: +(s.mux_id ?? 0),
				muxed: +(s.mux_id ?? 0) > 0,
				mux_link: s.mux_link,
				apn: s.apn,
				pdp_type: PDP_TYPES[s.pdp_type] ? s.pdp_type : 'ipv4v6',
				auth: s.auth,
				username: s.username,
				password: s.password,
				profile: (s.profile != null) ? +s.profile : null,
				mtu: (s.mtu != null) ? +s.mtu : null,
				use_pushed_mtu: bool_opt(s.use_pushed_mtu, true),
				use_pushed_prefix: bool_opt(s.use_pushed_prefix, false),
				settings_poll: +(s.settings_poll ?? 300),
			});
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
}

function compat_translate(raw, result)
{
	for (let name, s in (raw.network ?? {})) {
		if (s['.type'] != 'interface' || s.proto != 'qmi')
			continue;

		// new-style interface: references a context section
		if (s.context != null) {
			if (result.contexts[s.context])
				result.contexts[s.context].interface = name;
			else
				push(result.warnings, sprintf("interface %s references unknown context '%s'", name, s.context));

			continue;
		}

		// --- old-style qmi-advanced interface ---------------------------

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

		// modem-level options: first interface wins, conflicts are warned
		let modem_opts = {
			pincode: s.pincode,
			modes: s.modes,
			mcc: s.mcc,
			mnc: s.mnc,
			tty: null,
		};

		for (let key, val in modem_opts) {
			if (val == null)
				continue;

			if (modem[key] == null)
				modem[key] = val;
			else if (modem[key] != val)
				push(result.warnings, sprintf("interface %s: conflicting %s ignored (modem %s)", name, key, mkey));
		}

		if (type(s.at_init) == 'array' && !length(modem.at_init))
			modem.at_init = s.at_init;

		// cell lock is a modem-level property; old-style configs carry it on
		// the interface sections (LuCI's "Lock this cell" writes it there)
		let l4 = (type(s.lock_4g) == 'array') ? s.lock_4g :
		         (s.lock_4g != null ? [ s.lock_4g ] : []);

		if (length(l4)) {
			if (!length(modem.lock_4g))
				modem.lock_4g = l4;
			else if (join(',', modem.lock_4g) != join(',', l4))
				push(result.warnings, sprintf("interface %s: conflicting lock_4g ignored (modem %s)", name, mkey));
		}

		if (s.lock_5g != null) {
			if (modem.lock_5g == null)
				modem.lock_5g = s.lock_5g;
			else if (modem.lock_5g != s.lock_5g)
				push(result.warnings, sprintf("interface %s: conflicting lock_5g ignored (modem %s)", name, mkey));
		}

		if (s.lock_persist != null)
			modem.lock_persist = bool_opt(s.lock_persist, false);

		if (s.location != null)
			modem.location = +s.location > 1;   // old gate: location > 1

		if (s.delay != null)
			modem.delay = +s.delay;

		if (s.failreboot != null)
			modem.failreboot = +s.failreboot;

		if (s.zero_rx_timeout != null)
			modem.zero_rx_timeout = +s.zero_rx_timeout;

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

		result.contexts[name] = context_defaults({
			modem: mkey,
			interface: name,
			mux_id: nd?.mux_id ?? 0,
			muxed: nd?.muxed ?? false,
			mux_link: nd?.muxed ? dev : null,
			apn: s.apn,
			pdp_type: pdp,
			auth: s.auth,
			username: s.username,
			password: s.password,
			mtu: (s.mtu != null) ? +s.mtu : null,
			use_pushed_mtu: bool_opt(s.use_pushed_mtu, false),   // old default: off
			use_pushed_prefix: bool_opt(s.use_pushed_prefix, false),
			settings_poll: +(s.settings_poll ?? 300),
		});
	}
}

function validate(result)
{
	for (let name, ctx in result.contexts) {
		if (ctx.modem == null) {
			push(result.warnings, sprintf("context %s: no modem reference, ignoring", name));
			delete result.contexts[name];
			continue;
		}

		if (!result.modems[ctx.modem]) {
			push(result.warnings, sprintf("context %s: unknown modem '%s', ignoring", name, ctx.modem));
			delete result.contexts[name];
			continue;
		}

		if (ctx.mux_id > 0 && result.modems[ctx.modem].mux == 'none') {
			push(result.warnings, sprintf("context %s: mux_id set but modem '%s' has mux disabled", name, ctx.modem));
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
					"context %s: modem '%s' uses muxing, auto-assigned mux id %d", name, modem, id));
			}
		}
	}
}

export function parse(raw)
{
	let result = {
		globals: { log_level: 'info' },
		modems: {},
		contexts: {},
		warnings: [],
	};

	parse_wwand_sections(raw ?? {}, result);
	compat_translate(raw ?? {}, result);
	validate(result);

	return result;
}

// find the context serving a given netifd interface
export function context_for_interface(result, interface)
{
	for (let name, ctx in result.contexts)
		if (ctx.interface == interface)
			return name;

	return null;
}
