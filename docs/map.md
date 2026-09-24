# Where does wwand answer this question?

A **reverse index**: keyed by the question somebody debugging actually has,
not by subsystem. The other files here explain what the datapath *is*
(`architecture.md`, `datapath-interface.md`, `backend-interface.md`) and what a
config option *means* (`reference.md`). Between them they answer "what is X"
well and "which module prints this log line" not at all — and that second
question is the one that costs the time.

Every citation is `file symbol`, and `tools/check-map.py` resolves them. Symbol,
not line number: a line in a lookup table rots on every edit above it, while a
symbol survives refactoring inside a file and fails loudly when the thing is
renamed — which is exactly when the map is wrong.

If you had to grep for something and this table did not send you there, add the
row. That is the whole maintenance rule.

## Configuration: which value is actually in force

| Question | Answer |
|---|---|
| Which value wins for this connection — the card's, the interface's? | `context_common.uc conn_cfg` — per-ICCID `wwand_sim` first, interface second. The overridable set is one shared list, `context_common.uc SIM_OVERRIDABLE`. |
| Which IP family is the PDP actually using? | `context_common.uc effective_pdp` — reads the CONFIG, never the modem's read-back. |
| Which mux channel is really used (`auto` resolved)? | `config.uc effective_mux_id` |
| Which `wwand_sim` section matches the card in the slot? | `modem_common.uc match_sim_override` |
| What does a `proto qmi/mbim/ncm` interface become when migrated? | `config.uc migrate_plan` |

## The connection, from decision to netifd

| Question | Answer |
|---|---|
| Who decides to reconnect, and how long it holds the interface up? | `reconnect.uc enter_reconnecting`, `reconnect.uc retry_activate` — `daemon.uc` binds local aliases to them (`self._enter_reconnecting`), so grepping daemon.uc finds the call sites and not the logic. |
| What exactly is netifd told — addresses, routes, DNS, MTU? | `files/wwand-proto.sh _wwand_apply_settings` |
| Why does my interface have a default route with no gateway? | `files/wwand-proto.sh _wwand_apply_settings` — it branches on `IFF_NOARP`: a point-to-point link gets a device route, an ARP-resolving one a host route plus a via-default. Setup and renew both go through it. |
| Where does the dhcpv6 `<parent>_6` subinterface come from, and who switches it off? | `deps.uc ensure_wan6` / `deps.uc retire_wan6` — both dispatched from the connected handler in `daemon.uc`, on complementary `effective_pdp` conditions. |

## Telemetry, signal and cells

| Question | Answer |
|---|---|
| What is in the one-line telemetry log, and what do the fields mean? | `modem_common.uc format_telemetry` |
| **Which source produced those numbers?** | The per-metric ladder, chosen by `backend.uc choose`, which LOGS the winner once when it changes (`cells: answered by qmi\|mbim\|at`). It is **not** in `status` — see the note under § 8a in `extending.md`. Ask this BEFORE reasoning about a decoder: on a modem with QMI-over-MBIM passthrough the native MBIM cell decoder may never run. |
| How are MBIM cell metrics decoded? | `mbim_backend.uc get_cells`, with `mbim_backend.uc nr_convention` deciding per cell whether the NR block carries 7-bit report indices or direct physical values. |
| Why is a signal field blank rather than wrong? | Same place — a value no reading explains is refused. See `gotchas.md`, "two encodings in one MBIM message". |

## Recovery and hardware

| Question | Answer |
|---|---|
| What escalates, at which failure count? | `recovery.uc RUNGS` and `recovery.uc on_attempt` |
| Why did nothing happen although the count is past the threshold? | The arming gate in `recovery.uc on_attempt`: nothing physical until one request has completed in the selected protocol. `status` reports it as `recovery.armed`. |
| ...and the one exception to that gate? | `recovery.uc unarmed_reset_line` — a pulse of the modem's own named RESET line, once per outage, nothing else. |
| What would a repower do on THIS box for THIS modem? | `hwops.uc repower_plan` — the same precedence the action takes, so asking equals doing minus the doing. |
| Which GPIOs and LEDs does this board have? | `board.uc` profile table, keyed by `/etc/board.json` model id. |

## SIM, slots and eSIM

| Question | Answer |
|---|---|
| How many slots are there, and is that the modem's answer or ours? | `sim.uc slot_status` builds the rows; `sim.uc enumerated` says whether any row is a placeholder. A caller that ACTS on slot topology must ask the second. |
| Which transport carries APDUs on this modem? | `sim.uc apdu_backend` — MBIM UICC, then QMI UIM, then AT. `sim.power_cycle` deliberately uses the opposite order; the comments at both sites say why. |

## Status and ubus

| Question | Answer |
|---|---|
| What does `ubus call wwand status` expose? | `daemon.uc status` |
| Which ubus methods exist, and what may LuCI call? | `ubus.uc` (every method takes `ubus_rpc_session`) |
| **I cannot answer a reporter's question from `status`.** | That is a status gap, not an inconvenience — see `extending.md`, "when status cannot answer it". |

## Datapath

| Question | Answer |
|---|---|
| How is a mux child created, and which modes exist? | `netlink.uc`; the plug-in contract is `netlink.uc valid_plugin` and `datapath-interface.md`. |
| Why is my QMAP child not adopted by the vendor driver? | The `datapath_rmnet_nss*.uc` add-ons; they RETURN their implementation rather than registering it, because `require()` does not share module state. |
