# How a connection comes up

This document walks one cellular connection from power-on to passing traffic,
three times: as **wwand** sees it (daemon state machines, file/function
anchors), as the **modem** sees it (firmware state), and as the **network**
sees it (3GPP procedures). Read it next to `docs/architecture.md` (layering)
and `docs/reference.md` (configuration & ubus API). If you want to change or
extend a step, each phase links the place to hook in; the how-to patterns live
in `docs/extending.md`.

The same flow applies to all three control backends — QMI (`modem.uc`), MBIM
(`modem_mbim.uc`), NCM/AT (`modem_ncm.uc`) — behind one daemon-neutral
contract (`docs/backend-interface.md`). Where a step is backend-specific it is
called out.

## The three timelines, side by side

| Phase | wwand (daemon) | Modem (firmware) | Network (3GPP) |
|---|---|---|---|
| 1. Discovery | hotplug/scan finds control device, binds modem section | USB/PCIe enumeration, exposes cdc-wdm/tty/netdev | — |
| 2. Transport | open control channel, allocate service clients | QMI CTL / MBIM OPEN handshake | — |
| 3. Identify | read model/IMEI, apply quirks, identity gate | answers DMS/ATI queries | — |
| 4. Datapath | negotiate QMAP/mux, rename netdev to `wwandN` | configures aggregation | — |
| 5. RF online | set operating mode online (+ FCC unlock if locked) | leaves low-power, radio on | cell search/measurement |
| 6. SIM | read ICCID pre-PIN, match `wwand_sim`, enter PIN | SIM/USIM session, PIN verify | — |
| 7. Attach profile | write initial-attach APN (before attach) | stores attach EPS profile | — |
| 8. Register | request registration, watch serving system | RRC connection, NAS Attach/Registration | MME/AMF auth, HSS/UDM subscriber check |
| 9. Activate PDP | START_NETWORK / CONNECT / CGACT per family | PDN connectivity request | SMF/PGW allocates IP, GTP bearer |
| 10. Configure | read settings (IP/DNS/MTU), push to netifd | — | — |
| 11. Monitor | telemetry, stats, zero-rx watchdog, recovery ladder | signal/serving indications | handover, reject causes |

## 1. wwand's view (the daemon)

Everything below runs inside one `uloop` process (`main.uc` → `daemon.uc`).
State names are what `ubus call wwand status` shows.

### Discovery and binding

`discovery.uc` (+ the usbmisc/net hotplug scripts in `files/`) resolves each
configured `wwand_modem` to a control interface: a `/dev/cdc-wdmN` (QMI/MBIM),
or a netdev + AT tty (NCM/ECM). Binding anchors, in order of preference:
`option path` (sysfs topology, like wireless — survives re-enumeration and is
PCIe-ready), `serial` (USB iSerial), `device` literal. A modem whose control
device is absent **waits** (`control_note` = "waiting for modem", re-checked
every 30 s by the daemon tick) — boot order never fails a modem permanently.
Zero-config boxes get `wwmodem_auto` + `interface wwan0` created by autosetup
(`daemon.autosetup_scan` / hotplug, uci writers in `main.uc`).

### Bring-up chain (per modem)

`daemon.uc start_modem` builds the backend object; the per-backend init chain
drives states `INIT_TRANSPORT → INIT_SERVICES → INIT_DATAPATH → SET_OPMODE →
SIM_UNLOCK → CONFIGURE_NET → REGISTERING → READY`:

- **QMI** (`modem.uc` + `modem_init_qmi.uc`): CTL sync, service version probe,
  client allocation (DMS/NAS/UIM/WDS/WDA/DSD), AT side channel
  (`modem_common.open_at`), datapath negotiation (`datapath_qmi.uc`:
  QMAP/rmnet vs qmimux vs none, `SET_DATA_FORMAT`), operating mode online
  with the **FCC unlock chain** for RF-locked laptop modems
  (`GET_OPERATING_MODE` verify → `qmi_backend.fcc_auth`), SIM slot assert,
  SIM/PIN machine (`sim.uc`), identity read (IMSI/ICCID/MSISDN with per-field
  QMI→AT fallbacks), config validation (`config_check.uc`), **LTE attach
  profile** write (APN into the attach EPS profile *before* attach — some
  networks reject an IPv4-only or wrong-APN initial attach), then
  registration.
