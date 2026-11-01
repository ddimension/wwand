# wwand — status archive

The dated continuation log, newest first. This is HISTORY: an entry describes
what was true when it was written, not what is true now. For the current state
read `STATUS.md`; for beliefs that turned out to be wrong read `gotchas.md`.

It lives apart from `STATUS.md` because the two are read for different reasons
and mixing them was actively misleading — a 2000-line log with the current state
buried at the top invites reading an old entry as present tense.

---

## Moved from STATUS.md (2026-10-24)

The dated topic notes STATUS.md carried until 2026-10-24, verbatim, newest
first. Each section is as it stood on that day.

### The zero-rx watchdog resets a modem the board cannot repower (2026-10-24)

The zero-rx watchdog (inbound bytes frozen while QMI still reports the bearer
CONNECTED) used to call `usb_repower()` and stop there. On a self-powered
PCIe/MHI modem with no board profile that is a no-op — no USB power GPIO, no
`reset_gpio` — so a bearer that stalled with the session still reported
CONNECTED was never cleared and the link sat dead until a human intervened.
`trip_zero_rx` now asks `recovery.can_repower()` first: where the board **can**
repower it still does, and only where it cannot does it fall through to a
**modem reset** — the rung that actually clears such a stall (the gentler retry
/ opmode-cycle rungs do nothing for it). `can_repower()` prefers the daemon's
mechanism-aware answer (`board_can_repower`, built from the real `reset_gpio` /
`power_gpio`) over the mere presence of the repower closure: the daemon hands
that closure to the recovery even where it no-ops, so its presence alone cannot
tell "no mechanism here" from "refused". The reset keeps `usb_repower()`'s
evidence rule (never a modem that has never answered us) and does not cut across
an in-flight reattach, a low-power park, or a detach; a per-modem latch keeps two
contexts that trip on the same tick to a single reset. (ddimension/wwand#59.)

### Issue round 2026-10-13: AT port walk past an unopenable tty; MBIM settings refresh

- **#52 (T99W175, USB mode):** the AT search ended at a tty that would not
  open (`ttyUSB1`, "No such file or directory") and went straight to the
  MBIM pipe, never trying `ttyUSB2`, where the modem answers. An unopenable
  port is now skipped like a mute one (`modem_common.uc open_at_tty`); the
  wdm/MBIM fallbacks follow only when no tty is left. Workaround on older
  builds: `option tty '/dev/ttyUSB2'`.
- **#51 (RM520N, MBIMEx 3.0):** `IP_CONFIGURATION` answered at connect,
  Failure (status 2) to every periodic refresh, traffic fine — each refusal
  counted as a protocol error and the next success reset it: a sawtooth in
  collectd's proto_errors. The refresh is now `no_recovery`, logged once per
  run of refusals, the settings kept, and sent after the statistics answer
  instead of beside it (whether the overlap is what the modem refuses is
  unproven — the order costs nothing).
- **#51 follow-up:** the eUICC discovery on a plain SIM (MBIM UICC SelectFailed,
  QMI OPEN_LOGICAL_CHANNEL) counted toward the protocol-error ceiling at every
  start; the ISD-R discovery opens are `no_recovery` now (`sim.uc` NOT_A_FAULT).
- **#52 follow-up:** T99W175 in USB mode (05c6:90d5) pinned in `atcmd.uc`
  LOCAL_PORTS: if5 = AT (if0 DIAG, if4 has no bulk endpoints).
