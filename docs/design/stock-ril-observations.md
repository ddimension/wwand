# What a stock Qualcomm RIL does — observations for wwand

Black-box observation of a shipping Android device, as a second reference
next to libqmi. It shows what a vendor RIL actually sends a Qualcomm modem,
and in which order. Nothing here comes from vendor source code: the
evidence is logcat (radio and main buffers) and `dumpsys` output.

- **Device:** OnePlus 8T KB2003, OxygenOS 14 (Android 14, SDK 34),
  Snapdragon 865 with an X55 modem; rooted for `iptables` and `ip` only.
- **SIMs:** a physical congstar SIM on Telekom.de, `internet.v6.telekom`.
  The device's built-in eUICC holds no profile yet. The capture notes call
  the congstar card an eSIM; it is not.
- **Captures:** taken 2026-11-13; the logs are in ddimension/wwand-ims
  `research/op8t-20261113/` (personal data masked). The live reads were
  taken the same evening, 19:20–19:45 UTC.

## 1. Carrier configuration (MBN) is left to the modem

On bring-up and on SIM events the RIL only:
- registers for PDC indications (`qcril_qmi_register_pdc_indication`);
- keeps the ICCID per slot as "SIM info"
  (`qcril_qmi_pdc_set_sim_info`, file `/data/vendor/radio/iccid_N`);
- checks whether an MBN re-evaluation is due
  (`qcril_db_is_sw_mbn_reevaluation_needed`).

No PDC Set Selected Config or Activate Config was sent: not at boot, not on
a SIM swap, not on an eSIM disable/enable (radio-fullboot.log.gz,
radio-simswap-bringup.log.gz). The choice of carrier configuration is the
modem's automatic selection.

**For wwand:** this matches `carrier_config.uc`, which lists and selects
only on request and never loads or deletes. The modem's automatic choice is
the normal case; a manual selection is the exception.

## 2. SIM applications off and on, without a power cycle

Android's per-subscription switch (`setUiccApplicationsEnabled`) is not a
card power cycle. The RIL changes the card's provisioning session:
- `qcril_uim_fill_change_session_params` deactivates the GW session;
- libqmi 1.38 has the message as UIM Change Provisioning Session 0x0038;
- the modem answers with the UIM status change indication 0x0032.

The card stays powered. Timeline of one cycle (radio/main-fullboot,
19:08:33–19:08:44 UTC):

| t | event |
|---|---|
| 0 ms | applications off |
| +130 ms | IMS deregistered |
| +600 ms | data network disconnecting |
| +955 ms | disconnected; SIM `NOT_READY` |
| 0 ms | applications on (7.9 s later) |
| +377 ms | SIM `READY` |
| +985 ms | SIM `LOADED` |
| +2.16 s | data connecting; IMS registering |
| +2.46 s | data connected (IPv6) |
| +3.10 s | IMS registered |

What was switched here is a physical SIM's applications, not an eUICC
profile; the mechanism is the same for both.

**For wwand:** after an eSIM profile switch, `sim.uc` re-reads the card
with UIM Power Down/Up (0x0030/0x0031). The stock RIL's way of taking the
applications down and up is gentler: the card stays powered, and the whole
cycle takes about 3 s.

Not shown here: whether that is enough after a real LPA profile switch.
There the eUICC normally signals a REFRESH, and the capture holds no
profile switch. Worth a test on an eUICC modem before changing anything.

## 3. CLAT done by the modem

On `internet.v6.telekom` the data interface carries both families
(`rmnet_data3`, 19:43 UTC):
- **IPv6:** a /64 by router advertisement (SLAAC, privacy addresses).
- **IPv4:** `192.0.0.8/27`, gateway `192.0.0.7`, route MTU 1472.
  192.0.0.0/29 is the IPv4 service continuity prefix of RFC 7335. 1472 is
  1500 less the 28 bytes the IPv4-to-IPv6 translation adds.
- **Android's own CLAT:** `Nat464Xlat: <not started>`. The network
  already has IPv4, so the 464XLAT translation runs in the modem.

**For wwand:** that is what `option clat` asks the modem for (WDS profile
"CLAT Enabled", TLV 0xDE). Values to expect from the modem in that mode are
the address in 192.0.0.0/29, the gateway beside it, and an MTU of 28 below
the IPv6 one. A reference for checking what wwand hands netifd.

