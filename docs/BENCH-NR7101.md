# NR7101 bench integration notes (Amperstrand)

This branch (`feat/nr7101-rg502q`) carries the RG502Q-EA quirk patch
(GET_VERSION_INFO best-effort; see the commit message for the evidence
chain) plus these deployment learnings from the bench (2026-11-03/04):

## Deployment on the minimal 25.12.6 SDK
Full procedure: conwrt-bench/docs/nr7101/NR7101-WWAND-SDK-BUILD.md.
Key points: host ucode must match the target runtime commit
(25.12.6 = 85922056); json-c and libucode cross-built into SDK
staging; the final apk dependency check fails benignly — deploy the
staged tree; ship libucode.so.0 (the image's ucode is static) and the
wwand-qmi backend files alongside.

## Vendor-driver coexistence
Runs happily ON Quectel's qmi_wwan_q (the vendor kmod asserts DTR at
probe; stock qmi_wwan + this firmware yields a dead CTL channel for
every client tested). A hotplug script rebinds on USB add — the bind
race is real on every boot.

## Config pattern that works (per-ICCID credentials)
config wwand_modem + per-card wwand_sim sections (iccid → apn/name):
swap cards and the right credentials follow the card. Autosetup does
the right thing on a bare system.

## Field notes
- netifd interface state can zombie if a handover kills the proto
  mid-setup; recreate the interface (uci delete + re-add) or reboot.
- Quectel roaming profiles here disallow IPv6 PDN (WDS verbose reason
  210) — pdp_type ipv4 per wwand_sim silences the (already graceful)
  retry.
