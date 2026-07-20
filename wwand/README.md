# wwand package — configuration and API reference

## Configuration

### Native schema

`/etc/config/wwand` holds modems and contexts; netifd interfaces in
`/etc/config/network` reference a context.

```
config wwand 'globals'
	option log_level 'info'          # err|warn|notice|info|debug

config modem 'm0'
	option device '/dev/cdc-wdm0'    # or: option netdev 'wwan0'
	                                 # or: option usb_path '1-1.2' (stable for multi-modem)
	option pincode '1234'
	option modes 'lte,nr5g'          # lte umts gsm nr5g td-scdma cdma / all
	option mcc '262'                 # manual network selection (optional)
	option mnc '01'
	option mux 'auto'                # auto|rmnet|qmimux|none
	option dl_datagram_max_size '0'  # QMAP aggregation; 0 = model/board table
	option tty ''                    # AT port override (autodetected)
	list at_init 'ATE0'              # extra AT commands at init
	option lock_4g '1300:246'        # earfcn:pci — LTE cell lock (repeatable)
	option lock_5g '242:431070:15:1' # pci:arfcn:scs:band — NR SA cell lock
	option lock_persist '0'          # store lock in modem NV
	option location '0'              # QMI LOC positioning session
	option stats_interval '60'       # telemetry period in seconds, 0 = off
	option delay '0'                 # wait before first init
	option failreboot '100'          # recovery ladder ceiling, 0 = ladder off
	option zero_rx_timeout '21600'   # no-rx watchdog, seconds, 0 = off

config context 'wan_ctx'
	option modem 'm0'
	option mux_id '1'                # QMAP channel; l3 device becomes wwan0m1
	option apn 'internet'            # or '#2' = use modem profile 2 untouched
	option pdp_type 'ipv4v6'         # ipv4|ipv6|ipv4v6
	option auth 'none'               # none|pap|chap|both
	option username ''
	option password ''
	option mtu ''                    # fixed MTU (else pushed MTU when enabled)
	option use_pushed_mtu '1'
	option use_pushed_prefix '0'     # keep network-pushed IPv4 prefix (default /32)
```

```
# /etc/config/network
config interface 'wan'
	option proto 'qmi'
	option context 'wan_ctx'
	option metric '10'               # metric/peerdns/defaultroute/ip4table/ip6table
	                                 # are handled by netifd as usual
```

Muxing rules:

- When any context of a modem is muxed, **all** its contexts get a channel
  (the QMAP parent device carries no IP traffic itself). Missing channels are
  auto-assigned; a warning names the assignment.
- A device name `wwan0m0` means "muxed, auto-assign the channel, keep this
  link name" (QMAP channel 0 itself is invalid).

### Old-style configurations (compat layer)

Interfaces with `proto qmi` and **no** `option context` are interpreted the
old way (options `device wwan0`/`wwan0mN`, `apn` incl. `#N`, `auth`,
`username`, `password`, `pincode`, `modes`, `mcc`/`mnc`, `ipv4`/`ipv6`/
`pdptype`, `mtu`, `use_pushed_mtu`, `at_init`, `location`, `delay`,
`failreboot`, `zero_rx_timeout`). They are translated in-memory at daemon
start; nothing is written back. `dhcp`, `autocreateif`, `customroutes` and
`strongestnetwork` are obsolete and ignored with a warning.

`/usr/libexec/wwand/migrate` prints the equivalent native configuration
(dry run); `--apply` writes it and strips the old options from the network
sections.

## ubus API

Object `wwand`:

| Method | Arguments | Description |
|---|---|---|
| `status` | — | modems (state, identity, registration, counters) and contexts |
| `reload` | — | re-read UCI and rebuild |
| `hotplug` | `action`, `device` | device add/remove notification (hotplug script) |
| `modem_signal` | `modem` | last signal info (LTE/NR5G/WCDMA metrics) |
| `modem_cells` | `modem` | registration + signal + decoded cell environment |
| `modem_location` | `modem` | last LOC fix |
| `modem_at` | `modem`, `command`, `timeout?` | run an AT command on the modem's AT port |
| `context_up` | `context` or `interface` | connect; deferred reply with full IP config |
| `context_down` | `context` or `interface` | disconnect |
| `context_status` | `context` or `interface` | state, per-family cid/pdh, settings |

Events: `wwand.modem` (`registered`, `deregistered`, `removed`,
`sim_blocked`), `wwand.context` (`up`, `down`, `renew`). The netifd shim's
monitor subscribes to `wwand.context` and lets netifd re-run the setup when
a context drops.

## Telemetry

With `stats_interval > 0` the daemon logs one compact line per interval and
caches the structured data (query via `modem_cells`):

```
telemetry: tech=LTE plmn=262/01 (Telekom.de) roaming=no
  lte=[plmn 262/01 tac 3071 gci 29582339 earfcn 1300 pci 246 rsrp -97.4 rsrq -10.9 neigh 2]
  sig_lte=[rssi -66 rsrp -98 snr 15.0]
```

The first sample runs ~5 s after registration (cell environment at connect
time), then at the configured interval. Cost: one QMI request per interval.

## Troubleshooting

- `option log_level 'debug'` in the globals section shows every state
  transition, CID allocation and QMI error.
- `ubus call wwand status` / `context_status` for a live snapshot.
- `ubus call wwand modem_at '{"modem":"m0","command":"AT+QENG=\"servingcell\""}'`
  for ad-hoc modem diagnostics.
- Recovery counters live in `/tmp/wwand/state/` and survive daemon restarts
  (cleared by reboot — the ladder's last rung).

## Development

```
wwand/tests/run_tests.sh    # host-side suites, no hardware required
```

Needs a host ucode with the fs/struct/uloop modules (and ubus/uci plus a
`ubusd` binary for the daemon integration suite — it is skipped otherwise).
The mock hub drives the real codec; reproduce field issues as scenarios.

`tools/gen-atport-table.py <modemmanager-checkout> > src-ucode/atport.uc`
regenerates the AT port table from ModemManager's udev rules.