## 4. Cell broadcast (EU-Alert)

When the SIM is loaded (19:01:42 UTC) the RIL sends two WMS requests; the
modem answers both with no error:
1. Set Broadcast Config 0x003D with 11 message identifier ranges (3GPP TS
   23.041; libqmi 1.38 defines 0x003C, 0x003D and 0x003E Get Broadcast
   Config);
2. Set Broadcast Activation 0x003C, activate.

| Message ID | State on this SIM |
|---|---|
| 4355 | off |
| 4370 | on |
| 4372 | on |
| 4378 | on |
| 4380–4382 | off |
| 4383 | on |
| 4385 | on |
| 4391 | on |
| 4393–4395 | off |
| 4396–4397 | on |
| 4398–4399 | off |

**For wwand:** the WMS schema has no broadcast messages yet. With these
three from libqmi, a router could enable the warning channels and hand
received alerts on as a ubus event (and from there to LuCI, a LED, a
notification). The ranges come from the operator's carrier config. Without
an Android carrier config, the 23.041 alert range 4370–4399 is the
starting point. Not built; a candidate feature.

## 5. Data stall: detection and recovery

From `dumpsys` (19:20 UTC); the stall itself was not provoked to the end.
- **Detection (NetworkStack):** 5 consecutive DNS timeouts
  (`data_stall_consecutive_dns_timeout_threshold=5`), plus TCP failure
  rates. TCP is not polled in light doze.
- **Recovery (DataStallRecoveryManager):** five actions, 180 s apart
  (`DataStallRecoveryDelayMillisArray=[180000, 180000, 180000, 180000]`):
  1. get the data call list;
  2. clean up (tear the call down and set it up again);
  3. re-register (skipped on this carrier);
  4. radio restart;
  5. modem reset.

  `SkipRecoveryActionArray=[false, false, true, false, false]`.
- **Data setup retries (DataRetryManager):**
  - internet/IMS: 2.5 s, 3 s, 5 s, 10 s, … up to 30 min, at most 20 times;
  - a set of reject causes (ESM 8, 27–33, 35, 50, 51, …): 2.5 s, at most
    10 times.

**For wwand:** a comparison point for `recovery.uc`:
- wwand's ladder climbs by failure count: opmode cycle at 8, modem reset
  at 16, board power at 24.
- Android climbs by time: 3 min per step, with a data-call refresh and a
  plain reconnect before touching the radio.
- Neither is obviously better. Android's first two steps are cheap and
  have no wwand counterpart before the radio cycle.

## 6. The voice bearer of a VoLTE call stays in the modem

An MO call over IMS on Telekom.de (LTE band 20, EARFCN 6400), 2026-11-13,
19:57 UTC:

| t | event |
|---|---|
| 19:57:00.916 | call dialled |
| 19:57:01.091 | a new bearer on the IMS PDN (`handleDataBearerTypeChanged cid=0, bid=108`), 175 ms after the dial |
| 19:57:11 | call active |
| 19:57:25.9 | bearer allocations updated again after the hang-up |

While the call is active the framework shows `qosBearerSessions=[]` and
`defaultQos=null` for every data network, the IMS one included. The
dedicated bearer is created and used by the modem's IMS stack, and the
Android framework never sees its QoS.

**For wwand:** a modem doing VoLTE needs nothing from the host for the
voice bearer. If no such bearer appears (as with the Vodafone IoT SIM in
wwand-ims, where the IMS core aborts with an ASR), that is the network.

## 7. IPv6 to a tethered client: the /64 is shared

USB tethering from the same SIM (upstream `rmnet_data3`, downstream
`rndis0`), 2026-11-13, 20:00 UTC:

- **IPv6:** the downstream global address is in **the same /64** as the
  upstream one. The phone extends its mobile /64 onto the tethered link in
  the RFC 7278 way, with no prefix delegation, and forwards in BPF.
- **IPv4:** NAT to `192.168.210.92/24`. The upstream IPv4 is the modem
  CLAT's `192.0.0.0/27`, so a tethered client's IPv4 is translated twice:
  NAT44, then 464XLAT.

**For wwand:** the same choice as `option ipv6_pd` versus extending the
/64. A stock phone on a consumer SIM extends the /64, as there is no
delegated prefix to hand out.
