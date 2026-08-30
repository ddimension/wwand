<!-- Upstream-submission material: this note argues wwand's position next to
     ModemManager and drives an "adopt from MM" backlog. It is contributor
     documentation, not user documentation — see ../README.md for the map. -->

# wwand vs ModemManager — feature/architecture comparison & backlog

ModemManager (freedesktop, v1.24) is the incumbent full-featured WWAN daemon and
the OpenWrt-packages precedent for a large external cellular stack coexisting
with uqmi/umbim. This note compares it to wwand dimension by dimension, to (a)
drive a router-relevant "adopt from MM" backlog and (b) state wwand's advantages
for the upstream discussion.

Framing: MM is a ~15-year glibc/GLib/DBus daemon (15–30 MB RSS, 50+ compiled
vendor plugins, fwupd integration); wwand is a ~3 MB single-ucode daemon
purpose-built for OpenWrt routers. Several "gaps" below are deliberate scope
choices, flagged as such.

## Verdicts by dimension

| Dimension | MM | wwand | Verdict |
|---|---|---|---|
| Initial EPS/attach bearer | distinct attach APN + creds (`init_*`) | attach profile from the connection APN/pdp_type | near-parity; can't set a *separate* attach APN+auth |
| Roaming gate | `allow_roaming` | — | **MISSING** (MED–HIGH for fixed/M2M) |
| Allowed vs preferred RAT | both | allowed set only | near-parity (preferred tier missing, LOW) |
| PLMN pinning | register-in-operator | mcc/mnc + idempotent netsel + scan | **wwand better** |
| IP type / MTU | iptype | pdp_type + pushed-MTU/prefix knobs | wwand better (MTU) |
| Multi-PDN on one modem | one bearer/iface (OpenWrt handler) | N interfaces → QMAP mux channels | **wwand better** |
| QMI/MBIM/AT | all three | all three + QMI-over-MBIM passthrough | parity |
| PPP fallback | yes | no (mode-switch to usbnet instead) | missing by design (LOW) |
| Firmware update | fwupd | — | missing (LOW–MED) |
| Carrier config (PDC/MBN) | yes | Quectel MBN auto-select quirk only | **MISSING (partial)** (MED) |
| FCC unlock | per-vendor scripts | native (DMS/Foxconn/MBIM) | parity (MM wider vendor list) |
| SIM PIN/PUK | yes | PIN + PUK-avoidance guard | parity+ |
| Multi-SIM / per-SIM cfg | slots | slots + per-ICCID `wwand_sim` overrides | **wwand better** |
| eSIM download / LPA | **no profile download** (reports EID only) | **full LPA**: ES10c enable/disable/delete + SM-DP+ via lpac | **wwand better (headline)** |
| Signal / cell / DSD | Signal + GetCellInfo | signal + cells + DSD NSA/SA + CA + reject-cause + temp | parity/wwand better |
| Location GPS/NMEA/AGPS | GPS raw + NMEA + AGPS/SUPL | QMI LOC fix; yields port to gpsd | near-parity (no NMEA producer / AGPS) |
| SMS | send + receive | send + receive (PDU encoder; QMI WMS / MBIM / `AT+CMGS`) | parity |
| USSD | yes | — | **MISSING** (MED, prepaid balance) |
| Voice | yes | — | missing by design (LOW) |
| Recovery / robustness | reconnect; no HW reset | recovery ladder + board GPIO reset + zero-rx watchdog + persistent counters | **wwand better (decisive for routers)** |
| Non-destructive restart | bounces sessions | WAN + traffic survive, session adopted | **wwand better** |
| Control API | rich DBus (mmcli) | ubus (~30 methods) + events + `wwandctl` | parity for router use |
| netifd integration | PPP-oriented, one bearer | no-proto-task, VRF-safe, in-place renew, idempotent reload | **wwand better** |
| Zero-config | manual APN typical | autosetup + ICCID→APN fill | **wwand better** |
| Low-power / thermal | `lowpower` on ifdown; temp | op-mode low-power internal; temp read | near-parity (no user lowpower knob) |
| Data accounting | bearer Stats | live counters (zero-rx watchdog) | near-parity (no persisted quota) |
| Extensibility | compiled per-vendor plugins | pattern-gated quirk tables + runtime probing | wwand better for the niche (no recompile) |
| Distro reach / i18n | ubiquitous | OpenWrt-only, not yet upstream | MM better (the maturity gap) |

