# wwand — current state

_State of 2026-10-01, v1.6.9. 61 host suites, all green (`cd tests && sh
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
| Packages | `wwand` (base, no backend) + `wwand-qmi` / `-mbim` / `-ncm` / `-mhi` / `-esim`, plus two optional datapath add-ons in the feed. Plugins in their own repositories: `wwand-ipa` (SGP.32 eIM), `wwand-qlog` (Quectel QLog diag capture), `wwand-rsim` (remote SIM: readers, phones over Bluetooth SAP, other modems' cards) |
| Datapath | one plug-in interface (`docs/datapath-interface.md`): built-ins `rmnet`, `qmimux`, `vlan` (MBIM), pseudo-modes `raw_ip` and `ethernet` (802.3, WDA-less QMI stacks); add-ons `rmnet_nss`, `rmnet_nss_mhi` |
| QMAP | negotiated down a ladder v5 → v4 → v1, capped by `option qmap_version` |
| Feed | ddimension/openwrt-repo, two independent lines — stable (releases, published only by a date tag): `wwand`, `luci-app-wwand`, `luci-proto-wwand` 1.6.9; main (development): `1.7.0_preN` from the `v1.7.0-dev` marker. The source repos have the same two lines (`stable` from v1.6.9) |
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

Neither QMI modem accepts QMAP v4 (HW-observed, same runs as the table); both take v5 and fall back to v1 when asked
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

## Optional plugins, and the eSIM bridge's exit status (2026-09-26)

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

## The diag port on main; QLog capture as a plugin (2026-09-26)

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

## SIM inventory, a card lent to another modem, the radio hold (2026-09-26)

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

## Remote SIM (wwand-rsim, 2026-09-27)

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

## A block after a card change comes back by itself (2026-09-27)

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

## A new `wwand_sim` does not restart the modem (2026-09-27)

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

## A direct download's PIR reaches the SM-DP+ (2026-09-27)

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

## A modem waiting for its remote SIM stays off its own card (2026-09-28)

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

## Band lists on the FM350 (ddimension/wwand#43, 2026-09-29)

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

## The FM350 is asked whether it is ready before it is asked what it is (#45, 2026-09-30)

NCM bring-up now polls ATI (1 s, at most 30 s: `ready_timeout`/`ready_poll`)
before reading CGMI/CGMM. A modem still refusing after that is filled field by
field from its last bring-up, then from its USB id (`ncm_vendors.USB_IDENTITY`:
the FM350-GL's 0e8d:7126/7127), and a CGMM answering the manufacturer counts as
no model. Host-tested (test_ncm s9zb-s9ze); not yet confirmed on the reporter's
H29K.

## A profile switched by somebody else is applied (2026-10-01)

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

## The network sets the clock (2026-10-03)

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

## QMI over QRTR, and what it showed about PCIe (2026-10-04)

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

## The attach profile carries the config, always (2026-10-04)

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

## A dial the modem never answers frees itself; our reset keeps a live session (2026-10-04)

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

## Profile flags: IPv6 prefix delegation, CLAT, address allocation (2026-10-09)

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

## A reattach stops the PDNs before it detaches; operator detach/attach (2026-10-10)

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
   (currently `v1.7.0-dev`) and ships as `X.Y.Z_preN` on feed main. A patch
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
