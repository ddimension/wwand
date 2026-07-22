# wwand package — configuration and API reference

wwand is an event-driven QMI/MBIM connection manager for OpenWrt, written in
ucode. It owns the modem's control port (`/dev/cdc-wdmX`), drives netifd, and
exposes a ubus API. This document is the reference for configuration, the ubus
API, diagnostics and troubleshooting. For the design rationale see
`../docs/architecture.md`.

## Configuration

`/etc/config/wwand` holds `modem` and `context` sections; netifd interfaces in
`/etc/config/network` reference a context by name.

### Modem section

```
config wwand 'globals'
	option log_level 'info'          # err|warn|notice|info|debug

config modem 'm0'
	option device '/dev/cdc-wdm0'    # control port; or `option netdev 'wwan0'`
	                                 # or `option usb_path '1-1.2'` (stable across
	                                 #   renumbering on multi-modem setups)
	option tty ''                    # AT port override (auto-detected otherwise)
	option pincode '1234'            # SIM PIN; entered on each start
	option sim_slot '0'              # physical slot to activate (0 = leave as-is)
	option modes 'lte,nr5g'          # lte umts gsm nr5g td-scdma cdma / all / unset
	option mcc '262'                 # manual PLMN selection (optional, needs mnc)
	option mnc '01'
	option mux 'auto'                # auto|rmnet|qmimux|none — QMAP datapath backend
	option dl_datagram_max_size '0'  # QMAP DL aggregation bytes; 0 = model/board table
	list at_init 'ATE0'              # extra AT commands, sent once before registration
	option lock_4g '1300:246'        # earfcn:pci — LTE cell lock (repeatable / list)
	option lock_5g '242:431070:15:1' # pci:arfcn:scs:band — NR SA cell lock
	option lock_persist '0'          # store the cell lock in modem NV
	option location '0'              # start the QMI LOC positioning session
	option stats_interval '60'       # telemetry period in seconds (0 = off)
	option delay '0'                 # seconds to wait before the first init
	option failreboot '100'          # recovery-ladder ceiling (0 = ladder off)
	option zero_rx_timeout '21600'   # no-rx watchdog in seconds (0 = off)
```

### Context section

```
config context 'wan_ctx'
	option modem 'm0'
	option mux_id '1'                # QMAP channel; the L3 device becomes wwan0m1
	option profile '1'               # 3GPP profile (CID) for the attach + bearer
	                                 #   (default: mux_id, else 1)
	option apn 'internet'            # or '#2' = use modem profile 2 untouched
	option pdp_type 'ipv4v6'         # ipv4|ipv6|ipv4v6
	option auth 'none'               # none|pap|chap|both
	option username ''
	option password ''
	option mtu ''                    # fixed MTU (else the pushed MTU when enabled)
	option use_pushed_mtu '1'        # apply the network-advertised MTU
	option use_pushed_prefix '0'     # keep the pushed IPv4 prefix (default: /32 p-t-p)
	option settings_poll '300'       # re-check pushed IP/DNS/MTU every N s (0 = off)
```

`/etc/config/network`:

```
config interface 'wan'
	option proto 'qmi'
	option context 'wan_ctx'
	option metric '10'               # metric / peerdns / defaultroute / ip4table /
	                                 #   ip6table / VRF are handled by netifd as usual
```

