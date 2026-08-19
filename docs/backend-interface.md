# wwand protocol backends

**One lifecycle state machine drives three shipped wire protocols behind an
identical duck-typed contract.** QMI, MBIM and NCM/AT modems all present the same
modem and context objects — same events, same normalized `settings` shape, same
method surface — so `daemon.uc`, `ubus.uc` and the netifd shim never learn which
protocol is underneath. The most striking proof of the abstraction: MBIM even
**tunnels the whole QMI stack over itself** (the QMI-over-MBIM passthrough — see
below), reusing the QMI backend byte-for-byte over an open MBIM channel.

All three backends are **shipped and HW-validated**:

- **QMI** — `modem.uc` + `context.uc` (native QMUX; the reference backend).
- **MBIM** — `modem_mbim.uc` + `context_mbim.uc` (native MS Basic Connect
  Extensions **plus** the QMI-over-MBIM passthrough).
- **NCM/AT** — `modem_ncm.uc` + `context_ncm.uc` (no rich control protocol at
  all: the modem is driven entirely over an AT channel, with per-vendor recipes).

They run on a **shared core** (`modem_common.uc` + `context_common.uc`) and honour
one **event contract** and one **settings shape**. This document defines that
contract: the protocol-neutral *operations* the modem/context lifecycle needs, and
how each backend fulfils them.

> **QMI-over-MBIM passthrough — never CTL SYNC.** The passthrough tunnels the full
> QMI service stack through the MBIM `QMI` service. Bring it up with
> `GET_VERSION_INFO` + `ALLOCATE_CID` only — **never send CTL SYNC over it**: that
> resets the modem's embedded QMI state and kills the live MBIM data session
> (HW-proven on the EG06; structurally blocked in `qmi_over_mbim.send`).

## Concept

