# wwand — current state

_State of 2026-09-24, after v1.6.8. 58 host suites, all green (`cd tests && sh
run_tests.sh` — it prints the count, which moves too often to be worth repeating
here)._

This file describes **what is true now**. The dated log of how it got here is
`status-archive.md`; beliefs that looked right and were not are in
`gotchas.md`. Keeping them apart is deliberate: a running log with the current
state buried at the top invites reading a months-old entry as present tense.

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
| Packages | `wwand` (base, no backend) + `wwand-qmi` / `-mbim` / `-ncm` / `-mhi` / `-esim`, plus two optional datapath add-ons in the feed |
| Datapath | one plug-in interface (`docs/datapath-interface.md`): built-ins `rmnet`, `qmimux`, `vlan` (MBIM), pseudo-modes `raw_ip` and `ethernet` (802.3, WDA-less QMI stacks); add-ons `rmnet_nss`, `rmnet_nss_mhi` |
| QMAP | negotiated down a ladder v5 → v4 → v1, capped by `option qmap_version` |
| Feed | ddimension/openwrt-repo — stable (releases): `wwand`, `luci-app-wwand`, `luci-proto-wwand` 1.6.8; main: development pins as `1.6.8_pN` |
| Upstream | openwrt/packages#30185 (pins v1.6.3), openwrt/luci#8917 |

## Hardware verified (2026-08-30, on r49 + the same day's device-support HEAD)

| Box | Modem / backend | Datapath | Result |
|---|---|---|---|
| MikroTik Chateau 5G R17 (`245`) | RG650E, QMI | `rmnet · QMAP v5` | connected, traffic |
| Zyxel NR7101 (`242`) | RG502Q, QMI | `rmnet · QMAP v5` | connected, 5G-NSA |
| GL.iNet GL-X3000 (`3.93`) | RM520N-GL, MBIM | `vlan` | connected, traffic |
| Cudy LT300 v3 (`3.97`) | SLM770A, NCM | `cdc_ether` | connected, traffic |
| Huasifei WH3000 Pro (sponsor) | FM350-GL, NCM | `rndis_host` | connected, traffic |
| Huasifei WH3000 Pro (sponsor) | E3372H, NCM | `huawei_cdc_ncm` | connected, traffic — AT on the cdc-wdm control channel, IP via CGPADDR (CGCONTRDP/GTDNS absent on stick firmware 21.200), v6 via RA + dhcpv6 subinterface |
| Huasifei WH3000 Pro (sponsor) | E182E, QMI (minimal 2011 stack) | `ethernet` | **E2E verified: CONNECTED + traffic on 2G** (sponsor SIM). No UIM/DSD/WDA; DMS fallback, GET_SIGNAL_STRENGTH signal, 802.3 kept with ARP on (the function is an L2 bridge into the GGSN segment — NOARP broke the traffic path, HW-proven) |

Neither QMI modem accepts QMAP v4; both take v5 and fall back to v1 when asked
for something they decline. The MBIM and NCM paths report no QMAP version at
all, which is correct — QMAP is not on the wire there.

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

Two things worth knowing if that ever changes. The subscription encoding is **not
uniform**: NAS and WMS use one byte, 0-based; WDS, DMS, QOS and DSD four bytes,
1-based with 0 meaning "default" — a shared codec silently binds the wrong stack.
And DSDA cannot be commanded at all: there is no `SET_MSIM_SUB_MODE`, and
`nas_standby_pref_enum_v01` has no "dual active" member. It is a device property,
reported only.

## Startup banner (2026-08-31)

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

## IPv6 interface identifier (2026-09-10)

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

## Modem status page: live signal graphs (2026-09-10)

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
  (`atcmd_parse.uc:356`). `modem_common.normalise_qmi_signal()` converts at the
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

## MBIMEx v3 (2026-09-19)

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

## What MBIMEx v3 actually buys (2026-09-20)

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

## MBIM failures say what failed (2026-09-19)

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

## A renew netifd cannot receive (2026-09-20)

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

## `mux auto` on MBIM costs nothing now (2026-09-20)

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

## The MBIMEx handshake had no second chance (2026-09-20)

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

## The modem was never told what to tell us (2026-09-20)

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

## Three things MBIM could always do and wwand never asked (2026-09-20)

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

## GPS: the three pieces were all there (2026-09-20)

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

## eSIM fleet management through an eIM: wwand-ipa (2026-09-25)

An eIM is the fleet side of SGP.32: the operator queues profile operations and
an IoT Profile Assistant on the device runs them. `wwand-ipa` makes the router
that assistant, with onomondo-ipa (AGPL, commit 6aaeb38) as a separate program
packaged by the feed as `wwand-ipad`. Deliberately a first step: it drives an
SGP.22 consumer eUICC through the assistant's IoT eUICC emulation, and the eIM
accepts that mode. A standard SGP.32 v1.2 assistant is planned separately.

