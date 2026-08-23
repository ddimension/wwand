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

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as config from 'wwand/config.uc';
import * as daemon_mod from 'wwand/daemon.uc';

const TIMING = { sync_retry: 1, settle: 1, sim_settle: 1, card_poll: 1,
	reg_timeout: 500, backoff_min: 40, backoff_max: 60, hold_max_ms: 120 };

// one stubbed daemon: the modem stub carries the rndis_host datapath and both
// create() calls capture their on_event bindings; ensure_wan6 is recorded
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
			kick_interface: () => null,
			renew_interface: () => null,
			down_interface: () => null,
			iface_status: (iface, cb) => cb({ up: false }),
			datapath_fx: null,
			read_config: () => config.parse({ network: {
				m0: { '.type': 'wwand_modem', device: '/dev/mock0' },
				wan: { '.type': 'interface', proto: 'wwand', modem: 'm0', pdp_type: pdp },
			} }),
			resolve_modem_device: (cfg) => cfg.device,
			resolve_netdev: (cfg, device) => 'wwand0',
			learn_device: () => null,
			learn_modem_path: () => null,
			ensure_wan6: (p) => push(ensures, p),
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

eq(ensures, [ 'wan' ], 'wan6: context up on rndis + ipv6 pdp -> ensure_wan6(wan)');

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

done('test_wan6');