- **MBIM** (`modem_mbim.uc`): MBIM OPEN → optional Quectel FCC unlock →
  DEVICE_CAPS / SUBSCRIBER_READY (no SIM ⇒ terminal `SIM_BLOCKED`/
  `sim_absent`, not a retry loop) → PIN → REGISTER_STATE → ATTACH. Rich
  telemetry and NAS-grade features ride the **QMI-over-MBIM passthrough**
  (`qmi_over_mbim.uc` — never CTL SYNC over it).
- **NCM/AT** (`modem_ncm.uc`): AT identify (ATI/CGSN/CIMI/CCID), CPIN,
  CGDCONT write, CGATT/COPS registration polling (CEREG/C5GREG URCs),
  vendor telemetry tables (`telemetry_ncm.uc`).

The **stable L3 name** is applied in phase 4/discovery: non-mux datapaths get
their kernel netdev renamed to the assigned `wwandN` (`daemon.uc rename_l3`);
QMAP mux children are created under their `wwandN` name directly
(`netlink.uc`). See "Stable L3 names" in `reference.md`.

### Context activation (the actual "dial")

Contexts (`context.uc` QMI / `context_mbim.uc` / `context_ncm.uc`) are owned
by the daemon, one per `interface … proto wwand` section. On modem
`registered`, the daemon activates every `auto` context
(`daemon.uc _up_result` / `activate`): per address family it sets the IP
family, sends START_NETWORK (QMI, 120 s timeout) / CONNECT (MBIM) / CGACT
(NCM), then reads the negotiated settings (IP, gateway, DNS, MTU) and hands
them to **netifd** over ubus (`context_up` reply / `proto_send_update` in the
shim `files/wwand-proto.sh`). wwand touches only the link layer — addresses,
routes, VRF membership are netifd's job (see the VRF invariant in
`architecture.md`).

APN/credential resolution precedence: active `wwand_sim` (per-ICCID/IMSI
override) → interface section → card-provisioned attach APN (read from the
modem when the config leaves it empty) — `context_common.conn_cfg`.

### Steady state and failure

- Telemetry: slow loop each `stats_interval` (signal/serving/cells/CA log
  line, `telemetry_qmi.uc` / `telemetry_mbim.uc` / `telemetry_ncm.uc`), fast
  1 s watch loop while LuCI polls (`modem_common.watch_driver`).
- A **transient loss** keeps the netifd interface up (`hold_max`, default
  90 s) and reconnects the session in place (renew — IPv6-PD and VRF
  bindings survive). Permanent losses (`sim_blocked`, admin down) drop the
  interface immediately.
- The **zero-rx watchdog** (`context_common.rx_stall_watch`) and the
  **recovery ladder** (`recovery.uc`: opmode-cycle @8 failed attempts, modem
  reset @16, board power-cycle/reset-GPIO @24, reboot at `failreboot`)
  handle everything else. A vanished control device detaches the modem into
  the waiting state; presence is re-checked by the tick, so recovery does
  not depend on a hotplug event (HW-proven with a provider-side SIM reset).
- wwand restarts are non-destructive: the WAN stays up and the new daemon
  **adopts** the live session on `registered`.

To watch these states happen in the UI — live signal/cells, the registration
line, per-modem status — see the LuCI tour in [luci.md](luci.md).

## 2. The modem's view

What the firmware goes through, and which wwand step drives it:

1. **Enumeration** — USB descriptors expose the control endpoint (cdc-wdm for
   QMI/MBIM, ACM/serial for AT) and the network function (qmi_wwan / cdc_mbim
   / cdc_ncm / cdc_ether). Some modems boot into the wrong mode; wwand can
   switch (`protocol_switch.uc`, `AT+QCFG="usbnet"`-class) and waits for the
   re-enumeration.
2. **Control session** — QMI: client IDs per service from CTL; MBIM: OPEN
   handshake. The firmware keeps per-client state; wwand releases and
   re-allocates on every bring-up.
