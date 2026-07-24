# wwand package — configuration and API reference

wwand is an event-driven QMI/MBIM connection manager for OpenWrt, written in
ucode. It owns the modem's control port (`/dev/cdc-wdmX`), drives netifd, and
exposes a ubus API. This document is the reference for configuration, the ubus
API, diagnostics and troubleshooting. For the design rationale see
`architecture.md`.

## Configuration

**All configuration lives in `/etc/config/network`** (WireGuard-style). Three
wwand section types plus the netifd interface — no separate `/etc/config/wwand`
file for new setups:

- **`config wwand_modem '<name>'`** — the modem: hardware + primary SIM slot +
  default PIN + radio/cell/PLMN (device/netdev/usb_path, tty, mux, sim_slot,
  pincode, modes, mcc, mnc, lock_4g/5g/persist, at_init, location, delay,
  failreboot, zero_rx_timeout, stats_interval, dl_datagram_max_size).
- **`config wwand_sim '<name>'`** *(optional)* — a per-SIM override, matched at
  runtime to the inserted card by `option modem` + `option iccid`: overrides the
  modem's `pincode` and, optionally, `apn`/`auth`/`username`/`password` for that
  card (e.g. different eUICC profiles / dual-SIM with different PINs).
- **`config interface '<name>'`** with `option proto 'qmi'` — the connection:
  `option modem <name>` + `apn`, `pdp_type`, `auth`, `username`, `password`,
  `profile`, `mux_id` (0 = no mux, N = channel N), `mtu`, `use_pushed_mtu`,
  `use_pushed_prefix`, `settings_poll` + the usual netifd knobs. Several
  interfaces referencing one `wwand_modem` = multiple mux contexts on one modem.
- **`config wwand_globals 'globals'`** — `log_level`, `hold_max`.

```
config wwand_modem 'm0'
	option usb_path '1-1.2'
	option pincode '1234'
	option sim_slot '1'
	option modes 'lte,nr5g'

config wwand_sim 'vodafone'          # optional per-card override
	option modem 'm0'
	option iccid '89490...'
	option pincode '5678'
	option apn 'web.vodafone.de'

config interface 'wan'
	option proto 'qmi'
	option modem 'm0'
	option apn 'internet'
	option pdp_type 'ipv4v6'
```

**Precedence:** PIN = matching `wwand_sim.pincode` → `wwand_modem.pincode`;
APN/auth = `interface` → active `wwand_sim` → card-provisioned.

**Backward compatibility & migration.** The daemon still reads every older
wwand format: a legacy inline `proto qmi` interface, and the previous
`/etc/config/wwand` `modem`/`context` sections shown below. Nothing breaks.
Conversion to the model above happens automatically — a uci-defaults script runs
`/usr/libexec/wwand/migrate --apply` once on install/upgrade (it also converts
stock OpenWrt `proto mbim`/`proto ncm` interfaces, since `wwand-mbim`/`wwand-ncm`
replace those handlers), and saving in LuCI writes the new model too. Run the
migrate tool by hand any time (dry-run without `--apply`).

### Legacy: the `/etc/config/wwand` model

The previous model (still read for compatibility): `/etc/config/wwand` holds
`modem` and `context` sections; a netifd interface references a context by name
(`option context 'wan_ctx'`).

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

**`disabled` and `auto`** on the netifd interface are honoured:

- `option disabled '1'` — the interface is not linked to its context at all;
  the daemon never manages, kicks or reconnects it.
- `option auto '0'` — the daemon does **not** proactively bring the interface up
  on modem-ready (it only *adopts* it if it is already up, e.g. after a manual
  `ifup` or a wwand restart). With `auto '1'` (the default) the daemon kicks the
  interface up as soon as the modem registers.

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

## eSIM management & provisioning

eSIM support lives in the optional **`wwand-esim`** package
(`DEPENDS +wwand +wwand-lpac`). Without it the `modem_esim` methods answer
`{ "error": "esim_not_installed" }` and core wwand is unaffected.

