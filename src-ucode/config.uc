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
//   globals:  { log_level, hold_max },
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
		sim_slot: 0,
		stats_interval: 60,
		auto_correct_config: false,   // gated runtime auto-correction (default off)
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
		auto: true,   // netifd 'auto 0' => daemon won't proactively bring it up
		...(over ?? {}),
	};
}

// apply a globals section (log_level, hold_max) — shared by the old
// `config wwand 'globals'` (wwand file) and the new `config wwand_globals`
// (network file).
function apply_globals(s, result)
{
	result.globals.log_level = s.log_level ?? result.globals.log_level;

	if (s.hold_max != null) {
		let hm = +s.hold_max;

		if (hm > 0)
			result.globals.hold_max = hm;
		else
			push(result.warnings, sprintf('invalid hold_max %J, keeping %d',
				s.hold_max, result.globals.hold_max));
	}
}

// build a modem config from a raw section — shared by the old `config modem`
// (wwand file) and the new `config wwand_modem` (network file); both carry the
// identical option set.
function modem_from_section(s)
{
	return modem_defaults({
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
		sim_slot: +(s.sim_slot ?? 0),
		stats_interval: +(s.stats_interval ?? 60),
		auto_correct_config: bool_opt(s.auto_correct_config, false),
	});
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
		pincode: s.pincode,
		apn: s.apn,
		auth: s.auth,
		username: s.username,
		password: s.password,
	};
}

function parse_wwand_sections(raw, result)
{
	for (let name, s in (raw.wwand ?? {})) {
		switch (s['.type']) {
		case 'wwand':
			apply_globals(s, result);
			break;

		case 'modem':
			result.modems[name] = modem_from_section(s);
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

// parse the network-native wwand sections (the goal model: no /etc/config/wwand).
// These are WireGuard-style typed sections living in /etc/config/network:
//   config wwand_globals 'globals'   -> log_level / hold_max
//   config wwand_modem   '<name>'    -> a modem (same options as `config modem`)
//   config wwand_sim     '<name>'    -> a per-SIM override (modem + iccid keyed)
// The interface (proto qmi) that references a wwand_modem via `option modem` is
// handled in compat_translate alongside the other interface generations.
function parse_network_sections(raw, result)
{
	for (let name, s in (raw.network ?? {})) {
		switch (s['.type']) {
		case 'wwand_globals':
			apply_globals(s, result);
			break;

		case 'wwand_modem':
			result.modems[name] = modem_from_section(s);
			break;

		case 'wwand_sim':
			if (s.iccid == null || s.iccid == '') {
				push(result.warnings, sprintf("wwand_sim %s: no iccid, ignoring", name));
				break;
			}

			result.sims[name] = sim_from_section(s);
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

// merge the modem-level options an old-style qmi-advanced interface section
// carries into the synthesized modem (first interface wins; conflicts warn).
// Extracted from compat_translate so its per-interface loop reads as its
// distinct steps: skip-checks -> device resolution -> THIS -> context build.
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

	if (s.zero_rx_timeout != null)
		modem.zero_rx_timeout = +s.zero_rx_timeout;

	if (s.stats_interval != null)
		modem.stats_interval = +s.stats_interval;
}

function compat_translate(raw, result)
{
	for (let name, s in (raw.network ?? {})) {
		if (s['.type'] != 'interface' || s.proto != 'qmi')
			continue;

		// a disabled interface is not brought up by netifd; don't synthesize a
		// context (nor link one) for it, so the daemon doesn't manage/kick it
		if (bool_opt(s.disabled, false))
			continue;

		// current model: references a context section (in /etc/config/wwand)
		if (s.context != null) {
			if (result.contexts[s.context]) {
				result.contexts[s.context].interface = name;
				// 'auto 0' interfaces are not started at boot — the daemon must
				// not proactively kick them up (only adopt them if already up)
				result.contexts[s.context].auto = bool_opt(s.auto, true);
			}
			else
				push(result.warnings, sprintf("interface %s references unknown context '%s'", name, s.context));

			continue;
		}

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
				modem: s.modem,
				interface: name,
				mux_id: mux_id,
				muxed: muxed,
				mux_link: muxed ? (s.device ?? sprintf('%sm%d', nd?.netdev ?? 'wwan0', mux_id)) : null,
				apn: s.apn,
				pdp_type: PDP_TYPES[pdp_in] ? pdp_in : 'ipv4v6',
				auth: s.auth,
				username: s.username,
				password: s.password,
				profile: (s.profile != null) ? +s.profile : null,
				mtu: (s.mtu != null) ? +s.mtu : null,
				use_pushed_mtu: bool_opt(s.use_pushed_mtu, true),
				use_pushed_prefix: bool_opt(s.use_pushed_prefix, false),
				settings_poll: +(s.settings_poll ?? 300),
				auto: bool_opt(s.auto, true),
			});

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
			auto: bool_opt(s.auto, true),
		});
	}
}

function validate(result)
{
	// attach each per-SIM override to its modem; the daemon picks the matching
	// one at bring-up by the active card's ICCID. Drop overrides whose modem
	// reference is unknown.
	for (let name, sim in result.sims) {
		if (sim.modem == null || !result.modems[sim.modem]) {
			push(result.warnings, sprintf("wwand_sim %s: unknown modem '%s', ignoring", name, sim.modem));
			delete result.sims[name];
			continue;
		}

		let m = result.modems[sim.modem];
		m.sims = m.sims ?? [];
		push(m.sims, sim);
	}

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
		// hold_max: seconds the daemon holds a lost interface up while
		// reconnecting in place before giving up and downing it (netifd teardown)
		globals: { log_level: 'info', hold_max: 90 },
		modems: {},
		contexts: {},
		sims: {},
		warnings: [],
	};

	parse_wwand_sections(raw ?? {}, result);
	parse_network_sections(raw ?? {}, result);
	compat_translate(raw ?? {}, result);
	validate(result);

	return result;
}