**Attach profile.** Before registration, wwand programs the LTE **attach
profile** (CID `profile`, normally 1) from the primary context's `apn` +
`pdp_type`, so the modem's *autonomous* attach uses the right settings. A stale
attach profile (wrong APN, or IPv4-only where the subscription needs IPv4v6)
otherwise gets the attach rejected with EMM cause 33 and registration wedges —
see [Troubleshooting](#troubleshooting).

**Muxing rules.**
- When any context of a modem is muxed, **all** its contexts get a channel (the
  QMAP parent device carries no IP traffic itself). Missing channels are
  auto-assigned; a warning names the assignment.
- A device name `wwan0m0` means "muxed, auto-assign the channel, keep this link
  name" (QMAP channel 0 itself is invalid).

### Old-style configurations (compat layer)

Interfaces with `proto qmi` and **no** `option context` are read the old way
(options on the interface section: `device wwan0`/`wwan0mN`, `apn` incl. `#N`,
`auth`, `username`, `password`, `pincode`, `modes`, `mcc`/`mnc`, `ipv4`/`ipv6`/
`pdptype`, `mtu`, `use_pushed_mtu`, `sim_slot`, `at_init`, `lock_4g`/`lock_5g`/
`lock_persist`, `location`, `delay`, `failreboot`, `zero_rx_timeout`,
`stats_interval`). They are translated in memory at daemon start; nothing is
written back. `dhcp`, `autocreateif`, `customroutes` and `strongestnetwork` are
obsolete and ignored with a warning. A `disabled` interface is skipped entirely.

`/usr/libexec/wwand/migrate` prints the equivalent native configuration (dry
run); `--apply` writes it and strips the old options from the network sections.

## netifd integration (no-proto-task)

The proto handler sets `no_proto_task=1`: after setup the interface stays
`IFS_UP` with **no monitor process**. The **daemon owns the context lifecycle**
and drives netifd over ubus:

- **Transient loss** → the interface is held up, the session reconnects, and the
  daemon issues an in-place `renew` (no teardown → IPv6-PD / VRF preserved).
  Bounded by `hold_max` (~90 s), then `down`.
- **Permanent loss** (`sim_blocked`, admin/config down) → `down` immediately.
- **wwand restart is non-destructive** (`stop_local`, not `shutdown`): WAN and
  live traffic survive; the daemon **adopts** the running session on `registered`.

The daemon touches only the link layer (mux/MTU/carrier, sysctl); **all**
addressing and routing go through netifd, so `ip4table`/`ip6table`/VRF apply.

## ubus API

Object `wwand`. Every method also accepts `ubus_rpc_session` (injected by rpcd
when called from LuCI).

| Method | Arguments | Description |
|---|---|---|
| `status` / `modem_list` | — | modems (state, identity, registration, `registration_detail`, counters) + contexts |
| `reload` | — | re-read UCI and rebuild |
| `set_log_level` | `level` | change the log level at runtime |
| `hotplug` | `action`, `device` | device add/remove (from the hotplug script) |
| `modem_signal` | `modem` | last raw signal info (LTE/NR5G/WCDMA/GSM metrics) |
| `modem_cells` | `modem` | registration + `registration_detail` + signal + decoded cells + `dsd` + `ca` |
| `modem_location` | `modem` | last QMI LOC fix (when `location` is enabled) |
| `modem_at` | `modem`, `command`, `timeout?` | run an AT command on the modem's AT port |
| `modem_get_settings` / `modem_set_settings` | `modem`, `settings?` | NAS system-selection prefs (modes/bands) — the settings editor |
| `modem_plmn_lists` | `modem` | preferred/forbidden PLMN lists |
| `modem_sim_slots` | `modem` | physical slots: card presence, active, ICCID, eUICC flag, EID |
| `modem_sim_switch_slot` | `modem`, `slot` | switch the active physical SIM slot (drops the connection) |
| `modem_sim_pin_lock` | `modem`, `pin`, `enable` | enable/disable the SIM PIN lock (QMI first, AT fallback; idempotent) |
| `modem_esim` | `modem`, `op`, … | eSIM (list/enable/disable/eid/download/…); needs the optional `wwand-esim` package |
| `modem_apdu` | `modem`, `op`, … | raw ISO-7816 APDU channel (advanced) |
| `modem_set_protocol` | `modem`, `protocol` | switch the control protocol (`qmi` ⇄ `mbim`); the modem resets |
| `context_up` / `context_down` | `context` or `interface` | connect / disconnect (deferred reply with the IP config) |
| `context_status` / `context_settings` | `context` or `interface` | state, per-family cid/pdh, IP settings |

**Events.** The daemon broadcasts `wwand.modem` (`{ modem, event, … }`, events
`registered` / `deregistered` / `sim_blocked` / `removed` / …) and
`wwand.context` (`{ context, interface, event }`, events `up` / `down` /
`renew`). These are for observers (e.g. LuCI); netifd itself is driven directly
by the daemon (see above), not via an event subscription.

## Telemetry & diagnostics

With `stats_interval > 0` the daemon logs one compact line per interval and
caches the structured data (query it via `modem_cells`):

```
telemetry: tech=LTE plmn=262/01 (Telekom.de) roaming=no
  lte=[plmn 262/01 tac 3071 gci 29582339 earfcn 1300 pci 246 rsrp -97.4 rsrq -10.9 neigh 2]
  sig_lte=[rssi -66 rsrp -98 snr 15.0]
```

The first sample runs right after registration (cell environment at connect
time), then at the configured interval.

**registration_detail** — when registration is stuck or in limited service, the
daemon collects *why* and exposes it on `status` / `modem_cells` (and logs a
warning). QMI (`GET_SYSTEM_INFO`: limited-service flag + EMM reject cause) is
combined with `AT+CEER` (clear-text cause) — they are complementary, since many
modems leave the QMI reject cause empty but report limited service:

```json
"registration_detail": { "source": "qmi+at", "limited": true,
                         "reject_cause": 33,
                         "reject_text": "requested service option not subscribed" }
```

**Data-system mode** — `modem_cells` → `dsd { mode, lte, nr, source }` reports
the actual data system (`LTE` / `NSA` / `SA`) from the QMI DSD service, falling
back to the QENG serving line (AT) and then the coarse NAS radio interfaces.
`source` names which path answered.

**Invalid-response handling** — wwand recognises structurally-valid-but-unusable
QMI answers instead of caching garbage: a truncated decode is treated as a
protocol error; empty poll replies keep the last-known data; the per-type
"not available" sentinels (`-32768`, `0xFFFFFFFF`) are normalised to null on
signal and on every serving/neighbour cell at ingestion, so the UI shows "—"
rather than e.g. `-3276.8 dBm`.

## Troubleshooting

- `option log_level 'debug'` (globals) shows every state transition, CID
  allocation and QMI error. `set_log_level` changes it at runtime.
- `ubus call wwand status` / `context_status` for a live snapshot.
- `ubus call wwand modem_at '{"modem":"m0","command":"AT+QENG=\"servingcell\""}'`
  for ad-hoc modem diagnostics.
- Recovery counters live in `/tmp/wwand/state/` and survive daemon restarts
  (cleared by reboot — the ladder's last rung).

**Stuck in REGISTERING / limited service.** Read `registration_detail`. EMM
cause **33** ("requested service option not subscribed") on a good signal is an
**attach** rejection, not a coverage problem: the attach profile's APN/PDP type
is not what the subscription allows. wwand programs the attach profile from the
context config before registration; if it persists, check `apn` and `pdp_type`
(some subscriptions reject an IPv4-only attach — use `ipv4v6`).

**No 5G despite a 5G modem on a 5G cell.** If the modem is 5G-enabled and camps
on a valid NSA anchor but never gets an NR carrier, `modem_cells` → `dsd` shows
`nr: false`: the network is not granting EN-DC for this subscription
(DCNR-restricted / the tariff excludes 5G). Not a wwand or modem issue.

**SIM.** `modem_sim_slots` shows slot/card/eUICC state; `option sim_slot`
selects the physical slot; `modem_sim_pin_lock` enables/disables the PIN lock.
`SIM_BLOCKED` is terminal until a config reload (PIN guard tripped, no card, or
PUK required).

## Development

```
wwand/tests/run_tests.sh    # host-side suites, no hardware required
```

Needs a host ucode with the fs/struct/uloop modules (and ubus/uci plus a
`ubusd` binary for the daemon integration suite — skipped otherwise). The mock
hub drives the real codec; reproduce field issues as scenarios.

**QMI schemas must match libqmi.** Verify every message id and TLV id against
libqmi's `data/qmi-service-*.json` (request TLVs vs `input`, response vs
`output`, resolve `common-ref` ids) — a wrong tag silently decodes garbage.

`tools/gen-atport-table.py <modemmanager-checkout> > src-ucode/atport.uc`
regenerates the AT port table from ModemManager's udev rules.
