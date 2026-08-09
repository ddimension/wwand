Status update + maturity dossier (for @BKPepe and the WWAN maintainers)

Since the review I've made the load-bearing change and hardened the tree. A concise summary of where this stands against the concerns raised.

## 1. It no longer replaces the stock stack — coexistence, opt-in per interface

The single biggest objection ("a second implementation that replaces uqmi/umbim/comgt-ncm") is gone:

- **All `CONFLICTS` removed.** The packages install *alongside* uqmi/umbim/comgt-ncm.
- wwand manages **only `proto wwand`** interfaces. It does not touch existing `proto qmi`/`mbim`/`ncm`.
- Adopting the stock stack (registering the `qmi` proto alias, managing bare `proto qmi`, auto-migrating on upgrade) is gated behind a single global **`option takeover '1'`, default off**.
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

Field-proven behaviors that motivated the project: recovery ladder (opmode-cycle → modem-reset → GPIO/power-cycle → reboot), non-destructive reload (IPv6-PD/VRF preserved), QMAP multi-PDP, GDSP/M2M provider-SIM handling, board power/reset/LED profiles.

## 5. Audit changelog since the review

Addressed in the tree (and the packaging nits from the bot review):
- SPDX headers on all source, real GPL-2.0 text, `.editorconfig`; dropped a stray generated file.
- Decomposed the two largest modules along existing seams (daemon → simops/hwops op-modules; NCM vendor tables → ncm_vendors).
- Token sanitizer for every sysfs-bound value; hardened the C spawn plumbing.
- Closed real test gaps (vendor telemetry, netlink endpoint derivation, AT parser robustness).
- ModemManager config migration (`proto modemmanager` → `proto wwand`) as a user feature.
- Fixed the bot's packaging points: `+ucode` (not `+libucode`), `SUBMENU:=WWAN` on wwand-esim, `$(CMAKE_BINARY_DIR)`, removed the dead `qmi-advanced` CONFLICTS entry.

Still open from the bot review, will address in the next Makefile revision:
- the glob-then-`rm` split in `Package/wwand/install` (switch the base package to an explicit file list so a new backend file can never be double-owned);
- add the generic `test-version.sh`.

## 6. On device ownership under coexistence (bot's question)

`CONFLICTS` previously guaranteed only one stack could touch a given `/dev/cdc-wdmX`. Under coexistence that guarantee is now a **runtime** property: wwand opens a control device only for an interface it manages (`proto wwand`, or `proto qmi` only under `takeover`), so with `takeover` off it never contends with uqmi/qmi-advanced for the same node. The LuCI migration flow additionally warns the operator to stop/disable the stock dialer for a modem it's taking over. This is the same additive-ownership model ModemManager uses.

## 7. Request

Given the coexistence rework removes the "replaces the existing stack" objection, and given the ModemManager precedent, **could you take another look?** I'm happy to keep this open while it matures — broaden HW coverage, gather field bug reports, and recruit a co-maintainer. If after that the consensus is still that a separate ucode WWAN stack shouldn't live in the feed, I fully understand keeping it external. I'll also raise the architecture question (improve-existing-stack vs. a separate stack) on openwrt-devel so the WWAN/netifd maintainers can weigh in.
