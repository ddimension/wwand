Status update + maturity dossier (for @BKPepe and the WWAN maintainers)

Since the review I've made the load-bearing change and hardened the tree. A concise summary of where this stands against the concerns raised.

## 1. It no longer replaces the stock stack — coexistence, opt-in per interface

The single biggest objection ("a second implementation that replaces uqmi/umbim/comgt-ncm") is gone:

- **All `CONFLICTS` removed.** The packages install *alongside* uqmi/umbim/comgt-ncm.
- wwand manages **only `proto wwand`** interfaces. It does not touch existing `proto qmi`/`mbim`/`ncm`.
- wwand registers **only `proto wwand`** and never the `qmi` alias, and it never adopts a bare `proto qmi` interface. There is no switch that changes this: the former global `option takeover` was removed, because netifd settles two handlers claiming the same proto name by load order and no package can control that.
- Moving one interface to wwand is **user-triggered** (a "Migratable interfaces" list in the LuCI modem page; converts it in place to `proto wwand`).

So nothing is replaced unless the operator explicitly opts in, per interface.

## 2. Precedent: this is structurally the ModemManager position

`net/modemmanager` already lives in this feed: a large external WWAN daemon, additive, with its own `proto modemmanager` (`net/modemmanager/files/lib/netifd/proto/modemmanager.sh`), co-maintained by core people. After the coexistence rework wwand is positioned identically — an optional `proto wwand` the user selects, next to the stock handlers. The feed is exactly the place for "optional packages the user selects if they want them."

## 3. The AI-generated protocol code — what independent verification exists

For the low-level QMI/MBIM codec the concern is fair, so the verification is mechanical and reproducible, not "trust me":

- **Every QMI message id + TLV id is cross-checked against libqmi 1.38's `data/qmi-service-*.json`** (and libmbim for MBIM). Wrong tags silently decode garbage, so each decoder ships a **hand-built-wire-buffer test** that pins the exact bytes (e.g. the packet-drop 0x1D/0x1E fix, the NAS preferred-networks 0x0026/0x0027 arrays, the UIM 0x0022 write). Where libqmi has no binding (UIM Write Transparent) it's marked as spec-derived and HW-validated.
- **Host test suite: 40 suites / 2018 checks**, run in CI (below) and before every commit — mockhub over the *real* codec plus a private ubusd for the daemon integration test.
- **CI**: a GitHub workflow builds the host ucode + libubox/ubus and runs the suite + shellcheck on every push.

## 4. Hardware / real-world coverage

Not a lab-only stack. Running on production hardware here across all three control protocols and two CPU arches (aarch64 + mipsel):

| Box | Modem | Backend |
|---|---|---|
| MikroTik Chateau 5G (ipq60xx, aarch64) | Quectel RG650E-EU | QMI |
| " (2nd modem) | Huawei E392 | QMI |
| Zyxel LTE box (mipsel) | Quectel EG06-E | MBIM |
| Zyxel NR7101 (ipq40xx) | Quectel RG502Q | QMI |
| Cudy LT300 v3 | MeiG SLM770A | NCM (cdc_ncm/AT) |
| (mipsel) | Fibocom-class | MBIM |
| PCIe/MHI host (indep. tester @LS3434) | Foxconn T99W175 | MBIM over **MHI** |

The **PCIe/MHI** row is independent third-party validation from a forum tester
([@LS3434](https://forum.openwrt.org/t/looking-for-pcie-mhi-modem-testers-native-qmi-mbim-connection-manager-wwand/252692)):
their testing on a Foxconn T99W175 drove the two kernel-`wwan`/MHI portability
fixes now in the tree (resolve the control protocol from the wwan port type;
locate the data netdev of a wwan control node), extending coverage beyond USB
to the MHI transport across both arches.

Field-proven behaviors that motivated the project: recovery ladder (opmode-cycle → modem-reset → GPIO/power-cycle → reboot), non-destructive reload (IPv6-PD/VRF preserved), QMAP multi-PDP, GDSP/M2M provider-SIM handling, board power/reset/LED profiles.

## 5. Audit changelog since the review

Addressed in the tree (and the packaging nits from the bot review):
- SPDX headers on all source, real GPL-2.0 text, `.editorconfig`; dropped a stray generated file.
- Decomposed the two largest modules along existing seams (daemon → simops/hwops op-modules; NCM vendor tables → ncm_vendors).
- Token sanitizer for every sysfs-bound value; hardened the C spawn plumbing.
- Closed real test gaps (vendor telemetry, netlink endpoint derivation, AT parser robustness).
- ModemManager config migration (`proto modemmanager` → `proto wwand`) as a user feature.
- Fixed the bot's packaging points: `+ucode` (not `+libucode`), `SUBMENU:=WWAN` on wwand-esim, `$(CMAKE_BINARY_DIR)`, removed the dead CONFLICTS entries (and every stray `qmi-advanced` mention — it was never an official package).
- **`test-version.sh` added** for the generic CI version check across all three installed executables (`wwand`, `wwandctl`, `migrate`).

Landing together in the v1.3.0 Makefile revision:
- **glob-then-`rm` split → explicit per-file list** in `Package/wwand/install`, so a new backend file can never be silently double-owned.
- **New `wwand-mhi` package** answering Makefile:120 (MHI drivers): PCIe/MHI modems live on the kernel `wwan` subsystem and need the MHI driver stack, not the USB kmods. `wwand-mhi` pulls `kmod-mhi-pci-generic` + `kmod-mhi-wwan-ctrl` + `kmod-mhi-wwan-mbim` + `kmod-mhi-net` and ships the `wwan`-subsystem hotplug — moved out of the base package, since procd only arms a subsystem whose hotplug dir exists. Backend-neutral: pair with wwand-qmi or wwand-mbim.
- `codec/mbim-schema/` → `codec/mbim_schema/` install-path rename (matches the source tree).

On the bot's Makefile:215 (reuse stock `ucode-mod-io`): evaluated — the stock module is generic file I/O; wwand's native module does message-oriented cdc-wdm/tty framing plus an rmnet netlink helper, which the stock module does not provide. It stays wwand-private and version-locked to the ucode side.

## 6. On device ownership under coexistence (bot's question)

`CONFLICTS` previously guaranteed only one stack could touch a given `/dev/cdc-wdmX`. Under coexistence that guarantee is a **runtime** property: wwand opens a control device only for an interface it manages, and it manages `proto wwand` exclusively — so it never contends with uqmi for a node behind a `proto qmi` interface. The LuCI migration flow additionally warns the operator to stop/disable the stock dialer for a modem it is taking over. This is the same additive-ownership model ModemManager uses.

One case is NOT covered by that argument and is called out honestly in the review thread: zero-config **autosetup** is on by default, so on a box with no wwand configuration at all a newly appeared modem is claimed by the generated `wwand_modem` + interface. Setting `option autosetup '0'` disables it.

## 7. Request

Given the coexistence rework removes the "replaces the existing stack" objection, and given the ModemManager precedent, **could you take another look?** I'm happy to keep this open while it matures — broaden HW coverage, gather field bug reports, and recruit a co-maintainer. If after that the consensus is still that a separate ucode WWAN stack shouldn't live in the feed, I fully understand keeping it external. I'll also raise the architecture question (improve-existing-stack vs. a separate stack) on openwrt-devel so the WWAN/netifd maintainers can weigh in.
