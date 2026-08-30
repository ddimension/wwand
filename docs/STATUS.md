# wwand — current state

_State of 2026-08-30, after v1.6.0 (feed r49; the device-support work of this
date lives in HEAD, not yet released). 50 host suites / 3400 checks, all green
(`cd tests && sh run_tests.sh`)._

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
| Huasifei WH3000 Pro (sponsor) | E1820, QMI (minimal 2011 stack) | `ethernet` | READY without SIM — no UIM/DSD/WDA; DMS fallback, GET_SIGNAL_STRENGTH signal, 802.3 kept + NOARP; E2E connect open (empty SIM slot) |

Neither QMI modem accepts QMAP v4; both take v5 and fall back to v1 when asked
for something they decline. The MBIM and NCM paths report no QMAP version at
all, which is correct — QMAP is not on the wire there.

## Known open

- **openwrt/packages#30185** is `CHANGES_REQUESTED` on scope, which is a
  maintainer decision, not a defect list — all 34 review threads are resolved.
  The full build/runtime CI has not run on that PR since `8ffb9e3`; only the
  three FormalityCheck jobs report.
- **PCIe/MHI** (`wwand-mhi`) is validated with community testers rather than on
  hardware here.
- **eSIM over MBIM UICC** is wire-verified against libmbim 1.32 + lpac but not
  end-to-end: no eUICC-capable MBIM modem is on hand (the RG650E rejects
  MBIM_OPEN, the EG06 card has no eUICC).
- **The E1820-class QMI support is not E2E-verified**: the sponsor stick's SIM
  slot is empty, so START_NETWORK/GET_CURRENT_SETTINGS on real firmware (and
  the NOARP + /32 device-route traffic path) await a SIM. Also note the DMS
  fallback caveat — without UIM an empty slot surfaces as registration
  timeout, not SIM_BLOCKED (documented in `modem_quirks.uc`).
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
