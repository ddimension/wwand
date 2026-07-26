# wwand — status / continuation notes

_Last updated: 2026-07-26. All test suites green; all committed/pushed.
Three control backends (QMI, MBIM, NCM) behind one daemon-neutral contract._

## QModem study — datapath parity items (2026-07-26)

Studied QModem (FUjr/QModem) + quectel-CM vs wwand. wwand's QMI/AT/mux vocabulary
is a near-superset; only narrow datapath gaps. Adopted (schema libqmi-1.38-verified,
host+target `wwand_io.so` rebuilt, 31 suites/1281 checks green):
- **WDA UL aggregation** — SET_DATA_FORMAT now requests `ul_max_datagrams`(0x1B)/
  `ul_max_size`(0x1C)/`dl_min_padding`(0x19); negotiated maxima logged + stored.
- **rmnet UL egress aggregation** — mainline has NO `IFLA_RMNET_UL_AGG_PARAMS`;
  it's the ethtool **TX_AGGR coalesce** (default off). New genl helper
  `qmit_rmnet_tx_aggr` (wwand-io.c) + best-effort `netlink.setup` wire-up.
- **Dynamic endpoint type** — `netlink.ep_type_number` (HSUSB/PCIE from the bus);
  fixes PCIe modems (RG500Q/MHI) that were hardcoded HSUSB in SET_DATA_FORMAT +
  BIND_MUX. AW1000-relevant.
- **BIND_MUX `client_type`=1 (tethered)** TLV 0x13.
- **link_state per-mux gate** — vendor qmi_wwan_q sysfs, existence-gated best-effort
  (no-op mainline; opens the mux on a vendor kernel).

NCM backend parity (modem_ncm/context_ncm, host-tested — 242 is QMI so no HW yet):
- **5G-SA registration** — `parse_creg` widened to `+C5GREG` (POSIX ERE capturing
  group), register poll now CEREG → **C5GREG** → CREG (SA modems read CEREG
  not-registered while attached via 5GS only).
- **Fibocom auth = `+MGAUTH`** (FM150/FM350 reject `+CGAUTH`).
- **New vendor dial verbs** — gosuncn `+ZECMCALL`, neoway `$MYUSBNETACT`, telit
  fallback `#ICMAUTOCONN`, meig fallback 5-arg `$QCRMCALL=1,0,3,2,<cid>`.
- **Universal `AT+CGPADDR` liveness** — for vendors with neither a byte counter nor
  a dial status query (previously zero liveness); conservative, only trips on a
  clearly-empty reply for our cid.
- **`0.0.0.0`/`::` guard** in `build_settings`. (Autodial modems — Huawei-unisoc
  `^SETAUTODIAL`, neoway — deferred; needs HW.)

## test_context was silently running only 4/20 scenarios — fixed (2026-07-26)

Found while adding a mux-bind assertion: **`test_context.uc` silently executed only
the first 4 scenarios** (dual, v6-degrade, v4-fatal, disconnect) and reported "27
checks, 0 failures". Every scenario that defers its assertions / `next()` to a
`uloop.timer` *after* connect — disconnect teardown, admin-down, pdp-update,
**mux-bind**, reconnect, zero-rx watchdog, data-stats, … (~16) — **never ran**, so
their assertions had never validated. Root cause: on the host ucode build a
`uloop.timer` scheduled from inside the mock-driven callback chain (mockhub delivers
via `uloop.timer(0)`, no fd) does not fire under a single `uloop.run()` — the loop
returns once the current delivery wave drains (0.04 s, no guard timeout). Isolation
proves plain `uloop.run()` DOES block on top-level timers, so it's the mock async
chain, not uloop. Neither a parked pipe fd via `uloop.handle`, a self-rescheduling
keepalive, `uloop.interval`, nor globally-held timers kept it alive.

**Fix:** pump `uloop.run(2)` in short slices until all scenarios are consumed
(wall-clock advances so the deferred one-shot timers become due and fire). Now
**17/20 scenarios validate** (85 checks, was 27) — including the mux-bind
`client_type` TLV assertion, which passes. The 3 telemetry scenarios (zero-rx,
zero-rx-quiet, data-stats) rely on a *self-rescheduling* QMI-round-trip sampler that
the re-entrant pump still can't drive; they **self-skip with a printed note** rather
than silently pass. Proper full fix = an **fd-backed mock hub** so `uloop.run()`
blocks like production (transport.uc registers the cdc-wdm fd) — deferred.

