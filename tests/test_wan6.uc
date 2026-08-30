// wwand tests — the RNDIS v6 model's dynamic dhcpv6 subinterface wiring.
//
// On an RNDIS datapath the modem's v6 arrives via RA on the parent netdev;
// wwand ensures a dhcpv6 subinterface bound to the parent's device (@<parent>,
// <parent>_6 naming) via netifd's ubus add_dynamic — runtime-only, nothing
// written to /etc/config/network, `auto: true` hands the lifecycle to netifd.
// Gating under test:
//   - context 'up' on an rndis_host datapath + v6-capable pdp -> ensure_wan6
//   - the same on a pdp ipv4 context -> NOT called
//   - modem 'removed' -> NO daemon action (netifd auto-manages the dynamic
//     subinterface across device loss; the @device alias re-arms it)
//   - a non-rndis datapath -> never touched
//
// It also covers the two other cases where the daemon REFUSES to start a modem
// and has to explain itself through control_note rather than looking absent: a
// control device a foreign dialer owns, and a missing datapath-plugin package.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as fs from 'fs';
import * as config from 'wwand/config.uc';
import * as daemon_mod from 'wwand/daemon.uc';

const TIMING = { sync_retry: 1, settle: 1, sim_settle: 1, card_poll: 1,
	reg_timeout: 500, backoff_min: 40, backoff_max: 60, hold_max_ms: 120 };

// one stubbed daemon: the modem stub carries the rndis_host datapath and both
// create() calls capture their on_event bindings; ensure_wan6 is recorded
let kicks = [];
let autostart = true;

function mk(pdp, ensures)
{
	let ctx_on_event = null;
	let modem_on_event = null;

	let modem_stub = {
		id: 'm0',
		start: () => null, stop: () => null,
		note_connect_success: () => null, note_connect_failure: () => null,
		datapath: { backend: 'rndis_host' },
	};

	let d = daemon_mod.create({
		timing: TIMING,
		deps: {
			log: (lvl, msg) => null,
			load_qmi: () => ({
				modem: {
					create: (o) => {
						// mirror the daemon's own binding: the handler receives
						// the real objects
						modem_on_event = (ev) => o.deps.on_event(modem_stub, ev, null);
						return modem_stub;
					},
				},
				context: {
					create: (o) => {
						let ctx = { state: 'IDLE', config: o.config, modem: o.modem };
						ctx_on_event = (ev) => o.deps.on_event(ctx, ev, null);
						return ctx;
					},
				},
			}),
			emit_event: () => null,
			kick_interface: (i) => push(kicks, i),
			renew_interface: () => null,
			down_interface: () => null,
			iface_status: (iface, cb) => cb({ up: false, autostart: autostart }),
			datapath_fx: null,
			read_config: () => config.parse({ network: {
				m0: { '.type': 'wwand_modem', device: '/dev/mock0' },
				wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', pdp_type: pdp },
			} }),
			resolve_modem_device: (cfg) => cfg.device,
			resolve_netdev: (cfg, device) => 'wwand0',
			learn_device: () => null,
			learn_modem_path: () => null,
			ensure_wan6: (p, pdp) => push(ensures, sprintf('%s/%s', p, pdp ?? '-')),
		},
	});

	d.apply_config(config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/mock0' },
		wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', pdp_type: pdp },
	} }));

	return { d: d, ctx: () => ctx_on_event, modem: () => modem_on_event };
}

// --- scenario 1: v6-capable pdp on rndis -> ensure on connect ---------------
let ensures = [];
let s1 = mk('ipv6', ensures);

s1.ctx()('up');

eq(ensures, [ 'wan/ipv6' ],
	'wan6: context up on rndis + ipv6 pdp -> ensure_wan6(wan) with the pdp type');

// The pdp type has to REACH ensure_wan6: it is what decides whether the
// subinterface gets extendprefix=1 (RFC 7278). A mobile network hands out a
// single /64 and delegates no prefix, so without it odhcp6c has nothing to
// give the LAN and clients get no address at all.
ensures = [];
let s1b = mk('ipv4v6', ensures);
s1b.ctx()('up');
eq(ensures, [ 'wan/ipv4v6' ],
	'wan6: an ipv4v6 context passes its own pdp type (no extendprefix default there)');

// extendprefix is set for EVERY v6-capable PDP, ipv4v6 included, and the
// subinterface only exists for those — so the pdp type that arrives here is
// diagnostic, not a decision. What RFC 7278 answers is IPv6 with no delegated
// prefix; the presence of IPv4 is irrelevant to it (that is RFC 6877's
// problem). A dual-stack PDP gets the same undelegated /64, so its LAN is
// equally without IPv6 — working IPv4 just hides it. And keying on ipv6-only
// missed almost everything anyway, since pdp_type defaults to ipv4v6.

