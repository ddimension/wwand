# wwand — architecture

Status: after milestones M1–M6 + production use on a MikroTik Chateau 5G
R17 ax (Quectel RG650E-EU, 5G NSA, two parallel PDP contexts).

## 1. Measured baseline (Chateau)

| Metric | Value | Context |
|---|---|---|
| Daemon RSS | **~2.9 MB** | ModemManager + libqmi + glib: typically 15–30 MB |
| Open fds | 36 | cdc-wdm, tty, ubus, uloop; watched for leaks in soak tests |
| ucode sources | 196 KB uncompressed | ≈ 40–50 KB on squashfs |
| Native module | ~68 KB stripped | I/O + rmnet netlink helper |
| Processes | 1 daemon + 3 per context (shell monitor) | reducible to 2 |
| External spawns at runtime | 0 | only usb-repower/reboot in recovery |

## 2. Layering

```
 native (C):   wwand_io.so       — message-oriented cdc-wdm/tty I/O
                                   (protocol-agnostic), rmnet netlink helper
 codec:        qmux.uc, tlv.uc, schema/*.uc      — QMI-specific, declarative
 session:      transport.uc (hub/routing), client.uc — correlation, indications
 statemachine: modem.uc, context.uc, sim.uc      — QMI flow logic
 system:       netlink.uc (datapath), recovery.uc, atcmd.uc (+atport)
 integration:  daemon.uc (registry/policy), config.uc (+compat), ubus.uc, main.uc
 shell:        wwand-proto.sh (netifd shim), context monitor, init, hotplug
```

Design principles, all validated in the field:

- **Effect injection everywhere** (`fx`, `transport_open`, `deps`): the whole
  logic runs host-side against mocks — ~390 checks; every field bug becomes
  a scenario in the suite.
- **Declarative message schemas** (field tables verified against libqmi's
  JSON definitions) instead of generated code.
- **All state per modem/context instance** — multi-modem is a requirement,
  not an afterthought. Logs are prefixed accordingly.
- One process, one uloop, indication-driven; timers only where indications
  don't exist (packet stats, registration guard, settle delays).
- **Never trust modem echoes blindly.** A v5 aggregation request answered
  with "aggregation disabled, size 0" once produced a 4-byte URB
  configuration and a dwc3/swiotlb storm. The WDA negotiation now
  renegotiates on rejection and never adopts zeroed values.
- sysfs attributes differ per kernel (e.g. `rx_urb_size` is a vendor patch;
  mainline usbnet derives the URB size from the parent MTU) — every
  attribute write distinguishes "absent on this kernel" from "write failed".

## 3. Selected mechanisms

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

### netifd coupling (monitor, renew, live updates)

Teardown is event-driven: the proto shim parks a single blocking
`context_wait` ubus call per interface (the daemon holds the reply open until
the context drops), so netifd tears down and retries without a polling
watchdog or an `ubus listen` helper.

Setting changes are applied **in place**. The shim declares a renew handler
(`proto_qmi_renew`) that re-reads `context_settings` (read-only) and re-sends
the netifd update with `keep=1`; netifd diffs it against the live config and
applies only the delta — no teardown. The daemon triggers this itself: while
connected it re-queries `GET_CURRENT_SETTINGS` on serving-system changes (plus
a slow safety poll), and on a real diff emits `settings`, which the daemon maps
to `network.interface renew`. So a changed v6 prefix / DNS / MTU updates the
interface without a reconnect.

A further step was considered and ruled out: driving the mux child's carrier so
netifd's own link tracking would handle teardown/re-setup with zero helper
processes. rmnet/qmimux children do not implement `ndo_change_carrier`
(`ip link set wwan0mN carrier off` → "RTNETLINK answers: Not supported" on the
RG650E), and netifd derives link state from `IFF_LOWER_UP`, not operstate, so
the carrier cannot be toggled per context. The `context_wait` monitor above
stays the teardown mechanism.

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
table itself, netifd is free to enslave the mux child (e.g. `wwan0m1`) to a
VRF master and place its routes in the VRF table. A regression test
(`test_datapath`, "vrf: datapath performs no direct addressing/routing")
fences this invariant: any future `ip route` / `ip addr` / `ip rule` in the
datapath fails the suite. Deeper netifd integrations (runtime `notify_proto`
updates, carrier-driven teardown, renew) must keep addressing in netifd to
preserve this.