wwand owns the eUICC's APDU channel and drives **ES10c** natively for profile
management (list / enable / disable / delete / EID). Profile **download** from
an SM-DP+ is delegated to **lpac** (shipped as the self-contained `wwand-lpac`,
bundled wolfSSL + libcurl): lpac runs the **ES9+ HTTPS** session to the SM-DP+
over the router's normal uplink — any existing WAN, **no dedicated provisioning
APN** — while the ES10 APDUs travel over wwand's channel (the daemon bridges
lpac's stdio APDU protocol inline). AT-only modems download internally instead
(Quectel `AT+QESIM`); `backend.choose` picks the transport per modem, since some
firmwares report the QMI logical channel as `NOT_SUPPORTED` and settle on AT.

All operations go through `modem_esim { modem, op, slot?, … }` (`slot` defaults
to 1):

| op | args | Description |
|---|---|---|
| `eid` | — | read the eUICC EID |
| `backend` | — | which transport the eUICC uses (`qmi` / `at`) |
| `profiles` | — | list installed profiles (ICCID, state, provider / nickname) |
| `enable` | `iccid` | enable a profile (eUICC REFRESH → SIM re-init → re-register) |
| `disable` | `iccid` | disable a profile |
| `delete` | `iccid` | delete a profile (guarded) |
| `download` | `activation_code`, `confirmation_code?`, `auto_notify?` | install a profile from an SM-DP+ (async) |
| `download_status` | — | poll a running download: `idle`/`running`/`done`/`failed` + live lpac log |
| `notifications` | — | list pending eUICC notifications (ES9+) |
| `notify` | — | send the pending notifications to the SM-DP+ |

**Provisioning a profile (download flow):**

1. Get an activation code from the operator —
   `LPA:1$<sm-dp+ host>$<matching-id>` (plus a confirmation code if required).
2. Start the download (async, returns immediately):
   ```
   ubus call wwand modem_esim '{"modem":"m0","op":"download",
     "activation_code":"LPA:1$smdp.example.com$ABC-123"}'
   ```
3. Poll until it settles:
   ```
   ubus call wwand modem_esim '{"modem":"m0","op":"download_status"}'
   ```
   With `auto_notify` (default on) wwand sends the ES9+ install notification to
   the operator after a successful download; otherwise run `op:"notify"` later.
4. Enable the new profile:
   ```
   ubus call wwand modem_esim '{"modem":"m0","op":"enable","iccid":"8988..."}'
   ```
   The eUICC issues a REFRESH; the SIM stack re-initialises and the existing
   recovery/registration path re-establishes the connection.

**Switching to the eSIM permanently:** set `option sim_slot` to the eUICC's
physical slot (so it is selected on every start) and enable the desired profile.
Activation codes and confirmation codes are validated for shell-safe characters
before reaching lpac.

The LuCI **Network → Modem** settings page surfaces the profile list,
enable/disable, the download form with live progress, and notification handling;
the eSIM sections hide themselves when `wwand-esim` is not installed.

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

## Quirk handling

wwand adapts to per-model firmware quirks through small **pattern-gated tables**
and **runtime capability probing** (`backend.choose`: try the QMI path, fall
back to AT, cache the decision per modem). Adding a modem usually means
extending a table, not branching the code.