// --- scenario 2: pdp ipv4 -> no v6 subinterface ------------------------------
ensures = [];
let s2 = mk('ipv4', ensures);

s2.ctx()('up');

eq(ensures, [], 'wan6: pdp ipv4 -> no dhcpv6 subinterface');

// --- scenario 3: modem gone -> no daemon action ------------------------------
// the dynamic subinterface is netifd's: auto:1 + the @device alias let it go
// down with the vanished parent and come back up on its own when the device
// re-appears (reconnect / re-enumeration). wwand never removes it.
ensures = [];
let s3 = mk('ipv4v6', ensures);

s3.modem()('removed');

eq(ensures, [], 'wan6: modem removed -> no daemon action (netifd auto-manages)');

// --- scenario 4: non-rndis datapath -> never touched -------------------------
ensures = [];
let s4 = mk('ipv6', ensures);

s4.d.modems.m0.modem.datapath = { backend: 'qmi_wwan' };
s4.ctx()('up');

eq(ensures, [], 'wan6: qmi_wwan datapath -> no dhcpv6 subinterface');

// --- device blocklist: a modem on a foreign-owned device is not started ------
//
// The coexistence model rests on exactly one dialer owning a control node.
// Packaging cannot express that, so the daemon enforces it: a device named by a
// non-wwand interface is refused, with the reason on the modem's control_note
// rather than the modem merely looking absent.

let started = [];
let blk_logs = [];

function mkblk(raw)
{
	let parsed = config.parse(raw);
	let d = daemon_mod.create({
		timing: TIMING,
		deps: {
			log: (lvl, msg) => push(blk_logs, msg),
			load_qmi: () => ({
				modem: { create: (o) => { push(started, o.config.device ?? '?');
					return { id: 'm', start: () => null, stop: () => null,
					         note_connect_success: () => null, note_connect_failure: () => null,
					         datapath: {} }; } },
				context: { create: (o) => ({ state: 'IDLE', config: o.config, modem: o.modem }) },
			}),
			emit_event: () => null, kick_interface: () => null, renew_interface: () => null,
			down_interface: () => null, iface_status: (i, cb) => cb({ up: false }),
			datapath_fx: null, read_config: () => parsed,
			resolve_modem_device: (cfg) => cfg.device,
			resolve_netdev: () => 'wwan0',
			learn_device: () => null, learn_modem_path: () => null,
		},
	});
	d.apply_config(parsed);
	return d;
}

// the modem points at a device a stock `proto qmi` interface owns
let dblk = mkblk({ network: {
	m0:  { '.type': 'wwand_modem', device: '/dev/cdc-wdm0' },
	wan: { '.type': 'interface', proto: 'qmi', device: '/dev/cdc-wdm0' },
} });

eq(started, [], 'blocklist: a modem on a foreign-owned device is never started');
ok(dblk.modems.m0 != null, 'blocklist: the modem entry still exists (so status can explain it)');
ok(match(dblk.modems.m0.control_note ?? '', /owned by interface wan \(proto qmi\)/),
	'blocklist: control_note names the owning interface and proto');
ok(length(filter(blk_logs, (m) => match(m, /device blocklist:/))) == 1,
	'blocklist: the claim set is logged once at start');

// same modem, no foreign claim -> started normally
started = [];
let dok = mkblk({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/cdc-wdm0' },
} });

eq(started, [ '/dev/cdc-wdm0' ], 'blocklist: an unclaimed device starts as before');
eq(dok.modems.m0.control_note ?? null, null, 'blocklist: no note when nothing claims it');

// --- datapath plugin package -------------------------------------------------
//
// `option mux` may name an add-on datapath (wwand.datapath_<name>, require()d
// by the daemon and threaded down to netlink.setup). Missing package -> the same
// treatment as a missing control backend: a control_note, no crash, no silent
// fallback to a datapath the config did not ask for.
started = [];
let dp_asked = [];
let dplug = { links: () => [] };

