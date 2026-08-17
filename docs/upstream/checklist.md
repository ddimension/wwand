# Upstream action checklist (v1.3.0 window) — you execute, drafts prepared

Nothing below is pushed/posted. Order matters (the PR Makefile must point at a
*pushed* tag). Gated on the fleet being on the r26 apk first.

## A. Publish the code (prerequisite)
1. wwand `main` is already pushed through `b2d8176` (bytecode precompile,
   namespaced imports, mbim_schema rename, radio_ifs rat fallback, reconnect
   give-up recovery, idempotent renew, IP-push log-level fixes). Push any
   remaining uncommitted fixes first (`git status` in `wwand/`).
2. Push luci-app-wwand + luci-proto-wwand (both clean/pushed at last check).
3. Cut a release tag on the pushed wwand HEAD: **`v1.3.0`**.

## B. openwrt/packages PR #30185 (maintainer: @4920441; bot: openwrt-ai)
4. In the packages fork's `net/wwand/Makefile`, sync to v1.3.0:
   - `PKG_VERSION:=1.3.0`, `PKG_RELEASE:=1`; point `PKG_SOURCE`/URL at the
     `v1.3.0` tarball; refresh `PKG_HASH` (`scripts/update-hashes.sh` equivalent).
   - **`codec/mbim-schema/` → `codec/mbim_schema/`** in the install paths (the
     tarball has the renamed dir — install breaks otherwise).
   - **glob-then-`rm` → explicit per-file list** (done in the feed Makefile; port
     the same `WWAND_BASE_UC`/`_CODEC`/`_SCHEMA` split). Verify union == tree,
     disjoint (see the feed's ownership check).
   - **New `wwand-mhi` package** answering the bot's Makefile:120 (MHI drivers):
     `+kmod-mhi-pci-generic +kmod-mhi-wwan-ctrl +kmod-mhi-wwan-mbim +kmod-mhi-net`,
     ships the `wwan`-subsystem hotplug (moved out of base).
   - `test-version.sh` covers all three executables (already in the PR head).
   - Keep the upstream PR **source-shipped** (no bytecode/CMakeLists precompile —
     that stays feed-only) and keep `ucode-mod-wwand-io` **separate** upstream
     (the io-merge is feed-only); keep `CMAKE_SOURCE_SUBDIR:=io` and its
     `$(CMAKE_BINARY_DIR)/wwand_io.so` path (NOT the feed's `/io/` path).
5. Post the updated `dossier-packages-30185.md` as a PR comment: coexistence +
   device-ownership answer, the `ucode-mod-io` reuse answer, the HW matrix
   **including @LS3434's Foxconn T99W175 over MHI**, and the addressed points.
   Nudge @4920441 for a re-review (the scope decision is theirs).

## C. openwrt/luci PR #8917
6. No functional change needed for v1.3.0 (the 5G-band/telemetry fixes were
   daemon-side). All inline bot findings are closed. Optionally bump the
   "paired with" note to v1.3.0.

## D. openwrt-devel RFC
7. Send `rfc-openwrt-devel.md` to openwrt-devel@lists.openwrt.org, cc the current
   WWAN/netifd maintainers — the architecture discussion the maintainer asked for.

## E. Feed (ddimension/openwrt-repo)
8. Feed is at **r26 / `b2d8176`** (pushed this window, MIRROR_HASH
   `6477620d…`). The uncommitted feed prep (wwand-mhi, explicit-list install,
   qmi-advanced scrub, CI config) lands as **r27** after the fleet is on the r26
   apk — a push aborts the running per-package CI, so only on explicit go.

## Notes
- The E392 FPLMN limitation (old Huawei firmware refuses UIM + CRSM writes) is a
  hardware fact, not a wwand bug.
- mips + libucode ≤ 2023: bytecode teardown segvs on daemon restart (respawn-
  safe, cosmetic, source/aarch64 unaffected). Left as-is per decision; fixed by a
  newer ucode.
