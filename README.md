# wwand — lean WWAN connection manager daemon for OpenWrt

wwand is an event-driven connection manager for cellular modems on OpenWrt,
written in [ucode](https://github.com/jow-/ucode). It talks QMI natively over
`/dev/cdc-wdmX` — no uqmi, qmicli, libqmi or glib — and drives netifd directly
(the daemon owns the context lifecycle; there is no per-interface monitor
process). MBIM support shares the same foundation (see `docs/architecture.md`).

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
  switching, PIN-lock enable/disable, and optional eSIM/LPA management
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

| Path | Description |
|---|---|
| `wwand/` | OpenWrt package: the daemon (ucode), netifd shim, init, migration helper, tests. See `wwand/README.md` for the full configuration and ubus reference. |
| `ucode-mod-wwand-io/` | OpenWrt package: small native ucode module — message-oriented cdc-wdm/tty I/O, an rmnet netlink helper, and a non-blocking `spawn()` |
| `luci-proto-wwand/` | LuCI proto handler (registers `proto 'qmi'`, replaces stock luci-proto-qmi) |
| `luci-app-wwand/` | LuCI Status → Modem page (signal, cells, connections) and the settings editor |
| `docs/architecture.md` | Architecture, design decisions, measurements, MBIM integration plan |

Use this repository as an OpenWrt feed, or copy the two package directories
into an existing feed.

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

`ifup wan` — that's it. See `wwand/README.md` for the complete configuration
reference, the ubus API and the compat/migration path for old configurations.

## Status

Production-tested on a MikroTik Chateau 5G R17 ax (Quectel RG650E-EU) and
further Quectel modems (RG502Q, EG06). ~480 host-side unit checks run without
hardware.

## License

GPL-2.0-only. The AT port table is generated from ModemManager's udev rules
(GPL-2.0-or-later); see the file header for attribution.
