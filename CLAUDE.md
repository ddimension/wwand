# wwand — project guide for Claude

wwand is an event-driven **ucode** QMI/MBIM connection manager for OpenWrt,
replacing the legacy bash QMI dialer. Repo: github.com/ddimension/wwand.
Everything is English. Commit/push only when asked.

## Layout
This repo is the wwand **source tree** (package root = repo root):
`src-ucode/` (core), `io/` (native C module `io/src/wwand-io.c`:
message-oriented cdc-wdm/tty I/O + rmnet netlink helper;
`io/build-target/wwand_io.so` is the cross-built aarch64 module,
`io/build-host/wwand_io.so` the host build used by the tests), `files/`
(netifd shim, init, hotplug, migrate), `tests/`, `tools/`,
`docs/reference.md` (config + ubus API reference).
- **Package definitions live in ddimension/openwrt-repo** (the feed):
  `wwand/Makefile` there builds, from this repo (git source, pinned via
  PKG_SOURCE_VERSION — bump it there after pushing here), a **backend-neutral
  base + per-backend split**: `wwand` (daemon/framework/codec/shared core +
  the native `wwand_io.so`, which since 2026-08 ships inside the base package —
  the separate `ucode-mod-wwand-io` package is gone, `PROVIDES` covers old
  configs), `wwand-qmi`, `wwand-mbim` (DEPENDS wwand-qmi), `wwand-ncm`,
  `wwand-mhi` (PCIe/MHI transport + MHI kmods + the wwan-subsystem hotplug;
  backend-neutral, pair with wwand-qmi/-mbim), `wwand-esim`, plus two optional
  DATAPATH add-ons — `wwand-datapath-rmnet_nss` (vendor `qmi_wwan_q`, USB) and
  `wwand-datapath-rmnet_nss_mhi` (vendor `pcie_mhi`, PCIe/MHI) — which adopt the
  QMAP children those drivers register so Qualcomm NSS offload survives.
  Backends do **not** CONFLICTS the stock handlers — wwand coexists with
  uqmi/umbim/comgt-ncm and manages only `proto wwand`.
- **ucode is shipped precompiled to bytecode by default** (production builds),
  built by the **repo-root `CMakeLists.txt`** alongside `wwand_io.so` — one
  compiler invocation per file over **explicit source lists** (no glob as build
  input; a configure-time check fails on list drift, so ADD NEW `.uc` FILES to
  `WWAND_UCODE_MODULES`/`_PROGRAMS`/`_PLAIN` there). Every intra-tree module
  name is passed as `dynlink=` so files compile independently (no ordering;
  imports resolve at runtime via the search path); `-s` keeps the bytecode
  relocatable; a typo'd import is still a compile error. **Graceful fallback:** a
  configure-time capability probe checks the host ucode can actually emit a
  bytecode module with these flags — an older/absent ucode DOES NOT fail the
  build, it ships the ucode SOURCE instead (functional, no bytecode start-up
  win). That is not hypothetical and not a defect: **openwrt-25.12 ships source,
  snapshot ships bytecode**, because 25.12's ucode (2026.01.16) does not know
  `-cmodule` at all — it ignores the flag, compiles the file as a program, and
  `export` is illegal there. Nor is there a way around it: that interpreter
  cannot even LOAD a bytecode module (it reads the file as source and stops at
  the magic), so producing them elsewhere does not help. It flips by itself once
  the branch carries a newer ucode. Note the coupling is to the ucode VERSION,
  not the target: bytecode is architecture-independent (a module from the
  aarch64 package loads in an x86-64 interpreter). Dev opt-out:
  `CONFIG_WWAND_UCODE_SOURCE` (feed menuconfig) / `-DUCODE_PRECOMPILE=OFF`.
  **Invariants (configure fails otherwise): imports namespaced
  (`wwand.codec.tlv`), NEVER relative; no hyphens in module paths (hence
  `codec/mbim_schema/`).** require()-CommonJS shims (top-level `return`,
  `WWAND_UCODE_PLAIN`) stay source; they may import bytecode modules freely.
