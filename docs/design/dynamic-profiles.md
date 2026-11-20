# Dynamic profile handling — survey and plan

Status: stage 1 (read path) in the tree; the plan below was revised on
2026-11-20 after the ModemManager comparison and the APN TLV measurement.
Evidence: ddimension/wwand#88.

## The problem

Without `option profile` (or `apn '#N'`) a QMI context dials the profile
numbered like its mux channel and writes its APN and PDP type into it
(`context.uc` `resolve_profile`, `prepare`). For mux 1 that coupling is wanted:
profile 1 is the attach profile wwand programs (`ensure_attach_profile(1)`),
and the interface that dials it carries its data on the attach bearer instead
of opening a second PDN to the same APN (`modem_common.uc` `attach_owner`).
For mux 2 and up it is not: on carrier configurations profiles 2 and 3 are
usually `ims` and `sos`, which the modem uses itself. A second channel
overwrote profile 2 and VoLTE broke without a warning (#88, RG500Q-EA).

## What QMI offers (libqmi 1.38, qmi-service-wds.json)

| Message | Id | Use |
|---|---|---|
| Get Profile List | 0x002A | the stored profiles: type, index, name |
| Get Profile Settings | 0x002B | per profile, incl. IMCN flag 0x22 and P-CSCF-via-PCO 0x1F |
| Get LTE Attach PDN List | 0x0094 | the profiles the modem attaches with (`current`, `pending`) |
| Get Default Profile Number | 0x0049 | default profile per family (embedded / tethered) |
| Create Profile | 0x0027 | the modem picks the index (lowest free, per #88) |
| Delete Profile | 0x0029 | |
| Set LTE Attach PDN List | 0x0093 | |

Read side in the tree: `qmi_backend.read_profiles`, ubus `modem_profiles`.

## Survey

`ubus call wwand modem_profiles '{"modem":"…"}'`, read-only.

| Modem | Firmware | List | Attach list | Default (emb/teth) | Profiles |
|---|---|---|---|---|---|
| RG502Q-EA (ZyXEL NR7101) | RG502QEAACR13A04M4G_ZYXEL | ok | current [1], pending [] | 1 / 1 | 1 `plus` pdp 0; 2 `ims` ipv4v6 imcn 1 pco 1; 3 `sos` ipv4v6 imcn 0 pco 1 |

(HW-read on the NR7101, 2026-11-14.) To do: EG25-G (MDM9x07 — does it know
0x0094 at all?), RG650E-EU, EG06-E over the passthrough, MC7710.

Findings so far:
- The attach profile is 1 on this modem, as wwand assumes — but it is the
  modem's to name, and the list is the place to read it from.
- An IMS-family profile is recognisable, but not by IMCN alone: `sos` has
  IMCN 0 and P-CSCF-via-PCO 1. A guard needs both flags (or the APN).

## How ModemManager does it

Read in ModemManager main `2c0ecd7` (2026-11-17, version 1.25.95):

- **A QMI connect never writes a profile.** Without a profile-id the APN, IP
  family and credentials go into WDS Start Network as TLVs, with no profile
  index (`mm-bearer-qmi.c:2480-2515`, `:1324`). A given profile-id is used as
  it is and the APN settings are ignored ("we'll launch the connection
  specifying the profile id in use exclusively", `mm-bearer-qmi.c:2480`).
- **The attach profile** is `current[0]` of Get LTE Attach PDN List
  (`mm-broadband-modem-qmi.c:12649-12661`); MM writes it only on an explicit
  request, and only when it differs (`mm-iface-modem-3gpp-profile-manager.c:543`).
- **Create Profile** takes the index the modem hands out ("when creating, we
  cannot select which profile id to use", `mm-broadband-modem-qmi.c:6832`).
- **IMS/SOS/MMS profiles** are told by the APN Type Mask, Get Profile Settings
  TLV `0xDD` (guint64, libqmi 1.38 `qmi-service-wds.json`, since 1.30; bits
  DEFAULT, IMS, MMS, …, IA, EMERGENCY), not by the IMCN or P-CSCF flags.
- **Only the AT path picks a context** (`mm_3gpp_profile_list_find_best`,
  `mm-modem-helpers.c:1647`): exact match, a gap between CIDs, the highest
  CID + 1, a context with an empty APN and the same IP type, and as the last
  resort it overwrites the highest one — which can be `ims` when the table is
  full.

## Measured: the APN TLV without a profile index

WDS Start Network (0x0020) with TLV 0x14 (APN), 0x19 (IP family) and 0x30
(3GPP), **no 0x31**, on a modem freed of its own call (`ifdown`), through
`modem_qmi_raw` (one client, released after the request). An unknown APN
(`wwand-apntest.invalid`) refused by the **network** shows the TLV reached
it; a success would have meant the modem dialled its default profile instead.
HW, 2026-11-20:

| Modem (firmware) | unknown APN, IPv4 | real APN, IPv4 | unknown APN, IPv6 | APN TLV |
|---|---|---|---|---|
| Huawei E392 (11.433.59.00.192) | 3GPP 33 | ok (`ims.iot`) | 3GPP 36 | honoured |
| BroadMobi BM806U-E1 (M1.0.0_E1.0.1_A1.2.2, raw_ip) | 3GPP 33 | ok | 3GPP 33 | honoured |
| Quectel BG96 (BG96MAR02A07M1G) | internal 209 (throttled) | ok | internal 231 | honoured: the real APN dials in the same minute |
| Quectel RG502Q-EA (RG502QEAACR13A04M4G_ZYXEL) | 3GPP 27, then internal 209 | ok (`plus`) | internal 231 | honoured |

Internal 231 is `IP_VERSION_MISMATCH` (libqmi 1.38 `qmi-enums-wds.h`): without
a profile index the BG96 and the RG502Q take the PDP type from the default
profile (IPv4 on both) and refuse an IPv6 call locally. The E392's default
profile is ipv4v6, so it does not. That is #88's second interface (`wwan6`,
IPv6, own APN): a profile-less dial alone does not serve it.

Not measured: a **bound** QMAP channel ≥ 2 (Bind Mux Data Port + Start Network
on the same client — `modem_qmi_raw` sends one request per client), the
RG650E-EU (the Chateau's WAN), the EG06-E (not registered), the EG25-G.

## Plan (decided 2026-11-20)

Every channel keeps dialling with a profile index, as today; what changes is
which profile a channel gets.

1. **Mux 0/1, the attach owner, dials the attach profile** and wwand writes
   it to the interface's config, as today ("the attach profile carries the
   config", `modem_common.uc` `attach_owner`). Its index is the first entry of
   the LTE attach PDN list (0x0094 `current[0]`), 1 where the firmware does
   not know the message (the E392, error 71). Not "profile 1" by number: the
   EG06-E attaches with 5 (below), and a write into 1 would miss the attach.
   Its own data then runs on the attach bearer instead of a second PDN to the
   same APN, which networks may refuse (ESM cause 55).
2. **Mux 2 and up get a profile of their own**, marked by name
   `wwand:<iface>`: the profile carrying the mark is reused and brought to the
   interface's values with the existing read-before-write (`prepare`, Modify
   Profile — APN, PDP type, auth, `PROFILE_FLAGS`: `ipv6_pd`, `clat`,
   `address_allocation`, `option ims`); without one, Create Profile (0x0027)
   with the mark, at the index the modem hands out. The mark is the mapping:
   it lives in the modem's NV with the profile and survives a reset (below),
   so nothing else has to remember the index. A uci copy of it would be a hint
   at most, used only when the profile there still carries the mark.
3. **Profiles without the mark are never written** — the carrier's `ims`,
   `sos`, `mms` above all (#88 point 1). A channel never shares one, so no IMS
   guard is needed; the APN Type Mask (0xDD) is still worth decoding in
   `modem_profiles`, for the display.
4. **`option profile N` / `apn '#N'` stay the explicit override**, unchanged.
   `option profile <mux_id>` reproduces the old behaviour for anyone who wants
   it. A missing profile is no longer a failed dial (#88 point 2): the step-2
   path creates it.
5. **Clean up** marked profiles whose interface is gone. The table lives in
   NV; its size is no pressure, so this is hygiene, not a capacity fix:
   `AT+CGDCONT=?` (the cid range) next to the profiles in use
   (`modem_profiles`), HW-read 2026-11-20 — E392 1–16 (uses 1), EG06-E 1–24,
   BG96 1–24 plus 100–179, RG502Q-EA 1–42 (uses 1–3), RG650E-EU 1–42 (uses
   1–4), BM806U-E1 1–50 (uses 1); the NCM/MBIM modems count from 0: ME906s
   0–11, SLM770A-R 0–15.
6. **NCM** (`+CGDCONT` cids) and MBIM are not part of this step. MBIM passes
   the APN in the connect; for NCM, ModemManager's `find_best` order without
   its last step (refuse with a warning instead of overwriting the highest
   cid) is the model when it comes to it.

What users notice: nothing on a single interface per modem (mux 0/1 — most
installs). An interface on mux 2+ without `option profile` gets a new entry
`wwand:<iface>` in the modem's profile table at its first dial instead of
overwriting the profile numbered like its mux. A carrier profile an earlier
version already overwrote is not repaired by this; that takes a carrier
configuration reload or a manual write, and belongs in the release note.

Considered and not taken: **dialling mux 2+ without a profile index** (APN in
Start Network, as ModemManager does). It would write no NV at all, and every
modem measured honoured the APN TLV (below). But a profile-less call takes
everything else from the modem's default profile — the PDP type included
(internal 231 on the BG96 and the RG502Q) — so `clat`, `ipv6_pd`, `option ims`
and a different IP type would still need a profile; a firmware that ignored
the TLV would bring the call up on the wrong APN without an error, which needs
a check after every start; and the bound mux channel ≥ 2 path was not
measured. The profile of its own does all of that with the dial that runs
today.

### Measured: the LTE attach PDN list

Get LTE Attach PDN List (0x0094: `current` 0x10, `pending` 0x11, arrays of
u16 profile indices), Get Max LTE Attach PDN Number (0x0092), Get LTE Attach
Parameters (0x0085: the APN and IP type the running attach used, and whether
it was an OTA attach), all libqmi 1.38 since 1.28; read-only, HW 2026-11-20:

| Modem | current | pending | max | attach used | attach profile holds |
|---|---|---|---|---|---|
| RG650E-EU (A05G8G) | [1] | [] | 56 | `nonbonding.hybrid`, IPv4v6 | the same, pdp 3 |
| RG502Q-EA | [1] | [] | 56 | `plus`, IPv4 | the same, pdp 0 |
| BG96 | [1] | [] | 56 | `nbiot.global-m2m.net`, IPv4 | the same, pdp 0 |
| BM806U-E1 | [1] | [] | 2 | `apn.global-m2m.net`, IPv4 | the same, pdp 3 |
| EG06-E (MBIM, passthrough) | **[5]** | [] | 1 | `apn.global-m2m.net`, IPv4 | the same, pdp 3; profile 1 is `profile1` with an empty APN |
| E392 | QMI error 71 (`INVALID_QMI_COMMAND`) for all three | | | | profile 1 `default` `ims.iot`, its only one |

- The attach does use the profile the list names: its APN is that profile's
  everywhere. The IP type is the network's grant — IPv4 on the GDSP and Plus
  cards even where the profile asks for IPv4v6.
- **The attach profile is not always 1**: the EG06-E in MBIM mode attaches
  with 5, written there by the firmware for the MBIM LTE attach
  configuration; profile 1 is a different, empty one. A QMI write into 1 would
  not reach that attach — reading the list is not a formality.
- The E392 does not know the messages at all (error 71, not a refusal): an
  older firmware generation, where the fallback to 1 is right — its only
  profile is the one it attaches with.
- `pending` is empty everywhere: a Set (0x0093) with action 1 (none) waits
  there for the next attach; action 2 detaches or disconnects "based on the
  modem configuration" (libqmi `QmiWdsAttachPdnListAction`).
- Room for an attach profile of wwand's own: 56 entries on the Quectel 5G and
  BG96 firmwares, 2 on the BM806U, 1 on the EG06-E (there only by replacing
  the entry), none on the E392.

### Measured: the mark survives a modem reset

Create Profile (0x0027) with name `wwand:test`, the name read back (Get
Profile Settings 0x002B, TLV 0x10), a modem reset (`modem_reset`: DMS
offline → reset; over the MBIM passthrough on the EG06-E), read again, Delete
Profile (0x0029). HW, 2026-11-20:

| Modem (firmware) | index handed out | name after create | after reset | delete |
|---|---|---|---|---|
| Huawei E392 (11.433.59.00.192) | 2 | kept | kept | ok |
| Quectel EG06-E (EG06ELAR04A04M4G) | 4 | kept | kept | ok |
| Quectel BG96 (BG96MAR02A07M1G) | 2 | kept | kept | ok |
| Quectel RG502Q-EA (RG502QEAACR13A04M4G_ZYXEL) | 4 | kept | kept | ok |
| BroadMobi BM806U-E1 (M1.0.0_E1.0.1_A1.2.2) | 2 | kept | kept | ok |
| Quectel RG650E-EU (RG650EEU00AAR01A05G8G) | 5 | kept | not reset (the Chateau's WAN) | ok |

Every modem handed out the lowest free index (#88 saw the same) and stores
the name in NV with the profile, so the name is a usable mark: `wwand:<iface>`
in the modem finds the interface's profile again after a restart, a reset or
a reinstall of wwand, without a mapping kept anywhere else. A uci copy of the
index (written back like the auto-assigned L3 name) is at most a hint, used
only when the profile there still carries the mark — the table belongs to the
modem, and an MBN switch, a factory reset or another modem behind the same
section makes a stored number point at someone else's profile.

Open questions: a carrier configuration (MBN) switch can reset the table and
the marks with it (then the profile is created again — the safe direction);
which default a profile-less RmNet call takes as its template, the embedded or
the tethered one (0x0049) — both are 1 on every modem read so far, so the
measurement needs a modem where they differ, or one set apart for the test.
