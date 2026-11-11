# wwand — current state

_State of 2026-11-02: stable **v1.8.0** (feed release `2026.11.02`), main **v1.9.0-dev**.
65 host suites, all green (`cd tests && sh run_tests.sh` — it prints the count,
which moves too often to be worth repeating here)._

This file describes **what is true now**. The dated log of how it got here is
`status-archive.md`; beliefs that looked right and were not are in
`gotchas.md`. Keeping them apart is deliberate: a running log with the current
state buried at the top invites reading a months-old entry as present tense.

## Open threads (2026-10-29) — where the next session picks up

- **Release 1.8.0 (2026-11-01, released 2026-11-02):** main merged into
  stable in wwand and luci-app-wwand (stable's own commits were all
  cherry-picks, so the merged tree is main's), tagged `v1.8.0` there,
  `v1.9.0-dev` on main. luci-proto-wwand had nothing new and stays at
  v1.7.0; wwand-rsim got `v0.1.1`. Feed stable pins wwand 1.8.0 /
  luci-app-wwand 1.8.0 / wwand-rsim 0.1.1; its build went green and the
  release tag `2026.11.02` is pushed — the images build from it, check that
  run. Feed main: wwand `1.8.0_pre48`, luci-app-wwand `1.9.0_pre2` (Polish
  translation, `luci-i18n-wwand-pl`, #73). **Do not push to the feed while a
  build of the same branch runs** — a push cancels it.
- **`option ipa_mode 'ipad'` (2026-11-11, uncommitted):** an SGP.32 card
  with its own IPA runs it until the device sends TERMINAL CAPABILITY tag 84
  (IDEMIA DAKOTA IoT v1.2 DEV_REQ_8); the modem never does. With the option,
  `sim.uc declare_ipad` sends `A9 03 84 01 01` on the basic channel before
  every ISD-R open. It is opt-in because it switches the card's IPAe off. The
  name is not `ipa` because wwand-ipa owns that one. HW-verified on 5.202
  (IDEMIA card, RG502Q) with a card reset each time: without the option
  IPAe, with it IPAd and an ES10 EID read. LuCI: modem option
  "SGP.32 IPA", and the IPAe status line points to it. Deployed there as
  source over 1.8.0; originals in `/root/wwand-1.8.0-orig/` and
  `/root/luci-1.8.0-orig/`. AT and MBIM paths are host-tested only.
- **LED running light (2026-11-08, from #48):** the `tech` style takes
  `sweep: true` — the technology LEDs run oldest-first every 300 ms while
  the modem searches, on a timer of the board instance (`board.uc`
  `self.leds`; the status tick that plans it comes every 10 s). One LED
  blinks instead; steady over blinking over the light when entries share an
  LED. Host-tested (`test_board` section 8) and run against the real LEDs of
  the LTE3301 (5.201) from a /tmp board file: `#.. .#. ..#` at 300 ms, `..#`
  once on 4G.
- **Foxconn FCC unlock over MBIM (2026-11-09, from #75):** a T99W175 with
  Foxconn ids (`^CUSTOMER: 6`, `105b:e0ab`) is FCC-locked in MBIM mode, and
  wwand unlocked a Foxconn only on the QMI path. Now `modem_mbim.uc
  radio_off` also fires when our Radio State set is refused or leaves the
  software radio off (ModemManager's trigger, 1.24.0), and for a Foxconn
  modem sends the DMS Foxconn FCC authentication over the passthrough: v2
  with ModemManager's 105b magic, then v1 with 0 (`qmi_backend.uc
  fcc_foxconn`). Host-tested (the v2 magic against the 105b shell pipeline);
  not HW-tested — our T99W175 is not locked; mrhaav's runs locked as
  `^CUSTOMER: 6` and has been asked to test it (#75).
- **`option modes` on MBIM, natively (2026-11-08, from #75):** the MBIM
  init writes the modes as the Register State `DataClass` from MBIMEx 2.0
  on (`modem_mbim.uc sync_modes`, ModemManager's mapping, CUSTOM for the
  class a modem names that way), over the passthrough NAS on MBIM 1.0, and
  reports them otherwise; before, MBIM ignored `option modes` without a word.
  The QMI and MBIM init writes of modes / PLMN / RAT order now carry a
  permanent change duration, as the settings editor's always did. HW-read on
  a T99W175 (HP notebook, Debian + ModemManager, 2026-11-08): CUSTOM is its
  5G SA, the 5G_SA bit is dropped, the mask survives a modem reset, and no
  RAT order with NR is accepted. HW-run through wwand on the same notebook
  under OpenWrt (2026-11-08): `lte,nr5g` written as 0x80000060 and held,
  skipped on restart and after a modem reset, `umts,lte,nr5g` restored as
  0x8000007c. Open: the LuCI mode editor on an MBIM modem without a
  passthrough (FM350) still has no native path. Open: on mrhaav's
  T99W175.F0.1.0.0.9 (caps `custom` named "5G", no 5g-nsa) CUSTOM turns on
  TD-SCDMA plus NR in the NAS view, while the firmware reports the standard
  5g-nsa bit for NR on its own (#75, 2026-11-09) — so the ModemManager rule
  (CUSTOM = NSA) is wrong there; whether it accepts the standard bits in a
  set is asked.
- **A control device before its netdev (2026-11-08):** after a modem reset
  the T99W175 (mhi-pci-generic) announces `wwan0mbim0` before its netdev;
  the modem was started without one, the netdev kept its kernel name and
  the interface stayed down until a wwand restart. `start_modem` now waits
  for the netdev (`NETDEV_SETTLE`, 15 s; its hotplug add starts the modem,
  the waiting tick retries at that bound) and only then starts without one;
  a control device that leaves ends the wait. HW-verified: reset -> wait ->
  rename to `wwand0` -> connected, no restart.
- **SIM card per interface, `option iccid` (2026-11-07, from #39):** an
  ifup on a modem running another card takes one step towards it — slot
  switch or eSIM profile enable (`siminventory.uc bind_plan`) — and dials
  once the modem registered on it; refused while another interface bound to
  a different card uses the modem (first come wins, `bind_holder`); a card
  change under a bound interface takes it down (`daemon.uc sim_release`);
  manual slot switches / eSIM enable-disable answer `sim_in_use` unless
  `force`; the bring-up asserts the bound card's slot instead of `sim_slot`
  (`sim.uc boot_slot`). LuCI: "SIM card" on the interface form
  (luci-proto-wwand, choices from sim_inventory), error codes, status-page
  row, the slot buttons ask before forcing (luci-app-wwand), `sim_slot` help
  amended. HW-verified on the NR7101 (RG502Q-EA, two cards, 2026-11-07):
  refusal while the other card's interface is up; `ifup` switching slot 2 ->
  1 and back, the way back registering and dialling 14 s after the ifup;
  `wwandctl slot` refused under a bound interface, `--force` releasing it;
  the boot slot following the bound card. Three faults found there and fixed
  before this commit: the reconnect path dialled the new interface before
  its card was read, the attach profile took the APN of the interface bound
  to the other card, and an ifdown left the switch holding the modem. The
  slot-1 card itself gets no service there (EMM detached / not subscribed),
  so a dial on it could not be shown. LuCI form and status row checked on
  the same box (luci-app/-proto from the working trees; the box keeps them).
- **Stuck offline (2026-11-07):** the RPi4's EG25-G (192.168.3.123) was
  left offline by a recovery modem reset it acknowledged and never performed,
  and from offline refused every mode but reset (INVALID_TRANSITION) — the
  ladder then climbed towards a reboot that does not cut its USB power. The
  QMI bring-up now leaves a refused online through the mode's way out
  (offline: reset; else low power first) and says *stuck offline* instead of
  climbing; an acknowledged admin/ladder reset is watched for the modem
  staying offline on the bus (`modem_init_qmi.uc reset_out_of_offline`,
  `modem.uc watch_reset`, gotchas.md). HW-verified on the Pi (2026-11-07,
  main + this change via hwtest): online refused → "resetting it" → 30 s
  later "stuck offline … retrying the reset in 600 s", `control_note` set,
  state SET_OPMODE, the attempt counter stays (9) — no ladder. wwand keeps
  running there; the modem itself still needs a physical power cycle. Seen
  on the way: after ~10 h offline its QMI stopped answering altogether (CTL
  alloc and SYNC time out, AT still CFUN 7); a hub-port disable/enable
  (`1-1-port1/disable`) brought QMI back after ~130 s, still offline. The MBIM passthrough reset (`modem_mbim.uc reset`) has the same
  offline → reset shape and is not covered yet. The Pi's SIM (Vodafone IoT
  profile) is rejected on LTE (CEER 6,259) and was roaming-blocked on 2G
  (roaming_preference now 255) — separate thread.
- **LED styles `tech` and `signal_color` (#77, 2026-11-05):** a board
  file's `leds` may be a list of entries. `tech` lights one LED per
  generation (2G..5G, `cumulative` or one at a time for an RGB lamp,
  per-LED `weak` = on/blink/off at or below `weak_bars`, optional `signal`
  and `searching` LEDs); `signal_color` shows the bars as the colour of one
  RGB or red/green LED. The daemon tick hands the generation over as `gen`
  (`board.uc generation`: 5G NSA from rat_fine). LEDs are written only when
  they change. Host-tested with the Xunison D50 and AW1000 files from the
  issue; no test device has such a panel, so HW is the reporters' (4IceG,
  kuncy7). Not built: the LuCI LED page and micw's sweep (#48).
- **rmnet_nss after a restart (#78, 2026-11-05):** the probe needed a
  `<parent>_1`, which the first start had renamed to `wwandN`, so a restart
  fell back to a datapath that cannot serve `qmi_wwan_q` and looped on
  `mux_backend_unavailable`; the adoption's exact-MAC check refused the
  XT-Martinez driver's MAC + n children. Both now ask the sysfs parent link
  (`datapath_rmnet_nss.uc child_of`, see gotchas.md); a `qmi_wwan_q` parent
  with any child is claimed. HW-verified on the NR7101 (RG502Q-EA,
  2c7c:0800, which the driver gives `use_rmnet_usb`) with `qmi_wwan_q` 1.5.0
  from the XT feed, built for its 6.18.55 kernel in
  `/vol/release/nr7101/openwrt-ci` (upstream 116414a + the CI LTE-power
  patch), `qmap_mode=2`: the old code fell back to `rmnet` on the restart and
  looped, the fix adopted `wwand0`/`wwand1` (MAC + n, `device` -> `wwan0`) on
  two restarts, the second taking over the live session. To set it up again:
  stop wwand, unbind `2-1:1.4` from `qmi_wwan`, `insmod qmi_wwan_q.ko
  qmap_mode=2`. Back to `qmi_wwan` (bind `2-1:1.4`) the modem needed a
  `modem_reset` before usbnet sent again (tx_errors, rx 0; 2026-11-05).
- **QMAP DL aggregation default 31 KB (#79, 2026-11-05):** the per-model and
  per-board size tables are gone; every modem is asked for 31744 bytes and
  may clamp it (its echo sizes the receive side). 31 KB, not ModemManager's 32 KB, because the receive skb
  of 32768 + overhead needs a 64 KB allocation (netlink.uc
  `DEFAULT_DGRAM_SIZE`). New optional datapath entry `dgram_max`: the vendor
  datapaths (rmnet_nss, rmnet_nss_mhi) cap the request at the driver's fixed
  buffer. Measured by kuncy7 on an RG500Q-EA: CPU0 per 100 Mbit/s 10.9 % ->
  7.6 %.
- **Watchdog reset order (#76, 2026-11-02):** the zero-rx / TX-stall
  watchdog (`modem_common.trip_zero_rx`) went straight to the board repower
  where the board had one — a GPIO reset or power cut, skipping the modem's
  own reset. It now resets the modem first, as `modem_reset` does, and the
  board repowers only when that reset is refused or the modem is still on the
  bus after `reset_fallback` (default 30 s). Reported by marcinnet-25 on a
  Zyxel LTE7480-M804 (reset GPIO).
- **RAT priority (#75, built and HW-tested 2026-10-30):** `option rat_order`
  + `modem_get/set_settings` `rat_order` (+ `rat_order_writable`,
  `not_applied`) + LuCI Modem Tools *RAT priority* editor and the modem-page
  option; the `rat_order` config warning flags a supported RAT missing from
  the acquisition order (QMI validate pass and MBIM init alike). MBIM has no
  native order, so MBIM goes through the passthrough (reference.md "RAT
  priority"). hwtest `ratorder` checks + func and a CDP GUI test passed on
  every listed device but the blocked X3000 (Chateau read-only); every
  order was put back and compared. Firmware findings, all handled: the BG96
  lists eMTC/NB-IoT as NONE slots and refuses them (order then read-only);
  the EG06 over MBIM accepts an order and drops it at the next radio cycle
  (`not_applied`). Same run: hwtest `stage.sh` had been making `/usr`,
  `/etc`, `/lib` on every device non-root and 0775 — fixed, devices
  repaired (gotchas.md, tar entry).
- **TX-stall watch (built 2026-10-29, after pre30):** the daemon tick reads the
  kernel's `tx_timeout` count of each modem's data netdev, reports `tx_stall`
  in status (LuCI "TX stalls"), and a stall lasting `tx_stall_timeout`
  (default 120 s, 0 = watch only) takes the zero-rx recovery, only while a session of that modem is up. First seen on
  hardware by marcinnet-25 (#72, Quectel EG12, pre31, 2026-10-29): the stall
  was detected and tripped at his 60 s, but the counter re-fired every ~30-35 s,
  not every ~5 s, and the reset went over AT (QMI no longer answered), where
  `modem_common.at_reset` threw `access to undeclared variable guard` (in every
  release since 3a1fcc4, 2026-10-01, stable included). Fixed on main and
  HW-checked on the NR7101 (real engine, real CFUN=1,1, one callback);
  on stable as f25bcdc (cherry-pick, not yet in a release). The trip line no longer claims "the control
  channel kept answering" — `proto_errors` is a streak reset by any answer.
- **Fork branches for the device images** (ddimension/openwrt): `chateau-ci`,
  `lte3301`, `nbg7815-update` rebased onto openwrt main and **pushed 2026-10-24**
  (backups `*-pre-rebase-2026-10-24`); openwrt/openwrt#24881 is now its two
  remaining commits. Cause of the image failures: libffi moved into the OpenWrt
  core on 2026-10-19 (openwrt/openwrt@9b835ec626) and the old forks lacked it.
  The images rebuild with the next stable release tag — check that run.
- **Board files (#48, built 2026-10-29):** `board.uc` profiles are data now
  (`leds: { style, … }` over `LED_STYLES`), and a `<model id>.json` in
  `/usr/share/wwand/boards.d` or `/etc/wwand/boards.d` (that one wins) replaces
  the built-in entry; an invalid file is ignored whole and logged, status
  `board.profile_source` names the winner. hwtest `boardfile` (func.sh) passed on
  the Cudy, NR7101, LTE3301, LTE3301-PLUS and -M209. micw's 2G/3G/4G sweep panel
  would be a third LED style — build it with his board PR. MayorBug told on #50.
- **Issues waiting on reporters:** luci-app-wwand#16 (mrhaav — `BB3` band fixed
  in pre30; the eNodeB/sector row built 2026-10-29, luci-app-wwand 6d1abbc,
  checked on the Chateau), #73 (i18n
  packages; `pl` goes into `LUCI_WWAND_LANGS` once its po lands), #39 (MassiPi — slot-switch note fix),
  #66 (4IceG — `option mux_id '1'` + reboot suggested; the config error no
  longer walks the recovery ladder, fixed 2026-10-25; asked for `qmap_mode` to
  explain why the first boot ran unmuxed), #68/#71 (fixed,
  confirmation), #69 (`option gnss_nmea 'fix'` built 2026-10-25, measured on the
  NR7101's RG502Q: 28 → 3 sentences/s; EG12 untested — reporter to confirm), #70 (mrhaav — T99W175 `AT^TEMP?` → TSENS built 2026-10-28, keyed on the
  `QUALCOMM` manufacturer name; reporter to confirm), #48. #67 and #72 closed
  (#72: the freezes were the EG12 hanging on a weak signal). Two-week rule: a delivered issue with no answer for 14 days is
  closed.
- **PRs:** #50 (MayorBug, draft, conflicts) waiting on a rework. #60 and #65
  (xhudan) merged with follow-ups.
- **Upstream:** openwrt/packages#30185 (pins 1.6.9; maintainer review
  CHANGES_REQUESTED since 08-07; the bot's oldest open point — unversioned
  `+ucode` — is answered by the #67 floor once the PR is updated, which is done
  only on request), openwrt/luci#8917 (no maintainer review yet).
- **Not built, documented:** a modem with ONE dead QMI service is never reset —
  `docs/design/dead-service-recovery.md` (decision pending: auto-recover vs.
  report only). Bands > 64 on a legacy-only LTE modem still go out as the
  extended TLV alone.
- **Test devices:** only those in `../test-devices.txt` (workspace); HW tests run
  through `../hwtest/run.sh` (procedure and pitfalls in `../hwtest/README.md`).
  The LTE3301-PLUS (EG06-E, now in MBIM mode) does not register with its current
  SIM, so its `connect` check fails for that reason alone.

## What it is

An event-driven **ucode** connection manager for OpenWrt cellular modems.
**Three control backends — QMI, MBIM, NCM** — behind one daemon-neutral
contract. The daemon owns the modem and context lifecycle and drives netifd over
ubus with `no_proto_task=1`; netifd keeps all addressing and routing.

Config lives in `/etc/config/network` (`wwand_modem` / `wwand_sim` / an
`interface` with `proto wwand` / `wwand_globals`). wwand manages **only**
`proto wwand` and coexists with uqmi/umbim/comgt-ncm; handing an interface over
is always user-triggered.

## Shape

| | |
|---|---|
| Packages | `wwand` (base, no backend) + `wwand-qmi` / `-mbim` / `-ncm` / `-mhi` / `-esim`, plus two optional datapath add-ons in the feed. Plugins in their own repositories: `wwand-ipa` (SGP.32 eIM), `wwand-qlog` (Quectel QLog diag capture), `wwand-rsim` (remote SIM: readers, phones over Bluetooth SAP, other modems' cards) |
| Datapath | one plug-in interface (`docs/datapath-interface.md`): built-ins `rmnet`, `qmimux`, `vlan` (MBIM), pseudo-modes `raw_ip` and `ethernet` (802.3, WDA-less QMI stacks); add-ons `rmnet_nss`, `rmnet_nss_mhi` |
| QMAP | negotiated down a ladder v5 → v4 → v1, capped by `option qmap_version` |
| Feed | ddimension/openwrt-repo, two independent lines — stable (releases, published only by a date tag; last: 2026.10.20 with wwand 1.7.1; 1.8.0 building) and main (development, `X.Y.Z_preN` from the `vX.Y.0-dev` marker, now `v1.9.0-dev`). The source repos have the same two lines (`stable` at v1.8.0). `wwand` requires `ucode (>=` the SDK's ucode `)` since #67 |
| Upstream | openwrt/packages#30185 (pins v1.8.0), openwrt/luci#8917 (luci-app-wwand v1.8.0, luci-proto-wwand v1.7.0) |

## Hardware verified (2026-10-24, main 3a12e9e, `hwtest/run.sh`)

The test devices are those in the workspace's `test-devices.txt`, nothing else.

| Box | Modem / backend | Result |
|---|---|---|
| MikroTik Chateau 5G R17 AX (203.245) | RG650E-EU, QMI + Huawei E392, QMI | connected, traffic; eUICC in slot 2 (4 profiles) read via slot switch and back; internet fallback — keeps the new version when it works |
| ZyXEL NR7101 (5.202) | RG502Q-EA, QMI | connected; reattach; band change re-attaches with the session handed back (#62); UIM Remote switched on 2026-10-24 |
| ZyXEL LTE3301 (5.201) | BG96, QMI | connected; reattach; legacy-only LTE mask (the band fix 674908a); accepts a band change without applying it |
| ZyXEL LTE3301-PLUS (5.200) | EG06-E, **MBIM** (switched from QMI 2026-10-24) | daemon clean, but no registration with its SIM (`+EMM ERROR 1,15`); UIM Remote switched on |
| Cudy LT300 v3 (3.113) | SLM770A-R, NCM | connected; reattach |
| GL.iNet GL-X3000 (3.93) | RM520N-GL, QMI + E392 | blocked by other tests; UIM Remote already on |
| HP EliteBook 850 G7 (5.204, x86_64) | Dell DW5932e / Foxconn T99W373, **PCIe/MHI** (`mhi-pci-generic`, `wwand-mhi`), MBIM + QMI passthrough | connected 5G NSA (ENDC); RAT priority read and in LuCI (2026-10-30, main f3f3a6a); eUICC in slot 2 listed; UIM Remote on via `AT^EFS`; borrows the NR7101's card over SSH (`donor_cond none`, the RG502Q refuses the condition TLV); the slot needs `kmod-hp-elitebook-850-g7-wwan-unlock` |
| HP EliteBook 850 G7 (5.204, x86_64) | Dell DW5931e / Fibocom FM350-GL (MediaTek T7xx, PCI `14c3:4d75`, `kmod-mtk-t7xx`), firmware 81600.0000.00.29.23.06_GC, **native MBIM** (MBIMEx 3.0, no QMI passthrough: `NoDeviceSupport`) | 2026-10-31, main f2c804f: FCC lock released by GTFCCLOCK (06f51e0); connected, ping 3/3, 5G SA on o2-de; IP config needs the full 60-byte query (7e4e5d8); CA over `AT+GTCAINFO?` (4e1d62d); eUICC (SGP.22 2.2.2) and APDU over MBIM; no RAT priority or NAS settings, which need the passthrough (`unsupported_on_backend`) |

Snapshot devices run ucode 2026.07.09 (libucode ABI 20230711), so the feed's
current snapshot packages do not install there (the #67 floor); hwtest deploys
the ucode tree as source over each device's own `wwand_io.so`.

## Multi-SIM: what the hardware here actually is

Measured on 2026-08-30 with the read-only `multisim` summary on `modem_sim_slots`:

| Box | Modem | slots | executors | concurrency | mode | source |
|---|---|---|---|---|---|---|
| Chateau (245) | RG650E, QMI | 2 | ≥1 | — | — | inferred |
| NR7101 (242) | RG502Q, QMI | 2 | ≥1 | — | — | inferred |
| GL-X3000 (93) | RM520N-GL, MBIM | 2 | **1** | **1** | DSSA | **SYS_CAPS, exact** |
| Cudy LT300 (97) | SLM770A, NCM | — | — | — | — | no slot query on AT |

Note the two QMI rows report **no mode at all**, which is the point of the
column. Over QMI the executor count is a count of distinct logical slots in use
— a lower bound — and a lower bound of one rules nothing out: a modem with a
second executor whose other slot is empty looks exactly like this. Only the
MBIM row states a mode, because only there did the modem state the numbers.
(`mode_min` carries what a lower bound *can* support: two logical slots in use
would floor at DSDS. Neither box reaches it.)

**Everything reachable is single-executor** as far as anything here can show.
That is not a gap in the reporting:
the RG650E's own firmware settles it, since Qualcomm's MBIM implementation
(`mbimd`) writes `NumberOfExecutors` and `Concurrency` as literal `1` instead of
asking the modem — decompiled, not inferred.

So **DSSA is the shape wwand supports, and the only shape we can test.** DSDS and
DSDA are understood down to message ids and TLVs (two independent sources: a
vendor IDL tree and the RG650E's own `libqmiservices.so`), but nothing here can
exercise them, and for the NAS half there is no openly licensed carrier of those
ids — so an upstream submission would have to rest on observed behaviour we
cannot produce. Reported rather than implemented, which is why the summary exists
at all: someone holding a dual-executor modem can answer in one command what we
cannot answer for ourselves.

**The inactive slot is not reachable** on either QMI box (HW-read on 242 and
245, 2026-09-26): both physical slots map to logical slot 1, and the one not in
use is switched off. SEND_APDU on logical slot 2 is refused NOT_SUPPORTED (94),
and a logical channel opened "on slot 2" lands on the active card (both read
the same EF_ICCID). `AT+QUIMSLOT` only switches between the slots, and
`AT+QCFG` offers no dual-standby option. So a modem cannot use one card and
lend the other (wwand-rsim refuses that with this reason).

Two things worth knowing if that ever changes. The subscription encoding is **not
uniform**: NAS and WMS use one byte, 0-based; WDS, DMS, QOS and DSD four bytes,
1-based with 0 meaning "default" — a shared codec silently binds the wrong stack.
And DSDA cannot be commanded at all: there is no `SET_MSIM_SUB_MODE`, and
`nas_standby_pref_enum_v01` has no "dual active" member. It is a device property,
reported only.

## Index of the dated notes (moved to `status-archive.md` on 2026-10-24)

The topic notes that used to follow here are in `status-archive.md`, verbatim,
newest first. They are history — what was true when each was written; where one
still describes current behaviour, `reference.md` / `architecture.md` are the
place to check. One line each, with its opening sentence:

- **The zero-rx watchdog resets a modem the board cannot repower (2026-10-24)** — The zero-rx watchdog (inbound bytes frozen while QMI still reports the bearer CONNECTED) used to call `usb_repower()` and stop there.
- **Issue round 2026-10-13: AT port walk past an unopenable tty; MBIM settings refresh** — - #52 (T99W175, USB mode): the AT search ended at a tty that would not open (`ttyUSB1`, "No such file or directory") and went straight to the MBIM pipe, never trying `ttyUSB2`, where the modem answers.
- **A reattach stops the PDNs before it detaches; operator detach/attach (2026-10-10)** — `modem_reattach` (ubus) and the recovery ladder's opmode-cycle rung took the radio off — QMI DMS low_power, MBIM radio off, NCM CFUN=0, or `AT+COPS=2` — with the data sessions still up.
- **Profile flags: IPv6 prefix delegation, CLAT, address allocation (2026-10-09)** — Three interface options, all tri-state (unset = the modem profile is left as it is):
- **QMI over QRTR, and what it showed about PCIe (2026-10-04)** — ddimension/wwand#46 (xhudan) is merged: `option device 'qrtr'` runs the QMI stack over AF_QIPCRTR for an SDX modem whose QMI lives only on the QRTR bus (`qmi_over_qrtr.uc`, `wwand_io` qrtr_open/qsend/qread/qdiscover;
- **The attach profile carries the config, always (2026-10-04)** — Field case deborah-3 (LTE3301-Q222 with a Sierra MC7710 out of another box, a fresh Telekom card):
- **A dial the modem never answers frees itself; our reset keeps a live session (2026-10-04)** — deborah-3 again (Sierra MC7710, SWI9200X_03.05.29):
- **The network sets the clock (2026-10-03)** — `option nitz_time` on the `wwand_modem`, default on, LuCI flag *Set the clock from the network* in the modem settings.
- **A profile switched by somebody else is applied (2026-10-01)** — An SGP.32 IPAe profile enable on the EG25-G at 3.123 (QMI) dropped the session and left wwand on the old identity:
- **The FM350 is asked whether it is ready before it is asked what it is (#45, 2026-09-30)** — NCM bring-up now polls ATI (1 s, at most 30 s:
- **Band lists on the FM350 (ddimension/wwand#43, 2026-09-29)** — `band_lte` / `band_nr` / `band_umts` on a `wwand_modem`, contributed for the Fibocom FM350-GL, whose only band command `+GTACT` is not NV.
- **A modem waiting for its remote SIM stays off its own card (2026-09-28)** — A modem with a remote SIM assigned (wwand-rsim) runs on that card or not at all:
- **Remote SIM (wwand-rsim, 2026-09-27)** — What the plugin does now, and what the core offers it — the details, the tested hardware and the workarounds are in the wwand-rsim README:
- **A block after a card change comes back by itself (2026-09-27)** — An interface stayed down after an eSIM profile switch:
- **A new `wwand_sim` does not restart the modem (2026-09-27)** — SIM overrides are left out of the modem's reload signature:
- **A direct download's PIR reaches the SM-DP+ (2026-09-27)** — `esim_bridge.session_notify(ref, seq, cb)`:
- **Optional plugins, and the eSIM bridge's exit status (2026-09-26)** — SGP.32 eIM fleet management was first built into the core.
- **The diag port on main; QLog capture as a plugin (2026-09-26)** — The `wwand-qlog` branch (b3272e5, 528db7d, based on 55d1cf6) was split the same way as the eIM work.
- **SIM inventory, a card lent to another modem, the radio hold (2026-09-26)** — SIM inventory (`siminventory.uc`, ubus `sim_inventory`, `wwandctl sims`, LuCI Status → SIM cards):
- **What MBIMEx v3 actually buys (2026-09-20)** — Speaking v3 was the price of keeping an RM520N-GL connected (above).
- **A renew netifd cannot receive (2026-09-20)** — The daemon pushes new settings to netifd with `renew`.
- **`mux auto` on MBIM costs nothing now (2026-09-20)** — An `auto` channel used to take session 1 on MBIM, which means an 802.1q tag on every frame in both directions and a VLAN sub-device to route through.
- **The MBIMEx handshake had no second chance (2026-09-20)** — Found while switching a live MBIM modem's mux configuration, and unrelated to that:
- **The modem was never told what to tell us (2026-09-20)** — wwand registered indication handlers and never sent `MBIM_CID_DEVICE_SERVICE_SUBSCRIBE_LIST` (basic_connect cid 19), so what arrived was whatever each firmware volunteers.
- **Three things MBIM could always do and wwand never asked (2026-09-20)** — Each is the LOWEST rung of a ladder that already had two.
- **GPS: the three pieces were all there (2026-09-20)** — wwand FINDS the modem's NMEA port during enumeration (`gps_port`).
- **MBIMEx v3 (2026-09-19)** — wwand asks for MBIMEx 3.0 at `open()` and reads the layouts of whatever the modem agrees to.
- **MBIM failures say what failed (2026-09-19)** — The QMI client reports the failing message to the recovery hook and `modem.uc` logs it (`qmi error (qmi) svc N NAME, counter M`).
- **IPv6 interface identifier (2026-09-10)** — `option ip6ifaceid` (alias `ifaceid`) pins the low 64 bits of an interface's IPv6 address while the network keeps assigning the prefix.
- **Modem status page: live signal graphs (2026-09-10)** — The LuCI status page is now warnings → graphs → panels.
- **Startup banner (2026-08-31)** — Three lines at every start, so a posted log answers the questions that used to need a reply from the operator:

## Known open

- **DONE (2026-09-21) — `pdp_type` is configurable per SIM.** `wwand_sim` now
  carries it beside `pincode`/`apn`/`auth`/credentials, case-folded and
  validated exactly like the interface's (an unrecognised value is reported and
  dropped rather than silently becoming dual stack). Asked for in
  ddimension/wwand#35: an FM350-GL holding eSIM profiles from three Indonesian
  carriers, where by the reporter's tcpdumps XL answers IPv6 and Smartfren and
  IM3 do not — so the question is not "does this box want IPv6" but "does this
  SIM's carrier have it", which a global knob cannot say. The same parser
  warning turned up independently on an RM520N-GL the next day, and again here
  on the NR7101 (2026-09-21), so the expectation is not one person's.

  Accepting the key was the small half. Every consumer read the family off the
  INTERFACE, so the inventory below all had to move to
  `context_common.effective_pdp()`, which resolves through `conn_cfg` and
  carries the `ipv4v6` default in one place instead of eight:

  | Where | What read it |
  |---|---|
  | `context.uc` | four sites (profile setup, the AT `CGDCONT` string, the type check, the re-apply comparison) |
  | `context_mbim.uc` | the MBIM `IpType` at activation |
  | `context_ncm.uc` | `eff_config()`, whose override list was exactly `apn, auth, username, password` |
  | `modem_mbim.uc` | the ATTACH profile |
  | `modem_ncm.uc` | `attach_cfg()`, which returned `ctx.config` unfiltered |
  | `daemon.uc` | the dynamic DHCPv6 subinterface gate |

  The two NCM rows were the ones that would have shipped broken: the unit tests
  for the parser and the resolver both passed while NCM went on dialling
  IPV4V6 for a card that had said IP. What caught them was a BACKEND test —
  interface `ipv4v6`, card `ipv4`, assert the AT line on the wire — and the
  override list is now one shared constant (`context_common.SIM_OVERRIDABLE`)
  so a seventh consumer cannot quietly carry a copy of it.

- **DONE (2026-08-30) — the recovery ladder no longer touches hardware on a
  protocol it has never spoken.** Every rung, the reboot included, is gated on
  one answer having arrived in the selected protocol; the permission is sticky,
  persisted, withdrawn on a protocol change, and withdrawn again when
  `option protocol` contradicts the driver (an AT port answers on QMI and MBIM
  modems too, so it cannot prove an NCM pin). `option protocol` itself is parsed
  now — it was documented, advised by the daemon's own error message, and
  silently dropped by `config.uc`.
  **One exception was cut into it on 2026-09-23** (`ddimension/wwand#40`): on a
  board that exports the modem's own named RESET line, the ladder may pulse that
  line once per outage at the repower threshold even unarmed — nothing else, no
  power cycle, no reboot, and never when the pin is known to contradict the
  driver. The gate's own origin commit had already named the case it could not
  serve ("an NR7101 can wedge so that only a power cycle clears it"), and that is
  the board the reporter runs: the arming evidence lives in tmpfs, so every
  reboot turns a modem that has worked for months into one that has never
  answered, and the rung written for that hardware could never fire. It is the
  same pulse `modem_repower` already performs unguarded when a human asks for it.
  The bound is persisted like `rung`, or a procd respawn loop would have pulsed
  once per restart.
- **TODO — the QMI surface survey is a map, not a plan.**
  `docs/design/qmi-surface-survey.md` records what the vendor QMI/RIL surface
  has that wwand does not model, ranked by value per line, with each item's
  provenance marked (citable / device-observed / proprietary) because that
  decides whether it can ever be upstreamed. Its top items are DELIVERED — the
  UIM card diagnostics, `UIM_REFRESH_OK`, long APDU, TMD thermal and CAT toolkit
  routing all landed on 2026-08-30/31, and the file marks them as such. What
  remains is unscheduled, and three entries there dissolved on inspection rather
  than being deferred (RF-band changes already arrive by another route, the
  error-rate indication carries no LTE or NR, and the sys-info rate limiter
  throttles an indication wwand never arms).
- **The cancellation family is closed AT THE PRIMITIVE (2026-08-31); a residue
  remains at the callers.** `client.destroy()` used to report `cancelled` to
  every pending callback while the client was still registered and its pending
  map still live, so a callback that reads "error" as "carry on" issued its next
  request from inside that loop: the frame went out, a timeout timer was armed,
  and the pending entry it created was wiped a moment later by the very loop
  that had called it. The response could then never be dispatched while the
  timer still fired and reported a protocol TIMEOUT on a client that no longer
  exists — straight into the recovery error counter that drives the reboot
  ladder. `destroy()` now refuses further requests and detaches from the hub
  BEFORE running a single callback, and `request()` on a destroyed client
  answers `cancelled` synchronously, so no QMI request can reach the wire from a
  cancellation callback any more.

  **What that does NOT close, and what the list below is now about:** a
  cancellation callback can still (a) fall through to a NON-QMI transport —
  verified, `sim.set_pin_lock()` reads `cancelled` as a transport rejection and
  walks on to an AT write, which does reach the modem; (b) arm a uloop timer —
  the init chain's SYNC retry re-arms up to SYNC_TRIES times after teardown,
  bounded and now wire-less, but still running; (c) mutate cached state that
  survives into the next attempt. Read the sites below with that in mind: the
  mechanical half is gone, the state half is not.

  The historical description of the family, for the sites below: Everything inside the 2026-08-30/31 range is fixed,
  with tests that use the PRODUCTION error shape — the first attempt did not, and
  a guard checking a bare `err.error` never matched a caller that wraps it as
  `{ stage, err }`, with a green load-bearing test agreeing with the guard
  instead of the caller. A whole-tree sweep in review found the rest, all older:
  - `qmi_backend.set_opmode()` hands `cancelled` to its continuation, so the
    recovery cycle, the admin reset and the SIM-reapply radio cycle all carry on.
  - a cancelled `STOP_NETWORK` immediately sends a second `STOP_NETWORK` on the
    dying client (the preserved retry treats every error alike).
  - `netsel_ops`: a cancelled GET falls through to a **permanent modem write**,
    and a cancelled SET is read as "the firmware rejected one LTE TLV" and
    retries the alternate write.
  - `sim.set_pin_lock()` reads a cancellation as "try the next transport" and
    walks UIM → DMS → AT; the APDU probe can cache `_apdu_be = 'none'`.
  - the init chain does not capture `_gen` at all: SYNC, VERSION, ALLOCATE,
    `read_info`, opmode, SIM-slot, unlock, identity, system-preference and
    `config_check` all continue or re-arm timers.
  - telemetry continues across a cancellation and can cache degraded backend
    choices (`_ca_be`, `_dsd_be`) that survive into the retry.

  **It wanted one convention, and got one — in the primitive rather than at the
  callers.** Twenty patches was the wrong shape and the entry said so; what it
  did not see was that the trap belonged to `client.uc`, which could close it
  once for everybody. The per-caller convention (a captured generation plus a
  `torn_down(err, client)` helper next to the forward declarations, since a
  `let` further down is not hoisted in ucode and fails at CALL time) is still
  what the remaining state-half sites want, and modem_mbim's reattach got one on
  2026-08-31 for exactly that reason. Severity was always narrow — a teardown
  with a request in flight. The worst of the family are writes that outlive their
  modem: a slot switch, an NV profile write, a network-selection write. Raised in
  review 2026-08-30, primitive closed 2026-08-31.
- **TODO — recovery state has no identity boundary.** The counters, `proto_ok`
  included, are keyed on the modem *id* and persist across daemon restarts
  within a boot (tmpfs). Swap the physical modem behind that id and the
  replacement inherits the arming the previous one earned. There is no sound
  fix without evidence: a modem at that id which never answers is
  indistinguishable from the same modem gone silent, which is precisely the case
  the hardware rungs exist for — so refusing to inherit would disarm the wedged
  modem this feature was built for. The IMEI does not *fully* close the window
  either, since it only arrives after the modem has answered, by which point the
  replacement has earned its own arming anyway — but it is not useless: once a
  replacement IS detected, the inherited attempts/rung/proto-error counters are
  the previous modem's outage and should be reset rather than escalated on. The
  USB **iSerial** is the better lever, because this tree already reads it
  pre-open (`discovery.resolve_modem_device`), so for hardware that exposes a
  stable one the boundary can be closed opportunistically. Recorded because it
  is a real narrowing of the invariant ("a modem at this id answered", not "this
  modem answered"), and because the partial fixes are worth more than the
  absolute framing suggested. Raised in review, 2026-08-30.
- **TODO — nothing catches a mismatched split-package install.** The ucode tree
  ships as a base package plus per-backend ones, and the feed's DEPENDS carry no
  version. A base from one release running backends from another fails the way
  a partial deploy did here on 2026-08-30: HEAD's `modem.uc` against r49's
  `discovery.uc` stalled at `open_at` with **no log line at all**, which cost
  several rounds of suspecting the new code. Worth an exact-version DEPENDS in
  the feed, or a fail-loud internal API version constant checked at start-up —
  the point being that it must be loud, since the silent stall is the whole
  problem. Raised in review, 2026-08-30.
- **DONE (2026-08-31) — the NCM/AT backend accepts a `cdc-wdm` as its AT port.**
  On a `huawei_cdc_ncm` modem the AT channel IS `/dev/cdc-wdm0` (the driver
  registers a cdc-wdm carrying AT alongside its NCM datapath), and wwand only
  resolved ttys, using the wdm as an anchor to find one. Delivered by the
  device-support branch: a cdc-wdm is a char device, not a tty, so it skips
  termios setup and uses the message-oriented path the io module already has.
- **openwrt/packages#30185** is `CHANGES_REQUESTED` on scope, which is a
  maintainer decision, not a defect list — all 34 review threads are resolved.
  The full build/runtime CI has not run on that PR since `8ffb9e3`; only the
  three FormalityCheck jobs report.
- **PCIe/MHI** (`wwand-mhi`) is validated with community testers rather than on
  hardware here.
- **eSIM over MBIM UICC** is wire-verified against libmbim 1.32 + lpac but not
  end-to-end: no eUICC-capable MBIM modem is on hand (the RG650E rejects
  MBIM_OPEN, the EG06 card has no eUICC).
- **The E182E-class QMI support is now E2E-verified** (2026-08-31, sponsor box
  with a Globe SIM): CONNECTED on 2G and traffic through the 802.3 function.
  Two HW-forced corrections landed on the way: the `ethernet` datapath must
  keep **ARP on** (the function is an L2 bridge into the GGSN segment; NOARP
  left the host with a zero dest MAC and no traffic — the mwan3 track ping
  through the modem was the proof), and the client table is tiny — failed
  attempts leaked slots (teardown destroyed clients without CTL RELEASE_CID),
  so teardown now releases while the transport is up and ClientIdsExhausted
  triggers an AT+CFUN stack reset instead of a retry spiral. The DMS fallback
  caveat stays — without UIM an empty slot surfaces as registration timeout,
  not SIM_BLOCKED (documented in `modem_quirks.uc`).
- **v1 (plain QMAP) end-to-end on the RG650E** did not carry traffic in a
  deliberate downgrade test even through the create path, while v5 does. Not
  chased: no configuration here runs v1.

## Before a release

1. `cd tests && sh run_tests.sh` — all green.
2. `tools/check-export-terminators.py` — the suite CANNOT catch this one. The
   host ucode accepts an `export function` closed with a bare `}`; OpenWrt's
   refuses the module and blames the next export several lines down. It shipped
   that way in v1.6.4 (`wwandctl_fmt.uc`, ddimension/wwand#17) with every test
   green.
3. `tools/check-packaging.py --makefile ../repository/wwand/Makefile` — and again
   with `--makefile <pkgs>/net/wwand/Makefile --tarball <release>.tar.gz`.
4. The LuCI repos, which have no runner of their own — in `luci-app-wwand`:
   `node tools/test-format.js`, `node tools/test-modemsid.js`,
   `node tools/check-detached-methods.js`
   (and `--self-test`, which proves that checker still recognises the shapes it
   claims), `tools/check-xss.py`, and `node --check` over every shipped `.js`; in
   `luci-proto-wwand` the `node --check`. Step 4 exists because the frontend
   checks were written, then run by hand, then not run: `fmtRegistration`
   aliased without its receiver threw on every draw of the Registration column
   and shipped with a green suite, because the suite called it WITH a receiver
   and the view did not (openwrt/packages#37, 2026-09-21).
4a. Nothing to run by hand for the doc checkers: step 1 already runs
   `check-map.py`, `check-anchors.py --since HEAD` and
   `check-export-terminators.py` after the suites and fails on any of them.
   Step 2 stays listed because of the defect it names, and running it again
   costs nothing. What `--since HEAD` cannot see is a shift that is already
   COMMITTED: after a pass that removes or adds comment lines, run
   `tools/check-anchors.py --since <the commit before it> --fix` once.
5. **Two lines (since 2026-10-04):** releases are tagged on the `stable` branch,
   never on main; main carries the `vX.Y.0-dev` marker of the minor it develops
   (currently `v1.9.0-dev`) and ships as `X.Y.Z_preN` on feed main. A patch
   release: get the fix onto `stable` (cherry-pick `-x` from main, or fix on
   stable and merge stable into main), run 1-4 there, tag `vX.Y.Z` on stable —
   in luci-app-wwand / luci-proto-wwand only where they changed. Opening a new
   minor: merge main into stable, tag `vX.Y.0` there, tag `vX.(Y+1).0-dev` on main.
   Pin the **commit** (`git rev-parse vX.Y.Z^{commit}`), never the tag object.
6. Feed, on its **stable** branch for a release (its **main** for a development
   pin): `scripts/bump-source.sh wwand vX.Y.Z` (and the LuCI packages that were
   tagged) — the channel comes from the feed branch, the commit must be on the
   source branch of the same name; version, release and SDK hash in one go;
   verify the Makefile actually changed. Rules: the feed's CLAUDE.md.
7. One feed push, then wait: a push to feed stable only BUILDS. Devices get it
   with the release tag (`scripts/release-stable.sh`, only when asked), which
   is what publishes stable and starts the images.

The traps in steps 2 and 5-7 have each fired at least once; `gotchas.md` says how.