- LuCI packages moved to their own repos: ddimension/luci-proto-wwand,
  luci-app-wwand (sources only; package defs + wwand-lpac entirely in the
  feed repo).
- **Config: all in `/etc/config/network`** (WireGuard-style: `wwand_modem` /
  `wwand_sim` (per-ICCID override) / `interface proto wwand + option modem` /
  `wwand_globals`). Proto is **`wwand`**. Good citizen: wwand manages ONLY
  `proto wwand` interfaces and the shim registers ONLY that proto — the `qmi`
  name stays uqmi's, and a bare `proto qmi` interface is never adopted. There is
  no switch for it (the former `option takeover` is gone). No `/etc/config/wwand`
  for new installs; migration to the native model is always user-triggered (LuCI
  modem list / `config.migrate_plan` / `/usr/libexec/wwand/migrate`, or the
  example uci-defaults script in `/usr/share/wwand/examples/`).
  Full model in `docs/reference.md`; how to extend in `docs/extending.md`.
- **Zero-config autosetup** (default ON, opt-out `wwand_globals option
  autosetup '0'`): modem appears on an unconfigured box → daemon hotplug
  creates `wwmodem_auto` + `interface wwan0` (default wan firewall zone),
  then ONE-SHOT ICCID/IMSI→APN fill from `apndb.uc` is COPIED into uci
  (marker `option autosetup 1` cleared; uci writers live in main.uc deps
  `autosetup_create`/`autosetup_fill`). HW-verified on the Cudy LT300.
- **Idempotent sets + deferred apply**: netsel/settings/WDS-profile/NCM
  CGDCONT/slot-switch all read-before-write (`unchanged: true`, no radio
  bounce). Quirk `netsel_deferred`/`settings_deferred` (MeiG SLM7xx) →
  result `deferred: true` + `apply: 'modem_reset'` (ubus `modem_reset`:
  QMI DMS offline→reset, NCM CFUN=1,1; auto ifaces come back on their
  own). During INIT needed resets collect in `_init_resets` → ONE batched
  reset at the end. `option at2_external '1'` releases the secondary AT
  port for external tools (status `at2_released`; telemetry falls back to
  the control channel).
- **`docs/gotchas.md`** — beliefs that look right and are wrong, each with the
  evidence that settles it. Read it before debugging anything in the datapath,
  the QMAP negotiation or the LuCI rendering; it is the cheapest file in the
  tree per hour saved.
- `docs/architecture.md`, `docs/backend-interface.md`,
  `docs/datapath-interface.md`, `docs/extending.md`,
  `docs/datapath-interface.md`, `docs/STATUS.md` (current state; the dated
  log is `docs/status-archive.md`); contributor notes under
  `docs/design/` (research) and `docs/upstream/` (submission material).

## Core layering (src-ucode)
native `wwand_io.so` → codec (`qmux.uc`, `tlv.uc`, `hex.uc`, `schema/*.uc`
incl. `schema/rat.uc` = canonical RAT/IoT vocabulary, `mbim*.uc`) → session
(`transport.uc`, `client.uc`) → state machines
(`modem.uc` + its extracted QMI helpers `modem_init_qmi.uc` / `telemetry_qmi.uc`
/ `regdetail.uc` / `config_check.uc` / `datapath_qmi.uc`; the datapath
interface lives in `netlink.uc` with `datapath_*.uc` add-ons beside it
(docs/datapath-interface.md); `modem_mbim.uc` +
`telemetry_mbim.uc`; `modem_ncm.uc` + `ncm_vendors.uc` (vendor dial/auth tables)
+ `telemetry_ncm.uc`; `context.uc` + `context_monitor_qmi.uc`; `sim.uc`; shared
`modem_common.uc` / `context_common.uc` / `backend.uc`) → system (`netlink.uc`
datapath, `recovery.uc`, `atcmd.uc` + `atcmd_parse.uc`, `board.uc`) → integration
(`daemon.uc` + its extracted op modules `netsel_ops.uc` / `simops.uc`
(SIM/SMS/eSIM/APDU/PLMN ops) / `hwops.uc` (reset/repower), `config.uc`,
`ubus.uc`, `main.uc`).

