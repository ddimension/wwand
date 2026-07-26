# wwand package — configuration and API reference

wwand is an event-driven QMI / MBIM / NCM connection manager for OpenWrt, written
in ucode. It owns the modem's control port, drives netifd, and exposes a ubus
API. This document is the reference for configuration, the ubus API, diagnostics
and troubleshooting. For the design rationale see [architecture.md](architecture.md);
to add a modem, quirk or backend see [extending.md](extending.md).

## Configuration

**All configuration lives in `/etc/config/network`** (WireGuard-style). Three
wwand section types plus the netifd interface — no separate `/etc/config/wwand`
file for new setups:

- **`config wwand_modem '<name>'`** — the modem: hardware + primary SIM slot +
  default PIN + radio/cell/PLMN. Identity: **`device`** — a control node
  (`/dev/cdc-wdm0`) **or** a network device name (`wwan0`); or **`path`**, an
  *optional* stable USB topology anchor (like a wifi-device `path`, e.g. `1-1.2`,
  stable across renumbering on multi-modem setups). Plus tty, mux, sim_slot,
  pincode, modes, mcc, mnc, lock_4g/5g/persist, at_init, location, delay,
  failreboot, zero_rx_timeout, stats_interval, dl_datagram_max_size, and
  **`reset_gpio`** — a named GPIO wired to the modem RESET line, pulsed by the
  recovery ladder instead of a USB power-cycle (see [Board integration](#board-integration)) —
  and **`repower_time`** (seconds, default 30) — how long the modem is held
  de-powered during a recovery power-cycle, or held in reset when `reset_gpio` is used.
- **`config wwand_sim '<name>'`** *(optional)* — a per-SIM override, matched at
  runtime to the inserted card by `option modem` + `option iccid`: overrides the
  modem's `pincode` and, optionally, `apn`/`auth`/`username`/`password` for that
  card (e.g. different eUICC profiles / dual-SIM with different PINs).
- **`config interface '<name>'`** with `option proto 'wwand'` — the connection:
  `option modem <name>` + `apn`, `pdp_type`, `auth`, `username`, `password`,
  `profile`, `mux_id` (0 = no mux, N = channel N), `mtu`, `use_pushed_mtu`,
  `use_pushed_prefix`, `settings_poll` + the usual netifd knobs. Several
  interfaces referencing one `wwand_modem` = multiple mux contexts on one modem.
- **`config wwand_globals 'globals'`** — `log_level`, `hold_max`.

> **Proto name.** The netifd/LuCI protocol is **`wwand`** — one handler for all
> backends (QMI/MBIM/NCM; the driver decides which). For backward compatibility
> the handler *also* registers the historical name **`qmi`**, so interfaces still
> saved as `proto qmi` keep working; migration and LuCI rewrite them to
> `proto wwand` on the next save. Prefer `proto wwand` for new interfaces.

```
config wwand_modem 'm0'
	option device 'wwan0'            # netdev name or /dev/cdc-wdmX
	# option path '1-1.2'           # optional: pin to a fixed USB topology path
	option pincode '1234'
	option sim_slot '1'
	option modes 'lte,nr5g'

config wwand_sim 'vodafone'          # optional per-card override
	option modem 'm0'
	option iccid '89490...'
	option pincode '5678'
	option apn 'web.vodafone.de'

config interface 'wan'
	option proto 'wwand'
	option modem 'm0'
	option apn 'internet'
	option pdp_type 'ipv4v6'
```

**Precedence:** PIN = matching `wwand_sim.pincode` → `wwand_modem.pincode`;
APN/auth = `interface` → active `wwand_sim` → card-provisioned.

How the sections relate (all in `/etc/config/network`):

```
  config interface 'wan'          config interface 'ims'
    proto wwand                      proto wwand
    option modem 'm0' ───┐           option modem 'm0' ───┐      the connection:
    option apn 'internet'│           option apn 'ims'     │      apn / pdp_type /
    option mux_id '1'    │           option mux_id '2'    │      auth / mux channel
                         ▼                                 ▼
                    config wwand_modem 'm0'                       the modem: device/
                      device / pincode / sim_slot / modes …       SIM slot / radio
                      (path optional)
                         ▲
       matched by ICCID  │  (at bring-up, before PIN unlock)
                    config wwand_sim 'vodafone'                   per-SIM override,
                      iccid / pincode / apn   (option modem       keyed by ICCID —
                                               optional)          PIN + carrier APN
```

Two interfaces share one `wwand_modem` = two mux contexts on one modem. A
`wwand_sim` is picked by the inserted card's ICCID (modem binding optional).

**Backward compatibility & migration.** The daemon still reads every older
wwand format: a legacy inline `proto qmi` interface, and the previous
`/etc/config/wwand` `modem`/`context` sections shown below. Nothing breaks.
Conversion to the model above happens automatically — a uci-defaults script runs
`/usr/libexec/wwand/migrate --apply` once on install/upgrade (it also converts
stock OpenWrt `proto mbim`/`proto ncm` interfaces, since `wwand-mbim`/`wwand-ncm`
replace those handlers), and saving in LuCI writes the new model too. Run the
migrate tool by hand any time (dry-run without `--apply`).

For example, a stock `proto ncm` interface is rewritten in place:

```
  before (stock comgt-ncm)          after (wwand, network-native)
  ─────────────────────────         ─────────────────────────────
  config interface 'wan'            config wwand_modem 'wwmodem0'
    option proto 'ncm'                option device 'wwan0'
    option device 'wwan0'             option pincode '1234'
    option apn 'internet'             option mode 'lte'  → modes
    option pincode '1234'
    option mode 'lte'               config interface 'wan'
    option pdptype 'ipv4v6'           option proto 'wwand'    ← wwand's proto
                                       option modem 'wwmodem0'
                                       option apn 'internet'   ← connection stays
                                       option pdp_type 'ipv4v6'
```

wwand then detects at runtime (by the `cdc_ncm` driver) that it is an NCM modem.

### Legacy: the `/etc/config/wwand` model

The previous model (still read for compatibility): `/etc/config/wwand` holds
`modem` and `context` sections; a netifd interface references a context by name
(`option context 'wan_ctx'`).

### Modem section

```
config wwand 'globals'
	option log_level 'info'          # err|warn|notice|info|debug

config modem 'm0'
	option device '/dev/cdc-wdm0'    # control port, or a netdev name (`wwan0`)
	                                 # or `option path '1-1.2'` (optional stable USB
	                                 #   anchor; `usb_path` still accepted)
	option serial '99efe861'         # bind by USB iSerial — stable identity, matched
	                                 #   pre-open; follows the modem across re-enum
	option imei '868965060008609'    # bind by IMEI — verified post-open; a mismatch
	                                 #   blocks bring-up (wrong-modem safety)
	option tty ''                    # AT port override (auto-detected otherwise)
	option pincode '1234'            # SIM PIN; entered on each start
	option sim_slot '0'              # physical slot to activate (0 = leave as-is)
	option modes 'lte,nr5g'          # lte umts gsm nr5g td-scdma cdma / all / unset
	option mcc '262'                 # manual PLMN selection (optional, needs mnc)
	option mnc '01'
	option mux 'auto'                # auto|rmnet|qmimux|none — QMAP datapath backend
	option dl_datagram_max_size '0'  # QMAP DL aggregation bytes; 0 = model/board table
	list at_init 'ATE0'              # extra AT commands, sent once before registration
	option lock_4g '1300:246'        # earfcn:pci — LTE cell lock (repeatable / list)
	option lock_5g '242:431070:15:1' # pci:arfcn:scs:band — NR SA cell lock
	option lock_persist '0'          # store the cell lock in modem NV
	option location '0'              # start the QMI LOC positioning session
	option stats_interval '60'       # telemetry period in seconds (0 = off)
	option delay '0'                 # seconds to wait before the first init
	option failreboot '100'          # attempts before the final reboot rung (0 = never reboot)
	option proto_error_limit '25'    # protocol-error ceiling before a reboot (gated by failreboot)
	option zero_rx_timeout '21600'   # no-rx watchdog in seconds (0 = off)
	option repower_time '30'         # recovery power-cycle off / reset-hold seconds
```

**Binding a modem to hardware.** The anchors are tried most-stable first:
`serial` (USB iSerial, matched in sysfs before the modem is opened) → `imei` →
the topological anchors `device` / `path` / netdev. `imei` is normally *verified*
after open (a mismatch halts bring-up so the wrong physical modem never gets this
SIM/APN); additionally, modems that publish their IMEI **as** the USB iSerial are
matched pre-open too, exactly like `serial`. A short vendor serial or a dummy
constant (e.g. the EG06 `0123456789ABCDEF`) never false-matches an IMEI and just
falls through to the post-open check. `serial` and `imei` follow the modem across re-enumeration, a port change,
or two identical modems; the topological anchors do not. An empty or duplicated
iSerial is treated as ambiguous and falls back to the next anchor. With
`auto_correct_config` set, a modem that pinned no `imei` learns the one it
discovers (written back onto its `wwand_modem` section) so a loose config
self-stabilises. The LuCI Modems page and the inline interface editor populate the
serial/IMEI fields from `ubus call wwand modem_probe`.

### Context section

```
config context 'wan_ctx'
	option modem 'm0'
	option mux_id '1'                # QMAP channel; the L3 device becomes wwan0m1
	option profile '1'               # 3GPP profile (CID) for the attach + bearer
	                                 #   (default: mux_id, else 1)
	option apn 'internet'            # or '#2' = use modem profile 2 untouched
	option pdp_type 'ipv4v6'         # ipv4|ipv6|ipv4v6
	option auth 'none'               # none|pap|chap|both
	option username ''
	option password ''
	option mtu ''                    # fixed MTU (else the pushed MTU when enabled)
	option use_pushed_mtu '1'        # apply the network-advertised MTU
	option use_pushed_prefix '0'     # keep the pushed IPv4 prefix (default: /32 p-t-p)
	option settings_poll '300'       # re-check pushed IP/DNS/MTU every N s (0 = off)
```

`/etc/config/network`:

```
config interface 'wan'
	option proto 'wwand'             # legacy 'qmi' also accepted
	option context 'wan_ctx'
	option metric '10'               # metric / peerdns / defaultroute / ip4table /
	                                 #   ip6table / VRF are handled by netifd as usual
```

**Attach profile.** Before registration, wwand programs the LTE **attach
profile** (CID `profile`, normally 1) from the primary context's `apn` +
`pdp_type`, so the modem's *autonomous* attach uses the right settings. A stale
attach profile (wrong APN, or IPv4-only where the subscription needs IPv4v6)
otherwise gets the attach rejected with EMM cause 33 and registration wedges —
see [Troubleshooting](#troubleshooting).

**Muxing rules.**
- When any context of a modem is muxed, **all** its contexts get a channel (the
  QMAP parent device carries no IP traffic itself). Missing channels are
  auto-assigned; a warning names the assignment.
- A device name `wwan0m0` means "muxed, auto-assign the channel, keep this link
  name" (QMAP channel 0 itself is invalid).

### Old-style configurations (compat layer)

Interfaces with `proto wwand`|`qmi` and **no** `option modem`/`option context`
are read the old way
(options on the interface section: `device wwan0`/`wwan0mN`, `apn` incl. `#N`,
`auth`, `username`, `password`, `pincode`, `modes`, `mcc`/`mnc`, `ipv4`/`ipv6`/
`pdptype`, `mtu`, `use_pushed_mtu`, `sim_slot`, `at_init`, `lock_4g`/`lock_5g`/
`lock_persist`, `location`, `delay`, `failreboot`, `zero_rx_timeout`,
`stats_interval`). They are translated in memory at daemon start; nothing is
written back. `dhcp`, `autocreateif`, `customroutes` and `strongestnetwork` are
obsolete and ignored with a warning. A `disabled` interface is skipped entirely.

`/usr/libexec/wwand/migrate` prints the equivalent native configuration (dry
run); `--apply` writes it and strips the old options from the network sections.

## netifd integration (no-proto-task)

The proto handler sets `no_proto_task=1`: after setup the interface stays
`IFS_UP` with **no monitor process**. The **daemon owns the context lifecycle**
and drives netifd over ubus:

- **Transient loss** → the interface is held up, the session reconnects, and the
  daemon issues an in-place `renew` (no teardown → IPv6-PD / VRF preserved).
  Bounded by `hold_max` (~90 s), then `down`.
- **Permanent loss** (`sim_blocked`, admin/config down) → `down` immediately.
- **wwand restart is non-destructive** (`stop_local`, not `shutdown`): WAN and
  live traffic survive; the daemon **adopts** the running session on `registered`.

The daemon touches only the link layer (mux/MTU/carrier, sysctl); **all**
addressing and routing go through netifd, so `ip4table`/`ip6table`/VRF apply.

**`disabled` and `auto`** on the netifd interface are honoured:

- `option disabled '1'` — the interface is not linked to its context at all;
  the daemon never manages, kicks or reconnects it.
- `option auto '0'` — the daemon does **not** proactively bring the interface up
  on modem-ready (it only *adopts* it if it is already up, e.g. after a manual
  `ifup` or a wwand restart). With `auto '1'` (the default) the daemon kicks the
  interface up as soon as the modem registers.

## Deployment examples

Two ways to isolate a cellular WAN together with a DMZ so that **all inbound
traffic reaches a single local host**, in full IPv4/IPv6 dual-stack. Both share
the base below and differ only in how the routing is separated — per-interface
policy routing (variant 1) or a VRF (variant 2). All addressing and routing is
netifd's, per the
[routing/VRF invariant](architecture.md#routing--vrf-compatibility-invariant):
wwand only builds the link.

### Base scenario

A cellular uplink (`wan`, proto wwand, dual-stack) plus a DMZ on a tagged VLAN
whose single host receives every inbound connection. The WAN reaches no other
network, the DMZ may go out, and inbound is allowed only to the DMZ host.

`/etc/config/network`:

```
config wwand_modem 'm0'
	option device 'wwan0'             # the modem's control/net device

config interface 'wan'
	option proto 'wwand'
	option modem 'm0'
	option device 'wwan0m1'          # l3 device = QMI/MBIM mux child (see note)
	option apn 'internet'
	option pdp_type 'ipv4v6'          # dual-stack bearer

config device
	option type '8021q'               # DMZ on a tagged VLAN ...
	option ifname 'lan1'              #   ... off this switch port
	option vid '40'
	option name 'dmz0'

config interface 'dmz'
	option proto 'static'
	option device 'dmz0'
	option ipaddr '192.0.2.1'
	option netmask '255.255.255.0'
	option ip6assign '64'             # carve a /64 for the DMZ (see Dual-stack)
```

The interface's L3 device is the mux child the daemon creates and manages. Name it
either way:

- `option device 'wwan0m1'` — the mux id is **derived from the `…mN` suffix** (`1`
  here); or
- the 2-field form `option modem 'm0'` + `option mux_id '1'` — the daemon then
  derives the device name `wwan0m1`.

**Muxing is opt-in.** With neither of the above, QMI/MBIM run raw on the plain
modem netdev (`wwan0`, a single PDN); **NCM never muxes** (always the plain
netdev). Enabling muxing on QMI is also a throughput win — see
[Performance & tuning](#performance--tuning). Whichever form you use, that
resulting device name — `wwan0m1` (or `wwan0` unmuxed) — is what you reference in
a VRF's `list ports` and in firewall `option device` matches.

**The daemon materialises the name.** When a modem registers, the daemon writes
the resolved l3 device back onto the interface as `option device` (if you left it
empty) — so the config always carries the explicit name for VRF/firewall/LuCI to
reference, and LuCI shows it in an editable **L3 device** field. It is idempotent
and **never overwrites a value you set** (you have the final say — clear the field
to hand it back to auto-fill). Turn the write-back off globally with
`config wwand_globals` → `option write_device '0'`. For an rmnet mux child the
daemon reads the MAP id back from the kernel (`IFLA_RMNET_MUX_ID`) when adopting a
live link on restart; qmimux has no such kernel attribute, so the daemon keeps its
remembered mapping there.

`/etc/config/firewall` — a `wan` zone that reaches nothing else, a **new `dmz`
zone**, DMZ→WAN allowed, and all inbound forwarded to one host:

```
config zone
	option name 'wan'
	list network 'wan'
	option input 'REJECT'
	option output 'ACCEPT'
	option forward 'REJECT'
	option masq '1'                  # IPv4 NAT outbound (IPv6 is routed, no NAT)

config zone
	option name 'dmz'
	list network 'dmz'
	option input 'REJECT'            # the router itself stays unreachable from DMZ
	option output 'ACCEPT'
	option forward 'REJECT'

config forwarding                    # DMZ may reach the internet
	option src 'dmz'
	option dest 'wan'

config redirect                      # all inbound IPv4 -> the DMZ host (DMZ host / 1:1 DNAT)
	option name 'dmz-host-v4'
	option src 'wan'
	option dest 'dmz'
	option proto 'all'
	option dest_ip '192.0.2.10'

config rule                          # all inbound IPv6 -> the DMZ host (no NAT, just allow)
	option name 'dmz-host-v6'
	option src 'wan'
	option dest 'dmz'
	option family 'ipv6'
	option proto 'all'
	option dest_ip '<dmz-host-GUA>'  # host address out of the DMZ /64
	option target 'ACCEPT'
```

`/etc/config/dhcp` — advertise the DMZ `/64` (RA + DHCPv6 server):

```
config dhcp 'dmz'
	option interface 'dmz'
	option ra 'server'
	option dhcpv6 'server'
	list ra_flags 'managed-config'
	list ra_flags 'other-config'
```

**Pinning the DMZ host's address.** The rules target the host by address, so it
needs a *stable* one. Give it a fixed interface identifier (say `::10`) so every
prefix yields the same host part — on the DMZ host itself, e.g. (OpenWrt):

```
config interface 'dmzhost'
	option proto 'static'
	option device 'eth0'
	option ipaddr '192.0.2.10'        # matches dmz-host-v4 dest_ip
	option netmask '255.255.255.0'
	option ip6ifaceid '::10'          # stable GUA/ULA host part -> <prefix>::10
	list ip6addr 'fe80::10/64'        # fixed link-local (or use the HW-derived LL)
```

- **ULA** (`fd88:ff8d:4303:4535::10`, from the router's `ula_prefix`) never
  rotates — the rotation-proof handle for stable internal reachability and rules.
- **GUA** (`<prefix>::10`) keeps a stable host part, but on mobile the `/64`
  *prefix* itself rotates per reconnect, so the `dmz-host-v6` rule's `dest_ip`
  still tracks the current prefix — set it to `<current-prefix>::10` (or drive it
  from the ULA/host part). Fixed link-local and ULA do not have this problem.
- **Link-local** (`fe80::10`, or the host's HW-derived LL) is a stable next-hop
  for the router↔host link, independent of any prefix.

This base keeps all routes in the single `main` table. Pick one variant below to
separate the WAN/DMZ routing from the rest of the router.

### Variant 1 — policy routing

Give the WAN and the DMZ their own routing table so only these two interfaces use
the cellular default route. Add `ip4table` / `ip6table` (same id) to both, and
keep the WAN's default route:

```
config interface 'wan'
	option proto 'wwand'
	option modem 'm0'
	option device 'wwan0m1'         # l3 device (mux child); mux id derived from name
	option apn 'internet'
	option pdp_type 'ipv4v6'
	option ip4table '100'
	option ip6table '100'
	option defaultroute '1'          # default via WAN, into table 100

config interface 'dmz'
	option proto 'static'
	option device 'dmz0'
	option ipaddr '192.0.2.1'
	option netmask '255.255.255.0'
	option ip6assign '64'
	option ip4table '100'
	option ip6table '100'
```

netifd **auto-generates the `ip rule` source rules** — you do not write them: per
address a `from <host>` rule (prio 10000) and a `from <subnet>` rule (prio 20000)
into table 100, an `iif lo` rule (prio 90000+ifindex) so router-originated
traffic resolves there, and (IPv6) a reject rule at prio 4200000000 against
leakage. Inspect with `ip rule` / `ip -6 rule` and `ip route show table 100`.

### Variant 2 — VRF

Bind the WAN and DMZ into an L3 VRF instead. The VRF is a `config device` of
`type 'vrf'` with its own table; both interfaces' L3 devices are its `ports`:

```
config device
	option type 'vrf'
	option name 'vrf_wan'
	option table '100'
	list ports 'wwan0m1'             # the WAN l3 device (QMI/MBIM mux child;
	                                 #   for NCM use the plain netdev `wwan0`)
	list ports 'dmz0'                # the DMZ l3 device

config interface 'vrf_wan'           # REQUIRED: a `config device` is only brought
	option proto 'none'              #   up when an interface references it — this
	option device 'vrf_wan'          #   instantiates the master + enslaves the ports

config interface 'wan'
	option proto 'wwand'
	option modem 'm0'
	option device 'wwan0m1'         # l3 device (mux child); matches the VRF port
	option apn 'internet'
	option pdp_type 'ipv4v6'
	option ip4table '100'            # REQUIRED: place the default INTO the VRF table
	option ip6table '100'            #   — netifd does NOT auto-place proto routes
	option defaultroute '1'          #   there; without it the default leaks to main

config interface 'dmz'
	option proto 'static'
	option device 'dmz0'
	option ipaddr '192.0.2.1'
	option netmask '255.255.255.0'
	option ip6assign '64'
	option ip4table '100'
	option ip6table '100'
```

Apply with a **full `/etc/init.d/network restart`** (not `reload`): a `reload`
registers the VRF config but does not instantiate the master or enslave the
members. Verify: `ip link show master vrf_wan` lists `wwan0m1` and `dmz0`.

**VRF specialities — read these:**

- **wwand stays out of it.** The daemon never sets `IFLA_MASTER`; netifd enslaves
  the mux child to the VRF master and places its routes in the VRF table — see the
  [routing/VRF invariant](architecture.md#routing--vrf-compatibility-invariant).
- **l3mdev is a global switch, not per-VRF.** For the router's own *listening*
  sockets (a DHCPv6 client, DNS, …) to work across the VRF, enable it globally:
  ```
  config globals 'globals'
  	option tcp_l3mdev '1'
  	option udp_l3mdev '1'
  ```
  (writes `net.ipv4.{tcp,udp}_l3mdev_accept`; host-wide, all-or-nothing.)
- **fw4 is VRF-agnostic — and you MUST add the VRF master to the WAN zone.** fw4
  derives a zone's `iifname`/`oifname` from each member's `l3_device` (`wwan0m1`,
  `dmz0`). But a **forwarded, DNAT'd** packet is re-injected by the l3mdev with
  `iif = vrf_wan` (the master, not the member) — so unless `vrf_wan` is in the WAN
  zone it matches no zone and hits the default reject (HW-confirmed via `nft
  monitor trace`: `iif "vrf_wan" oif "br-lan.20" … jump handle_reject`). Add the
  master as a device to the WAN zone:
  ```
  config zone
  	option name 'wan'
  	list network 'wan'
  	list device 'vrf_wan'          # REQUIRED: l3mdev re-injects forwarded
  	...                            #   traffic with iif = the VRF master
  ```
- **l3mdev FIB rule is automatic — do not script it.** When the first VRF device
  is created the kernel installs the `1000: from all lookup [l3mdev]` rule for
  **both** v4 and v6 itself, and the `config device` + `config interface vrf_wan`
  pair re-instantiates the master on every (cold) boot. Cold-boot-verified: no
  `ip rule add l3mdev` and no hotplug helper are needed (an earlier workaround
  adding them by hand was pure redundancy).

**Forwarding to a DMZ host through the VRF (HW-tested).** With the master in the
WAN zone, inbound traffic is correctly DNAT'd and forwarded to the DMZ host — v4
end-to-end confirmed, v6 end-to-end once the two routing fixes below (catch-all
default route + `keep_addr_on_down`) are in place. Announce the DMZ prefix so
the host can address itself, and NAT the forwarded traffic so its reply returns
symmetrically via the router:

```
# /etc/config/dhcp — announce the DMZ /64 (RA) so the host auto-configures
config dhcp 'dmz'
	option interface 'dmz'
	option ra 'server'
	option dhcpv6 'server'
	list ra_flags 'none'

# /etc/config/firewall — DMZ-host DNAT + NAT66 so the host replies via the router
config redirect                     # all inbound v4 -> the DMZ host
	option name 'DMZ-host'
	option src 'wan'
	option dest 'dmz'
	option proto 'all'
	option dest_ip '192.0.2.10'

config zone
	option name 'dmz'
	list network 'dmz'
	option masq6 '1'                # NAT66: forwarded v6 gets an on-link source,
	...                             #   so the host's reply routes back to us
```

**Allow ICMPv6 ND on a REJECT-input DMZ zone (else v6 breaks entirely).** A DMZ
zone with `input 'REJECT'` and no ICMPv6 allow **rejects the host's incoming
neighbour advertisements** — so the router can never resolve the host's L2 address
and every v6 forward silently fails with the neighbour stuck `FAILED`
(HW-confirmed via `nft monitor trace`: the NA hits `input_dmz → reject_from_dmz →
handle_reject`). The stock `wan` zone ships an `Allow-ICMPv6-Input` rule; a custom
DMZ zone needs the same:
```
config rule
	option name 'Allow-DMZ-ICMPv6'
	option src 'dmz'
	option family 'ipv6'
	option proto 'icmp'
	list icmp_type 'neighbour-solicitation'
	list icmp_type 'neighbour-advertisement'
	list icmp_type 'router-solicitation'
	list icmp_type 'router-advertisement'
	list icmp_type 'echo-request'
	list icmp_type 'echo-reply'
	list icmp_type 'destination-unreachable'
	list icmp_type 'packet-too-big'
	list icmp_type 'time-exceeded'
	option limit '1000/sec'
	option target 'ACCEPT'
```
With this, the neighbour resolves (`… lladdr … REACHABLE`) and the host replies
(HW-confirmed SYN → SYN-ACK). The DMZ host must also have an address *in an on-link
prefix the router shares* (SLAAC from the announced RA, or a static address in a
common `fd…::/64` you also put on the DMZ interface as `::1`) so `masq6` can give
the forwarded traffic an on-link source and the reply returns via the router. To
force that on-link source deterministically (RFC-6724 selection otherwise prefers
the GUA over the ULA for a ULA destination), SNAT the forwarded traffic to the
shared `::1` explicitly rather than relying on `masq6` alone — e.g. an
`/etc/nftables.d/` include:
```
# /etc/nftables.d/20-dmz-v6-snat.nft — on-link source for the DMZ host
chain dmz_v6_snat {
	type nat hook postrouting priority 99; policy accept;   # before fw4 srcnat (100)
	oifname "dmz0" ip6 daddr fd00:…::/64 snat ip6 to fd00:…::1
}
```

**The forwarded v6 reply needs a non-source-specific default route in the VRF
table (else it is dropped before `forward`).** Over cellular the WAN's IPv6
default is **source-specific** — `default from <WAN /64> via … dev wwan0m1`, an
artefact of the delegated/temporary prefix. On the DNAT'd reply the kernel un-NATs
the *destination* at prerouting but the *source* only at postrouting, so at the
**routing decision the source is still the DMZ host's address** — not in the WAN
`/64`, so the source-specific default does not match → `RTNETLINK: Network
unreachable` and the reply is dropped **before** the `forward` hook (HW-confirmed:
`nft monitor trace` stops at `prerouting`, no `forward`/`postrouting`). IPv4 is
immune (its default is not source-scoped). Add a **catch-all** default into the
VRF table — a device route (no gateway) so it survives prefix/gateway rotation:
```
config route6
	option interface 'wan'           # the wwand WAN interface
	option target '::/0'
	option table '100'               # the VRF table
	option metric '2048'             # below the source-specific default (1024)
```
The router's own traffic still prefers the source-specific default (metric 1024);
only the forwarded reply — whose source does not match it — falls through to the
catch-all. With this the v6 3-way handshake completes end-to-end.

**Keep the DMZ's static IPv6 address across VRF enslavement (`keep_addr_on_down`).**
When the DMZ carries a *static* `ip6addr` (the shared `fd…::1/64` the host replies
to on-link), **enslaving the port into the VRF flushes its IPv6 addresses** — the
kernel keeps IPv4 on a master change but drops IPv6, and netifd never notices (it
still lists the address in `ubus … status`; `reload` is a no-op, only a full
`ifup dmz` re-adds it). At boot the enslavement runs *after* the DMZ comes up, so
the static ULA is gone until the next `ifup`. Fix it with one sysctl — retain
IPv6 addresses on a down/master-change:
```
# /etc/sysctl.d/10-keep-addr-on-down.conf
net.ipv6.conf.default.keep_addr_on_down = 1
net.ipv6.conf.all.keep_addr_on_down = 1
```
Cold-boot-verified: the static ULA then survives enslavement with no hotplug/`ifup`
workaround. (A SLAAC address from the announced RA is re-added by netifd anyway;
this only matters for a *static* `ip6addr`.) The root cause is a netifd gap — it
subscribes only to `RTNLGRP_LINK`, never to `RTM_DELADDR`, so an externally-caused
address flush is invisible to it; the sysctl sidesteps it entirely.

**Both members in one VRF collapse fw4's zone distinction (breaks dmz→wan).** The
l3mdev rewrites the ingress `iif` to the master `vrf_wan` for **all** inter-member
forwarding, so fw4 can no longer tell dmz-sourced from wan-sourced transit traffic
— both arrive as `iif = vrf_wan`. The `vrf_wan`-in-WAN-zone entry above (required so
the **inbound** DNAT return matches a zone) therefore also makes the DMZ host's
**outbound** traffic look wan-sourced → it is classified wan→wan and dropped
(`drop wan out: IN=vrf_wan OUT=wwan0m1`, HW-seen with a DMZ host's outbound IKE).
There is no clean fw4 fix — the zone key (the ingress device) is gone. Either scope
the VRF to the WAN only (leave the DMZ a normal interface that routes into the VRF
table via `ip4table`/`ip6table` + a policy rule, so it keeps its real `br-lan.20`
iif), or — simpler — use **Variant 1 (policy routing)**, where the iif is never
rewritten and dmz↔wan works both ways natively.

> **Hard limit — the WAN uplink itself must NOT be VRF-enslaved if the router
> terminates traffic on its WAN IP.** VRF works for traffic **forwarded through**
> the router (inbound → a DMZ host): those packets carry `iif = the VRF`, so the
> kernel applies the l3mdev redirect and they route out correctly. But traffic
> **terminated on the router's own WAN address** (ping to the WAN IP, or any
> service the router itself runs there) is **broken by design**: the router's
> reply is generated locally, is *not* VRF-associated (no socket bound to the
> VRF), routes to the raw slave **without** the l3mdev redirect, and cannot egress
> the enslaved member. This was HW-confirmed for **both ICMP and TCP** (SYN in, no
> SYN-ACK out — `tcp_l3mdev_accept=1` does not help; it is a routing/l3mdev-egress
> issue *below* the firewall, so no fw4/nftables rule fixes it). Secondary fw4
> symptoms you will also see: the reply is untracked → `ct state invalid` → the
> anti-NAT-leak drop; and the l3mdev double-traversal reclassifies it as
> *forwarded*, hitting the `wan` zone's `forward` policy (IPv6 often survives only
> because of the stock `Allow-ICMPv6-Forward` rule). **If the router must be
> reachable / run services on the cellular WAN IP, use Variant 1 (policy routing)
> — it does exactly that and is the tested model.** Reserve VRF for the
> forward-only case where the router never terminates WAN traffic.

### Dual-stack and IPv6 prefix delegation

The examples are already dual-stack: `pdp_type 'ipv4v6'` brings up both families,
wwand configures the WAN IPv6 GUA + default route and (RFC 7278) shares its `/64`,
so the DMZ's `ip6assign '64'` takes addresses from that same `/64`. One shared
`/64` is enough for a single downstream network.

For a **separately delegated** prefix (a real IA_PD — e.g. a `/56` the carrier
delegates so the DMZ gets its own `/64`), run a DHCPv6-PD client **on top of** the
wwand interface. wwand keeps managing the WAN GUA; a stacked `dhcpv6` logical
interface requests only the prefix:

```
config interface 'wan6'
	option proto 'dhcpv6'
	option device '@wan'             # ride on wan's l3 device (inherits its GUA)
	option reqaddress 'none'         # wwand owns the address; request a prefix only
	option reqprefix 'auto'
```

The DMZ then draws its `/64` from the delegated prefix exactly as above
(`option ip6assign '64'`), advertised by odhcpd.

**Two hard constraints:**

- **The carrier must actually delegate.** 3GPP prefix delegation is a DHCPv6
  IA_PD exchange with the network (P-GW); there is no QMI/MBIM path to a shorter
  prefix. Where the network delegates nothing, you fall back to the shared `/64`
  above — nothing breaks.
- **The DHCPv6 client needs a global source address.** The stacked interface
  **must** ride on `@wan` so it inherits the wwand-configured GUA: over the
  cellular bearer a link-local source usually does not carry, and odhcp6c has no
  option to force the source — the kernel selects it (RFC 6724) and prefers a
  link-local when one exists. If your bearer drops link-local DHCPv6, IA_PD needs
  an odhcp6c that pins the global source; verify with
  `tcpdump -i <wan-l3dev> udp port 547` which source the SOLICIT uses.

**How prefix delegation works on mobile (background).** In 3GPP every IPv6 /
IPv4v6 PDN connection is assigned its own `/64` by the network via SLAAC — the
connection is a point-to-point link between the modem and the P-GW, and that
single `/64` is exactly what wwand configures and (RFC 7278) shares. Delegating a
*separate*, shorter prefix is an **optional DHCPv6-PD feature** (RFC 8415; 3GPP
TS 29.061, overview in RFC 6459) that the operator must provision **per APN**: the
router is the requesting router, the P-GW the delegating server (often backed by
RADIUS, RFC 4818). Most consumer APNs do not enable it — a PD `SOLICIT` then goes
unanswered and you are left with the shared `/64`; the standard-compliant
link-local source is fine there, the network simply offers no PD. Verified on this
project's SIMs: Vodafone DE (`web.vodafone.de`) and Telekom DE
(`nonbonding.hybrid`) return no delegation on either a link-local or a global
source. Business / M2M APNs with explicit PD provisioning are where a delegated
prefix actually appears.

## Performance & tuning

Two knobs dominate routed throughput on a cellular WAN.

### QMI muxing + QMAP aggregation

For the **QMI backend, enable muxing** (`option mux_id 'N'` on the context) even
with a single PDN. Muxing switches the datapath from raw-IP `qmi_wwan` to the
**rmnet driver with QMAP**, which aggregates many IP packets into one USB transfer
(plus MAPv5 checksum offload) instead of one URB per packet. On fast 5G/LTE links
the raw-IP path is CPU-bound well below line rate; QMAP aggregation is what reaches
full throughput — this is why the examples above set `option mux_id '1'`.

- Aggregation is **bidirectional**: downlink (the modem batches packets into the
  host's rx URB) *and* uplink (the host batches IP packets into QMAP frames —
  WDA-negotiated `ul_max_datagrams`/`ul_max_size` plus the rmnet egress coalesce).
  The **endpoint type** (USB vs PCIe) is auto-detected from the netdev's bus, so
  PCIe/MHI modems negotiate the data format correctly. It is capability-gated —
  a modem that does not confirm QMAP simply runs plain framing.
- Tune the aggregation buffer per modem with `option dl_datagram_max_size` on the
  `wwand_modem` section (default from a per-model table, ~31 KB): larger buffers
  aggregate more but cost latency/RAM. The daemon renegotiates plain QMAP if the
  modem rejects a datagram-aggregation size (e.g. the RG650E's DAP-8 edge case).
- **MBIM** aggregates natively (NTB) — no extra config. **NCM** (`cdc_ncm`) cannot
  mux and runs the plain netdev, so expect a lower ceiling there.

### Firewall flow offloading

For a router that forwards/NATs cellular traffic, enable **software flow
offloading** so established connections take the nftables fast path instead of
traversing the full netfilter chains per packet:

```
config defaults
	option flow_offloading '1'          # software fast path (recommended)
	option flow_offloading_hw '1'       # + hardware offload where the SoC supports it
```

- Software offloading is a large CPU win on any target. Hardware offloading
  (`flow_offloading_hw`) depends on the SoC — e.g. the Chateau's ipq60xx supports
  it, smaller ramips targets may not — and falls back to software when absent.
- Trade-off: offloaded flows **bypass per-packet netfilter**, so SQM/QoS shaping
  and some counters do not see them. If you shape the WAN with SQM, leave
  offloading off (or accept that offloaded flows are not shaped).
- Offloading works at the routing/conntrack layer, **independent of the mux
  datapath and of policy-routing / VRF** — it composes with both variants above.

`option packet_steering '1'` in `config globals` (as on the reference boards)
spreads softirq/RPS load across CPU cores and helps on multi-core targets.

## ubus API

Object `wwand`. Every method also accepts `ubus_rpc_session` (injected by rpcd
when called from LuCI).

| Method | Arguments | Description |
|---|---|---|
| `status` / `modem_list` | — | modems (state, identity, registration, `registration_detail`, counters, `control_note`, `apdu_backend`) + contexts + `board` (detected profile, power/reset capability) |
| `reload` | — | re-read UCI and rebuild |
| `set_log_level` | `level` | change the log level at runtime |
| `hotplug` | `action`, `device` | device add/remove (from the hotplug script) |
| `modem_signal` | `modem` | last raw signal info (LTE/NR5G/WCDMA/GSM metrics) |
| `modem_cells` | `modem` | registration + `registration_detail` + signal + decoded cells + `dsd` + `ca` |
| `modem_location` | `modem` | last QMI LOC fix (when `location` is enabled) |
| `modem_at` | `modem`, `command`, `timeout?` | run an AT command on the modem's AT port |
| `modem_get_settings` / `modem_set_settings` | `modem`, `settings?` | NAS system-selection prefs (modes/bands) — the settings editor |
| `modem_plmn_lists` | `modem` | preferred/forbidden PLMN lists |
| `modem_sim_slots` | `modem` | physical slots: card presence, active, ICCID, eUICC flag, EID |
| `modem_probe` | — | detected modems for the stable-binding picker: `managed[]` (live IMEI/model/device) + `present[]` (every control device in sysfs with its iSerial, read pre-open) |
| `modem_sim_switch_slot` | `modem`, `slot` | switch the active physical SIM slot (drops the connection) |
| `modem_sim_pin_lock` | `modem`, `pin`, `enable` | enable/disable the SIM PIN lock (QMI first, AT fallback; idempotent) |
| `modem_esim` | `modem`, `op`, … | eSIM (list/enable/disable/eid/download/…); needs the optional `wwand-esim` package |
| `modem_apdu` | `modem`, `op`, … | raw ISO-7816 APDU channel (advanced) |
| `modem_sms_list` | `modem`, `storage?` | list stored SMS (decoded: sender, timestamp, text, multipart merged); `storage` `SM` (SIM, default) or `ME` (modem) |
| `modem_sms_read` | `modem`, `storage?`, `index` | read one stored SMS by index |
| `modem_sms_delete` | `modem`, `storage?`, `index` | delete one stored SMS by index (write ACL) |
| `modem_repower` | `modem?` | hardware repower: pulse the modem `reset_gpio` (or the board default), else power-cycle the modem USB power. Same path as the recovery ladder; recovers a hung / vanished modem |
| `modem_set_protocol` | `modem`, `protocol` | switch the control protocol (`qmi` ⇄ `mbim`); the modem resets |
| `context_up` / `context_down` | `context` or `interface` | connect / disconnect (deferred reply with the IP config) |
| `context_status` / `context_settings` | `context` or `interface` | state, per-family cid/pdh, IP settings |

**Events.** The daemon broadcasts `wwand.modem` (`{ modem, event, … }`, events
`registered` / `deregistered` / `sim_blocked` / `removed` / …) and
`wwand.context` (`{ context, interface, event }`, events `up` / `down` /
`renew`). These are for observers (e.g. LuCI); netifd itself is driven directly
by the daemon (see above), not via an event subscription.

## eSIM management & provisioning

eSIM support lives in the optional **`wwand-esim`** package
(`DEPENDS +wwand +wwand-lpac`). Without it the `modem_esim` methods answer
`{ "error": "esim_not_installed" }` and core wwand is unaffected.

wwand owns the eUICC's APDU channel and drives **ES10c** natively for profile
management (list / enable / disable / delete / EID). Profile **download** from
an SM-DP+ is delegated to **lpac** (shipped as the self-contained `wwand-lpac`,
bundled wolfSSL + libcurl): lpac runs the **ES9+ HTTPS** session to the SM-DP+
over the router's normal uplink — any existing WAN, **no dedicated provisioning
APN** — while the ES10 APDUs travel over wwand's channel (the daemon bridges
lpac's stdio APDU protocol inline). AT-only modems download internally instead
(Quectel `AT+QESIM`).

The **APDU channel** is chosen per modem by `backend.choose`, in order:
**QMI UIM logical channel** (native, or tunnelled over the QMI-over-MBIM
passthrough) → **native MBIM MS UICC Low Level Access** (`OPEN_CHANNEL` /
`APDU` / `CLOSE_CHANNEL`, so eSIM works on an MBIM modem even without an AT port)
→ **AT** (`CCHO`/`CGLA`/`CCHC`, for firmwares that report the QMI channel as
`NOT_SUPPORTED`). The same `_apdu_be` choice serves both the raw `modem_apdu`
channel and the ES10c eSIM path.

All operations go through `modem_esim { modem, op, slot?, … }` (`slot` defaults
to 1):

| op | args | Description |
|---|---|---|
| `eid` | — | read the eUICC EID |
| `backend` | — | which APDU transport the eUICC uses (`qmi` / `mbim` / `at`) |
| `profiles` | — | list installed profiles (ICCID, state, provider / nickname) |
| `enable` | `iccid` | enable a profile (eUICC REFRESH → SIM re-init → re-register) |
| `disable` | `iccid` | disable a profile |
| `delete` | `iccid` | delete a profile (guarded) |
| `download` | `activation_code`, `confirmation_code?`, `auto_notify?` | install a profile from an SM-DP+ (async) |
| `download_status` | — | poll a running download: `idle`/`running`/`done`/`failed` + live lpac log |
| `notifications` | — | list pending eUICC notifications (ES9+) |
| `notify` | — | send the pending notifications to the SM-DP+ |

**Provisioning a profile (download flow):**

1. Get an activation code from the operator —
   `LPA:1$<sm-dp+ host>$<matching-id>` (plus a confirmation code if required).
2. Start the download (async, returns immediately):
   ```
   ubus call wwand modem_esim '{"modem":"m0","op":"download",
     "activation_code":"LPA:1$smdp.example.com$ABC-123"}'
   ```
3. Poll until it settles:
   ```
   ubus call wwand modem_esim '{"modem":"m0","op":"download_status"}'
   ```
   With `auto_notify` (default on) wwand sends the ES9+ install notification to
   the operator after a successful download; otherwise run `op:"notify"` later.
4. Enable the new profile:
   ```
   ubus call wwand modem_esim '{"modem":"m0","op":"enable","iccid":"8988..."}'
   ```
   The eUICC issues a REFRESH; the SIM stack re-initialises and the existing
   recovery/registration path re-establishes the connection.

**Switching to the eSIM permanently:** set `option sim_slot` to the eUICC's
physical slot (so it is selected on every start) and enable the desired profile.
Activation codes and confirmation codes are validated for shell-safe characters
before reaching lpac.

The LuCI **Network → Modem** settings page surfaces the profile list,
enable/disable, the download form with live progress, and notification handling;
the eSIM sections hide themselves when `wwand-esim` is not installed.

## SMS

Receive-only (list / read / delete stored messages — no send). `modem_sms_list`
returns each message decoded — sender (incl. alphanumeric), timestamp, text
(GSM 7-bit incl. umlauts, 8-bit, UCS2), with concatenated multipart messages
merged. `storage` selects the **SIM** (`SM`, default) or the **modem** store
(`ME`). Backend-neutral, chosen once per modem (`sms.uc`, like the APDU path):

1. **QMI WMS** — native, or over the QMI-over-MBIM passthrough. The probe issues
   a real *List Messages*, so a modem whose firmware rejects it (the Quectel
   RG650E returns QMI `MISSING_ARGUMENT`) falls through instead of being picked.
2. **native MBIM SMS** (`uuid_sms`) — for a pure-MBIM modem without the
   passthrough; it has no storage selector (reads the modem's store), so it is
   tried after QMI.
3. **AT** — `AT+CPMS` + `AT+CMGF=0` + `CMGL`/`CMGR`/`CMGD` in PDU mode.

The one GSM 03.40 PDU decoder (`sms_pdu.uc`) serves every backend. LuCI exposes
an **SMS** section on the **Modem Tools** page: a storage selector, load, and a
per-row delete. HW-validated on the RG650E (AT) and the EG06 (passthrough +
native MBIM).

## Board integration

Cellular routers wire the modem's **USB power** and **RESET** lines, and its
**status LEDs**, to board GPIOs — historically driven by a vendor helper script.
wwand absorbs that: it detects the board from `/etc/board.json` and applies a
built-in profile.

- **Power / reset** — a profile may expose a modem power GPIO and/or a reset
  GPIO. The recovery ladder's hardware rung uses them (a modem `reset_gpio` in
  config, or the board default, is **pulsed** — read, inverted, held for
  `repower_time` (default 30 s), restored; otherwise the USB power is **power-cycled**), fully replacing the old
  external `usb-repower` tool. Trigger it by hand with `modem_repower` (a "Reset
  modem" button in LuCI) to recover a modem that hung or dropped off the USB bus.
  A modem `reset_gpio` works **without** a board profile, so any router can wire a
  GPIO reset into the ladder.

The recovery ladder escalates on consecutive failed connection attempts:
op-mode cycle (8) → modem reset (16) → board repower / reset-GPIO pulse (24) →
system reboot (> `failreboot`, default 100). The three **hardware** rungs fire
on their thresholds **independent of `failreboot`**; `failreboot 0` disables
**only** the final reboot — the hardware recovery still runs and the ladder then
keeps retrying forever, so a headless box stays up for logging/debugging.
`proto_error_limit` (default 25) is a separate ceiling on protocol-level errors
that also ends in a reboot, and is gated by `failreboot` the same way.
- **Status LEDs** — driven from the modem's registration + signal: a **5-bar
  signal graph** (e.g. MikroTik Chateau `green:mobile-1..5`) or a **mobile / LTE**
  set (e.g. Zyxel `…:red/green:mobile`, `…:lte`).
- **Waiting for modem** — after boot, a modem reboot or a power-cycle the control
  device may take a while to (re)appear. wwand then **waits for hotplug** (it does
  not fail), sets the modem `control_note` (shown in `status` and LuCI), reports a
  `WAITING_MODEM` interface error to netifd, and re-logs it every 30 s so the wait
  is visible.

Built-in profiles: MikroTik Chateau 5G (`modem-power` + `modem-reset` + 5 signal
LEDs), Zyxel LTE3301-plus / -m209 / -q222 (`power_modem`/`usbpower` + mobile/LTE
LEDs), NR7101 (no dedicated GPIO/LED). An **unknown board** yields a no-op
profile — wwand runs unchanged, and any GPIO/LED can still be named per modem
(`reset_gpio`). LuCI's reset-GPIO picker lists every named GPIO line the kernel
exposes. Adding a profile: see [extending.md](extending.md#adding-a-board-profile).

## Telemetry & diagnostics

With `stats_interval > 0` the daemon logs one compact line per interval and
caches the structured data (query it via `modem_cells`):

```
telemetry: tech=LTE plmn=262/01 (Telekom.de) roaming=no
  lte=[plmn 262/01 tac 3071 gci 29582339 earfcn 1300 pci 246 rsrp -97.4 rsrq -10.9 neigh 2]
  sig_lte=[rssi -66 rsrp -98 snr 15.0]
```

The first sample runs right after registration (cell environment at connect
time), then at the configured interval.

**registration_detail** — when registration is stuck or in limited service, the
daemon collects *why* and exposes it on `status` / `modem_cells` (and logs a
warning). QMI (`GET_SYSTEM_INFO`: limited-service flag + EMM reject cause) is
combined with `AT+CEER` (clear-text cause) — they are complementary, since many
modems leave the QMI reject cause empty but report limited service:

```json
"registration_detail": { "source": "qmi+at", "limited": true,
                         "reject_cause": 33,
                         "reject_text": "requested service option not subscribed" }
```

**Data-system mode** — `modem_cells` → `dsd { mode, lte, nr, source }` reports
the actual data system (`LTE` / `NSA` / `SA`) from the QMI DSD service, falling
back to the QENG serving line (AT) and then the coarse NAS radio interfaces.
`source` names which path answered.

**Invalid-response handling** — wwand recognises structurally-valid-but-unusable
QMI answers instead of caching garbage: a truncated decode is treated as a
protocol error; empty poll replies keep the last-known data; the per-type
"not available" sentinels (`-32768`, `0xFFFFFFFF`) are normalised to null on
signal and on every serving/neighbour cell at ingestion, so the UI shows "—"
rather than e.g. `-3276.8 dBm`.

## Troubleshooting

- `option log_level 'debug'` (globals) shows every state transition, CID
  allocation and QMI error. `set_log_level` changes it at runtime.
- `ubus call wwand status` / `context_status` for a live snapshot.
- `ubus call wwand modem_at '{"modem":"m0","command":"AT+QENG=\"servingcell\""}'`
  for ad-hoc modem diagnostics.
- Recovery counters live in `/tmp/wwand/state/` and survive daemon restarts
  (cleared by reboot — the ladder's last rung).

**Stuck in REGISTERING / limited service.** Read `registration_detail`. EMM
cause **33** ("requested service option not subscribed") on a good signal is an
**attach** rejection, not a coverage problem: the attach profile's APN/PDP type
is not what the subscription allows. wwand programs the attach profile from the
context config before registration; if it persists, check `apn` and `pdp_type`
(some subscriptions reject an IPv4-only attach — use `ipv4v6`).

**No 5G despite a 5G modem on a 5G cell.** If the modem is 5G-enabled and camps
on a valid NSA anchor but never gets an NR carrier, `modem_cells` → `dsd` shows
`nr: false`: the network is not granting EN-DC for this subscription
(DCNR-restricted / the tariff excludes 5G). Not a wwand or modem issue.

**SIM.** `modem_sim_slots` shows slot/card/eUICC state; `option sim_slot`
selects the physical slot; `modem_sim_pin_lock` enables/disables the PIN lock.
`SIM_BLOCKED` is terminal until a config reload (PIN guard tripped, no card, or
PUK required).

## Quirk handling

wwand adapts to per-model firmware quirks through small **pattern-gated tables**
and **runtime capability probing** (`backend.choose`: try the QMI path, fall
back to AT, cache the decision per modem). Adding a modem usually means
extending a table, not branching the code — see
[docs/extending.md](extending.md) for the step-by-step.

| Quirk | Mechanism | Example |
|---|---|---|
| AT port discovery | 4-level fallback: `option tty` → board table → the `atport.uc` udev table (generated from ModemManager) → first-ttyUSB heuristic | — |
| Init AT commands | `MODEL_QUIRKS` (atcmd.uc): model pattern → commands run once before registration | EG06/EM06/RG50xQ → `AT+QMBNCFG="AutoSel",1` (carrier-config auto-select) |
| QMAP aggregation size | `board_dgram_size`: DL datagram size per model, then per board, overridable via `dl_datagram_max_size` | RG650E-EU → 31 KB (else 4 KB default) |
| QMAP DAP fallback | rmnet requests MAPv5 checksum offload, renegotiates plain QMAP when the modem declines aggregation | RG650E declines DAP 8 edge cases |
| eSIM host access | `esim_quirks`: some firmwares must have the internal LPA's `lpa_enable` disabled (one-time NV reset) so host-side ES10 APDUs work | RG65xx |
| Identity read | UIM raw EF read → DMS getter fallback | EG06 rejects EF reads → IMSI/ICCID via DMS |
| PIN unlock | UIM `VERIFY_PIN` → DMS fallback, with retry guards | — |
| Attach profile | CID1 programmed from config before the autonomous attach | avoids the EMM-33 IPv4-only / wrong-APN reject |
| Operator name | decoded whether plain ASCII or GSM-7 bit-packed (some modems pack the PLMN name) | EG06 |
| Protocol switch | QMI ⇄ MBIM via `AT+QCFG="usbnet"` (`modem_set_protocol`); the modem resets and re-enumerates | Quectel RG5xx/RG6xx/EG |
| MBIM firmware bug | some firmwares reject `MBIM_OPEN` — MBIM stays QMI-only there | RG650E |
| Serial drain | discard stray serial noise before AT on modems that need it | M9200B |
| Cell locking | Quectel `AT+QNWLOCK` for a fixed 4G anchor / 5G SA cell | `lock_4g` / `lock_5g` |

The known-model tables live in `atcmd.uc` (init + eSIM quirks), `netlink.uc`
(datagram size) and `protocol_switch.uc` (protocol recipes); capability probes
go through `backend.uc`.

## Glossary

| Term | Meaning |
|---|---|
| **PDP context / bearer** | A cellular data session with its own IP config. wwand maps one context to one netifd interface. |
| **Attach profile** | The 3GPP profile (CID 1) the modem uses for the *autonomous* LTE/5G attach. wwand programs its APN/PDP type from config **before** registration to avoid a wrong-APN reject. |
| **QMAP / mux** | Qualcomm multiplexing that carries several PDP contexts over one USB link, each as an L3 device `wwan0mN`. Backends: **rmnet** (kernel, preferred) or **qmimux** (sysfs). |
| **`mux_id`** | The QMAP channel of a context (0 = no mux, N = `wwan0mN`). |
| **NSA / SA / DSD** | 5G Non-Standalone (NR anchored on LTE) / Standalone / Data-System-Determination (the QMI service reporting which the session actually uses). |
| **EMM cause** | LTE NAS reject reason. Cause 33 ("service option not subscribed") usually means the *attach* APN/PDP type is wrong for the SIM, not "no coverage". |
| **eUICC / eSIM** | An embedded UICC that holds multiple downloadable SIM **profiles**; one is enabled at a time. |
| **SM-DP+ / ES9+ / ES10** | The GSMA remote-provisioning server (SM-DP+), the download protocol to it (ES9+, HTTPS), and the local eUICC APDU interface (ES10). lpac speaks ES9+; wwand relays ES10 APDUs to the modem. |
| **no-proto-task** | The netifd mode where the proto handler runs no supervisor process; the daemon owns the interface lifecycle and drives netifd over ubus. |
| **passthrough** | QMI-over-MBIM: the QMI stack tunnelled through the MBIM `QMI` service, so an MBIM modem gets full QMI telemetry/config. |

## FAQ

**Does restarting wwand drop the connection?** No. A restart is non-destructive
(`stop_local`): the WAN and live traffic survive, and the daemon adopts the
running session once the modem reports `registered`. Only a full `shutdown`
(package removal) tears the session down.

**The modem sits in REGISTERING with good signal — why?** Read
`registration_detail`. An EMM reject cause (e.g. 33, "requested service option
not subscribed") means the *attach* was rejected, not that there is no coverage
— usually the attach APN or PDP type is wrong for the subscription. Check `apn`
and use `pdp_type ipv4v6` (some subscriptions reject IPv4-only).

**5G modem on a 5G cell but only LTE.** `modem_cells` → `dsd` with `nr: false`
means the network is not granting EN-DC for this SIM (the tariff is LTE-only /
DCNR-restricted). Nothing wwand or the modem can change.

**Two connections over one modem?** Point two `interface` sections at the same
`option modem`, each with a different `mux_id` (and `apn`); QMAP multiplexing
gives each its own `wwan0mN` L3 device. All contexts of a muxed modem get a
channel.

**Switch to an eSIM profile?** Install `wwand-esim`, download a profile
(`modem_esim op:download`), enable it (`op:enable`), and set `option sim_slot`
to the eUICC slot for a permanent switch — see
[eSIM management](#esim-management--provisioning).

**MBIM doesn't work on my modem.** Some firmwares (e.g. RG650E) reject
`MBIM_OPEN` — a firmware bug, not wwand; stay on QMI. Switch back with
`AT+QCFG="usbnet",0` + `AT+CFUN=1,1`, or `modem_set_protocol`.

**Old config — do I need to migrate?** No. The daemon reads every older format
(legacy inline `proto qmi`, the previous `/etc/config/wwand`). Conversion to the
network-native model happens automatically on install/upgrade (a uci-defaults
script) and on LuCI save. It also converts **stock `proto mbim`/`proto ncm`**
interfaces — required, since `wwand-mbim`/`wwand-ncm` replace those handlers. Run
it by hand any time: `/usr/libexec/wwand/migrate` (dry run) then `--apply`.

**Lock to a specific cell?** `option lock_4g 'earfcn:pci'` (LTE) or
`option lock_5g 'pci:arfcn:scs:band'` (NR SA); `lock_persist 1` stores it in the
modem NV. The LuCI Modem page has a one-click "Lock this cell".

**Where are the recovery counters?** `/tmp/wwand/state/` — they survive a daemon
restart and clear on reboot (the recovery ladder's last rung).

## Development

```
wwand/tests/run_tests.sh    # host-side suites, no hardware required
```

Needs a host ucode with the fs/struct/uloop modules (and ubus/uci plus a
`ubusd` binary for the daemon integration suite — skipped otherwise). The mock
hub drives the real codec; reproduce field issues as scenarios.

**QMI schemas must match libqmi.** Verify every message id and TLV id against
libqmi's `data/qmi-service-*.json` (request TLVs vs `input`, response vs
`output`, resolve `common-ref` ids) — a wrong tag silently decodes garbage.

`tools/gen-atport-table.py <modemmanager-checkout> > src-ucode/atport.uc`
regenerates the AT port table from ModemManager's udev rules.