**The card is reached the way lpac reaches it.** onomondo-ipa knows only PC/SC.
Patch 100 (feed, `wwand-ipad/patches/`) gives it a card backend that speaks
lpac's stdio APDU protocol byte for byte, so `esim_bridge` relays it over the
modem's own channel (MBIM UICC / QMI UIM / AT) with no new transport. The two
sides do not speak the same card dialect, and the backend reconciles them:

- libipa talks raw T=0: TERMINAL CAPABILITY, MANAGE CHANNEL, SELECT ISD-R
  expecting 61xx, and GET RESPONSE with a length it checks exactly.
- A modem opens channels by AID and completes GET RESPONSE itself.

So MANAGE CHANNEL is answered locally, and the channel is really opened at the
SELECT. CLA carries the modem's channel, not libipa's. An answer that arrives
whole is handed out again in 61xx/GET RESPONSE portions of exactly the
announced size. The patch has its own ctest (`tests/scard_stdio`), and each of
its checks was confirmed to fail with the code it guards removed.

**A profile change needs the host, and the assistant has to wait for it.**
Without a REFRESH the modem keeps the old profile until the SIM is reset. The
result of the package can only reach the eIM over the new session, and the
state needed to report it, or to roll back, lives in the assistant's MEMORY,
not in its state file. So the assistant must stay alive through the change.
Its new `-H` option emits `profile_changed` and blocks. wwand resets the SIM,
waits for a NEW connection generation (the old session still reads CONNECTED
for a while), and answers. The assistant then re-opens the card channel, which
the reset closed. If the eIM stays unreachable, it rolls back on its next poll,
and hands that change back the same way.

**SIGTERM saves the state.** The bridge ends a hung run with a kill. In
emulation, the state file IS the eIM trust: the configuration and the replay
counter. So SIGTERM interrupts the blocking read, and every later exchange
fails at once, which lets main() reach the save. Tested on the host by leaving
an exchange unanswered and killing the process. Before the fix, the shutdown
path blocked on a second read and never saved.

**Refused where guessing would be wrong.**
- A card without a state file and no `ipa_eim_config` is not polled.
- Manual profile changes and notification delivery on a managed card are
  refused (`ipa_managed`, override with `force`), because the assistant's
  record of the card would go out of step.
- The ipa options are outside the modem's reload signature, so switching fleet
  management on does not bounce the session it runs over (test_daemon, reload
  2b).

Found on the way: `tools/check-map.py` read a regex literal with an odd number
of quote characters as the start of a string and blanked the rest of the file,
so any symbol cited after one (`esim_bridge.uc stdio_run`) looked missing. It
skips regex literals now.

**Operating a fleet.**
- The assistant logs to the syslog, not to a file. Its stderr joins the
  protocol pipe and is mapped onto wwand's levels: ERROR → warn, and the APDU
  hexdumps only at debug.
- Polls are spread per router, by a fixed fraction derived from its IMEI, over
  the first-run wait and the interval, and failures back off by doubling. That
  way a fleet that comes back from one power cut does not hit the eIM at the
  same moment.
- `/etc/wwand/ipa` survives a sysupgrade through keep.d. Package conffiles are
  file+checksum pairs of what the package shipped (base-files sysupgrade,
  bacda03b76), and the nvstate is created at runtime, so they would not keep it.
- The card's profile list in status is re-read after every run that reached
  the card.

Found on the way: **the eSIM bridge never saw a child's exit status.** close()
returns the shell's, and the shell's last command is the `echo __EXIT` marker,
so it read 0 unless uloop had reaped the shell first. lpac hid it, because its
verdict is its result line. For the assistant the exit status is the whole
verdict. The marker now wins.

**Not yet verified:** hardware, or a real eIM. Host-tested: the C backend
against a scripted host and against a fake card with the upstream binary
(provisioning run and eIM poll), and the scheduler with a fake bridge (test_ipa,
with counterproofs for the new-generation wait, the shell-safety refusal, the
no-config refusal and the lock). No LuCI yet.

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
5. Tag, pinning the **commit** (`git rev-parse vX.Y.Z^{commit}`), never the tag
   object.
6. Feed, on its main branch: `scripts/bump-source.sh wwand vX.Y.Z` (and the two
   LuCI packages, tagged `vX.Y.Z` alongside) — version, release and SDK hash in
   one go; verify the Makefile actually changed. Rules: the feed's CLAUDE.md.
7. One feed push, then wait: the feed CI is `cancel-in-progress` per branch.
   Devices get it when the feed's stable is released (`scripts/release-stable.sh`).

The traps in steps 2 and 5-7 have each fired at least once; `gotchas.md` says how.