## Board / power / LEDs (`board.uc`)
Generic, keyed off `/etc/board.json` model id → a profile table (MikroTik
Chateau, Zyxel LTE33xx/NR7101; unknown = null profile → all ops no-op). Absorbs
the vendor helper scripts: modem power/reset GPIOs + status LEDs. Wired in:
recovery `usb_repower` rung → board **power-cycle or reset-GPIO pulse** (replaces
the external `usb-repower`); a modem config `reset_gpio` (or the board default)
is pulsed instead of power-cycling. `daemon` runs a status tick (LEDs from
reg+signal; re-logs a waited-on modem every 30 s). `modem_repower` ubus method +
LuCI button. Everything through an injectable `fx` → `test_board.uc`.

## eSIM / APDU transport (`sim.uc` + `esim.uc`)
`_apdu_be` probe order (sim.uc `apdu_backend`): **native MBIM MS UICC Low Level
Access** (`mbim_backend.uicc_*`, UUID `c2f6588e…`, via `command_raw`) → **QMI
UIM logical channel** (native, or over the QMI-over-MBIM passthrough via
`modem_mbim._ensure_uim`) → **AT** (`CCHO`/`CGLA`). `sim.power_cycle`
deliberately uses the OPPOSITE precedence (QMI-UIM first — the HW-proven SIM
hot-reset — then MBIM UICC Reset, then AT CFUN=0/1); see the comments at both
sites. MBIM modem exposes `self.mbim_uicc` (duck-typed; keeps the
base `sim.uc` free of an mbim import). Wire format verified vs libmbim 1.32 +
lpac; wire-buffer tests in `test_mbim_backend`. Not HW-validated end-to-end (no
eUICC-equipped MBIM modem on hand; RG650E rejects MBIM_OPEN, EG06 card has no
eUICC). Telemetry log is now one shared `modem_common.format_telemetry(o)` for
all backends.

## netifd integration (current model — no-proto-task)
The proto handler sets **`no_proto_task=1`**: after setup the interface stays
`IFS_UP` with **no monitor process**. The **daemon owns the context lifecycle**
and drives netifd over ubus (deps in `main.uc`: `kick_interface`=up,
`renew_interface`=renew, `down_interface`=down, `iface_status`=status probe).
- Transient loss → hold the interface up, reconnect the session, `renew`
  **in place** (no teardown → IPv6-PD/VRF preserved). Bounded by `hold_max`
  (~90 s) then `down`. See `daemon.uc` `enter_reconnecting`/`retry_activate`.
- Permanent loss (`sim_blocked`, admin/config down) → `down` immediately.
- wwand restart is non-destructive (`stop_local`, not `shutdown`): WAN + traffic
  survive; the daemon **adopts** the live session on `registered`.
Shim: `files/wwand-proto.sh` → `/lib/netifd/proto/wwand.sh`
(`proto_wwand_setup/teardown/renew`; `add_protocol wwand` and nothing else —
netifd sources every handler in /lib/netifd/proto, so two claiming `qmi` would
be decided by load order; `_wwand_apply_settings` builds the netifd update).

## Invariants / conventions
- **VRF**: the daemon touches only the link layer (mux/MTU/carrier via
  RTM_NEWLINK, sysctl); it never adds routes/addresses or sets `IFLA_MASTER`.
  ALL addressing/routing goes through netifd (`proto_add_*`/`proto_send_update`)
  so `ip4table`/`ip6table`/VRF apply. Guarded by `test_datapath` ("vrf: …").
