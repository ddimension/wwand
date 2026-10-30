<!-- SPDX-License-Identifier: GPL-2.0-only -->
<!-- Design note: recovering a modem with ONE dead QMI service. Analysis and
     options, not shipped behaviour — nothing below "Options" exists in code. -->

# One dead QMI service: why it is never recovered, and what would fix it

> **Design note, 2026-10-24.** Written against `main` at c82466c (after the
> #61 fixes). Nothing in "Options" is implemented; the decision between
> recovering and only reporting is open with the maintainer.

## The situation

A modem whose control channel works but on which **one** QMI service has stopped
answering. Seen on a Quectel RG520N-EB over QMI-over-QRTR (PCIe/MHI, IPQ5018):
after 7–8 h a service (NAS, going by the last log line — a timed-out
`GET_CELL_LOCATION_INFO`) stopped taking messages while DMS and WDS kept
answering, and the data path kept forwarding (ddimension/wwand#61, reporter's
logs 2026-10-18).

Over QRTR that is not a transient. The kernel counts unconfirmed DATA packets per
destination (node, port) and, at ten, sleeps every further sender until the
remote answers with RESUME_TX (`net/qrtr/af_qrtr.c` `qrtr_tx_wait` :288-291,
linux 6.18.41). RESUME_TX goes out when the remote READS a packet marked for
confirmation (`qrtr_recvmsg` :1073), so a service that stopped reading pins the
flow — and the counter lives in the kernel's node, not in any socket, so it
outlives the daemon. Only the endpoint going away (a modem or MHI reset) clears it.

Since e81d319 and c82466c wwand survives this: the send is bounded and answers
`'blocked'` (`io/src/wwand-io.c` `qmit_qsend`), the hub stops sending to that
service and probes it every 30 s (`src-ucode/qmi_over_qrtr.uc` `self.send`,
`self.blocked`), and requests it holds back in between fail as `'held'`, which
`client.uc` does not count as protocol errors. The daemon stays responsive.

What it does not do is **get the service back**.

## Why the recovery ladder never fires

Every QMI request that fails is one protocol error for the whole modem
(`modem.uc` client hook `on_error`, `src-ucode/recovery.uc:612` `on_proto_error`). Past
`proto_error_limit` (default 25, `src-ucode/config.uc:282`) the hardware rung fires — a
board repower, or with ddimension/wwand#65 a modem reset where no repower
exists (`src-ucode/recovery.uc:654-673`).

But the counter is **per modem**, and **any** answered request on **any**
service resets it to zero (`src-ucode/recovery.uc:710` `on_proto_success`, :717-721). With
NAS dead and DMS/WDS answering, it goes 1, 0, 1, 0 for as long as the modem
runs. The probes of the blocked service count (one error each), the answers of
the healthy ones undo them. The rung is unreachable by construction — correctly
for a flaky optional read, wrongly for a service that is gone for good.

## What a dead service costs

The data path usually keeps running (in #61 the WAN pinged at 33 ms throughout),
so nothing is down — but the modem is no longer manageable through that
service:

| Dead service | What stops working |
|---|---|
| WDS | reconnect after a drop, session/byte statistics, profile writes |
| NAS | registration and signal telemetry, network selection, band settings, the registration watchdog's information |
| DMS | modem reset over QMI, identity/firmware reads, operating-mode changes (reattach, low power) |
| UIM | SIM status, PIN handling, eSIM/APDU, slot switch |
| LOC, PDC, WMS, … | the feature behind it only |

So the question is not whether the box is broken, but whether wwand should
interrupt a working WAN to make the modem manageable again.

## Options

### 1. Count per service

Keep a streak per service: an error raises that service's count, an answer
resets only that service's. The rung fires when one service crosses the limit.

- Covers every transport, USB QMUX included, where a dead service shows as
  plain timeouts.
- Every service that fails persistently on some firmware becomes a modem reset
  with a WAN drop on that firmware. Most optional reads carry `no_recovery`, but
  that would have to be audited at every request site first, and a missed one is
  a reset loop in the field.

### 2. A "stuck" signal from the QRTR hub (recommended)

The hub already knows, as a fact rather than an inference, that a service is
blocked and since when (`self.blocked[svc].since`). It would report "service S
blocked for N minutes" to the modem, which then takes the hardware rung.

- Precise: fires only on the kernel condition that is known not to clear by
  itself, never on timeouts of unclear cause.
- QRTR only. USB QMUX has no flow control that can block; a dead service there
  remains a gap (option 1 territory).

Limits it would need:

- **Essential services only** — WDS, NAS, DMS, UIM. A dead LOC or PDC is
  reported, not acted on.
- **A long window** — about 10 minutes blocked (≈ 20 failed probes), so that a
  firmware sitting out a long command (a network scan) never trips it.
- **The right action for what is dead.** If DMS answers, a QMI modem reset (the
  modem leaves the bus, the kernel node and its pinned flows go). If DMS is the
  dead one, the reset cannot be sent over it: board repower, or on PCIe the MHI
  controller's `soc_reset` (`drivers/bus/mhi/host/init.c` `soc_reset_store`
  :117-128, linux 6.18.41; `/sys/bus/mhi/devices/mhi0/soc_reset`) — the latter
  would be new.
- **The usual guards** of the hardware rung: not while detached, parked,
  re-attaching, or while a plugin holds the radio.

### 3. Report only

Same detection as option 2, no action: the stuck service appears in `status`
(e.g. `qrtr_stuck: [ { service, since } ]`), in LuCI and once in the log, and
the operator decides. No surprise WAN drop, but a box nobody looks at stays
unmanageable until it is rebooted.

## Open decision

Option 2 with automatic recovery, or option 3 (report only). Either way the
detection is the same and small; the difference is whether wwand may trade a
working data path for a manageable modem without being asked.
