# Upstream action checklist (Package G) — you execute, I prepared the drafts

Nothing below has been pushed/posted. Order matters (the PR Makefile must point
at a *pushed* tag).

## A. Publish the code (prerequisite for everything else)
1. Push the local wwand commits to github.com/ddimension/wwand `main`:
   `0e9c7c3` (IoT-RAT + FPLMN), `3b35834` (luci-app, separate repo), `74092e3`
   (audit pass). — 3 wwand commits total this window on top of what's already pushed.
2. Push luci-app-wwand + (unchanged) luci-proto-wwand.
3. Cut a release tag on the new wwand HEAD, e.g. `v1.2.0`.

## B. openwrt/packages PR #30185
4. In your packages fork's `net/wwand/Makefile`:
   - bump `PKG_VERSION` to `1.2.0`, `PKG_RELEASE:=1`;
   - point `PKG_SOURCE`/URL at the `v1.2.0` tag tarball; refresh `PKG_HASH`
     (`make package/wwand/download` then read `.../dl/*.tar.gz` sha256, or
     `scripts/update-hashes.sh`).
   - **Fix the two open bot points:**
     a) `Package/wwand/install` — replace the "install `*.uc` then `rm -f` the
        backend files" glob-then-rm with an **explicit base-package file list**
        (install only the base `.uc` by name), so a newly added backend file can
        never be double-owned. The current backend `rm` list is: main.uc; QMI:
        modem/context/qmi_backend/callend/qmi_lazy; MBIM: modem_mbim/context_mbim/
        mbim_backend/mbim_client/qmi_over_mbim/mbim_lazy + codec/mbim.uc; NCM:
        modem_ncm/context_ncm/ncm_lazy; eSIM: esim/esim_bridge. Everything else in
        src-ucode/ (incl. the new `simops.uc`, `hwops.uc`, `ncm_vendors.uc`,
        `codec/schema/rat.uc`) is base — verify each new file lands in exactly one
        package after the switch (`make ... V=s`, then diff the file lists).
     b) add the generic `test-version.sh` the CI version check expects.
5. Post the dossier (scratchpad/dossier-packages-30185.md) as a PR comment,
   tagging @BKPepe. It recaps the coexistence pivot, the ModemManager precedent,
   the audit changelog, the HW/test matrix, and answers the device-ownership
   question. (BKPepe has not re-reviewed since the coexistence rework — this nudge
   is the point; the ~2-week window he offered is still open.)

## C. openwrt/luci PR #8917
6. Sync the luci-app/luci-proto to the pushed HEAD. No formal review yet; the
   inline findings from the earlier round are already addressed (qmi.js alias
   dropped, SIM-slot fix, poller cleanup, i18n). Optional follow-up noted in the
   PR (a modem selector on the settings page) — not a blocker.

## D. openwrt-devel RFC
7. Send scratchpad/rfc-openwrt-devel.md to openwrt-devel@lists.openwrt.org, cc the
   WWAN/netifd maintainers. This is the architecture discussion BKPepe asked for
   (improve-existing-stack vs. a separate proto); it also signals good faith on
   the PR. Adjust the Cc list to the current maintainers before sending.

## E. Feed (ddimension/openwrt-repo) — after A
8. Bump the feed `wwand/Makefile`: `PKG_SOURCE_VERSION` → the new wwand commit,
   `PKG_SOURCE_DATE`, `PKG_MIRROR_HASH` (via scripts/update-hashes.sh, SDK-
   authoritative). Currently pinned at `0189cc8` (pre-split) — stale.

## Notes
- The E392 FPLMN limitation (old Huawei firmware refuses UIM + CRSM writes) is a
  hardware fact, not a wwand bug — no action, just don't claim FPLMN works on
  every modem.
- I can prepare the explicit-file-list Makefile diff (B.4a) and the test-version.sh
  against the feed Makefile as a reference patch if you want — say the word.
