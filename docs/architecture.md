# wwand — architecture

A from-scratch native QMI/MBIM/NCM stack in ~3 MB — a tenth of ModemManager —
that has survived a dwc3/swiotlb 4-byte-URB storm, provider-side SIM purges, and
four datapath variants (rmnet / qmimux / raw-ip / NCM-ECM) in production. This
document is how it's built and why each decision was forced by the field; read
[`connection-flow.md`](connection-flow.md) next to it for the runtime bring-up
sequence, and [`luci.md`](luci.md) for the web UI.

Status: three control backends (QMI, MBIM, NCM) behind one daemon-neutral
contract, all config in `/etc/config/network`, native SIM/eSIM. In production on
a MikroTik Chateau 5G R17 ax (Quectel RG650E-EU, 5G NSA, two parallel PDP
contexts). RSS figures below are for the QMI-only base; MBIM/NCM add ~200–400 KB
per modem and load only when their package is installed.

## 1. Measured baseline (Chateau)

One process. Zero per-context spawns. ~3 MB resident. The measured baseline:

| Metric | Value | Context |
|---|---|---|
| Daemon RSS | **~2.9 MB** | ModemManager + libqmi + glib: typically 15–30 MB |
| Open fds | 36 | cdc-wdm, tty, ubus, uloop; watched for leaks in soak tests |
| ucode sources | 196 KB uncompressed | ≈ 40–50 KB on squashfs |
| Native module | ~68 KB stripped | I/O + rmnet netlink helper |
| Processes | **1 daemon, 0 per context** | no per-interface supervisor (no-proto-task) |
| External spawns at runtime | 0 | only reboot in recovery (repower is a board GPIO) |

## 2. Layering

```
 native (C):   wwand_io.so       — message-oriented cdc-wdm/tty I/O
                                   (protocol-agnostic), rmnet netlink helper
 codec:        qmux.uc, tlv.uc, hex.uc, schema/*.uc  — QMI, declarative
               mbim.uc, mbim-schema/*.uc             — MBIM, declarative
 session:      transport.uc (hub/routing), client.uc (QMI correlation),
               mbim_client.uc, qmi_over_mbim.uc (QMI-over-MBIM passthrough hub)
 backends:     QMI  — modem.uc/context.uc + extracted helpers modem_init_qmi.uc,
                      telemetry_qmi.uc, datapath_qmi.uc, context_monitor_qmi.uc,
                      regdetail.uc, config_check.uc
               MBIM — modem_mbim/context_mbim + telemetry_mbim.uc
               NCM  — modem_ncm/context_ncm + telemetry_ncm.uc (NCM/AT)
               one daemon-neutral contract; shared core:
                      modem_common.uc, context_common.uc, backend.uc,
                      qmi_backend.uc, mbim_backend.uc, sim.uc
 system:       netlink.uc (datapath), recovery.uc, board.uc (power/reset/LEDs),
               atcmd.uc + atcmd_parse.uc (+atport),
               discovery.uc (control-type detection), modeswitch/protocol_switch
 integration:  daemon.uc + netsel_ops.uc (registry/policy), config.uc
               (+migrate/compat), ubus.uc, main.uc
 shell:        wwand-proto.sh (thin netifd shim → wwand.sh, proto `wwand` + opt-in `qmi`), init, hotplug,
               wwand-migrate + uci-defaults (opt-in config migration, `option takeover`)
```

The three control backends (QMI, MBIM, NCM) sit behind one **daemon-neutral
contract** (`docs/backend-interface.md`): identical modem methods and an
identical context `settings` shape, so everything above the backend layer is
protocol-agnostic. `discovery.resolve_control` picks the backend per modem from
the driver/device. Backends load lazily and ship as **separate packages**
(`wwand-qmi` / `wwand-mbim` / `wwand-ncm`) on a backend-neutral `wwand` base; a
missing backend package is reported (`control_note` in `status()`), not fatal.
All configuration lives in `/etc/config/network` (see `docs/reference.md`).

Design principles, all validated in the field:

- **Effect injection everywhere** (`fx`, `transport_open`, `deps`): the whole
  logic runs host-side against mocks (current suite/check counts live in
  `docs/STATUS.md`); every
  field bug becomes a scenario in the suite.
- **Declarative message schemas** (field tables verified against libqmi's
  JSON definitions) instead of generated code.