## VRF vs policy-routing — HW deep-dive (2026-07-26)

Tried converting 242 (NR7101, Telekom, **public** WAN `2.164.26.219` + v6 GUA,
reachable from the internet) from policy routing to a VRF per the docs. Deep HW
investigation; 242 restored to the working policy-routing baseline afterwards (LAN
untouched throughout).

- **VRF instantiation gaps (docs fixed):** a `config device type 'vrf'` only comes
  up when an interface references it → needs `config interface 'vrf_wan' proto
  'none' device 'vrf_wan'`; and a **full `network restart`** (not `reload`) to
  enslave the members. The member interfaces must keep `ip4table=<vrf-table>` or
  the default route leaks to `main`. The `l3mdev` FIB rule (v4+v6) **and** the VRF
  master itself **are** auto-created by the kernel/netifd on every (cold) boot —
  an earlier hotplug helper adding them by hand was pure redundancy
  (cold-boot-verified).
- **More VRF sharp edges found on HW (all reproduced, all documented):**
  - *dmz→wan outbound is dropped.* With **both** members in one VRF the l3mdev
    rewrites the ingress iif to the master `vrf_wan` for **all** inter-member
    forwarding, so fw4 can no longer tell dmz-sourced from wan-sourced traffic.
    The `vrf_wan`-in-wan-zone fix (needed so the **inbound** DNAT return matches a
    zone) then misclassifies the DMZ host's **outbound** (`iif=vrf_wan` → wan) as
    wan→wan → dropped (`drop wan out: IN=vrf_wan OUT=wwan0m1`, HW-seen with the DMZ
    host's IKE/UDP-4500). Policy routing keeps the real iif (`br-lan.20`=dmz) so
    dmz→wan just works.
  - *v6 return needs a non-source-specific default.* The cellular v6 default is
    source-scoped (`from <WAN /64>`); on the DNAT reply the source is un-NAT'd only
    at postrouting, so at routing time it is still the DMZ host's addr → no match →
    `unreachable`, dropped before `forward`. Fixed with a catch-all `config route6`
    (device default) in the VRF table. (Applies to policy routing too.)
  - *static DMZ IPv6 is flushed on enslavement.* The kernel keeps IPv4 but drops
    IPv6 on a master change; netifd never notices (only listens to `RTNLGRP_LINK`,
    never `RTM_DELADDR`) → the static ULA is gone after boot until an `ifup`. Clean
    fix is a sysctl, `net.ipv6.conf.{default,all}.keep_addr_on_down=1`
    (`/etc/sysctl.d/`), cold-boot-verified. No netifd patch needed.
- **Hard limit (docs' new caveat):** router-**terminated** traffic on the WAN IP
  is broken under VRF — HW-confirmed for **ICMP and TCP** (request in, no reply
  out). Root cause is *below* the firewall: the router's locally-generated reply
  is not VRF-associated, routes to the raw slave **without** the l3mdev
  `<redirect>`, and cannot egress. Proven that no fw4/nftables change fixes it
  (accept rules, `notrack` both legs, master-in-zone all just shifted the
  symptom); secondary fw4 effects (untracked→`ct state invalid` drop, forward
  reclassification via l3mdev double-traversal) are real but downstream. Forwarded
  traffic (inbound→DMZ host, `iif=VRF`) does get the redirect and works.
- **Verdict:** **242 left on policy routing (Variant 1)** — it does everything
  natively and cleanly: bidirectional DMZ forwarding (in **and** out, incl. the
  DMZ host's own IKE), inbound DNAT (v4 404 + v6 handshake), and router-terminated
  traffic on the cellular WAN IP (ping from the WAN IP, 0% loss). VRF *can* be made
  to forward inbound with a stack of fixes (master-in-zone, catch-all route6,
  keep_addr_on_down sysctl, on-link SNAT, ICMPv6-allow) but still cannot do
  router-terminated WAN traffic or clean bidirectional dmz↔wan — it is only worth
  it for a strictly forward-only uplink. reference.md Variant 2 carries all the
  VRF fixes + caveats; Variant 1 remains the tested/recommended model.

## Device name as a first-class handle (2026-07-26)

- **Daemon write-back.** On `registered` the daemon materialises the resolved l3
  device name onto the interface as `option device` (`main.uc` `learn_device`,
  triggered in `daemon.uc` via `derive_netdev`; forward-declared to dodge the ucode
  TDZ trap). Idempotent, never clobbers a user value (device-name sovereignty),
  `commit`-only (no interface bounce). Off-switch `wwand_globals.write_device`
  (default on). Status now also reports `contexts[].l3_device`.
- **Config-path hardening (`config.uc`).** Both the native and compat paths now
  treat `device`+`mux_id` identically: a bare-netdev `device` + `mux_id` derives
  `<netdev>m<mux_id>` (regression: it named the child the same as the parent), and
  the compat path honours a separate `mux_id` (previously ignored). New
  `test_config` cases cover both; `test_daemon` covers the write-back.
- **rmnet kernel readback (C).** `io/src/wwand-io.c` gains `rmnet_mux_id(name)`
  (RTM_GETLINK + parse `IFLA_RMNET_MUX_ID`); `netlink.uc` reads it when adopting a
  pre-existing rmnet child on restart and warns on a config-vs-kernel mismatch.
  qmimux has no such attribute → stays daemon-remembered.
- **LuCI.** `wwand.js` stops stripping `interface.device` (it's the l3 handle now,
  not a legacy inline modem netdev) and adds an editable **L3 device** field
  (empty = daemon auto-fill, set = user override). `node --check` clean.
- All 31 host suites green (`test_config` 135, `test_daemon` 49).
- **HW-validated on 245 (RG650E/QMI, live Vodafone session):** wwand restart wrote
  `network.wwan0m1.device='wwan0m1'` (`learn_device` logged once) with **no
  connection bounce** (IP unchanged across two restarts); the C
  `rmnet_mux_id('wwan0m1')` read back `1` from the kernel; idempotent on the 2nd
  restart (no re-write). LuCI JS deployed (RW field pending a browser look).
  No-clobber is unit-tested (same early-return as the HW-proven idempotency).

## Deployment docs + IPv6-PD analysis (2026-07-26)

- **New `## Deployment examples` section** in `docs/reference.md`: a DMZ-host
  scenario (all inbound → one local v4/v6 host) in full dual-stack, with two
  routing variants — **policy routing** (`ip4table`/`ip6table`, netifd
  auto-generates the source `ip rule`s) and **VRF** (`config device type 'vrf'`).
  Documents the firewall/VRF specialities: fw4 is VRF-agnostic (zones bind to the
  member L3 devices, not the VRF master), `tcp_l3mdev`/`udp_l3mdev` is a **global**
  `config globals` switch, and the double-traversal caveat (`/etc/nftables.d/`).
  `docs/architecture.md` gained the netdev-recreate VRF-enslavement window note +
  an IPv6 addressing/PD subsection.
- **IPv6 prefix delegation — analysis + design + HW verdict.** Established that
  wwand does **no IA_PD** today (single WAN `/64`, RFC-7278 shared). True PD is a
  DHCPv6 IA_PD exchange with the P-GW, so the design is **PD on top**: a stacked
  `proto dhcpv6` interface (`device @wan`, `reqaddress none`, `reqprefix auto`)
  while wwand keeps owning the GUA. Feasibility knot found by reading odhcp6c
  (`10a52220`): it has **no source-address control** (binds `::`, sends to
  `ff02::1:2` with no `IPV6_PKTINFO` source), so the kernel picks the source
  (RFC 6724 → link-local if present).
- **HW test (245 Vodafone `web.vodafone.de`, 242 Telekom `nonbonding.hybrid`):**
  ran a PD-only `odhcp6c -N none -P 0` on `wwan0m1` with tcpdump. Default SOLICIT
  sources from **link-local** → **no response** on either carrier. Forced the
  **GUA** source (temporarily removed the interface LL — v6 gateway is global, so
  routing was unaffected) → SOLICIT now from the GUA, **still no response**.
  **Verdict: neither Vodafone DE nor Telekom DE answers DHCPv6-PD over the mobile
  bearer here — the source address is NOT the blocker, the network offers no PD.**
  Consequence: the **odhcp6c `-G` patch is not justified** (would not help) and the
  optional `ipv6_share_prefix` knob is unneeded — the **RFC-7278 `/64` sharing
  wwand already does is the correct and only mechanism** for these carriers. PD
  stays carrier-dependent as documented; other networks/business APNs may differ.
  Deployment docs (reference.md `## Deployment examples`) are the shipped
  deliverable; no odhcp6c/wwand code change needed. Plan (for reference):
  `~/.claude/plans/parallel-cooking-cloud.md`.

## SMS + fixes (2026-07-25)

- **SMS receive/list · read · delete** (no send) across all backends, HW-validated
  on 245 (RG650E) + 246 (EG06). New `sms_pdu.uc` (GSM 03.40 decoder — 7-bit incl.
  umlauts/UCS2/alphanumeric-sender/multipart, tested on real Vodafone PDUs),
  `codec/schema/wms.uc` (QMI WMS, vs libqmi 1.38), `sms.uc` (backend ladder: QMI
  WMS native/passthrough → native MBIM SMS → AT, probed by a real List so the
  RG650E's `MISSING_ARGUMENT` falls to AT), `modem_mbim._ensure_wms` (passthrough)
  + `mbim_backend.sms_read_all/sms_delete` (native `uuid_sms`, validated identical
  to passthrough on the EG06). ubus `modem_sms_list/read/delete`; LuCI SMS tab on
  Modem Tools. Tests: `test_sms_pdu`, `test_wms`, `test_sms`, `test_mbim_backend`.
- **Fix — telemetry/serving:** `_update_serving` replaced `self.reg` wholesale, so
  a cell-reselection SERVING_SYSTEM_IND that omits the optional Current-PLMN/roaming
  TLV wiped the operator line; now carried forward.
- **Fix — stuck-pending interface:** the `registered` handler treated a netifd
  `pending` interface (orphaned after a wwand restart mid-setup) as "down" and
  kicked it with a no-op `up`; now it `down`s a pending+IDLE interface first, then
  re-runs setup (HW-validated self-heal on 245).

_Earlier baseline: 27 suites (~1005 checks). Deep-review follow-ups #1/#2/#4/#5 +
minor-hardening done; #3 scaffolding consolidated._

## Next TODO — deep-review follow-ups (2026-07-23)

A full architecture/correctness/test review ran (codec verified clean vs libqmi
1.38 / libmbim 1.32 — no schema drift). The trivial-but-real bugs are **fixed**
(commit `222798d`): unbounded MBIM decode loops bounded, `ref-ipv4/ipv6` unpack
guarded, structural **never-SYNC rail** in `qmi_over_mbim.send` (+ test),
hotplug `cdc-wdm1`↔`cdc-wdm10` substring match → basename-exact, `self.dsd` CID
released on teardown. Remaining, ranked by value:

1. ✅ **DONE (`bc7a675`) — `test_daemon` 3 → 47 checks.** Root cause was a single
   missing mock handler (`GET_CURRENT_DATA_BEARER_TECHNOLOGY`): context bring-up's
   `get_bearer` hit mockhub's `die()`, which unwound `uloop.run()` from inside a
   uloop callback before any deferred ubus reply (or the 5 s guard) fired — so the
   whole no-proto-task lifecycle went untested while the suite showed "3 checks,
   0 failures". Added the handler + a **completion sentinel** (innermost callback
   sets a flag asserted after `uloop.run()`), so any future die-unwind now FAILS
   visibly instead of silently shrinking the check count.
2. ✅ **DONE (`ecf6953`) — recovery skippable rungs fixed.** Replaced exact
   `==8/16/24` rung matching with a **fired-once threshold crossing** over a
   persisted `rung` index: each rung fires once, in order, robust to a counter
   jump (never skips) and to a daemon restart mid-outage (rung index persisted;
   legacy state files default it from the restored attempt count). +12 tests.
   **Double-count finding:** empirically the common context-activation-failure
   path is **1:1** (each retry = one increment via the daemon `error` path); the
   modem `fail()` path only fires during bring-up (modem not READY), so the two
   callers are mutually exclusive there — the "~2×" does not reproduce. The
   narrow deregister-mid-session overlap stays theoretical, and the rung-crossing
   neutralizes its only real harm (skipped rungs). A true single-owner refactor
   of the counter is **not pursued** — low value, and the caller path is
   HW-critical WAN code better left untouched without HW validation.
3. **Three forked state machines → real shared core.** *Partially done — the
   three concrete duplications the review named are consolidated:*
   - ✅ zero-rx watchdog (3 copies) → `context_common.uc` (`zero_rx_limit_ms` +
     `rx_stall_watch`), commit `f09be7d`, +22 tests.
   - ✅ fast "watch" telemetry loop (2 copies, "Mirrors modem.uc") →
     `modem_common.watch_driver`, commit `e0d3b2e`, +12 tests.
   - ✅ `dsd_from_serving`/`dsd_from_radio` helpers → `modem_common`, commit
     `220130e`. The rest of the `_ca_be`/`_dsd_be` resolvers stays per-backend
     on purpose (candidate lists genuinely differ: `self.nas` vs the lazy
     passthrough `self.pt.nas`, plus MBIM's native candidate — folding them
     would add parameterisation without real dedup).

   **Scaffolding — now consolidated** (`805b97e`, `5c016ee`, `589120a`,
   `d8f1763`, `f7a5d2e`). `modem_common` grew a shared core the three modems now
   install instead of each carrying a copy:
   - `scaffolding(self, {deps,log,rec})` — `emit`/`notify_contexts`/`set_state`/
     `attach_context`/`note_connect_success`/`trip_zero_rx`/`stop`/`_device_gone`
     (all byte-identical before).
   - `make_fail(self, …)` — the `fail()`+backoff handler (was 3 near-copies; also
     fixed a real divergence — MBIM/NCM now emit the `'error'` event QMI always
     did).
   - `note_connect_failure_light(self, rec)` — the MBIM/NCM "light" recovery
     passthrough (QMI keeps its dms-cycling version).
   - `watch_driver` now drives the fast-telemetry cadence for **all three**
     (NCM was migrated too — it had the same loop).

   Net −68 LOC despite ~250 new test lines; the real win is one source of truth
   (test_modem_common 65 checks) + the divergence fix. **Remaining fork is
   genuine, not duplication:** the per-protocol step chains, `with_nas`, the
   teardown bodies (client destruction differs), and QMI's CID alloc/release —
   these are legitimately backend-specific and not worth forcing together.
4. ✅ **DONE (`d406ce4`) — `qmi_backend` telemetry suite.** New `test_qmi_backend`
   (24 checks), the QMI analogue of `test_mbim_backend`: each op (`get_ca`/
   `get_data_mode`/`get_reg_detail`/`get_packet_stats`/`get_bearer`/
   `get_channel_rates`) runs against a real QMI client on the mock hub, answered
   with a hand-built TLV block via a new mockhub `__raw` path (bypasses
   `tlv.pack`), so the schema's own decode runs — verified it bites (corrupting
   the pcell tag 0x13→0x33 fails the suite). mockhub also gained the DSD service.
5. ✅ **DONE (`11ceac7`) — at2 telemetry channel opened lazily.** `open_at` now
   stashes a one-shot opener; `modem_common.telemetry_at(self)` runs it on the
   first telemetry poll and returns the dedicated engine thereafter, else the
   control channel. QMI/MBIM only open at2 if/when they hit the AT fallback
   (often never); NCM opens it on its first tick (same end state). All telemetry
   sends route through `telemetry_at`. +16 tests.

Minor/latent hardening — **all done**:
- ✅ `client.uc` txn-collision: `alloc_txn` skips in-flight ids, never overwrites
  a pending slot (`e286623`).
- ✅ `hold_max` live on reload via `daemon.set_hold_max_ms` + status exposure
  (`4d759c5`).
- ✅ `wanted` cleared at the daemon-driven down (hold expiry + sim_blocked),
  closing the re-kick race (`c7116b1`).
- ✅ `encode_info` arrays now `die()` loudly instead of emitting a corrupt buffer;
  orphaned `encode_struct` removed (`5bee835`).
- ✅ modeswitch liveness watchdog: a non-re-enumerating usbnet switch is flagged
  in status (`control_note`) instead of silently unmanaged (`c36c706`).
  protoswitch left as-is — its failure is already visible (modem → `ABSENT` in
  status), user-initiated, and not once-guarded, so no silent-stuck class exists.
- ✅ deferred ubus replies routed through a `defer()` helper with a once-guard +
  backstop watchdog (300s; > any real op), so a dropped backend callback can't
  leak the request open (`e37fd1e`).

**Deferred (needs HW):** NCM ECM end-to-end (usbnet switch blocked on RG650E
firmware); Huawei/MeiG NCM telemetry recipes need bench verification.

## Multi-backend + parity work (recent, all committed)

wwand now has **three control backends** selected per modem by
`discovery.resolve_control` (cdc-wdm→qmi/mbim, cdc_ncm/cdc_ether→ncm, serial-only
→ppp with a one-time usbnet mode-switch), plus hotplug rediscovery
(`files/wwand.hotplug.net`).

- **MBIM → full CDC telemetry parity (HW-verified, EG06/246).** Shared AT
  bring-up (`modem_common.open_at`); a **QMI-over-MBIM passthrough** shim
  (`qmi_over_mbim.uc`) tunnels the whole QMI stack over the MBIM channel; native
  MBIM decode (`mbim_backend.uc` / MS Basic Connect Extensions); per-capability
  `backend.choose` (passthrough-first — reuses the trusted QMI decode; native
  MBIM as fallback). Live signal/cells/CA/data-mode over MBIM without disrupting
  the session. **Rule: never CTL SYNC over the passthrough** (memory
  `qmi-over-mbim-passthrough`).
- **NCM backend** (`modem_ncm.uc`/`context_ncm.uc`) — AT-controlled,
  cdc_ncm/cdc_ether datapath, IP via CGCONTRDP, multi-vendor dial (per-modem
  resolved: Quectel QNETDEVCTL→CGACT fallback, MeiG, Huawei, …), QICSGP auth.
  Core AT HW-validated on the RG650E; full ECM end-to-end HW test blocked
  (memory `ncm-backend-status`). Telemetry parity (multi-vendor) in progress.
- **Config parity + network selection** — `modem_get/set_settings` now protocol-
  neutral (MBIM via the passthrough NAS, HW-verified); `modem_scan` +
  `modem_set_network_selection` (NAS NETWORK_SCAN / AT COPS).
- **Init config validation** — `modem.validate_config` compares the live modem to
  config + `modem_quirks.uc`, surfaces `config_warnings` on status (gated
  `auto_correct`, default off).
- **LuCI settings editor** — band pickers, network-selection scan panel,
  cell-lock editing, config-warnings banner.
- **Empty/unset APN** — read the SIM/modem-provisioned APN, log it, use it (no
  blank write); attach APN reported on registration errors.

---

_Earlier robustness pass (committed): MBIM zero-rx watchdog + `hold_max` UCI._

## Where we are

The QMI path is production-shaped, unit-tested, and verified on three Quectel
modems: **242** RG502Q (Zyxel VA) and **245** RG650E (MikroTik Chateau) both
CONNECTED; **246** EG06 (Zyxel LTE3301) REGISTERING because its SIM is not
activated (correctly diagnosed as EMM #33 / limited service). The no-proto-task
model is HW-verified: transient losses hold + renew in place (IPv6-PD/VRF
survive), a wwand restart adopts the live session, permanent losses down the WAN.

Deploy to the fleet is a whole-`src-ucode` tar-over-ssh + non-destructive
restart (see `CLAUDE.md` → Test router). The proper path is the apk package.

## Done recently (all committed + pushed)

- **Attach profile before registration** — the modem attaches autonomously off
  CID1 before wwand activates its context, so wwand now programs the attach
  profile (apn + pdp_type) at init. Fixes the EMM-#33 wedge (Telekom rejects an
  IPv4-only / wrong-APN attach). `d152bce`.
- **Registration diagnostics** — `registration_detail` (reject cause + limited
  service) via QMI `GET_SYSTEM_INFO` + `AT+CEER`, on ubus + in the log. `d152bce`.
- **Invalid-response detection** — truncation → protocol error, `has_payload`
  gate, central sentinel table; neighbour-cell `-32768` normalised at the
  source. `aeff5bf`.
- **Config/LuCI audit** — added the missing form options + descriptions;
  **`disabled` / `auto` interface handling** (auto=0 is no longer force-upped).
- **Richer modem details** — UMTS/GSM signal, serving RSRQ/SINR, TAC/cell-id/
  timing-advance, CA SCell state/count, neighbour RSSI/Srxlev.
- **Refactors** — `merge_iface_modem_opts` (config), `setup_rmnet_links`/
  `setup_qmimux_links` (netlink), `_fetch_ca_info`/`_determine_data_mode`
  (fast_tick). `f1e50d5`.
- **IMSI/ICCID fallback** — UIM read_ef → DMS getters → AT (EG06 rejects EF reads).
- **Docs** — package reference (`wwand/README.md`) rewritten: config, no-proto-
  task, full ubus API, eSIM management & provisioning, telemetry/diagnostics,
  quirk handling, FAQ, troubleshooting. `94028f3` / `7acec96`.

## Multi-protocol backend abstraction (in progress)

Goal: one shared modem/context core driving pluggable protocol backends (QMI,
MBIM, AT-only) instead of the current two parallel implementations. Contract +
plan in `docs/backend-interface.md`.
- **Phase 0 (done):** the backend-interface contract doc; de-QMI'd the shared
  vocabulary (recovery `on_proto_error/success`, `counters.proto_errors`; status
  keeps a `qmi_errors` alias). Adoption path already covered by test_daemon (#4);
  the mock-backend core tests belong to Phase 1 (no core to plug into yet).
- **Phase 1 (in progress):** `qmi_backend.uc` now holds the QMI *leaf* ops —
  modem `read_info`/`get_ca`/`get_data_mode`/`set_opmode`/`get_reg_detail`, and
  context `get_channel_rates`/`get_bearer`/`get_packet_stats`/`stop_network`.
  These were the clean query→normalize→return and single-shot teardown ops.
  **Remaining piece — the activation core** (`context.up`: family loop, CID-per-
  family alloc, `BIND_MUX_DATA_PORT`/`SET_IP_FAMILY`/`START_NETWORK`, PDH,
  `PACKET_SERVICE_STATUS_IND`, settings shaping). **Re-evaluated 2026-07-23 —
  de-prioritized, and here's why:**
  - *Design is clear* (was not the blocker): both contexts already emit the
    neutral `{ipv4,ipv6,mtu}` settings shape + neutral events, and the daemon
    drives them polymorphically. The clean contract is a *thick*
    `backend.connect(config, profile, hooks) → settings + loss-signal` — QMI
    owns family-loop/CID/mux-bind/START_NETWORK/241-reclaim, MBIM owns
    CONNECT+IP_CONFIGURATION, the core owns state machine / gen-guard / prepare /
    stats / settings-poll / emit / reconnect.
  - *But low value, high risk:* the two state machines already share the neutral
    contract at their edges; the remaining activation *mechanism* is
    legitimately divergent (QMI = N WDS calls/family + PDH/mux; MBIM = one
    CONNECT). Forcing one core over that adds an abstraction fitting neither.
    And `test_context` protects only the QMI core — MBIM has stub unit tests but
    **no mockhub integration**, so a merge would run MBIM through the unified
    path with no net.
  - *Do it when it pays for itself:* the AT-only 3rd backend (a core over 3
    backends earns the abstraction) or a concrete divergence bug.
  - **Higher-value prerequisite — DONE:** `tests/lib/mbim_mockhub.uc` (an MBIM
    control-channel mock speaking the real framing) + `test_context_mbim.uc`
    drive `modem_mbim`+`context_mbim` end-to-end (bring-up → connect → IP decode
    → CONNECT-deactivate loss → reconnect → REGISTER deregister/suspend). MBIM
    now has the same integration net QMI has via `test_context`. This gates any
    future core merge; the merge itself stays deferred per the above.
  - Codec note surfaced while building the mock: **`mbim.encode_info` can't
    produce count+offset array responses** (or `ref-ipv4` gateways) — it's
    asymmetric with the fixed `decode_info`. Harmless in prod (arrays appear
    only in *responses*, which wwand decodes, never encodes); the mock hands
    such buffers in raw via a `{ __raw }` handler escape. Worth making symmetric
    if wwand ever needs to *emit* an array field.
- Phases 2–5: MBIM as a backend, daemon reach-ins behind ops, generalize
  `backend.choose`, AT-only backend. See the doc.

## Pending (not blocking anything)

- **`context.up` refactor** — subsumed by Phase 1 above (the context core split
  is where its nested 241-reclaim / v4-fatal-v6-degrades logic gets extracted,
  behind the mock-backend core tests).
- **Firmware update** — explored, not built. Tiered: ① carrier-config/MBN
  selection (`AT+QMBNCFG`, native, safe), ② FOTA delta (`AT+QFOTADL`, native
  orchestration), ③ full Firehose reflash via qfirehose (optional package,
  wwand orchestrates release→flash→re-adopt, like lpac). Start with ①.
- ~~`hold_max` UCI option~~ **done** — global `config wwand` option (seconds,
  default 90), parsed in `config.uc`, plumbed via `main.uc` into the daemon
  timing. Applied at start (a change takes effect on wwand restart).
- **MBIM zero-rx watchdog** **done** — `context_mbim` now samples MBIM
  `PACKET_STATISTICS` (cid 20) while CONNECTED and trips `zero_rx` on an rx
  stall, at parity with the QMI context (cdc_mbim carrier doesn't reflect a
  silent bearer stall, so this is the only backstop). HW-verified on the EG06
  (rx_bytes/rx_packets surface on `context_status`); tested in `test_context_mbim`.
- **MBIM — data plane now WORKS end-to-end on real HW (EG06/246).** Config
  `device wwan0` → compat parses mux_id 0 → MBIM **session 0** → raw `wwan0`
  netdev. netifd claims plain `wwan0` cleanly, the `qmi` shim applies the IP +
  default route, real public IP, ping works. Achieved with **zero wwand code
  changes** — raw wwan0/session 0, **no VLAN, no `config device`, no
  force_link**. The IP_CONFIGURATION decode fix (count+offset arrays) still
  applies; the RG650E rejects MBIM_OPEN so MBIM stays EG06-only.
  - The long "MBIM won't bind / VLAN / carrier flapping" saga was **two
    246-specific deploy artifacts, not code** — see auto-memory
    `mbim-datapath-findings`:
    1. Stale `/lib/netifd/proto/qmi-advanced.sh` (old bash dialer) still present;
       it also `add_protocol qmi` and **won** over wwand's `qmi.sh`, waiting on
       its own `/tmp/qmi/wwan0/device_initialized` marker. Remove it.
    2. `qmi.sh` deployed **without +x** (tar dropped the mode) → netifd couldn't
       exec it → **no `qmi` handler registered** → `proto: none` (up, no L3).
       `chmod +x` fixes it. The apk pkg is correct (`Makefile:54` INSTALL_BIN);
       only ad-hoc tar deploys lose it. **Always `chmod +x
       /lib/netifd/proto/qmi.sh` + `network restart` after a tar deploy.**
  - The earlier "netifd follows carrier destructively on no_proto_task"
    conclusion was **wrong** — that flapping was proto-none handler churn.
  - **Carrier finding:** on cdc_mbim a radio loss does *not* drop the netdev
    carrier, so netifd never reacts (address/route stay) but data is dead →
    wwand must detect loss via the **MBIM session/registration state**, not
    carrier. **Fixed:** `context_mbim.connect_indication` (routed from
    `modem_mbim` by session id) handles the unsolicited MBIM_CID_CONNECT
    deactivation — the MBIM analogue of QMI's `PACKET_SERVICE_STATUS_IND` — and
    emits `down`/`disconnected` into the same daemon reconnect-in-place path.
    Unit-tested (test_mbim); HW-deploy showed no regression (a real network-side
    deactivation is hard to trigger on demand — the EG06 ignores AT+CFUN in MBIM
    mode).
  - **EG06 MBIM quirk:** AT commands time out in MBIM mode (`AT+CFUN=0/1/?` all
    `at: timeout`); a `wwand restart` re-inits and recovers radio+session.
  - **Fixed:** a connect that failed after CONNECT activated used to leave the
    context activated → retry hit MBIM status 13 (max activated contexts).
    `context_mbim` now tracks an `activated` flag and DEACTIVATEs in `_fail`
    before reporting failure (shared `deactivate` helper with `down`). Tested.
  - (246 is currently in MBIM mode with `network.wan.device='wwan0'`; switch
    back to QMI needs `device 'wwan0m1'` + `AT+QCFG="usbnet",0`.)

## Notes

- QMI schemas must be audited against libqmi's `data/qmi-service-*.json` — a
  wrong tag silently decodes garbage. See `CLAUDE.md`.
- Project auto-memory covers the field findings (attach profile/#33, EG06 UIM
  read fallback, 5G-not-subscribed on the Hybrid SIM, backend.choose pattern).
