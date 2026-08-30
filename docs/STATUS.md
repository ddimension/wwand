# wwand — current state

_State of 2026-08-30, release **v1.6.0**. 50 host suites / 3268 checks, all
green (`cd tests && sh run_tests.sh`)._

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
| Datapath | one plug-in interface (`docs/datapath-interface.md`): built-ins `rmnet`, `qmimux`, `vlan` (MBIM), fallback `raw_ip`; add-ons `rmnet_nss`, `rmnet_nss_mhi` |
| QMAP | negotiated down a ladder v5 → v4 → v1, capped by `option qmap_version` |
| Feed | ddimension/openwrt-repo — `wwand` r49, `luci-app-wwand` r23, `luci-proto-wwand` r11 |
| Upstream | openwrt/packages#30185 (pins v1.6.0), openwrt/luci#8917 |

## Hardware verified (2026-08-30, on r49)

| Box | Modem / backend | Datapath | Result |
|---|---|---|---|
| MikroTik Chateau 5G R17 (`245`) | RG650E, QMI | `rmnet · QMAP v5` | connected, traffic |
| Zyxel NR7101 (`242`) | RG502Q, QMI | `rmnet · QMAP v5` | connected, 5G-NSA |
| GL.iNet GL-X3000 (`3.93`) | RM520N-GL, MBIM | `vlan` | connected, traffic |
| Cudy LT300 v3 (`3.97`) | SLM770A, NCM | `cdc_ether` | connected, traffic |

Neither QMI modem accepts QMAP v4; both take v5 and fall back to v1 when asked
for something they decline. The MBIM and NCM paths report no QMAP version at
all, which is correct — QMAP is not on the wire there.

## Multi-SIM: what the hardware here actually is

Measured on 2026-08-30 with the read-only `multisim` summary on `modem_sim_slots`:

| Box | Modem | slots | executors | concurrency | mode | source |
|---|---|---|---|---|---|---|
| Chateau (245) | RG650E, QMI | 2 | 1 | — | DSSA | inferred |
| NR7101 (242) | RG502Q, QMI | 2 | 1 | — | DSSA | inferred |
| GL-X3000 (93) | RM520N-GL, MBIM | 2 | **1** | **1** | DSSA | **SYS_CAPS, exact** |
| Cudy LT300 (97) | SLM770A, NCM | — | — | — | — | no slot query on AT |

**Everything reachable is single-executor.** That is not a gap in the reporting:
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

- **TODO — the recovery ladder must not touch hardware on a protocol it has
  never spoken.** `recovery.uc:176` escalates to `usb_repower` once the
  protocol-error counter passes its limit. That rung exists for a real case (an
  NR7101 can wedge so that only a power cycle clears it, and without the rung
  the router reboot-loops), but it assumes protocol errors mean the modem
  stopped answering. They can equally mean wwand picked the wrong control
  protocol and is talking QMI at a device that does not speak it — reported from
  the field on 2026-08-30, where a misdetected modem was power-cycled for it.
  The missing discriminator is whether **one** successful exchange has ever
  completed on this channel with the currently selected protocol; if none has,
  the errors are evidence about our detection, not about the hardware, and no
  hardware rung may fire. Gate all of them on that, not just the repower.
  Related and awaiting the reporter's driver output: `discovery.uc:878` falls
  back to `'qmi'` when `protocol_of()` cannot identify the driver (same fallback
  at `daemon.uc:965` and `:1035`) — a guess where "unknown" is the honest answer,
  and the reason the misdetection happened at all.
- **TODO — the NCM/AT backend must accept a `cdc-wdm` as its AT port.** Stock
  `comgt-ncm` sends AT straight to `option device`, whatever it is:
  `gcom -d "$device"`, with an explicit usbmisc branch
  (`package/network/utils/comgt/files/ncm.sh:79`). On a `huawei_cdc_ncm` modem
  that device IS `/dev/cdc-wdm0` — the driver registers a cdc-wdm carrying AT
  alongside its NCM datapath. wwand instead resolves a **tty** and uses the
  cdc-wdm only as an anchor to find one on the same USB device
  (`atcmd.uc:209-240`), so a modem whose AT lives on the wdm node has no AT
  channel at all even though its protocol is now identified correctly. Field
  case (2026-08-30) also has `ttyUSB0`/`ttyUSB1`, so it may work there by
  accident; that is not a fix. The native io module already does
  message-oriented cdc-wdm I/O for QMI/MBIM, so the port layer is the piece that
  needs to accept it.
- **openwrt/packages#30185** is `CHANGES_REQUESTED` on scope, which is a
  maintainer decision, not a defect list — all 34 review threads are resolved.
  The full build/runtime CI has not run on that PR since `8ffb9e3`; only the
  three FormalityCheck jobs report.
- **PCIe/MHI** (`wwand-mhi`) is validated with community testers rather than on
  hardware here.
- **eSIM over MBIM UICC** is wire-verified against libmbim 1.32 + lpac but not
  end-to-end: no eUICC-capable MBIM modem is on hand (the RG650E rejects
  MBIM_OPEN, the EG06 card has no eUICC).
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