- **QMI schemas must match libqmi.** Verify every message id + TLV id against
  `/vol/release/chateau/openwrt/build_dir/.../libqmi-1.38.0/data/qmi-service-*.json`
  (request TLVs vs `input`, response vs `output`, resolve `common-ref` ids).
  A wrong tag silently decodes garbage (e.g. the packet-dropped 0x1D/0x1E fix).
- **Kernel behaviour must be verified against the kernel source**, the same way
  QMI schemas are verified against libqmi. The tree is at
  `/vol/release/chateau/openwrt/build_dir/target-*/linux-*/linux-*/drivers/`.
  This rule exists because it was missing: a datapath fix was built on the
  assumption that `rmnet_changelink()` ASSIGNS the QMAP flags, it applies them
  masked, and the hardware test passed anyway because the case tried happened to
  be a bit extension. See `docs/gotchas.md`.
- **Anchor every external claim, and date it.** Anything asserted about libqmi,
  the kernel, netifd, luci.js, apk or a modem's firmware carries the source and
  the version it was checked against — `(rmnet_config.c, 6.18.41)`,
  `(luci.js:1394-1396)`, `(HW-observed on the RG650E, 2026-08-30)`. An
  unanchored claim cannot be re-verified, only believed, and it decays silently
  when the dependency moves. This applies to code comments as much as to docs.
- **LuCI ubus**: every ucode ubus method called from LuCI must accept
  `ubus_rpc_session: ''` in its args (rpcd injects it).
- **Packaging is checkable, not just documented**: `tools/check-packaging.py`
  asserts that every `.uc` is installed by exactly one package, that nothing
  named is missing, and that every `files/…` path resolves — against the working
  tree or a release tarball. Run it before a release and after any rename:

      tools/check-packaging.py --makefile ../repository/wwand/Makefile
      tools/check-packaging.py --makefile <pkgs>/net/wwand/Makefile --tarball wwand-X.Y.Z.tar.gz

## ucode gotchas (hit repeatedly)
- **Imports MUST be namespaced** (`import … from 'wwand.codec.tlv'`), never
  relative (`'./codec/tlv.uc'`) — the bytecode precompile resolves modules only
  via the search path, and the root CMakeLists.txt fails the configure on a
  relative import. Sibling files in subdirs need the FULL namespace path
  (`wwand.codec.schema.loc`, not `wwand.loc`). No `-` in module dirs/files.
  New `.uc` files must be added to the CMakeLists source lists.
- Self/mutually-referencing `let` arrows (recursion/reschedule) throw
  "Can't access lexical declaration before initialization" → **forward-declare**
  (`let f; f = () => {…}`).
- Object literal keys must be identifiers/strings — **numeric keys fail**
  ("Expecting label"); quote them (`'8': …`) and look up via `sprintf('%d',n)`.
- `Date.now()`/`new Date()`/`Math.random()` unavailable; `time()` is a builtin
  (works in the daemon; not in Workflow scripts).
- `replace(s, /-/g, '')` for global replace (string arg replaces first only).
- **`require()` gives the loaded script its OWN copies of imported modules.** A
  plain script pulled in with `require()` does NOT share module instances with
  the importing side, so module-level mutable state (a registry, a cache) is
  invisible across that boundary — and silently so. Verified on the host
  interpreter; it is why the datapath plugins RETURN their implementation
  instead of registering it (`netlink.uc`, `docs/extending.md` §4). The
  `*_lazy.uc` shims are unaffected because they only hand back factories.
- **Module-level `export function f() {…}` MUST end with `};`** — the OpenWrt
  ucode parser errors ("Expecting ';'" at the next export) without it; the
  newer host-built ucode is lenient, so `run_tests.sh` does NOT catch this.
  Always sanity-import changed modules on the target after deploy.

## Build / test / deploy
- **Tests (host):** `cd tests && sh run_tests.sh` — all suites must be green
  before every commit (current count lives in docs/STATUS.md); mockhub
  over the real codec + a private ubusd. Run before every commit.
