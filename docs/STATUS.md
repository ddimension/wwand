# wwand — status / continuation notes

_Last updated: 2026-07-22. All work committed + pushed to origin; working tree
clean; 15 test suites green (~480 checks)._

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
- **Phase 1 (next):** split `modem.uc`/`context.uc` into the shared core + a QMI
  backend (mockhub suites then validate both). Big lift, test-protected.
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
- **`hold_max` UCI option** — currently a 90 s default; the `timing` struct is
  not plumbed through `main.uc` in production (tests set it via TIMING).
- **MBIM** end-to-end blocked on RG650E firmware (`MBIM_OPEN` fails); the code
  is written + host-tested, lazy-loaded. Needs MBIM-capable HW to validate.

## Notes

- QMI schemas must be audited against libqmi's `data/qmi-service-*.json` — a
  wrong tag silently decodes garbage. See `CLAUDE.md`.
- Project auto-memory covers the field findings (attach profile/#33, EG06 UIM
  read fallback, 5G-not-subscribed on the Hybrid SIM, backend.choose pattern).
