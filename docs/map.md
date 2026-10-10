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
| Which value wins for this connection — the card's, the interface's? | `context_common.uc conn_cfg` — per-ICCID `wwand_sim` first, interface second — except the login, which follows the APN: a `wwand_sim` with its own APN never takes the interface's credentials. The overridable set is one shared list, `context_common.uc SIM_OVERRIDABLE`. |
| Which IP family is the PDP actually using? | `context_common.uc effective_pdp` — reads the CONFIG, never the modem's read-back. |
| Which interface's APN and IP family go into the modem's attach profile? | `modem_common.uc attach_owner`: the interface that dials profile 1 (its default bearer IS the attach bearer), else one brought up automatically, else the first bound. Used by `modem_init_qmi.uc` (init), `modem.uc` (SIM reapply), `modem_mbim.uc` `_apply_attach` and `modem_ncm.uc` attach context 1. |
| Who sets the profile flags `ipv6_pd` / `clat` / `address_allocation`, and when are they left alone? | `context.uc check_pdp_type` (dial) and `context.uc ensure_attach_profile` (attach), both from the one table `context.uc PROFILE_FLAGS` via `context.uc flags_wanted` — read first, one MODIFY_PROFILE together with the pdp type; unset, or an IPv6-only flag on an ipv4 connection, is left alone. |
| Where does a delegated IPv6 prefix come from, and how does it reach netifd? | `context.uc read_delegated` (vendor WDS 0x00AC, the GET_DELEGATED_PREFIX entry of the WDS schema) on every IPv6 settings fetch, as `settings.ipv6.delegated`; `files/wwand-proto.sh _wwand_apply_settings` turns it into the netifd prefix and its sourced default route. On NCM: `ncm_vendors.uc read_pd_prefix` (Quectel `AT+QIP6CFG="PD_addr"`) from `context_ncm.uc with_delegated`, and the flag via `ncm_vendors.uc sync_pd` (dial path and `modem_ncm.uc step_attach`). |
| An interface stays down with DEVICE_CLAIM_FAILED behind a connected session — who fixes it? | `daemon.uc heal_device_claim` (on that error, from `modem_registered` and the renew probe) runs `deps.uc netifd_device_detour`; a half-done one is undone by `deps.uc detour_restore` at start (`main.uc`). |
| Where does the GNSS position come from — port or QMI LOC? | `daemon.uc modem_registered` decides (NMEA port when `gps_tty`, else `deps.uc gps_start_loc`); the LOC session is `gps.uc loc_session`, its client comes from the modem's `extra_client` and its LOC STOP runs from `modem_common.uc before_release` ahead of the RELEASE_CID. |
| Who sets the system clock, and when does it leave it alone? | `deps.uc set_clock` — one policy for both sources: NITZ (`modem_common.uc nitz_apply` — fed by QMI NAS, `modem_mbim.uc _query_nitz` and `+CTZV`; `option nitz_time`, default on) steps when the clock is more than `NITZ_TOLERANCE_S` off; GNSS (`option gnss_set_time`) only when it is pre-2021. The time zone is never set. |
| Which mux channel is really used (`auto` resolved)? | `config.uc effective_mux_id` |
| Which `wwand_sim` section matches the card in the slot? | `modem_common.uc match_sim_override` |
| What does a `proto qmi/mbim/ncm` interface become when migrated? | `config.uc migrate_plan` |
| Which band list does the modem run, and why did a `band_lte` do nothing? | QMI/MBIM keep bands in modem NV (`netsel_ops.uc install`, `modem_set_settings`); only a Fibocom FM350/FM150 applies `band_*`, through `ncm_vendors.uc gtact_set` at bring-up (`modem_ncm.uc apply_config_bands`) and live on reload (`daemon.uc apply_config`). A list nothing applies, or one that failed, is the `band_lists` warning from `daemon.uc band_warnings`. |
| What does a reattach do to the live sessions, and who brings them back? | `netsel_ops.uc install` (`modem_reattach`, `reattach_released`): every CONNECTED context is stopped first (`context.uc down`, reason `reattach`), `_reattaching` holds the daemon off (`daemon.uc on_context_event`, case `down`), then the backend `modem.uc reattach` / `modem_mbim.uc reattach` or AT COPS=2/0, then the daemon reconnect (`reconnect.uc install`, via the `sessions_released` event in `daemon.uc on_modem_event`). The order itself is `modem_common.uc scaffolding` (`with_sessions_released`), shared with the ladder's opmode cycle (`modem.uc note_connect_failure`, `modem_common.uc note_connect_failure_light`). |
| Why does an interface say DETACHED / why does a modem not re-register? | The operator detached it: `netsel_ops.uc install` (`modem_detach` / `modem_attach`, backend `modem.uc ps_attach` / `modem_mbim.uc ps_attach`, AT+CGATT otherwise). `detached` is honoured in the registration-loss paths (`modem.uc _update_serving`, `modem_mbim.uc _update_register`), the reconnect (`reconnect.uc install`) and `daemon.uc context_up`. |

