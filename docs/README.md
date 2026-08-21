# wwand documentation map

wwand is an event-driven ucode connection manager for OpenWrt cellular modems
(QMI, MBIM, NCM/AT behind one contract). This page is the index — start here,
whether you are a user, a developer, or an AI assistant working on the tree.

## Reading order by task

| I want to… | Read |
|---|---|
| Configure a router (APN, PIN, multi-modem, mux, VRF, IPv6) | [reference.md](reference.md) — config model, examples, workflows |
| Isolate the WAN in a VRF / run a DMZ | [vrf.md](vrf.md) — VRF & DMZ deep-dive |
| See the UI | [luci.md](luci.md) — a visual tour of the LuCI web app (screenshots + slideshow) |
| Understand what happens when it dials | [connection-flow.md](connection-flow.md) — the same connection from the wwand, modem and network side |
| Understand the design / internals | [architecture.md](architecture.md) — layering, mechanisms, invariants |
| Add a quirk, option, backend, telemetry, ubus method, board | [extending.md](extending.md) — one checklist per extension type |
| Write or port a control backend | [backend-interface.md](backend-interface.md) — the duck-typed modem/context contract |
| Know which modem exposes which telemetry | [telemetry-survey.md](telemetry-survey.md) — a dated, point-in-time survey |
| See what changed / current test counts / open items | [STATUS.md](STATUS.md) — running continuation log |

## The 60-second model

- **Config lives in `/etc/config/network`** (WireGuard-style): `wwand_modem`
  (hardware + PIN + radio policy), optional `wwand_sim` (per-ICCID/IMSI
  override), `interface … proto wwand` + `option modem` (the connection),
  `wwand_globals`. wwand coexists with the stock uqmi/umbim/comgt-ncm packages;
  migrate a stock `proto qmi/mbim/ncm` interface to wwand on demand from the LuCI
  modem list, with `/usr/libexec/wwand/migrate --apply`, or unattended at the
  next boot via the example uci-defaults script in `/usr/share/wwand/examples/`.
- **One daemon** (`/usr/sbin/wwand`) owns modems and contexts, drives netifd
  over ubus (`no_proto_task`), touches only the link layer — netifd owns all
  addressing/routing (VRF-safe).
- **L3 devices are named `wwand0`…`wwand100`** (stable, auto-assigned and
  written back to the config; explicit `option device` pins a name).
- Interfaces stay up across transient losses (reconnect-in-place, ~90 s
  hold); a recovery ladder (opmode cycle → modem reset → board
  power-cycle/reset GPIO → reboot) handles the rest.
- ubus API `wwand` (status, telemetry, netsel/scan, SIM/eSIM, SMS, reset) —
  full table in [reference.md](reference.md#ubus-api); LuCI apps
  (`luci-proto-wwand`, `luci-app-wwand`) sit on top of it.

## For AI assistants

- Source layout & invariants: repo-root `CLAUDE.md` (build/test/deploy,
  gotchas) and [architecture.md](architecture.md) §2 (layering).
- Never trust a QMI/MBIM field layout without checking it against the libqmi/
  libmbim JSON definitions — a wrong TLV/CID decodes garbage silently.
- Tests are the spec: `tests/run_tests.sh` (host, mocked I/O over the real
  codec). Every behavior change lands with a scenario; current counts in
  [STATUS.md](STATUS.md).
- The three backends implement one contract
  ([backend-interface.md](backend-interface.md)); prefer fixing shared code
  (`modem_common.uc`, `context_common.uc`, `backend.uc`) over per-backend
  copies, and keep backend parity when adding features.
