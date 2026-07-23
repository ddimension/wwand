# wwand protocol backends

wwand supports more than one modem control protocol (QMI today, MBIM, and — as a
target — AT-only). This document defines the **backend interface**: the set of
protocol-neutral *operations* the modem/context lifecycle needs, so that one
shared state machine can drive any backend.

Status: this is the **target contract**. Today QMI (`modem.uc` + `context.uc`)
and MBIM (`modem_mbim.uc` + `context_mbim.uc`) are two parallel implementations
that already honour the same *event contract* and *settings shape* (which is why
`daemon.uc`, `ubus.uc` and the netifd shim are protocol-neutral). The migration
(see the end) collapses them onto a shared core that calls a backend for each
operation below.

## Concept

```
        daemon.uc / ubus.uc / netifd shim        (protocol-neutral)
                     │  events + settings shape + method surface
        ┌────────────┴─────────────┐
        │   modem/context CORE      │  lifecycle + policy: state machine,
        │   (one implementation)    │  timers, recovery ladder, hold/adopt,
        └────────────┬─────────────┘  telemetry orchestration, status assembly
                     │  backend operations (this document)
     ┌───────────────┼────────────────┐
   QMI backend    MBIM backend      AT backend
   (wds/nas/…)    (mbim cids)       (+CGACT/+CSQ/…)
```

The **core** owns everything protocol-neutral. A **backend** owns everything
below "issue operation X, call back with normalized data": wire framing,
service/CID management, TLV pack/unpack, error-code mapping, and the
`codec/schema/*` imports. The core never imports `codec/schema/*`.

## Backend operations

Each operation is `op(args, cb)` with `cb(err, data)`; `err` is `null` on
success or `{ error, ... }`; `data` uses the normalized shapes below. An
operation a backend cannot perform reports `{ error: 'unsupported' }` — the core
tolerates that (every optional capability is guarded and best-effort).

### Modem-level

| Operation | Purpose | QMI today | MBIM today |
|---|---|---|---|
| `open` | bring the control channel up | transport + `CTL SYNC` + version + per-service CID alloc | open + `MBIM OPEN` |
| `read_info` | model, revision, imei, manufacturer, capabilities | `DMS GET_*` | `DEVICE_CAPS` |
| `set_opmode(mode)` | online / low_power / offline / reset | `DMS SET_OPERATING_MODE` | radio-state (partial) |
| `slot_status` / `switch_slot(n)` | list / select physical SIM slots | `UIM GET_SLOT_STATUS` / `SWITCH_SLOT` | — |
| `sim_unlock(pin)` | query PIN state, verify, guard retries | `UIM`/`DMS` | `SUBSCRIBER_READY` + `PIN` |
| `read_identity` | imsi, iccid, msisdn | `UIM` EF read → `DMS` → AT | `SUBSCRIBER_READY` |
| `config_network(modes,plmn)` | mode/PLMN preference | `NAS SET_SYSTEM_SELECTION_PREFERENCE` | — |
| `ensure_attach_profile(apn,pdp)` | program the autonomous-attach profile | `WDS MODIFY_PROFILE` (CID 1) | folded into connect |
| `register` | wait for registration + subscribe indications | `NAS REGISTER_INDICATIONS` + `GET_SERVING_SYSTEM` + ind | `REGISTER_STATE` + `PACKET_SERVICE` |
| `reg_detail` | EMM reject cause + limited-service flag | `NAS GET_SYSTEM_INFO` + AT `+CEER` | — |
| `signal` / `cells` / `ca` / `data_mode` | telemetry | `NAS GET_SIGNAL_INFO`/`GET_CELL_LOCATION_INFO`/`GET_LTE_CPHY_CA_INFO`, `DSD GET_SYSTEM_STATUS` | `SIGNAL_STATE` (thin) |
| `location` | GNSS position | `LOC` service (broken on Quectel; AT+QGPS is the real path) | — |
| `teardown` | release clients/CIDs | `RELEASE_CID` + close | `MBIM CLOSE` |

### Context-level (per PDP / data session)