- **JS syntax:** `node --check <file>.js` for LuCI resources.
- **C module (cross):** aarch64 toolchain at
  `/vol/release/chateau/openwrt/staging_dir/toolchain-aarch64_cortex-a53_gcc-14.4.0_musl`;
  build against `staging_dir/target-aarch64_cortex-a53_musl` (`-shared -fPIC
  -I…/usr/include -lucode`, then strip). Output already at
  `io/build-target/wwand_io.so`.
- **Proper build = OpenWrt package** (preferred) — the Makefile lives in
  **openwrt-repo** (`wwand/Makefile`, git source pinned on this repo).
  Fixes that MUST stay there: `CMAKE_SOURCE_SUBDIR:=io` (cmake tree is a
  subdir). All backends (QMI/MBIM/NCM) are **lazy-`require`d** in `daemon.uc`
  (`*_lazy.uc` shims) and ship in their own package — the base `wwand` carries
  no backend; `wwand-mbim` ships `codec/mbim_schema` (underscore — bytecode
  module names cannot carry hyphens). `wwand` DEPENDS pulls
  `+ucode-mod-struct` etc. — apk install resolves the ucode deps. Bump
  PKG_RELEASE or `apk add --force-reinstall`.

## Test router
`ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.203.245`
— MikroTik Chateau 5G R17 ax (qualcommax/ipq60xx, aarch64 musl), Quectel
RG650E-EU. **Reflashed often → SSH host key changes** (hence UserKnownHostsFile
=/dev/null). Root has an **empty password**. OpenWrt build tree at
`/vol/release/chateau/openwrt/` — do not modify except with explicit permission.
No sftp/scp on the device → deploy via `tar | ssh` or install the .apk.
**Always `sync` after a file deploy.** A `tar x`/`cp` deploy **drops the +x
bit** on the files that get *executed* — this bit twice:
- `/lib/netifd/proto/wwand.sh` — netifd can't exec it, the `wwand` proto handler
  never registers (`ubus call network get_proto_handlers` has no `wwand`), and
  interfaces fall back to `proto: none` (up, no L3 config).
- `/usr/sbin/wwand` (the daemon, a ucode script with `#!/usr/bin/env ucode`) —
  procd exec fails with **exit 127**, respawn retries exhaust, and wwand is dead
  (the WAN persists by no-proto-task design, so ping still works — misleading).
  `ubus call service list '{"name":"wwand"}'` shows `exit_code: 127`.
So after a tar/cp deploy: **`chmod +x /usr/sbin/wwand /lib/netifd/proto/wwand.sh`**,
then `/etc/init.d/wwand restart` + `/etc/init.d/network restart`. The `.uc`
modules under `/usr/share/ucode/wwand/` are imported, not exec'd — they don't
need +x. The apk pkg is fine (Makefile uses INSTALL_BIN). Note: wwand never
registers `proto qmi`, so uqmi's `qmi.sh` keeps it — expected coexistence, not
a bug.
Modem is normally in **QMI mode**
(`qmi_wwan`); MBIM mode → switch back with `AT+QCFG="usbnet",0` + `AT+CFUN=1,1`.

## Gotchas from field bring-up
- Restarting the OLD (pre-no-proto-task) wwand while `context_wait` monitors were
  parked **wedged ubusd** (whole bus dead → needs reboot). The no-proto-task
  rewrite removes the monitor entirely; this class of wedge is gone.
- RG650E firmware **rejects MBIM_OPEN** (STATUS_FAILURE) — reference mbimcli
  fails identically → firmware bug, not wwand. MBIM stays QMI-only on this HW.
- RG650E "declines QMAP DAP 8" was OUR bug, not its firmware: DAP 8 is QMAPv4
  (libqmi QMI_WDA_DATA_AGGREGATION_PROTOCOL_QMAPV4 = 0x08; v5 is 0x09, and
  quectel-cm only ever sends 0x05 or 0x09). `DAP_QMAPV5` was 8 and is 9 now, so
  the renegotiation that used to fire here should stop. Re-verify on HW;
  `dl_datagram_max_size` (default model table = 31 KB) is overridable per modem.