// --- migration to the network-native model -----------------------------------
// migrate_plan(raw) returns an ordered list of uci changes that convert OLD
// configs to the WireGuard-style network-native model (wwand_modem + interface
// `option modem` + connection inline), all in /etc/config/network. It handles:
//   - stock OpenWrt `proto mbim` (umbim) / `proto ncm` (comgt-ncm) interfaces —
//     these BREAK once wwand-mbim/-ncm replace the stock handler, so converting
//     them to `proto qmi` (wwand's proto) is what lets netifd invoke wwand;
//   - wwand legacy inline `proto qmi` interfaces.
// Already-new interfaces (`proto qmi` + `option modem`) are skipped. Each change
// is [ op, 'network', section, option|null, value ]; op is 'add' (create a typed
// section), 'set', 'add_list' or 'delete'. Pure + host-testable.

// radio/SIM/hardware options -> the wwand_modem section
const MIGRATE_MODEM_OPTS = [ 'device', 'netdev', 'usb_path', 'tty', 'mux',
	'dl_datagram_max_size', 'sim_slot', 'pincode', 'modes', 'mcc', 'mnc',
	'lock_4g', 'lock_5g', 'lock_persist', 'at_init', 'location', 'delay',
	'failreboot', 'zero_rx_timeout', 'stats_interval' ];
// connection options (apn/auth/username/password/profile/mtu/use_pushed_*/
// settings_poll) simply stay on the interface, so they need no explicit list.

export function migrate_plan(raw)
{
	let net = raw?.network ?? {};
	let changes = [];
	let modem_by_ident = {};   // modem identity -> wwand_modem section name
	let seq = 0;

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

		let name = sprintf('wwmodem%d', seq++);
		modem_by_ident[ident] = name;
		push(changes, [ 'add', 'network', name, null, 'wwand_modem' ]);

		for (let k in MIGRATE_MODEM_OPTS) {
			// the modem identity itself: for a wwan0mN device the parent netdev
			// is the modem, the mN is the connection's mux channel
			let v = s[k];

			if (k == 'device' && v != null) {
				let nd = parse_netdev(v);
				v = nd?.muxed ? nd.netdev : v;
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

		if (proto != 'qmi' && proto != 'mbim' && proto != 'ncm')
			continue;

		// already network-native
		if (proto == 'qmi' && s.modem != null)
			continue;

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

		// interface: proto -> qmi, reference the modem, keep the connection
		// options (apn/auth/…) that are ALREADY on the interface in place.
		if (proto != 'qmi')
			put(name, 'proto', 'qmi');

		put(name, 'modem', modem);

		if (nd?.muxed)
			put(name, 'mux_id', nd.mux_id);

		// pdp_type: rename the stock/legacy `pdptype`
		if (s.pdptype != null && s.pdptype != '') {
			put(name, 'pdp_type', s.pdp_type ?? s.pdptype);
			push(changes, [ 'delete', 'network', name, 'pdptype', null ]);
		}

		// the radio/SIM options moved to the wwand_modem -> drop them here
		for (let k in MIGRATE_MODEM_OPTS)
			if (s[k] != null)
				push(changes, [ 'delete', 'network', name, k, null ]);

		// stock proto junk that has no place in the wwand model
		for (let j in [ 'ctldevice', 'dhcp', 'ipv4', 'ipv6', 'mode',
		                'strongestnetwork', 'autocreateif', 'customroutes' ])
			if (s[j] != null)
				push(changes, [ 'delete', 'network', name, j, null ]);
	}

	return changes;
}

// find the context serving a given netifd interface
export function context_for_interface(result, interface)
{
	for (let name, ctx in result.contexts)
		if (ctx.interface == interface)
			return name;

	return null;
}