```
        daemon.uc / ubus.uc / netifd shim        (protocol-neutral)
                     │  events + settings shape + method surface
        ┌────────────┴─────────────┐
        │   modem/context CORE      │  lifecycle + policy: state machine,
        │  (modem_common /          │  timers, recovery ladder, hold/adopt,
        │   context_common)         │  telemetry orchestration, status assembly
        └────────────┬─────────────┘  backend operations (this document)
     ┌───────────────┼────────────────┐
   QMI backend    MBIM backend      NCM backend
   (wds/nas/…)    (mbim cids +      (AT: +CGDCONT/
                   QMI passthrough)  +CGACT/+CEREG/…)
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

Two deliberate convention splits exist in the backends — both are on purpose,
do not "fix" one side to match the other:

- **Callback shape.** Mutating / must-succeed operations use `cb(err[, data])`
  (`set_opmode`, `stop_network`, sim/esim/sms ops). *Normalized-telemetry
  getters* use the result-only form `cb(result | null)` (`get_ca`,
  `get_data_mode`, `get_bearer`, `get_channel_rates`, `get_reg_detail`,
  `read_info` and the mbim_backend equivalents): a telemetry failure is not an
  error the caller can act on — null simply means "nothing to display" and the
  poll loop moves on.
- **First argument.** `qmi_backend`/`mbim_backend` operations take the bare
  protocol *client* (`set_opmode(dms, …)`, `get_ca(nas, …)`) and never touch
  modem state — they are pure wire adapters. The stateful service layers
  (`sim.uc`, `esim.uc`, `sms.uc`) take the whole `modem` because they choose
  transports (`backend.choose`/`first_of`), read `modem.config`/`active_sim`
  and update `modem.info`.

### Modem-level

| Operation | Purpose | QMI | MBIM | NCM (AT) |
|---|---|---|---|---|
| `open` | bring the control channel up | transport + `CTL SYNC` + version + per-service CID alloc | open + `MBIM OPEN` | open the AT tty (this *is* the control channel; optional usb-serial `new_id` bind) |
| `read_info` | model, revision, imei, manufacturer, capabilities | `DMS GET_*` | `DEVICE_CAPS` | `ATI`/`CGMI`/`CGMM`/`CGMR` + `CGSN` (imei); manufacturer selects the vendor recipe |
| `set_opmode(mode)` | online / low_power / offline / reset | `DMS SET_OPERATING_MODE` | radio-state (partial) | `AT+CFUN` (reset = `AT+CFUN=1,1`) |
| `slot_status` / `switch_slot(n)` | list / select physical SIM slots | `UIM GET_SLOT_STATUS` / `SWITCH_SLOT` | — | vendor `slots` recipe (Fibocom `AT+GTDUALSIM`, switch + CFUN reset) |
| `sim_unlock(pin)` | query PIN state, verify, guard retries | `UIM`/`DMS` | `SUBSCRIBER_READY` + `PIN` | `AT+CPIN?` + `AT+CPIN="…"`; retries via `AT+QPINC` |
| `read_identity` | imsi, iccid, msisdn | `UIM` EF read → `DMS` → AT | `SUBSCRIBER_READY` | `AT+CIMI` (imsi) + `AT+QCCID`/`+CCID`/`+ICCID` chain |
| `config_network(modes,plmn)` | mode/PLMN preference | `NAS SET_SYSTEM_SELECTION_PREFERENCE` | — | AT (`AT+COPS`; `with_nas` is null → daemon uses the AT path) |
| `ensure_attach_profile(apn,pdp)` | program the autonomous-attach profile | `WDS MODIFY_PROFILE` (CID 1) | folded into connect | `AT+CGDCONT` (+ vendor auth: `QICSGP`/`CGAUTH`/…) on CID 1 |
| `register` | wait for registration + subscribe indications | `NAS REGISTER_INDICATIONS` + `GET_SERVING_SYSTEM` + ind | `REGISTER_STATE` + `PACKET_SERVICE` | poll `AT+CEREG?` → `AT+C5GREG?` → `AT+CREG?` (5G-SA aware), with registration URCs (`+CREG`/`+CEREG`/…, Fibocom) as a poll fast path |
| `reg_detail` | EMM reject cause + limited-service flag | `NAS GET_SYSTEM_INFO` + AT `+CEER` | — | vendor `reg_detail` block (AT; best-effort) |
| `signal` / `cells` / `ca` / `data_mode` | telemetry | `NAS GET_SIGNAL_INFO`/`GET_CELL_LOCATION_INFO`/`GET_LTE_CPHY_CA_INFO`, `DSD GET_SYSTEM_STATUS` | `SIGNAL_STATE` + QMI-over-MBIM passthrough (full parity) | per-vendor AT block (`telemetry_ncm.uc`): `CSQ`, `QENG="servingcell"` (rsrp/rsrq/sinr/bandwidth), `QCAINFO` (CA), `QRSRP`/`QSINR` (per-branch); Fibocom `GTCAINFO`/`GTCCINFO` (CA SCCs); `data_mode` from the QENG serving line |
| `location` | GNSS position | `LOC` service (broken on Quectel; AT+QGPS is the real path) | — | — |
| `teardown` | release clients/CIDs | `RELEASE_CID` + close | `MBIM CLOSE` | close the AT engine(s) |

### Context-level (per PDP / data session)

| Operation | Purpose | QMI | MBIM | NCM (AT) |
|---|---|---|---|---|
| `prepare(apn,auth,pdp)` | program the data profile | `WDS MODIFY_PROFILE` | folded into connect | `AT+CGDCONT` + vendor auth (idempotency-guarded against `AT+CGDCONT?`) |
| `bind_mux(channel)` | bind the data port to a mux channel | `WDS BIND_MUX_DATA_PORT` | session id / VLAN | — (plain cdc_ncm/cdc_ether/rndis_host netdev, no mux) |
| `activate(family)` | start a data session, return a handle | `WDS SET_IP_FAMILY` + `START_NETWORK` → pdh | `CONNECT set` | resolved vendor "dial" binds the netdev to the bearer (`QNETDEVCTL`/`NDISDUP`/…, falling back to `CGACT`) |
| `settings(family)` | fetch assigned IP config | `WDS GET_CURRENT_SETTINGS` | `IP_CONFIGURATION` | `AT+CGCONTRDP=<cid>` via the per-vendor `ip_config` hook (e.g. the Fibocom T700 path: `CGPADDR` address, gateway-less, + CGCONTRDP DNS; the embedded-v4 form is extracted on BOTH the CGPADDR and the CGCONTRDP parser paths but deliberately NOT applied on an ipv6-only PDP — 3GPP: `pdp ipv6` means no host v4, the network's 464XLAT CLAT stays in the modem) — always STATIC from the modem, DHCP is never used; a modem that reports no MTU falls back to the netdev's own `/sys/class/net/…/mtu` |
| `deactivate(family)` | stop a session | `WDS STOP_NETWORK` | `CONNECT` deactivate | vendor dial disconnect (`QNETDEVCTL=0`/`CGACT=0`/…) |
| `stats` | packet/byte counters + channel rate + bearer tech | `WDS GET_PACKET_STATISTICS`/`GET_CHANNEL_RATES`/`GET_CURRENT_DATA_BEARER_TECHNOLOGY` | — | vendor byte counter (`QGDCNT`/`DSFLOWQRY`) feeds the zero-rx watchdog |
| `on_lost` | connection-lost notification | `WDS PACKET_SERVICE_STATUS_IND` | `PACKET_SERVICE` ind | AT poll (dial-status query, else `AT+CGPADDR` liveness), plus unsolicited `+CGEV` PDN DEACT pokes where the modem sends them (Fibocom T700) |

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
`location`, `stats`. The core degrades gracefully — the shipped NCM/AT backend is
exactly this case: it implements the required subset over AT and simply has no
GNSS (slot switching comes via the vendor `slots` recipe where one exists),
which the core tolerates.

## Event contract + status fields

Independent of protocol, a modem/context emits: `state`, `registered`,
`deregistered`, `serving_system`, `sim_blocked`, `removed`, `telemetry`,
`protocol_switch` (modem); `up`, `down`, `renew` (context). Status fields the
daemon reads off a modem object: `state`, `info`, `reg`, `reg_detail`, `signal`,
`counters{attempts,proto_errors}`. The recovery ladder (`recovery.uc`,
`on_proto_error`/`on_proto_success`) is protocol-neutral; only its rungs
(`opmode_cycle`, `modem_reset`) call a backend operation (`set_opmode`).

## Backend selection

Per modem: `option protocol 'qmi'|'mbim'|'ncm'|'auto'` (default `auto`), else the
bound USB driver decides (`discovery.protocol_of`: `qmi_wwan`→qmi, `cdc_mbim`→mbim,
`cdc_ncm`/`cdc_ether`→ncm). The daemon instantiates the matching backend; **all
three backends are lazy-loaded** (`qmi_lazy`/`mbim_lazy`/`ncm_lazy` shims,
`require()`d on first use) and ship in their own package, so an install pulls in
only the code/schema for the backends it needs. Per-capability fallback within a
backend uses `backend.uc` `choose()` (probe candidates once, cache the winner,
dispatch by name — used for APDU/eSIM/CA/DSD transport, and for the NCM dial-method
resolution).

## Status (realized)

The contract above is implemented across all three backends:

- **Shared core** — `modem_common.uc` (state/context scaffolding, `make_fail` +
  backoff, the adaptive telemetry `watch_driver`, AT bring-up, lazy `at2`) and
  `context_common.uc` (zero-rx watchdog) are installed by every backend instead
  of being duplicated.
- **QMI** (`modem.uc` / `context.uc`) — the reference backend, native QMUX.
- **MBIM** (`modem_mbim.uc` / `context_mbim.uc`) — runs on the shared core with a
  native MS-BasicConnect decoder plus a **QMI-over-MBIM passthrough** that reuses
  the QMI backend + schemas (hence `wwand-mbim` DEPENDS `wwand-qmi`).
- **NCM** (`modem_ncm.uc` / `context_ncm.uc`) — the AT-only backend (the
  "AT-driven" backend: its datapath is a plain `cdc_ncm`/`cdc_ether`/
  **`rndis_host`** netdev, so RNDIS modems like the Fibocom FM350-GL need no
  separate backend). Per-vendor `VENDORS` dial/auth/**ip_config**/telemetry
  recipes in `ncm_vendors.uc` (Quectel, Fibocom, Huawei, Meig, SIMCom, Sierra,
  Sony, Samsung, ZTE, MikroTik, MediaTek, Spreadtrum/Unisoc, Telit, Gosuncn,
  Neoway + a 3GPP-standard fallback); registration polls `AT+CEREG?` →
  `AT+C5GREG?` → `AT+CREG?` (5G-SA aware); bearer liveness comes from the
  vendor byte counter, the dial's status query, or a universal `AT+CGPADDR`
  poll for modems that have neither. Assigned IP config is always STATIC from
  the modem (CGCONTRDP, or the vendor `ip_config` hook — e.g. CGPADDR on the
  T700) — DHCP is never involved. RNDIS datapaths come up with ARP disabled
  (NOARP), so the gateway-less /32 device route needs no neighbour
  resolution.
- Daemon reach-ins are behind backend ops (`with_nas`), and per-capability
  telemetry/config is chosen at runtime by `backend.choose`
  (native → passthrough → AT), cached per modem.

Adding a fourth backend is a matter of the same contract + a lazy shim + a
package — see [extending.md](extending.md#3-adding-a-control-backend).
