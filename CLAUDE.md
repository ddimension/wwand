# wwand — project guide for Claude

wwand is an event-driven **ucode** QMI/MBIM connection manager for OpenWrt,
replacing the old bash `qmi-advanced` dialer. Repo: github.com/ddimension/wwand.
Everything is English. Commit/push only when asked.

## Layout
- `wwand/` — the daemon package: `src-ucode/` (core), `io/` (native C module
  `io/src/wwand-io.c`: message-oriented cdc-wdm/tty I/O + rmnet netlink
  helper; `io/build-target/wwand_io.so` is the cross-built aarch64 module,
  `io/build-host/wwand_io.so` the host build used by the tests), `files/`
  (netifd shim, init, hotplug, migrate), `tests/`, `Makefile`, `README.md`.
  One source package → binary packages `wwand`, `ucode-mod-wwand-io`,
  `wwand-esim`.
- LuCI packages + wwand-lpac moved to their own repos: ddimension/
  luci-proto-wwand, luci-app-wwand (sources only) and wwand-openwrt-repo
  (the OpenWrt package-definition feed, incl. wwand-lpac entirely).
- `docs/architecture.md`, `docs/telemetry-survey.md`, `docs/STATUS.md`.

## Core layering (src-ucode)
native `wwand_io.so` → codec (`qmux.uc`, `tlv.uc`, `schema/*.uc`, `mbim*.uc`) →
session (`transport.uc`, `client.uc`) → state machines (`modem.uc`,
`context.uc`, `sim.uc`) → system (`netlink.uc` datapath, `recovery.uc`,
`atcmd.uc`) → integration (`daemon.uc`, `config.uc`, `ubus.uc`, `main.uc`).

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
Shim: `files/wwand-proto.sh` (`proto_qmi_setup/teardown/renew`,
`_wwand_apply_settings` builds the netifd update with `proto_set_keep 1`).

## Invariants / conventions
- **VRF**: the daemon touches only the link layer (mux/MTU/carrier via
  RTM_NEWLINK, sysctl); it never adds routes/addresses or sets `IFLA_MASTER`.
  ALL addressing/routing goes through netifd (`proto_add_*`/`proto_send_update`)
  so `ip4table`/`ip6table`/VRF apply. Guarded by `test_datapath` ("vrf: …").
- **QMI schemas must match libqmi.** Verify every message id + TLV id against
  `/vol/release/chateau/openwrt/build_dir/.../libqmi-1.38.0/data/qmi-service-*.json`
  (request TLVs vs `input`, response vs `output`, resolve `common-ref` ids).
  A wrong tag silently decodes garbage (e.g. the packet-dropped 0x1D/0x1E fix).
- **LuCI ubus**: every ucode ubus method called from LuCI must accept
  `ubus_rpc_session: ''` in its args (rpcd injects it).

## ucode gotchas (hit repeatedly)
- Self/mutually-referencing `let` arrows (recursion/reschedule) throw
  "Can't access lexical declaration before initialization" → **forward-declare**
  (`let f; f = () => {…}`).
- Object literal keys must be identifiers/strings — **numeric keys fail**
  ("Expecting label"); quote them (`'8': …`) and look up via `sprintf('%d',n)`.
- `Date.now()`/`new Date()`/`Math.random()` unavailable; `time()` is a builtin
  (works in the daemon; not in Workflow scripts).
- `replace(s, /-/g, '')` for global replace (string arg replaces first only).

## Build / test / deploy
- **Tests (host):** `cd wwand/tests && sh run_tests.sh` — 14 suites, mockhub
  over the real codec + a private ubusd. Run before every commit.
- **JS syntax:** `node --check <file>.js` for LuCI resources.
- **C module (cross):** aarch64 toolchain at
  `/vol/release/chateau/openwrt/staging_dir/toolchain-aarch64_cortex-a53_gcc-14.4.0_musl`;
  build against `staging_dir/target-aarch64_cortex-a53_musl` (`-shared -fPIC
  -I…/usr/include -lucode`, then strip). Output already at
  `wwand/io/build-target/wwand_io.so`.
- **Proper build = OpenWrt package** (preferred). Makefile fixes that MUST stay:
  `wwand/Makefile` has a `Build/Prepare` staging `io/` into PKG_BUILD_DIR for
  cmake (sources live in the pkg dir, no
  PKG_SOURCE); `wwand/Makefile` installs `codec/mbim-schema` (daemon imports
  MBIM at top level — MBIM is lazy-`require`d in `daemon.uc` but the schema must
  still ship). `wwand` DEPENDS pulls `+ucode-mod-struct` etc. — apk install
  resolves the ucode deps. Bump PKG_RELEASE or `apk add --force-reinstall`.

## Test router
`ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.203.245`
— MikroTik Chateau 5G R17 ax (qualcommax/ipq60xx, aarch64 musl), Quectel
RG650E-EU. **Reflashed often → SSH host key changes** (hence UserKnownHostsFile
=/dev/null). Root has an **empty password**. OpenWrt build tree at
`/vol/release/chateau/openwrt/` — do not modify except with explicit permission.
No sftp/scp on the device → deploy via `tar | ssh` or install the .apk.
**Always `sync` after a file deploy.** A `tar x`/`cp` deploy **drops the +x
bit** on the files that get *executed* — this bit twice:
- `/lib/netifd/proto/qmi.sh` — netifd can't exec it, the `qmi` proto handler
  never registers (`ubus call network get_proto_handlers` has no `qmi`), and
  interfaces fall back to `proto: none` (up, no L3 config).
- `/usr/sbin/wwand` (the daemon, a ucode script with `#!/usr/bin/env ucode`) —
  procd exec fails with **exit 127**, respawn retries exhaust, and wwand is dead
  (the WAN persists by no-proto-task design, so ping still works — misleading).
  `ubus call service list '{"name":"wwand"}'` shows `exit_code: 127`.
So after a tar/cp deploy: **`chmod +x /usr/sbin/wwand /lib/netifd/proto/qmi.sh`**,
then `/etc/init.d/wwand restart` + `/etc/init.d/network restart`. The `.uc`
modules under `/usr/share/ucode/wwand/` are imported, not exec'd — they don't
need +x. The apk pkg is fine (Makefile uses INSTALL_BIN). Also ensure no **stale
`qmi-advanced.sh`** (old dialer) lingers — it also `add_protocol qmi` and wins.
Modem is normally in **QMI mode**
(`qmi_wwan`); MBIM mode → switch back with `AT+QCFG="usbnet",0` + `AT+CFUN=1,1`.

## Gotchas from field bring-up
- Restarting the OLD (pre-no-proto-task) wwand while `context_wait` monitors were
  parked **wedged ubusd** (whole bus dead → needs reboot). The no-proto-task
  rewrite removes the monitor entirely; this class of wedge is gone.
- RG650E firmware **rejects MBIM_OPEN** (STATUS_FAILURE) — reference mbimcli
  fails identically → firmware bug, not wwand. MBIM stays QMI-only on this HW.
- RG650E declines QMAP DAP 8 aggregation edge cases → renegotiate plain QMAP;
  `dl_datagram_max_size` (default model table = 31 KB) is overridable per modem.
