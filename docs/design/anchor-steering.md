# Anchor steering — a supervised, volatile LTE cell lock

Status: implemented (`src-ucode/steering.uc`), measured 2026-11-21 on the
NR7101 (Quectel RG502Q-EA, Telekom card). First run: QMI PCI scan refused,
QSCAN, lock on 6400/381 serving after 3 s, EN-DC after 39 s, `save_ctrl` read
back 0,0 while locked; a daemon restart left the lock to the init, which
released it; switching steering off released it and wrote `save_ctrl` 1,1.

## The problem

A fixed CPE camps on the LTE cell the network's idle-mode rules favour, and
that cell need not advertise EN-DC. The NR7101 sat on a strong B20 cell
(6300/334, RSRP −62 dBm) that broadcasts **262/02** while the card is
registered on 262/01: a cell another operator hosts. Its SIB2 carries no
upperLayerIndication, so the modem never shows 5G, and its SIB5 ranks B20
above every other layer (B20 = 3, B3/B7 = 0), so the modem never measures, let
alone reselects to, the operator's own cells.

`AT+QSCAN=1,1` found those cells: Telekom B20 6400/381 at −79 dBm, B8
3749/116, B3 1300/342 and 1444/482 near −95 dBm. Locked to 6400/381 the modem
reported `nsa_available` after 8 s and an NR5G-NSA leg on n1 (ARFCN 431070,
PCI 242) as a secondary carrier next to the B20 PCC, without a single lost
ping. A phone on the same card finds that cell on its own (connected-mode
mobility while it moves); a CPE that never moves does not.

## Rules

1. **Carrier aggregation is never restricted.** Steering moves the primary
   cell only; no band is ever excluded, not even briefly. Band locks are out,
   including for discovery.
2. **The lock is volatile.** On Quectel `AT+QNWLOCK="save_ctrl"` is global NV
   and wwand leaves it at 1,1 after every release, so ANY lock — the QMI one
   too — survives a power cycle (a GPIO reset kept the QMI lock, 2026-11-21).
   A steering lock is preceded by `save_ctrl 0,0`; the release restores what
   `lock_persist` asks for.
3. **Every lock has a deadline.** The target must be the serving cell and the
   modem registered with data within `T_acquire` (15 s), or the lock is
   cleared. A lock on a cell that is not there costs data at once: 6400/500
   (no such PCI) dropped data after 3 s and left the modem in SEARCH, then
   limited service on another operator's cell, for as long as the lock stayed.
   Clearing it brought data back within 10 s, all PDN sessions held.
4. **Lost while locked → clear.** Serving cell ≠ target, registration lost or
   limited, RSRP below the floor for N s, or a data stall (zero-rx/TX stall)
   — and before any recovery rung runs, so the ladder never fights a lock
   wwand set itself.
5. **Clean slate.** At every init a lock the config does not ask for is
   released. That already exists (`cell_lock.sync`, measured: "modem reports
   a 4G cell lock the config does not ask for — releasing it" after the reset
   above) and is what makes a crash safe.
6. **A configured lock wins.** With `lock_4g`/`lock_5g` set, steering is off.
7. **No ping-pong.** A target that missed its deadline or brought no anchor
   is blocked for hours; attempts are rate-limited.
8. **Not during a call, not during a scan-sensitive moment.** No lock change
   while a VoLTE call is up; discovery scans only when idle-ish and rarely
   (a QSCAN costs ~16 s of data).
9. **Roaming.** A GDSP or other global roaming card is steered within the
   visited network it is registered on, never onto another PLMN's cell (that
   would force a PLMN reselection). A visited network that gives the SIM no
   EN-DC makes every candidate fail: such a round doubles the wait (up to 8
   intervals); a new registered network resets the block list.
10. **No files.** The learned table, the block list and the state live in the
   daemon and are published over ubus; a restart learns again.

## Mechanism, in order of preference

| Step | Primary | Fallback | Measured |
|---|---|---|---|
| Discover cells | QMI NAS Perform Network Scan 0x0021, scan type 3 (PCI) with an LTE band mask | `AT+QSCAN=1,1` | QMI type 3/4 refused (70 / 48) by the RG502Q-EA and the RG650E-EU, at once and without a data gap; QSCAN answered in 26 s, ~16 s without data |
| Lock | QMI `SET_CELL_LOCK_CONFIG` 0x00AF (u16) / `SET_CELL_CONFIG` 0x00D8 (u32), `enforce` 1 — the existing `cell_lock.uc` `qmi` dialect | `AT+QNWLOCK="common/4g"` | 0x00AF on the RG502Q-EA: on the target in 4 s, no data lost |
| Release | the same message with an empty list | `AT+QNWLOCK="common/4g",0` | 0x00AF empty list: back on the old cell, data in 10 s |

The steering lock calls `cell_lock` with dialects `[ QMI, QUECTEL ]`; the
config lock keeps `[ QUECTEL, QMI ]`. Not chosen, both measured 2026-11-21 and
listed in `docs/qmi-beyond-libqmi.md`: LTE band priority (0x0080/0x0083: set
and read back, but a camped modem stays where it is, after a radio cycle too)
and Force LTE Scan (0x00DB: accepted, no effect).

## State machine (per modem, in memory)

    off ──enable──▶ idle ──due──▶ scanning ──cells──▶ choosing
                     ▲                                  │ best target
                     │                                  ▼
                 backoff ◀──clear(reason)── locked ◀── locking (T_acquire)
                                              │
                                              └─ verified: anchor seen within T_anchor

- **choosing**: candidates = scanned cells of the registered PLMN (hosted
  cells of another PLMN rank last), RSRP ≥ floor (default −105 dBm) and not
  worse than the current cell by more than `max_drop` (default 20 dB), not
  blocked. Ranked: seen with an anchor > unknown; then RSRP.
- **locking → locked**: target serving and registered within `T_acquire`.
- **verified**: `nsa_available` within `T_anchor` (60 s); otherwise clear,
  block the cell ("no anchor") and try the next candidate once.
- **locked** is supervised on every fast-telemetry tick (rule 4).
- **backoff**: exponential, capped (default 6 h); a new scan only then.

## Config (`config wwand_modem`)

    option anchor_steering 'off'      # off | auto
    option steer_rsrp_min '-105'      # dBm floor for a target
    option steer_scan_interval '21600' # s between discovery scans

## Status and UI

`status.modems.<m>.steering = { state, target: 'earfcn:pci', since, reason,
candidates: [ { earfcn, pci, band, plmn, rsrp, anchor } ], blocked: [ … ] }`,
and `cell_layers` (serving layer with the network's reselection parameters,
the listed inter-frequency layers, `shared` when the cell's PLMN is not the
registered one) — the LuCI status page shows both, so the reason a modem
camps where it does is visible without AT commands.
