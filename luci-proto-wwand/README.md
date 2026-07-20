# luci-proto-wwand

LuCI network-manager integration for the [wwand](../wwand) modem daemon.

It provides the JavaScript protocol handler for `proto 'qmi'` interfaces
(Network → Interfaces), using the current LuCI protocol API and talking to
the `wwand` ubus object directly for live data.

## Features

- Inline configuration of all wwand-relevant options (APN, PDP type, PIN,
  auth, radio modes, manual PLMN, MTU, resilience, GPS) — written to
  `/etc/config/network`, translated by wwand's compat layer.
- **Live modem status** in the interface form (model/IMEI, registration,
  operator, LTE/5G signal, serving cell) polled from `wwand status`,
  `modem_signal`, `modem_cells`.
- **Cell-lock tab** with the current cell environment — serving cell and
  neighbour cells with technology, band, frequency, signal (RSRP/RSRQ/SNR/
  RSSI) and the ready-to-use `earfcn:pci` lock value — plus the `lock_4g`,
  `lock_5g`, `lock_persist` fields.
- Modem-device dropdown populated from `wwand status` (netdev + model/IMEI).

Band and frequency are derived client-side from EARFCN (LTE) / ARFCN (NR).
Bandwidth is shown when the daemon reports it (`bandwidth` field on a cell).

## Installation

Registers protocol `qmi`, replacing the stock `luci-proto-qmi` — both install
`…/resources/protocol/qmi.js`, so only one can be installed. Remove
`luci-proto-qmi` first. Depends on `wwand`.

The ACL `root/usr/share/rpcd/acl.d/luci-proto-wwand.json` grants the LuCI
session read access to the `wwand` ubus object (status/modem_signal/
modem_cells/context_status).