- **All state per modem/context instance** — multi-modem is a requirement,
  not an afterthought. Logs are prefixed accordingly.
- One process, one uloop, indication-driven; timers only where indications
  don't exist (packet stats, registration guard, settle delays).
- **Never trust modem echoes blindly.** The WDA negotiation renegotiates on
  rejection and never adopts zeroed values (see the field lesson below).
- sysfs attributes differ per kernel (e.g. `rx_urb_size` is a vendor patch;
  mainline usbnet derives the URB size from the parent MTU) — every
  attribute write distinguishes "absent on this kernel" from "write failed".

> **Field lesson — the 4-byte-URB storm.** A v5 QMAP aggregation request once
> came back answered with "aggregation disabled, size 0". Taken at face value,
> that zero drove a 4-byte URB configuration into the driver and set off a
> dwc3/swiotlb storm that took the datapath down. The fix — and the reason the
> WDA path treats a zeroed echo as a rejection to renegotiate, never a value to
> adopt — is the single most load-bearing "don't trust the modem" rule in the
> codebase.

## 3. Selected mechanisms

### Modem lifecycle

Bring-up is a linear step chain per modem; any step failure tears down and
schedules a capped-backoff retry that climbs the recovery ladder (§ Recovery).

```
  ABSENT
    │ start()
    ▼
  INIT_TRANSPORT ─► INIT_SERVICES ─► INIT_DATAPATH ─► SET_OPMODE
                                                          │ set-online
                                                          ▼
                             ┌── low power ──  VERIFY_ONLINE ◄──┐
                             ▼                 (GET_OPMODE)      │ retry
                          FCC_AUTH ────────────────────────────┘
                       (dms 0x555F / foxconn 0x5571)
                                                          │ online
                                                          ▼
                                    (read active ICCID)  SIM_UNLOCK ──blocked──► SIM_BLOCKED
                                    pick wwand_sim PIN        │                   (terminal until
                                                              ▼                    config reload)
                                                        CONFIGURE_NET
                                                        (attach profile
                                                         set from config)
                                                              │
    ┌── fail: teardown + backoff ◄──── REGISTERING ◄──────────┘
    │   retry (recovery ladder)            │
    │                                      ▼ registered
    └────────────────────────────────►  READY
                                           │  emits 'registered'
                                           ▼
                                the daemon binds/kicks each interface;
                                contexts activate (per PDP / mux channel)
```

`device removed` → `ABSENT` + `removed` at any point; hotplug rebuilds it.
MBIM and NCM run the same shape with protocol-specific steps (e.g. MBIM
`OPEN → DEVICE_CAPS → SUBSCRIBER_READY → PIN → REGISTER → PACKET_SERVICE`).

**FCC RF unlock.** Laptop-SKU modems (Lenovo/Dell/HP Quectel EM05/EM120/EM160,
Foxconn SDX55/SDX62, Dell DW5821e-class) accept set-online but stay in
(persistent) low power until the host sends an FCC authentication message. So
after `SET_OPMODE` the QMI init re-reads `GET_OPERATING_MODE`
(`modem_init_qmi.uc` `verify_online`): a modem still reporting a low-power mode
runs the `fcc_auth` chain (`qmi_backend.fcc_auth` — DMS Set FCC Authentication
`0x555F`, no args; or Foxconn `0x5571` with a u8 magic — `option fcc_auth`
selects `dms`/`foxconn[:magic]`, `auto` tries both, `off` disables), sets
online again and retries. An ordinary modem answers online on the first pass and
never sees an FCC message. MBIM does the equivalent through the vendor Quectel
Radio State service (`codec/mbim-schema/quectel.uc`, mirroring `mbimcli
--quectel-set-radio-state=on`).

### Datapath (QMAP muxing)

Backend selection per modem: rmnet pass-through preferred (needs
`kmod-rmnet`), qmimux via sysfs `add_mux` as fallback, plain raw-ip without
muxing. Sequence preserved from years of field experience: link down →
`raw_ip` (before `pass_through` — driver requirement) → MTU 1504 → create
mux links → parent MTU = negotiated aggregation size + 4 → children up.
rmnet links are created through the native helper including
`IFLA_RMNET_FLAGS` (ingress deaggregation is mandatory; MAPv5 checksum
offload flags are set only when the modem confirms v5 — the RG650E declines
it on USB). Aggregation size comes from a model table (e.g. RG650E 31 KB),
then a board table, config override wins; the modem clamps the request and
the echoed value drives the driver side.

