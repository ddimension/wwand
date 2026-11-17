# QMI beyond libqmi 1.38

wwand's QMI schemas follow libqmi 1.38 (`data/qmi-service-*.json`) wherever
libqmi defines a message. This page lists every message, TLV and value in
`src-ucode/codec/schema/` that libqmi 1.38 does **not** define: where it comes
from, and what checked it. A wrong id decodes garbage without any error, so
each entry here names its source in the schema comment as well, and anything
that is sent is measured on hardware first.

The list is generated, not kept by hand: `tools/qmi-libqmi-audit.sh` in
wwand-ims dumps every schema, compares each message and TLV id with libqmi
1.38, and looks each one up in a vendor IDL dump. Rerun it after a schema
change; a new row without an entry here is a gap. The plugin's own entries
(wwand-ims `plugins/ims.uc`) are listed in wwand-ims
`docs/qmi-beyond-libqmi.md`.

## Sources

| Key | Source |
|---|---|
| **IDL-8T** | The Qualcomm IDL encoder tables in a shipping RIL: OnePlus 8T (KB2003, OxygenOS 14, SM8250/X55), `/vendor/lib64/libqmiservices.so` (md5 a062f6bae6caa55fac574e7c8e07e8b1), decoded with wwand-ims `tools/qmi-idl-dump.py` on 2026-11-15. The dump is wwand-ims `research/op8t-20261113/idl-libqmiservices.json`. It gives message ids, TLV ids and wire widths, no names. |
| **IDL-OP13** | The Qualcomm IDL of a newer RIL: OnePlus 13 vendor tree (NAS IDL 1.0x190), the service headers and encoder tables (`network_access_service_v01`, `wireless_data_service_v01`), read 2026-11-16 from the private reference library (`qcril-ref/idl`). It gives names, TLV ids and wire widths. |
| **IDL-8996** | Qualcomm's msm8996 QMI service sources (`wireless_data_service_v01.c` and others) and `dsi_netctrl`, in the reference library under `~/projects/wwand-ims-docs/library`. They give names and widths. |
| **IDL-RG650E** | The request and indication tables in the RG650E's own apps side (`libqmiservices.so`, `libdsi_netctrl.so`), from earlier RE rounds (chateau_5g notes). |
| **Gobi** | Qualcomm's Gobi API, 2013-07-31 (`QMIEnum.h`, `GobiConnectionMgmtAPIStructs.h`). It is old, so its value tables are not trusted for current firmware. |
| **Kernel** | The GPL-2.0 Linux QMI sources (`thermal_mitigation_device_service_v01.{h,c}`). |
| **HW** | Measured on a named modem. |

## Messages and TLVs

