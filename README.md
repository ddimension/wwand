# wwand — lean WWAN connection manager daemon for OpenWrt

wwand is an event-driven connection manager for cellular modems on OpenWrt,
written in [ucode](https://github.com/jow-/ucode). It talks QMI natively over
`/dev/cdc-wdmX` — no uqmi, qmicli, libqmi or glib — and drives netifd directly
(the daemon owns the context lifecycle; there is no per-interface monitor
process). MBIM support shares the same foundation (see `docs/architecture.md`).

Beyond connectivity it manages the **SIM** — PIN, multi-slot switching, and
**eSIM/eUICC**: native ES10c profile management plus **SM-DP+ provisioning**
(profile download) driven by a bundled lpac, with the HTTPS running on the
router over the existing WAN (no dedicated provisioning APN). See
[eSIM management & provisioning](docs/reference.md#esim-management--provisioning).

It replaces a grown bash-based connection manager (`qmi-advanced`) whose
field-proven behaviors, quirks and recovery strategies were ported
deliberately, while its known bugs were left behind.

**Highlights**

- **Multiple modems and multiple parallel PDP contexts** per modem via QMAP
  multiplexing (rmnet pass-through and qmimux backends, automatic selection,
  automatic mux channel assignment)
- **Tiny footprint:** ~3 MB RSS for the daemon, no processes spawned during
  normal operation, one uloop, indication-driven (no polling)
- IPv4/IPv6/dual-stack per context; IPv4 as /32 point-to-point (optional
  pushed prefix), IPv6 with RFC 7278 prefix delegation
- Recovery escalation ladder with persisted counters:
  retry → operating-mode cycle → modem reset → usb-repower → reboot
- **Attach profile programmed from config before registration**, so the modem's
  autonomous attach uses the right APN/IP family (avoids the EMM-cause-33
  IPv4-only/wrong-APN attach reject)
- SIM: PIN via the UIM service (legacy DMS fallback, retry guards), multi-slot
  switching, PIN-lock enable/disable
- **eSIM (optional `wwand-esim`):** native ES10c profile management
  (list/enable/disable/delete/EID) plus SM-DP+ **provisioning/download** via
  bundled lpac — ES9+ HTTPS runs on the router over the existing WAN, no
  dedicated provisioning APN
- **Registration diagnostics**: EMM reject cause + limited-service flag
  (QMI + AT+CEER) surfaced on ubus and in the log; robust handling of empty /
  truncated / sentinel QMI answers
- AT side channel: port discovery from a table generated out of
  ModemManager's udev rules, model-specific init quirks, Quectel cell
  locking (4G anchor / 5G SA)
- Telemetry: periodic cell environment (serving cell + neighbours, LTE and
  NR5G), signal, operator and data-system mode (LTE/NSA/SA) — logged and
  queryable over ubus
- QMI LOC positioning support
- Compatibility layer: existing old-style `proto qmi` interface
  configurations keep working unchanged; a migration helper generates the
  native configuration

## Repository layout

This repository holds the wwand sources; the OpenWrt package definitions
live in the [openwrt-repo](https://github.com/ddimension/openwrt-repo)
feed, which builds the `wwand`, `ucode-mod-wwand-io` and `wwand-esim`
binary packages from this tree.

| Path | Description |
|---|---|
| `src-ucode/` | The daemon (ucode): codec, session, state machines, netifd/ubus integration |
| `io/` | Native ucode C module — message-oriented cdc-wdm/tty I/O, rmnet netlink helper, non-blocking `spawn()` |
| `files/` | netifd proto shim, init script, default config, hotplug, migration helper |
| `tests/` | Host-side test suites (`sh run_tests.sh`, no hardware needed) |
| `docs/reference.md` | Full configuration and ubus API reference |
| `docs/architecture.md` | Architecture, design decisions, measurements, MBIM integration plan |

The LuCI packages live in their own repositories:
[luci-proto-wwand](https://github.com/ddimension/luci-proto-wwand) and
[luci-app-wwand](https://github.com/ddimension/luci-app-wwand); their
package definitions (and the `wwand-lpac` package entirely) are also part
of the openwrt-repo feed.

## Quick start

```
# /etc/config/wwand
config modem 'm0'
	option device '/dev/cdc-wdm0'
	option modes 'lte,nr5g'

config context 'wan_ctx'
	option modem 'm0'
	option mux_id '1'
	option apn 'internet'
	option pdp_type 'ipv4v6'

# /etc/config/network
config interface 'wan'
	option proto 'qmi'
	option context 'wan_ctx'
```

`ifup wan` — that's it. See `docs/reference.md` for the complete configuration
reference, the ubus API and the compat/migration path for old configurations.

## Status

Production-tested on a MikroTik Chateau 5G R17 ax (Quectel RG650E-EU) and
further Quectel modems (RG502Q, EG06). ~480 host-side unit checks run without
hardware.

## License

GPL-2.0-only. The AT port table is generated from ModemManager's udev rules
(GPL-2.0-or-later); see the file header for attribution.