## The connection, from decision to netifd

| Question | Answer |
|---|---|
| Who decides to reconnect, and how long it holds the interface up? | `reconnect.uc enter_reconnecting`, `reconnect.uc retry_activate` — `daemon.uc` binds local aliases to them (`self._enter_reconnecting`), so grepping daemon.uc finds the call sites and not the logic. |
| Why was my interface left down as "administratively down" — or brought back although it was down? | `daemon.uc operator_down` — a cleared autostart is the operator's only when context_down (or the shim, with no daemon to reach) recorded their ifdown; only on a start whose record is not trusted (`daemon.uc admin_record_complete`: first start since boot or an upgrade, or a damaged file) does "no `wwand` error" count, and that guess is recorded (`daemon.uc seed_admin_record`). `daemon.uc our_down` covers the downs wwand issues itself; an unrecorded down is looked at once more before it is undone (`daemon.uc confirm_then`). |
| How are `/tmp/wwand/state/admin_downs.json` and `giveups.json` written, and when is one not believed? | `daemon.uc write_state` (replaced whole through `netlink.uc default_fx`'s `write_atomic`); `daemon.uc merge_admin_record` folds in the names the shim appended (`files/wwand-proto.sh proto_wwand_teardown`); `daemon.uc admin_record_complete` decides trust; `daemon.uc admin_locked` holds the flock the shim's append takes too. |
| What exactly is netifd told — addresses, routes, DNS, MTU? | `files/wwand-proto.sh _wwand_apply_settings` |
| Why does my interface have a default route with no gateway? | `files/wwand-proto.sh _wwand_apply_settings` — it branches on `IFF_NOARP`: a point-to-point link gets a device route, an ARP-resolving one a host route plus a via-default. Setup and renew both go through it. |
| Where does the dhcpv6 `<parent>_6` subinterface come from, and who switches it off? | `deps.uc ensure_wan6` / `deps.uc retire_wan6` — both dispatched from the connected handler in `daemon.uc`, on complementary `effective_pdp` conditions. |
| Which code writes `/etc/config/network` on its own, and what does it leave alone? | `deps.uc autosetup_create` / `deps.uc autosetup_fill` (the first modem on an empty box), `deps.uc ensure_wan6`, `deps.uc sim_upsert` (a plugin's `wwsim_<iccid>` section, never a user's `wwand_sim`), and `deps.uc record_bands` (a settings-editor band edit on a modem that does not keep it, `daemon.uc persist_bands`). |

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
| How is a SIM re-read without a modem reset, and who keeps the modem watching for a swapped card? | `simops.uc modem_sim_reinit` (ubus `modem_sim_reinit`: `sim.uc power_cycle`, then `simops.uc card_changed`); hot-plug detection on a Quectel is the modem option `sim_detect`, applied as an init setting by `atcmd.uc sim_detect_commands`. |
| How many slots are there, and is that the modem's answer or ours? | `sim.uc slot_status` builds the rows; `sim.uc enumerated` says whether any row is a placeholder. A caller that ACTS on slot topology must ask the second. |
| Why was the SIM power-cycled with "sim … did not complete" in the log? | `sim.uc refresh_fallback`: the card announced a re-initialisation (QMI: `sim.uc install_refresh`, UIM REFRESH START; MBIM: `modem_mbim.uc _install_indications`, ready-state leaving INITIALIZED) and did not finish it within `refresh_end`; it gets the eSIM switch's apply. |
| Where does the status page's eUICC / IPA row come from? | `daemon.uc probe_euicc` (once per modem object, from the status tick) → `sim.uc card_euicc_info` (ISD-R SELECT answer, `fci_iot_info`; GetEUICCInfo1 6985 = IPAe) → status `euicc`. |
| Why did the recovery ladder not reset the modem although the rung was due? | `recovery.uc hold_for_card`, set by `daemon.uc modem_sim_refresh` when the identity changed on a card whose own IPA is in charge (`sim.uc card_euicc_info`, `fci_iot_info`); `option card_hold`. |
| How does a modem whose QMI / MBIM side hangs still get reset? | `modem_common.uc at_reset` (open AT engine, else the raw write `reset_stack_at`), from `modem.uc` (ladder rung + `self.reset`) and `modem_mbim.uc self.reset`. |
| Why did the AT port appear only minutes after the modem came up? | `modem_common.uc at_late_retry` — a port that was mute during bring-up is asked again (QMI `modem_init_qmi.uc step_at`, MBIM `modem_mbim.uc`). |
| Why did the accounting check say what it said? | `apntest/runner.uc acct_evaluate` (session lookup, `acct_state` bands), XML via `mccp_sessions`, the download in `check_accounting`. |
| What did the APN test box report, and why? | `apntest/runner.uc create` (`run_test`, `check_ping`, `fail_test`), plan validation `apntest/plan.uc parse`; last verdicts `/tmp/wwand-apntest/last.json` via `apntest_cli.uc cmd_last`. |
| Which transport carries APDUs on this modem? | `sim.uc apdu_backend` — MBIM UICC, then QMI UIM, then AT. `sim.power_cycle` deliberately uses the opposite order; the comments at both sites say why. |
| Who runs lpac, and who runs another host session on the card (a plugin's)? | Both through `esim_bridge.uc stdio_run`, which relays their stdio APDU protocol to the modem. lpac comes in through `lpac_run`, a plugin's process (e.g. an SGP.32 assistant) through `session_run`. Both hold the same claim, so the card only ever sees one host session. |
| Who sends the Profile Installation Result of an SGP.32 assistant's direct download to the SM-DP+? | lpac, through `esim_bridge.uc session_notify` (`notification process -r <seq>`), asked for by the assistant's `notify` event while its session waits; the download itself ran through `esim_bridge.uc session_download` without the notification step. |
| Why was a manual eSIM change refused (`esim_managed`)? | A plugin manages the card: `plugins.uc install` (its `esim_guard`), checked in `simops.uc ESIM_CHANGING`. `force` overrides. |
| How does an optional package hook into the daemon, the config and wwandctl? | `plugins.uc list` / `install` (tick, eSIM guard, ubus `modem_plugin`); its options arrive as `entry.ext` (`config.uc parse_network_sections`), outside the reload signature; its CLI command is `wwandctl.uc ctl_plugin`. |
| Which card is where, and why is one listed as not present? | `siminventory.uc from_modem` turns a modem's state into sources, `siminventory.uc create` derives each card from them; the daemon feeds it in `daemon.uc inventory_refresh`. A remote card is filed under its reader via `plugins.uc install` (`card_source`). |
| Why does this modem's radio stay off, and why is its ifup refused (`radio_held`)? | A plugin lent its card or waits for a remote SIM: `plugins.uc install` (`radio_hold`), consulted in the init chains before the radio can register (`modem_init_qmi.uc install`, step_opmode; `modem_mbim.uc create`, hold_at_open and step_register), in `daemon.uc context_up`, on `registered`, and before a dial (`reconnect.uc retry_activate`); the park itself is `daemon.uc plugin_radio` over each backend's `set_opmode` (`modem_mbim.uc create`: passthrough DMS, else Radio State), released on the tick when nothing holds it. A modem that cannot be held: `daemon.uc note_unholdable`, `status()` `radio_hold_error`. |
| Why was the eSIM profile list in status re-read? | `simops.uc profiles_changed`, fired by `esim_bridge.uc create` (`changed`) after a download or a profile change. |

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
| How does a `device 'qrtr'` modem reach its QMI, and when does it count as present or gone? | `qmi_over_qrtr.uc create` (the hub: CTL emulated, one socket per client, the name server's DEL_SERVER of DMS = gone); presence is `discovery.uc qrtr_probe` / `discovery.uc qrtr_pick_node`, gated in `daemon.uc start_modem`. |
| Which WDA endpoint (type, interface) does a modem get, and which QMAP version did it end on? | `netlink.uc ep_type_number` / `netlink.uc ep_iface_number` (from the resolved sysfs path of the data netdev; PCIe -> 4), a config `ep_type`/`ep_id` wins (`daemon.uc` passes them on); the version ladder and when it steps down is `modem_datapath_qmi.uc negotiate`. |
| Why is my QMAP child not adopted by the vendor driver? | The `datapath_rmnet_nss*.uc` add-ons; they RETURN their implementation rather than registering it, because `require()` does not share module state. |
