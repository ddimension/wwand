# What the QMI surface has that wwand does not model

A survey of the vendor RIL/QMI surface against libqmi 1.38 and against wwand,
done 2026-08-30. It exists because the question "what else is out there" kept
coming up and being answered from memory. **Nothing here is a plan.** It is a
map, with each entry carrying what it would cost, what it is worth, and — the
part that decides whether it can ever be upstreamed — where the knowledge came
from.

## Provenance classes, and why they are marked

Three tiers, because they are not interchangeable:

- **OPEN** — GPL/BSD/LGPL sources we can cite in a commit message or an MR:
  libqmi itself, the mainline kernel's QMI helpers, ofono, the qrtr `lookup.c`
  service table (BSD-3), and the old Gobi enums. Implementable *and* citable.
- **DEVICE** — read off the firmware of a modem we own (RG650E). Citable as an
  observation about that device, which is how much of libqmi's own
  vendor-specific surface got in: "modem X answers 0x004B with these TLVs",
  backed by a capture.
- **VENDOR** — mirrored proprietary Qualcomm IDL. Deliberately not named or
  linked here. Use it to know *what* to implement and to write tests against;
  never paste it, never cite it. An MR that cites it is worse than one that
  cites nothing.

The practical route for anything upstream-bound: cite OPEN for the service or
message **id**, derive the **TLV layout** from `GET_SUPPORTED_MESSAGES (0x001E)`
/ `GET_SUPPORTED_FIELDS (0x001F)` plus a wire capture on hardware. That is the
same standard the existing wwand schemas were held to.

## What is reachable, which is not the same as what exists

The survey established what QMI services exist *inside* the RG650E's firmware.
That is a different question from what is proxied onto the cdc-wdm QMUX link,
and it costs nothing to answer: wwand already sends CTL `GET_VERSION_INFO` at
INIT and logs the decoded service list (`modem_init_qmi.uc`, `services: …`).

From that log line on the Chateau (RG650E, 2026-08-30), the services present
beyond the nine wwand models:

| id | service | note |
|---|---|---|
| 0x0A | CAT2 | terminal-profile control — see below |
| 0x11 | SAR | 14 requests on this firmware; libqmi models 2 |
| **0x17** | **TS — thermal sensors** | **present on the link** |
| 0x18 | TMD — thermal mitigation | fully OPEN-specified |
| 0x1D | CSVT | |
| 0x24 | PDC — persistent device config | |
| 0x22 | COEX | LTE/Wi-Fi interference + antenna arbitration |
| 0x29 | RFRPE | RFM scenario switch |
| 0x2E | ATP | |
| 0x30 | DFS — data filter service | powersave/low-latency filters |
| 0x31 | IPA | |
| 0x44, 0x49, 0x4A, 0x4C, 0x4D | OTT, ?, ANTSWITCH, ?, ? | |
| 0x4E | DFC | |
| 0x55–0x5A, 0x5C | ? | unidentified, present |

**Two results that correct the survey's own conclusions:**

- **TS (0x17) is on the link.** The survey found no TS service object in the
  firmware image and concluded "use TMD, not TS". The live service list says
  otherwise. TS is the more interesting of the two — real sensor temperatures
  with host-set thresholds and a push indication — so this is worth re-opening
  rather than closing. Note the unresolved type question if it is: the vendor
  IDL calls the temperature `float`, the OPEN kernel table a generic 4 bytes.
  They agree on the width and disagree on the reading.
- **The Quectel vendor service (0xE3) is NOT on the link,** nor is UIM HTTP
  (0x47) or UIM Remote (0x32). The firmware exports a `quec_common_qmi` object
  with 75 requests, and it is not proxied to the host — so reverse-engineering
  it buys nothing for this modem over QMUX. That closes the one lead the survey
  named as worth a disassembler.

Also note **0xE3 is claimed three ways** — libqmi assigns it to Foxconn, the
Qualcomm BSP to an internal service, this firmware to Quectel. Any code keying
off 0xE3 must key off the manufacturer too. Same hazard at 0xE7/0xE8.

## Delivered from this survey

- **Call-end reasons** (`callend.uc`) — the internal table completed to 268, the
  181-entry call-manager table (type 3) added, verbose type `0x0C` = handoff
  recognised, and internal 241/236 corrected: 241 is INTERFACE_IN_USE_CONFIG_MATCH,
  236 is CALL_ALREADY_PRESENT. Needed no proprietary source at all — libqmi's own
  `qmi-enums-wds.h` carries all of it. **OPEN.**
- **WDA Set Data Format request TLVs** 0x18 qos_header_format, 0x19
  dl_min_padding, 0x1A flow_control — declared in the schema, deliberately not
  sent. DEVICE + VENDOR agreeing on ids and widths.
- **Multi-SIM shape reporting** (`sim.multisim`) — read-only, MBIM SYS_CAPS
  exact, QMI inferred and marked as such.

## Open, ranked by value per line of code

1. **UIM `REGISTER_EVENTS` (0x002E) mask bits.** wwand sets 4 of 12. Bits 3, 5,
   7, 9 unlock `SESSION_CLOSED_IND 0x0043` (with a 12-value cause enum:
   CARD_ERROR, CARD_REMOVED, REFRESH, RECOVERY, …), `SIM_BUSY_STATUS_IND 0x004A`,
   `RECOVERY_IND 0x0050`, `CARD_ACTIVATION_STATUS_IND 0x0055`. wwand already
   sends the message — this is a constant and four decoders, and it turns a
   class of silent SIM failures into named events. VENDOR for the bit meanings,
   but the ids are DEVICE-confirmed.