function mkdp(mux, impl, real, scandir)
{
	let parsed = config.parse({ network: {
		m0: { '.type': 'wwand_modem', device: '/dev/cdc-wdm0', mux: mux },
	} });
	let d = daemon_mod.create({
		timing: TIMING,
		deps: {
			log: (lvl, msg) => push(blk_logs, msg),
			// `real` exercises the daemon's OWN require()-based loader instead
			// of a stub — the packaging contract, see below
			load_datapath: real ? null : ((n) => { push(dp_asked, n); return impl; }),
			load_qmi: () => ({
				modem: { create: (o) => { push(started, o.datapath?.plugins ?? 'builtin');
					return { id: 'm', start: () => null, stop: () => null,
					         note_connect_success: () => null, note_connect_failure: () => null,
					         datapath: {} }; } },
				context: { create: (o) => ({ state: 'IDLE', config: o.config, modem: o.modem }) },
			}),
			emit_event: () => null, kick_interface: () => null, renew_interface: () => null,
			down_interface: () => null, iface_status: (i, cb) => cb({ up: false }),
			// the module-dir scan behind `option mux 'auto'` runs over fx.glob
			ucode_dir: scandir,
			datapath_fx: scandir ? { glob: (pat) => fs.glob(pat) } : null,
			read_config: () => parsed,
			resolve_modem_device: (cfg) => cfg.device,
			resolve_netdev: () => 'wwan0',
			learn_device: () => null, learn_modem_path: () => null,
		},
	});
	d.apply_config(parsed);
	return d;
}

let dp_ok = mkdp('vendorx', dplug);
eq(dp_asked, [ 'vendorx' ], 'plugin: the daemon asks for wwand.datapath_vendorx');
eq(started, [ { vendorx: dplug } ], 'plugin: the loaded object reaches the modem datapath');
eq(dp_ok.modems.m0.control_note ?? null, null, 'plugin: no note when it loaded');

started = []; dp_asked = [];
let dp_missing = mkdp('vendory', null);
eq(started, [], 'plugin: a modem whose datapath package is missing is not started');
ok(match(dp_missing.modems.m0.control_note ?? '', /wwand-datapath-vendory package not installed/),
	'plugin: control_note names the package to install');

// a named built-in never consults the loader (nor the scan)
started = []; dp_asked = [];
mkdp('rmnet', null);
eq(dp_asked, [], 'plugin: a named built-in mux does not go looking for a package');
eq(started, [ 'builtin' ], 'plugin: built-in starts with no candidates');

// ... and the same over the daemon's OWN loader against a REAL module file on
// the search path: the packaging contract end to end — module name
// wwand.datapath_<name>, a require()-able plain script that RETURNS its
// implementation (it cannot register itself anywhere; a require()d script gets
// its own copies of whatever it imports).
let dpdir = sprintf('%s/wwand-test-dp', getenv('TMPDIR') ?? '/tmp');

try { fs.mkdir(dpdir); } catch (e) { }
try { fs.mkdir(dpdir + '/wwand'); } catch (e) { }

let pf = fs.open(dpdir + '/wwand/datapath_testplug.uc', 'w');
pf.write("'use strict';\nreturn { probe: () => true, links: () => [ 'wwand0' ] };\n");
pf.close();
push(global.REQUIRE_SEARCH_PATH, dpdir + '/*.uc');

started = [];
let dp_real = mkdp('testplug', null, true);
eq(dp_real.modems.m0.control_note ?? null, null, 'plugin: real require() found the module');
ok(type(started[0]?.testplug?.links) == 'function',
	'plugin: the module\'s returned implementation reaches the modem');

// 'auto' hands over every INSTALLED plugin, found by scanning the module dir —
// without that scan a plugin could never introduce itself on a zero-config box
started = [];
let dp_auto = mkdp('auto', null, true, dpdir + '/wwand');
ok(type(started[0]?.testplug?.links) == 'function',
	'auto: the installed plugin is discovered by the module scan');
eq(dp_auto.modems.m0.control_note ?? null, null, 'auto: nothing to complain about');

// an installed-but-broken module (no links()) is refused like a missing one
pf = fs.open(dpdir + '/wwand/datapath_brokenplug.uc', 'w');
pf.write("'use strict';\nreturn { probe: () => true };\n");
pf.close();

started = [];
let dp_broken = mkdp('brokenplug', null, true);
eq(started, [], 'plugin: a module without links() does not start the modem');
ok(match(dp_broken.modems.m0.control_note ?? '', /wwand-datapath-brokenplug/),
	'plugin: broken module reported like a missing package');

fs.unlink(dpdir + '/wwand/datapath_testplug.uc');
fs.unlink(dpdir + '/wwand/datapath_brokenplug.uc');

