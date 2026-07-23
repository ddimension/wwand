# wwand — status / continuation notes

_Last updated: 2026-07-23. 27 test suites green (~968 checks); all committed.
Three control backends (QMI, MBIM, NCM) behind one daemon-neutral contract.
Deep-review follow-ups below: #1/#2/#4/#5 + the full minor-hardening list done;
#3 partial (only the large state-machine-scaffolding unification remains)._

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

   **Remaining (the large part):** the modem *scaffolding* still forks —
   `emit`/`set_state`/`notify_contexts`/`attach_context`/`note_connect_*`/
   `fail`+backoff and the step-chain shape are parallel across `modem.uc`/
   `modem_mbim.uc`/`modem_ncm.uc`. `docs/backend-interface.md` describes the
   shared-core contract as the target. This is Phase 1/2 of the migration doc:
   large, staged, HW-critical — best done incrementally with a HW pass. Not yet
   started.
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
