# wwand — status / continuation notes

_Last updated: 2026-08-12. All test suites green (42 suites).
Three control backends (QMI, MBIM, NCM) behind one daemon-neutral contract._

## MHI/PCIe: MBIM-only modem misdetected as QMI (2026-08-14, HW-found)

Forum tester (LS3434) ran wwand on a PCIe/MHI RM520N: `device_claim_failed`,
`failed in sync: { "error": "timeout" }`, recovery ladder climbing. The modem
exposes `wwan0at0` / `wwan0mbim0` / `wwan0qcdm0` over MHI — **no `wwan0qmi0`**.
Root cause: `discovery.protocol_of()` classified the control device only by its
bound driver (`qmi_wwan`/`cdc_mbim`), but an MHI control node's driver is
`mhi-pci-generic`, so it returned null → `resolve_control` fell through to the
`'qmi'` default → the daemon ran QMI CTL SYNC against an MBIM-only port → sync
timeout. Fix: `protocol_of` now reads the kernel wwan port `type` file
(`/sys/class/wwan/<port>/type` → QMI/MBIM) for any `/dev/wwan*` control node
before falling back to the driver; the type→proto mapping is shared with
`wwan_control_ports`. Regression test in test_discovery (MBIM-only MHI). NOTE:
an MBIM MHI modem needs the **wwand-mbim** package installed.

Follow-up (same tester, T99W175/DELL X55 on a BPI-R4): with the protocol fixed
the modem reached READY/registered but the interface still got
`DEVICE_CLAIM_FAILED` — `netdev_for_device()` only searched the USB cdc-wdm
sysfs (`/sys/class/usbmisc/<n>/device/net`), so the MHI data netdev was never
found (`status.netdev = null`) and netifd had no L3 device to claim. HW sysfs:
the data netdev `wwan0` (POINTOPOINT/NOARP raw-IP MBIM channel) and the control
port `wwan0mbim0` both resolve to the same `.../mhiN/wwan/wwan0` device dir.
Fix: `netdev_for_device` now, for a `/dev/wwan*` control node, matches the
netdev whose `device` path equals the control port's. Regression test with the
confirmed layout.

## SMS send + parity finishers + CLI --json (2026-08-13)

- **SMS send** (the receive-only gap): `sms_pdu.encode_submit` (SMS-SUBMIT
  encoder — GSM7/UCS2 auto-select, 8-bit concatenation UDH for long text;
  byte-verified vs GSM 03.40), QMI WMS `RAW_SEND` (0x0020, spec-verified) over
  native or the MBIM passthrough, else `AT+CMGS` PDU mode via a new
  `atcmd.send_pdu` two-phase `>`-prompt handler. ubus `modem_sms_send
  {modem,number,text}`, `wwandctl sms-send`, LuCI ACL. NOT live-sent (costs /
  outbound); encoder + AT-prompt unit-tested.
- **PUK retries surfaced**: QMI now reports a PUK-locked card distinctly as
  `puk_required` with the remaining unblock attempts (UIM app_state 3 →
  puk1/upuk_retries; DMS pin status 4 → unblock_retries) instead of a generic
  `app_state`/`pin_blocked` — the LuCI/CLI PUK dialog now shows the correct
  branch + "N attempts left".
- **Parity finishers**: MBIM + NCM refresh IP settings while CONNECTED (re-read
  IP_CONFIGURATION / CGCONTRDP on the stats tick, emit 'settings' → daemon
  renews in place — QMI parity; catches network-pushed DNS/MTU/prefix changes).
  NCM rejects a second parallel context (`unsupported_multi_context`) instead
  of two interfaces silently sharing the one cdc_ncm netdev.
- **wwandctl `--json`**: machine mode — raw ubus reply of a read command
  (status/modems/signal/cells/datapath/slots/plmn) for scripting/monitoring.

Deferred (user): the optional stats/metrics module (JSON exporter / quota /
`wwandctl watch`).

## wwandctl CLI + end-to-end PUK entry (2026-08-12)

- **`wwandctl`** (`src-ucode/wwandctl.uc` → `/usr/bin/wwandctl`, base package):
  human-friendly CLI over the ubus API — status/modems/signal/cells/datapath,
  up/down/reattach/scan/select, slots/slot/pin/pin-lock/puk/plmn, sms,
  reset/repower/at/migrate/log-level, `help`. Modem argument optional with a
  single managed modem (auto-resolve; a first arg naming a modem is consumed).
  Live-validated on 245 (status/modems/slots/at/signal/reattach).
- **PUK entry, LuCI → ubus → daemon → card**: new `sim.unblock_puk` transport
  chain (QMI UIM `UNBLOCK_PIN` 0x0027 — spec-verified vs libqmi 1.38 — →
  native MBIM `PIN` set PUK1+ENTER (duck-typed `modem.mbim_pin`, base stays
  mbim-free) → `AT+CPIN="puk","newpin"`). SAFETY: falls through ONLY on QMI
  transport-reject codes that provably never reached the card; an attempt that
  reached the card is terminal (wrong PUKs brick the SIM). ubus
  `modem_sim_puk {modem, puk, new_pin}` (8-digit/4–8-digit validation), on
  success restarts bring-up with the new PIN as one-shot override. LuCI:
  "Unlock SIM" button on the modem list while `sim_block` is set — PUK+new-PIN
  dialog for puk_required/retries_exhausted, manual PIN release otherwise
  (modem_sim_pin_verify finally wired into the UI + ACL). 4 host tests for the
  chain (ok / transport-fallback / wrong-PUK-terminal / no-transport).

## Audit tranche 3 — dedup + extractions (2026-08-12)

Duplication audit follow-through (suite green after every step):

- **Extractions** (established install()/re-export patterns): `sim_plmn.uc`
  (PLMN/FPLMN codec + EF read/write out of sim.uc, 1448→889 LOC; API stable
  via re-exports), `reconnect.uc` (daemon reconnect/hold engine),
  `ctx_settings.uc` (context-settings assembly + CTX_LIVE_FIELDS);
  daemon.uc 1705→1457, plus one lazy-loader factory replacing the four
  memoized try-require quadruplets.
- **ubus.uc**: one `ok_reply` wrapper for all 22 deferred methods; sync
  LuCI-facing methods normalized to the `{ ok: bool, ... }` envelope
  (purely additive — every existing key incl. `error` preserved).
- **Shared modem core** (scaffolding): `switch_protocol`/
  `protocol_switch_supported` (3 identical copies), `make_recovery`
  (3× factory preamble), `sim_block` emitter (9 sites, payload preserved),
  `enter_ready` (READY epilogue — propagates NCM's HW-proven
  teardown-during-emit guard to QMI+MBIM), `resolve_active_sim`
  (reapply tails; QMI keeps matching the RAW re-read identity).
- **MBIM**: `ensure_pt_client` factory (_ensure_uim ≡ _ensure_wms),
  pdp/auth enum maps single-sourced in basic_connect
  (IP_TYPE_FROM_PDP/AUTH_FROM_CFG — the 'both'→CHAP collapse can't drift),
  UTF-16LE encode/decode exported from codec/mbim.uc (ext-schema twins gone).
- **ncm_vendors**: shared `AUTH_CGAUTH` builder (8 identical lambdas).
- **context_common**: one NETMASK_BITS table + both converters (context.uc
  and modem_ncm.uc carried identical copies).

Consciously deferred (drift risk > value right now): the context-lifecycle
skeleton merge (modem_event/up-guard/_fail/connected-tail), the slow-telemetry
loop driver, the stats-driver core, ncm status_state regex factory, atcmd
first_match helper.

## Audit tranche 2 — backend parity MBIM/NCM (2026-08-12)

Closes the parity gaps the audit's capability matrix surfaced (HW-smoked on
245 QMI + 246 MBIM/EG06; suite green):

- **Recovery rungs 8/16 now act on MBIM + NCM**: `note_connect_failure_light`
  takes optional `{ opmode_cycle, modem_reset }` handlers — MBIM cycles
  RADIO_STATE (reset via passthrough-DMS/AT), NCM cycles CFUN 0/1 (reset
  CFUN=1,1). Before, both rungs were silent no-ops and the ladder skipped
  from plain retries straight to board repower.
- **MBIM `self.reattach`** — passthrough DMS low_power→online (HW-proven:
  2 s on the EG06, session survives), native RADIO_STATE off→on fallback;
  no longer rides the frequently-dead AT port. netsel log now backend-neutral.