- **#52 feature (asked for by the reporter, approved 2026-10-14):** `option
  recovery_steps` on `wwand_modem` — the attempt counts of the radio cycle,
  modem reset and hardware rung (default 8 16 24; 1-3 rising numbers, the
  first ones replacing the defaults). `recovery.uc steps_from` / per-instance
  RUNGS, `config.uc steps_opt` (refused with a warning, never half-applied),
  status ladder (`recovery.rungs(failreboot, steps)`), LuCI modem option.
- **HW 2026-10-15, eSIM:** 245 (RG650E, QMI): with the eUICC in physical slot 2
  active, QMI logical channels need logical slot 1 — fixed (`sim.uc
  uim_slot`, switch records the active slot). 3.93 (RM520N-GL): eSIM over QMI
  and over **native MBIM UICC** (first HW proof: open/APDU/close, EID +
  profiles), named open failure `select_failed`/SW 6A82 on a plain SIM; the
  MBIM group close is refused (INVALID_LOGICAL_CHANNEL) by that firmware.
- **PR #56 (xhudan) taken with a follow-up:** QMI-context AT+QENG goes through
  telemetry_at (his commit). telemetry_at retired on ERROR only, and the case
  was timeouts — so a timeout now counts when the port answered another
  command since this one last went silent; 5 retire it (`modem_common.uc`
  AT_RETIRE_SILENT_AFTER). A port that answers nothing retires nothing.
- **Issue round 2026-10-15:** #55 (SG500M2-X, MBIM) — *Reset to defaults*
  sent bands 1–63/1–79 with the RAT reset in one SET; the firmware refused the
  bands (qmi 3) and with them the RAT reset, silently. Now DMS Get Band
  Capabilities (`dms.uc`, `band_caps`) gives the real band list, and a refused
  band set is re-sent without bands (`partial`, `refused`). #57 (EG12-EA) —
  the eUICC probe stops at the first ANSWERED refusal (`sim.uc
  refused_answer`; QMI transient codes excluded), retries only when the
  transport could not ask; a card change re-asks. #52 — MBIM identity asks
  AT+GMI first (T99W175 answers AT+CGMI without OK).
- **CREDITS.md (2026-10-24):** everyone who contributed through PRs, issues or
  review, across the wwand repos and the two upstream submissions (by GitHub
  account, generated from the history). Add a name when a new one turns up.
- **PR #60 (xhudan) merged with a follow-up:** a SEPARATE at2 telemetry
  channel that answers nothing for 20 telemetry commands is closed and
  telemetry falls back to the control engine (never the control engine
  itself — that would strand an NCM modem). So "a port that answers nothing
  retires nothing" (#56) now holds per command only. The PR made
  atcmd.close() complete queued callbacks for EVERY caller; Codex found that
  re-arms NCM's cfun timers, advances init chains and counts failures during
  teardown — so close() drops silently again (what every teardown is written
  against) and the give-up uses the new atcmd.abort(), after switching
  telemetry to the control engine. PR #65 (xhudan) merged: zero-rx resets a
  modem the board cannot repower (#59); a failed reset is logged.
- **Remote SIM status (2026-10-24):** a Quectel lists QMI UIM Remote only with
  its EFS switch on (read at boot) — the RG502Q-EA and EG06-E listed it after
  00 -> 01 + reset. `remote_sim` therefore said "the modem offers no UIM
  Remote" for a modem that was merely switched off; the daemon now reads the
  switch once per modem from the tick and reports `switch` + the remedy.
- **HW run 2026-10-24 (hwtest/, 5 devices on main):** a legacy-only LTE modem
  (BG96: GET reports no ext_lte_band) got the extended TLV ALONE for an
  unchanged band list and refused it (MISSING_ARGUMENT 17) — the guard now
  compares it against the legacy mask (`netsel_ops.uc` modem_set_settings).
  Open: bands > 64 on such a modem still go out as the extended TLV alone.
  The BG96 also accepts a legacy band change without applying it.
- **Anchors (2026-10-24):** ~100 in-tree `file:line` anchors had drifted onto
  lines that still exist (check-anchors cannot see that) — repointed after
  reading each against the code it describes. **Open, documented:** a modem
  with ONE dead QMI service is never recovered (proto counter per modem, any
  answer resets it) — analysis and options in `docs/design/dead-service-recovery.md`,
  decision (auto-recover vs. report only) pending.
- **#67 (FM350-GL, snapshot):** a feed build from after OpenWrt master moved
  libucode 20230711 -> 20261009 (2026-10-19) was installed onto an older
  snapshot and died on the missing `libucode.so.20261009`. Feed: `wwand` gets
  `EXTRA_DEPENDS ucode (>=<the SDK's ucode date>)`, so apk refuses instead
  (deliberately not `+libucode`: it would keep the old library on a later
  upgrade and load two ABIs into one process). `files/wwand.init` now also
  probes `wwand_io` and says what to do on that dlopen error.
- **Issue round 2026-10-24:** #39 regression (MassiPi) — "session closed: card
  removed" stood on the status after a slot switch and a switch back: the
  leaving card's SESSION_CLOSED_IND arrives after card_changed cleared the
  note. A UIM card note now ignores an indication naming another slot than
  the active one and carries the ICCID it was set under; status shows it only
  for that card. #68 rf band change → debug. #71 interface refs accept
  `@iface` and an unambiguous L3 device (watchcat passes those). #61
  follow-up: held-back QRTR requests are not counted as protocol errors.
- **Issue round 2026-10-19:** #61 (RG520N-EB, QMI over QRTR) — the daemon froze
  inside `sendto()`: QRTR's tx flow control sleeps a sender at 10 unconfirmed
  packets per destination whatever SOCK_NONBLOCK says, and our EINTR retry kept
  it there through SIGTERM. `qmit_qsend` bounds the wait (SIGALRM, 500 ms) and
  answers `'blocked'`; the hub fails that service's requests and probes it every
  30 s until it answers (`docs/gotchas.md`). Not HW-verified (no QRTR modem
  here). HW-confirmed by the reporter (2026-10-21: 22 h, no freeze). Requests
  the hub holds back during the 30 s pause fail as `'held'` and are not counted
  as protocol errors (only the attempts are), so one long command cannot climb
  the ladder. Open: a modem with ONE dead service is never reset — the proto
  counter is per modem and any answered request resets it; that needs a
  per-service streak or a hub-level "stuck" signal (not built).
- **#62 (EG12-EA):** a band change was written alone; the modem lost its
  serving band, dropped the bearer and sat in "EMM detached [limited service]"
  — no registration, so nothing re-armed the interface, and the ladder's opmode
  cycle would have come ~30 min later. A band/RAT change now runs inside
  `with_sessions_released` and ends in the backend's reattach (`netsel_ops.uc
  modem_set_settings`, result `reattached`). Asked the reporter whether the
  Reattach button alone recovers the stuck state (else a SIM power cycle is
  the step). HW 2026-10-19 on 3.93 (RM520N-GL, QMI, not connected): band
  write -> DMS low_power -> online in 2 s, `reattached: true`; list restored.
- **Issue round 2026-10-17:** #58 (EG12-EA) — a multi-cell `lock_4g` went
  out as `AT+QNWLOCK="common/4g_ext"`, which that firmware refuses. The second
  field of `"common/4g"` is the cell COUNT (RG650E `=?`: `(0-10),<freq>,<pci>`),
  so every lock now uses `common/4g` (`atcmd.uc cell_lock_commands`) — which is
  also the only form the lock check and telemetry read; a 4g_ext lock read
  "not applied" there even on the RG650E. Not HW-verified on an EG12.
- **MS UICC text pass (2026-10-14):** MBIM ready state 7 "no eSIM profile
  enabled" stops at the SIM step (`no_esim_profile`, no ladder) and resumes by a
  10 s ready-state poll (the indication handler only exists after
  registration — so `sim_absent` on MBIM now resumes on card insertion too);
  OPEN_CHANNEL failures named with SW1 SW2 (`mbim_client` `keep_info`); own
  channel group 0x7777, swept once per modem run before the first open.
  Not HW-verified (no eUICC-capable MBIM modem). Noted, not changed: lpac
  sends APDUs as class type Inter-Industry, wwand as Extended (ETSI 102 221,
  which GP STORE DATA CLA 80 belongs to); TERMINAL_CAPABILITY unused.
- **PR #53 (closed):** automatic IPv6 suppression after refusals declined —
  `pdp_type` is the operator's; instead a typed refusal (internal 210, 3GPP
  50; `callend.uc ipv6_refused`) logs once per context which option ends it
  (`context.uc`, the v6 degrade branch).

### A reattach stops the PDNs before it detaches; operator detach/attach (2026-10-10)

`modem_reattach` (ubus) and the recovery ladder's opmode-cycle rung took the
radio off — QMI DMS low_power, MBIM radio off, NCM CFUN=0, or `AT+COPS=2` — with
the data sessions still up. The network then tears the bearers down implicitly
with the detach and the modem learns of it from the call-end that follows,
while the daemon is already redialling into the radio-off window. Now
`modem_common.scaffolding` `with_sessions_released` stops every CONNECTED
context first (`ctx.down(cb, reason)`: STOP_NETWORK / MBIM deactivate /
CGACT=0), holds the daemon's reconnect off (`_reattaching`, also honoured by
`reconnect.uc retry_activate`), runs the cycle, and hands the stopped contexts
back (`sessions_released` → daemon reconnect, which waits for READY). Used by
`modem_reattach`, the daemon's radio cycle after an unanswered dial, and the
ladder rung on all three backends. Suspected link to the "Insufficient
resources" rejects after a reattach — not proven; re-check on HW.

New: **`modem_detach` / `modem_attach`** (ubus, `wwandctl detach|attach`, LuCI
modem list → Detach/Attach, status row "detached by the operator"). Detach =
sessions end (reason `admin`), then PS detach with the radio on: QMI NAS Attach
Detach 0x0023 (libqmi 1.38, action 2/1), MBIM PACKET_SERVICE set, AT+CGATT.
The modem stays detached (`detached`, park semantics: no re-registration, no
ladder, no redial, ifup refused `detached` → netifd DETACHED) until attach or
a modem reset (a daemon restart forgets only the mark; a QMI modem stays
PS-detached — attach first). AT attach/reattach wait for the registration
(CEREG/CGREG poll, 60 s) before re-dialling: COPS=0 and CGATT=1 answer
before it (MeiG SLM770A). HW-tested 2026-10-10: 245 (RG650E, QMI), 242
(QMI), 192.168.1.1 (Zyxel LTE3301, BG96 QMI on GSM — registration kept, the
attach re-arms at once), 3.113 (Cudy LT300, MeiG, AT/NCM). Not tested: MBIM
(246 offline), 3.93 (modem not registering — reattach/detach/attach ran with
no session).

Seen on the Cudy LT300 (MeiG SLM770A, AT/NCM) and NOT new — the previous
main does the same, 3 of 3 runs: after an AT reattach (COPS=2/0) the dial
`AT+ECMDUP=1,1,1` answers ERROR although CEREG says registered, until the
network has re-established the default bearer by itself (then "cid 1 already
connected, adopting"), sometimes only after the ladder's radio cycle at attempt
8 (2026-10-10). Open: whether ECMDUP needs the bearer the MeiG brings up on
its own, i.e. adopt-first after a reattach on this modem.

Still the old order: the init attach-profile radio cycle (no live session
normally at that point).

### Profile flags: IPv6 prefix delegation, CLAT, address allocation (2026-10-09)

Three interface options, all tri-state (unset = the modem profile is left as it
is): `ipv6_pd`, `clat`, `address_allocation` (`nas`|`dhcp`). QMI has all three;
NCM has `address_allocation` (CGDCONT field 7, every vendor) and `ipv6_pd`
(Quectel `AT+QIP6CFG`, flag and prefix read); MBIM has no field for any of them
(libmbim 1.32). They are
stored WDS profile settings (TLV 0xDF / 0xDE / 0x2D, libqmi 1.38), written
read-before-write on the dialled profile and on the attach profile through one
table, `context.uc PROFILE_FLAGS`.

The delegated prefix itself is read back with Qualcomm's vendor WDS message
0x00AC (not in libqmi; layout from the RG650E firmware) on every IPv6 settings
fetch, and handed to netifd as the LAN prefix with a sourced default route. A
host DHCPv6 client on the rmnet link gets no answer on these modems — the
bearer's DHCPv6 is the modem's.

HW: the flag round-trips on the RG650E (QMI 0xDF == `AT+QIP6CFG="PD_enable"`,
both directions); 0x00AC answers "nothing delegated" (INTERNAL) on the RG650E
(nonbonding.hybrid, /64) and on the RM520N-GL (v6.global-m2m.net, a PD APN in
beta). **A prefix actually delegated end to end has not been seen yet** — open
whether that APN delegates, or the modem asks only in router mode.

### QMI over QRTR, and what it showed about PCIe (2026-10-04)

ddimension/wwand#46 (xhudan) is merged: `option device 'qrtr'` runs the QMI
stack over AF_QIPCRTR for an SDX modem whose QMI lives only on the QRTR bus
(`qmi_over_qrtr.uc`, `wwand_io` qrtr_open/qsend/qread/qdiscover; HW-tested by
the author on an RG520N-EB on an IPQ5018). Fixed alongside, both generic:
- **The PCIe endpoint.** `netlink.ep_iface_number` returned nothing for a PCI
  path, so an MHI modem got no endpoint at all and refused WDA with error 70.
  PCIe now gives interface 4 (ModemManager's constant), and both endpoint
  helpers read the RESOLVED sysfs path: the kernel's link from an mhi_net
  netdev is `../../../mhi0_IP_HW0`, with the PCI address only above it. This
  reaches the existing MHI path (`/dev/wwan0qmi0`) as well — not yet seen on
  hardware.
- **The QMAP ladder** steps down on InvalidOperation (error 70) for a
  version, not only on an echoed other version; only the last rung's error
  fails, and any other error fails at once (a transient Internal must not
  leave the modem on a lower QMAP until its next init).
The hub itself, rewritten on top of #46:
- **One socket per QMI client.** On QRTR a service tells clients apart by
  their source port; there is no client id on the wire. #46 gave every client
  of a service the same cid on one socket, and wwand runs several WDS clients
  at once (the modem's own plus one per IP family and attempt), so they were
  one client on the modem. Each emulated ALLOCATE_CID now opens a socket,
  RELEASE_CID closes it, and a reply belongs to the socket it arrived on.
- **The modem's lifecycle.** The name server keeps reporting to the lookup
  socket; DMS leaving the modem's node, or showing up there on another port
  (a restart, whichever report comes first), is "device gone" (rebuild,
  vanish escalation as for a cdc-wdm); a NEW_SERVER moves any other
  service's port, and a DEL_SERVER for a port already superseded is ignored.
- **Presence.** `device 'qrtr'` is present once a node serves DMS and WDS
  (`discovery.qrtr_probe`, at most 300 ms) — WDS too, because the QMI init
  reads the service list once and a booting SDX registers its services one by
  one; a WDA registering later than WDS is still missed until the next init.
  Before that it waits like a missing cdc-wdm, retried by the tick.
  `option qrtr_node` picks among several.
- **Existing MHI users:** the PCIe endpoint (PCIE/4) now goes out on the
  `/dev/wwan0qmi0` + mhi_net path and with the vendor pcie_mhi /
  rmnet_nss_mhi add-on too, where before no endpoint was sent and a muxed
  context stopped at `endpoint_unknown`. ModemManager and quectel-CM do the
  same; not yet seen on hardware here — `ep_type`/`ep_id` override it.
- Unknown CTL requests are NotSupported instead of a fake success; a client
  whose socket cannot be opened gets ClientIdsExhausted.
- A DEL_SERVER for an endpoint its service has already left (a restart's
  re-registration arriving first) is ignored; `qdiscover` reads and writes
  the control packets little-endian, as the name server does (it was host
  order: on a big-endian target such as mips_24kc no QRTR modem would ever
  have been found).
Host-tested (`test_qmi_over_qrtr`, the presence gate in `test_daemon`); NOT
yet on hardware — nobody here has a QRTR modem, xhudan is asked to verify on
the RG520N (dual-stack, a modem reset). The feed installs
`qmi_over_qrtr.uc` in `wwand-qmi` (modem.uc imports it).

### The attach profile carries the config, always (2026-10-04)

Field case deborah-3 (LTE3301-Q222 with a Sierra MC7710 out of another box,
a fresh Telekom card): autosetup created `wwan0` without an APN; the QMI
attach step then deliberately left profile 1 as it was ("SIM-provisioned"),
autosetup saw an APN there and declined its table, and the modem attached
with a stale APN out of its previous life — limited service, registration
lost every second, every dial "no service". An APN set by hand afterwards
changed nothing until a restart. Now, decided with the user:
- QMI (`context.uc ensure_attach_profile`) and MBIM (`modem_mbim.uc
  _apply_attach`) write the CONFIGURED APN, an unset one as EMPTY (network
  default), as NCM already did at dial; `#N` alone stays untouched.
  Credentials still only with a configured APN.
- An init that reaches the attach step with no interface bound says so and
  programs it when the first one binds (`modem_common attach_context`
  -> `reapply_sim`; MBIM's `reapply_sim` now re-applies the attach too).
- A live change of APN, PDP type or login on a running modem's interface
  re-programs the attach profile (`daemon.uc apply_config` -> `reapply_sim`).
- Autosetup fills from `apndb.uc` in its own run only, whatever profile 1
  held; the marker goes on the first card read, match or not. A card that
  needs its own APN (the Telekom hybrid `nonbonding.hybrid` the table broke on
  a Chateau, 2026-09-12) gets it configured — the APN table no longer guards it.
Tests: test_context, test_modem_mbim, test_autosetup, test_deps, test_daemon
(each new check fails without its change). Not yet on hardware.

### A dial the modem never answers frees itself; our reset keeps a live session (2026-10-04)

deborah-3 again (Sierra MC7710, SWI9200X_03.05.29): after a STOP_NETWORK
the modem's WDS side hangs — every later START_NETWORK times out (120 s), not
even a new WDS client is handed out (uqmi: "Failed to connect to service"),
the modem keeps reporting the session `connected`, and only a modem reset or
a radio cycle frees it. Two ways into that, both fixed and HW-verified there:
- **wwand's own reset hit a live session.** A setup netifd held 'pending'
  (an early `busy` before the modem was ready) is reset with down+up; the
  status answer that triggers it arrives after the queued activation has
  dialled, and the down stopped that fresh session. `context_down` now keeps
  a session that is not IDLE on our own reset; the `up` takes it over.
  After a modem reset the interface comes up on the first dial.
- **ifdown -> ifup.** The stop is the operator's, so it stays; the dial that
  follows times out. A START_NETWORK that is not answered at all on a
  registered modem now cycles the radio once at once (`modem.reattach`, at
  most every 10 min per modem) instead of waiting for the ladder's cycle at
  attempt 8 (~16 min). ifdown, 10 s, ifup: connected after 126 s, by itself.
**Root cause, proven the same day (debug, with the client bookkeeping below):**
not client-ID exhaustion — wwand holds at most two WDS clients (the config
client and the dial's), every RELEASE_CID is acknowledged, and the modem kept
handing out new CIDs during the hang. The MC7710 acknowledges STOP_NETWORK
and keeps the LTE default bearer up: with wwand stopped and uqmi the only
reader, packet status read `connected` after the stop, with the very address
"stopped" (the pdh is the same 41124240 in every session). A new
START_NETWORK for it then gets no answer at all, where newer firmware says
NO_EFFECT. So the dial now asks first (GET_PACKET_SERVICE_STATUS, unmuxed and
alone on the modem only) and adopts a running session — the NO_EFFECT path.
HW: ifdown, 10 s, ifup -> up in 1 s, traffic flows. The radio cycle on an
unanswered dial stays as the safety net.
- **Client bookkeeping:** every ALLOCATE_CID/RELEASE_CID is logged with its
  result (a refused or unanswered release is a warn: the slot stays taken)
  and `status.qmi_clients` lists the CIDs wwand holds per service. Note for
  any uqmi check alongside a running wwand: both read the same cdc-wdm, and
  wwand swallows the other's CTL answers — "Failed to connect to service"
  there is the test, not the modem.
- **A CID leak did exist, on a different path:** the same bookkeeping, under
  a flapping registration (the box's `wwand_sim` set `pdp_type ipv4v6`, which
  this card only gets limited service for), showed `1:[8,17,21,25,27]` — one
  WDS CID more with every dial that registration loss aborted. The suspend
  abort empties `self.families`, but an ALLOCATE_CID still in flight answers
  afterwards; that client belonged to no attempt and the next one overwrote
  `families['4']`. `activate_family` now asks whether its attempt is still
  live and releases a late client instead (`test_context` suspend-abort-alloc,
  failing without the fix). So exhaustion WAS reachable on a long flap — just
  not the cause of the ifdown/ifup hang above.
- **The radio cycle on an unanswered dial now owns the reconnect:** the
  daemon sets `modem._reattaching` around it (released by its callback, or a
  60 s guard) and starts the reconnect when it ends — before, the next dial
  ran into the radio-off window and was aborted by the deregistration. And
  `qmi_clients` is cleared on teardown: the in-flight releases' answers die
  with CTL, so a rebuilt modem listed the old session's CIDs beside its own.
- **Left as is, by decision (Codex review 2026-10-04):** the pre-dial adoption
  trusts any CONNECTED an unmuxed WDS client reports while no other context is
  up — a bearer someone else started (modem autoconnect, a uqmi beside wwand)
  would be adopted; and the QMI attach profile writes credentials only when
  configured, so clearing or changing the APN keeps an old login there (MBIM
  writes them in full).

- **The MC7710 crashes on IPv6** (deborah-3, 2026-10-04): an ipv4v6 attach
  profile leaves it in limited service, a dial with IPv6 in it answers
  internal 204 until a reset. Quirk `ipv4_only` (modem_quirks.uc):
  `context_common.effective_pdp()` resolves every pdp_type to ipv4 for that
  model — attach profile, data profile and dialled families all read it there
  — and autosetup writes the carrier's IPv4 APN (`apn_ipv4`) with pdp ipv4.
  HW: config `ipv4v6`, attach stays pdp 0, ifdown/ifup up in 3 s.
- **No netifd reset while an activation runs:** the registered handler reset
  a `pending` interface (down + kick) even when the queued up was already
  dialling — on every plain bring-up after a modem reset. Only an IDLE context
  behind a pending setup is an orphan now.

- **GNSS over QMI LOC, in wwand-gps** (2026-10-04): a modem with `option gnss`
  and no NMEA port gets the same NMEA over QMI LOC — natively, or over the
  MBIM passthrough — into the same reader (`gps.uc loc_session`, feed-only
  reader; `modem_gps` says `source: qmi_loc`). The core's own LOC
  (`_start_loc`, `self.location`) is gone; `option location` is an alias of
  `gnss`, `modem_location` a short view over the reader, and the LOC schema
  ships in wwand-gps. New neutral hook for plugin clients:
  `client.before_release`, run by the modem ahead of the RELEASE_CID on
  teardown and extra_release (QMI and MBIM) — the LOC STOP rides it.
  HW (NR7101 / RG502Q, 2026-10-04): port and LOC both 3D; LOC needed
  periodic fixes (an absent Fix Recurrence TLV is a single fix — ~60
  sentences, then silence) and NMEA types ALL (0x1F is GPS-only; ALL gave
  GPS + GLONASS + Galileo, 33 in view instead of 14 — and the port emits them
  too afterwards, the setting is the engine's). Two reader fixes it exposed:
  a read longer than MAX_LINE (a second of multi-constellation sentences)
  dropped its first sentence as `unparsed` — the limit is on the unfinished
  tail now; and valid NMEA not interpreted (GNS, $PSTIS) counts as `ignored`.
  Teardown STOP/RELEASE twice, QMI healthy. MBIM passthrough not HW-tested.

- **netifd device detour** (2026-10-04): on `DEVICE_CLAIM_FAILED` for a wwand
  interface (netifd's stale parent record after a mux child became the
  renamed parent) the daemon points the interface at a placeholder, reloads,
  points it back, reloads — netifd frees the old record with its last user
  (`deps.uc netifd_device_detour`, `daemon.uc heal_device_claim`, at most once
  per 5 min per interface; isolated uci delta dir; an unfinished one is undone
  at start, `detour_restore`). Also: a QMI config without any mux channel
  removes the old QMAP child holding the stable name before renaming the
  parent (it was pruned only after the rename had given up — NO_DEVICE).
  HW (NR7101, mux_id 1 → 0): DEVICE_CLAIM_FAILED, detour, up 1 s later.
  Seen on the way back (mux 0 → 1 + a second interface, two rebuilds within a
  minute): the RG502Q's QMI stopped answering ALLOCATE_CID (CTL still
  answered) for 9 init attempts until a modem reset — not caused by this
  change, not yet explained; the "AT reset for a hung QMI side" did not fire.
  New checker `tools/check-ucode-pitfalls.py` (see docs/gotchas.md).

- **A QMI modem leaving QMAP at runtime** (245 / RG650E, 2026-10-05;
  mux_id auto -> 0 on a running modem). Four fixes on the way, then the one
  that made it dial:
  - a reload stopped a modem's backend in the same breath as its contexts:
    STOP_NETWORK went unanswered and the session stayed in the modem.
    stop_modem now waits for the active contexts' teardown (at most 5 s) and
    restarts the modem after it (`_retiring`);
  - WDA without QMAP left the aggregation TLVs out, so the modem kept QMAP;
    raw-IP now asks for DISABLED explicitly (as qmicli does, qmicli-wda.c:561);
  - qmi_wwan's pass_through stayed Y from rmnet on a parent with no child;
    raw-IP/ethernet clear it first (the driver refuses raw_ip=N while it is set);
  - the "QMAP v1 … requested proto 5" log line for a no-QMAP request;
  - none of that made the RG650E answer the dial (a BIND_MUX_DATA_PORT to mux
    0 did not either) — only a modem reset did. So the daemon resets a QMI
    modem once, at its next init, when rename_l3 finds its own leftover QMAP
    child (`_left_qmap`, kept until an init actually issues the reset). HW:
    up with v4 + v6 85 s after the config change; E392 (raw-IP only)
    unaffected by all of it (rebuild, ifdown/ifup, revert).

- **PR #49 merged (MayorBug): vendor Quectel MHI** (`pcie_mhi`, Cudy P5 /
  RM551E-GL / MHI 1.6.0): control ports under /sys/class/mhi_uci_q,
  rmnet_nss_mhi selectable after a restart (renamed children matched by
  their device link, which names the parent netdev), QMAP version from the
  driver ioctl or its PCI-ID list. Review fixes on top (checked against the
  driver source, 1.3.8 and 1.6.0): the port name is "mhi_" + channel
  ("QMI0"/"MBIM") + the controller index from the second controller on, so
  mhi_QMI01 -> rmnet_mhi1 and mhi_MBIM -> rmnet_mhi0 (the PR mapped
  QMI only, and QMI01 to rmnet_mhi01); one name grammar for discovery and
  autosetup (`discovery.mhi_uci_control`); the four SDX35 ids of 1.6.0 in
  the QMAP-v5 list; dated driver anchors. A Codex finding that the child's
  device link names the MHI device rather than the parent netdev was wrong:
  SET_NETDEV_DEV(qmap_net, &real_dev->dev) with real_dev the parent
  net_device (mhi_netdev_quectel.c:1608,1619).

### The network sets the clock (2026-10-03)

`option nitz_time` on the `wwand_modem`, **default on**, LuCI flag *Set the
clock from the network* in the modem settings. A NITZ time (QMI NAS network
time indication, or `+CTZV` on any modem's AT port) steps the system clock when
it is more than 120 s off (`modem_common.NITZ_TOLERANCE_S`), in either
direction; within that NTP's finer time stands. Before, NITZ stepped the clock
only when it was "plainly unset" (pre-2021) — the GNSS rule, which it still
shares. An RTC-less box boots with its image's build date, which that rule
takes for a set clock, so a router without reachable NTP kept it: a Raspberry
Pi 4 ran on 2026-06-29 a week later (2026-10-01). The time zone is not touched.
`'0'` records the time (`network_time` in status) and leaves the clock alone.
Native MBIM reads it too, over the MS Voice Extensions service (NITZ, CID 10;
`codec/mbim_schema/ms_voice_ext.uc`, layout from libmbim 1.32.0): queried once
per registration, and its indication subscribed only after the query was
answered, because the subscribe list is one SET for every service and a
service the firmware lacks must not put the mandatory ones at risk. The
zone is a guint32 on the wire, read as signed; `0xFFFFFFFF` means no zone.
Host-tested against hand-built buffers; not yet seen on hardware.

### A profile switched by somebody else is applied (2026-10-01)

An SGP.32 IPAe profile enable on the EG25-G at 3.123 (QMI) dropped the session
and left wwand on the old identity: UIM REFRESH stage 1 (START), then
`uim session closed: refresh` and no END — the re-read only ran on END. The
status kept the old ICCID and APN, the modem sat in limited service, until a
restart. wwand's own eSIM switch never hit this, because `esim_bridge`
power-cycles the card after lpac's enable rather than trusting the refresh.

- **`sim.uc refresh_fallback`:** an announced card re-initialisation that has
  not ended after `refresh_end` (10 s) gets the bridge's apply — power-cycle,
  unlock, `reapply_sim` — whose `sim_refresh` re-dials on the new card. Left
  alone when somebody power-cycled after the start (the bridge), and not armed
  by the echo of a recent power-cycle.
- **QMI** (`sim.uc install_refresh`, moved out of `modem.uc`): armed by REFRESH
  START in any mode but FCN; END_SUCCESS re-reads as before, END_FAILURE
  applies at once.
- **MBIM, natively:** armed by the Basic Connect ready-state leaving
  INITIALIZED (to NOT_INITIALIZED or DEVICE_LOCKED), disarmed when it returns.
  No passthrough or MS extensions needed; the reset goes passthrough UIM →
  native UICC reset → AT. SLOT_INFO_STATUS is deliberately not a trigger: its
  slot index is not mapped to the card in use here.
- **Recovery hold for IPAe cards** (`recovery.uc hold_for_card`): after the
  card's own IPA changed the subscription, no modem reset / repower / reboot
  for `card_hold` (35 min) so the card's rollback/fallback is not reset under
  it; the opmode cycle and the counting go on. Only for a card whose IPAe is
  in charge — `sim.uc card_euicc_info`: FCI tag `E1` with `ipaeSupported`,
  and GetEUICCInfo1 refused with 6985.
- **Modem reset when the control channel hangs** (`modem_common.at_reset`):
  QMI (no DMS client or a timed-out request) and MBIM (no passthrough, or it
  times out) reset over `AT+CFUN=1,1`, opening the AT port for the write if
  needed — ladder rung and admin reset alike. Before, an EG25-G whose QMI
  hung (3x on 2026-10-01, AT fine) had only the router reboot left.
- **QMI LOC session ended before its client goes** (`modem.uc` teardown,
  schema `STOP` 0x0023 per libqmi 1.38): an EG25-G with `option location`
  hung its QMI side three times after teardowns (2026-10-01); `location`
  is now off on 3.123. Not yet HW-proven that the STOP prevents it.
- **AT port mute at cold boot** (ddimension/wwand#47, NR7101 RG502Q-EA):
  QMI/MBIM ask a port that opened but did not answer again 30/60/120 s later
  on the same modem object (`modem_common.at_late_retry`) — before, AT came
  back only with a modem reset. And a bare ERROR to a vendor-setting PROBE
  (`atcmd.send` option `probe`: QCFG autoconnect/iotopmode, QNWLOCK reads)
  logs at info as "not implemented by this firmware" instead of a warning on
  every start.
- **Zyxel LTE3301-M209/-Q222** (`board.uc`): the rest of the vendor helper
  `/usr/sbin/lte3301` taken over — both boards bind both modem ids
  (`1435 d181`, `2020 2033`), and the LTE LED lights only on LTE (daemon
  `led_state.lte`). The OpenWrt port (lte3301 fork, one dtsi for both) names
  the LEDs `green:mobile` / `red:mobile` / `green:lte` — no `lte3301:`
  prefix any more; HW-verified on an M209 with a BG96 (2026-10-03: EDGE ->
  green mobile on, red off, LTE off). The port's board.d hangs `green:wan` on
  netdev `wwan0`, which wwand renames to `wwand0`: set
  `system.led_wan.dev='wwand0'` (done on that unit by hand).
- **wwand-apntest phase 1** (`apntest/runner.uc`, `apntest_cli.uc` ->
  `/usr/sbin/wwand-apntest`, `files/wwand-apntest.init`, `files/apntest.config`):
  sweep, slot groups, dial via netifd with uncommitted uci, pool/DNS regex,
  ping, NSCA, cron. First target: apntester-gdsp-lte-m (LTE3301-M209, BG96
  Cat-M); its plan is in /vol/release/lte3301/wwand-apntester. Accounting and
  eUICC profiles report UNKNOWN until phases 2/3. Not HW-run yet.
- **wwand-apntest accounting (m-ccp)**: per-session comparison of the
  operator's record (bytesIn+bytesOut of the session that started after the
  dial, same APN) with the netdev's rx+tx; 90–110 % OK. Verified against a
  real api-ng.m-ccp.de answer (globalsim, 2026-10-03). `iec` accounts:
  UNKNOWN until their answer has been looked at.
- **Open:** NCM (AT-only) has no card-reinitialisation signal wired; a
  `+QSIMSTAT`/`+CPIN` URC would be the hook. Not HW-verified yet (the
  QMI path is the case seen on 3.123).

### The FM350 is asked whether it is ready before it is asked what it is (#45, 2026-09-30)

NCM bring-up now polls ATI (1 s, at most 30 s: `ready_timeout`/`ready_poll`)
before reading CGMI/CGMM. A modem still refusing after that is filled field by
field from its last bring-up, then from its USB id (`ncm_vendors.USB_IDENTITY`:
the FM350-GL's 0e8d:7126/7127), and a CGMM answering the manufacturer counts as
no model. Host-tested (test_ncm s9zb-s9ze); not yet confirmed on the reporter's
H29K.

### Band lists on the FM350 (ddimension/wwand#43, 2026-09-29)

`band_lte` / `band_nr` / `band_umts` on a `wwand_modem`, contributed for the
Fibocom FM350-GL, whose only band command `+GTACT` is not NV. What holds now:

- The lists are applied at every bring-up, awaited **before** the dial is
  resolved, so the one re-registration a write costs never lands on a fresh
  bearer. A mask the modem runs is not written; every write is read back.
- A band edit in the settings editor on such a modem is written to its uci
  section (`persistent: false` from the codec → `daemon.uc persist_bands`), so
  it survives a power cycle like a QMI edit does in modem NV. A reload applies
  changed lists to the running modem; band lists are out of the restart
  signature.
- Written only for RAT tuples 20 and 4, the shapes accepted on hardware. The
  parser reads the first band as UMTS, and tuple 17's own read-back sent back
  verbatim was refused, so any other tuple is refused with a reason
  (`unsupported_tuple`, shown as a `band_lists` status warning).
- Once the module has answered `AT+GTACT=?` (a failed read is asked again,
  not cached), only bands it lists are sent, sorted and each once; "no band
  ticked" is that whole list, not the unverified `0` token. A group the tuple
  does not carry (NR on tuple 4) is refused, not kept unapplied.
- The band step is serialised per modem, so the bring-up and a reload's live
  apply cannot both write.
- QMI/MBIM and other NCM modems do not apply the options; a list there is a
  `band_lists` warning instead of silence.
- LuCI shows only what the backend can set (`settable`): one NR list, the
  module's own bands, the RAT boxes read-only.

Not verified on hardware in this form: the awaited bring-up write and the
`=?`-driven "all bands" (the codec is tested against the captures in #43).

### A modem waiting for its remote SIM stays off its own card (2026-09-28)

A modem with a remote SIM assigned (wwand-rsim) runs on that card or not at
all: the plugin's `radio_hold` answers for it until the modem has taken the
remote card (CONNECT_IND), also when the remote SIM failed or its reader is
misconfigured, and again when the modem lets go of it.

- **At init (QMI):** SET_OPMODE asks the plugins first (`modem.radio_hold`,
  set by the daemon next to `at_init_extra`). Held, the radio goes to low
  power instead of online, as the plugin's park; the init reads the SIM,
  waits in REGISTERING without failing (no recovery ladder), and an
  attach-profile change does not cycle it online. The daemon's tick wakes it
  when the hold is gone; that READY entry is the one `registered`. Before,
  the RG650E on 245 registered with its own card 2 s after every boot — on
  LTE an attach, the network saw the local IMSI — and was parked only after.
  HW-checked on 245 (2026-09-28): after a reboot no registration on the
  local card; the remote card was taken with the radio off, the radio went
  on after.
- **While running:** the plugin parks a modem registered on its own card
  although held (a remote SIM configured while online, or one the modem let
  go of); the core parks only at a new registration or an interface
  bring-up, and refuses to dial a held modem's interfaces.
- **Status:** `status()` carries `radio_held` (the reason, from any plugin);
  `wwandctl status` prints it, the modem status page (luci-app-wwand) shows
  a Radio row, the RADIO_HELD interface error names both reasons.
- **MBIM (2026-09-28, host-tested, not yet on hardware):** until now an MBIM
  modem had no `set_opmode` at all, so a held MBIM modem was **not parked at
  all** — not at init and not after: it registered on its own card and stayed
  registered, only its interfaces were refused. It has one now (passthrough
  DMS low power, else the software Radio State),
  so `modem_radio`, the park at a registration, `option lowpower` and the
  init-time hold work there: the hold is asked right after MBIM OPEN (an
  MBIM modem registers on its own, so step_register would be too late),
  REGISTERING waits while held, a registration lost while parked is not
  re-registered, the wake's registration is reported, and the recovery
  ladder's radio cycle and an attach-profile change leave a parked radio off.
- **NCM:** parked after registration (`AT+CFUN=4`), no init-time hold. NCM
  without an AT port cannot be held at all: every park answers `unsupported`
  (logged once per modem), `status()` carries `radio_hold_error` ("cannot
  hold this modem"), `wwandctl status` prints the radio as on although held.
- **Audit follow-up (2026-09-28):**
  - a **held modem is not dialled**, parked or not (`reconnect.uc
    retry_activate`): after a non-destructive restart the still-up interface
    was adopted through that path, which knew nothing of the hold, and dialled
    on the local card of a modem waiting for its remote SIM;
  - a **hand-back is not a wake** while another hold answers
    (`plugin_radio(on)` → `radio_held`); the tick wakes it once nothing does;
  - a modem that **refuses low power at init** continues held instead of
    failing its init: the ladder's cycles and resets end online, the
    registration the hold is there to prevent. No `offline` fallback — libqmi
    calls it RF off and "partially shutdown" (`qmi-enums-dms.h`, 1.38.0), and
    the way back from it is a reset;
  - the **FCC check** the held init skips with the radio runs at the wake
    (`_fcc_due`, `modem.uc set_opmode`) — an RF-locked laptop SKU otherwise
    stays in low power after the wake;
  - a **re-init after the hold ended** clears the park flags (QMI at the
    init's online switch, MBIM in step_register): the same modem object
    outlives a failed init, and a stale `lowpower_parked` made REGISTERING
    wait forever and swallowed the next registration loss;
  - `wwandctl status` names the holding plugin instead of repeating the
    reason its own status row gives.
- **Review follow-up, MBIM park (2026-09-28):**
  - a held modem with `fcc_auth 'quectel'` gets the vendor Radio State = on
    (a radio-on of its own) at the WAKE, before its radio is switched back
    on — sent before the park, an RF-locked modem could register on its
    local card first;
  - the **wake undoes what may be off**: DMS and the Radio State are
    independent switches, and a DMS park outlives its modem object (a
    daemon restart) — a new object that parked over the switch woke only
    the switch and left DMS in low power for good. A modem object that has
    not set DMS itself (`_dms_unknown`) wakes both; one it parked over DMS
    is woken over DMS, without falling back to the switch. And a start
    with NO hold asks DMS once (GET_OPERATING_MODE over the passthrough,
    step_register): a low power an earlier daemon left is switched online
    ("left in low power by an earlier park") — the Radio State query saw a
    radio that was on, and the modem sat in REGISTERING until the ladder's
    reset. OFFLINE is left to that reset; no passthrough, nothing to ask;
  - a **failed wake of an earlier pass's park** keeps the park flags and
    how it was made, is tried again, and fails the init after `WAKE_TRIES`;
  - **passthrough CID releases are tracked** until acknowledged
    (`_pt_unreleased`): retried at the next use of the stack, carried by
    `drop_pt`'s release burst, given up (and logged) after
    `PT_RELEASE_TRIES`. A timed-out RELEASE_CID left a CID in the modem's
    table that nothing tracked, one per hold/wake.

### Remote SIM (wwand-rsim, 2026-09-27)

What the plugin does now, and what the core offers it — the details, the
tested hardware and the workarounds are in the wwand-rsim README:

- **Card sources:** a reader on the router or on another machine over SSH
  (Smartmouse USB with clock and mode set by software, Phoenix, PC/SC), a
  phone's SIM over Bluetooth SAP, a modem wwand does not manage over its AT
  port (`AT+CSIM`), a modem on this router lending its card (*sponsor*: SIM
  Access or APDU), a modem on another wwand router (`wwandctl rsim proxy`
  there). `wwandctl rsim scan [user@host]` lists what a machine offers; the
  SSH key can be restricted to `rsim-card --serve`.
- **Clients:** QMI modems with UIM Remote switched on (RG650E), and MBIM
  modems through the QMI passthrough: the plugin dep `qmi_client` works there
  now (modem_mbim.uc extra_client). On the GL-X3000 (RM520N-GL, MBIM) a card
  from the lab PC's Smartmouse ran — the modem connected, 431 APDUs, the
  remote card's identity read, back on its own card afterwards. The
  indications UIM Remote needs DO come over the passthrough there, unlike
  NAS's (gotchas.md).
- **In the core for it:** the radio hold (a sponsor's radio stays off, its
  ifups are refused with `radio_held`, a registration of it is parked again),
  the card-change process on both sides (`sim_changed`), the SIM inventory
  filing a remote card under its reader (`card_source`), `sim_upsert` for the
  settings a lending router dials a card with (`origin 'rsim'`).
- **Packages:** `wwand-rsim` (plugin, `wwandctl rsim`), `luci-app-wwand-rsim`
  (Network → Remote SIM: status, find SIM sources, SSH setup), `rsim-card`
  and `rsim-card-pcsc` (the helper alone, for a SIM host).
- **Not possible:** one modem using one slot and lending the other — a
  single-standby modem switches its inactive slot off (above, Multi-SIM).

### A block after a card change comes back by itself (2026-09-27)

An interface stayed down after an eSIM profile switch: the modem was cardless
for a moment, the setup that landed then was answered `sim_blocked`, and the
shim's `proto_block_restart` cleared autostart for good. Two changes:

- `context_up` notes that answer as the daemon's own give-up (`set_giveup`),
  so the next `registered` re-arms and kicks it — as the daemon's own
  SIM-block down already was. Not as "our down": wwand issued none, and the
  marker would make an operator's ifdown right after it look like ours.
- **Who cleared autostart is decided on evidence** (`daemon.uc operator_down`,
  used by all three kick sites): an operator ifdown is recorded where it
  happens (`context_down`, also when there is no context to take down, and by
  the shim itself when the daemon is not running; persisted in
  `/tmp/wwand/state/admin_downs.json`, cleared by the next up, whatever it is
  answered with). **Only that record** makes a cleared autostart the
  operator's: without it the interface is brought back, error or not. The
  in-memory marker for our own downs is lost on a daemon restart — the case
  HW-seen on 245 (autostart false, errors `[RADIO_HELD]`, "administratively
  down"), and again on the NR7101 (242, 2026-09-27: both interfaces parked
  after a `wwand restart` whose old daemon crashed on the way out, no error
  on either — the former fallback "no `wwand` error = the operator's" read
  that as an ifdown nobody had run). The price: an ifdown of an interface
  that was already down (no teardown, no record) is undone at the next
  registration.
  Two guards around that: the record is trusted only once its file can
  exist (written at every start; the first start since boot or since an
  upgrade from a version that recorded nothing keeps the former guess), and
  a cleared autostart with no record is looked at a second time, 5 s later,
  before wwand undoes it (`confirm_then`): netifd clears autostart the
  moment an ifdown starts, the record arrives with the shim's teardown —
  up to a second later still when the ifdown has to kill a running setup
  first (SIGTERM, 1 s, SIGKILL: `proto-ext.c:780-788`, netifd
  2026.07.08~6088f7b3).
  `auto 0` interfaces that are down are no longer wanted (a SIM change's
  reconnect and the low-power decision read `wanted`) — unless the down is
  wwand's own give-up of one the operator had brought up.
- **Audit follow-up (2026-09-28):**
  - what the first start's guess reads as the operator's is **recorded**
    (`operator_down`), and that start asks netifd about every interface at
    its first `apply_config` (`seed_admin_record`), writing the trusted file
    only when all have answered — before, the second start after an upgrade
    trusted a record the first had written empty and undid the ifdown the
    first had honoured;
  - the record is **trusted only whole**: the daemon's JSON array at the
    head of the file. Empty, torn, or the shim's appends alone are read for
    their names but not trusted — trusted, "nothing recorded" would revive
    every ifdown whose record went with the rest of the file;
  - `admin_downs.json` and `giveups.json` are **replaced whole** (write
    beside under a name of its own, rename over, no temporary left on a
    failed write: `default_fx.write_atomic`), and the daemon re-reads the
    file before each write and when it decides, so a name the shim appended
    while the daemon ran (its teardown could not reach it) is neither written
    away nor ignored. The read-merge-write holds a flock on
    `admin_downs.lock`, which the shim takes around its append (busybox
    `flock`): an append between the daemon's read and its rename went to
    the replaced file;
  - an ifup that finds the modem gone (`modem_absent`) also ends wwand's own
    down: its marker, kept past the ifup, sent the operator's next ifdown
    down the "ours" branch unrecorded;
  - the second look is **one per interface entry** (a burst of settings
    events armed one timer each), cancelled by `stop_context`, `stop_local`
    and `shutdown`; at the connect-first site it now also requires the same
    CONNECTED session and an interface netifd is not bringing up by itself.
- An answer that lands after a reload replaced the context — the activation,
  and the two netifd status probes before a kick — is not acted on.

Also corrected: netifd does not retry a failed setup of a `no_proto_task`
handler by itself — the interface stays pending (gotchas.md). Host-tested
with counter-proofs; the HW round on 245 is open.

### A new `wwand_sim` does not restart the modem (2026-09-27)

SIM overrides are left out of the modem's reload signature: adding one — by
hand, or wwand-rsim keeping a lender's settings — restarted every modem.
The running modem gets the new list AND matches its card against it again
(`active_sim`, which the dial reads); handing over the list alone left a new
override ignored and a deleted one in force until the next card read. A
modem held at SIM_BLOCKED is still restarted, since the override may carry
the PIN it waits for. An edit that changes what the card in use gets is also
APPLIED like a card re-read: the attach profile is programmed again
(`reapply_sim`; the attach APN lives only there) and the sessions still up
re-dial — matching alone left an edited APN unused and a rejected attach
rejected (HW-seen on 245, 2026-09-27). The attach profile now also gets the
connection's CREDENTIALS when its APN is the connection's (no `init_apn`):
a CHAP-only M2M APN rejected the attach without them ("EMM attach failed",
profile 1 with the APN and no login) while data calls with the same login
worked. The password is written once per value, so a live edit lands. And the login now goes with the APN
(`conn_cfg`): a `wwand_sim` with its own APN never takes the interface's
credentials — a Telekom card got an M2M card's CHAP login from the
interface, in the attach profile and in its data calls.

### A direct download's PIR reaches the SM-DP+ (2026-09-27)

`esim_bridge.session_notify(ref, seq, cb)`: while an SGP.32 assistant waits
in an event, lpac sends one pending notification to its SM-DP+ (`notification
process -r <seq>`, removed from the card only after the acknowledgement). An
assistant's direct download (SGP.32 v1.3 3.2.3.1) runs lpac without its
notification step so the assistant can read the PIR into its result for the
eIM (step 13); step 14 — the PIR to the SM-DP+ over ES9+ — had nobody doing
it, and the eIM forwards only the PIRs of indirect downloads it ran (5.7.4).
wwand-ipa answers ipad's new `notify` event with it. Host-tested
(`test_esim_bridge`: that one notification with `-r`, never `-a`; lpac's
result line decides; refused outside a waiting session); not run on hardware.

### Optional plugins, and the eSIM bridge's exit status (2026-09-26)

SGP.32 eIM fleet management was first built into the core. On 2026-09-26 it
was moved out into its own repository, github.com/ddimension/wwand-ipa,
because it is not meant for upstream. What stays in the core is the
interface it needed, kept neutral enough for any optional package
(`plugins.uc`, reference.md "Plugins"):
- **Hooks:** a registry for plugins under `/usr/share/ucode/wwand/plugins/`
  with tick, eSIM guard and ubus ops (`modem_plugin` and a read-only twin).
- **Config:** a plugin's `wwand_modem` options arrive as `entry.ext`. They are
  not reported as unknown, and they sit outside the modem's reload signature,
  so switching a plugin feature on does not bounce the connection (test_daemon,
  reload 2b).
- **Card lock:** status names the plugin that manages a card
  (`esim_managed_by`), and `modem_esim` refuses card-changing ops there
  (`esim_managed`, `force` overrides).
- **CLI:** `wwandctl` commands come from `/usr/share/ucode/wwand/ctl/<cmd>.uc`.
- **Bridge:** `esim_bridge` got `session_run`, another stdio-APDU process on
  the card under lpac's claim, with `{"type":"event"}` lines the host
  answers. Its generic `stdio_run` can log to the syslog instead of a file.

Found on the way, and fixed in the core: **the eSIM bridge never saw a child's
exit status.** close() returns the shell's status, and the shell's last
command is the `echo __EXIT` marker, so it read 0 unless uloop had reaped the
shell first. lpac hid this, because its verdict is its result line. The marker
now wins, and that makes lpac's download ack (`notified`) truthful too. Also
fixed: `tools/check-map.py` read a regex literal with an odd number of quote
characters as the start of a string, and blanked the rest of the file.

### The diag port on main; QLog capture as a plugin (2026-09-26)

The `wwand-qlog` branch (b3272e5, 528db7d, based on 55d1cf6) was split the
same way as the eIM work.

**Into the core, because it is neutral:** the modem's DM/DIAG node is
resolved and never opened, like `gps_port`. This covers:
- the `qcdm` role in the generated port table, regenerated from ModemManager
  e1f8061 and identical to the committed one;
- `discovery.wwan_port_by_type`, `atcmd.find_mhi_diag` and
  `modem_common.resolve_diag_port`;
- `option diag_port` and `status.diag_port`.

**Into github.com/ddimension/wwand-qlog, as a wwandctl command plugin:**
the QLog logic (`qlog.uc`) and `wwandctl qlog`. It is still not verified on
hardware.

### SIM inventory, a card lent to another modem, the radio hold (2026-09-26)

**SIM inventory** (`siminventory.uc`, ubus `sim_inventory`, `wwandctl sims`,
LuCI Status → SIM cards): every card seen, by ICCID, and where it is — modem
and slot, eUICC and profile, or a reader (wwand-rsim). It is derived from the
modems' state on every tick and every call, so identity re-reads, slot
switches, remote cards and eSIM changes show up without hooks of their own. An
eSIM download, enable, disable or delete through wwand-esim re-reads the
profile list (`esim_bridge` `changed` → `simops` `profiles_changed`; coalesced
per modem, waits while another host session is on the card). A card a modem
reports missing (`no_sim` / `sim_absent`) is marked not present.

**Plugin interface, grown for wwand-rsim:** `qmi_client` / `qmi_release`,
`modem_at`, `modem_radio`, `sim_slots`, `sim_changed`; hooks `card_source`,
`status` rows, `radio_hold`, `stop` / `busy`. A plugin whose tick throws is
logged and skipped. On exit the daemon stops the plugins and runs its loop
until they are done, at most 8 s (procd `term_timeout` 10). A modem that
stopped for lack of a card resumes its init when a card arrives
(`retry_sim`, via `sim_changed`).

**The radio hold is the daemon's.** A plugin parks a modem's radio through
`modem_radio`; the daemon records it, wakes it on the hand-back only as
`option lowpower` allows, and releases a park no plugin holds any more.
While a plugin's `radio_hold` answers, `context_up` fails with `radio_held`
(shim: RADIO_HELD; the interface waits in setup — netifd does not retry it —
until the wake's registration brings it up) and a registration parks the radio
again. A parked radio is not dialled by the reconnect path, and recovery
cycles, reattach and attach-profile changes leave it off. Woken, a modem
reports `registered` again, which re-arms the interfaces given up while it
was parked. Host-tested; the HW round on 245/242 follows the push.

### What MBIMEx v3 actually buys (2026-09-20)

Speaking v3 was the price of keeping an RM520N-GL connected (above). This is
what it makes reachable, which is a different question and was worth asking.

**Fields that ride on messages already being polled.** Packet Service gains
FrequencyRange, DataSubclass and the attach TAI; Register State gains
PreferredDataClasses. All APPENDED after the v1 fields, so one layout reads
every generation and a v1 modem stops early — the decoder answers null, which is
what absent means.

`data_subclass` is the one that earns its keep. MbimDataSubclass names
ENDC / 5G NR / NEDC / ELTE / NGENDC, so the modem STATES whether 5G sits on an
LTE anchor or stands alone. Everywhere else that distinction is inferred from
the shape of the cell environment — a good guess, still a guess. On the test box
the two disagree: the cells say LTE, the modem says ENDC. Both are shown.

**Layouts that are selected, not appended.** LTE Attach Info INSERTS NwError
after LteAttachState, so the two versions differ from the second field on and
every string offset after it moves. Extended Device Caps (CID 6) is worse — it
reorders AND changes kind partway through: eleven inline fields, DataSubclass a
guint64 there and a guint32 in Packet Service, and everything from LteBandClass
on a TLV. Both carried the wrong layout unconditionally since `b2d8176` and were
harmless only because nothing called them. Same commit also had
`LTE_ATTACH_STATE_ATTACHING = 1 / ATTACHED = 2`; MbimLteAttachState has two
values, not three (mbim-enums.h:1424-1425).

**Two commands that exist only in v3**: Modem Configuration (CID 16), the
carrier profile over MBIM rather than QMI PDC and so readable on firmware with
no PDC at all, and Wake Reason (CID 19). Both need TLV DEcoding, which the codec
did not have — it could only write them. Asked once, and only when v3 was
actually negotiated. The RM520N-GL refuses both (NotInitialized,
NoDeviceSupport), which is visible at debug rather than silent.

That refusal is why `no_recovery` had to start working on `command` and not only
`command_raw`: an optional CID a firmware has not implemented was counting
against the control channel and driving the hardware ladder toward a repower.

**The attach diagnostic needed AT.** MBIM reports the attach STATE reliably and
leaves NwError empty on most firmware — "detached" and nothing else. So when
MBIM gives no cause and an AT channel exists, `AT+CEER` is asked; `regdetail.uc`
has relied on exactly that complementarity for the registration cause since it
was written. With a deliberately wrong attach APN the LuCI page now reads
"detached · Requested service option not subscribed" where it read "searching",
and `wwandctl status` reads "not registered: attach: Requested service option
not subscribed" where it read a bare "not registered" — the CLI names one
reason, by precedence (mapped 3GPP cause, else the raw CEER text, else the
state), because a status line has no room to list them all.

Three things review caught that were wrong on the first pass, all now tested:

- The diagnostic runs on the registration TIMEOUT and asking costs seconds. The
  state test guarding the timer says when it FIRED, not how things stand now —
  so a registration landing inside the query was reported as a timeout and the
  working session torn down. Re-checked in the callback; both queries bounded
  explicitly (the defaults are 15 s and 5 s, no bound worth having on a failure
  path).
- `decode_tlvs` ignored the claimed padding. libmbim sizes a record as header +
  data_length + padding_length (mbim-tlv.c:150-160); a header claiming padding
  that is not there is truncated, and it was being accepted as whole.
- `attach_info` was written at the moment of failure and destroyed by the
  teardown that follows, so status and LuCI read null every time. Carried on the
  recovery record now, as `last_reg_detail` already was.

**Published, decided on nowhere.** Everything harvested goes out through
`status()` and nothing branches on it. What is RENDERED is narrower, and worth
stating rather than glossing:

| | LuCI page | `wwandctl status` |
|---|---|---|
| `data_subclass` | yes, beside the derived RAT | yes, same place |
| `frequency_range` | yes | yes |
| attach TAI | yes | yes |
| `attach_info` | yes, its own row | folded into the not-registered line |
| `preferred_data_class` | no | no |
| `modem_config`, `wake_reason` | no | no |

The last two rows are ubus-only for now: this modem refuses both v3 commands, so
there has never been a value to render, and a row that has never once been seen
is a row written blind. Closing the CLI/GUI split for the rest was deliberate —
`max_sessions` and the temperature row each sat parsed-and-unprintable for as
long as they existed.

HW: GL-X3000 / RM520N-GL — FR1 and DataSubclass ENDC read off the wire, the CEER
cause confirmed with a bogus APN, the box restored afterwards.

### A renew netifd cannot receive (2026-09-20)

The daemon pushes new settings to netifd with `renew`. netifd drops that on the
floor for an interface it is not holding: `interface_renew()` returns -1 for
`IFS_DOWN` and `IFS_TEARDOWN` before the proto handler is reached
(`interface.c:1380-1386`, netifd 2026.07.08~6088f7b3), and wwand's renew is
fire-and-forget, so nothing said so. A CONNECTED context behind a down interface
therefore stayed that way — and stayed that way indefinitely, because the path
that kicks an interface up needs a MODEM transition to fire, and a modem that
never moved never gives one.

The renew decision now asks netifd what it is holding **before** deciding, and
kicks instead of renewing when the answer is "nothing":

| netifd says | wwand does |
|---|---|
| up, holding what we pushed | skip (unchanged) |
| up, holding something else | renew in place |
| `pending` (IFS_SETUP) | nothing — it is coming up by itself |
| down, `auto 0` | nothing — wait for an `ifup` |
| down, `autostart` cleared and not by us | nothing; record the operator's intent |
| down, otherwise | **kick** (re-run setup), and drop the applied signature |

The probe used to be skipped whenever the settings had changed, which is exactly
when netifd is most likely not to be holding the interface — so the case was
invisible from the one place that could see it.

Two things this made necessary, both found by review rather than by the tests:

- **The probe is deferred, and the world moves while it is out.** The callback
  now revalidates that the entry and the context are still the daemon's current
  ones, still CONNECTED, and still the same *connection* — `entry._conn_seq`,
  bumped on every `up`, because a reconnect keeps the same entry and the same ctx
  object and ends in CONNECTED again, so nothing else tells the two apart.
- **One probe in flight per context, and the latch is the probe itself.** A
  plain flag would be cleared only in a callback, so a request that never
  answered would silence that interface's renews for the life of the daemon; the
  latch carries when it went out and expires after 30 s. But an expiry makes two
  probes live at once, so a callback that cannot tell whether it is still the
  current one would act on a superseded answer *and* clear the live probe's
  latch on the way out. Each probe is its own token; a superseded one says
  nothing and touches nothing. A reconnect drops the latch outright — that
  probe asks about a connection that has ended, and holding it would block the
  renew that carries the new session's addresses to netifd.

Also here: the v6 half of the idempotence test compares the **prefix**, not the
whole address. The question is "is netifd still holding what we pushed", and the
host half is not part of that answer — some firmware hands back different low 64
bits on every settings read while prefix, gateway and DNS stay put (the monitor
has compared this way for that reason since `keep_stable_v6`), and netifd may
re-derive the identifier itself from an interface token.

Measured on the GL-X3000 / RM520N (MBIM, 2026-09-20): a netifd restart against a
CONNECTED context recovers on its own — its setup calls `context_up` and gets
`up=1` straight back — so the sticking case is the unlucky window where that
setup lands while the context is reconnecting. The hardware run confirms the new
probe costs nothing in normal operation: a full `ifdown`/`ifup` cycle and a
`killall netifd` both come back with addressing intact and no spurious kicks.

### `mux auto` on MBIM costs nothing now (2026-09-20)

An `auto` channel used to take session 1 on MBIM, which means an 802.1q tag on
every frame in both directions and a VLAN sub-device to route through. It bought
nothing: untagged traffic on a cdc_mbim parent already IS IPS session 0
(`drivers/net/usb/cdc_mbim.c:262-270`, Linux 6.18.41 — and `FLAG_IPS0_VLAN`, the
flag that would change that, is only set when someone creates VID 4094, which
wwand never does). The 1 came from the channel allocator, which counts from 1
because QMAP channel 0 is invalid. MBIM's is not.

A modem whose only muxed interface is `auto` now asks for no session:

    modem wwmodem_wwan0: mux auto resolves to MBIM session 0 — untagged on the parent, no vlan child
    datapath: vlan selected but no mux channels configured — MBIM session 0 on the parent, untagged
    modem wwmodem_wwan0: datapath: untagged (vlan not applicable here), parent wwand0, mux []

Two interfaces on one modem still take a tagged session each — one untagged
parent carries one session — and a pinned `option mux_id '1'` is the operator
asking for a tagged session and keeps it.

**`untagged` is its own datapath name**, not `raw_ip`. Both mean "the parent
carries it" and they are not the same parent: `raw_ip` is a qmi_wwan framing
mode with a sysfs knob behind it, and calling an MBIM parent that told operators
their modem was in a mode it does not have. It is a mode like `raw_ip` and
`ethernet`, with no implementation behind it, and it declares `mbim` — naming it
on a QMI modem is refused the way `ethernet` is refused on a non-QMI one.

**One line was the whole bug.** `context_mbim` dialled `config.mux_id` directly
while everything else — `derive_netdev`, the status children list, the QMI WDS
binding — resolved through `effective_mux_id`. With the parent untagged and the
context still dialling session 1, the session came up, netifd got an address,
and not one frame arrived: the modem tagged session 1 and no device was
listening for the tag. Found on hardware (GL-X3000/RM520N, 2026-09-20), not in
the suite, because no test had ever made the two disagree. `derive_netdev` had
the same split for MBIM and is now on the effective id too.

Visible without guessing: `wwandctl status` prints `datapath auto → untagged`,
and the LuCI status page shows the same under Datapath → Backend, whenever what
was configured is not what came up.

Three things the hardware found that the suite could not, all on the live
tagged → untagged switch:

- **The stable L3 name has to be reclaimed from the leftover child.** It is
  asked for before the datapath runs, the old vlan child still holds it at that
  moment, and setup() prunes that child a second later — after the rename has
  already been skipped, with nothing to retry it. The parent then kept a raw
  kernel name that depends on USB enumeration order, which is the instability
  stable L3 names exist to remove, and the next unchanged reload was a no-op.
  `rename_l3` now removes its own leftover child first, identified by
  `lower_<parent>` so nothing else can be mistaken for it. Raised by Codex
  review, reproduced on hardware.
- **`option mux 'untagged'` has to disable a pinned `mux_id`**, like `raw_ip`
  and `ethernet` do. It has no implementation, so setup() builds nothing and
  ignores the links it is handed, while a pinned channel is never demoted — the
  context would dial session 1 against an untagged parent. Also Codex.
- **netifd needs a restart afterwards, and wwand now says so.** The name moves
  from the mux child to the parent, and netifd still holds a device record for
  it in its old shape; claiming it re-runs that record's setup against a parent
  that is gone (`DEVICE_CLAIM_FAILED`, netifd `interface.c:1349-1353`). A reload
  does not clear it. Nothing wwand can do from its side, so it logs the remedy.

### The MBIMEx handshake had no second chance (2026-09-20)

Found while switching a live MBIM modem's mux configuration, and unrelated to
that: after the modem bounced, the version query came back a **function error**,
no version was agreed, the client fell back to the v1 layouts — and a modem
serving v3 answers the v1 CONNECT with status 21 (`InvalidParameters`). Every
bring-up then failed identically, thirty-odd times, and only restarting the
daemon cleared it. On the GL-X3000 / RM520N, 2026-09-20.

`self.opened` in `mbim_client` is that CLIENT's belief, not the device's. A
fresh client over a function a previous host session left in-session has
`opened = false`, so it never sends CLOSE, and the function answers the version
query with an error. libmbim has a step for exactly this — an explicit CLOSE
before OPEN when the device may still be in session (`mbim-device.c:2051-2058`,
1.32.0). wwand had none.

Now: a function error on the version query closes the channel, reopens it and
asks once more. A DECLINED handshake is not retried — that is the modem
answering, and asking again gets the same answer; only an error from the
function itself is recoverable. Both halves are pinned by tests, and the
hardware shows the recovery working:

    MBIMEx version query hit a function error — closing and reopening the channel once
    MBIMEx 3.0 agreed (after reopening the channel)

And the log line that hid this says why now. "no MBIMEx version agreed" on its
own reported a decision with real consequences and gave nothing to act on; the
same modem agreed 3.0 on one start and not on the next, and the log could not
tell the two apart. It is a `warn` with the reason in it — `query failed
(function_error)`, `answer too short (N bytes)`, or the versions the modem
offered.

### The modem was never told what to tell us (2026-09-20)

wwand registered indication handlers and never sent
`MBIM_CID_DEVICE_SERVICE_SUBSCRIBE_LIST` (basic_connect cid 19), so what
arrived was whatever each firmware volunteers. That is not nothing — an
RM520N-GL volunteers SIGNAL_STATE, REGISTER_STATE, PACKET_SERVICE,
LTE_ATTACH_INFO and MODEM_CONFIGURATION at init (GL-X3000, 2026-09-20) — but it
is the MODEM's choice, and a firmware with a thinner default leaves every
handler listening to silence with nothing in the log to say so.

The list is **derived from the registered handlers**, never a second table
beside them: a hardcoded copy goes stale the first time an `on()` is added
without it, and the failure mode is silence. That also means a vendor service
(the QMI-over-MBIM passthrough) is carried without anyone remembering it.

    subscribed to 3 services, modem confirms 3

Best-effort throughout: a modem that answers an error keeps whatever it sent
before, and it is never a reason to fail a bring-up.

**CID 19 REPLACES the default set, and that is measurable.** The first
subscription omitted LTE_ATTACH_INFO — wwand queried that CID on demand and had
no handler for it — and the modem stopped volunteering it within the minute. So
it has a handler now, which is worth having on its own: the attach state and its
3GPP cause arrive about once a minute unasked, where before they were read only
when a registration timed out. The state is kept every time, logged only when it
moves.

Two more indications that had no handler:

- **RADIO_STATE** (cid 3) — the hardware kill switch, which nothing else in this
  daemon could see. A physical RF switch or a host airplane-mode toggle turns
  the radio off under a running modem: registration drops, every reconnect
  fails, and the recovery ladder climbs through opmode cycles and resets against
  a modem doing exactly what it was told. Hardware-off and software-off are kept
  apart, because the software one is wwand's to undo and the hardware one is a
  switch somebody moved. Surfaced as a `control_note`, in `status.radio`, and as
  a row on the LuCI status page that appears only when something is off. The
  state read at init is kept too — otherwise "not asked yet" and "both on" look
  the same.
- **SLOT_INFO_STATUS** (ext cid 8) — per-slot UICC state, until now polled at
  init and after a slot switch, so a card pulled while the modem ran was noticed
  only by the failures that followed.

And every indication is now logged at `debug`, handled or not:

    indication ms_basic_connect_ext/cid 4, 88 bytes (no handler)

An unsubscribed one used to vanish without trace, so "does this modem send X?"
could only be answered by adding a handler and seeing whether it fired — and a
firmware that sends nothing looked exactly like one this client forgot to listen
for. It is the QMI side's equivalent, at the same level, and it is what made the
measurements above possible.

### Three things MBIM could always do and wwand never asked (2026-09-20)

Each is the LOWEST rung of a ladder that already had two. That order is not
modesty: the QMI scan carries band and RAT per operator, AT+COPS is the one
every modem answers, and MBIM's own versions carry less. The point is what
happens when neither of the first two exists — an MBIM modem whose QMI
passthrough refuses a NAS scan and has no AT port used to answer
`unsupported_on_backend` for operations its own protocol implements.

**Operator scan** — `VISIBLE_PROVIDERS` (cid 8) was declared in the schema and
called from nowhere. The response is a ref-struct-array of `MbimProvider`, each
carrying two strings, and **two offset bases meet in it**: the array's
(offset, size) pairs are relative to the information buffer, the string pairs
inside a provider are relative to THAT PROVIDER's start. libmbim reads the pair
at `information_buffer_offset + relative_offset` and the data at
`information_buffer_offset + struct_start_offset + offset`
(`mbim-message.c:553-565`, 1.32.0). Swapping them decodes into garbage that
still looks like data, which is why the test builds the buffer by hand rather
than round-tripping our own encoder.

**Network selection** — `REGISTER_STATE`'s set takes a provider id and an
action. The width is the statement: `310/030` and `310/30` are different
operators and a provider id carries no flag to say which was meant, so the MNC
is zero-padded to the requested width. (ucode's `sprintf` has no `%0*d`, which
is exactly how a 3-digit MNC gets silently truncated — padded by hand.)

**Carrier configuration** — `no_pdc` was a hard refusal, and MBIMEx v3 has a
configuration of its own. It is READ ONLY and says so: MBIM has a status and a
name and no way to select one, so a `set` is still refused — with a reason that
names the difference rather than repeating the generic message.

That one also found a real bug of its own. The init query runs before the radio
is up, and the RM520N answers it with **status 14, `NotInitialized`** — the
modem saying "not yet", not "never" — after which wwand never asked again and
reported the configuration as unavailable for the life of the process. It is
asked once more when registration completes, and then it answers:

    carrier configuration unavailable: { "error": "mbim", "status": 14 }
    carrier configuration: Commercial-DT-VOLTE (completed)

The same CID also arrives as an indication (during `INIT_SERVICES`, before the
handlers are installed, so it is not what fixes this) and now has a handler, for
the modem where a configuration switch announces itself.

Reached by DUCK-TYPING, not by importing: the MBIM schemas ship in `wwand-mbim`
and `netsel_ops` / `hwops` are in the base package, so the MBIM modem offers
`native_scan` / `native_register` and nobody else does — the same pattern
`sim.uc` uses for `mbim_uicc`.

**Not hardware-validated end to end**, and deliberately not claimed to be: the
MBIM modem here has both higher rungs, so the ladder never reaches the bottom on
it. The wire formats are host-tested against hand-built buffers matching libmbim
1.32.0. What WAS verified on hardware (GL-X3000 / RM520N, 2026-09-20): the
carrier configuration read, and a manual network selection onto the serving PLMN
and back to automatic with the connection intact throughout.

### GPS: the three pieces were all there (2026-09-20)

wwand FINDS the modem's NMEA port during enumeration (`gps_port`). `option gnss`
STARTS the receiver with the vendor AT command — QMI's LOC service is documented
as broken on Quectel and AT is what works, and only wwand has the port. ugps, in
OpenWrt base, READS NMEA and publishes a `gps` ubus object, and knows nothing
about modems.

Nothing joined them, because ugps takes a **static** tty out of
`/etc/config/gps` (`uci get gps.@gps[-1].tty`, its init) while wwand's is
discovered and can move between boots or when a modem is replaced. `wwand-gps`
is that write, plus a `modem_gps` ubus method answering with both halves at
once, plus a LuCI panel.

**Good citizen, here too.** wwand manages exactly one `config gps` section and
only one it created itself, marked `option wwand '1'`. ugps reads the LAST
section, so an operator's own receiver would be silently taken over by a section
appended beside it — wwand refuses and says so instead. Idempotent by
read-before-write for a sharper reason than usual: a commit fires procd's reload
trigger, a reload restarts ugps, and a restarted ugps loses its fix.

The map on the status page is a **link, not a tile**. Embedding one would have
the router's own web interface fetch from a third party the moment anyone opened
the page, and send them this router's position to do it.

Two bugs the hardware found, neither of them in the new code:

- **`option gnss` reported a failure when the receiver was already running.**
  `+CME ERROR: 504` is "session is ongoing" and the recipe table lists it as
  benign — but atcmd parses it into `{ error: 'cme', code: '504' }` and leaves
  the response lines EMPTY, and the check matched only the lines. So the
  receiver was on, the start was logged as a warning, and `gnss_started` never
  latched: status said the receiver was not running while it was.
- **A `require()`d module logging through its own `wwand.log`.** require() gives
  the loaded script its own copies of its imports (docs/gotchas.md), so that log
  is a second instance with no output target set — every line went to stderr and
  procd tagged the lot `daemon.err`, reading `daemon.err … notice: gps: …`.
  `gps.uc` returns what it did and the caller, which is a real module, says so.

And one thing measurement settled that guessing would have got wrong: **ugps
answers in STRINGS and uses an EMPTY one for a field it has no value for** —
`"elevation": ""`, `"satellites": ""`. A fix keyed off `latitude != null` would
have called an empty string a position, and `+""` renders as `0.0 m`, which
reads as a measurement rather than the absence of one.

Verified on hardware (GL-X3000 / RM520N, 2026-09-20), end to end: wwand wrote
the section, procd reloaded ugps onto `/dev/ttyUSB3`, and the panel showed a
real fix — 52.03582, 8.54918, elevation 69.1 m, HDOP 3.4, fix age 1 s.

The mislabelled flag is fixed with it. `option location` had the label "Enable
GPS/location" and writes the QMI LOC path — the one that does not work on
Quectel — while `option gnss`, the one that does, had no UI at all.

### MBIMEx v3 (2026-09-19)

wwand asks for **MBIMEx 3.0** at `open()` and reads the layouts of whatever the
modem agrees to. This is not cosmetic: MBIMEx versions are different
*structures*, not variants of one.

What forced it. A GL.iNet GL-X3000 (RM520N-GL, MBIM) had a working connection
until a daemon restart, after which every CONNECT returned
`MBIM_STATUS_ERROR_INVALID_PARAMETERS` (21) and `imsi`/`iccid` read empty —
while `AT+CIMI` and the UICC slot query read the card perfectly. Refuted along
the way: missing eSIM profile, wrong APN, a session already active, session id
out of range, ip_type, a malformed buffer (hex-dumped and decoded field by field
against libmbim — it was well-formed), accumulated modem state. The answer was
in the raw SUBSCRIBER_READY_STATUS response: its second u32 is `Flags`, a field
that exists **only in v3**. The modem had been serving v3 layouts all along.

What that means concretely (libmbim 1.32.0, `mbim-service-ms-basic-connect-v3.json`):

- **SUBSCRIBER_READY_STATUS** inserts `Flags` (u32) after ReadyState. The fixed
  part is positional, so reading a v3 answer as v1 takes `Flags` for the
  SubscriberId offset — empty strings. The reverse is worse and was briefly
  shipped in this branch: reading a v1 answer as v3 returns the IMSI **missing
  its first digit** and a null ICCID. A plausible wrong answer, not a failure.
  Held shut now by a hand-built v1 wire buffer in `test_mbim`.
- **CONNECT** is redefined: reordered fixed fields, an added `MediaPreference`
  u32, and the three strings as **MBIM TLVs** instead of offset/length pairs
  (`encode_connect_v3`, `codec/mbim.uc`). Every CONNECT takes the agreed form —
  the DEACTIVATE as much as the activation, through one `send_connect` in
  `context_mbim.uc`; branching only the up path would leave the modem holding a
  bearer the context reported as down.

Which layout applies is decided **per modem**, from the negotiated version
(`mbim.mbimex_v3(mc)`), for queries and indications alike — an indication
resolves it when it arrives, because handlers are registered before `open()`.

This supersedes `2df78a1`, which disabled the negotiation on the reasoning that
asking for a version is a promise to speak it. The principle was right; the
resolution was the wrong half. The answer was to speak v3.

HW: GL-X3000 / RM520N-GL — `MBIMEx 3.0 agreed`, imsi/iccid populated, IPv4
`10.24.245.13` + IPv6, ping 3/3 and 2/2, and an `ifdown`/`ifup` cycle back to
CONNECTED (2026-09-19). Not exercised on a v3 modem other than this one.

### MBIM failures say what failed (2026-09-19)

The QMI client reports the failing message to the recovery hook and `modem.uc`
logs it (`qmi error (qmi) svc N NAME, counter M`). MBIM reported only a kind, so
every failure logged as `mbim proto error (mbim)` — identical whether the SIM
was missing, the channel wedged, or a buffer had the wrong shape. That is why
the v3 hunt above took a day.

`mbim_client` now passes the command name and the `MBIM_STATUS_ERROR` to
`on_error`, and the status decodes through a name table taken from libmbim
1.32.0:

    mbim error (mbim) basic_connect/SUBSCRIBER_READY_STATUS status 21 (InvalidParameters), counter 1
    mbim error (mbim) 533fbeeb-14fe-4467-9f90-33a223e56c3f/cid 2 status 9 (NoDeviceSupport), counter 2

The second is from hardware and shows the fallback working: a service wwand
addresses by raw UUID with no schema file (SMS) prints its UUID, which is
exactly the case where the UUID is the useful thing. Named services now include
the standard libmbim set, not only the ones this tree has schemas for. At
`debug`, like its QMI counterpart — `ubus call wwand set_log_level
'{"level":"debug"}'`.

### IPv6 interface identifier (2026-09-10)

`option ip6ifaceid` (alias `ifaceid`) pins the low 64 bits of an interface's
IPv6 address while the network keeps assigning the prefix. Carriers that rotate
the identifier on a live bearer break every source-restricted route, firewall
rule and DNS record naming the address; the /64 belongs to the UE on 3GPP
(RFC 6459 §5.2), so choosing the host part is legitimate. Full description in
`reference.md`; the traps are in `gotchas.md`.

**The default is empty and changes nothing** — netifd's own `ip6ifaceid`
defaults to `::1`, which would renumber every existing installation on upgrade.

One option, two mechanisms, because an address reaches a cellular interface two
ways:

| source | who forms the address | what wwand does |
|---|---|---|
| control protocol (QMI/MBIM/NCM) | wwand, from the modem's reply | rewrites it as the settings are assembled (`context_common.apply_iface_id`) |
| router advertisement | the kernel | sets the kernel's IPv6 **token** (`IFLA_INET6_TOKEN`, new `wwand_io.set_iface_token`), or `addr_gen_mode` for `eui64`/`stable`/`random` |

A token is refused on a raw-IP link — the kernel takes one only where neighbour
discovery happens — so on rmnet modems only the control-protocol path applies.
It cannot help against a rotating *prefix*; nothing can.

**In LuCI it is the stock "IPv6 suffix" box** on Advanced Settings, not a wwand
field. `ip6ifaceid` is a generic netifd option and luci-mod-network claims it
for every protocol with `nettools.replaceOption(s, 'advanced', ...)` *after* a
protocol handler has added its own options — so the field luci-proto-wwand
briefly carried under that name was created and then replaced without a word,
and its validator never ran while the daemon went on refusing the values it was
written to catch. The duplicate is gone (LuCI Master 26.220.05397, checked on
hardware 2026-09-10). That box's datatype is `ip6hostid`, so `eui64` / `random`
/ `stable` have to be set through uci.

Verified on the RG650E (`245`, Telekom 262/01 — the box's own
registration and its 2a01:598 prefix; an earlier note here said O2): without the option three sessions produced
three identifiers under one stable /64; with `::1234:5678` the address held
across reconnects, traffic flowed from it, and removing the option restored the
network-assigned identifier. The token path was verified against 6.18.41 in a
netns (set/clear, `IFF_NOARP` refused, survives enabling IPv6 and a link bounce).

### Modem status page: live signal graphs (2026-09-10)

The LuCI status page is now warnings → **graphs** → panels. The old signal-bar
panel and its peak-hold button are gone; the graphs carry current, average and
peak over the window that is actually on screen.

- **One quantity per canvas** — RSRP, SINR, RSRQ, 3G Ec/Io — each with its own
  published thresholds drawn as labelled rules. Sharing a unit is not sharing a
  scale: SINR and RSRQ are both dB and were briefly on one axis, which graded a
  normal -12 dB RSRQ against SINR's rules.
- **One series per RAT**, never a line that changes meaning when the modem
  switches. On EN-DC the LTE anchor and the NR carrier arrive in the same reply
  and differ widely, and a gap in the 5G line *is* the information that 5G
  stopped serving. Solid = the serving cell's own power (RSRP, RSCP on 3G),
  dashed = the band-wide RSSI in the same colour. An RSSI keeps the RAT that
  measured it; the untagged line appears only when nothing tagged is on offer —
  a NAS 1.0 stack's AT+CSQ floor (E182E).
- **Canvases and legend rows appear with their data.** An LTE-only modem never
  shows the Ec/Io graph; a 2G-camped one shows nothing but its RSSI.
- **The history lives in the browser** (ddimension/wwand#14): no daemon-side
  buffer to serialise into every status call, and no sampling while nobody is
  watching. It starts empty and a reload clears it.
- Thresholds are the published vendor tables, and they are the same ladder
  `board.bars_from_signal()` steps the signal LEDs at — what the case shows and
  what the browser shows agree. Sources and caveats hang off each heading as a
  mouse-over.

Two unit traps were closed on the way, both of the same shape — one key meaning
two things depending on which path answered:

- **WCDMA Ec/Io** arrives over QMI as a raw gint16 in -0.5 dB units
  (`qmicli-nas.c:460-462`, libqmi 1.38.0) but over AT already in dB
  (`atcmd_parse.uc:424`). `modem_common.normalise_qmi_signal()` converts at the
  edge — at **all three** doors that store a raw QMI signal reply: the polled
  `GET_SIGNAL_INFO`, the `SIGNAL_INFO_IND` indication and the same request over
  the QMI-over-MBIM passthrough. Converting only the first was worse than
  converting none: indications arrive between refreshes.
- **NR RSRQ is not inside `nr5g`.** QMI carries NR RSRP/SNR in TLV 0x17 and RSRQ
  in TLV 0x18 of its own, so the reply has a top-level `nr5g_rsrq`, in plain dB
  while the neighbouring SNR is in tenths (`qmicli-nas.c:581-584`).

`tools/luci-screenshot.py` captures the documentation screenshots: headless
Chrome over CDP, stops the one-second refresh, masks the subscriber identifiers
and addresses, and **refuses to write a file** unless a second pass proves
nothing repainted over the mask.

### Startup banner (2026-08-31)

Three lines at every start, so a posted log answers the questions that used to
need a reply from the operator:

```
wwand 2026.08.30~199a2f8a-r53; backends: qmi, mbim, ncm
datapath: built-in auto, raw_ip, ethernet, rmnet, qmimux, vlan; add-ons rmnet_nss, rmnet_nss_mhi
backend qmi loaded
```

The version is read from the package database (`version.uc`), never a constant in
the tree: the package version is the release it was built from (`1.6.6-r1`, a
development build `1.6.6_p3-r1`), so a constant would be a second truth that starts lying the first
time somebody forgets to bump it. A hand-deployed tree says `unpackaged`.
Availability is a file check on each backend's lazy shim — probing by
`require()` would defeat the lazy loading the package split exists for, and each
shim ships in its own backend package, so the file IS the answer. "Loaded" is
announced separately, once, when a modem actually asks for a backend.

---

## Core changes for the wwand-rsim plugin, found on the hardware (2026-09-27)

Driven by running wwand-rsim (remote SIM) across 245, 242, 3.93 and the Cudy
LT300: cards lent over SSH, by phones over Bluetooth and by sponsor modems.

**Plugins take part in the AT init.** `plugins.uc` gains an `at_init` hook:
a plugin contributes idempotent steps (`{check, want, set, note, reset}`) to
the modem's AT init sequence (`atcmd.run_sequence`), and a step whose `set`
needs a reset gets one — once per daemon (`at_init_changed`). wwand-rsim uses
it for Quectel's SIM Access switch (the EFS item
`sap_security_restrictions`). `modem_common.init_commands` / `init_done` are
the shared entry for the three init sites. A modem rebuilt by hotplug keeps
its plugin options (`carry_over` carries `ext`).

**NCM parks with `CFUN=4`.** `option lowpower` and a lent card switched the
radio off with `CFUN=0`, which powers the SIM down on most modems: a card
lent over `AT+CSIM` answered `+CME ERROR: 13` (MeiG SLM770A). Now `CFUN=4`,
as QMI's LOW_POWER; `CFUN=0` only for a modem that refuses 4. The radio cycle
and the SIM power cycle keep 0/1 — there the SIM is meant to go down.

**The identity after a card change is read from the card.** DMS `GET_IMSI`
answers from the firmware's cache: after a card change it gave the previous
card's IMSI for a while, which matched that card's `wwand_sim` — its PIN and
APN (RG650E with a remote card). `sim.read_identity` takes `fresh` (no DMS
cache); the QMI `reapply_sim` always reads fresh (every caller is a card
event), and `card_changed` reads again every 15 s, up to 6 times, while a
slow card has no IMSI yet.

**A give-up survives a daemon restart.** An interface wwand downed itself
(reconnect-hold expiry, a SIM block) is re-armed on the next registration —
a mark that lived on the context entry only. A restart inside the outage (a
package upgrade) lost it, and the interface, autostart cleared by our own
down, was read as an operator ifdown and stayed down. The marks are kept in
`/tmp/wwand/state/giveups.json`, per interface; an operator ifdown still
clears them.

**`tools/luci-screenshot.py` masks two more shapes.** An ICCID or EID printed
in groups (`8949 0200 …`, the SIM slot panel) and the log panel, a
`<textarea>` filled through `.value`, went out in clear; both are masked now
and part of the residue check. The committed images predate both panels and
were checked: masked.

## Device support pass: sponsor field fixes + huawei-cdc (2026-08-30)

Driven by the Huasifei WH3000 Pro field report (Fibocom FM350-GL + two Huawei
modems; full report from the OpenWrt forum thread). Six fixes, one new seam.

**Recovery ladder proven-gated.** The recovery hardware rungs (opmode cycle,
modem reset, repower, reboot — both ladders) no longer fire until at least one
successful protocol exchange has ever completed with the currently selected
protocol. The field case that made this non-negotiable: a misdetected modem was
power-cycled at 25 protocol errors — the errors were evidence about our own
detection, not the hardware. `recovery.uc` persists `proven` + `protocol` with
the counters; a protocol change (`option protocol` or a re-detection picking
another backend) invalidates the proof on load; while gated, the rung index
does NOT advance, so the rung stays armed for when the protocol is proven.
`daemon.uc` passes the resolved control protocol into `make_recovery` (the
switch_protocol rebuild goes through the same path, so a switched modem must
re-earn the proof too), and `status()` now surfaces `proven` so the gate is
visible in LuCI/logs. HW-verified on the sponsor box (FM350/NCM: `proven: true`
persisted with `protocol: "ncm"` after the deploy).

**cdc-wdm as the AT channel.** `huawei_cdc_ncm` registers its cdc-wdm as the
embedded AT port alongside the NCM datapath — the E3372H field case has no
usable AT tty (its serial siblings are PCUI/diag). `open_at` now falls back,
in order: tty → an AT-bearing cdc-wdm (gated on the AT-driver table — AT is
never poked into a QMI/MBIM control channel) → the MBIM pipe. `atcmd.open_transport`
opens a cdc-wdm as a plain stream (termios would fail with ENOTTY);
`option tty '/dev/cdc-wdmN'` pins the channel explicitly. On the box the probe
also settled what the E3372H's cdc-wdm is: pure AT (uqmi times out), while the
E182E answers partial QMI via `qmi_wwan new_id` (no data endpoint — a PPP
stick; the new_id experiment was reverted).

**E3372H end-to-end (the huawei-cdc proof, same day).** The E2E migration on
the sponsor box surfaced three things the morning probes could not see, each
fixed and HW-validated:

- **The dial must go over the wdm.** ttyUSB3 answers generic AT (CGDCONT/CSQ/
  telemetry all work) — but `^NDISDUP` sent there leaves `^NDISSTATQRY` at 0,
  silently. The same dial over the cdc-wdm connects. `open_at` therefore
  PREFERS the wdm for `huawei_cdc_ncm` (an explicit `option tty` still wins;
  a silent wdm falls back to the tty search). The wdm proved to be a full AT
  channel incl. URCs (`^RSSI`/`^HCSQ`/`^NDISSTAT` all arrive there; the tty
  gets none).
- **IP via CGPADDR.** Stick firmware 21.200 implements neither CGCONTRDP nor
  GTDNS (bare ERROR) — the PDP address comes from `AT+CGPADDR` (also empty
  until the dial has bound the bearer). The huawei recipe got an `ip_config`
  hook: CGCONTRDP first (newer firmware), CGPADDR fallback in the /32
  gateway-less p2p model; no DNS over AT (the operator config covers it).
- **v6 via RA, and the dhcpv6 subinterface gate opened.** The v6 model was
  gated on `rndis_host`; the E3372H shows the same `kernel_ra` addresses on
  the parent netdev, so `ensure_wan6` now triggers for every AT-driven NCM
  datapath (`discovery.is_at_driver`). `lte_6` (dhcpv6, extendprefix=1) was
  created live and DITO handed out global v6. The huawei `^NDISSTAT` bearer
  push (up/down per family, reason 36 = regular deactivation per 3GPP
  TS 24.008) is parsed as a `session_urc` — the context verifies via
  `^NDISSTATQRY` before acting. End-to-end proven on the box: a disconnect
  produced the pushes, the verify agreed, the session was torn down and the
  daemon reconnected automatically. `^MODE`/`^SRVST`/`^SIMST` do not exist on
  this firmware (queries ERROR) — no parser is built on them. `^DSFLOWRPT`
  (the traffic report) pushes every ~2 s and is filtered as a URC, not parsed.
  The third stick — E182E — DOES expose a CDC ethernet function (interface
  1.1: class 02/sub 06 + a CDC data interface), but the kernel deliberately
  refuses it for wwand's purposes: `cdc_ether.c` blacklists 12d1:14ac/iface 1
  ("egregiously nonconformant with the CDC Ethernet specs" — the id_table IS
  the blacklist and even a dynamic new_id lands in the same
  `driver_info == 0 → -ENODEV` probe, usbnet.c; a host-MAC quirk was the
  tell, per Bjørn Mork's 2013 thread), and `qmi_wwan` — which the entry
  defers to — rejects the class-02 layout (`qmi_wwan.c`: interface-number
  matches bind only vendor-specific functions). Its QMI (via new_id) is
  incomplete anyway (DMS answers, NAS = "Invalid QMI command"). `AT^SETPORT?`
  is not implemented. Verdict: NCM/ECM would take a kernel patch — out of
  scope; the stick stays a PPP serial modem (wwand manages no PPP, by design).
  The usbmode composition toggle (SCSI message `…1106…`) flips the layout and
  is reversible via USB re-authorization — original state restored.

---

## 802.3 `ethernet` datapath + minimal-service QMI support (2026-08-30/31)

The E182E audit above ended in "outside wwand's scope"; the follow-up brought
it inside. A new **`ethernet` pseudo-mode** beside `raw_ip` (`netlink.uc`):
no multiplexing, the parent KEEPS the kernel's 802.3 framing (`raw_ip`
re-asserted to N, idempotent) and gets **NOARP** (the RNDIS p2p optimization —
static /32 from WDS + device route needs no neighbour resolution). The WDA
`SET_DATA_FORMAT` link-layer protocol is now datapath-driven
(`datapath_caps().llp_802_3` → `LLP_802_3`, previously hardcoded
`LLP_RAW_IP` in `modem_datapath_qmi.uc`). **Auto-selection**: a QMI modem
WITHOUT a WDA service (no format negotiation possible — the kernel link is
what stays) selects `ethernet` under `auto`, beating the datapath probes; an
explicit `option mux` keeps its historic behavior. The E182E's DMS model
string turned out to be literally "8" — the service table, not the model, is
the anchor. Backend tolerances pinned by a dedicated `e182e` scenario
(minimal service table, `__error: 71` for every NAS-1.1+ message): the UIM/
DSD/WDA-less paths are all graceful by design; the QMI signal chain is now
**GET_SIGNAL_INFO → GET_SIGNAL_STRENGTH (NAS 0x0020, the 1.0-era message —
qmicli-verified on the stick: RSSI/RSRQ/SNR/RSRP) → AT+CSQ floor** (the
shared parse/sig_csq_floor moved to `modem_common`), the data-mode ladder
resolves from NAS radio_ifs without cells, and every optional poll
(GET_SIGNAL_INFO / GET_CELL_LOCATION_INFO / GET_LTE_CPHY_CA_INFO) carries
`no_recovery` so a stack that rejects them by design cannot climb the
recovery ladder. The transport puzzle of the session — wwand frames got no
answer while uqmi did — turned out to be the CTL **client id**: the 2011
stack accepts CTL only on cid 0, which is what wwand's modem always used
(the probe scripts used 1). A second bring-up blocker surfaced live: the
stack answers **no QMI_CTL_SYNC at all** — SYNC is now best-effort
(no_recovery, continue on the version query, like libqmi), and the DMS
GET_IDS IMEI comes back padded with uninitialised bytes on this stack, so
the field is trimmed to its leading 15 digits (box-verified:
"359740023613407"). Box-verified without a SIM: services 0(1.3) 1(1.5)
2(1.2) 3(1.0) 224(0.0), `datapath: ethernet selected — no WDA service`,
raw_ip=N kept, NOARP set on the parent, REGISTERING (registration 0) as
documented. A `files/wwand.hotplug.e182e` hotplug fragment re-creates the
12d1:14ac qmi_wwan new_id bind on every replug (the feed Makefile install
line ships with the next bump). `modem_quirks.uc` documents the class
caveats (empty SIM slot = registration timeout, not SIM_BLOCKED). E2E
connect still awaits a SIM in the stick's slot.

---
  `--get-versions` returns exactly five services — CTL 1.3, **WDS 1.5**, DMS
  1.2, NAS 1.0, and 0xE0 v0.0 (the pre-0x1A WDA id) — **no UIM, no PDS, no
  CAT/LOC/WMS/DSD**. Live probes: DMS IMEI ✓; NAS Get Serving System ✓
  (`not_registered` — no SIM in the slot) but **Get Signal Info = "Invalid
  QMI command"** (NAS 1.0 predates it); WDS answers status/settings and
  ACCEPTS Start Network (no "Invalid" — it hangs instead, consistent with
  no-SIM/no-registration). `qmi_wwan`'s data link reports **raw_ip=N**
  (802.3 framing; the in-driver WDA handshake is gone in 6.18 and the
  `raw_ip` sysfs flag is manually settable, so raw-ip capability stays
  unverified without a SIM to drive a real session). Code-side this audit
  also confirmed `modem_init_qmi` treats UIM as OPTIONAL (dms fallback) and
  the telemetry data-mode has a DSD→QENG→radio_ifs fallback chain — the
  wwand QMI backend is old-stack-tolerant by design; the E182E stays out
  for the missing NAS signal message, the unverified 802.3 link and the
  empty SIM slot, not for a hard UIM dependency.

**Fibocom RSRP-0 sentinel.** The FM350/T700 reports RSRP 0 when the signal is
too weak to measure; the status page read that as a perfect 0 dBm. Anything
above -44 dBm (the physical RSRP ceiling, 3GPP TS 36.133 9.1.4) is now null,
like the 255 sentinel on the offset-coded rows.

**ReferenceError in the RNDIS v6 path.** `ensure_wan6` called a bare `log(...)`
that does not exist in that scope — every RNDIS v6 connect threw and crashed
the daemon ("FM350 disconnects often" was very likely this crash-loop).
Both call sites now use `logmod.log`.

**Migration anchors on hardware, not /dev nodes.** `config.migrate_plan`
accepts `opts.resolve_path`; `/dev/cdc-wdmN` resolves to the wireless-style
`option path` (`1-1.3.4` short USB id; a wwan-framework port keeps its sysfs
path) via the new `discovery.path_of_device` — a `/dev` node is an
enumeration-order artifact that can flip with a second modem. Wired through
`daemon.migrate` (ubus, LuCI, `wwandctl migrate`) and `/usr/libexec/wwand/migrate`.

Also on the box (observation, not code): after an EMI reset the E3372H can
come back with stale descriptors ("CDC Union missing" on rebind); USB
re-authorization (`echo 0/1 > authorized`) heals it. A candidate for a
recovery rung cheaper than power-cycle — documented, not built.

---


## One datapath interface: MBIM joins it, and `none` becomes `raw_ip` (2026-08-29)

Three changes to the same seam, in the order they were asked for.

**`none` -> `raw_ip`.** The no-mux datapath now says what the parent IS (plain
raw-IP framing) instead of what it is not. `netlink.canon_mux()` is the one place
that decides, and it keeps two older spellings alive: `none`, which is what every
config written before this says, and `raw-ip`, which is how the thing is written
in prose and therefore what people type. That second alias is not politeness — a
hyphen would have failed `config.uc`'s shape check and silently fallen back to
`auto`, i.e. muxing switched back ON in a config that asked for it off. The
underscore is canonical because a datapath name doubles as the module name of an
add-on package, and a module path cannot carry a hyphen.

**The MBIM session mux is now a datapath like the others.** It was
`netlink.setup_mbim()`, a second implementation beside `setup()`, and the two had
already drifted: the stale-child prune was fixed in `setup()` and missed there,
leaving the MBIM path with exactly the defect it had been fixed for (its own
comment said so). It is the built-in `vlan` backend now — one `links()` that
creates the 802.1q sub-devices and sizes the trunk, with prune, parent rename,
child MTU and link-up coming from the shared path. `modem_mbim` calls
`select_backend()` + `setup()` like `datapath_qmi` does, so `option mux` works on
MBIM for the first time: `raw_ip` turns the session mux off, and an add-on
package can claim an MBIM box.

Getting a VLAN mux through a path built for QMAP took two new contract fields
rather than an `if (backend == 'vlan')`, and both are behavioral:

- `aggregate` (default true) — the QMAP header add-on, `rx_urb_size`, and the
  aggregation buffer on the parent MTU. vlan sizes the trunk itself (largest
  child + 4 for the tag), so it opts out.
- `programs_parent` (default true) — whether this datapath reprograms the parent
  driver's link-layer format, which the driver accepts only while the parent is
  DOWN. vlan programs nothing, and the bounce is not free: on a restart that
  adopts a live session it would drop the traffic it is adopting. The bounce now
  also needs something to actually program (a `qmi` sysfs group or a backend
  `pre`), so an unmuxed MBIM parent is left alone too.

Plus `child_name()`, because the three places that must agree on what a child is
called — the shared prune, the parent-rename collision check, and `links()` —
cannot agree if only one of them knows the naming rule. Returning null means "no
child at all", which is MBIM session 0 riding the parent untagged.

`select_backend()` is protocol-aware for the same reason: under `auto` an MBIM
box must never be handed a qmi_wwan mux, and the rmnet module being loaded is a
property of the kernel, not of the modem. Built-ins have a per-protocol
preference order; a plugin declares `proto` (default `[ 'qmi' ]`). Naming a
datapath outright is still honoured whatever the protocol — an explicit act is
not second-guessed.

**The LuCI list comes from the daemon.** `status` `globals.datapaths` is a
catalog — name, kind (mode/builtin/plugin), the control protocols it applies to,
a one-line description — assembled from what `netlink.uc` implements plus the
add-on packages actually installed. The dropdown builds itself from that, so an
installed `rmnet_nss` is offered with no UI change. One limit worth knowing: LuCI
options are per-column, not per-section, so on a box with both a QMI and an MBIM
modem the list is the union of both and the protocol tag on each entry is what
tells the rows apart.

48 suites / 3068 checks green (was 2935). New coverage: the alias spellings
through `select_backend`, `setup` and `config.parse`; the vlan backend through
the shared `setup()`, including the two things it must NOT get (urb arithmetic,
parent bounce); the per-protocol auto selection; `aggregate`/`programs_parent`/
`child_name` on a plugin; the catalog. `test_modem_mbim` now drives a real
datapath through `modem_mbim`, so "MBIM goes through `netlink.setup()`" is
asserted end to end rather than by reading.

**The probe gate is gone (same day).** `select_backend()` used to short-circuit
to `raw_ip` before running a single probe whenever the config had no channels —
which meant an add-on datapath could not introduce itself on exactly the installs
that never write `option mux`, autosetup boxes included. `datapath_qmi` now
always asks (`want_mux = true`), and the two things that gate used to protect are
handled where the information actually is:

- **unclaimed box.** `select_backend` under `auto` falls back to `raw_ip` instead
  of null when no mux was required; the caller fails with
  `mux_backend_unavailable` only when `mux_links` is non-empty. Every previous
  failure survives — a configured channel with no available backend still fails
  loudly.
- **claimed but no channels.** `setup()` drops any backend with no children to
  build back to `raw_ip` and logs it. Not cosmetic: rmnet's `pre` writes
  qmi_wwan's `pass_through`, which hands raw QMAP frames to an rmnet child that
  does not exist — link up, no traffic. The drop happens AFTER the backend's own
  `prune()`, so a datapath whose children the KERNEL owns (a vendor driver
  creating them at module load) keeps them instead of having the default prune
  delete them.

The measured matrix, QMI: channels+rmnet -> rmnet; channels+no mux driver ->
FAIL; no channels+rmnet -> selected, effective `raw_ip`; no channels+nothing ->
`raw_ip`. MBIM: a session-0-only config reports `raw_ip`, not a `vlan` with no
children — the count that decides is children, not mux entries. `status` reports
the datapath that actually ran (`setup()` returns it), not the one selected.

**Autosetup writes a mux channel on QMI (same day).** The zero-config path
created a single unmuxed interface, so the probes it now runs found a datapath
and then had nothing to build. It writes `mux_id '1'` when — and only when — the
modem can carry one: `netlink.mux_available(fx, netdev, proto, plugins)`, QMI
only, against the netdev resolved from THAT modem's control device. Per modem,
not per box, and the distinction is real: rmnet is a global module but qmimux
reads the device's own `add_mux` node and an add-on probes the device, so a
two-modem box can legitimately answer differently for each. MBIM and NCM keep
their defaults — an MBIM session is not a QMAP channel and NCM has no mux.

The decision lives in `netlink.uc` rather than `main.uc` so it is testable at
all; `main.uc` only supplies the two discovery answers (protocol, netdev) and
the daemon hands over its installed-datapath map, since it is the side that
scans for them. Parser output for the written section was checked rather than
assumed: `device 'wwand0'` + `mux_id 1` yields `mux_link wwand0`, muxed — the
parent keeps its raw kernel name and the stable name moves to the child, which
is the existing rename-collision path.

**The rmnet_nss vendor datapath, written from the driver sources.**
`src-ucode/datapath_rmnet_nss.uc` (in `WWAND_UCODE_PLAIN`; the feed still has to
package it). Four things came out of reading `qmi_wwan_q.c` / `rmnet_nss.c` /
quectel-cm that no amount of reasoning would have produced, and one of them
needed a contract change:

- **The QMAP id is not the channel number.** `priv->mux_id = QUECTEL_QMAP_MUX_ID
  + offset_id`, `QUECTEL_QMAP_MUX_ID = 0x81`; quectel-cm agrees
  (`profile.muxid = <digit> + 0x80`). wwand bound WDS to the config number,
  which the driver drops outright ("drop qmap unknow mux_id"). New optional
  `map_id(entry)` on the datapath contract; `setup()` returns `map_ids` and
  `context.uc` binds to that. Identical to the channel number for every datapath
  that creates its own children, so nothing else moves.
- **The driver's attribute group has no `.name`**, so `qmap_mode`, `qmap_size`
  and `link_state` sit DIRECTLY on the netdev — there is no `qmi/` group, hence
  no raw_ip, no pass_through, no rx_urb_size (`dev->rx_urb_size = qmap_size` is
  set by the driver at bind). `programs_parent: false`, `aggregate: false`.
  wwand's existing `link_state` path already used the flat location and the
  driver's semantics (`offset_id = (link_state & 0x7F) - 1`, 0x80 clears) match
  what it writes — verified, not assumed.
- **The children are the kernel's**, registered in the USB probe, one per the
  `qmap_mode` module parameter (S_IRUGO — fixed at insmod). `links()` adopts,
  `prune()` is a no-op, and a channel beyond `qmap_mode` produces an error that
  names the number and says modprobe.d, because that is the actual fix.
- **rmnet_nss must be loaded before the modem's driver binds.** `use_qca_nss =
  !!nss_cb` is captured at child creation. So the probe gates on loaded, not
  installed: claiming an installed-but-unloaded box would hand back children
  with no NSS context and no way to tell.

The probe is `/sys/module/rmnet_nss` AND a `qmap_mode` node on THIS netdev —
specific enough that it cannot claim a mainline qmi_wwan box, whose knobs live
under `qmi/`. Worth knowing why that matters: mainline `rmnet`'s own probe is
satisfied by a vendor parent (it wants `/sys/module/rmnet` and the ABSENCE of a
qmi group), so without the add-on installed, `auto` lands on `rmnet` and builds
children that forward on the CPU — which is exactly the reported symptom. A test
pins both halves of that.

**The protocol restriction moved onto the datapaths themselves.** It used to
live in two places beside them — an `AUTO_ORDER` map per protocol and a `CATALOG`
table repeating `proto` for the UI — with the built-ins carrying no declaration
at all. Now every datapath states its own `proto` (rmnet/qmimux qmi, vlan mbim,
add-ons defaulting to qmi), `BUILTIN_ORDER` is one list filtered by it, and the
catalog is BUILT from the entries, so a datapath and its catalog line cannot
disagree about what it serves.

It is also enforced now where it was not: naming a datapath whose protocol does
not match used to be honoured ("an explicit act"), which was the right rule for
a probe and the wrong one here — rmnet's QMAP framing on a cdc_mbim session
cannot carry traffic however firmly it was named. It is refused with an error
naming both protocols, the way a missing package is.

LuCI filters PER ROW, which needed a `renderWidget` override: a LuCI option
object is shared by every section of a GridSection, so `o.value()` is per column
and the plain list was the union across a QMI and an MBIM modem — offering each
of them datapaths the daemon now refuses. The rendering hook is the one place
that knows which section it is drawing. Unknown protocol (modem not running)
shows everything, and the value already configured is always kept in its own
dropdown.

**`wwand-datapath-rmnet_nss` is its own feed package** (`+wwand-qmi`), with the
underscore intact: the datapath name is also the ucode module name and what the
daemon's "package not installed" note is built from, so the three must read
alike. It deliberately does NOT depend on the vendor driver or the NSS shim —
those come from the board's kernel tree, and the package has to stay installable
next to them rather than try to name them. The base package's install list is
per-file, so nothing overlaps.

**Status page.** `modem_datapath` gained an `extra` block fed by an optional
`status(fx, netdev)` on the datapath, because the generic rows know QMAP and NTB
and nothing about a vendor datapath — the NSS one reports `qmap_mode`,
`qmap_size` and whether the shim is loaded; LuCI renders whatever keys arrive.
Asking that question also surfaced a real defect in the first cut of the NSS
datapath: it adopted the driver's `wwan0_1` and never renamed it, so netifd —
which binds `option device` to the context's stable `wwandN` — would have left
the interface unclaimed, and every child-side status row (channels, counters,
learned device) would have been empty. It renames now, tolerating a restart that
already did; the NSS context is keyed on the netdev, not its name.

**A second pass over the vendor sources caught two more.** `qmap_mode > 0` is
not the same as "there are children to adopt": qmi_wwan_q registers them only
when `use_rmnet_usb` is set (qmap_mode > 1, or three idProducts), so with
qmap_mode == 1 on anything else the PARENT carries the QMAP and no child exists
— and no `nss_create()` ran either. The probe now tests for `<netdev>_1`, which
is what the vendor's own dialer script tests before falling back to the bare
parent. And `map_id` is `0x80 + channel`, the driver's arithmetic, not the bit
set that only happens to agree below channel 128.

Also confirmed rather than assumed: `link_state`. The driver reads
`offset_id = (link_state & 0x7F) - 1` with 0x80 clearing; quectel-cm writes
`(link_state ? 0 : 0x80) + (muxid - 0x80)` where muxid is `0x80 + channel`. Both
say the value is the channel number, which is what wwand's shared code already
writes — and it is not optional on 5G modems, where the driver starts with
`link_state = !lte_a`, carrier off until someone writes it.

**And that decision was taken: the probe is the vendor signature alone.** What
the datapath does is adopt qmi_wwan_q's children; they need adopting whether or
not NSS is loaded, and the driver decides the offload by itself. Gating on the
shim too was worse than useless — a non-NSS vendor box then fell through to
mainline rmnet, whose probe such a parent satisfies (it asks for
`/sys/module/rmnet` and the ABSENCE of a `qmi` group), and rmnet built its own
children on a parent that already demuxes QMAP internally. A missing shim is now
reported at notice with the ordering that would fix it, and shown on the status
page (`nss_shim: absent`), rather than acted on. The name still says rmnet_nss
because that is what the datapath is FOR.

**Review catch: `option mux` off did not switch muxing off.** Two defects, one
of them mine. The interface loop compares the modem's mux against `'raw_ip'`,
but canonicalisation ran AFTER it — so a legacy `option mux 'none'`, the very
spelling the alias exists for, never matched the guard. The canonicalisation
moved above the loop.

The older one: the guard cleared `mux_id` and left `muxed` alone, and the
auto-assign pass a few lines down hands a channel back to every context whose
`muxed` is set. So "mux disabled" never disabled anything, in any spelling —
the config asked for a plain parent and got a mux child name netifd would then
look for on a datapath that builds none. `muxed` and `mux_link` are cleared too
now. Covered for all three spellings.

**...and the same mistake in three more places.** Chasing the review finding
turned up its siblings: `backend == 'rmnet'` decided both QMAPv5 negotiation and
uplink coalescing, and `dp.backend != 'rmnet' && != 'qmimux'` decided whether
the aggregation ratio on the status page means anything. Every datapath added
later fell outside all three without a word — the NSS one would have negotiated
plain QMAP and shown no aggregation ratio. They are capabilities now
(`netlink.datapath_caps`): `qmap` (QMAP on the wire — a different question from
`aggregate`, which is who sizes the buffers), `qmap_v5`, `tx_aggr`. Behaviour
for the three built-ins is unchanged; the matrix is pinned by tests.

The NSS datapath declares `aggregate: false, qmap: true, qmap_v5: true`. The
last one is the only unmeasurable choice in it: the driver fixes `qmap_version`
at bind from its own table and exposes it nowhere, so it follows the reference
client for this exact driver (quectel-cm sends `qmap_version = 0x05`). First
thing to check on hardware — and the plain-QMAP fallback still catches a modem
that refuses v5 outright.

**A Codex review of the run found three more in the adopt path**, all the same
shape: a NAME was treated as an identity.

- The rename's return value was ignored, and the target pushed into `mux_devs`
  regardless. If the name was taken, the shared code then set the MTU on a
  device we do not own and netifd bound to it, while the real channel stayed
  unclaimed — link up, no traffic, the exact failure this datapath exists to
  avoid. It now refuses to rename onto an occupied name, checks the result, and
  drops the channel with a reason.
- On a restart, ANY netdev carrying the target name was adopted. It now has to
  carry the parent's MAC, which the driver copies onto every child
  (`__dev_addr_set(qmap_net, real_dev->dev_addr)`). That proves nothing between
  two all-zero raw-IP addresses, but it rejects an ordinary netdev that happens
  to hold the name.
- A channel whose configured name CHANGED found neither the canonical nor the
  new name and was skipped under an error blaming `qmap_mode`. The two causes
  are told apart now: too few channels (a modprobe.d edit) versus renamed by an
  earlier configuration (only a driver reload restores it).

Chasing those also corrected a wrong claim in the code: the comment said the
default prune would delete these children. It would not — it matches on
`iflink` pointing at the parent, and the vendor driver sets no `ndo_get_iflink`
and links no upper device, so each child's iflink is its own ifindex. Overriding
`prune` is still right; the reason in the comment was not.

**A second NSS datapath, for PCIe/MHI (2026-08-30).** Research into whether the
Quectel manager does MBIM with rmnet_nss turned up that it does — but through
the DRIVER and only on PCIe/MHI. `qmap_bridge_mode.c` has three paths: MBIM over
USB is an 802.1q VLAN (no QMAP child, so no `nss_create()` hook — which is
exactly what wwand's `vlan` datapath builds), MBIM over MHI has real QMAP
children, and QMI over USB is the `qmi_wwan_q` case already shipped. The NSS
hook lives in `mhi_netdev_quectel.c` and is protocol-independent.

`datapath_rmnet_nss_mhi.uc` adopts those children. Nearly every detail differs
from the USB sibling — dot-separated child names, a child MAC whose last octet
is the channel number, both control protocols — and the wire id is where reading
the driver mattered:

    u16 tci = mux_id;                 // priv->mux_id = mbim_mux_id + offset
    if (qmap_mode > 1) tci += 1;      // "rmnet_mhi0.X map to session X"

with the RX side indexing `mpQmapNetDev[tci - 1 - mbim_mux_id]`. So the MBIM
session id is `mbim_mux_id + n`, and `mbim_mux_id` is 0 everywhere except an
SDX7x (PCI 17cb:0309), where it is 112 — meaning on ordinary hardware the wire
id already EQUALS wwand's channel number and nothing is remapped. A prior
research note had this as `mbim_mux_id + offset`; the driver's `+1` is what
turns the common case from "needs a mapping" into "already correct".

Carrying that into MBIM took `map_id(entry, netdev, fx)` (the answer is a
property of the device and must be read, not assumed) and a `wire_session()` in
`context_mbim` feeding CONNECT, DEACTIVATE, IP_CONFIGURATION — and the
unsolicited CONNECT indication, which `modem_mbim` matches to a context BY
SESSION ID. That last one would have silently swallowed MBIM's primary
session-loss signal.

An audit of the change before commit found the chain was inert anyway:
`modem_mbim` did not store `map_ids` when it built `self.datapath`, so every
remap was dead code and no test noticed, because none drove MBIM setup through
the modem with a remapping datapath. Two more from the same audit: the SDX7x
detection read the PCI ids under the netdev's own `device`, where they do not
exist (`SET_NETDEV_DEV(ndev, &mhi_dev->dev)` — they are on an ancestor), and the
probe checked only that the module was loaded, not that the netdev belonged to
it. The test fixture now models the real sysfs shape rather than inventing the
convenient one.

**Not on hardware yet.** Everything above is host-tested only. The NSS datapath
has no witness at all here — it needs kuncy7's IPQ807x + RG500Q, and the first
thing to check there is whether the WDA format negotiation wwand does itself
(quectel-cm's job until now) is accepted by `qmi_wwan_q` with `qmap_mode` set.
This also wants a cold-boot autosetup run on the Cudy LT300 (the autosetup HW-verify platform, but
NCM — so it must come up UNMUXED there) and a QMI box for the muxed case. The MBIM datapath
change wants a run on 246 (EG06), and the QMI side a regression run on 245 —
`option mux` is unchanged there in effect, but the parent-bounce condition is
new code on a path every QMI modem takes.

## Open after 1.5.0 (2026-08-27)

Things a later session should not have to rediscover. None of these block the
release; each is either waiting on hardware we do not have or on somebody else.

**The SIGSEGV fix is reasoned, not reproduced.** `transport.uc`/`atcmd.uc` freed
a uloop handle from inside its own callback — a use-after-free that a 64-bit
allocator absorbs and MIPS32 does not. The report is from a RUTM11 (ramips); the
Cudy LT300 here is the same mipsel_24kc but drives NCM over AT ttys and never
opens a cdc-wdm control device, so it does not execute the faulty path at all
(five restarts clean). Confirmation has to come from the reporter running 1.5.0.

**The R4 cannot hold a SIM**, so MHI coverage stops at SIM_BLOCKED. Everything
up to and including the datapath is HW-validated; registration, bearer
activation, live telemetry, the reconnect path and the zero-rx watchdog are not,
and cannot be until that board's SIM1 path is repaired or the modem moves to
another host.

**`atcmd_mbim.attach()` is unproven on hardware.** The `open()` half — our own
MBIM client on a modem some other backend drives — is HW-verified on the R4.
The borrowed-client half has no witness: the one MBIM-driven modem to hand (an
RM520N-GL on a GL-X3000) ADVERTISES the QDU service in DEVICE_SERVICES and then
never answers CID 8, so it exercises the decline path only. Different firmware
(RM520NGLAAR03A03M4G vs …APR01A04M4G on the R4) — QDU support is per-firmware,
not per-model, which is why the probe exists.

**The kernel DUN patch is downstream only.** `patches/kernel/969-*.patch`, scoped
to the mediatek target. Upstreaming it properly means the two-patch shape
described in that README — teach `mhi_wwan_ctrl` to decline a port whose channel
the device refuses to start, THEN widen the generic channel list — because MHI
has no capability exchange and over-declaring otherwise yields a port that
cannot be opened.

**LuCI row actions wrap but stack.** The overflow is fixed and confirmed on
screen; with nine buttons in a narrow column most lines hold one button, so the
row is tall. Folding the rare actions (Reboot/Repower/Delete) into an overflow
menu would be nicer — a design decision, not a defect, so it was not made
unilaterally.

**Nine PR threads wait on the reviewer**, not on us: every one has an answer,
including the ENOEXEC question (bytecode keeps the `#!` line, so no ENOEXEC —
measured on the packaged artifacts). `#30185` stays at CHANGES_REQUESTED until
they are resolved. `~/.local/bin/wwand-pr-status` reports this in ~1.4 s from
cache and exits 1 while anything is genuinely unanswered.

**Bytecode ships on snapshot only — and that is correct, not a defect.**
Measured on the published r45: the snapshot package carries bytecode
(`#!/usr/bin/env ucode\n\x1bucb`, 175 KB), the openwrt-25.12 one carries source
(`// SPDX-…`, 266 KB). Two earlier claims here were wrong and are corrected:
this is not "the first release shipping bytecode" without qualification, and a
failure does NOT surface as a loud build error — the cmake capability probe
falls back to source on purpose, which is why the run is green.

The cause is exact. 25.12 ships ucode 2026.01.16, snapshot 2026.07.09, and the
older one does not know the `-cmodule` flag at all:

    $ ucode -s -cmodule,dynlink=fs -o out probe.uc      # 25.12
    Unrecognized -c flag "module", ignoring
    Syntax error: Exports may only appear at top level of a module

It ignores the flag, compiles the file as a program, and `export` is illegal
there — the syntax error is a consequence, not the cause. `ucode/host` builds
fine and the dependency resolves; nothing is broken.

There is no workaround, which was checked rather than assumed:

- A PROGRAM with `import` does compile on 25.12 (`-cdynlink=fs`, rc=0, and the
  result runs), so `/usr/sbin/wwand` and `wwandctl` could be bytecode there.
  Not worth taking: the win is the ~45-file module tree (the 41 ms -> 5 ms in
  the Kconfig help is "for the core imports"), while the interpreter-version
  coupling arrives in full the moment any part is bytecode.
- Compiling the modules elsewhere and merely SHIPPING them does not work
  either: the 25.12 interpreter cannot LOAD a bytecode module. It reads the
  file as source and stops at the magic (`Unexpected character`, byte 1), with
  or without an interpreter line. Producing and consuming precompiled modules
  evidently arrived together with `-cmodule`.

So this needs no code: 25.12 flips to bytecode by itself once its ucode carries
the flag.

**ucode bytecode is NOT architecture-specific.** A module taken from the
published aarch64 snapshot package loaded in an x86-64 interpreter and exposed
its ten exports. The binding constraint is the format version alone — which is
what the init-script guard and the Makefile note are about, and the reason
those speak of the interpreter rather than the target.

## PCIe/MHI bring-up on a BananaPi BPi-R4 (2026-08-26)

A Quectel RM520N-GL in the M.2 key-B slot, kernel 6.18, driven over QMI. It went
from "no control device" to a working muxed datapath plus an AT channel. The
mechanics live in `docs/architecture.md` §8; what follows is what was wrong and
how it was found, since none of it was visible from the USB side.

**Port and device naming.** The kernel publishes QMI, MBIM and QCDM as separate
nodes of one wwan device and attaches them in its own order, so first-come
binding took MBIM. `discovery.preferred_wwan_port()` now picks the best sibling
on the same device. Autosetup also wrote `wwan0qmi0` bare into uci — only
`cdc-wdm*` was being prefixed — so the daemon reported `control device not
present` for a node that existed.

**Datapath.** `mhi_net` does not hang its netdev off the wwan device; the data
channels are siblings under `mhiN`. The lookup widened to that parent, choosing
`IP_HW0` over `IP_SW0`. Then setup died on `raw_ip unavailable`: those knobs are
qmi_wwan's `qmi` sysfs group, which a raw-IP-by-construction driver does not
have. A missing GROUP is now "nothing to configure"; a knob missing from an
existing group stays fatal.

**Multi-PDP works, and one thing about it is easy to get wrong.** rmnet stacks
on `mhi_net` directly — `pass_through` exists only because qmi_wwan would
otherwise parse QMAP itself — so `select_backend` no longer demands a knob that
cannot exist there. Verified with two contexts. The subtle part: on MHI there is
no `rx_urb_size`; `mhi_net` sizes RX buffers from `mru`, and our profile sets
none, so the **parent MTU is the receive buffer**. It must stay coupled to the
negotiated `dl_max_size` or aggregated frames get truncated silently.

**Uplink aggregation never worked anywhere.** Chasing "uplink aggregation
unavailable, kernel default kept: Invalid argument" led to
`WW_ETHTOOL_MSG_COALESCE_SET` being defined as 21 in `io/src/wwand-io.c`.
`ETHTOOL_MSG_COALESCE_SET` is **20**; 21 is `PAUSE_GET`. Every request was sent
as a pause query carrying coalesce attributes, which the kernel answered with
EINVAL — on every transport, not just MHI, for as long as the call has existed.
The log line said "unavailable" and was taken at face value. With the id fixed
the kernel ACKs and both children report `uplink aggregation on (11 frames /
4096 bytes)`.

**The modem died twice before any of this.** `mhi-pci-generic` runtime-suspends
the endpoint into D3, and this one does not survive the resume: the link returns
`Uncorrectable (Non-Fatal)` / `CmpltTO` and never answers again. `remove`+
`rescan`, the bridge's `reset_subordinate` and a re-probe of the whole
`mtk-pcie-gen3` controller all end at `LTSSM detect.quiet`; only a cold boot
recovers it, and the board has no modem GPIO to pulse. So `netlink.pin_runtime_pm()`
pins the endpoint and its bridge to `power/control = on` the moment the control
device is seen — before the state machine, because the fatal suspend hit while
the modem sat idle in `SIM_BLOCKED`.

**AT on a modem with no AT port.** The generic Qualcomm MHI profile declares no
DUN channel, so there is no `/dev/wwanNat0` — and `protocol_switch`, `QSIMDET`
and AT telemetry all need AT. QMI service 0x08 is not a way in (it is ATCoP
*forwarding*: a client registers command names the modem forwards *to* it; the
IDL was confirmed against the modem, including `0x0027`, which exists only from
minor 6 and pins the version). The way in is Quectel's AT-over-MBIM pipe — QDU
service, CID 8 — reachable because MBIM is a separate MHI channel even while
QMI drives the modem. `atcmd_mbim.uc` implements it as an ordinary atcmd
transport; `ubus call wwand modem_at` now answers on this hardware. It carries
no URCs, so a real DUN channel remains the better long-term answer.

**The R4's SIM1 holder is faulty on this unit — MHI validation stops at
SIM_BLOCKED.** Worth recording so nobody repeats the hunt. The board hardwires
SIM1 to the M.2 slot and SIM2/SIM3 to the two mini-PCIe slots (device tree, and
confirmed by BPI's developer in the forum: there is no GPIO muxing, "the slots
are hardwired to one specific slot"), so only SIM1 can reach our modem. In SIM1
the modem drives the card lines and gets nothing back: `CARD_STATE_ERROR` with
`error 3 = no ATR received`, and `power off` -> `power down` -> `power on` ->
`no ATR` again, so the slot obeys and genuinely retries. `AT+CPIN?` answers
`CME 10`, `AT+QSIMSTAT?` reads `0,0` with detection enabled in BOTH polarities,
and `AT+QCCID` answers `CME 13`. The same card works in another device, and
another user runs exactly this modem on SIM1 successfully — so it is neither the
card nor the design, but this board's SIM1 path.

Two things that look like the answer and are not. A BPi-R4 write-up
(github.com/Phwatang-Blog/BPIR4-with-RM520NGLAA) reports that the board very
easily fails to power the SIM1 slot and that a TRUE cold boot — mains removed,
not `reboot` — recovers it; every test here was already a cold boot with the
power pulled, so that is not it. The same write-up warns that the RM520N-GLAP
carries no USB at all, unlike the GLAA: this board's modem reports
`RM520NGLAPR01A04M4G`, which is why it never enumerates over USB and why MHI is
the only path to it. That one is worth knowing, but it does not touch the SIM.

Consequence for coverage: everything up to and including the datapath is
HW-validated on MHI (port selection, `/dev` naming, `mhi_net` netdev discovery,
the absent `qmi` sysfs group, QMAP + rmnet with two contexts, uplink
aggregation, the runtime-PM pin, AT over both DUN and MBIM). Registration,
bearer activation, live telemetry, the reconnect path and the zero-rx watchdog
remain untested on MHI until that board can hold a SIM.

**A caution about `no ATR received`.** With `AT+QSIMDET` disabled — the default
on this modem — the modem ignores the detect pin and simply tries the card, so
an EMPTY slot reports the same `no ATR` as a card that will not answer. It does
not distinguish "empty" from "present but silent" on this board, and reading it
that way sent this investigation down the wrong path for a while. Enabling
detection is what makes the modem report `no_sim` instead — but leave it
disabled where the detect line may be unwired, or a perfectly good card becomes
invisible.

**SIM diagnosis without AT.** `GET_SLOT_STATUS` and `GET_CARD_STATUS` use
DIFFERENT enums — `QmiUimPhysicalCardState` (0 unknown/1 absent/2 present)
versus `QmiUimCardState` (0 absent/1 present/**2 error**). A card that is there
but never answers sits in state 2 with `error_code 3 = no ATR received`; wwand
reported that as `no_sim` and sent us hunting the slot wiring for hours. It now
names the modem's own reason, and stops reading EFs off a slot it knows it
cannot read (four `err 48` warnings per LuCI poll otherwise).

## Two field reports and a maintainer review (2026-08-24)

### The NR signal block outlived the 5G it described

Reported on an FM350-GL riding out heavy rain: the modem fell back from 5G to
LTE, the serving cell correctly read LTE/B3, and the two 5G bars underneath kept
showing the last NR reading — RSRP -83 dBm, SINR 10 dB, frozen.

`fill_signal_from_serving()` builds the new signal block from a COPY of the
previous one and then writes `sig.lte` / `sig.nr5g` only for the branches the
serving read reports. A branch not written on a tick therefore survived
untouched, forever. The cells block is rebuilt from scratch and did not have the
problem, which is why the page showed a serving cell and a signal block that
contradicted each other.

A branch the serving read does not report is deleted now. Safe exactly here:
`assemble_cells()` returns before this point unless the read produced at least
one branch, so an empty or failed read can never blank a live reading. The
regression test replays the report and fails without the fix — checked, because
a regression test that passes either way is worth nothing.

QMI does not share the bug: it replaces `self.signal` wholesale.

### `extendprefix` on an ipv6-only APN

A mobile network hands out a single `/64` on the WAN link and delegates no
prefix, so odhcp6c has nothing to give the LAN. RFC 7278 is what shares that
`/64`, and in OpenWrt it is off unless `extendprefix` is set.

The `proto wwand` path already did the equivalent in the shim
(`proto_add_ipv6_prefix`). The gap was the **dhcpv6 subinterface** — which is
precisely where the ipv6-only RNDIS model has its only address, since there the
modem's RA is the whole story and there is nothing for the shim to push.

The subinterface now gets `extendprefix '1'` when the APN is ipv6-only, both at
creation and — the case that matters in the field — filled into a section from
an earlier connect. Two limits keep it a default rather than a policy: an
explicit `extendprefix '0'` is never overwritten, and only a section wwand named
itself (`<parent>_6`) is touched, because reference.md promises that a
user-written section is left alone. `ipv4v6` is deliberately not covered: the v4
half keeps LAN clients working there.

Note the spelling — the netifd option is `extendprefix`, not `extendedprefix`.

### Device blocklist: `device` is not always a device name

A maintainer on openwrt/packages#30185 asked whether the blocklist covers
`3g`, `directip` and `modemmanager`. Checked against the handlers rather than
reasoned about: comgt's `3g` and `directip` declare `device:device` — a real
device node — and were already covered. `modemmanager` declares a plain
`device` and puts a **sysfs path** in it, which can never match a `/dev` node or
a netdev name, so such an interface claimed its modem invisibly.

A `device` under `/sys/` is a path-shaped claim now, resolved through the same
`claim_path()`/`same_hw_path()` comparison as uqmi's `devpath` and `wwan.sh`'s
`bus`. Keyed on the prefix, not the proto name: `mmcli --modem=` also takes an
index or a D-Bus path, and neither names hardware anything could resolve.

The general shape of the mistake is worth keeping: the enumeration was over
*protocols*, asking which options each uses. The question that actually decides
coverage is what KIND OF VALUE an option holds.

## A field session on the AT path: URCs, a reset that killed the modem, and an ifdown that would not stay down (2026-08-23)

An evening on the Cudy LT300 / MeiG SLM770A, with the network operator kicking
the modem off on request. Almost everything below was found by watching real
hardware rather than by reading code, and two of the fixes correct code written
earlier the same evening.

### Both AT ports are read now, and every URC says which one it came from

`open_at` used to open the second AT port (`at2`) LAZILY, on the first telemetry
poll, to save an fd on QMI/MBIM. But an unopened port does not go unparsed — it
goes UNREAD: nothing holds the fd, so whatever the modem pushes there is gone.
On NCM the first poll only runs at state READY, which left the whole SIM and
registration phase unwatched on a port some modems report it on. Both ports are
opened up front now; `at2_external` remains the only way to keep wwand off one.

The dispatch carries its channel and logs it at ONE site for all backends
(`urc[at]:` / `urc[at2]:`). That paid for itself immediately: the SLM770A
mirrors most URCs onto both ports, but `^DCONN` arrived on **at2 only**.

Two traps closed on the way. `atcmd.create` stored `DEFAULT_URC_PREFIXES` by
REFERENCE while `add_urc_prefixes` pushes in place, so the first modem's vendor
codes leaked into every AT engine in the process — including other modems'. The
arrays are copied per engine now. And `log.uc` DELETED control characters, which
made an embedded CR invisible: a merged line read as one seamless entry with no
hint that two had been joined. CR and LF are escaped instead, which is what
later ruled out a framing bug rather than merely suspecting one.

### The modem-reset GPIO had a latent polarity inversion

Two repower clicks 7 s apart left the modem dead until the box was mains-cycled.
`reset_pulse` derived the resting level from the CURRENT pin level, so the
second call sampled a line the first was still driving, took the ASSERTED level
for the resting one, and inverted itself: its release drove the modem down and
left it there, and every later pulse inherited the inversion (up for the hold,
down for good afterwards).

- **One pulse at a time.** A second call while one is in flight is ignored.
  Overlapping callers are real: the recovery ladder, `modem_reset`,
  `modem_repower` and the LuCI button all land here, and a second click while
  nothing visibly happens is the normal human reaction to a 30 s pulse.
- **Polarity is stated, not inferred.** A profile that knows its wiring sets
  `reset_run` (the level at which the modem RUNS); the pin is not consulted.
  `cudy,lt300-v3` is **active low** — measured, and the opposite of what the
  profile comment claimed. Sampling stays the fallback for unmeasured boards.
- `modem_repower` now logs who pulsed. It was the only one of the three paths
  that logged nothing, which is exactly what has to be told apart when two
  pulses overlap.

Exercised for real when the network kicked the modem: recovery asserted the
reset, the modem returned 40 s later and registered.

### `ifdown` did not survive a daemon restart

Reported as "the interface came back up on its own". An isolated `ifdown` is
clean; the trigger is a restart afterwards. Every interface-bound context is
built with `wanted: (cfg.interface != null)` — unconditionally true — so
operator intent lived only in the daemon's memory and died with the process.

netifd's RUNTIME `autostart` flag is the durable record, and it is safe to key
on: measured during a modem repower, the interface read `up=false`,
`available=false` but `autostart=TRUE`. Device presence lives in `available`.
The kick decision consults it and writes `wanted=false` back; the NCM
connect-first path re-checks before its own kick, so an `ifdown` landing in that
window is not undone by it.

### Registration `<stat>`: 9/10 are registrations, 11 is not

`parse_creg` treated only 1 and 5 as registered. **9 and 10 (CSFB not
preferred) are full data registrations** — on a network signalling them the
modem would have polled forever. 6/7 (SMS only), 8 (emergency) and 11 are real
attachments no PDP context can live on; they are reported as `restricted`
instead.

Stat 11 was observed on every registration cycle, in the same second as the
vendor's `^SRVST: 1` — which the SLM770A manual defines as "restricted
service". Two independent signals agreeing is what settled the reading; the
MeiG manual itself documents only `<stat>` 0-5.

The wait now says WHY it continues, once per change of reason
(`waiting for registration: registration denied (stat 3)`). It used to be
completely silent at notice level for minutes.

### Three commands this firmware refuses, and what to do about it

- **`AT+C5GREG?`** — a Cat4 modem answers a bare ERROR forever, and the
  registration poll asks every 2 s while searching. Latched off on the first
  refusal: an unknown command is unambiguous.
- **`AT^DSFLOWQRY`** — `+CME ERROR: 3` on every stats tick. Retired after THREE
  consecutive refusals, not one: a CME error can be a passing condition. The
  netdev counter takes over and feeds the same zero-rx watchdog, so only a
  wasted round-trip is lost. (The manual explains it: the command depends on
  `AT^DSFLOWRPT=1`, which it marks "to be developed". Enabling that does make it
  answer — tested — but the byte fields did not move against the netdev counters
  in a 60 s window, so the mapping stayed unproven and the idea was dropped.)
- **`AT+URCCFG`** — "Set the Active Reporting Port", documented in manual V2.5
  and answered with a CME error by firmware `B.0.3_EQ101`. That is why URCs
  arrive twice: we could not steer them to one port even if we wanted to.

### What the modem pushes, and what is worth doing with it

- **`^DEND`/`^DCONN`** (bearer down/up) are wired, but as HINTS: a `^DEND` arms
  a verification and only a real status probe tears the context down. The
  SLM770A was seen re-establishing a session by itself five seconds later, so
  acting on the notification alone would kill a session about to heal. First
  field firing showed the verification was too strict — `AT+ECMDUP?` came back
  EMPTY, which is how this modem says "no contexts", and an `=== 0` test did
  nothing. An empty list counts as confirmation now, but only there, where the
  modem's own `^DEND` is already on the record.
- **`^SRVST`** is recorded, not acted on: the registration URCs arrive in the
  same burst and already drive the poll. The VALUE is the gain — "registered
  but carrying nothing" was previously indistinguishable from a healthy modem.
  Seeded at init from `AT^SRVST?`, since the URC only fires on a change.
- **`^MODE`** refreshes telemetry, and that one is not redundant: signal and
  cells come only from the 60 s stats poll, so the old radio was shown for up to
  a minute after a RAT change.

`^SRVST` push and query share a name but not their field count
(`^SRVST: <status>` vs `^SRVST: <enable>,<status>`) — the URC parser is anchored
to one field so a query echo can never be read as a state. The `^CELLLOCK`
class of bug, caught before it happened.

### NCM reports an operator now

`on_registered` built `reg` without a PLMN, so every NCM modem showed an empty
operator — and LuCI r16, which read `reg.plmn`, threw on it and left the status
page at "loading...". QMI gets this free from the serving-system indication.

`^EONS=1` (MeiG) answers instantly with names; `AT+COPS?` is the generic
fallback and takes over 8 s on this firmware. Both answer shapes are accepted:
numeric gives mcc/mnc, and the 3GPP DEFAULT format 0 gives a name with no
numbers at all — which is what a Fibocom FM350 returns, and rejecting it would
have made the generic path a no-op on exactly the modem that has no vendor
command.

## Device blocklist: never touch hardware another interface names (2026-08-23)

The counterpart to the `takeover` removal, and the answer to the one review
thread still open on openwrt/packages#30185: dropping the `qmi` proto alias gave
exactly one owner per *interface*, but said nothing about the *device* behind it.
A `proto dhcp` on `wwan0` left over from a comgt-ncm setup is not a cellular
proto, so the autosetup guard did not see it, and a hand-written `wwand_modem`
pointing at a device uqmi drives was never checked at all.

- **`config.parse` collects the claims** into `result.blocked`: every
  `device`/`ifname`/`ctldevice` on a non-wwand interface section, mapped to the
  owning interface and proto.
- **Path-shaped claims too** (`result.blocked_paths`). Reading the stock
  handlers rather than assuming showed the first cut would have missed the
  configurations that matter most: `qmi.sh` and `mbim.sh` both take `devpath`
  (an absolute sysfs path used as a glob base) beside `device`, and `wwan.sh`
  — installed on both test boxes — declares **no `device` option at all**, only
  `bus`. A device-name-only blocklist is blind to exactly the stable-binding
  configuration a careful user writes. `discovery.claim_path()` normalises both
  spellings to the `/sys/devices/`-relative form `sysfs_path_of()` produces, and
  `same_hw_path()` compares on component boundaries so a claim on a USB device
  covers its functions. A claim resolving nowhere under `/sys/devices` is
  dropped, never treated as a wildcard.
- **Coverage checked against the handlers, not assumed.** `qmi.sh` and `mbim.sh`
  bind with `device`/`devpath`, `ncm.sh` (comgt, now in openwrt core at
  `package/network/utils/comgt`) with `device`/`ifname`, `wwan.sh` with `bus`
  alone. `PROTO_DEFAULT_OPTIONS` is `defaultroute peerdns metric`, so
  `proto_config_add_defaults` adds nothing device-shaped. All four are covered. Two exclusions, both deliberate — a **disabled**
  interface claims nothing (netifd never brings it up, so a stale section must
  not block a device forever), and `@name` references an interface rather than a
  device.
- **The daemon refuses to bind** a blocked device instead of contending for it,
  and checks the configured *and* resolved names (`option device wwan0` and the
  `/dev/cdc-wdm0` it resolves to are the same hardware; a foreign section may
  name either). The modem entry survives with a `control_note` naming the owner,
  so status/LuCI say "someone else owns this" rather than showing an absent
  modem.
- **Autosetup refuses too.** Its existing guard only recognised cellular protos.
- **Logged once, on change** — netifd fires the reload trigger for unrelated
  edits, so the notice repeats only when the claim set actually changes.

This is a runtime guarantee, which is what the review asked about: packaging
cannot express device ownership. It does not close the honest gap either — with
autosetup on, an unconfigured box still claims a modem nobody has claimed. It
closes the case where somebody HAS.

## `takeover` removed: one owner per interface, migration is always the user's (2026-08-21)

Raised in the openwrt/packages review (#30185): with `CONFLICTS` gone, uqmi's
`qmi.sh` and wwand's shim can be installed together, and under `takeover` both
registered `proto qmi` — netifd sources every handler in `/lib/netifd/proto`, so
which one won was decided by load order, which no package can control.

The switch is gone rather than documented as a caveat.

- **The shim registers `wwand` and nothing else.** The `qmi` proto name stays
  uqmi's. The `proto_qmi_*` alias functions are removed with it.
- **A bare `proto qmi` interface is never adopted.** `config.uc` accepts only
  `proto wwand` in the interface loop, so exactly one dialer owns any interface
  and its control device. The old two-step (accept `qmi`, then gate on
  `takeover`) collapsed into one condition — no dead branch left behind.
- **Migration is always explicit**, and now has three equal entry points: the
  LuCI modem list, `/usr/libexec/wwand/migrate --apply`, and a new **example
  uci-defaults script** for an unattended one-shot conversion at the next boot.
- **Nothing is installed under `/etc/uci-defaults` any more.** The old
  `99-wwand-migrate` hook ran on every install/upgrade (gated on `takeover`);
  the replacement ships inert in `/usr/share/wwand/examples/` and only does
  anything once the user copies it. Installing or upgrading wwand can no longer
  rewrite an existing configuration under any setting.

`migrate_plan` is untouched — it still converts `proto qmi`/`mbim`/`ncm`, which
is how an interface changes owner. The compat parser is untouched too: it is
reached by `proto wwand` without `option modem`, which is what the adoption
tests now exercise.

This closes the packaging side of the ownership question. The remaining honest
gap, called out in the review rather than papered over: zero-config **autosetup**
is on by default, so on a box with no wwand configuration at all a newly
appeared modem is still claimed (`option autosetup '0'` disables it).

## ucode bytecode: source by default, and a guard for the mismatch (2026-08-21)

Raised in the openwrt/packages review (#30185): precompiled bytecode is coupled
to the interpreter, and the package cannot express that.

The coupling is real and the suggested fix does not cover it. Bytecode carries
`UCODE_BYTECODE_VERSION` (ucode's `include/ucode/vm.h`, currently `0x02`), which
is a VM constant entirely separate from libucode's `PKG_ABI_VERSION` / SONAME
(`20230711`) — the two move independently, so depending on the ABI-versioned
name would be a proxy that only sometimes holds. No package in openwrt or the
packages feed ships precompiled ucode at all, which is why no mechanism exists.

Failure is clean but fatal: `program.c` rejects a mismatched version with
"Bytecode version mismatch, got 0xNN, expected 0xNN" and the load fails, so the
daemon exits at once — and procd respawns it forever with nothing explaining
why.

- **Source is now the default** (`CONFIG_WWAND_UCODE_PRECOMPILE`, default off —
  the old `WWAND_UCODE_SOURCE` opt-out is inverted). Precompiling stays
  available for a self-built image, where ucode and wwand come from the same
  tree and the coupling holds by construction. In a feed, where ucode upgrades
  on its own, we must not create it.
- **The init script refuses instead of respawning** (`wwand_modules_loadable`):
  it probes one module through the system ucode and, on exactly the two
  bytecode failures, logs what happened and what to do. Any other import error
  falls through, so an unrelated problem never blocks the daemon. Verified
  against a hand-patched version byte (`0x02` -> `0x09`), which produces the
  expected message and is caught.
- What the precompile is worth, measured over 20 runs importing
  `daemon`/`config`/`ubus`: **41 ms -> 5 ms** per start on x86, tree 1.2 MB ->
  860 KB. Real, but not worth an inexpressible coupling in a distro feed.
- Note: an openwrt-25.12 base never had the exposure — its ucode predates the
  flags the CMake capability probe requires, so that build already fell back to
  source. Snapshot was the exposed case.

Still open upstream: ucode itself should expose the bytecode version (a
`PROVIDES`, or bumping `PKG_ABI_VERSION` when `UCODE_BYTECODE_VERSION` changes)
so consumers *can* express it. Until then no package can ship bytecode safely.

## FM350-GL: a DNS server as the WAN address — AT layer + CGCONTRDP (2026-08-21)

Field report (WH3000 Pro / FM350-GL, Singtel) plus an independent reproduction:
after a live `pdp_type` change the interface came up with
`ipv4 config: 165.21.83.88/32` — the carrier's DNS server installed as the WAN
address (mwan3 "no usable default route", odhcpd `ra_lifetime 0`, `sim_6` RS
failing). On the v6 side the same defect put `2400:d800::1` (a resolver) on the
WAN and, via the shim's RFC 7278 prefix extension, `2400:d800::1/64` on br-lan.

Three independent faults chained into it; all three are fixed.

- **`parse_cgcontrdp` threw away the field position** (`ncm_vendors.uc`). It
  tokenised the whole line with one `/[, \t]+/` split — collapsing the
  separators — bucketed the tokens by family and then assigned
  `[0]=addr, [1]=gateway, rest=dns` *within the bucket*. With the modem
  answering `…,"","","165.21.100.88","165.21.83.88",…` (empty
  `<local_addr and subnet_mask>` and `<gw_addr>`, both resolvers in the DNS
  slots) the first DNS became the address. The parser now splits on **commas
  first** so the 3GPP field index survives, then on whitespace (the RG650E packs
  a v4 and a v6 token into one field). Only fields 3 and 4 can yield an address;
  a token from field 5 on is a resolver and can never be promoted. Family
  bucketing stays — it is what makes the RG650E's interleaved shape work.
- **`valid_host_v6` could not have caught it.** It tests the first hextet for
  `2000::/3`/`fc00::/7`; a carrier resolver is ordinary global unicast. The
  filter was never the wrong idea, it was at the wrong layer — the defect is one
  step earlier, in the parse. It stays as the backstop it was written to be.
- **GTDNS was family-blind.** `dns_from_gt` returned one flat list that the
  caller assigned wholesale to `ipv4.dns` — live on the sponsor router two IPv6
  resolvers sat in the v4 bucket. It now returns `{v4, v6}` and each bucket gets
  its own family, falling back to the CGCONTRDP DNS slots of the *same* family.
  `+GTDNS` (manual 12.2.17) is the documented, NAMED resolver query; `+CGPADDR`
  (12.2.5) the documented address source. The vendor path leans on both instead
  of mining CGCONTRDP for either.
- **CGPADDR's v6 slot is an interface identifier, not an address.** The FM350
  answers `0:0:0:0:4682:5956:c6d6:e2c5` — 3GPP assigns the IID, the /64 arrives
  by RA. It is no longer taken as a host address (it only ever survived because
  `valid_host_v6` happened to reject a zeroed prefix).
- Regression-tested with the **verbatim live capture** (`s9w`), plus the two
  parse-level shapes on both families.

### The AT layer lost every URC that arrived inside a command window

The trigger for the above was a vendor degradation: `AT+CGMI` returned only a
`+CGEV: ME PDN DEACT 1` (the T700 drops the answer while a PDN teardown runs),
so the manufacturer came back null, `vendor_for(null)` returned `generic`, and
the Fibocom `ip_config` — the compensation for the broken parse — was gone for
the whole session. Silently: the recipe in use was never logged.

- **One buffer, never discarded** (`atcmd.uc`). `buffer` (in-command) and
  `urc_buffer` (idle) were separate and never reconciled, and `next()` wiped the
  former at every command start. A line straddling a command boundary was torn
  in half: its head dropped, its tail pushed into the *next* command's lines as
  if it were an answer — enough for a bare-value command like `AT+CGMI` to take
  a headless fragment as the manufacturer.
- **URCs are classified per line, during commands too.** They were pushed into
  `cur.lines` and never reached `on_urc` at all: in a 245-line field log 5 of 17
  URCs were lost, including all three `+CGEV: ME PDN ACT/DEACT` events the NCM
  state machine has a handler for. A URC is framed exactly like a result code
  (manual 2.4.3: `<CR><LF>…<CR><LF>`), so it always arrives whole — but it lands
  *between* the lines of a multi-line response, hence per-line. The running
  command's own prefix always wins, so `AT+CEREG?`'s answer stays an answer.
  Prefix-less codes (`RING`, `NO CARRIER`, …) are matched as whole lines so they
  cannot be mistaken for a bare-value answer. The prefix set now lives once, in
  the AT layer — it used to exist twice, in two different spellings.
- **Identify retries an empty answer once**, and **`vendor_for` falls back to the
  model**: `AT+CGMM` answered `FM350-GL` correctly in the very same chain.
- **The resolved recipe is logged**, and a `generic` fallback despite a known
  model warns. The degradation was previously invisible.

There is no second channel to move the events to: `+GTUSBMODE` 40/41 both expose
exactly one AT interface, `+GTDIPCMODE <md_at_interface>` only moves it between
USB and PCIe, and the manual contains no MBIM/QMI at all. `+CGEREP`/`+CGEV` are
not documented either — so the URCs stay an accelerator and the state polls
(`+CGACT?`, `+CEREG?`) stay the truth.

**Not HW-verified yet** — the FM350 box was unreachable for the whole
implementation window. Host suite: 47/47, 2711 checks.

## Band selection: two Quectel firmware quirks in the NAS set path (2026-08-21)

Field report from 242 (Zyxel NR7101, Quectel RG502Q-EA, `…R13A04M4G_ZYXEL`):
unchecking a single LTE band in the LuCI modem tools failed with a bare
"Failed: qmi". Root-caused over ubus on the live modem. **Reproduced identically
on 245** (MikroTik Chateau, Quectel RG650E-EU `…R01A04G8G`) — same error codes,
same TLV combinations — so this is Quectel line behaviour, not one model or one
vendor build. All fixes HW-verified on BOTH boxes (band 8 off/on, NR band off/on,
neither connection dropped).

- **Never send both LTE band TLVs** (`netsel_ops.uc`). The `lte_bands` list was
  converted into BOTH the legacy `lte_band_preference` (0x15, u64) and
  `ext_lte_band` (0x24, 4×u64) and both went out in one
  SET_SYSTEM_SELECTION_PREFERENCE. The RG502Q answers that pair with
  **INVALID_ARGUMENT (48)**; either TLV alone is accepted and the firmware
  mirrors it into the other. The request now carries exactly one: the extended
  TLV (the only one that can express bands > 64), falling back to the legacy one
  only on a modem whose GET reports no extended mask. Both masks are still
  filled before the idempotency guard so it can compare against whichever the
  modem reports.
- **An NR5G band TLV needs a mode preference beside it** (same file). 0x2F/0x30
  alone → **MISSING_ARGUMENT (17)** on the RG502Q; with `mode_preference` (0x11)
  in the same request they apply. Since the idempotency guard strips an
  unchanged `mode_preference`, every NR-only band edit from LuCI failed. The
  current value is now re-added when an NR band TLV survives the guard — it is
  what the modem already runs, so it stays out of the `applied` list.
- **LuCI surfaced no detail** (`luci-app-wwand` settings.js): a failing
  `modem_set_settings` printed only `error` ("qmi") and dropped `detail`.
  `describeError()` now appends result/code, which is the difference between
  "it does not work" and a diagnosable answer.
- Schemas were NOT at fault — 0x15/0x24/0x2F/0x30 re-verified against
  libqmi 1.38.0 `qmi-service-nas.json` (ids and field formats all correct).
  Firmware behaviour, so no `modem_quirks.uc` entry: sending one band TLV and
  pairing NR bands with a mode preference is correct on every modem.
- **One-shot retry to the other LTE band TLV** (same file). Which of the two a
  firmware accepts cannot be probed up front — the pick above reads the GET
  response, which is a good signal but not a guarantee. A rejected band request
  is therefore retried once with the other TLV before the error reaches the
  caller; a second failure is the caller's error, no further retry.
- **LuCI dropped the mode bits it does not render** (settings.js). `MODE_BITS`
  covers GSM/UMTS/LTE/NR5G, and `collect()` rebuilt `mode_preference` from the
  checkboxes alone — so every save silently cleared CDMA (0x01), HDR/EVDO (0x02)
  and TD-SCDMA (0x20). Caught on the RG650E, where a LuCI save turned 0x7F into
  0x5C. The mask now starts from the unrendered bits of the reported value.
- Regression-tested in `test_netsel` (extended-mask modem → ext TLV only, legacy
  TLV absent; NR band → mode preference carried, not reported applied; rejected
  TLV → retried with the other one; second rejection → error surfaces with its
  qmi code) and `test_daemon` (legacy-only modem → legacy TLV only).

## Audit follow-up: eSIM quiet refcount, slot-switch watchdog (2026-08-21)

Post-merge audit of the FM350-GL round; two concurrency/liveness gaps closed
(both regression-tested — the new checks fail on the pre-fix sources).

- **eSIM quiet mode is a refcount, not a flag** (`esim_bridge.uc`). The daemon's
  bring-up eSIM refresh and a user op share `modem._esim_op`; as a bool the
  first completion re-opened the AT queue while the other op was still running,
  so a long APDU run could be starved behind URC poll bursts after all. Each op
  now holds a `quiet_claim` released exactly once (double-release guarded), and
  the ops that outlive their ack (in-modem AT download, lpac download,
  notif-process) raise their long-lived claim BEFORE the ack, so the count never
  dips to zero in between. Readers still only test truthiness.
- **Slot-switch re-enumeration watchdog** (`modem_ncm.uc`). `step_simslot` ends
  the switch with a CFUN reset and stops the modem for the re-enumeration the
  hotplug 'add' restarts it from — a firmware that keeps the USB device across
  the reset fires no hotplug at all and the modem sat ABSENT forever. A
  `timing.reenum` (60 s) watchdog now resumes the bring-up in place; `start()`
  is state-guarded, so a modem the hotplug already restarted is untouched.
- **One switch attempt per modem object** (same path): the reset re-runs the
  whole chain, so a firmware that accepts `GTDUALSIM=` without ever making the
  slot active would reset in a loop (true before the watchdog too, via the
  hotplug restart). The second pass only reads the slot status and reports where
  we ended up. An `unchanged` short-circuit does not count as the attempt.
- Left as-is by decision: the `nudge_rs` disable_ipv6 window vs a static v6 on
  RNDIS (RA-only on the T700), and `ensure_wan6` rewriting a same-named
  non-dhcpv6 user section.

## FM350-GL field round: RNDIS v6 subif, EN-DC merge, netdev counters (2026-08-20)

- **RNDIS v6 subinterface** (Huasifei WH3000 Pro / FM350-GL): a persisted
  static section `<parent>_6` (proto dhcpv6, `device @<parent>`, `auto 1`,
  the parent's firewall zone as `option zone` — LuCI-visible; fw4 joins it
  via netifd's zone attribute), never deleted, instantiated immediately via
  `add_dynamic` (no config reload); a user section wins via the status
  probe.
- **NCM byte counters from the netdev** (parity with QMI/MBIM): the stats
  sampler reads the datapath netdev statistics as primary/fallback (no
  vendor stats AT on fibocom) — status page, wwandctl, zero-rx watchdog;
  the datapath method surfaces parent counters on NCM too.
- **GTCAINFO + GTCCINFO merge** (fibocom telemetry): GTCCINFO enriches the
  NR serving cell (rsrq/sinr/bw → 5G status SNR, CA table). NR scales:
  rsrp v/2−121 + sinr v/2 (cross-validated vs simultaneous GTCAINFO
  reads), rsrq (v−87)/2 + bw v/5 (3ginfo-lite's field-derived 0e8d7127
  FM350 script). Rows pair on pci+band — a mismatch (handover between the
  two reads) drops the stale row whole, identity included.
- Temperature via `AT+ETHERMAL?` (the FM350 rejects the NL952 `AT+MTSM=1`).
- An addr-less (DNS-only) ipv6 bucket is flagged `ipv6.unmanaged` — status
  renders "unmanaged (RA/SLAAC)" instead of null/0; the fibocom signal
  block refreshes from the serving cells every tick (it used to freeze on
  the first fill).
- **Audit fixes** (code-review round): the shim pushes v6 DNS on EVERY
  connection shape again (the DNS-only branch had replaced the dual-stack
  push); the zone lookup splits the classic space-separated
  `option network 'wan wan6'` spelling; the literal `::` address is never
  pushed; the RS nudge is gated to rndis_host (cdc_ncm/cdc_ether keep
  their static v6); the CPUK redact branch actually masks; fibocom wins
  the vendor match over mediatek; `wwandctl status` reads `has_power`;
  `_reattaching` arms before the COPS bounce; the esim_ready refresh
  latch clears on failure; GTCCINFO `hxid` nulls only the long all-F
  placeholders (TAC 0xFF / ECI 0xFFFFFF stay real).

## Bytecode precompile, namespaced imports, io merge, radio_ifs rat fallback (2026-08-16)

- **Production builds ship ucode as precompiled bytecode**, built by the new
  **repo-root `CMakeLists.txt`** in the same cmake run as `wwand_io.so` — one
  independent compiler invocation per file (like C translation units: parallel,
  incremental), driven by **explicit source lists** (`WWAND_UCODE_MODULES` /
  `_PROGRAMS` / `_PLAIN`; no glob as build input — a configure-time check fails
  on any drift between the lists and the tree). The trick that removes all
  ordering: every intra-tree module name is passed as `dynlink=`, so imports are
  never resolved at compile time; the VM resolves them at runtime via the
  search path. A typo'd import stays a hard compile error (only listed names are
  dynlink). Modules compile `-cmodule`, `main.uc`/`wwandctl.uc` `-c` (interp
  line survives → procd-exec'able), the require()-CommonJS shims are copied as
  source. `-s` (strip debug) is mandatory: unstripped bytecode embeds the
  absolute build path and is not relocatable. Configure-time guards reject
  relative imports, hyphens in module paths and unlisted files. Feed Makefile:
  `-DUCODE_COMPILER=$(STAGING_DIR_HOSTPKG)/bin/ucode` (`PKG_BUILD_DEPENDS:=
  ucode/host` — same revision as the target VM, bytecode is VM-locked);
  dev opt-out `CONFIG_WWAND_UCODE_SOURCE` / `-DUCODE_PRECOMPILE=OFF` ships
  plain source (source-line tracebacks, on-device editing). Host-validated:
  full parallel build in ~0.3 s, single-file incremental rebuild, whole daemon
  graph loads relocated, `require()` shims over bytecode work. (An interim
  standalone-script variant was replaced by this cmake integration.)
  **HW-validated on the whole fleet** (on-device compile with each router's own
  ucode = exact VM match; A/B fresh-restart + 35 s settle): daemon RSS drops
  **~31–33 %** — 245 (aarch64, 2 modems) 6328→4332 kB, 93 (aarch64) 6140→4096,
  242 (mipsel) 4944→3416, 246 (mipsel) 5072→3496. All modems READY/CONNECTED
  on bytecode, telemetry incl. band/bandwidth pipeline intact, wwandctl works.
  Rollback: `/usr/share/ucode/wwand.bak` (source) left on each router.
- **Import style migrated tree-wide: namespaced only.** All 160 relative
  imports (`'./codec/tlv.uc'`) became search-path names (`'wwand.codec.tlv'`) —
  the ucode VM resolves bytecode modules ONLY via the search path. The
  precompiler hard-fails on relative imports, on hyphens in module paths
  (`codec/mbim-schema/` → renamed **`codec/mbim_schema/`**) and on intra-tree
  specifiers that do not resolve to a file (caught two real migration slips:
  `wwand.loc`/`wwand.wms` in the lazy schema shims needed the full
  `wwand.codec.schema.*` path, and `../mbim.uc` in ms_basic_connect_ext).
  Full suite green after migration.
- **`ucode-mod-wwand-io` package merged into `wwand`.** The native `wwand_io.so`
  is wwand-private and version-locked to the ucode side; shipping it in the base
  package removes the stale-.so/arch-mismatch deploy hazard. `PROVIDES:=
  ucode-mod-wwand-io` keeps old configs resolving; feed CI/imagebuilder/README
  references updated.
- **`rat` status fallback from NAS `radio_ifs`** (`modem_common.
  rat_from_radio_ifs`, highest-tech-wins): a registered modem without a DSD
  service and without QNWINFO (Huawei E392 on 245) showed `rat: null` while its
  telemetry line said `tech=LTE` — `probe_iot_rat` now falls back to the coarse
  radio_ifs RAT when `dsd_status` is absent. Found while raw-dumping the E392's
  `GET_CELL_LOCATION_INFO` to rule out a decode dialect (bytes decode cleanly;
  the "duplicate serving cell" across both 245 modems is physical reality —
  both camp on the same B20 site). HW-validated on 245. +9 checks.

**Deploy note:** the fleet still runs the pre-split source deploys; the first
apk upgrade to a bytecode build replaces the whole `/usr/share/ucode/wwand`
tree. `wwand.x` forum draft untouched.

## MBIM 5G caps, passthrough parity, coexistence + uptime fixes (2026-08-16)

A cluster of correctness fixes, several from forum HW reports:

- **MBIM caps read 5G from the CUSTOM `custom_data_class` string.** The Quectel
  RM520N-GL (93) leaves the 5G bits unset in the base `DEVICE_CAPS.data_class`
  (`0x8000003C` = CUSTOM|UMTS|HSxPA|LTE) and describes the extra classes in the
  free-text `custom_data_class` ("5G/TDS"). `rat.families_from_mbim(dataclass,
  custom)` now parses that string **only when the CUSTOM bit is set** (no phantom
  5G on an empty/absent string), so `caps.rats` reports `nr5g`. HW-validated on 93;
  test_rat golden + negatives. See [[qmi-over-mbim-passthrough]].
- **QMI-over-MBIM passthrough is REQUEST/RESPONSE ONLY.** HW-probed on EG06 (246)
  and RM520N (93): both accept NAS `REGISTER_INDICATIONS` over the passthrough
  (`err=null`) but never push a single unsolicited QMI message back as MBIM
  `INDICATE_STATUS` — so MBIM telemetry stays poll-based (`watch_driver`); you
  cannot subscribe over the passthrough. `qmi_over_mbim.deliver` still fans a
  `0xff` broadcast indication out to every same-service client (parity with the
  native `transport.uc` hub — it was silently dropping them); test_passthrough
  +5 checks. Kept correct for any firmware that would forward them; none on the
  fleet does. **Do not re-run that probe.**
- **Autosetup device-ownership coexistence.** The zero-config occupancy gate
  (`main.uc autosetup_create`) treated the box as configured only for an existing
  `wwand_modem`, a `proto wwand`/`qmi` interface, or a `wwan0` section — a stock
  umbim (`proto mbim`) / comgt-ncm (`proto ncm`) interface under another name
  slipped through, so autosetup could auto-grab a cdc-wdm the stock stack already
  owns and open a second session. Now `proto mbim`/`ncm` count as occupied too —
  the good-citizen device-ownership contract (raised in the openwrt/packages
  review, #30185).
- **Uptime uses a monotonic clock.** A context's connected uptime was
  `time() - connected_since`, both wall-clock. On an RTC-less PCIe/MHI board the
  modem connects at boot **before** NTP sets the clock, so the NTP step then made
  uptime jump by the offset (forum tester LS3434 saw a constant ~18 h on a
  Foxconn/Dell T99W175). New `context_common.mono()` (CLOCK_MONOTONIC via
  `clock(true)`) is used for both capture and read across all three backends;
  test_context covers it. (Same thread: 5G band info reaches LuCI natively — the
  NR band is derived client-side from `nr5g_arfcn`, which both the passthrough
  `GET_CELL_LOCATION_INFO` and native MBIM `BASE_STATIONS_INFO` populate.)

## Never block the uloop: async netifd calls + native recv/waitpid timeouts (2026-08-14)

Symptom (HW, Cudy during an operator scan): `ubus call wwand status` hangs
while wwand is busy. Root cause: the single uloop was blocked in a synchronous
syscall, so the daemon couldn't answer its own ubus. Fixes (no fork/thread —
the design is single-loop non-blocking):
- **netifd calls** used ucode's synchronous `conn.call()`, which blocks the
  loop until netifd replies (up to its 30s timeout); during a scan the flapping
  registration fires renew/down/kick and each froze the daemon. Switched to
  `conn.defer(obj, method, data, cb)` (uloop-integrated async): up/renew/down/
  reload are fire-and-forget (cb logs a non-zero status); `iface_status`
  (adopt-vs-kick in modem_ready) is now `(iface, cb)` and the decision runs in
  the callback. The runtime keeps the deferred alive until completion, so the
  handle need not be retained.
- **wwand-io.c**: `nl_recv` sets `SO_RCVTIMEO` (2s) so a wedged rmnet/driver
  datapath op can't block forever; `qmit_close` reaps the spawn child with
  `WNOHANG` only (a lingering lpac no longer blocks close() — uloop's SIGCHLD
  reaper collects it, the __EXIT marker carries the real status).
Optional follow-up: a procd/cron watchdog for pathological kernel-ioctl hangs.

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
  config_warning (no slot transport on AT-only) — superseded 2026-08-19: NCM
  now has the vendor `slots` recipe (Fibocom GTDUALSIM, see the FM350-GL
  section).
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
  composition codes are many-to-one per chipset). `GTACT`/`GTCELLLOCK`
  band/cell lock remain **deferred** pending Fibocom HW; the `GTCCINFO`/
  `GTCAINFO` cell telemetry landed HW-checked 2026-08-19 (see the FM350-GL
  section).

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
- **Fibocom auth = `+MGAUTH`** (FM150/FM350 reject `+CGAUTH`) — superseded
  2026-08-19 by the error-tolerant MGAUTH→CGAUTH chain (see the FM350-GL
  section).
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

Tried converting 242 (NR7101, public WAN IP + v6 GUA,
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
firmware); the Huawei NCM telemetry recipe needs bench verification (MeiG is
HW-verified on the SLM770A).

## Fibocom FM350-GL support (2026-08-19)

Support pass for the Fibocom **FM350-GL** (MediaTek T700, M.2; USB offers RNDIS
compositions only — `AT+GTUSBMODE` 40/41 → 0e8d:7126/7127; no MBIM/QMI).
Built from public captures + kernel docs, then **field-validated on a
WH3000 Pro (2026-08-19)** — the field facts are in the "First field run"
bullet below:

- **AT-port discovery** (`atcmd.uc` LOCAL_PORTS): 0e8d:7126 iface 4 / 0e8d:7127
  iface 6 pinned as `at` (OpenWrt-forum dumps + the ModemManager udev rules for
  this module). No aux port in either composition. Deliberately NOT in
  `SERIAL_NEW_ID` — the kernel option driver knows the module since 4.19.318,
  and a blanket `new_id` grabs ADB → crash-loop (forum-observed).
- **Discovery data path**: no change needed — `rndis_host` is already in
  `NCM_DRIVERS`; the forum's working recipe (CGDCONT+CGACT) is exactly the
  NCM backend's GTRNDIS-probe → CGACT fallback (the T700 lacks GTRNDIS).
- **Auth chain** (`ncm_vendors.uc`): new `auth_cmds` list support; the fibocom
  recipe now offers **+MGAUTH → +CGAUTH** in the error-tolerant setup sequence
  (MGAUTH = the Qualcomm FM150/FM350 form; the T700 form is undocumented, so
  both candidates run and the firmware takes the one it knows).
- **Telemetry** (`telemetry_ncm.uc`): new `FIBOCOM` block + `parse_gtcainfo`
  (serving LTE/NR + SCC aggregation from `AT+GTCAINFO?`) + `parse_gtccinfo`
  (the serving row). Field offsets cross-checked between real FM190 captures
  (GTCAINFO vs the GTCCINFO hex row) and the 3ginfo-lite parser, then
  **HW-checked live** on the field run — no `unverified` mark. rsrq/sinr stay
  null only on the GTCAINFO-only path (the GTCCINFO enrichment parses LTE
  rsrq/sinr). Anchored by `tests/test_ncm_fibocom.uc` (verbatim captures).
- **Board profile** (`board.uc`): **Huasifei WH3000 Pro** (MT7981B Filogic 820,
  official OpenWrt `huasifei,wh3000-pro-{emmc,nand}`; the FM350-GL's typical
  host — M.2 slot wired to USB). The DTS exports the modem power enable as the
  named gpio `modem_power` (pio 4) — field-verified INVERTED (1 = off, 0 =
  on; `power_gpio_active_low`), so `init()` only drives the line when it
  reads "off" and the recovery ladder + `modem_repower` power-cycle with the
  inverted levels. No modem RESET line, no dedicated modem LEDs (the board's
  two LEDs are the OS status pair) -> nothing else; the FM350-GL serials stay
  OUT of `option_ids` (kernel-bound since 4.19.318; blanket new_id grabs ADB
  -> crash-loop). Board PWM fan is OS-owned, not wwand's.
- **Docs**: `interface-landscape.md` Fibocom section corrected — the FM350-GL
  is MediaTek T700, not Qualcomm; RNDIS-only + kernel/AT-port facts recorded.

- **First field run (WH3000 Pro, FM350-GL)** — static-IP path
  HW-validated end-to-end: CGPADDR address + /30 peer (two sessions: .77/.78,
  .69/.70 — peer rule holds), DNS from the CGCONTRDP tail, **no DHCP at all**
  (the T700 serves none); netifd applies /32 + host route + via-route (shim
  fix), defaults untouched (pre-existing default/VPN routes and metrics),
  mwan3 sim = metric-3 last resort, ping through sim 0% loss. The cid-1
  idempotency guard skipped a context write on reconnect — field-proven.
  Device-side lessons: OpenWrt's ucode parser needs `};` on module-level
  export functions (host parser lenient), `basename` is NOT a ucode global,
  netifd registers proto handlers only at start (first deploy needs a
  network restart/reboot), and `auto 0` keeps the interface dormant until an
  explicit ifup by design. Open: GTCAINFO command form (tech=none until
  probed), reg display while connected.
- **IPv6-only/464XLAT — field-analyzed, 3GPP-correct model applied.** On the
  v6-only PDP the raw CGCONTRDP line is empty-local (no host address) with
  the gw + dns1 slots carrying two 16-octet tokens decoding to the
  provider's **DNS64 pair** (a /32 ending `:53:10` / `:53:22`) — never an
  address; CGPADDR carries the embedded `<0×8, 0,1, 0,0><v4>` CLAT artifact
  (13/14.x pool (anonymized) — the modem-internal CLAT's address, field-
  pinged 3/3, but **deliberately NOT assigned**: an ipv6-only PDP carries no
  host v4, verified against atc.sh's logic + patrakov's review — host v4 on
  such networks comes from the separate **464xlat package** (jool, wan_4)).
  The real host v6 comes from the **modem's internal RA/SLAAC** (global /64
  with the modem's MAC-derived IID, default route via fe80::5) — it appears
  once the netdev accepts RAs, which the NCM datapath enables (disable_ipv6=0,
  accept_ra=2) and the context re-solicits after every connect (disable_ipv6
  toggle — a PDP re-establishment can leave the modem's v6 forwarding stale
  until a fresh RS). DNS chain: `AT+GTDNS=<cid>` (the T700's canonical
  resolver query) wins when it answers; when GTDNS is unsupported, an
  ipv4-only PDP falls back to the CGCONTRDP v4 DNS, any other PDP to the
  DNS64 pair read off the CGCONTRDP v6 fields (null when the line carries
  none). Egress check (ifconfig.me): v6 egresses as the SLAAC address
  unchanged (no rewrite); the v4 egress is CGNAT-rewritten by the provider.
  Addresses anonymized.
- **URC infrastructure (field-verified on the mode-40 AT port).** The AT
  engine surfaces idle `+CODE` lines via `on_urc` (including lines buffered
  behind the previous command's OK); the fibocom recipe enables the
  registration/network URCs (`CREG=3`-style + `CTZR=1`). Wired: register
  fast-path (URC-triggered re-poll, polling stays the fallback), `+CGEV` PDN
  DEACT/ACT context pokes (liveness/settings — hints, the probe's result
  decides), `+CTZV` NITZ into the shared clock path (`nitz_ctzv` →
  `set_clock`, QMI parity), and the `GTFCCEFFSTATUS?` FCC-lock probe
  (`fcc_lock` in status, mode 0 = unlocked). The field provider pushes no
  NITZ regularly — the CTZV branch awaits a real event. Auth commands are
  redacted in the AT logs.
- **eSIM field finding (FM350-GL):** the module is dual-SIM — SUB1 = the
  physical SIM, SUB2 = the built-in eUICC slot; `AT+GTDUALSIM=<0|1>` switches
  (SIMTYPE? 1 = eSIM). New NCM slot surface (vendor `slots` recipe +
  modem_ncm slot_status/switch_slot, sim.uc dispatch) makes both slots
  visible and switchable from wwandctl/LuCI — field-validated: switch to
  SUB2 reports "NO SERVICE" (no ENABLED profile in the eUICC), switch
  back re-enumerates the modem (CFUN reset) and the connection restores.
  **Host-side APDU WORKS when the eSIM slot is ACTIVE** (field-validated):
  the T700 answers CCHO with a BARE session id (parse fixed), the ISD-R
  opens in a window after the slot switch before the internal LPA
  re-claims it, and the eSIM ops re-probe per call (`backend.forget`) —
  `eid` and `profiles` run end-to-end over CCHO/CGLA/CCHC (ES10c, SW
  9000). The eUICC carries one DISABLED test profile (factory
  conformance-testing) — hence the EMPTY_EUICC CPIN state; enable/
  disable/delete share the proven channel, download untested.

**Deferred (needs HW):** `protocol_switch.uc`'s GTUSBMODE recipe still carries
Qualcomm composition codes — the T700 set differs; NR rsrq/sinr offsets (LTE
is HW-checked via GTCCINFO). `wwand-mhi` does not cover the FM350-GL's MT7xx
PCIe path.

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