| Service | Message | Id | Not in libqmi | Wire | Sources | Used |
|---|---|---|---|---|---|---|
| WDS 0x01 | Get Current Settings | 0x002D | resp TLV **0x2E** PCSCF IPv6 Address List | u8 count + count × 16-byte address, network order (max 20) | IDL-8T (type 59 = list of type 58, 16 bytes), IDL-8996 (`pcscf_ipv6_server_addr_list`), dsi_netctrl (asks request bit 11 on the IPv6 client, reads 0x2E). **HW** RG650E 2026-11-15: the same two addresses, in the same order, as `AT+CGCONTRDP` | read on an `ims` interface; no separate request bit (1 << 17 is Technology Name) |
| WDS 0x01 | Get Delegated IPv6 Prefix | 0x00AC | whole message | req 0x01 16-byte address; resp 0x10 address + prefix length | IDL-RG650E, IDL-8T; **HW** RG650E, RM520N-GL | sent |
| NAS 0x03 | Set System Selection Preference | 0x0033 | req TLV 0x2E nr5g_disable_mode | u32 | IDL-8T; **HW** RG502Q-EA, RG650E-EU | sent when configured |
| NAS 0x03 | Get System Selection Preference | 0x0034 | resp TLV 0x2B nr5g_disable_mode | u32 | IDL-8T; **HW** as above | read |
| NAS 0x03 | Register Indications | 0x0003 | req TLV 0x28 LTE CA, 0x54 LTE CA aggregated, 0x5D NR BWP info, 0x62 NR cell frequency info, 0x66 NR CA signal info (0x21 Network Reject is libqmi's) | u8 each | IDL-OP13; **HW** 2026-11-16, each alone in a request: 0x28 accepted by the RG502Q-EA, EG06-E, BG96, BM806U-E1 and RG650E-EU; 0x54, 0x5D, 0x62, 0x66 by the RG650E-EU, refused with MissingArgument by the other four | sent, one request per TLV |
| NAS 0x03 | Network Reject indication | 0x0068 | ind TLV 0x12 CIoT mode, 0x14 attempt counter at maximum, 0x15 procedure type (0x01-0x03, 0x10, 0x11 are libqmi's) | u32, u8, u32 | IDL-OP13. Not yet seen on a modem here: nothing was refused while a probe listened | read into `registration_detail` and the log |
| NAS 0x03 | LTE CA indications | 0x0082, 0x00C3, 0x0132 | whole messages | 0x0082: 0x01 { pci u16, earfcn u16, state u32 }, 0x14 aggregated DL bandwidth u16, 0x15 SCells u16; 0x00C3: 0x10, 0x11 u16; 0x0132: 0x12 u16 | IDL-OP13. **HW** RG650E-EU 2026-11-16: all three arrive, the aggregated bandwidth reading 400, 300, 200, 100 as SCells went — not MHz, unit not established. The SCell layout is the one Get LTE Cphy CA Info answers in 0x10 (RG502Q-EA, 8 bytes) | a trigger to read the carrier list again; content only in the debug log |
| NAS 0x03 | NR CA signal info / serving cell frequency info / RRC BWP info indications | 0x015B, 0x0153, 0x013F | whole messages | not decoded (0x015B: 0x10 u8) | IDL-OP13. Registration accepted by the RG650E-EU only; not seen (no NR service on a test modem) | a trigger to read the carrier list again |
| NAS 0x03 | Set / Get Cell Lock Config | 0x00AF / 0x00D7 | whole messages | set 0x01 u8-counted { pci u16, freq u16 }, 0x10 enforce u8; get resp 0x10 the same list | IDL-OP13 (marked deprecated there). **HW** 2026-11-17: answered by the RG502Q-EA (lock to 6300/409 set, read back, released with an empty list; the same state reads back over AT+QNWLOCK, and survives a modem reset with "save_ctrl" 1,1) and the RG650E-EU (read); InvalidQmiCommand on the EG06-E, BG96, BM806U-E1, E392 | `cell_lock.uc` dialect `qmi`, when its u32 pair is refused |
| NAS 0x03 | Set / Get Cell Config | 0x00D8 / 0x015A | whole messages | as above with freq **u32** | IDL-OP13. **HW** 2026-11-17: RG650E-EU (lock to 6300/334 set with enforce 1, data kept, read back by both gets and AT+QNWLOCK, released); InvalidQmiCommand on the RG502Q-EA and the four above | `cell_lock.uc` dialect `qmi` |
| NAS 0x03 | Set / Get NR5G Cell Config | 0x010E / 0x010F | whole messages | set 0x01 type u32 (0 one cell, 1 ARFCN list, 2 unlock, 3 several PCIs), 0x10 { pci u16, scs u32 (0=15 … 4=240 kHz), arfcn u32, band mask 8 × u64, bit n-1 = band n }; get resp 0x10 type, 0x11 the cell | IDL-OP13. **HW** 2026-11-17 RG502Q-EA: a lock to n78 / 636666 / 30 kHz / PCI 100 reads back over AT as "common/5g",100,636666,30,78, LTE data kept, released with type 2; type 2 with nothing locked is error 3 (Internal). The RG650E-EU answers the get with 94 (NotSupported) | `cell_lock.uc` dialect `qmi` |
| WDS 0x01 | Indication Register | 0x0003 | req TLV 0x22 LTE attach parameters, 0x25 RAB reject, 0x33 LTE attach failure, 0x3F IPv6 prefix update (libqmi has 0x12, 0x19) | u8 each | IDL-OP13. **HW** 2026-11-16: the RG502Q-EA and EG06-E answer success for these and for a TLV no IDL has (0x7E), so the answer proves nothing | sent in one request |
| WDS 0x01 | Get LTE Attach Parameters | 0x0085 | resp TLV 0x13 IPv4 address | u32, as Get Current Settings | **HW** RG502Q-EA 2026-11-16: equal to the address the indication gave for the same attach | read |
| WDS 0x01 | LTE Attach Parameters indication | 0x00C6 | whole message | 0x01 valid u8, 0x10 APN (bare characters), 0x11 IP type u8 (0 IPv4, 1 IPv6, 2 IPv4v6), 0x12 IPv4 address; 0x13 gateway, 0x14 netmask, 0x15/0x16 IPv6 address + length | IDL-OP13; **HW** RG502Q-EA 2026-11-16 over a radio cycle: 0x01 = 0 alone on the detach, then 0x01 0x10 0x11 0x12. 0x13-0x16 not seen. BG96 and BM806U-E1 sent none in 150 s | read into `attach_info` |
| WDS 0x01 | 3GPP RAB Reject indication | 0x00CF | whole message | 0x01 cause u32 (its own list, `wds.uc RAB_REJECT_CAUSE`) | IDL-OP13. Not seen. Its read, 0x00CE, answers on the RG502Q-EA and RG650E-EU (0x10 = 0) and is InvalidQmiCommand on the EG06-E, BG96, BM806U-E1 | logged only |
| WDS 0x01 | LTE Attach Failure Info indication | 0x0103 | whole message | 0x01 PLMN 3 BCD bytes, 0x02 { type u16, reason u16 } | IDL-OP13; the reason widths are assumed from libqmi's verbose call end reason. Not seen | logged, `attach_info.failure` |
| WDS 0x01 | IPv6 Prefix Update indication | 0x0134 | whole message | 0x01 { 16-byte prefix, length u8 }, 0x02 type u32, 0x03 status u32 | IDL-OP13. Not seen. Its read, 0x0133, exists on the RG650E-EU only (MissingArgument without a prefix) | logged only |
| UIM 0x0B | Write Transparent | 0x0022 | whole message | 0x01 session, 0x02 file { u16 id, path }, 0x03 { u16 offset, data with a u16 count }; resp 0x10 { sw1, sw2 } | QMI UIM spec (mirrors Read Transparent), IDL-8T; **HW** RG650E | sent |
| UIM 0x0B | Send APDU | 0x003B | req 0x12 long_request, resp 0x11 long_response | 0x11 = { u16 total, u32 token } | IDL-8T | 0x11 read; 0x12 declared, not sent |
| UIM 0x0B | Send APDU indication | 0x003B | ind 0x01 chunk | { u32 token, u16 total, u16 offset, u8 data[] with a **u16** count (max 1024) } | IDL-8T | read |
| UIM 0x0B | Refresh Register All | 0x0044 | req 0x10 vote_for_init | u8 | IDL-8T, IDL-RG650E | sent with the Refresh OK handler |
| UIM 0x0B | Refresh OK | 0x002B | whole message | 0x01 session, 0x02 ok_to_refresh u8 | Gobi (id 43), IDL-RG650E, IDL-8T | sent |
| UIM 0x0B | Refresh indication | 0x0033 | ind 0x11 enforcement | **u64** | IDL-8T, IDL-RG650E | read |
| UIM 0x0B | Get Profile Info | 0x0064 | whole message | req 0x01 slot e8, 0x02 profile id **u32** | IDL-8T, IDL-RG650E | read |
| UIM 0x0B | Get EID | 0x0065 | whole message | req 0x01 slot e8; resp 0x10 u8[≤16] | IDL-8T, IDL-RG650E | read |
| UIM 0x0B | Session Closed indication | 0x0043 | whole message | 0x13 cause **u32** | IDL-8T, IDL-RG650E | read |
| UIM 0x0B | SIM Busy Status indication | 0x004A | whole message | 0x10 u8 per slot | IDL-8T, IDL-RG650E | read |
| UIM 0x0B | Recovery indication | 0x0050 | whole message | 0x01 slot e8 | IDL-8T, IDL-RG650E | read |
| UIM 0x0B | Card Activation Status indication | 0x0055 | whole message | 0x01 slot e8, 0x02 u32 | IDL-8T, IDL-RG650E | read |
| WDA 0x1A | Set Data Format | 0x0020 | req 0x18 qos header format, 0x19 DL minimum padding, 0x1A flow control | u32, u32, u8 | IDL-8T, IDL-8996 (2026-11-15; before that unverified, and 0x18 was wrongly declared u8) | declared, not sent |
| CAT 0x0A | Set / Get Configuration | 0x002D / 0x002E | whole service (libqmi has no CAT) | 0x01/0x10 mode **e8**, 0x10/0x11 terminal profile u8[≤80] | ofono (service id), Gobi (message ids), IDL-8T | only with `option cat_mode` |
| TMD 0x18 | Mitigation device list / level / notifications | 0x0020-0x0025 | whole service (libqmi knows only its id) | see `codec/schema/tmd.uc` | Kernel (no vendor source needed) | read |

Every row's TLV ids are in IDL-8T, apart from TMD, which the 8T's library does
not carry, and the rows sourced IDL-OP13, which were not looked up there. The widths checked against IDL-8T (every row above) match the schemas,
with one exception that is now fixed (WDA 0x18).

## Values and bits

| Where | Not in libqmi | Source |
|---|---|---|
| UIM Event Registration 0x002E mask | bits 3 and up (libqmi has 0, 1, 2, 4) | IDL-RG650E; only the four that name a SIM failure are armed |
| WDS call end reason type (`callend.uc`) | 12 = handoff (libqmi's enum stops at 9) | emitted by modems on an inter-RAT handoff |
