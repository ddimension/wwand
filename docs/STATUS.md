# wwand — current state

_State of 2026-08-31, after v1.6.0 (feed r53; the QMI-surface and device-support
work of 2026-08-30/31 lives in HEAD, not yet released). 50 host suites, all green
(`cd tests && sh run_tests.sh` — it prints the count, which moves too often to
be worth repeating here)._

This file describes **what is true now**. The dated log of how it got here is
`status-archive.md`; beliefs that looked right and were not are in
`gotchas.md`. Keeping them apart is deliberate: a running log with the current
state buried at the top invites reading a months-old entry as present tense.

## What it is

An event-driven **ucode** connection manager for OpenWrt cellular modems.
**Three control backends — QMI, MBIM, NCM** — behind one daemon-neutral
contract. The daemon owns the modem and context lifecycle and drives netifd over
ubus with `no_proto_task=1`; netifd keeps all addressing and routing.

Config lives in `/etc/config/network` (`wwand_modem` / `wwand_sim` / an
`interface` with `proto wwand` / `wwand_globals`). wwand manages **only**
`proto wwand` and coexists with uqmi/umbim/comgt-ncm; handing an interface over
is always user-triggered.

## Shape

| | |
|---|---|
| Packages | `wwand` (base, no backend) + `wwand-qmi` / `-mbim` / `-ncm` / `-mhi` / `-esim`, plus two optional datapath add-ons in the feed |
| Datapath | one plug-in interface (`docs/datapath-interface.md`): built-ins `rmnet`, `qmimux`, `vlan` (MBIM), pseudo-modes `raw_ip` and `ethernet` (802.3, WDA-less QMI stacks); add-ons `rmnet_nss`, `rmnet_nss_mhi` |
| QMAP | negotiated down a ladder v5 → v4 → v1, capped by `option qmap_version` |
| Feed | ddimension/openwrt-repo — `wwand` r49, `luci-app-wwand` r23, `luci-proto-wwand` r11 |
| Upstream | openwrt/packages#30185 (pins v1.6.0), openwrt/luci#8917 |

## Hardware verified (2026-08-30, on r49 + the same day's device-support HEAD)

| Box | Modem / backend | Datapath | Result |
|---|---|---|---|
| MikroTik Chateau 5G R17 (`245`) | RG650E, QMI | `rmnet · QMAP v5` | connected, traffic |
| Zyxel NR7101 (`242`) | RG502Q, QMI | `rmnet · QMAP v5` | connected, 5G-NSA |
| GL.iNet GL-X3000 (`3.93`) | RM520N-GL, MBIM | `vlan` | connected, traffic |
| Cudy LT300 v3 (`3.97`) | SLM770A, NCM | `cdc_ether` | connected, traffic |
| Huasifei WH3000 Pro (sponsor) | FM350-GL, NCM | `rndis_host` | connected, traffic |
| Huasifei WH3000 Pro (sponsor) | E3372H, NCM | `huawei_cdc_ncm` | connected, traffic — AT on the cdc-wdm control channel, IP via CGPADDR (CGCONTRDP/GTDNS absent on stick firmware 21.200), v6 via RA + dhcpv6 subinterface |
| Huasifei WH3000 Pro (sponsor) | E1820, QMI (minimal 2011 stack) | `ethernet` | **E2E verified: CONNECTED + traffic on 2G** (sponsor SIM). No UIM/DSD/WDA; DMS fallback, GET_SIGNAL_STRENGTH signal, 802.3 kept with ARP on (the function is an L2 bridge into the GGSN segment — NOARP broke the traffic path, HW-proven) |

Neither QMI modem accepts QMAP v4; both take v5 and fall back to v1 when asked
for something they decline. The MBIM and NCM paths report no QMAP version at
all, which is correct — QMAP is not on the wire there.

## Multi-SIM: what the hardware here actually is

Measured on 2026-08-30 with the read-only `multisim` summary on `modem_sim_slots`:

| Box | Modem | slots | executors | concurrency | mode | source |
|---|---|---|---|---|---|---|
| Chateau (245) | RG650E, QMI | 2 | ≥1 | — | — | inferred |
| NR7101 (242) | RG502Q, QMI | 2 | ≥1 | — | — | inferred |
| GL-X3000 (93) | RM520N-GL, MBIM | 2 | **1** | **1** | DSSA | **SYS_CAPS, exact** |
| Cudy LT300 (97) | SLM770A, NCM | — | — | — | — | no slot query on AT |

Note the two QMI rows report **no mode at all**, which is the point of the
column. Over QMI the executor count is a count of distinct logical slots in use
— a lower bound — and a lower bound of one rules nothing out: a modem with a
second executor whose other slot is empty looks exactly like this. Only the
MBIM row states a mode, because only there did the modem state the numbers.
(`mode_min` carries what a lower bound *can* support: two logical slots in use
would floor at DSDS. Neither box reaches it.)

