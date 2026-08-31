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
| Initial EPS/attach bearer | distinct attach APN + creds (`init_*`) | same: `init_apn`/`init_auth`/`init_user`/`init_pass` on `wwand_modem`, else the connection APN | parity |
| Roaming gate | `allow_roaming` | — | **MISSING** (MED–HIGH for fixed/M2M) |
| Allowed vs preferred RAT | both | allowed set only | near-parity (preferred tier missing, LOW) |
| PLMN pinning | register-in-operator | mcc/mnc + idempotent netsel + scan | **wwand better** |
| IP type / MTU | iptype | pdp_type + pushed-MTU/prefix knobs | wwand better (MTU) |
| Multi-PDN on one modem | one bearer/iface (OpenWrt handler) | N interfaces → QMAP mux channels | **wwand better** |
| QMI/MBIM/AT | all three | all three + QMI-over-MBIM passthrough | parity |
| PPP fallback | yes | no (mode-switch to usbnet instead) | missing by design (LOW) |
| Firmware update | fwupd | — | missing (LOW–MED) |
| Carrier config (PDC/MBN) | yes | QMI PDC list/get/set (`modem_carrier_config`) + the Quectel quirk | parity (wwand selects among shipped blobs; deliberately never writes or deletes one) |
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
| Low-power / thermal | `lowpower` on ifdown; temp | `option lowpower` parks the radio on the last context-down and an ifup wakes it; QMI TMD mitigation state + temp | parity |
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
4. ~~**Distinct attach-bearer credentials**~~ — **SHIPPED.** `init_apn`,
   `init_auth`, `init_user`, `init_pass` on `wwand_modem` feed the attach-profile
   write instead of reusing the context APN, closing the separate IMS/attach-APN
   case. `init_user`/`init_pass` without `init_apn` is warned about at parse
   time: the attach profile then keeps its own APN and the credentials would
   apply to that one.
5. **Metered-SIM usage accounting + quota action** — MED/med. Persist the
   `context.uc` stats counters across reconnects; `option data_limit` emits an
   event / downs the context at threshold.
6. ~~**QMI-native carrier config / PDC (MBN select)**~~ — **SHIPPED.**
   `codec/schema/pdc.uc` + `carrier_config.uc` + `modem_carrier_config` on ubus,
   with a settings-page panel. Generalises the Quectel-only QMBNCFG quirk to any
   Qualcomm modem exposing PDC. Read-mostly by design: wwand lists, reads and
   selects among the blobs the vendor shipped and models neither LOAD nor DELETE
   — a wrong write there is not a misconfiguration but a brick. A selection takes
   effect on the next modem reset and is reported as `pending` until then.
7. ~~**`lowpower`-on-ifdown power state**~~ — **SHIPPED.** `option lowpower`
   parks the radio once no context of the modem wants to be up, and an `ifup`
   wakes it first. Parking is a state the modem remembers, which both halves need:
   the registration supervisor lets the resulting deregistration pass instead of
   chasing it into the recovery ladder, and the bring-up knows to switch the
   radio back on rather than dialling a modem that cannot register. Battery/solar.
8. ~~**Thin `wwand` CLI**~~ — **SHIPPED** as `wwandctl` (`src-ucode/wwandctl.uc`,
   installed to `/usr/bin/wwandctl`): an `mmcli`-like verb surface over the ubus
   object, with `--json` for scripting.
9. **Preferred-RAT tier + signal delta thresholds** — LOW/low. Extend
   `modem_set_settings` with a preferred-RAT ranking + QMI NAS signal-threshold
   config (report on delta, not just interval).
10. **AGPS/SUPL + NMEA stream** — LOW/med. SUPL-server config on the QMI LOC
    session; optionally emit an NMEA stream (today wwand only yields the port).

Still open, in the order above: **1** roaming gate, **3** USSD, **5** metered
usage accounting + quota action, **9** preferred-RAT tier + signal delta
thresholds, **10** AGPS/SUPL + NMEA. Five of the ten have shipped (2, 4, 6, 7,
8); the list keeps its original numbering so earlier references to "item 6" still
find the same thing. Last reviewed against the tree on **2026-08-31**.

Deliberately excluded as low-value-for-effort on routers: PPP fallback, voice
calls, firmware/fwupd, suspend/resume.

## wwand advantages (for the upstream dossier)

- **Full eSIM LPA built in** — native ES10c profile enable/disable/delete +
  SM-DP+ download (bundled lpac, over the existing WAN). MM cannot download eSIM
  profiles at all. Strongest single differentiator.
- **Router-grade recovery** — recovery ladder with board-GPIO modem reset /
  board power-cycle, zero-rx watchdog, protocol-error ceiling, persistent
  counters, provider-purge self-heal. MM has none of this. The ladder is also
  *gated*: no rung touches hardware until the modem's control channel has
  answered at least once (a sticky `proto_ok`), so a wrong `option protocol` or
  a driver that never bound produces a diagnosis in the log instead of a
  power-cycle loop on hardware that was never the problem.
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
package, not a line-by-line 1.24 source read; wwand's USSD and voice absences
were verified directly in source (SMS send was on that list until it shipped)._