3. **Radio state** — most modems boot `online`; laptop SKUs boot
   **FCC-locked** in (persistent) low power and need the unlock message
   (`option fcc_auth`, see reference.md) before the RF ever transmits.
4. **SIM session** — the USIM application starts, PIN gates it; the modem
   caches IMSI/ICCID. An eSIM profile switch or provider-side (GDSP) reset
   restarts this stack — wwand hot-resets the SIM (UIM power-cycle) and
   re-reads identity (`reapply_sim`) instead of rebooting.
5. **Attach profile** — the initial-attach EPS bearer uses a stored profile
   (CID 1 on Quectel); wwand writes APN/PDP type there *before* attach.
6. **Registration** — the baseband scans (stored frequency lists first),
   camps, runs the NAS attach. Serving-system/register-state indications
   stream back; wwand mirrors them into `status.registration`.
7. **PDP context** — one per address family/APN; the firmware returns the
   negotiated IP configuration wwand then reads.
8. **Data** — frames flow over the net function, QMAP-aggregated when
   negotiated. Firmware-side stalls show up as the zero-rx pattern wwand
   watches for.

## 3. The network's view

The 3GPP side, mapped to what you see in wwand's logs:

1. **Cell selection** — the UE measures and camps; no core-network state yet.
   Log: `rf band change`, serving-cell telemetry.
2. **RRC connection + NAS Attach / 5G Registration** — the UE authenticates
   (SIM AKA against HSS/UDM). Rejections surface as **EMM/5GMM causes**
   (`registration rejected: …`, decoded in `regdetail.uc` via QMI system
   info + AT+CEER): e.g. cause #33 "requested service option not subscribed"
   for a wrong/missing attach APN (the reason wwand writes the attach
   profile early), roaming barred, or "no cause" right after a provider-side
   subscriber purge (GDSP SIM reset — re-attach succeeds once provisioning
   settles).
3. **PDN/PDU session setup** — the SMF/PGW validates the APN against the
   subscription, allocates the address(es) and DNS. Failures come back as
   **SM causes** (`callend.uc` decodes both the 3GPP SM table and the
   modem-internal reasons — e.g. internal 204 "unknown cause code").
   Dual-stack (`pdp_type ipv4v6`) is one bearer with both families where the
   network allows it; wwand activates the families it was granted.
4. **Steady state** — handovers and cell reselections are invisible except
   for serving-cell telemetry changes; bearer loss or network-initiated
   deactivation arrives as a WDS/MBIM indication and starts wwand's
   reconnect-in-place path.
5. **IPv6** — the network assigns the /64 via RA on the bearer;
   DHCPv6-PD is generally NOT answered on mobile APNs (HW-verified for
   Vodafone/Telekom DE) — downstream delegation uses RFC 7278 /64 sharing
   (see the Dual-stack section in reference.md).

## Extending the flow

Every phase has one intended extension point (patterns + checklists in
`docs/extending.md`):

| You want to… | Hook |
|---|---|
| Support a firmware quirk (delay, deferred apply, band decode) | `modem_quirks.uc` (§1 in extending.md) |
| Add a config option end-to-end | `config.uc` defaults + parser → consumer → reference.md (§2) |
| Add a whole control backend | `docs/backend-interface.md` contract + `*_lazy.uc` shim (§3) |
| Rename the datapath netdev / assign a stable L3 name | `daemon.uc rename_l3` + `config.uc assign_l3_names` (phase 4) |
| Add a telemetry source | `telemetry_*.uc` + `backend.choose()` transport probe (§4) |
| Expose a new ubus method | `daemon.uc`/`netsel_ops.uc` + `ubus.uc` + ACL (§5) |
| Board power/reset/LED wiring | `board.uc` profile table (§7) |
| React differently to a failure | `recovery.uc` ladder / `callend.uc` cause tables |

Rules that hold across all of it: netifd owns L3 (never add routes/addresses
in wwand), QMI message layouts must match libqmi's JSON, every new decoder
gets a wire-buffer test, and `tests/run_tests.sh` stays green.