**Bidirectional aggregation, endpoint typing & client type.** `SET_DATA_FORMAT`
negotiates **uplink** QMAP aggregation as well as downlink — `ul_max_datagrams`
/`ul_max_size` (libqmi TLVs 0x1B/0x1C) alongside the DL parameters — and the host
side is switched on to match via the rmnet **egress coalesce** (ethtool `TX_AGGR`,
since mainline rmnet has no `IFLA_RMNET_UL_AGG_PARAMS`; a native genl helper in
`wwand_io`). So a QMAP link aggregates in **both** directions, not just downlink.
The endpoint-info TLV carries the real bus — `ENDPOINT_TYPE_HSUSB` vs `PCIE`,
derived from the netdev's sysfs path (`netlink.ep_type_number`) — so PCIe/MHI
modems (e.g. RG500Q on M.2) are typed correctly instead of a hardcoded HSUSB, in
both `SET_DATA_FORMAT` and `BIND_MUX_DATA_PORT`; the bind also tags the client as
tethered (`client_type`). A vendor `qmi_wwan` that gates each mux behind a
`link_state` sysfs node is opened per channel (existence-gated, no-op on mainline).
All of it stays **capability-gated**: aggregation is applied only when the modem
confirms QMAP in its echo (non-zero DL size) — a non-QMAP modem, or a config
without a mux, drops to plain raw-ip framing and the extra TLVs are harmless.

**Stable L3 device names.** USB enumeration order is not stable, so wwand gives
every interface a deterministic L3 device name instead of inheriting whatever the
kernel picked. `config.uc` `assign_l3_names` walks the contexts in config order
and hands each one a name from a single flat namespace **`wwand0`..`wwand100`**,
independent of which modem it lives on; an explicit interface `option device`
(any non-path name) pins the name instead. How that name is realised depends on
the datapath:

- **Non-mux datapaths** (QMI/MBIM without a mux, and NCM/ECM): the daemon
  **renames** the kernel netdev to the assigned name over netlink
  (`daemon.uc` `rename_l3` → `link_set {rename}`). If the target name is already
  in use, or the link is busy and the rename fails, it logs an error and **keeps
  the kernel name** — it never forces the issue.
- **Muxed datapaths** (QMAP): the mux **child** is created directly under the
  assigned name (`mux_link` is unified onto `l3_name`); the muxed **parent**
  keeps its kernel name and is never renamed.

On `registered` the daemon writes the resolved name back onto the interface
section as `option device` (`main.uc` `learn_device`): idempotent, `commit`-only
so no interface bounce, and it **never clobbers a user-set value** — gated by
`wwand_globals.write_device` (default on). That gives VRF `list ports`, firewall
and LuCI one explicit, editable, stable handle onto the datapath.

### netifd coupling (no-proto-task; daemon drives netifd in place)

There is **no per-interface monitor process**. The proto handler declares
`no-proto-task`, so after setup netifd leaves the interface `IFS_UP` with no
supervisor task, and the **daemon** owns the context lifecycle — it drives
netifd over ubus (`network.interface <x> up/renew/down`).

```
  ifup wan
     │
     ▼
  netifd ──proto_wwand_setup──► wwand-proto.sh ──ubus wwand context_up──► daemon
                                                                          │ activate
                                                                          │ PDP context
     ◄──────────── reply { ipv4{…}, ipv6{…}, mtu } ◄───────────────────── ┘
     │
  proto_add_ipv4_address / proto_add_*_route / proto_add_dns_server
  proto_send_update (keep=1)          ← addressing/routing = netifd's job (VRF-safe)
     │
     ▼
  interface IFS_UP        (no task — daemon owns the lifecycle from here)
     ⋮
  transient loss ─► daemon reconnects the session in place
                    ─► ubus network.interface renew
                    ─► proto_wwand_renew re-reads context_settings → delta update
                       (no teardown → IPv6-PD + VRF routes preserved)
     ⋮
  permanent loss / hold_max expiry ─► network.interface down (accept the flush)
```



