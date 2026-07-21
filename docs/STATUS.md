# wwand — status / continuation notes

_Last updated: 2026-07-21. HEAD: `2fb50a1`. All work committed + pushed to
origin; working tree clean; 14 test suites green._

## Where we are
QMI path is production-shaped and unit-tested. The big recent change is the
**no-proto-task rewrite** (`2fb50a1`): the per-interface monitor process is
gone, the daemon drives netifd in place, transient losses no longer tear the
WAN down (so IPv6-PD/VRF dependencies survive), and a wwand restart no longer
bounces the interface. See `CLAUDE.md` → "netifd integration" and
`docs/architecture.md`.

## ⛔ Immediate blocker
The **test router (192.168.203.245) was reflashed** and does not have the
current build. Nothing since the reflash has been verified on hardware. Next
session must: build the OpenWrt packages (see `CLAUDE.md` → Build), install via
apk (`--force-reinstall` or bump PKG_RELEASE), reboot, switch the modem to QMI
if needed (`AT+QCFG="usbnet",0` + `AT+CFUN=1,1`).

## Must verify on-device (the no-proto-task change is untested on HW)
Set up: WAN `qmi` proto in a VRF table, IPv6-PD delegating a /64 to a downstream
`dmz`. Then confirm:
1. **Transient blip** (radio/coverage cycle) → `ip -6 route show table <vrf>`
   and `ip -6 addr show dev dmz` **unchanged**; `logread` shows hold + `renew`,
   no "is now down". Only a brief WAN blackhole.
2. **`/etc/init.d/wwand restart`** → `ubus call network.interface.wan status`
   stays `up:true`; dmz PD + VRF routes persist; logread shows resync-via-renew,
   not down/up. Also: `ps | grep context-monitor` empty; `ubus -v list wwand`
   has no `context_wait`.
3. **Permanent**: pull USB modem → after `hold_max` (~90 s) WAN downs (PD
   withdrawn, expected); re-insert → `registered` → revives. SIM-blocked → WAN
   down until PIN/PUK.
4. Measure whether **CTL SYNC** on restart tears the live bearer (adoption
   tolerates it, but measure the blackhole).
Then re-run the LuCI status checks: max-rate / data-usage / uptime / error
counters (wwan0m2), inter-frequency cells, multi-modem selector.

## Pending work (not blocked by anything but the router)
- **Dedicated restart-adoption unit test** — the code path (iface_status →
  adopt-in-place vs kick) is exercised indirectly in `test_daemon` but there is
  no full "fresh daemon adopts a live session" scenario yet.
- **`hold_max` UCI config** — currently a 90 s default; the daemon `timing`
  struct isn't even plumbed through `main.uc` in production (tests set it via
  TIMING). Wire a global option if configurable holds are wanted.
- **AT-based stats** (need the modem, verify exact response format):
  per-antenna RSRP/SINR `AT+QRSRP`/`QSINR` (gold for antenna alignment),
  channel **bandwidth in MHz** `AT+QENG="servingcell"` (the "second bandwidth",
  fills the cell-lock `—`), Carrier Aggregation `AT+QCAINFO`, temperature
  `AT+QTEMP`. Plan + priorities in `docs/telemetry-survey.md`.
- **MBIM** end-to-end blocked on RG650E firmware (MBIM_OPEN fails); code is
  written + host-tested, lazy-loaded. Needs MBIM-capable HW to validate.

## Done this session (all committed)
- no-proto-task rewrite (`2fb50a1`); before it: bounded long-poll monitor
  (`73692e0`) and the ubusd-wedge graceful-shutdown fix (`e3d0567`) — both
  superseded by removing the monitor, but the history explains the wedge.
- QMI schema audited against libqmi 1.38 → fixed packet-dropped TLV ids
  (`e3825ad`), dropped dead GET_MSISDN.imsi (`40392c4`). Reusable audit approach
  in `CLAUDE.md`.
- Status page: PDP failure reason → text (`728d5e1`), data counters + uptime
  (`334c9ab`), modem-computed max up/down bandwidth (`d2e21c1`), inter-frequency
  cells + connections panel (`359c3b9`), multi-modem selector flicker fix
  (`6e1190e`), first stats sample fires immediately (`16a3c33`).
- LuCI cell-lock "Lock this cell" buttons; band tables deduped into
  `wwand.bands`.
- Lazy MBIM load (−228 KB RSS, `3f00087`); Makefile fixes: `Build/Prepare`
  (`2bfcf11`) + install `codec/mbim-schema` (`7f99e1f`).
- Telemetry/stats survey (`c38a8f3`); carrier-teardown (stage A) ruled out
  (`f507629`).

## Notes
- A tar-over-ssh deploy script exists in the session scratchpad (temporary, not
  in the repo). Prefer the proper apk package now.
- Memory index for this project: the user's auto-memory has `qmid-rewrite-project`
  and `wwand-vrf-constraint`.