### Recovery ladder

Failed connection cycles climb: attempt 8 → operating-mode low-power/online
cycle, 16 → modem offline/reset, 24 → usb-repower, > `failreboot` → system
reboot. QMI request errors have a separate ceiling (25 → reboot). Counters
persist in tmpfs across daemon restarts and are intentionally cleared by
reboot. A zero-rx watchdog (packet stats delta) triggers usb-repower.

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

1. `modem.uc` (~900 lines) should split: telemetry + LOC into
   `telemetry.uc`, WDA negotiation into its own module.
2. A ~25-line `series()` helper would flatten the deeper callback chains
   (`_read_info`, sim flows).
3. Error objects are ad hoc; an `errors.uc` with constants and a QMI
   error-code name table would improve logs and grep-ability.
4. The shell context monitor costs 3 processes per context (sh + pipeline
   subshell + `ubus listen`); the subshell can be eliminated.
5. Recovery persistence writes on every counter change; a dirty-flag with a
   1 s timer would throttle failure storms (tmpfs, so hygiene only).

## 5. MBIM integration plan (next milestone)

MBIM is, like QMI, a binary message protocol over `/dev/cdc-wdmX` (driver
`cdc_mbim`) — **the native I/O layer and the hub stay unchanged**.
Differences: UUID-addressed services instead of QMUX service ids, UTF-16LE
strings with offset/length pairs, message fragmentation, sessions instead of
mux ids, datapath via cdc_ncm (session ↔ VLAN mapping).

New/changed modules:

```
 codec/mbim.uc              framing (OPEN/CLOSE/COMMAND/INDICATE), txn ids,
                            fragments, field codec (u32le, uuid, utf16, offsets)
 codec/mbim-schema/basic_connect.uc
                            DEVICE_CAPS, SUBSCRIBER_READY, PIN, REGISTER_STATE,
                            PACKET_SERVICE, SIGNAL_STATE, CONNECT, IP_CONFIGURATION
 mbim_client.uc             pending map + timeouts + indication dispatch
 modem_mbim.uc              OPEN → caps/ready → PIN → register → attach → READY
 context_mbim.uc            CONNECT(session) → IP_CONFIGURATION → settings
 netlink.uc                 + 'mbim' backend: session links as VLANs (native
                            rtnl), NCM buffer tuning via cdc_ncm rx_max/tx_max
 discovery.uc               driver detection qmi_wwan|cdc_mbim → protocol
 daemon.uc                  modem/context factory by protocol
 config.uc                  modem option protocol 'auto|qmi|mbim'
```

The key contract: **contexts produce an identical `settings` object**
(`{ipv4{addr,prefix,gateway,dns[]}, ipv6{addr,plen,gateway,dns[]}, mtu}`)
for both protocols — the netifd shim, the ubus API and any UI stay
protocol-neutral. Recovery, the AT engine (port discovery works on USB ids,
independent of the driver), telemetry framing, config and compat are reused.

Estimated effort: ~1,500 lines of ucode plus tests. Expected memory cost:
+200–400 KB per MBIM modem instance; the daemon base stays as is.
Hardware test path: the RG650E can be switched to MBIM via
`AT+QCFG="usbnet"`.

## 6. Roadmap

1. Packaging into the target build system (feed), soak testing (24 h,
   fd/CID leaks), iperf3 throughput comparison of aggregation sizes.
2. MBIM milestone as above.
3. Byte-trace captures from real modems as codec regression fixtures.
4. Cell-lock automation on top of `modem_cells` telemetry; LuCI status page.