| Quirk | Mechanism | Example |
|---|---|---|
| AT port discovery | 4-level fallback: `option tty` → board table → the `atport.uc` udev table (generated from ModemManager) → first-ttyUSB heuristic | — |
| Init AT commands | `MODEL_QUIRKS` (atcmd.uc): model pattern → commands run once before registration | EG06/EM06/RG50xQ → `AT+QMBNCFG="AutoSel",1` (carrier-config auto-select) |
| QMAP aggregation size | `board_dgram_size`: DL datagram size per model, then per board, overridable via `dl_datagram_max_size` | RG650E-EU → 31 KB (else 4 KB default) |
| QMAP DAP fallback | rmnet requests MAPv5 checksum offload, renegotiates plain QMAP when the modem declines aggregation | RG650E declines DAP 8 edge cases |
| eSIM host access | `esim_quirks`: some firmwares must have the internal LPA's `lpa_enable` disabled (one-time NV reset) so host-side ES10 APDUs work | RG65xx |
| Identity read | UIM raw EF read → DMS getter fallback | EG06 rejects EF reads → IMSI/ICCID via DMS |
| PIN unlock | UIM `VERIFY_PIN` → DMS fallback, with retry guards | — |
| Attach profile | CID1 programmed from config before the autonomous attach | avoids the EMM-33 IPv4-only / wrong-APN reject |
| Operator name | decoded whether plain ASCII or GSM-7 bit-packed (some modems pack the PLMN name) | EG06 |
| Protocol switch | QMI ⇄ MBIM via `AT+QCFG="usbnet"` (`modem_set_protocol`); the modem resets and re-enumerates | Quectel RG5xx/RG6xx/EG |
| MBIM firmware bug | some firmwares reject `MBIM_OPEN` — MBIM stays QMI-only there | RG650E |
| Serial drain | discard stray serial noise before AT on modems that need it | M9200B |
| Cell locking | Quectel `AT+QNWLOCK` for a fixed 4G anchor / 5G SA cell | `lock_4g` / `lock_5g` |

The known-model tables live in `atcmd.uc` (init + eSIM quirks), `netlink.uc`
(datagram size) and `protocol_switch.uc` (protocol recipes); capability probes
go through `backend.uc`.

## FAQ

**Does restarting wwand drop the connection?** No. A restart is non-destructive
(`stop_local`): the WAN and live traffic survive, and the daemon adopts the
running session once the modem reports `registered`. Only a full `shutdown`
(package removal) tears the session down.

**The modem sits in REGISTERING with good signal — why?** Read
`registration_detail`. An EMM reject cause (e.g. 33, "requested service option
not subscribed") means the *attach* was rejected, not that there is no coverage
— usually the attach APN or PDP type is wrong for the subscription. Check `apn`
and use `pdp_type ipv4v6` (some subscriptions reject IPv4-only).

**5G modem on a 5G cell but only LTE.** `modem_cells` → `dsd` with `nr: false`
means the network is not granting EN-DC for this SIM (the tariff is LTE-only /
DCNR-restricted). Nothing wwand or the modem can change.

**Two connections over one modem?** Give the modem two `context` sections with
different `mux_id` (and `apn`); QMAP multiplexing gives each its own `wwan0mN`
L3 device. All contexts of a muxed modem get a channel.

**Switch to an eSIM profile?** Install `wwand-esim`, download a profile
(`modem_esim op:download`), enable it (`op:enable`), and set `option sim_slot`
to the eUICC slot for a permanent switch — see
[eSIM management](#esim-management--provisioning).

**MBIM doesn't work on my modem.** Some firmwares (e.g. RG650E) reject
`MBIM_OPEN` — a firmware bug, not wwand; stay on QMI. Switch back with
`AT+QCFG="usbnet",0` + `AT+CFUN=1,1`, or `modem_set_protocol`.

**Old `proto qmi` config — do I need to migrate?** No, it keeps working via the
compat layer. To move to the native schema, run `/usr/libexec/wwand/migrate`
(dry run) then `--apply`.

**Lock to a specific cell?** `option lock_4g 'earfcn:pci'` (LTE) or
`option lock_5g 'pci:arfcn:scs:band'` (NR SA); `lock_persist 1` stores it in the
modem NV. The LuCI Modem page has a one-click "Lock this cell".

**Where are the recovery counters?** `/tmp/wwand/state/` — they survive a daemon
restart and clear on reboot (the recovery ladder's last rung).

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