A **transient** loss (network drop, registration loss, recovery reset, brief
modem-lost) keeps the netifd interface up and reconnects the modem session **in
place**: on success the daemon fires `network.interface renew`, whose
`proto_wwand_renew` re-reads `context_settings` and re-sends the update with
`keep=1`, so netifd diffs against the live config and applies only the delta.
No teardown fires, so `interface_ip_flush` never runs and the downstream
IPv6-PD assignments and VRF-table routes are preserved. The blackhole is bounded
by a hold timer (`hold_max`, default 90 s); if the context never recovers the
daemon drives `network.interface down` (accepting the flush) and revives it when
the modem is usable again. A **permanent** loss (`sim_blocked`, admin/config
down) drives `down` immediately.

Because a plain daemon exit is non-destructive (`stop_local` does not bring
contexts down), the WAN stays up and traffic keeps flowing across a wwand
restart; the fresh daemon **adopts** the live session on modem-ready — it probes
`network.interface status` and, if the interface is still up, re-activates the
context and renews in place (never a down/up), otherwise kicks netifd to re-run
setup. Settings changes while connected work the same way: the context
re-queries `GET_CURRENT_SETTINGS` on serving-system changes (plus a slow safety
poll) and emits `settings`, which the daemon maps to `renew`.

A config **reload** (`apply_config`) is likewise scoped: it diffs the new config
against the running state and bounces **only** the modems/contexts that actually
changed, keyed on a per-modem signature (its cfg plus its derived mux set + L3
name) and a per-context signature (its cfg). An unchanged section keeps its live
`modem`/`ctx` object untouched, so editing one interface's APN reconnects only
that context while every other session — including sibling contexts on the same
modem — runs uninterrupted. Adding/removing a mux channel changes that modem's
datapath signature, so its own contexts bounce (scoped to that modem). A forced
single-interface restart stays available through `ifup`/`ifdown`, which act on
exactly one interface regardless of the diff.

(Earlier designs — a `context_wait` long-poll monitor, and driving the mux
child's carrier so netifd's own link tracking would teardown/re-setup — were
dropped: the deferred long-poll still cost a process per interface, and
rmnet/qmimux children do not implement `ndo_change_carrier` so the carrier
cannot be toggled per context.)

### Routing / VRF compatibility (invariant)

The daemon touches only the **link layer** of the datapath — mux creation,
MTU, carrier, rename, up/down (`RTM_NEWLINK`) and qmi/sysctl sysfs. It never
adds IP addresses, routes or policy rules, and never sets `IFLA_MASTER`. All
addressing and routing is handed to **netifd** via the proto shim
(`proto_add_ipv4_address` / `proto_add_*_route` / `proto_send_update`).

This is what makes wwand VRF-safe: netifd applies the interface's
`ip4table` / `ip6table` (and thus any VRF / l3mdev binding) to every address
and route it installs, entirely at the interface level and independent of the
protocol. Because the daemon never enslaves the l3 device or writes a routing
table itself, netifd is free to enslave the mux child (e.g. `wwand0`) to a
VRF master and place its routes in the VRF table. A regression test
(`test_datapath`, "vrf: datapath performs no direct addressing/routing")
fences this invariant: any future `ip route` / `ip addr` / `ip rule` in the
datapath fails the suite. Deeper netifd integrations (runtime `notify_proto`
updates, carrier-driven teardown, renew) must keep addressing in netifd to
preserve this.

One caveat follows from the same split: when the daemon *recreates* the mux child
(QMAP renegotiation, a backend/mode switch that re-enumerates the netdev) the new
device comes up **unenslaved**, and netifd re-applies `IFLA_MASTER` only when it
observes the device reappear — so a brief window exists where the netdev is up but
not yet in the VRF. Holding the netdev stable (renew **in place** rather than
teardown/recreate) keeps that window from opening; it is another reason the
transient-loss path never tears the device down.

### IPv6 addressing & prefix delegation

wwand configures the WAN's IPv6 from the modem's `GET_CURRENT_SETTINGS`: a global
address (published as a `/128`) plus the on-link `/64`, which the proto shim
shares toward the LAN per RFC 7278 (`proto_add_ipv6_prefix`). There is **no
IA_PD request to the modem** — QMI/MBIM only ever expose that single `/64`.