| Operation | Purpose | QMI today | MBIM today |
|---|---|---|---|
| `prepare(apn,auth,pdp)` | program the data profile | `WDS MODIFY_PROFILE` | folded into connect |
| `bind_mux(channel)` | bind the data port to a mux channel | `WDS BIND_MUX_DATA_PORT` | session id / VLAN |
| `activate(family)` | start a data session, return a handle | `WDS SET_IP_FAMILY` + `START_NETWORK` → pdh | `CONNECT set` |
| `settings(family)` | fetch assigned IP config | `WDS GET_CURRENT_SETTINGS` | `IP_CONFIGURATION` |
| `deactivate(family)` | stop a session | `WDS STOP_NETWORK` | `CONNECT` deactivate |
| `stats` | packet counters + channel rate + bearer tech | `WDS GET_PACKET_STATISTICS`/`GET_CHANNEL_RATES`/`GET_CURRENT_DATA_BEARER_TECHNOLOGY` | — |
| `on_lost` | connection-lost notification | `WDS PACKET_SERVICE_STATUS_IND` | `PACKET_SERVICE` ind |

## Normalized data shapes

The **settings** object is already the shared contract — both context
implementations produce it identically, which is what keeps netifd/ubus neutral:

```
settings = {
  ipv4: { addr, prefix, gateway, dns[], mtu } | null,
  ipv6: { addr, plen, gateway, dns[], mtu } | null,
  mtu,
}
```

Other normalized shapes the core expects from a backend (protocol-independent):
`info{model,revision,imei,manufacturer}`, `reg{registration,radio_ifs,roaming,
plmn{mcc,mnc,description}}`, `reg_detail{source,limited,reject_cause,reject_text}`,
`signal{lte{…},nr5g{…},wcdma{…},gsm_rssi}`, `cells{lte_intra,lte_inter,nr5g_cell,
ca,serving,…}`, `dsd{mode,lte,nr,source}`, and a normalized `nw_error{text,type,
code}` fed into the shared `callend.uc` text table (instead of raw QMI TLVs).

## Required vs optional

**Required** for a usable backend: `open`, `read_info`, `sim_unlock`,
`read_identity`, `register`, context `activate` + `settings` + `deactivate`,
`teardown`. **Optional** (report `unsupported`): `set_opmode`, slot switching,
`config_network`, `ensure_attach_profile`, `reg_detail`, `ca`/`data_mode`,
`location`, `stats`. The core degrades gracefully — e.g. an AT-only backend
implements the required subset and reports the rest unsupported.

## Event contract + status fields

Independent of protocol, a modem/context emits: `state`, `registered`,
`deregistered`, `serving_system`, `sim_blocked`, `removed`, `telemetry`,
`protocol_switch` (modem); `up`, `down`, `renew` (context). Status fields the
daemon reads off a modem object: `state`, `info`, `reg`, `reg_detail`, `signal`,
`counters{attempts,proto_errors}`. The recovery ladder (`recovery.uc`,
`on_proto_error`/`on_proto_success`) is protocol-neutral; only its rungs
(`opmode_cycle`, `modem_reset`) call a backend operation (`set_opmode`).

## Backend selection

Per modem: `option protocol 'qmi'|'mbim'|'auto'` (default `auto`), else the bound
USB driver decides (`discovery.protocol_of`: `qmi_wwan`→qmi, `cdc_mbim`→mbim).
The daemon instantiates the matching backend; MBIM is lazy-loaded so QMI-only
installs never pull in the MBIM code/schema. Per-capability fallback within a
backend uses `backend.uc` `choose()` (probe candidates once, cache the winner,
dispatch by name — already used for APDU/eSIM/CA/DSD transport).

## Migration (target)

1. **Phase 0 (done):** this contract; de-QMI the shared vocabulary
   (`on_proto_error/success`, `counters.proto_errors`); test scaffolding.
2. **Phase 1:** split `modem.uc`/`context.uc` into the shared **core** + a **QMI
   backend**; the 15 mockhub suites then validate the QMI backend + the core.
3. **Phase 2:** reframe `modem_mbim.uc`/`context_mbim.uc` as an **MBIM backend**
   on the shared core (kills ~750 duplicated lines; MBIM gains cells/stats/etc.
   where the backend can implement them).
4. **Phase 3:** move the daemon's remaining QMI reach-ins (`modem_get/set_settings`
   system-selection, SIM ops) behind backend operations; `sim.uc`/`callend.uc`
   take normalized inputs.
5. **Phase 4:** generalize `backend.choose` into the per-capability selector.
6. **Phase 5:** an **AT-only backend** implementing the required subset.