- **MBIM status parity**: `rat`/`caps` (probe_iot_rat in the slow loop),
  `pin1` (from the PIN query; `enabled: null` where MBIM can't know),
  `info.revision` (from firmware_info until ATI enriches it),
  `last_error` on context_mbim/_ncm `_fail` (+ cleared on connect — QMI parity).
- **`option sim_slot`**: MBIM asserts it at init (step_simslot before the SIM
  step, idempotent via sim.slot_status/switch_slot); NCM surfaces an honest
  config_warning (no slot transport on AT-only).
- **PLMN/FPLMN on MBIM**: sim.uc `ensure_uim` brings up the passthrough UIM
  on demand for read_plmn_lists/read_fplmn/write_fplmn (operator/home lists
  no longer null; FPLMN no longer capped to the 12-byte AT+CRSM path);
  simops gate accepts `_ensure_uim` (`no_sim_transport` replaces the
  misnamed `no_uim_client`).
- **LED bars on native MBIM**: bars_from_signal also picks the flat
  `{ rssi, rsrp }` v1 shape (was 0 bars / dark LEDs).
- QMI modem carries `protocol: 'qmi'` (modem_datapath/location gates read
  it); `modem_location` says `unsupported_on_backend` when `option location`
  is configured on a non-QMI backend (was a misleading `location_disabled`);
  simops transport errors are `sim_transport` (was `qmi` even on NCM).

Deferred (documented, not blocking): MBIM/NCM in-place IP-settings refresh
while CONNECTED, MSISDN on MBIM/NCM, NCM multi-context rejection.

## Audit tranche 1 — bug fixes across ucode + C module (2026-08-12)

Five-agent project audit (RAM / duplication / maintainability / C+shell /
backend parity); tranche 1 = the confirmed defects. All host-tested, HW-smoked
on 245 (QMI/RG650E, aarch64) and 246 (MBIM/EG06, mipsel):

- **sim.uc crash**: `unlock()`/`read_iccid`/`read_identity` null-deref'd
  `modem.dms` on modems with neither uim nor dms (native-MBIM-UICC / NCM,
  reachable via the eSIM apply path) — guarded; `unlock()` now bridges over
  `_ensure_uim` (MBIM) or reports `no_unlock_backend`.
- **MBIM PUK**: a PUK/perso-locked SIM looped PIN1-ENTER → recovery ladder;
  now terminal `SIM_BLOCKED` (`puk_required`/`personalization`), PIN2 passes
  through (attach not gated). New `PIN_TYPE_*` consts vs libmbim.
- **Context leak**: reload-replaced contexts stayed in `modem.contexts`
  (retained + still receiving events) — `detach_context` in scaffolding,
  called from the daemon's `stop_context`.
- `modem_probe.registered` was always false (string vs numeric compare) —
  shared `is_registered()`; `repower_modem` with an unknown ref no longer
  falls back to ANOTHER modem's reset GPIO; MBIM proto-error hook now runs the
  `usb_repower` rung (NR7101-class fix was QMI-only); MBIM context aborts an
  in-flight activation on `suspend` (netifd requeue parity); activate()'s
  150 s queue-guard timer is cancelled on flush.
- **wwand-io.c**: OOB read on truncated netlink replies (nlmsg_len clamp +
  16K/8K aligned union buffers — the 2K buffer was routinely too small for
  RTM_GETLINK); rmnet_add/tx_aggr no longer report success on a missed ACK
  (EINTR loop + strict nlmsgerr check); nla_begin/nla_put NULL checks;
  spawn close() returns null when uloop's SIGCHLD reaper won the race
  (esim_bridge now carries the exit status in-band via an `__EXIT` marker);
  GC free() probes WNOHANG before signalling (pid-reuse hazard);
  write() returns null for pure-EAGAIN vs false for hard errors (transport
  treats false as device-gone instead of busy-retrying forever).
- Hygiene: SPDX headers completed (3 files), 6 dead imports removed, stale
  doc references fixed (ncm_vendors, hwops, 3 missing ubus methods in
  reference.md), wwand-migrate header said `proto qmi` instead of `proto
  wwand`, init reload falls back to restart when the daemon is dead.

## MBIM cold-boot SIM race → bogus terminal SIM_BLOCKED/verify_failed (2026-08-12)

HW-hit on the x1800 (GL-X3000/RM520N-GL, MBIM, `sim_slot 2`) on every cold
boot: modem parked in `SIM_BLOCKED` reason `verify_failed`, yet the SIM was
fine — `+CPIN: READY`, PIN retries untouched at 3/3 (no verify ever consumed
one); only a wwand restart cleared it. Root cause chain in `modem_mbim.uc`
`step_sim`: MBIM opens before the card is up (`SUBSCRIBER_READY_STATUS` →
`ready_state 0`, no imsi/iccid), the old code raced straight into the PIN
query, firmware answered "locked" mid-init, the ENTER was refused WITHOUT
consuming a retry — and every verify error was mapped to a terminal
`SIM_BLOCKED`. Fixes (deployed on the x1800):
- **SIM-init wait**: `ready_state == NOT_INITIALIZED` → poll
  SUBSCRIBER_READY_STATUS (QMI `unlock_uim` card-poll parity, 10× `card_poll`
  1 s), refreshing imsi/iccid + the `wwand_sim` override when the identity
  lands late (some firmwares never send the indication); exhaustion →
  retriable `fail('sim_ready')`, not terminal.
- **Verify-error disambiguation**: on a refused ENTER re-query PIN and let the
  retry counter decide — counter decremented ⇒ genuinely wrong PIN ⇒ terminal
  `verify_failed` (now with `retries`); re-query says unlocked ⇒ reply was
  lost, proceed; unchanged ⇒ transient refusal ⇒ retriable `fail('pin_verify')`
  (the `pin_block_reason` last-try guard still applies on the next attempt).
- New suite `test_modem_mbim_sim` (18 checks): cold-boot wait / transient
  refusal / wrong PIN / lost reply.
- NOTE the x1800's underlying trigger is likely hardware: during diagnosis the
  slot-2 card (M2M, 898823…) went electrically absent (`+CPIN` CME 10,
  `+QSIMSTAT: 0,0`) and stayed gone through CFUN 0/1, QUIMSLOT toggles and a
  full CFUN=1,1 — while the slot-1 card (1NCE, 898822…) reads fine. Reseat the
  slot-2 card / check the tray.

## NCM AT-port discovery dead on cold boot: no anchor when device=null (2026-08-12)

From the Cudy LT300 (SLM770A ECM) boot log of 2026-08-08: 7 consecutive
`no_at_port` attempts — including retries kicked by the `hotplug add ttyUSB*`
events — while ttyUSB0-3 existed the whole time. Discovery builds NCM modems
with `device = null` (no control node) and pins `control.tty` at resolve time;
on a cold boot the serial interfaces bind only after the first resolve
(board-profile/runtime `new_id`, late kmodloader), so `cfg.tty` stayed null and
`open_at`'s tty discovery anchored on `self.device` — null — so no retry could
ever find them (`find_tty` bails without device/base). Fix in
`modem_ncm.start()`: anchor = `self.device ?? datapath.netdev`; the serial
new_id bind runs off it and `open_at` gets a `base_override` of the netdev's
USB parent (`/sys/class/net/<netdev>/device/..`). New suite
`test_ncm_atdiscover` (6 checks) replays the boot race (attempt 1 no ttys →
new_id → attempt 2 finds the role-tagged AT port from scratch). Not yet
deployed to the LT300 (tunnel down at fix time).

## Datapath: stale-renamed parent silently adopted as its own mux child (2026-08-11)

HW-hit on the Chateau after a config update: link up, packets leave, nothing
returns — persistent across restarts. Root cause chain: a config reload briefly
produced a channel-less datapath snapshot (`datapath: none, mux []`), whose
non-mux path legitimately renames the raw netdev to the stable L3 name
(`wwan0` → `wwand0`, daemon `rename_l3`). When the next setup ran WITH mux
channels, the child name collided with the (renamed) parent; `link_add_rmnet`
failed and the pre-existing-link tolerance **adopted the parent as its own mux
child** — QMAP-muxed traffic on a raw parent, dead data plane, logged as
success. Fixes (netlink.uc, mirrors the existing setup_mbim recovery):
- **setup()**: when a mux child name is held by the parent itself, rename the
  parent back to a free raw kernel name first (`free_raw_name`, moved above
  setup() — ucode resolves module names textually, no hoisting), then create
  the child on the moved parent; `parent` is returned and followed by
  datapath_qmi (`self.datapath.parent`).
- **rmnet adopt hardening**: an existing device that is not a verifiable rmnet
  mux child (`rmnet_mux_id` readable) is REFUSED, not adopted; the fx wrapper
  leaves `rmnet_mux_id` unset on an older wwand_io.so so legacy tolerant
  adoption remains there.
- fakefx rename now moves the whole sysfs subtree (kernel-faithful);
  test_datapath +5 collision checks. HW-validated on the Chateau: healing
  rename fires once, wwan0(parent)+wwand0(rmnet child) restored, two full
  uci-commit/reload_config cycles survive with 0% loss.

## SIM slots on MBIM modems: passthrough bring-up + native MS BCE CIDs (2026-08-11)

`modem_sim_slots`/`modem_sim_switch_slot` never worked on MBIM modems: sim.uc
required a ready `modem.uim` (QMI UIM client) and bailed with `no_uim_client`,
but nothing on the MBIM side ever allocated one for the slot path (APDU/eSIM ride
native MBIM UICC first) — LuCI showed no slot list (found on the x1800/RM520N-GL,
2 slots). Fixes:
- **sim.uc**: `slot_status`/`switch_slot` bring the passthrough UIM up on demand
  via `modem._ensure_uim` (same pattern as `power_cycle`), falling back to the
  native path below; a UIM `GET_SLOT_STATUS` refusal (err 71/94) flips the modem
  to the native path permanently (`_slot_via_mbim`) instead of caching
  `unsupported` when a fallback exists.
- **Native MBIM multi-slot** for pure-MBIM modems (no passthrough): MS Basic
  Connect Extensions `SYS_CAPS` (CID 5, slot count), `DEVICE_SLOT_MAPPINGS`
  (CID 7, active slot + raw-built SET for switching — ref-struct-array layout),
  `SLOT_INFO_STATUS` (CID 8, per-slot `MbimUiccSlotState`), all verified against
  libmbim 1.32. `mbim_backend.slot_status/slot_switch` normalize to the exact
  QMI-shaped rows sim.uc produces (card/active/is_euicc; the native CIDs carry no
  per-slot ICCID/EID — the active slot's ICCID is filled from modem info).
  Exposed duck-typed as `self.mbim_slots` (like `mbim_uicc`), cleared on close.
- **Tests:** test_mbim_backend +15 (mockhub slot scenario incl. exact SET bytes,
  ref-struct-array wire decodes, zero-slot guard; mockhub now records raw request
  buffers), test_sim +13 (on-demand UIM bring-up, native fallback + ICCID fill,
  err-71 flip caching). HW-validated on the x1800 (RM520N-GL MBIM: passthrough
  path lists both slots — slot 1 active eUICC with EID, slot 2 physical SIM).

## Audit / consolidation pass over the 2-day feature window (2026-08-09)

Three-dimension review (consolidation, docs, core-fitness) over the PLMN/FPLMN/
IoT-RAT changes; fixes:
- **Behavioural bugs:** `modem_plmn_restore` now uses `effective_plmn_restore`
  (per-SIM `plmn_list` wins) so the LuCI "restore now" applies the SAME list as
  the boot-time restore; `write_fplmn` reads the current EF length and rewrites
  the WHOLE file (no stale forbidden PLMNs in tail slots on a >12-byte EF_FPLMN);
  `modem_plmn_set` rejects an unknown `list_type` instead of silently writing NAS.
- **Consolidation (sim.uc):** one `sim.write_plmn(modem, type, entries, cb)`
  dispatcher replaces the type→writer map that was triplicated across simops +
  restore; shared `bcd_plmn` / `scrub_digits` / `valid_plmn` / `act_flags` /
  `nas_of` helpers replace the duplicated BCD decode, digit-scrub, AcT masks and
  `with_nas` shims; dropped the redundant `EF_FPLMN_ID`.
- **Docs:** reference.md now documents `config wwand_plmnlist` (user/nas/fplmn),
  `option plmn_list`, and `modem_plmn_set`/`modem_plmn_restore`; CLAUDE.md core
  layering lists simops/hwops/ncm_vendors/rat.uc; telemetry-survey temperature
  marked done; extending.md gains RAT/caps + SIM-EF pointers. rat.uc header now
  states which mappers are wired vs. provided-for-extension.
- **Tests:** +config `wwand_plmnlist` fplmn/nas/dangling-ref cases (test_config).
- HW-re-validated FPLMN write/read/clear on RG650E (UIM) + Cudy (CRSM) after the
  refactor; `invalid_list_type` rejection confirmed.

## Forbidden-PLMN (FPLMN) management (2026-08-09)

A third managed PLMN list type (`fplmn`) alongside `user`/`nas` — the SIM
EF_FPLMN (6F7B), the *hard* network block (unlike the preferred lists, which are
only ordering hints). Same workflow: read from modem, edit, save as a named
`wwand_plmnlist type 'fplmn'`, restore before every radio-on, LuCI editor +
per-modem/SIM attach.

- **No QMI NAS forbidden message exists** (libqmi 1.38 has Get/Set *Preferred*
  only), so FPLMN is SIM-EF-only: **QMI UIM WRITE/READ_TRANSPARENT(6F7B)** with
  an **AT+CRSM (214/176)** fallback (the only path on modems whose UIM rejects EF
  access, e.g. the Huawei E392 — code 48). `sim.uc` `read_fplmn`/`write_fplmn`
  (+ `decode_fplmn`/`encode_fplmn`, 3-byte MCC/MNC, no AcT); `atcmd_parse.parse_crsm`.
- **UIM WRITE_TRANSPARENT (0x0022)** added to `codec/schema/uim.uc` — spec-derived
  (libqmi ships NO binding), mirrors READ_TRANSPARENT, locked by a wire-buffer
  test (`test_qmux`) and HW-validated.
- Wired through `config.uc` (type `fplmn`), `simops.uc`/`ubus` (`modem_plmn_set`
  list_type `fplmn`, restore dispatch), and the LuCI editor (type dropdown; the
  RAT columns are hidden for fplmn — forbidden entries carry no AcT).
- **HW-validated 2026-08-09**: RG650E (QMI, UIM path) write/read/clear OK — the
  spec-derived UIM write schema confirmed on real hardware; Cudy LT300 v3
  (SLM770A/MeiG, NCM, pure AT+CRSM) write/read/clear OK. **E392 CANNOT write
  FPLMN by any means** — UIM rejects (code 48) AND its old Huawei firmware
  refuses AT+CRSM UPDATE (214) while allowing READ (176); a hard modem limitation
  (use manual COPS selection there). The CRSM write tries quoted then bare
  `<data>` for firmware compatibility.

## IoT / extended radio-type identification (2026-08-09)

Identify and display the cellular-IoT / reduced-capability radio types that
libqmi 1.38 and libmbim 1.32 do **not** model at all — **NB-IoT, LTE-M
(Cat-M1/eMTC), EC-GSM-IoT, RedCap, NTN/satellite** — plus the 5G NSA/SA split.
Read-only (no mode selection).

- **`codec/schema/rat.uc`** (new) — one canonical RAT vocabulary + mappers from
  every source: `from_qmi_radio_if` / `from_dsd` (incl. `so_mask` bits verified
  vs `qmi-flags64-dsd.h`) / `from_mbim` / `from_at_cops_act` (3GPP TS 27.007
  `<AcT>`) / `from_qnwinfo` / `from_qeng_act`, plus `merge` (AT/QNWINFO wins for
  the IoT variants QMI/MBIM can't name), `label`, `caps_from`. `test_rat.uc`.
- **AT is the only standardised path to NB-IoT** — `atcmd_parse.uc`: fixed the
  `+COPS` `<AcT>` map (**8→EC-GSM-IoT, 9→NB-IoT**, previously folded into
  GSM/LTE), added `<AcT>` to the `+COPS?` read form, new `parse_qnwinfo`
  (Quectel active access-tech: eMTC/NB-IoT/NR5G-NSA/NR5G-SA/…) and
  `parse_qcfg_iotopmode` (which IoT modes the modem searches).
- **`modem_common.probe_iot_rat`** — vendor-gated (Quectel) `AT+QNWINFO` over the
  at2 side channel on the slow telemetry loop → `self.rat_fine` + `self.rat_label`;
  **`collect_caps`** → `self.caps {rats, iot_modes, ntn}` from the authoritative
  **QMI DMS device-capability `radio_ifs`** (`from_dms_radio_if`; DMS 5GNR=10, not
  the NAS 12) + Quectel `AT+QCFG="iotopmode"` (once) + model hints (RedCap/NTN) +
  observed RATs. Wired into the QMI + NCM telemetry ticks (MBIM left alone —
  EG06 AT times out in MBIM mode).
- **`format_telemetry`** now lets a fine IoT/RedCap/NTN reading override the
  coarse radio-interface `tech=` (non-IoT readings leave the existing output
  intact — no regression).
- **ubus `status`** gains per-modem `rat` (current fine access tech) + `caps`;
  **LuCI status** shows a "Technology" row (prefers `rat`) and a "Capabilities"
  badge row (IoT/RedCap/NTN highlighted).
- **HW-verified on 245**: RG650E (Quectel) → `rat=LTE` (live QNWINFO probe),
  `caps.rats=[lte,nr5g,umts]` (DMS caps — honest 5G capability while camped on
  LTE); E392 (Huawei, non-Quectel) → QNWINFO skipped (`rat=null`) but DMS caps
  still give `[gsm,lte,umts]`; `tech=LTE` unchanged. RedCap/NTN paths are
  host-tested only (no such modem on hand) but plug in via one mapper/hint entry.

## QModem-quirk harvest (2026-08-09)

Studied FUjr/QModem for valuable, non-obvious modem quirks wwand lacked; adopted
the ones that fit (skipping what QModem does that wwand already had — CGACT dial
fallback, CGDCONT context, per-RAT signal, cell-lock).

- **Temperature telemetry (P1)** — new per-vendor AT readout in
  `modem_common.collect_temperature` (Quectel `AT+QTEMP`, MeiG `AT+TEMP`
  milli-°C /1000, Huawei `AT^CHIPTEMP`, SIMCom `AT+CPMUTEMP`); parsers in
  `atcmd_parse.uc`. Wired into the NCM + QMI slow telemetry loops, the
  `format_telemetry` log line (`temp=NNC`), the `modem_cells` ubus field
  (`temperature{celsius,source}`), and the LuCI status "Serving cell" panel.
  **HW-validated on 245 (RG650E): `temp=42C`.**
- **Correctness fixes (P2)** — Huawei `AT^SETAUTODIAL=0` (disable the modem's
  internal auto-dialer at init) and Sierra `AT!ENTERCND="A710"` (unlock the `AT!`
  command set, else all Sierra config silently ERRORs) added to their NCM
  `modem_init`.
- **Generic-variant audit** — verified we always co-set the standard 3GPP
  variant where one exists: `AT+CGACT` is already the universal dial fallback;
  fixed the one gap where ZTE/MikroTik defined the context only via proprietary
  `AT+ZGDCONT` — `build_pdp_setup` now **always** emits generic `AT+CGDCONT`
  first, with the vendor define layered on top, so the CGACT fallback has a valid
  context. (Auth stays vendor-specific: it is either-or, not co-settable.)
- **MHI/PCIe AT-port discovery (P4)** — `atcmd.find_mhi_at` probes
  `/dev/wwan*at*` / `/dev/mhi_*DUN*`; `find_tty` falls back to it when a modem
  exposes no USB tty siblings (M.2/PCIe modems on the MHI bus).
- **Fibocom mode-switch (P3, partial)** — documented `AT+GTUSBMODE` recipe in
  `protocol_switch.uc`, **UNVERIFIED** (excluded from `supported()`; the
  composition codes are many-to-one per chipset). The Fibocom `GTCCINFO`/
  `GTCAINFO` cell telemetry and `GTACT`/`GTCELLLOCK` band/cell lock are
  **deferred** pending Fibocom HW — a wrong cell parser silently shows garbage.

## Good-citizen coexistence + user-triggered migration (2026-08-08 late)

- wwand no longer replaces the stock cellular stack by default. **Package
  CONFLICTS removed** (wwand-qmi/-mbim/-ncm install alongside uqmi/umbim/
  comgt-ncm). New global **`option takeover`** (`wwand_globals`, default **off**)
  gates all automatic adoption: the shim's `add_protocol qmi` alias, the daemon's
  runtime adoption of bare `proto qmi` interfaces (config.uc `parse()` gate — a
  bare legacy interface is a context only under takeover; `proto wwand` + `option
  modem` always managed), and the uci-defaults auto-migration on install/upgrade.
- **User-triggered migration** replaces the automatic path: a new `migrate` ubus
  method (`daemon.migrate(interfaces, apply)` in main.uc, reusing the tested
  `config.migrate_plan`; scopes by dropping unselected legacy interfaces from the
  raw dump to preserve modem dedup) + a **Migratable interfaces** section in the
  LuCI modem list (checkboxes + *Migrate selected*). Converts `proto qmi/mbim/ncm`
  **in place** to `proto wwand` (name/firewall/IP kept). rpc.js `migrate` + ACL.
- test_config: compat/adoption tests now parse with takeover on via `padopt()`;
  a dedicated *takeover gate* block asserts the default-off behavior (+ new
  checks). Docs (reference/architecture/extending/luci/README + both CLAUDE.md)
  rewritten from "replaces/auto-migrates" to "coexists/opt-in".

## Log wording: context → interface (netifd-style) (2026-08-08 late)

- Per-entity **log prefixes** now read like netifd: a connection logs as
  **`interface <name>: …`** (was `context <name>: …`) and a modem as
  **`modem <name>: …`** (already the case). 3GPP/PDP terminology is left intact —
  "attach context", "skipping context write" (CGDCONT) still say *context*, since
  there it means the PDP context, not the netifd interface. Internal code
  (`context.uc`, `self.contexts`) keeps its names; this is a log-text change only.
  HW-verified on 245/246: `logread` shows `interface wwan0m1: …` / `interface
  wan: …`.
- **Test harness robustness** (`run_tests.sh`): a suite's verdict now comes from
  the `"<name>: N checks, 0 failures"` summary it prints (line-buffered so it
  survives a teardown abort), not the exit code. This tolerates a **pre-existing
  host ucode `ubus.so` use-after-free at VM teardown** (valgrind-proven:
  `uc_ubus_object_call_cb` → `ucv_gc_common`, present on a clean tree too — a
  host-interpreter bug, not wwand's; the product on musl is unaffected). glibc
  only turns that latent double-free into a SIGABRT depending on heap layout, so
  a longer log string could make `test_daemon` abort *after* all checks passed; a
  crash *before* the summary still fails the suite.

## Syslog-priority logging via /dev/log (2026-08-08 late)

- **wwand now logs to `/dev/log`** (the syslog datagram socket) with real
  RFC3164 priorities, so `logread` shows each message at its true severity
  (`daemon.info`/`notice`/`warn`/`err`/`debug`) instead of everything arriving as
  `daemon.err` through procd's stderr capture. When /dev/log is unreachable it
  falls back to stderr (self-healing: it retries the socket per message, so logd
  coming up late is picked up automatically). Older `wwand_io.so` without the
  seam → clean stderr fallback (feature-detected).
- **Native seam** in `io/src/wwand-io.c`: `syslog_open(ident, facility)` /
  `syslog_emit(severity, msg)` / `syslog_close` — an AF_UNIX SOCK_DGRAM to
  /dev/log (stock ucode has no unix-socket support). `log.uc` reworked around it
  (target `auto`/`syslog`/`stderr`, severity map err=3…debug=7).
- **CLI overrides** (main.uc), precedence over uci `log_level`, sticky across
  reloads: `--log-level`, `--log-target`, `--stderr`, `--syslog`.
- HW-verified on 245 (aarch64) and 246 (mipsel_24kc — rebuilt the `.so` for that
  arch): `logread` shows a real mix of severities post-restart.
- test_log +7 checks (priority mapping via a fake seam, target selection, emit-
  false → stderr fallback).

## Idempotent reload + modem reboot button (2026-08-08 late)

- **Idempotent config reload**: `apply_config` no longer tears everything down and
  rebuilds on every reload. It now **diffs** the new config against the running
  state (per-modem signature = cfg + derived mux set + L3 name; per-context
  signature = cfg) and bounces **only** what changed. Unchanged modems/contexts
  keep their live objects untouched — editing one interface's APN reconnects only
  that context; siblings and other modems run uninterrupted. Adding/removing a mux
  channel is scoped to that modem. New helpers `stop_modem`/`stop_context` (scoped
  teardown, distinct from the whole-box `shutdown`); `_sig` is carried across
  internal rebuilds (hotplug re-add, waiting-modem retry) so those never trigger a
  false bounce on the next unrelated reload. `ifup`/`ifdown` stay the force path
  for a single interface. `test_daemon` +30 checks (no-op / APN change / add /
  remove / mux-add scenarios with a fake backend asserting object identity).
  **HW-verified on the dual-modem Chateau**: no-op reload → zero churn; changing
  modem A's APN kept modem B CONNECTED across all 36 samples of the reload window,
  logs showed only A's context reconnecting. 246 (MBIM single) no-op reload → no
  bounce.
- **LuCI modem-list Reboot button** — a per-row **Reboot** action next to Tools
  triggers `ubus modem_reset` for that modem (GPIO reset if the board has one,
  else backend soft reset), with a confirm. The list also now shows each modem's
  **backend** and **up-connection count**.
- **Cold-boot finding (Cudy/SLM770A)**: on a cold boot the MeiG SLM770A can
  enumerate its USB composite **net-function only** (`cdc_ether`, no ttyUSB) — the
  NCM backend then has no AT control channel and stays ABSENT (`no AT port`).
  A GPIO reset did not restore the serial ports in this state; warm boots do.

## FCC unlock + stable L3 names + doc overhaul (2026-08-08 pm)

- **FCC RF unlock** for laptop-SKU modems that boot radio-locked (Lenovo/Dell/
  HP Quectel EM1xx, Foxconn SDX55/SDX62, DW5821e). QMI: after set-online,
  `GET_OPERATING_MODE` verifies the mode and, if stuck in low power, runs the
  `fcc_auth` chain (`option fcc_auth`: auto=dms→foxconn, off, or explicit
  incl. `foxconn:<magic>` / `foxconn2:<str>:<num>`) then retries online —
  DMS 0x555F / Foxconn 0x5571 v1+v2 verified vs libqmi 1.38. MBIM:
  `codec/mbim-schema/quectel.uc` (vendor UUID, RADIO_STATE cid 1, vs libmbim
  1.32), `option fcc_auth 'quectel'` sends radio-state ON after OPEN. LuCI
  Combobox + reference.md; test_modem auto-chain + off scenarios.
- **Stable L3 device names `wwand0`…`wwand100`**: every context gets a
  deterministic datapath name in one flat namespace (config order), an
  explicit `option device` pins it. Non-mux datapaths (QMI/MBIM without mux,
  NCM/ECM) rename the kernel netdev via netlink; mux children are created
  under the wwandN name; the muxed **parent keeps its kernel name**. Name
  conflict → error-log, kernel name kept. learn_device write-back pins the
  number. Autosetup pre-pins `wwand0`. HW-verified on all four datapath
  variants: Chateau QMI non-mux (wwan0→wwand1) + QMI mux child (wwand0,
  parent untouched), Cudy NCM (usb0→wwand0), 246 MBIM non-mux (wwan0→wwand0,
  public IP intact) — all reconnected. (246 converted to the modern
  wwand_modem+option-modem model for the test; backup at
  /etc/config/network.bak-wwandtest.)
- **Docs**: new `docs/README.md` (documentation map, AI-friendly) and
  `docs/connection-flow.md` (a dial-in walked through from the wwand, modem
  and network side, with per-phase extension hooks); reference.md gains a TOC
  + a "Configuration workflows" chapter (fresh box, manual, 2nd APN/modem,
  per-SIM, eSIM, radio pin, FCC, migration); the `fcc_auth` option and the
  L3-naming model documented; extending.md gains the explicit-parse trap
  note. LuCI proto L3-device help + placeholder updated to wwandN.
- **LuCI screenshots** can be produced headlessly (Chrome + CDP with the
  session cookie) — captured Modems / Status / Modem Tools for review.

## Re-audit follow-up + generic modem reset (2026-08-08)

Re-audit of the decomposed tree confirmed the earlier fixes hold; the residual
findings were all worked off:

- **Bug fixes**: proto `renderCellScan` resolves the modem from the
  interface's `option modem` first (netdev heuristic only as fallback — a
  cell lock must never target the wrong modem after a netdev swap);
  `settings.js` writes cell lock / SIM slot to the wwand_modem section of the
  **selected** modem tab (was: always the first wwand interface);
  `modem_init_qmi` parks its regdetail probe timer in the shared `tm` holder.
- **Generic `modem_reset`** (user request): priority reset-GPIO (per-modem
  `reset_gpio`; board default only when a single modem is managed) → backend
  soft reset. NEW MBIM backend reset (passthrough-DMS offline→reset, else
  AT+CFUN=1,1) closes the parity gap. `modem_repower` + the recovery repower
  rung gate board GPIO/power-cycle to single-modem boxes
  (`multi_modem_needs_reset_gpio`) — on multi-modem hardware the board lines
  would reset the wrong modem. LuCI button now calls `modem_reset` with the
  section's modem (was `modem_repower` with an empty ref).
- **Call-end decode**: verbose type 2 (modem-internal) reasons now named via
  the libqmi `VERBOSE_CALL_END_REASON_INTERNAL` table (201-220 + 241) — e.g.
  the field-seen `internal cause 204` now logs `unknown cause code`.
- **Dedupe/cleanup**: `clean_cell_metrics` hoisted to modem_common;
  `telemetry_mbim.uc` extracted from modem_mbim (mirrors telemetry_qmi);
  sim.uc uses `hexmod.bytes_to_iccid` + named `QMI_ERR_NO_EFFECT`; esim
  imports the hex codecs directly (sim re-exports dropped); shared LuCI
  `fmt.hasSignal/mhz/regShort/dB`; dead imports/requires, stranded comments,
  the app-ACL `modem_sim_pin_verify` over-grant and the unused `repower` rpc
  removed; config_check/regdetail reflowed; named consts for the transport
  txq (64/5ms), QMAP datagram maxima (32/11) and the START_NETWORK timeout.
- **NEW suites**: test_backend (choose/first_of/run_seq/reset),
  test_transport (txq congestion/flush/dispatch over an injected fake
  `io_open` handle — NOTE: ucode does not parse `(a ?? b)(args)` as a call),
  test_hex (roundtrips incl. ICCID/EID), test_log (child-process capture).
- **Provider-driven (GDSP) SIM reset — played through live on HW** (Huawei
  E392, IMSI 9012800014...): the provider purges the registration; the modem
  loses registration ("unknown cause code", the newly-decoded internal 204),
  attach attempts get rejected without a cause, and the E392 eventually
  reboots itself off the bus. The old "only a router reboot helps" was the
  device-gone dead end above — with the removed-detach + presence re-check the
  whole cycle now self-heals: drop → detach → waiting → rebuild → fresh attach
  → READY, ~25-30 s per cycle, repeatedly HW-verified (incl. a mid-cycle wwand
  restart adopting seamlessly). Network-side re-acceptance took up to ~15 min
  of passive cycles; an admin `modem_reset` (LuCI button, backend DMS reset)
  produced a fresh attach the network accepted immediately — the documented
  fast path after a provider purge. Fallout fixed on the spot: sim.uc lost its
  internal hex_to_arr alias in the dedupe (daemon crash when the eSIM/slot
  path ran) — restored as non-exported aliases; check_modem now reports
  `modem_waiting` for a detached-but-configured modem.

## Maintainability audit rounds 1-3 (2026-08-07)

Three-agent audit (core / codec+services / LuCI+docs), findings worked off in
commit rounds; both modems on the Chateau (RG650E + Huawei E392, multi-modem)
re-verified CONNECTED on the refactored core. Highlights:

- **Consolidation**: `context_common.ctx_scaffolding` (emit/set_state/_fail
  tail — the context-side mirror of `modem_common.scaffolding`),
  `codec/hex.uc` (all byte/hex/BCD codecs, 5 copies dropped),
  `backend.first_of`/`run_seq` (sequential ladders/pyramids),
  `modem_common.TIMING_BASE`, config.uc `conn_fields`+`derive_mux_link` (the
  mux-child naming rule existed twice).
- **Structure**: `atcmd_parse.uc` split out of atcmd.uc (volatile vendor
  parsers vs stable engine; `atcmd.parse_*` re-exported), daemon
  `on_modem_event` split into named per-event handlers.
- **Safety**: NEW `tests/test_sim.uc` (35 checks) covers the PIN/PUK unlock
  machine (was the most safety-critical untested code); warn-only state
  validation (MODEM_STATES registry + complete CONTEXT_TRANSITIONS matrix);
  mbim encode_info die() now fails the request, not the daemon; the
  HW-unverified Sierra protocol-switch recipe is gated out of supported();
  batched-init-reset failures are logged.
- **Dead code**: six unused schema messages, NETIFD_OPTS, unused exports/ACL
  grants removed; `_apdu_be` docs aligned with the code (probe MBIM→QMI→AT,
  power_cycle deliberately QMI-first).
- **LuCI**: shared `wwand.rpc` / `wwand.format` / `wwand.modemsid` modules
  (rpc.declare and formatter duplication across 5 files), settings.js split
  (`wwand.esim` + `wwand.netsel`); identity-field save invariant documented
  (Combobox create-preservation), IMEI picker sources widened.

## Cold-boot autosetup + reload-race crash + M2M-eUICC detection (2026-08-05)

All HW-validated on the Cudy LT300 (MeiG SLM770A-R, NCM/ECM):

- **Cold-boot autosetup sweep** (`daemon.autosetup_scan`, called once from
  `main.uc` after the initial apply): zero-config autosetup phase 1 was
  hotplug-only — on the slow-booting Cudy the `usb0` net hotplug fires ~30 s
  BEFORE wwand is on the bus, the `ubus call wwand hotplug` forwarder call goes
  nowhere and nothing ever re-triggers it → freshly flashed box stayed
  unconfigured every cold boot. The startup sweep replays the first present
  candidate (`deps.list_present`: cdc-wdm or NCM netdev) through the same
  hotplug path; `autosetup_create` re-checks live uci emptiness, so configured
  boxes are untouched. New suite `tests/test_autosetup.uc`.
- **Reload-race daemon crash fixed** (HW-hit): autosetup phase 2 writes uci and
  reloads SYNCHRONOUSLY inside the `registered` emit → tears the emitting NCM
  modem instance down (`close_at` nulls the engines) → the READY hook then ran
  `tel_meig_locks` → `telemetry_at(self)` was null → `null.send` Reference
  error, daemon died (procd respawn). Three-layer fix: `on_registered`
  re-checks `state == 'READY'` after the emit; the CEREG/C5GREG poll callbacks
  re-check `REGISTERING`/`self.at` (stale in-flight responses); and
  `modem_common.telemetry_at` NEVER returns null any more — a torn-down modem
  gets a stub engine whose `send()` fails with `'closed'`, covering the ~25
  unguarded `telemetry_at(self).send(...)` call sites in all backends. New NCM
  scenario `s8_teardown_in_registered_emit` + stub checks in
  `test_modem_common`.
- **M2M / locked eUICC classification** (`esim.uc` + LuCI settings.js): an
  EMnify M2M eUICC (ICCID 8988239…, bootstrap IMSI 90128…) selects the ISD-R
  fine but refuses every ES10 STORE DATA with bare `6985` — SGP.02 cards have
  NO local ES10 (profiles are OTA-managed by the operator's SM-SR); proven via
  raw-AT probe (INS E2 to the USIM returns 6D00 → modem doesn't filter; ISD-R
  FCI carries no SGP.22 BF64 tag). `es10_request` now classifies this as
  `{ error: 'es10_refused', sw, hint: 'm2m_or_locked_euicc' }`; the LuCI eSIM
  panel renders an explanatory banner instead of a bare failure. Local profile
  download on such cards is impossible by design — NOT a wwand/lpac bug.
- ucode require-vs-import note: `esim.uc` is an exportless `require()` module
  with a top-level `return` — sanity-check it on-target with
  `ucode -e 'require("wwand.esim")'`, NOT via `import` (which fails by design).
- Open (deliberately not done): apndb entry for the EMnify bootstrap
  (IMSI 90128 → APN `em`) — user opted for detection/UX only.

## Cudy LT300 v3 / MeiG SLM770A-R bring-up — NCM HW fixes (2026-08-04)

First real NCM/ECM field bring-up (Cudy LT300 v3, MT7628, 58 MB RAM; MeiG
SLM770A-R, ASR platform, USB 2dee). Modem switched RNDIS→ECM (`AT+SER=2,1`;
2 = ECM, 3 = RNDIS — QModem's meig.sh mapping, HW-confirmed). All fixes
HW-validated on the device incl. three cold-boot cycles; committed in 65bbf0c:

- `atcmd.uc` LOCAL_PORTS: MeiG SLM770A `2dee:4d57` (RNDIS) / `2dee:4d58` (ECM)
  → if4 `at`, if3 `at2` (if2 is a mute DIAG port the first-ttyUSB heuristic
  used to pick → every AT timed out, dial never started).
- `modem_ncm.uc` DIAL_ECMDUP: carries `<pdp_type>` (`AT+ECMDUP=<cid>,1,<0|1|2>`)
  — without it the modem dials IPv4-only.
- `context_ncm.uc`: on dial-connect ERROR probe `dial.status`; if the bearer is
  already up (SLM770A auto-dials after attach and rejects a second ECMDUP with
  bare ERROR) **adopt the live session** instead of failing forever.
- `daemon.uc`: the stuck-pending interface reset marks `entry._reset_pending`;
  `context_down` no longer reads the self-inflicted teardown as operator intent
  (kept killing the queued activation and clearing `wanted` → interface stayed
  down until a manual wwand restart).
- `daemon.uc` + new `files/wwand.hotplug.tty` (feed Makefile updated): tty
  hotplug add re-kicks a modem parked in `no_at_port` ABSENT backoff — NCM
  serial ports can appear long after the netdev (vendor-serial `new_id` bind).
- `discovery.uc` resolve_control: accept a netdev-name `option device` for the
  NCM classification (was serial/netdev/usb_path only) — a LuCI save dropped
  `serial` from the wwand_modem section and the modem became UNRESOLVED.
  (Open: the LuCI modemopts `serial` field saved empty; consider read-back.)

Batch 2 (same day, all HW-validated on the Cudy incl. a clean cold boot;
also in 65bbf0c / luci-app af635b3):

- `modem_ncm.uc` **SERIAL_NEW_ID** table + `ensure_serial_bind()` — vid:pid
  whose serial interfaces the kernel `option` driver doesn't know (MeiG ECM
  `2dee:4d58`); wwand writes the id to
  `/sys/bus/usb-serial/drivers/<drv>/new_id` itself before AT discovery. The
  device-local init/hotplug hack scripts are REMOVED from the Cudy — wwand owns
  this now. (Complements `board.uc` `option_ids`, which is board-keyed +
  init-time only.)
- `atcmd.uc` find_tty: **netdev anchor fallback** — an NCM `device` is a netdev
  name; when `/sys/class/usbmisc/<dev>` yields no ttys, anchor on
  `/sys/class/net/<dev>/device/..`. Without this the retry path (ttys created
  late by the new_id bind) could never find the port even with ttys present.
- `board.uc`: **Cudy LT300 v3 profile** — modem reset line = named gpio `4g`
  (`/sys/class/gpio/4g/value`). HW-validated: `modem_repower` recovered a modem
  that had vanished from the USB bus entirely.
- **Async network scan** — `modem_scan_start`/`modem_scan_status` (daemon +
  ubus): a real scan runs MINUTES (AT+COPS=? and QMI NAS alike), which the
  LuCI→uhttpd(script_timeout 60 s)→rpcd chain cannot survive as one blocking
  call. LuCI settings.js now starts the job and polls every 3 s (legacy
  blocking fallback kept for old daemons). SCAN_TIMEOUT_MS 90 s → 240 s.
  HW-validated: 41 s scan on the SLM770A found Telekom.de + o2.
- luci-app-wwand `modemopts.js`: custom `o.load` overrides now end in
  `self.super('load', [section_id])` instead of `self.cfgvalue(...)` (canonical
  idiom; suspect in the LuCI save that dropped `serial`).
- **ucode gotcha (now in CLAUDE.md):** module-level `export function f() {…}`
  needs a trailing `};` — OpenWrt's ucode parser rejects the file otherwise
  ("Expecting ';'"), while the newer host-built ucode accepts it, so the test
  suite does NOT catch it. The daemon then reports the module's backend as
  "package not installed" (lazy-load treats any require error that way).

The kernel-proper fix (add 2dee:4d58 to the option driver id table upstream)
remains open; wwand's runtime bind covers it meanwhile.

## QModem study — datapath parity items (2026-07-26)

Studied QModem (FUjr/QModem) + quectel-CM vs wwand. wwand's QMI/AT/mux vocabulary
is a near-superset; only narrow datapath gaps. Adopted (schema libqmi-1.38-verified,
host+target `wwand_io.so` rebuilt, 31 suites/1281 checks green):
- **WDA UL aggregation** — SET_DATA_FORMAT now requests `ul_max_datagrams`(0x1B)/
  `ul_max_size`(0x1C)/`dl_min_padding`(0x19); negotiated maxima logged + stored.
- **rmnet UL egress aggregation** — mainline has NO `IFLA_RMNET_UL_AGG_PARAMS`;
  it's the ethtool **TX_AGGR coalesce** (default off). New genl helper
  `qmit_rmnet_tx_aggr` (wwand-io.c) + best-effort `netlink.setup` wire-up.
- **Dynamic endpoint type** — `netlink.ep_type_number` (HSUSB/PCIE from the bus);
  fixes PCIe modems (RG500Q/MHI) that were hardcoded HSUSB in SET_DATA_FORMAT +
  BIND_MUX. AW1000-relevant.
- **BIND_MUX `client_type`=1 (tethered)** TLV 0x13.
- **link_state per-mux gate** — vendor qmi_wwan_q sysfs, existence-gated best-effort
  (no-op mainline; opens the mux on a vendor kernel).

NCM backend parity (modem_ncm/context_ncm, host-tested — 242 is QMI so no HW yet):
- **5G-SA registration** — `parse_creg` widened to `+C5GREG` (POSIX ERE capturing
  group), register poll now CEREG → **C5GREG** → CREG (SA modems read CEREG
  not-registered while attached via 5GS only).
- **Fibocom auth = `+MGAUTH`** (FM150/FM350 reject `+CGAUTH`).
- **New vendor dial verbs** — gosuncn `+ZECMCALL`, neoway `$MYUSBNETACT`, telit
  fallback `#ICMAUTOCONN`, meig fallback 5-arg `$QCRMCALL=1,0,3,2,<cid>`.
- **Universal `AT+CGPADDR` liveness** — for vendors with neither a byte counter nor
  a dial status query (previously zero liveness); conservative, only trips on a
  clearly-empty reply for our cid.
- **`0.0.0.0`/`::` guard** in `build_settings`. (Autodial modems — Huawei-unisoc
  `^SETAUTODIAL`, neoway — deferred; needs HW.)

## test_context was silently running only 4/20 scenarios — fixed (2026-07-26)

Found while adding a mux-bind assertion: **`test_context.uc` silently executed only
the first 4 scenarios** (dual, v6-degrade, v4-fatal, disconnect) and reported "27
checks, 0 failures". Every scenario that defers its assertions / `next()` to a
`uloop.timer` *after* connect — disconnect teardown, admin-down, pdp-update,
**mux-bind**, reconnect, zero-rx watchdog, data-stats, … (~16) — **never ran**, so
their assertions had never validated. Root cause: on the host ucode build a
`uloop.timer` scheduled from inside the mock-driven callback chain (mockhub delivers
via `uloop.timer(0)`, no fd) does not fire under a single `uloop.run()` — the loop
returns once the current delivery wave drains (0.04 s, no guard timeout). Isolation
proves plain `uloop.run()` DOES block on top-level timers, so it's the mock async
chain, not uloop. Neither a parked pipe fd via `uloop.handle`, a self-rescheduling
keepalive, `uloop.interval`, nor globally-held timers kept it alive.

**Fix:** pump `uloop.run(2)` in short slices until all scenarios are consumed
(wall-clock advances so the deferred one-shot timers become due and fire). Now
**17/20 scenarios validate** (85 checks, was 27) — including the mux-bind
`client_type` TLV assertion, which passes. The 3 telemetry scenarios (zero-rx,
zero-rx-quiet, data-stats) rely on a *self-rescheduling* QMI-round-trip sampler that
the re-entrant pump still can't drive; they **self-skip with a printed note** rather
than silently pass. Proper full fix = an **fd-backed mock hub** so `uloop.run()`
blocks like production (transport.uc registers the cdc-wdm fd) — deferred.

## VRF vs policy-routing — HW deep-dive (2026-07-26)

Tried converting 242 (NR7101, Telekom, **public** WAN `2.164.26.219` + v6 GUA,
reachable from the internet) from policy routing to a VRF per the docs. Deep HW
investigation; 242 restored to the working policy-routing baseline afterwards (LAN
untouched throughout).

- **VRF instantiation gaps (docs fixed):** a `config device type 'vrf'` only comes
  up when an interface references it → needs `config interface 'vrf_wan' proto
  'none' device 'vrf_wan'`; and a **full `network restart`** (not `reload`) to
  enslave the members. The member interfaces must keep `ip4table=<vrf-table>` or
  the default route leaks to `main`. The `l3mdev` FIB rule (v4+v6) **and** the VRF
  master itself **are** auto-created by the kernel/netifd on every (cold) boot —
  an earlier hotplug helper adding them by hand was pure redundancy
  (cold-boot-verified).
- **More VRF sharp edges found on HW (all reproduced, all documented):**
  - *dmz→wan outbound is dropped.* With **both** members in one VRF the l3mdev
    rewrites the ingress iif to the master `vrf_wan` for **all** inter-member
    forwarding, so fw4 can no longer tell dmz-sourced from wan-sourced traffic.
    The `vrf_wan`-in-wan-zone fix (needed so the **inbound** DNAT return matches a
    zone) then misclassifies the DMZ host's **outbound** (`iif=vrf_wan` → wan) as
    wan→wan → dropped (`drop wan out: IN=vrf_wan OUT=wwan0m1`, HW-seen with the DMZ
    host's IKE/UDP-4500). Policy routing keeps the real iif (`br-lan.20`=dmz) so
    dmz→wan just works.
  - *v6 return needs a non-source-specific default.* The cellular v6 default is
    source-scoped (`from <WAN /64>`); on the DNAT reply the source is un-NAT'd only
    at postrouting, so at routing time it is still the DMZ host's addr → no match →
    `unreachable`, dropped before `forward`. Fixed with a catch-all `config route6`
    (device default) in the VRF table. (Applies to policy routing too.)
  - *static DMZ IPv6 is flushed on enslavement.* The kernel keeps IPv4 but drops
    IPv6 on a master change; netifd never notices (only listens to `RTNLGRP_LINK`,
    never `RTM_DELADDR`) → the static ULA is gone after boot until an `ifup`. Clean
    fix is a sysctl, `net.ipv6.conf.{default,all}.keep_addr_on_down=1`
    (`/etc/sysctl.d/`), cold-boot-verified. No netifd patch needed.
- **Hard limit (docs' new caveat):** router-**terminated** traffic on the WAN IP
  is broken under VRF — HW-confirmed for **ICMP and TCP** (request in, no reply
  out). Root cause is *below* the firewall: the router's locally-generated reply
  is not VRF-associated, routes to the raw slave **without** the l3mdev
  `<redirect>`, and cannot egress. Proven that no fw4/nftables change fixes it
  (accept rules, `notrack` both legs, master-in-zone all just shifted the
  symptom); secondary fw4 effects (untracked→`ct state invalid` drop, forward
  reclassification via l3mdev double-traversal) are real but downstream. Forwarded
  traffic (inbound→DMZ host, `iif=VRF`) does get the redirect and works.
- **Verdict:** **242 left on policy routing (Variant 1)** — it does everything
  natively and cleanly: bidirectional DMZ forwarding (in **and** out, incl. the
  DMZ host's own IKE), inbound DNAT (v4 404 + v6 handshake), and router-terminated
  traffic on the cellular WAN IP (ping from the WAN IP, 0% loss). VRF *can* be made
  to forward inbound with a stack of fixes (master-in-zone, catch-all route6,
  keep_addr_on_down sysctl, on-link SNAT, ICMPv6-allow) but still cannot do
  router-terminated WAN traffic or clean bidirectional dmz↔wan — it is only worth
  it for a strictly forward-only uplink. reference.md Variant 2 carries all the
  VRF fixes + caveats; Variant 1 remains the tested/recommended model.

## Device name as a first-class handle (2026-07-26)

- **Daemon write-back.** On `registered` the daemon materialises the resolved l3
  device name onto the interface as `option device` (`main.uc` `learn_device`,
  triggered in `daemon.uc` via `derive_netdev`; forward-declared to dodge the ucode
  TDZ trap). Idempotent, never clobbers a user value (device-name sovereignty),
  `commit`-only (no interface bounce). Off-switch `wwand_globals.write_device`
  (default on). Status now also reports `contexts[].l3_device`.
- **Config-path hardening (`config.uc`).** Both the native and compat paths now
  treat `device`+`mux_id` identically: a bare-netdev `device` + `mux_id` derives
  `<netdev>m<mux_id>` (regression: it named the child the same as the parent), and
  the compat path honours a separate `mux_id` (previously ignored). New
  `test_config` cases cover both; `test_daemon` covers the write-back.
- **rmnet kernel readback (C).** `io/src/wwand-io.c` gains `rmnet_mux_id(name)`
  (RTM_GETLINK + parse `IFLA_RMNET_MUX_ID`); `netlink.uc` reads it when adopting a
  pre-existing rmnet child on restart and warns on a config-vs-kernel mismatch.
  qmimux has no such attribute → stays daemon-remembered.
- **LuCI.** `wwand.js` stops stripping `interface.device` (it's the l3 handle now,
  not a legacy inline modem netdev) and adds an editable **L3 device** field
  (empty = daemon auto-fill, set = user override). `node --check` clean.
- All 31 host suites green (`test_config` 135, `test_daemon` 49).
- **HW-validated on 245 (RG650E/QMI, live Vodafone session):** wwand restart wrote
  `network.wwan0m1.device='wwan0m1'` (`learn_device` logged once) with **no
  connection bounce** (IP unchanged across two restarts); the C
  `rmnet_mux_id('wwan0m1')` read back `1` from the kernel; idempotent on the 2nd
  restart (no re-write). LuCI JS deployed (RW field pending a browser look).
  No-clobber is unit-tested (same early-return as the HW-proven idempotency).

## Deployment docs + IPv6-PD analysis (2026-07-26)

- **New `## Deployment examples` section** in `docs/reference.md`: a DMZ-host
  scenario (all inbound → one local v4/v6 host) in full dual-stack, with two
  routing variants — **policy routing** (`ip4table`/`ip6table`, netifd
  auto-generates the source `ip rule`s) and **VRF** (`config device type 'vrf'`).
  Documents the firewall/VRF specialities: fw4 is VRF-agnostic (zones bind to the
  member L3 devices, not the VRF master), `tcp_l3mdev`/`udp_l3mdev` is a **global**
  `config globals` switch, and the double-traversal caveat (`/etc/nftables.d/`).
  `docs/architecture.md` gained the netdev-recreate VRF-enslavement window note +
  an IPv6 addressing/PD subsection.
- **IPv6 prefix delegation — analysis + design + HW verdict.** Established that
  wwand does **no IA_PD** today (single WAN `/64`, RFC-7278 shared). True PD is a
  DHCPv6 IA_PD exchange with the P-GW, so the design is **PD on top**: a stacked
  `proto dhcpv6` interface (`device @wan`, `reqaddress none`, `reqprefix auto`)
  while wwand keeps owning the GUA. Feasibility knot found by reading odhcp6c
  (`10a52220`): it has **no source-address control** (binds `::`, sends to
  `ff02::1:2` with no `IPV6_PKTINFO` source), so the kernel picks the source
  (RFC 6724 → link-local if present).
- **HW test (245 Vodafone `web.vodafone.de`, 242 Telekom `nonbonding.hybrid`):**
  ran a PD-only `odhcp6c -N none -P 0` on `wwan0m1` with tcpdump. Default SOLICIT
  sources from **link-local** → **no response** on either carrier. Forced the
  **GUA** source (temporarily removed the interface LL — v6 gateway is global, so
  routing was unaffected) → SOLICIT now from the GUA, **still no response**.
  **Verdict: neither Vodafone DE nor Telekom DE answers DHCPv6-PD over the mobile
  bearer here — the source address is NOT the blocker, the network offers no PD.**
  Consequence: the **odhcp6c `-G` patch is not justified** (would not help) and the
  optional `ipv6_share_prefix` knob is unneeded — the **RFC-7278 `/64` sharing
  wwand already does is the correct and only mechanism** for these carriers. PD
  stays carrier-dependent as documented; other networks/business APNs may differ.
  Deployment docs (reference.md `## Deployment examples`) are the shipped
  deliverable; no odhcp6c/wwand code change needed. Plan (for reference):
  `~/.claude/plans/parallel-cooking-cloud.md`.

## SMS + fixes (2026-07-25)

- **SMS receive/list · read · delete** (no send) across all backends, HW-validated
  on 245 (RG650E) + 246 (EG06). New `sms_pdu.uc` (GSM 03.40 decoder — 7-bit incl.
  umlauts/UCS2/alphanumeric-sender/multipart, tested on real Vodafone PDUs),
  `codec/schema/wms.uc` (QMI WMS, vs libqmi 1.38), `sms.uc` (backend ladder: QMI
  WMS native/passthrough → native MBIM SMS → AT, probed by a real List so the
  RG650E's `MISSING_ARGUMENT` falls to AT), `modem_mbim._ensure_wms` (passthrough)
  + `mbim_backend.sms_read_all/sms_delete` (native `uuid_sms`, validated identical
  to passthrough on the EG06). ubus `modem_sms_list/read/delete`; LuCI SMS tab on
  Modem Tools. Tests: `test_sms_pdu`, `test_wms`, `test_sms`, `test_mbim_backend`.
- **Fix — telemetry/serving:** `_update_serving` replaced `self.reg` wholesale, so
  a cell-reselection SERVING_SYSTEM_IND that omits the optional Current-PLMN/roaming
  TLV wiped the operator line; now carried forward.
- **Fix — stuck-pending interface:** the `registered` handler treated a netifd
  `pending` interface (orphaned after a wwand restart mid-setup) as "down" and
  kicked it with a no-op `up`; now it `down`s a pending+IDLE interface first, then
  re-runs setup (HW-validated self-heal on 245).

_Earlier baseline: 27 suites (~1005 checks). Deep-review follow-ups #1/#2/#4/#5 +
minor-hardening done; #3 scaffolding consolidated._

## Next TODO — deep-review follow-ups (2026-07-23)

A full architecture/correctness/test review ran (codec verified clean vs libqmi
1.38 / libmbim 1.32 — no schema drift). The trivial-but-real bugs are **fixed**
(commit `222798d`): unbounded MBIM decode loops bounded, `ref-ipv4/ipv6` unpack
guarded, structural **never-SYNC rail** in `qmi_over_mbim.send` (+ test),
hotplug `cdc-wdm1`↔`cdc-wdm10` substring match → basename-exact, `self.dsd` CID
released on teardown. Remaining, ranked by value:

1. ✅ **DONE (`bc7a675`) — `test_daemon` 3 → 47 checks.** Root cause was a single
   missing mock handler (`GET_CURRENT_DATA_BEARER_TECHNOLOGY`): context bring-up's
   `get_bearer` hit mockhub's `die()`, which unwound `uloop.run()` from inside a
   uloop callback before any deferred ubus reply (or the 5 s guard) fired — so the
   whole no-proto-task lifecycle went untested while the suite showed "3 checks,
   0 failures". Added the handler + a **completion sentinel** (innermost callback
   sets a flag asserted after `uloop.run()`), so any future die-unwind now FAILS
   visibly instead of silently shrinking the check count.
2. ✅ **DONE (`ecf6953`) — recovery skippable rungs fixed.** Replaced exact
   `==8/16/24` rung matching with a **fired-once threshold crossing** over a
   persisted `rung` index: each rung fires once, in order, robust to a counter
   jump (never skips) and to a daemon restart mid-outage (rung index persisted;
   legacy state files default it from the restored attempt count). +12 tests.
   **Double-count finding:** empirically the common context-activation-failure
   path is **1:1** (each retry = one increment via the daemon `error` path); the
   modem `fail()` path only fires during bring-up (modem not READY), so the two
   callers are mutually exclusive there — the "~2×" does not reproduce. The
   narrow deregister-mid-session overlap stays theoretical, and the rung-crossing
   neutralizes its only real harm (skipped rungs). A true single-owner refactor
   of the counter is **not pursued** — low value, and the caller path is
   HW-critical WAN code better left untouched without HW validation.
3. **Three forked state machines → real shared core.** *Partially done — the
   three concrete duplications the review named are consolidated:*
   - ✅ zero-rx watchdog (3 copies) → `context_common.uc` (`zero_rx_limit_ms` +
     `rx_stall_watch`), commit `f09be7d`, +22 tests.
   - ✅ fast "watch" telemetry loop (2 copies, "Mirrors modem.uc") →
     `modem_common.watch_driver`, commit `e0d3b2e`, +12 tests.
   - ✅ `dsd_from_serving`/`dsd_from_radio` helpers → `modem_common`, commit
     `220130e`. The rest of the `_ca_be`/`_dsd_be` resolvers stays per-backend
     on purpose (candidate lists genuinely differ: `self.nas` vs the lazy
     passthrough `self.pt.nas`, plus MBIM's native candidate — folding them
     would add parameterisation without real dedup).

   **Scaffolding — now consolidated** (`805b97e`, `5c016ee`, `589120a`,
   `d8f1763`, `f7a5d2e`). `modem_common` grew a shared core the three modems now
   install instead of each carrying a copy:
   - `scaffolding(self, {deps,log,rec})` — `emit`/`notify_contexts`/`set_state`/
     `attach_context`/`note_connect_success`/`trip_zero_rx`/`stop`/`_device_gone`
     (all byte-identical before).
   - `make_fail(self, …)` — the `fail()`+backoff handler (was 3 near-copies; also
     fixed a real divergence — MBIM/NCM now emit the `'error'` event QMI always
     did).
   - `note_connect_failure_light(self, rec)` — the MBIM/NCM "light" recovery
     passthrough (QMI keeps its dms-cycling version).
   - `watch_driver` now drives the fast-telemetry cadence for **all three**
     (NCM was migrated too — it had the same loop).

   Net −68 LOC despite ~250 new test lines; the real win is one source of truth
   (test_modem_common 65 checks) + the divergence fix. **Remaining fork is
   genuine, not duplication:** the per-protocol step chains, `with_nas`, the
   teardown bodies (client destruction differs), and QMI's CID alloc/release —
   these are legitimately backend-specific and not worth forcing together.
4. ✅ **DONE (`d406ce4`) — `qmi_backend` telemetry suite.** New `test_qmi_backend`
   (24 checks), the QMI analogue of `test_mbim_backend`: each op (`get_ca`/
   `get_data_mode`/`get_reg_detail`/`get_packet_stats`/`get_bearer`/
   `get_channel_rates`) runs against a real QMI client on the mock hub, answered
   with a hand-built TLV block via a new mockhub `__raw` path (bypasses
   `tlv.pack`), so the schema's own decode runs — verified it bites (corrupting
   the pcell tag 0x13→0x33 fails the suite). mockhub also gained the DSD service.
5. ✅ **DONE (`11ceac7`) — at2 telemetry channel opened lazily.** `open_at` now
   stashes a one-shot opener; `modem_common.telemetry_at(self)` runs it on the
   first telemetry poll and returns the dedicated engine thereafter, else the
   control channel. QMI/MBIM only open at2 if/when they hit the AT fallback
   (often never); NCM opens it on its first tick (same end state). All telemetry
   sends route through `telemetry_at`. +16 tests.

Minor/latent hardening — **all done**:
- ✅ `client.uc` txn-collision: `alloc_txn` skips in-flight ids, never overwrites
  a pending slot (`e286623`).
- ✅ `hold_max` live on reload via `daemon.set_hold_max_ms` + status exposure
  (`4d759c5`).
- ✅ `wanted` cleared at the daemon-driven down (hold expiry + sim_blocked),
  closing the re-kick race (`c7116b1`).
- ✅ `encode_info` arrays now `die()` loudly instead of emitting a corrupt buffer;
  orphaned `encode_struct` removed (`5bee835`).
- ✅ modeswitch liveness watchdog: a non-re-enumerating usbnet switch is flagged
  in status (`control_note`) instead of silently unmanaged (`c36c706`).
  protoswitch left as-is — its failure is already visible (modem → `ABSENT` in
  status), user-initiated, and not once-guarded, so no silent-stuck class exists.
- ✅ deferred ubus replies routed through a `defer()` helper with a once-guard +
  backstop watchdog (300s; > any real op), so a dropped backend callback can't
  leak the request open (`e37fd1e`).

**Deferred (needs HW):** NCM ECM end-to-end (usbnet switch blocked on RG650E
firmware); Huawei/MeiG NCM telemetry recipes need bench verification.

## Multi-backend + parity work (recent, all committed)

wwand now has **three control backends** selected per modem by
`discovery.resolve_control` (cdc-wdm→qmi/mbim, cdc_ncm/cdc_ether→ncm, serial-only
→ppp with a one-time usbnet mode-switch), plus hotplug rediscovery
(`files/wwand.hotplug.net`).

- **MBIM → full CDC telemetry parity (HW-verified, EG06/246).** Shared AT
  bring-up (`modem_common.open_at`); a **QMI-over-MBIM passthrough** shim
  (`qmi_over_mbim.uc`) tunnels the whole QMI stack over the MBIM channel; native
  MBIM decode (`mbim_backend.uc` / MS Basic Connect Extensions); per-capability
  `backend.choose` (passthrough-first — reuses the trusted QMI decode; native
  MBIM as fallback). Live signal/cells/CA/data-mode over MBIM without disrupting
  the session. **Rule: never CTL SYNC over the passthrough** (memory
  `qmi-over-mbim-passthrough`).
- **NCM backend** (`modem_ncm.uc`/`context_ncm.uc`) — AT-controlled,
  cdc_ncm/cdc_ether datapath, IP via CGCONTRDP, multi-vendor dial (per-modem
  resolved: Quectel QNETDEVCTL→CGACT fallback, MeiG, Huawei, …), QICSGP auth.
  Core AT HW-validated on the RG650E; full ECM end-to-end HW test blocked
  (memory `ncm-backend-status`). Telemetry parity (multi-vendor) in progress.
- **Config parity + network selection** — `modem_get/set_settings` now protocol-
  neutral (MBIM via the passthrough NAS, HW-verified); `modem_scan` +
  `modem_set_network_selection` (NAS NETWORK_SCAN / AT COPS).
- **Init config validation** — `modem.validate_config` compares the live modem to
  config + `modem_quirks.uc`, surfaces `config_warnings` on status (gated
  `auto_correct`, default off).
- **LuCI settings editor** — band pickers, network-selection scan panel,
  cell-lock editing, config-warnings banner.
- **Empty/unset APN** — read the SIM/modem-provisioned APN, log it, use it (no
  blank write); attach APN reported on registration errors.

---

_Earlier robustness pass (committed): MBIM zero-rx watchdog + `hold_max` UCI._

## Current state

The planning tail that used to live here (multi-protocol backend abstraction
"in progress", pending items, "where we are") is superseded: all three control
backends (QMI, MBIM, NCM) are shipped and HW-validated. For the up-to-date
picture read the dated entries above (newest first) and
[backend-interface.md → Status (realized)](backend-interface.md#status-realized).