// a PATH-shaped claim blocks too: uqmi/umbim `devpath` and wwan.sh `bus` name
// the same hardware without naming its device node, so the match is made on the
// sysfs path via deps.hw_path
started = [];
let dpath = null;
let parsed_p = config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/cdc-wdm0', path: 'platform/x/usb1/1-1' },
	wan: { '.type': 'interface', proto: 'wwan', bus: '1-1' },
} });

dpath = daemon_mod.create({
	timing: TIMING,
	deps: {
		log: (lvl, msg) => push(blk_logs, msg),
		load_qmi: () => ({
			modem: { create: (o) => { push(started, o.config.device ?? '?');
				return { id: 'm', start: () => null, stop: () => null,
				         note_connect_success: () => null, note_connect_failure: () => null,
				         datapath: {} }; } },
			context: { create: (o) => ({ state: 'IDLE', config: o.config, modem: o.modem }) },
		}),
		emit_event: () => null, kick_interface: () => null, renew_interface: () => null,
		down_interface: () => null, iface_status: (i, cb) => cb({ up: false }),
		datapath_fx: null, read_config: () => parsed_p,
		resolve_modem_device: (cfg) => cfg.device,
		resolve_netdev: () => 'wwan0',
		learn_device: () => null, learn_modem_path: () => null,
		hw_path: {
			claim: (raw) => (raw == '1-1') ? 'platform/x/usb1/1-1' : null,
			same: (a, b) => a == b,
			modem: (cfg) => cfg.usb_path,
		},
	},
});
dpath.apply_config(parsed_p);

eq(started, [], 'blocklist: a bus= claim blocks the modem it resolves to');
ok(match(dpath.modems.m0.control_note ?? '', /bus=1-1 is owned by interface wan \(proto wwan\)/),
	'blocklist: control_note names the option, value and owner');

// --- operator ifdown: netifd's autostart is the durable record ---------------
//
// `wanted` lives in the daemon's memory and every interface-bound context is
// rebuilt with wanted=true on start/reload, so it cannot carry operator intent
// across a restart. Reproduced on a Cudy LT300 (2026-08-23): ifdown wwan0, then
// /etc/init.d/wwand restart, and the interface came back up on its own.
//
// netifd's RUNTIME autostart flag is the discriminator. Measured on the same
// box: during a modem repower the interface read up=false, available=false but
// autostart=TRUE, so keying on it cannot swallow the reconnect after a modem
// reset — device presence lives in `available`, not here.

kicks = [];
autostart = true;
let dkick = mk('ipv4', []);
dkick.modem()('registered');
eq(kicks, [ 'wan' ], 'ifdown: a normally-down interface is still kicked up once registered');

kicks = [];
autostart = false;
let ddown = mk('ipv4', []);
ddown.modem()('registered');
eq(kicks, [], 'ifdown: an administratively down interface (autostart=false) is left alone');
ok(ddown.d.contexts.wan.wanted == false,
	'ifdown: the operator intent is recorded so later modem-ready cycles skip it too');

// device loss must NOT look like an ifdown
kicks = [];
autostart = true;
let dgone = mk('ipv4', []);
dgone.modem()('registered');
eq(kicks, [ 'wan' ], 'ifdown: a vanished device (autostart still true) reconnects as before');

// ...and neither must OUR OWN down. netifd's ubus `down` runs
// interface_set_down(), which does `iface->autostart = false`, so a down wwand
// issued itself leaves exactly the trace an operator's ifdown leaves. Without
// the marker, a modem that went SIM_BLOCKED and then came back found its own
// interface flagged "administratively down" and stayed off until someone ran
// ifup by hand — field-reported on an EG060K-EA after entering the PIN.
kicks = [];
autostart = true;
let dsim = mk('ipv4', []);

dsim.modem()('sim_blocked', { reason: 'pin' });
eq(dsim.d.contexts.wan.wanted, false, 'sim_blocked: the context is parked');
ok(dsim.d.contexts.wan._our_down == true, 'sim_blocked: the down is marked as ours');

// the PIN is entered, the modem re-inits and comes back — netifd still reports
// autostart=false, because WE cleared it
kicks = [];
autostart = false;
dsim.modem()('registered');
eq(kicks, [ 'wan' ], 'sim_blocked: our own down is undone once the modem is ready again');
ok(dsim.d.contexts.wan._our_down == false, 'sim_blocked: the marker is cleared by the kick');

// an operator ifdown that lands AFTER ours must still win
kicks = [];
autostart = false;
let dboth = mk('ipv4', []);
dboth.modem()('registered');
eq(kicks, [], 'ifdown: without our marker, autostart=false is still operator intent');

done('test_wan6');
