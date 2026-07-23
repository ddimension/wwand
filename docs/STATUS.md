# wwand — status / continuation notes

_Last updated: 2026-07-23. 16 test suites green (~510 checks). Committed through
the MBIM datapath/loss-detection/mockhub work. Uncommitted: a robustness pass —
MBIM zero-rx watchdog + `hold_max` UCI option (commit on request)._

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