True prefix delegation (a separate, shorter prefix from the carrier) is therefore
layered **on top**, not folded into the daemon: a stacked `proto dhcpv6` interface
riding on wwand's l3 device (`option device '@wan'`) runs a DHCPv6-PD client for
the delegation, while wwand keeps owning the GUA + default route unchanged. Two
constraints shape this: the exchange is a DHCPv6 IA_PD toward the P-GW (only works
where the carrier delegates), and it needs a **global** source address — hence the
stack must inherit wwand's GUA (a link-local source generally does not carry over
the bearer, and odhcp6c cannot be told to pick the source). See the
[deployment examples](reference.md#deployment-examples) for the concrete config.

### Recovery ladder

Failed connection cycles climb: attempt 8 → operating-mode low-power/online
cycle, 16 → modem offline/reset, 24 → **hardware repower** — a modem/board
`reset_gpio` pulse or a USB-power-cycle via the [board profile](reference.md#board-integration)
(replacing the old external `usb-repower` tool) — > `failreboot` → system
reboot. QMI request errors have a separate ceiling (25 → reboot). Counters
persist in tmpfs across daemon restarts and are intentionally cleared by
reboot. A zero-rx watchdog (packet stats delta) triggers the same repower.

Alongside the automatic ladder, the `modem_reset` ubus method
(`daemon.uc`) offers an admin-driven reset with the same GPIO-first priority: it
pulses the modem/board `reset_gpio` when one is configured, else falls back to
the backend soft reset (QMI DMS offline→reset, NCM `CFUN=1,1`). Board-default
GPIOs are gated by `board_gpio_ok` (a shared board power/reset rail is only
touched on a single-modem box); a per-modem `reset_gpio` is the multi-modem path.

### Boot robustness

The daemon may start before USB enumeration: modems resolve lazily, the
hotplug script re-triggers resolution and binds contexts afterwards. netifd
may give up after early setup failures — on modem registration the daemon
kicks the affected interfaces (`network.interface up`).

### AT side channel (best-effort)

Port discovery: config override → board quirk table → USB id + interface
number lookup in a table generated from ModemManager's udev rules (225
devices; lazily loaded) → first-tty heuristic. Serialized command engine
with echo filtering and OK/ERROR/+CME parsing. Used for model init quirks
(Quectel MBN autoselect — a QMI-native PDC replacement is a future option),
cell locking, the Huawei mode fallback, and ad-hoc diagnostics via ubus.
Connection bring-up never depends on AT.

## 4. Maintainability review — open items

The cross-backend duplication (scaffolding, fail/backoff, the telemetry watch
loop, the zero-rx watchdog) has been consolidated into `modem_common.uc` /
`context_common.uc`; the remaining fork between the three backends is genuine
per-protocol logic (step chains, teardown, `with_nas`). Open items:

1. A ~25-line `series()` helper would flatten the deeper callback chains
   (`_read_info`, sim flows).
2. Error objects are ad hoc; an `errors.uc` with constants and a QMI
   error-code name table would improve logs and grep-ability.
3. Recovery persistence writes on every counter change; a dirty-flag with a
   1 s timer would throttle failure storms (tmpfs, so hygiene only).

(The old per-interface shell monitor is gone — the no-proto-task model in §3
removed it entirely, so its process cost no longer applies.)

## 5. Control backends (QMI, MBIM, NCM)

`discovery.resolve_control` classifies each modem by its driver/device and
builds the matching backend; all three satisfy the same contract, so nothing
above cares which one is in use.

```
              ┌──────────── daemon-neutral contract ─────────────┐
              │ modem: start/stop/state/with_nas/attach_context/ │
              │        note_connect_*/switch_protocol + events    │
              │ context settings: {ipv4{…}, ipv6{…}, mtu}         │
              └──────────────────────────────────────────────────┘
                   │                  │                    │
               ┌───┴───┐         ┌────┴────┐          ┌────┴───┐
               │  QMI  │         │  MBIM   │          │  NCM   │
               │ modem │         │ modem   │          │ modem  │
               └───┬───┘         └────┬────┘          └───┬────┘
      native qmux  │      native MBIM │  + QMI-over-MBIM  │  AT commands
                   │    (MS BasicConn)│    passthrough    │
                   ▼                  ▼   (reuses QMI)     ▼
            /dev/cdc-wdmX       /dev/cdc-wdmX        /dev/ttyUSBx  +
             (qmi_wwan)          (cdc_mbim)          cdc_ncm/cdc_ether
```

- **QMI** — native QMUX over `/dev/cdc-wdmX`, the reference backend.
- **MBIM** — native **MS Basic Connect Extensions** (v2/v3) for telemetry, plus a
  **QMI-over-MBIM passthrough** (`qmi_over_mbim.uc`): a hub-shim that tunnels raw
  QMUX frames through the MBIM `QMI` service, so the entire QMI stack
  (`client.uc`, schemas, `qmi_backend.uc`) runs unchanged over the open MBIM
  channel. This is why `wwand-mbim` depends on `wwand-qmi`. **Invariant: never
  send CTL SYNC over the passthrough** — it resets the modem's embedded QMI state
  and kills the live MBIM data session (HW-proven on EG06); the shim blocks it
  structurally.
- **NCM** — AT-controlled (`modem_ncm.uc` `VENDORS` recipes) over a plain
  `cdc_ncm`/`cdc_ether` netdev, for modems with no cdc-wdm control device.

Shared logic is extracted once and installed by every backend:
`modem_common.uc` (state/context scaffolding, `make_fail`, the adaptive
telemetry `watch_driver`, AT bring-up, lazy `at2`) and `context_common.uc`
(zero-rx watchdog). A PPP-only modem is mode-switched once (`modeswitch.uc`) to a
richer usbnet mode and rebuilt by hotplug.

## 6. SIM, eSIM & eUICC

wwand owns the modem's UIM channel end to end, so SIM handling is native — no
separate AT port or helper daemon.

- **SIM** — PIN unlock (UIM `VERIFY_PIN` → DMS fallback, retry-guarded), multi-
  slot switching (`modem_sim_slots` / `modem_sim_switch_slot`), PIN
  enable/disable (`modem_sim_pin_lock`), and per-SIM config overrides
  (`config wwand_sim`, matched by ICCID) that pick the PIN/APN for the inserted
  card before unlock (the MF-level ICCID is readable while locked).
- **eSIM (eUICC)** — native **ES10c** profile management (list / enable / disable
  / delete) over the UIM APDU channel, plus **SM-DP+ provisioning** driven by a
  bundled **lpac** (optional `wwand-esim` package). The download runs the ES9+
  HTTPS on the router over the existing WAN — no dedicated provisioning APN:

```
  LuCI / ubus  ──►  daemon: modem_esim(op:"download", activation_code)
                       │
                       ▼
              esim_bridge spawns lpac  (env LPAC_APDU=stdio LPAC_HTTP=curl)
                       │
        ES9+ HTTPS ────┤  lpac ⇄ SM-DP+   (profile download, over the WAN)
                       │
        ES10 APDUs ────┤  lpac stdio ⇄ daemon ⇄ modem UIM
                       │                 (ubus modem_apdu — wwand stays the
                       │                  sole owner of the modem)
                       ▼
              profile installed on the eUICC
                       │
              op:"enable" ──► ES10c ENABLE + eUICC REFRESH ──► SIM re-init
                       │                                       ──► re-register
                       ▼
              set `option sim_slot` to the eUICC slot = permanent boot default
```

lpac is either the stock openwrt-packages `lpac` or the bundled `wwand-lpac`
(both provide `/usr/bin/lpac`); the stdio APDU bridge needs lpac ≥ 2.3.0.

## 7. Configuration & migration

All config lives in `/etc/config/network` (WireGuard-style typed sections):
`wwand_modem` (hardware + SIM slot + radio), `wwand_sim` (per-ICCID override),
`interface` with `proto wwand` + `option modem` (the connection), `wwand_globals`.
The netifd shim registers `wwand`; the legacy `qmi` alias only when the global
`option takeover` is set. **wwand is a good citizen by default:** it installs
alongside the stock uqmi/umbim/comgt-ncm packages (no CONFLICTS) and manages only
`proto wwand` interfaces — bare `proto qmi`/`mbim`/`ncm` interfaces are left to the
stock stack. Moving one to wwand is explicit: `config.migrate_plan` converts it
**in place** to `proto wwand` (+ a linked `wwand_modem`), driven from the LuCI
modem list (the `migrate` ubus method) or the `wwand-migrate` CLI. Setting
`option takeover '1'` restores the old automatic behavior (adopt legacy
interfaces at runtime + auto-migrate on install/upgrade). See `docs/reference.md`.

## 8. Roadmap

1. Byte-trace captures from real modems as codec regression fixtures.
2. QMI-native cell-lock / PDC (replacing the AT `QNWLOCK` / `QMBNCFG` quirks).
3. Wider modem coverage in the quirk tables (see `docs/extending.md`).
