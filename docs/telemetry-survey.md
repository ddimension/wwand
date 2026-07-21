# Telemetry & statistics survey — QMI + Quectel AT (RG650E / SDX72)

Which QMI messages and Quectel AT commands carry *useful statistical / diagnostic*
information, what wwand already surfaces, and what is worth adding. Target modem:
Quectel RG650E-EU (Qualcomm SDX72), 5G NSA/SA.

## Already decoded / surfaced

| Source | Info | Where |
|---|---|---|
| NAS `GET_SIGNAL_INFO` (+ `SIGNAL_INFO_IND`) | RSSI / RSRP / RSRQ / SNR per RAT | `modem_signal`, status page, watch loop |
| NAS `GET_CELL_LOCATION_INFO` | serving + intra- **and inter-**freq LTE neighbours, NR5G serving cell, timing advance | `modem_cells`, status page |
| NAS `GET_SERVING_SYSTEM` (+ IND) | registration, PLMN, roaming, radio techs | `status`, status page |
| WDS `GET_PACKET_STATISTICS` | tx/rx **packets** only (mask 3) | zero-rx watchdog (not shown) |
| WDS `GET_CURRENT_SETTINGS` | IP / gateway / DNS / MTU | connections panel |
| DMS `GET_CAPABILITIES` | theoretical max tx/rx rate | (not shown) |

## Tier 1 — high value, worth adding

### 1. Call-end / activation error → code + text  *(explicitly requested)*
WDS `START_NETWORK` failure already returns **`call_end_reason`** and
**`verbose_call_end_reason`** (a *type* + *reason* pair). wwand captures both in the
error object but neither maps them to text nor retains them. Decode the verbose
reason type (3GPP / internal / CM / MIP / PPP) + code into a message table so the
log and status page can say "user authentication failed" / "missing or unknown
APN" / "operator determined barring" instead of a bare number. 3GPP SM causes worth
naming: 8 ODB, 27 missing/unknown APN, 29 user authentication failed, 31 activation
rejected, 32 service option not supported, 33 requested service option not
subscribed, 34 service option temporarily out of order. Retain a per-context
`last_error {code, type, text, ts}` and expose it via `context_status` + `status`.

### 2. Data usage + error counters
WDS `GET_PACKET_STATISTICS` also returns **tx/rx bytes, tx/rx dropped, tx/rx
errors, overflows** — wwand only reads packets. Widen the mask and surface bytes
(data usage per connection) and error/drop counters (link-quality signal) in
`context_status`. Alternative persistent counters: Quectel `AT+QGDCNT?` /
`AT+QGDNRCNT?` (bytes since last reset, survives call drops).

### 3. Per-antenna signal  *(antenna-alignment gold)*
`AT+QRSRP?`, `AT+QRSRQ?`, `AT+QSINR?` report values **per Rx branch** (Rx0..Rx3).
For the alignment status page this shows MIMO branch balance — a weak/dead antenna
branch is invisible in the aggregate RSRP but obvious per-branch. Highest-value
add for the page's actual purpose.

### 4. Bandwidth + SINR + band in one shot  *(long-standing open item)*
`AT+QENG="servingcell"` returns RAT, band, EARFCN/ARFCN, PCI, RSRP, RSRQ, **SINR**,
**bandwidth**, TAC in one line (LTE and NR). This fills the bandwidth gap the
cell-lock UI has today (`lc.bandwidth`/`nc.bandwidth` are already plumbed to accept
it). QMI alternative: NAS `GET_RF_BAND_INFO` (band + bandwidth authoritatively).

### 5. Carrier Aggregation  *(details you can't otherwise see)*
`AT+QCAINFO` (or QMI NAS `GET_LTE_CPHY_CA_INFO`) lists the **primary + secondary
component carriers**: band, EARFCN, bandwidth and state per CC. Shows how many
carriers are aggregated and how wide the pipe really is — very informative on
LTE-A / 5G-NSA.

### 6. Connection uptime / call duration
WDS `GET_CALL_DURATION` gives per-call uptime directly (no need to borrow netifd's).
Cheap per-context stat for the connections panel.

### 7. Temperature  *(thermal health)*
`AT+QTEMP` reports several sensors (PA, modem, etc.). 5G modems throttle on heat;
a temperature readout explains sudden rate drops. No standard QMI equivalent.

## Tier 2 — nice to have

- WDS `GET_CURRENT_CHANNEL_RATE` — instantaneous negotiated tx/rx channel rate.
- WDS `GET_DATA_BEARER_TECHNOLOGY` / `EVENT_REPORT_IND` — current bearer, NSA vs SA,
  dormancy transitions.
- `AT+QENG="neighbourcell"` — an additional neighbour-cell source (LTE + NR);
  sometimes lists cells QMI omits.
- `AT+QNWINFO` — access tech / operator / band / channel (compact summary).
- `AT+CESQ` — standard extended signal quality (RSRP/RSRQ/RSCP/EcNo).
- DMS `GET_OPERATING_MODE` — online / low-power / offline (already queried during
  init; could be surfaced).

## Notes on implementation

- The AT side channel (`atport.uc`) already exists and is used for cell-lock
  (`AT+QNWLOCK`) and MBN config; adding `QENG`/`QRSRP`/`QTEMP`/`QCAINFO` queries is
  incremental. Poll them in the existing watch loop (load-adaptive, ≤1/s) rather
  than on the 60 s telemetry tick when the status page is open.
- QMI additions (`GET_CALL_DURATION`, wider `GET_PACKET_STATISTICS`,
  `GET_RF_BAND_INFO`, CA info) avoid the AT round-trip and are cheaper; prefer QMI
  where it carries the datum, fall back to AT for what QMI lacks (bandwidth,
  per-antenna, temperature, CA detail on some firmwares).
- Everything new should flow through the existing `telemetry` event +
  `modem_signal`/`modem_cells`/`context_status` ubus surface so the LuCI page and
  the proto handler pick it up without new plumbing.