## Top-10 "adopt from MM" backlog (router-relevant, prioritized)

1. **Roaming gate** (`option allow_roaming`) — HIGH/low. Gate `context_up` on the
   serving-system roaming flag (or set QMI NAS roaming-preference home-only).
   Note the option name is already *recognised* on the migration path — it is in
   `MIGRATE_STRIP_IFACE_MM` (`config.uc`), i.e. stripped from a migrated
   `proto modemmanager` interface because wwand has no home for it yet.
2. ~~**SMS send**~~ — **SHIPPED.** PDU encoder + QMI WMS RawSend / MBIM /
   `AT+CMGS`, `modem_sms_send` on ubus, LuCI inbox on the Modem Tools page.
3. **USSD** — MED/med. `modem_ussd` → QMI NAS/VS or `AT+CUSD`; reuse the GSM-7
   codec. Prepaid balance/top-up is a real cellular-router use case.
4. **Distinct attach-bearer credentials** (`init_apn`/`init_auth`/`init_user`/
   `init_pass` on `wwand_modem`) — MED/low. Feed the attach-profile write instead
   of reusing the context APN. Closes the separate IMS/attach-APN case.
5. **Metered-SIM usage accounting + quota action** — MED/med. Persist the
   `context.uc` stats counters across reconnects; `option data_limit` emits an
   event / downs the context at threshold.
6. **QMI-native carrier config / PDC (MBN select)** — MED/med. New
   `codec/schema/pdc.uc` (list/get/set) + `modem_carrier_config`; generalises the
   Quectel-only QMBNCFG quirk. Already a roadmap item.
7. **`lowpower`-on-ifdown power state** — MED/low. `option lowpower` sets DMS
   op-mode low-power on context-down (uses existing `set_opmode`). Battery/solar.
8. ~~**Thin `wwand` CLI**~~ — **SHIPPED** as `wwandctl` (`src-ucode/wwandctl.uc`,
   installed to `/usr/bin/wwandctl`): an `mmcli`-like verb surface over the ubus
   object, with `--json` for scripting.
9. **Preferred-RAT tier + signal delta thresholds** — LOW/low. Extend
   `modem_set_settings` with a preferred-RAT ranking + QMI NAS signal-threshold
   config (report on delta, not just interval).
10. **AGPS/SUPL + NMEA stream** — LOW/med. SUPL-server config on the QMI LOC
    session; optionally emit an NMEA stream (today wwand only yields the port).

Deliberately excluded as low-value-for-effort on routers: PPP fallback, voice
calls, firmware/fwupd, suspend/resume.

## wwand advantages (for the upstream dossier)

- **Full eSIM LPA built in** — native ES10c profile enable/disable/delete +
  SM-DP+ download (bundled lpac, over the existing WAN). MM cannot download eSIM
  profiles at all. Strongest single differentiator.
- **Router-grade recovery** — recovery ladder with board-GPIO modem reset / USB
  power-cycle, zero-rx watchdog, protocol-error ceiling, persistent counters,
  provider-purge self-heal. MM has none of this.
- **VRF/policy-routing-safe netifd integration** — daemon touches only the link
  layer; all addressing/routing in netifd; regression-fenced (`test_datapath`).
- **Non-destructive restart + in-place renew** — WAN and live traffic survive a
  daemon restart; transient loss preserves IPv6-PD/VRF routes (no flush).
- **Idempotent, scoped multi-modem reload** — editing one interface's APN
  reconnects only that context; siblings untouched (HW-verified dual-modem).
- **First-class multi-PDN QMAP mux** — several netifd interfaces per modem, each
  a stable `wwandN` L3 device; MM-on-OpenWrt is effectively one bearer/iface.
- **Zero-config autosetup** + **per-ICCID SIM config** + **PUK-avoidance PIN
  guard**.
- **Footprint** — ~2.9 MB RSS, one process, no per-context spawns; MM+libqmi+glib
  is 15–30 MB.
- **Testability** — effect-injection host suites (count in
  [STATUS.md](../STATUS.md)), schemas verified
  against libqmi-1.38 / libmbim-1.32; the AT-port table is generated from MM's
  own udev rules (`tools/gen-atport-table.py`).

_Caveat: MM-side feature claims are from its published API surface + the OpenWrt
package, not a line-by-line 1.24 source read; wwand's SMS-send/USSD/voice
absences were verified directly in source._
