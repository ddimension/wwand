# Observing a stock RIL — public evidence for QMI behaviour

wwand and the wwand-ims plugin speak QMI to Qualcomm modems. The public
definition of that surface (libqmi) stops where the vendor services
begin: the IMS Settings service, vendor NAS messages, voice service
details. This page documents how we close that gap **by observation of a
stock device** instead of consulting vendor source trees — the method
behind the evidence in the wwand-ims research folder.

## The method

A stock Android phone with a Qualcomm SoC runs the real Qualcomm RIL
(qcril). With root only for access (logcat buffers, props), we record
what that RIL **actually sends**, on our own test device:

1. **Continuous `logcat -b radio` (and `-b main`) on the workstation**,
   in a restart loop across reboots, SIM swaps and toggles — no buffer
   rotation loss.
2. **qcril verbose logging** (`persist.vendor.radio.adb_log_on=1` +
   a qcrild restart). The RIL then logs its QMI activity with
   file:line — message names (`qcril_qmi_imss_send_set_ims_service_
   enable_config_req`), the config items it sets, call-type values,
   call states and modes, handover events.
3. **Triggers** that make the RIL act: SIM bring-up, airplane-mode
   cycles, eSIM re-activation, the VoWiFi toggle, real calls.

The result is black-box behavioural evidence: which QMI messages a
shipping RIL sends, with which fields and values, in which order — and
what the modem does without them (the default state).

## What it is good for

- Anchoring plugin schemas to observed behaviour where libqmi has no
  definition (the wwand-ims `SET_IMS_SERVICE_ENABLE_CONFIG` TLVs, the
  dial call TLVs, the voice bind question).
- Defaults and state machines: the modem never enables VoLTE by itself;
  the CC_IN_PROGRESS/mode-6 state is a normal intermediate step.
- Handover and WFC flows (a full LTE→WLAN Rove-In was captured).
- Clean-room documentation sources: the same sequences feed the
  wwand-ims-docs call-flow chapters without vendor trees.

## What it is not

- Not a specification: it shows one RIL revision's behaviour, not the
  protocol. TLV numbering still needs the public IDL (libqmi) or
  measured round-trips.
- Not raw QMI bytes: the Android diag path (diag_mdlog masks) does not
  deliver on OOS 14 yet — the logcat evidence is message-level, not
  wire-level.
- It needs a rooted Qualcomm device (Snapdragon; Exynos/MediaTek RILs
  are different stacks).

## The reference setup

Device, rooting path, capture recipes, working triggers, evidence grep
patterns and the masking rules are documented step by step in the
wwand-ims repo: `research/op8t-20261113/HOWTO.md` (with the findings in
`FINDINGS.md` and the raw logs alongside).

## Rules

- Every committed capture is masked first: phone numbers, IMSIs,
  ICCIDs, EIDs, WLAN SSIDs (pattern list in the HOWTO).
- Findings cite the log line + timestamp; the raw file is always
  committed alongside, so a claim can be re-checked.
- A captured behaviour replaces a guess, not a public definition — where
  libqmi has the message, libqmi stays the anchor.
