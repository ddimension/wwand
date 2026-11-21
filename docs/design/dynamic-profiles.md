# Dynamic profile handling — survey and plan

Status: the plan below is in the tree since 2026-11-20 (QMI): attach index
from the attach list, own profiles for mux 2+, the sweep. NCM is not part of it.
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

## Plan

1. **Attach from the list.** Read 0x0094 at init; the attach profile is
   `current[0]`, falling back to 1 where the firmware refuses the message. The
   attach owner dials that profile (the mux-1 coupling, with the index the
   modem names).
2. **Match or create for the other channels**, instead of index = mux_id:
   a profile wwand created for this interface (marked by name, e.g.
   `wwand:<iface>`) is reused and modified; else a profile with the same APN
   and PDP type that is neither the attach nor an IMS-family profile is used
   as it is; else one is created and marked. Unmarked profiles are never
   modified. `option profile` / `apn '#N'` stay the explicit override.
3. **Clean up** marked profiles whose interface is gone — the profile table
   is small (often 16–24) and lives in NV.

Open questions for stage 2: whether every firmware keeps the profile name
(the mark); a carrier configuration (MBN) switch can reset the table and the
marks with it; NCM has the same model over `+CGDCONT` cids, MBIM passes the
APN in the connect and is not affected.
