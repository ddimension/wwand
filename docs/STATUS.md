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
- **MBIM** — first validated on real HW (EG06/246): control plane works
  (open/caps/SIM/**registration**) and the data session now **connects with the
  correct IP** after fixing the IP_CONFIGURATION decode (count+offset arrays —
  it had only ever been host-tested against the wrong layout; the RG650E rejects
  MBIM_OPEN so it never ran). Remaining: after a *live* QMI→MBIM protocol switch,
  netifd doesn't bind the IP (interface stays down). Two datapath-integration
  issues, both confirmed on a fresh boot into MBIM (246):
  1. **VLAN not declared to netifd.** The config `device 'wwan0m1'` is the QMAP
     name; under MBIM it's an 802.1q VLAN of wwan0. netifd reports NO_DEVICE
     until the VLAN is declared as a `config device` (type 8021q, ifname wwan0,
     vid 1) — then `available:true`. Fix belongs in the MBIM datapath / migrate
     (emit the device section, or use netifd's `wwan0.1` naming, or mark the
     wwand-created VLAN external).
  2. **cdc_mbim carrier flapping (chicken-and-egg).** The raw wwan0 carrier
     follows the MBIM session state; netifd waits for link-up before running the
     proto handler (which is what connects the session), so wwan0/wwan0m1 flap
     up/down and the interface never settles. The MBIM datapath/proto flow needs
     to establish the session (carrier) independently of netifd's link wait.
  Also latent: a connect that fails after CONNECT activated leaves the context
  activated, so the retry hits MBIM status 13 (max activated contexts) —
  deactivate before retry. (246 currently carries an ad-hoc `config device
  mbimvlan` from this investigation.)

## Notes

- QMI schemas must be audited against libqmi's `data/qmi-service-*.json` — a
  wrong tag silently decodes garbage. See `CLAUDE.md`.
- Project auto-memory covers the field findings (attach profile/#33, EG06 UIM
  read fallback, 5G-not-subscribed on the Hybrid SIM, backend.choose pattern).