2. **UIM `REFRESH_OK` (0x002B) and the refresh enforcement policy.** libqmi
   models neither, so a libqmi-based stack cannot answer a `WAIT_FOR_OK` refresh
   stage at all. A box that votes for init and never sends REFRESH_OK stalls the
   card; one that does not vote gets its session pulled mid-data-call. **OPEN**
   (Gobi `eQMI_UIM_REFRESH_OK`). Operator OTA is not hypothetical on M2M SIMs.
3. **Indications libqmi can arm but not decode** — `RF_BAND_INFO_IND 0x0066`,
   `CURRENT_PLMN_NAME_IND 0x0061`, `ERR_RATE_IND 0x0053`. libqmi documents the
   registration TLVs and not the messages. One schema entry each.
4. **Indication rate control.** `NAS_LIMIT_SYS_INFO_IND_REPORTING 0x0070` (one
   64-bit mask) and the signal-info hysteresis timer at `0x006C` TLV 0x42 —
   libqmi models 0x006C but stops at TLV 0x3B, so it can set thresholds and not
   hysteresis. Directly reduces wakeups on a battery-less-but-CPU-bound router.
5. **TMD 0x18 / TS 0x17 thermal.** Both **OPEN**-specified end to end including
   the string encoding (nested string = 1-byte length, no NUL; a string that is
   the whole TLV payload carries no prefix). Both on the link. wwand currently
   gets temperature over AT (`AT+QTEMP`), which is vendor-specific per modem;
   this would be protocol-native.
6. **Long-APDU TLVs** on `SEND_APDU 0x003B` / `OPEN_LOGICAL_CHANNEL 0x0042` —
   matters for eSIM, where responses exceed the short form.
7. **CAT `SET_CONFIGURATION 0x002D`.** A headless CPE has no UI to render SETUP
   MENU or DISPLAY TEXT. Advertising a terminal profile that claims only what we
   can honour — or `DISABLED (0x00)` — is the structural fix for "operator OTA
   wedges the SIM". **OPEN** (ofono + Gobi). Service is on the link.
8. **Native eUICC queries** (UIM 0x0052, 0x0053, 0x0064–0x006D) — GET_EID,
   profile info incl. class and policy rules, without driving lpac for read-only
   questions. All DEVICE-confirmed in the request table. VENDOR for TLVs.
9. **Keepalive offload** (WDS 0x00D6/0x00D7/0x00D8, DSD NAT keepalive 0x0041) —
   an idle WAN survives carrier-NAT timeouts without waking the CPU.
10. **DFS powersave / low-latency filters**, **eDRX** (NAS 0x00BA/0x00BB, with a
    TLV-order trap between SET and GET), **PSM** (DMS 0x0060–0x0067).

## Open and blocked

**The radio-stack half of multi-SIM.** Message ids are known from two
independent sources (DEVICE + VENDOR): NAS standby preference 0x004B/0x005C with
indication 0x0047, NAS `MSIM_SUB_MODE` as the read-only QMI answer to MBIM's
`Concurrency` — DSDS-vs-DSDA is *reported*, never commanded — DMS TLV 0x14
`{max_subscriptions, max_active}` as the direct counterpart of MBIM
`SYS_CAPS.{NumberOfExecutors, Concurrency}`, and per-service subscription
binding (WDS 0x00AF, **OPEN**; NAS binding, VENDOR-only).

Blocked on two things, and neither is code:

- **No hardware here has more than one executor.** Everything reachable is
  single-executor; the RG650E's own firmware hardcodes `NumberOfExecutors = 1`.
  We cannot exercise DSDS or DSDA, only report their absence.
- **The radio-stack half has no openly-licensed carrier of those message ids.**
  The slot half (UIM 0x0046/0x0047/0x0048) and the data-session binding half
  (WDS 0x00AF, QOS 0x002D) are fully covered by OPEN sources and could be
  upstreamed today. The NAS half could only go up as observed behaviour, backed
  by a capture we cannot produce.

**Subscription encoding is not uniform** — NAS and WMS use one byte, 0-based;
WDS, DMS, QOS and DSD four bytes, 1-based with 0 meaning "default". Getting this
wrong is silent.

## Negative results worth keeping

- **Quectel/MeiG/Fibocom band locking, cell locking, USB composition and GNSS
  control are done over AT, not a QMI vendor extension.** quectel-cm's own
  headers contain no vendor service and no `0x55xx` message. wwand's existing AT
  path is the right one — do not hunt for a QMI equivalent.
- **The QMI AT service (0x08) is not a way to send AT to the modem.** It is the
  modem asking the *host* to handle AT arriving from elsewhere. Two sources also
  disagree on which id is the register-response, so do not implement it blind.
- **libqmi offers DMS messages this class of modem does not have** — firmware
  id/preference/stored-image/boot-download (0x003E, 0x0047–0x004C, 0x004F/0x0050)
  are absent from both the vendor IDL and the RG650E's own table.
- **No TCP MSS clamping message exists** anywhere in WDS/WDA/DSD/QCMAP.

## Still unconfirmed

`NAS_T3346_TIMER_STATUS_CHANGE_IND` — the registration TLV (0x2E) is confirmed
and names the indication verbatim, but no id for it was found in any tree. It is
the mobility-management backoff timer, and the most valuable single unconfirmed
item: a modem in T3346 backoff looks exactly like a modem that will not attach.

TLV layouts for SAR beyond 0x0002, RFRPE, COEX, ATP, WDA packet filters, and a
long tail of WDS ids: message ids confirmed, layouts not. Given the "a wrong tag
silently decodes garbage" invariant, none of these may get a schema without
`GET_SUPPORTED_MESSAGES` plus a capture.