**Everything reachable is single-executor** as far as anything here can show.
That is not a gap in the reporting:
the RG650E's own firmware settles it, since Qualcomm's MBIM implementation
(`mbimd`) writes `NumberOfExecutors` and `Concurrency` as literal `1` instead of
asking the modem — decompiled, not inferred.

So **DSSA is the shape wwand supports, and the only shape we can test.** DSDS and
DSDA are understood down to message ids and TLVs (two independent sources: a
vendor IDL tree and the RG650E's own `libqmiservices.so`), but nothing here can
exercise them, and for the NAS half there is no openly licensed carrier of those
ids — so an upstream submission would have to rest on observed behaviour we
cannot produce. Reported rather than implemented, which is why the summary exists
at all: someone holding a dual-executor modem can answer in one command what we
cannot answer for ourselves.

Two things worth knowing if that ever changes. The subscription encoding is **not
uniform**: NAS and WMS use one byte, 0-based; WDS, DMS, QOS and DSD four bytes,
1-based with 0 meaning "default" — a shared codec silently binds the wrong stack.
And DSDA cannot be commanded at all: there is no `SET_MSIM_SUB_MODE`, and
`nas_standby_pref_enum_v01` has no "dual active" member. It is a device property,
reported only.

## Known open

- **DONE (2026-08-30) — the recovery ladder no longer touches hardware on a
  protocol it has never spoken.** Every rung, the reboot included, is gated on
  one answer having arrived in the selected protocol; the permission is sticky,
  persisted, withdrawn on a protocol change, and withdrawn again when
  `option protocol` contradicts the driver (an AT port answers on QMI and MBIM
  modems too, so it cannot prove an NCM pin). `option protocol` itself is parsed
  now — it was documented, advised by the daemon's own error message, and
  silently dropped by `config.uc`.
- **TODO — the QMI surface survey is a map, not a plan.**
  `docs/design/qmi-surface-survey.md` records what the vendor QMI/RIL surface
  has that wwand does not model, ranked by value per line, with each item's
  provenance marked (citable / device-observed / proprietary) because that
  decides whether it can ever be upstreamed. Its top items are DELIVERED — the
  UIM card diagnostics, `UIM_REFRESH_OK`, long APDU, TMD thermal and CAT toolkit
  routing all landed on 2026-08-30/31, and the file marks them as such. What
  remains is unscheduled, and three entries there dissolved on inspection rather
  than being deferred (RF-band changes already arrive by another route, the
  error-rate indication carries no LTE or NR, and the sys-info rate limiter
  throttles an indication wwand never arms).
- **TODO — the cancellation family is mapped but not closed.** Destroying a QMI
  client reports `cancelled` to every pending callback **synchronously**, while
  the hub is still live. Any callback that reads "error" as "carry on" then
  issues its next request on a client mid-destruction and resumes a chain the
  teardown existed to stop. Everything inside the 2026-08-30/31 range is fixed,
  with tests that use the PRODUCTION error shape — the first attempt did not, and
  a guard checking a bare `err.error` never matched a caller that wraps it as
  `{ stage, err }`, with a green load-bearing test agreeing with the guard
  instead of the caller. A whole-tree sweep in review found the rest, all older:
  - `qmi_backend.set_opmode()` hands `cancelled` to its continuation, so the
    recovery cycle, the admin reset and the SIM-reapply radio cycle all carry on.
  - a cancelled `STOP_NETWORK` immediately sends a second `STOP_NETWORK` on the
    dying client (the preserved retry treats every error alike).
  - `netsel_ops`: a cancelled GET falls through to a **permanent modem write**,
    and a cancelled SET is read as "the firmware rejected one LTE TLV" and
    retries the alternate write.
  - `sim.set_pin_lock()` reads a cancellation as "try the next transport" and
    walks UIM → DMS → AT; the APDU probe can cache `_apdu_be = 'none'`.
  - the init chain does not capture `_gen` at all: SYNC, VERSION, ALLOCATE,
    `read_info`, opmode, SIM-slot, unlock, identity, system-preference and
    `config_check` all continue or re-arm timers.
  - telemetry continues across a cancellation and can cache degraded backend
    choices (`_ca_be`, `_dsd_be`) that survive into the retry.

  **This wants one convention, not twenty patches.** The shape that worked here
  is a captured generation plus a `torn_down(err, client)` helper next to the
  forward declarations (a `let` further down is not hoisted in ucode and fails at
  CALL time). Doing it piecemeal is how the last several rounds went, and each
  fix introduced the next hole. Severity is real but the window is narrow — a
  teardown with a request in flight. The worst of the family are writes that
  outlive their modem — a slot switch, an NV profile write, a network-selection
  write; the first two are fixed in this range, the network-selection ones are
  among the open sites above. Raised in review, 2026-08-30.
- **TODO — recovery state has no identity boundary.** The counters, `proto_ok`
  included, are keyed on the modem *id* and persist across daemon restarts
  within a boot (tmpfs). Swap the physical modem behind that id and the
  replacement inherits the arming the previous one earned. There is no sound
  fix without evidence: a modem at that id which never answers is
  indistinguishable from the same modem gone silent, which is precisely the case
  the hardware rungs exist for — so refusing to inherit would disarm the wedged
  modem this feature was built for. The IMEI does not *fully* close the window
  either, since it only arrives after the modem has answered, by which point the
  replacement has earned its own arming anyway — but it is not useless: once a
  replacement IS detected, the inherited attempts/rung/proto-error counters are
  the previous modem's outage and should be reset rather than escalated on. The
  USB **iSerial** is the better lever, because this tree already reads it
  pre-open (`discovery.resolve_modem_device`), so for hardware that exposes a
  stable one the boundary can be closed opportunistically. Recorded because it
  is a real narrowing of the invariant ("a modem at this id answered", not "this
  modem answered"), and because the partial fixes are worth more than the
  absolute framing suggested. Raised in review, 2026-08-30.
- **TODO — nothing catches a mismatched split-package install.** The ucode tree
  ships as a base package plus per-backend ones, and the feed's DEPENDS carry no
  version. A base from one release running backends from another fails the way
  a partial deploy did here on 2026-08-30: HEAD's `modem.uc` against r49's
  `discovery.uc` stalled at `open_at` with **no log line at all**, which cost
  several rounds of suspecting the new code. Worth an exact-version DEPENDS in
  the feed, or a fail-loud internal API version constant checked at start-up —
  the point being that it must be loud, since the silent stall is the whole
  problem. Raised in review, 2026-08-30.
- **DONE (2026-08-31) — the NCM/AT backend accepts a `cdc-wdm` as its AT port.**
  On a `huawei_cdc_ncm` modem the AT channel IS `/dev/cdc-wdm0` (the driver
  registers a cdc-wdm carrying AT alongside its NCM datapath), and wwand only
  resolved ttys, using the wdm as an anchor to find one. Delivered by the
  device-support branch: a cdc-wdm is a char device, not a tty, so it skips
  termios setup and uses the message-oriented path the io module already has.
- **openwrt/packages#30185** is `CHANGES_REQUESTED` on scope, which is a
  maintainer decision, not a defect list — all 34 review threads are resolved.
  The full build/runtime CI has not run on that PR since `8ffb9e3`; only the
  three FormalityCheck jobs report.
- **PCIe/MHI** (`wwand-mhi`) is validated with community testers rather than on
  hardware here.
- **eSIM over MBIM UICC** is wire-verified against libmbim 1.32 + lpac but not
  end-to-end: no eUICC-capable MBIM modem is on hand (the RG650E rejects
  MBIM_OPEN, the EG06 card has no eUICC).
- **The E1820-class QMI support is now E2E-verified** (2026-08-31, sponsor box
  with a Globe SIM): CONNECTED on 2G and traffic through the 802.3 function.
  Two HW-forced corrections landed on the way: the `ethernet` datapath must
  keep **ARP on** (the function is an L2 bridge into the GGSN segment; NOARP
  left the host with a zero dest MAC and no traffic — the mwan3 track ping
  through the modem was the proof), and the client table is tiny — failed
  attempts leaked slots (teardown destroyed clients without CTL RELEASE_CID),
  so teardown now releases while the transport is up and ClientIdsExhausted
  triggers an AT+CFUN stack reset instead of a retry spiral. The DMS fallback
  caveat stays — without UIM an empty slot surfaces as registration timeout,
  not SIM_BLOCKED (documented in `modem_quirks.uc`).
- **v1 (plain QMAP) end-to-end on the RG650E** did not carry traffic in a
  deliberate downgrade test even through the create path, while v5 does. Not
  chased: no configuration here runs v1.

## Before a release

1. `cd tests && sh run_tests.sh` — all green.
2. `tools/check-packaging.py --makefile ../repository/wwand/Makefile` — and again
   with `--makefile <pkgs>/net/wwand/Makefile --tarball <release>.tar.gz`.
3. Tag, pinning the **commit** (`git rev-parse vX.Y.Z^{commit}`), never the tag
   object.
4. Feed: bump `PKG_RELEASE`/`PKG_SOURCE_VERSION`/`_DATE`, then
   `scripts/update-hashes.sh` — and verify the Makefile actually changed.
5. One feed push, then wait: the feed CI is `cancel-in-progress`.

The traps in steps 3-5 have each fired at least once; `gotchas.md` says how.
