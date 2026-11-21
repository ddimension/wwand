# The wwand-ims plugin — VoLTE / IMS

**wwand-ims** adds VoLTE for a plain SIP phone (or a PBX trunk) on the LAN,
through a cellular modem wwand manages. It lives in its own repository
([ddimension/wwand-ims](https://github.com/ddimension/wwand-ims)) and is **not
for upstream** — the wwand core carries no voice code. It is documented here
because it is the plugin with the deepest core integration: it borrows the USIM
over wwand's APDU channel, runs IPsec through `wwand_io.so`'s `xfrm`
sub-namespace, and reads the P-CSCF out of wwand's QMI context status. For the
generic plugin contract see [extending.md "A feature in its own package:
plugins"](extending.md#a-feature-in-its-own-package-plugins) and
[reference.md "Plugins"](reference.md).

## Shape

Three parts in `wwand-ims` (two of them ordinary wwand plugins), and two
optional packages:

| Part | Where | What |
|---|---|---|
| `plugins/ims.uc` | daemon plugin, `/usr/share/ucode/wwand/plugins/ims.uc` | the **modem-IMS backend**: IMS registration/service state and call control over QMI (IMSA, IMS, NAS, Voice). ubus `modem_plugin`. |
| `ctl/ims.uc` | wwandctl command, `/usr/share/ucode/wwand/ctl/ims.uc` | `wwandctl ims check\|fix\|setup\|mbn\|call` — prepares the modem and the router. |
| `sipd` | own procd daemon, `/usr/share/wwand-ims/` | SIP registrar + B2BUA for LAN phones / a PBX trunk, and (backend `ue`) **the router's own IMS UE**. |
| `vowifi/` | package `wwand-ims-vowifi` | **VoWiFi**: the UE's IMS through an IKEv2/EAP-AKA tunnel to the operator's ePDG over the fixed-line WAN instead of the IMS PDN (strongSwan's charon, driven over vici). |
| `luci/` | package `luci-app-wwand-ims` | Status → VoLTE (registration, phones, the running call, the last ten calls, the VoWiFi tunnel) and Network → VoLTE (`/etc/config/wwand_ims`, operator profiles; *Clone current settings* makes a new profile from what the modem and the network use now). |

Two ways to carry a call, chosen per modem by `wwand_ims.ims_modem.backend`:

- **`ue`** (the current direction) — the **router** is the IMS UE. sipd
  registers over the modem's IMS PDN (`line_ue.uc`: IMS-AKA through the card,
  sec-agree ESP, SIP), the modem's own IMS is switched off, and RTP is relayed
  1:1 to the LAN. Needs the kernel IPsec + VRF prerequisites below.
- **`qmi`** — the **modem's** own IMS registers and carries the call; the
  `ims.uc` plugin drives its call control over QMI and sipd bridges SIP/RTP to
  the LAN. No IPsec on the router. Works where the module does not refuse MO
  calls internally.

## Prerequisites

- **Modem** with an IMS PDN and USIM APDU access (QMI UIM, MBIM UICC, or AT;
  QMI Send APDU alone is enough — a Huawei E392 without logical channel
  messages and without QMAP registers and carries calls as the IMS-only modem
  next to a data modem).
  On a Quectel data module VoLTE needs **LTE FGI bits 3 and 7** on and the
  **modem's own IMS off** — `wwandctl ims fix` does both (FGI via
  `AT+QNWCFG="lte_fgi_fdd"`, or via a patched carrier MBN, see below).
  Two ways to set the FGIs, check with `wwandctl ims check` (it prints
  `missing 3, 7` when they are off):
  - **`wwandctl ims fix`** — on a Quectel module whose firmware answers
    `AT+QNWCFG="lte_fgi_fdd"`. **Not on the RG650E:** the command is accepted
    and reads back with 3 and 7, but the UE capability sent over the air keeps
    the MBN's FGIs (airplane cycle), and a modem reset reloads the MBN and
    drops the AT value (HW-measured with a NAS/RRC trace, 2026-11-15). There,
    `ims check` can say "on" while the network still sees them off.
  - **A patched carrier MBN** (`wwandctl ims mbn patch --base FILE --upload`) —
    the persistent way, and the only one where the AT knob is missing. The
    base MBN comes from the modem's firmware image, see "Getting the base
    MBN" below.

  The carrier config follows the SIM: another SIM (or a remote SIM over
  wwand-rsim) can make the modem select another MBN, without the FGIs. Run
  `wwandctl ims check` after every SIM change.

  **Getting the base MBN.** Downloading a stored config from the modem (QMI
  PDC "Get Config") is buggy on USB modems: the modem sends 4096-byte frames
  in 4133-byte messages, and the kernel's `qmi_wwan` control channel
  (cdc-wdm) takes 4096, so every frame arrives cut. `mbn patch` without
  `--base` therefore fails there. The same request works where the control
  channel is not USB (measured over QRTR on a phone and on the RG650E's own
  Linux side). Take the base from the firmware instead:
  - **From the firmware package.** The modem image (`NON-HLOS.bin`, a FAT
    image) carries every carrier config as
    `image/modem_pr/mcfg/configs/mcfg_sw/generic/<region>/<operator>/…/mcfg_sw.mbn`:
    `7z x NON-HLOS.bin 'image/modem_pr/mcfg/configs/mcfg_sw/*'`.
  - **From a module with adb** (Linux on the module, e.g. RG650E): the same
    tree is mounted at `/firmware/image/modem_pr/mcfg/`; `adb pull` the file.
    Configs that were uploaded later are kept zlib-compressed under
    `/data/persist/rfs/mdm/mpss/mcfg_sw<hash>`. They are not in the modem EFS,
    so the DIAG/EFS route does not reach them.
  - **Which file is which:** `wwandctl ims mbn patch --base FILE` prints the
    name and item count; `wwandctl ims mbn list` shows the names the modem
    holds. Tools to look into an MBN, or to compare several:
    [sbaresearch/mbn-mcfg-tools](https://github.com/sbaresearch/mbn-mcfg-tools)
    (Python; its `FORMAT.md` documents the container),
    [Biktorgj/mcfg_tools](https://github.com/Biktorgj/mcfg_tools) (C,
    unpack/pack) and
    [fenrir-naru/mbn_utils](https://github.com/fenrir-naru/mbn_utils) (Ruby,
    items as text). For modem-side access:
    [bkerler/edl](https://github.com/bkerler/edl) (DIAG and EDL; packaged in
    the [ddimension feed](https://github.com/ddimension/openwrt-repo) as
    `python3-edlclient`, next to `qfirehose`).
- **wwand + a control backend** (`wwand-qmi`), with a `wwand_io.so` that has
  the `xfrm` sub-namespace (wwand ≥ the NETLINK_XFRM merge).
- **Kernel IPsec** — for backend `ue` only. The SAs go in over NETLINK_XFRM, so
  the kernel needs `CONFIG_XFRM_USER` (`xfrm_user.ko`), `CONFIG_INET_ESP`
  (`esp4.ko`) and `CONFIG_INET6_ESP` (`esp6.ko`). Selecting `wwand-ims` in an
  image build pulls `kmod-ipsec` / `kmod-ipsec4` / `kmod-ipsec6`, which force
  those symbols. **A prebuilt image whose kernel lacks them fails** — `ip xfrm`
  returns *"Cannot open netlink socket: Protocol not supported"* and the
  kmod-ipsec apks install empty. `CONFIG_XFRM=y` alone is not enough.
- **VRF** — `kmod-vrf` (netifd builds the `type vrf` device) and `ip-full`
  (the l3mdev FIB rules the hotplug re-adds are iproute2-only).
- **Packages** the feed pulls (`DEPENDS`): `+wwand +kmod-ipsec +kmod-ipsec4
  +kmod-ipsec6 +kmod-vrf +ip-full +ucode-mod-{fs,uloop,ubus,socket,uci,digest,struct}`.
  It is noarch (`PKGARCH:=all`): pure ucode + scripts.

## Setup

`wwandctl ims` drives the whole thing. The short path:

```sh
# 1. the modem side (FGI on, modem's own IMS off; resets the modem if needed)
wwandctl ims fix
#    RG650E: the AT value never reaches the radio (see Prerequisites) —
wwandctl ims mbn patch --base FILE --upload   # FILE: the MBN from the firmware image

# 2. are we ready?  (modem + an IMS PDN interface)
wwandctl ims check

# 3. the router side: writes the IMS PDN interface, its VRF, the firewall zone
#    + ESP/SIP/RTP/ICMP rules, the l3mdev hotplug, and sipd's `ue` line.
#    A dry run without --apply.
wwandctl ims setup --apply               # sections that differ: add --force

# 4. the SIP side: set the phone/PBX password and where sipd listens
uci set wwand_ims.@extension[0].password='…'
uci set wwand_ims.main.listen='lan'      # a network interface, or an address
uci commit wwand_ims

# 5. bring it up (network restart detached when over ssh — it drops the link)
setsid /etc/init.d/network restart
/etc/init.d/firewall reload
/etc/init.d/wwand-ims-sipd enable
/etc/init.d/wwand-ims-sipd restart

# 6. verify
wwandctl ims check
wwandctl status                          # look for the "IMS UE" row
```

The operator settings (APN, PDP type, auth, codecs, IPsec algorithms, timers)
live in profiles in `/etc/config/wwand_ims`, selected by SIM IMSI/ICCID prefix
— a new IoT operator is a new profile, not new code. The shipped
`/etc/config/wwand_ims` is a documented example (conffile, kept across
sysupgrade). The IMS PDN network/firewall that `setup` writes is also available
to merge by hand as `ims-network.example`.

### VoWiFi (wwand-ims-vowifi)

VoWiFi takes the router's IMS line over the internet (fixed line, Wi-Fi
uplink, anything) instead of over the modem's IMS PDN. The router builds an
IPsec tunnel to the operator's ePDG; the modem only lends the SIM for the
login. Useful where the mobile signal is weak, or when the modem's own
VoLTE does not work.

**Quick start**

```sh
apk add wwand-ims-vowifi                    # pulls strongSwan with what it needs
uci set wwand_ims.@ims_modem[0].access='vowifi'
uci commit wwand_ims
wwandctl ims setup --apply                  # the ePDG settings from the SIM's carrier config into its profile
setsid /etc/init.d/network restart          # detached when over ssh
/etc/init.d/firewall reload
/etc/init.d/wwand-ims-sipd restart
wwandctl status                             # see below
```

When it works, `wwandctl status` shows:

```
  IMS UE      registered +49… over VoWiFi via <P-CSCF>
  VoWiFi      up to epdg.epc.mnc…pub.3gppnetwork.org, inner <address>, 2 P-CSCF
```

Back to VoLTE: `access 'pdn'` (or delete the option) and restart sipd.

**Operator settings** come from the carrier config of the SIM (the modem's
own Wi-Fi-calling settings in its MBN, read by `wwandctl ims setup`) into
the SIM's operator profile. Normally nothing needs to be set. To change one,
set it in the profile (LuCI: Network → VoLTE → Operator profiles → VoWiFi);
a value you set is never overwritten:

| Option | What | Default |
|---|---|---|
| `vowifi_epdg` | the ePDG's name | `epdg.epc.mnc<MNC>.mcc<MCC>.pub.3gppnetwork.org` from the SIM |
| `vowifi_apn` | sent as the tunnel's responder identity | `ims` (`%any`: none) |
| `vowifi_proposals`, `vowifi_esp_proposals` | IKE / ESP algorithms (strongSwan notation) | from the carrier config, then strongSwan's |
| `vowifi_rekey_s`, `vowifi_esp_rekey_s`, `vowifi_dpd_s` | rekeying, dead peer detection | from the carrier config; else no rekeying, DPD 60 s |
| `vowifi_remote_auth` | how the ePDG proves itself | `eap-aka` (EAP only; `pubkey`: certificate) |

**Tested** (NR7101, RG502Q, 2026-11-21):

| Operator | Result |
|---|---|
| Telekom DE | registers; incoming calls with audio both ways |
| Vodafone DE | registers (needs the strongSwan plugin `epdg-idr` from this feed, pulled in by the package); calls not tried yet |

Outgoing calls over VoWiFi are not measured yet.

**When it does not come up**

- `wwandctl status`: the `VoWiFi` row says `connecting`, or `down` with the
  reason and the number of failed attempts. The tunnel is retried by itself
  (5 s, then up to every 60 s), also after a restart or crash of strongSwan.
- More detail: `uci set wwand_ims.@ims_modem[0].vowifi_loglevel='2'`, restart
  sipd, then `logread -e wwand-ims-sipd` shows every step of the tunnel setup
  (`charon[…]` lines).
- See *Common failures* below for the known cases.

**How it works** (for the curious): sipd drives strongSwan's charon only
over its control socket (vici) — nothing goes into `swanctl.conf`, other
IPsec connections of the router are untouched. The SIM login (EAP-AKA) runs
on the modem's SIM through wwand (strongSwan plugin `ext-aka`). The ePDG
answers with an identity of its own; the plugin `epdg-idr` lets charon
accept it. netifd sets up the router side with two interfaces sipd creates
at run time and removes when it stops (no sections in
`/etc/config/network`): the tunnel interface `imswifi0` (`proto xfrm`, in
the firewall zone `ims` by itself) and `wwvowifi` (`proto wwandvowifi`),
which takes the tunnel's address and puts the routes into table 31 (no
VRF: netifd 25.12 turns IPv6 off on VRF ports). Only sipd brings a dropped
tunnel back (strongSwan's own restart is off), also after a network
restart. On MT7621 boards sipd unloads the
`crypto_hw_eip93` driver when it cannot do the IMS encryption (see *Common
failures*).

### SMS over IP

`ims_modem` option `smsip '1'` (off by default) registers the UE for SMS
(TS 24.341). An incoming SMS is written into the modem's own store (option
`sms_storage` `ME`/`SM`) and is then an ordinary SMS for wwand
(`wwandctl sms`, the LuCI SMS list, the `sms` event); `wwand modem_sms_send`
goes over IMS while the UE is registered with `smsip`. With one number on
several SIMs the network may deliver to the router instead of the phone.
Profile options `sms_smsc`, `sms_psi`.

## Usage

### A LAN SIP phone

Point the phone at sipd (the `sip_gateway` address, port 5060) with an
`extension`'s username/password. With backend `ue` sipd relays the SDP, so the
phone must offer **AMR-WB or AMR** (no transcoding). Dial E.164 with `+` — the
UE refuses national numbers.

### An Asterisk trunk

sipd is set up like a SIP provider: Asterisk registers at sipd, outgoing calls
go over the endpoint, incoming ones hit the registered contact. HW-tested with
Asterisk 20 (`codec_amr`, `allow=amrwb,amr`). The full `pjsip.conf` /
`extensions.conf` is `asterisk-pjsip.example` in the plugin repo; the matching
router side is an `extension` with the same username/password and a
`sip_gateway` listening on the address Asterisk registers to.

The called number is in the INVITE's `To` (the network's
`P-Called-Party-ID`), the caller's in `From` (`P-Asserted-Identity`).

### Forwarded calls

A call forwarded to this number (e.g. a landline diverted to the mobile)
reaches the LAN with the network's **`History-Info`** as it came (RFC 7044)
and **`Diversion`** headers made from it (RFC 5806: the diverting number,
`reason` from the RFC 4458 cause — `unconditional`, `user-busy`,
`no-answer`, `deflection`, `unavailable`, `unknown`; the latest diversion
first), or the network's own `Diversion` when it sends one. In Asterisk:
`${REDIRECTING(from-num)}`, `${REDIRECTING(reason)}`,
`${PJSIP_HEADER(read,History-Info)}`. Nothing is filtered — the network
leaves out what the subscriber may not see. `sip_gateway` option
`redirect_info '0'` turns it off.

### One number on several SIMs

With a MultiSIM number the network sends one INVITE per device. A phone in
idle needs a few seconds of paging; if the router's 180 comes first, the
network does not alert the phone. sipd therefore holds its 180 back
(profile option `alert_delay_ms`, default **4500**; the LAN phone rings at
once). More than about 5.9 s and Telekom cancels the router's leg
(`CC_NOT_REACHABLE`) — sipd warns above 5 s; `0` sends the 180 at once.
Whoever answers first takes the call; the other leg gets a CANCEL with
`Reason: …"Call completed elsewhere"`.

### A test call

```sh
wwandctl ims call +49…                     # one MO call from the router UE, echo on
wwandctl ims call +49… --no-echo --talk 20 # or --ring/--hold S, --pcscf ADDR
```

Runs the proven UE driver (`ims-register.uc`) for a single registration + call,
with the P-CSCF discovered over QMI. Stop sipd first (it holds the UE ports).

### The modem-IMS backend (backend `qmi`)

```sh
ubus call wwand modem_plugin '{"modem":"wwmodem0","plugin":"ims","op":"status"}'
#   op: status | calls | dial | answer | hangup   (dial: {"args":{"number":"+49…"}})
```

## Debugging

- **`wwandctl ims check`** — one line per requirement (FGI, modem IMS off,
  carrier MBN, IMS profile, IMS PDN interface up), with the fix hint for each.
- **`wwandctl status`** — the `IMS UE` row shows the router UE's registration
  (`registered <number> via <pcscf>`, or `down`/`registering`); the modem-IMS
  row shows next to it when that backend is on.
- **`logread -e wwand-ims-sipd`** — sipd logs to syslog at real severities under
  its own ident (not `daemon.err ucode[…]`). The `ue:` lines are its UE line.
- **ubus events** — the live state as it changes:
  - `wwand.ims.ue` `{ modem, state, impu, pcscf, calls, … }` — sipd's UE line
    (the heartbeat the `IMS UE` row reads).
  - `wwand.ims.call` `{ modem, calls:[…] }` and `wwand.ims.registration`
    `{ modem, status, voice }` — from the `ims.uc` plugin.

  `ubus listen wwand.ims.ue` to watch registration/call changes.
- **IPsec** — `ip xfrm state` / `ip xfrm policy`: a registered UE holds **four
  SAs** (the sec-agree association). None, or `spi … 0`, means the SA install
  failed (see below).
- **SIP trace** — `sip_gateway` option `sip_trace '/tmp/wwand-ims-sip.trace'`:
  every SIP message of both sides in full (identities and keys included —
  for debugging only).
- **VoWiFi** — `wwandctl status` has a `VoWiFi` row under `IMS UE` (up to
  the ePDG with the inner address and P-CSCFs, connecting, or down with
  the reason and the failed attempts). charon's log lines for the tunnel are in sipd's syslog
  (`charon: …`), the USIM authentication under ident `wwand-ims-vowifi`;
  `swanctl --list-sas`, `ifstatus wwvowifi`, `ip -6 route show table 31`.
- **Call list** — `ubus call wwand-ims calls`: the last ten calls with
  result, reason and RTP packet counts per direction.

### Common failures

| Symptom | Cause / fix |
|---|---|
| `ip xfrm`: *Protocol not supported*; empty kmod-ipsec apks | kernel without `XFRM_USER`/`INET_ESP`/`INET6_ESP` — rebuild the image with kmod-ipsec/4/6 (see Prerequisites). |
| IMS PDN won't come up: *interface in use, config matches an existing call (internal 241)* | the modem's own IMS holds the IMS profile — `wwandctl ims fix` (`QCFG ims` → 2 = off) + reset. |
| `xfrm: spi missing or reserved, sa out spi 0` | the P-CSCF returned a degenerate Security-Server (`spi-c=1; spi-s=0`) after an unclean de-register — a `CFUN 0/1` re-attach clears it; next REGISTER gets real SPIs. Always de-REGISTER cleanly (stop sipd) so SAs/policies do not leak. |
| REGISTER times out although the P-CSCF answers a ping; `ping -M do -s 1468` to it gets nothing, `-s 1448` does | the IMS PDN's path MTU is below 1500 and the network signals none, so the full-size first fragment of the REGISTER is lost — set `option mtu '1400'` on the IMS interface (measured: Vodafone GDSP, APN `ims.iot`). |
| IMS interface: `DEVICE_CLAIM_FAILED` on a modem without QMAP | such a modem has one netdev and carries one PDN: only one `proto wwand` interface may name it, and the IMS interface takes no `mux_id`. |
| `no SIP over TCP on port 5064: Address in use` | another UE (a leftover sipd, or `wwandctl ims call`) holds the protected ports — only one UE per IMS PDN. |
| REGISTER times out (`state: unprotected`) on an **IPv4** IMS PDN, though tcpdump shows the 401 on the IMS interface and on the VRF device | netifd's `<addr> dev <iface> scope link` host route displaces the kernel's `local` route for the /32 in the VRF table, so the reply is not delivered locally (no UDP counter moves). The `25-wwand-ims-l3mdev` hotplug re-adds `local <addr>` on every ifup; check `ip route show table <vrf table>` for it. No `ip_nonlocal_bind` / `udp_l3mdev_accept` sysctl is needed. |
| Call ends right after the 183 with `503`, `Reason: … ASR: BEARER_RELEASED` or `ASR: INSUFFICIENT_SERVER_RESOURCES` (which one depends on the P-CSCF site) | the voice bearer (QCI 1) could not be set up. Seen with LTE FGI 3 and 7 missing in the UE capability: no dedicated-bearer request reaches the modem at all. Set the FGIs (Prerequisites); typical after a SIM change that switched the carrier MBN. |
| VoWiFi: tunnel up, REGISTER times out, `ICMP port unreachable` back from the router | `imswifi0` is not in the `ims` firewall zone: check `ifstatus imswifi0` (`data.zone`) and `/etc/init.d/firewall reload`; a static section `imswifi0` from an older setup needs `option zone 'ims'` or `list network 'imswifi0'` in the zone. |
| VoWiFi: `send(): Network unreachable`, no IPv6 address on `imswifi0` (`disable_ipv6 1`) | the XFRM interface is a port of a VRF: netifd 25.12 turns IPv6 off there. Remove the VRF for the tunnel (the current `setup` writes none). |
| VoWiFi: `constraint check failed: identity 'ims' … required, not matched by 'epdg…'` | the ePDG answers with its own identity and the strongSwan plugin `epdg-idr` is missing or not on: install `strongswan-mod-epdg-idr` (the package pulls it), restart strongSwan (`/etc/init.d/swanctl restart`). `… requires public key authentication`: set `vowifi_remote_auth 'eap-aka'`. |
| VoWiFi: `EAP method not supported` from charon | `strongswan-mod-fips-prf` missing (EAP-AKA needs it). |
| `registration failed: … xfrm … kernel: Invalid argument … sa out` with an operator that wants `ealg=aes-cbc` (Vodafone DE), MT7621 board | the EIP-93 crypto driver (`crypto_hw_eip93`) rejects the keys of `authenc(hmac(sha1),cbc(aes))`. sipd unloads it by itself (log: `kernel module crypto_hw_eip93 unloaded`), the kernel's software crypto takes over; it comes back at boot and is unloaded again. A driver fix is a TODO. |
| MultiSIM: the phone rings only with its display on | the router's 180 came before the phone was paged — `alert_delay_ms` (default 4500). |
| `IMS UE  down` though sipd runs | the IMS PDN (wwims) is down or re-attaching, so the UE de-registered — check `wwandctl status` for wwims `CONNECTED` and the P-CSCF in `status.contexts.wwims`. |

## How it works

The design, phases and operator-profile mapping are in the plugin repo's
`docs/design.md`; the QMI ids it uses beyond libqmi 1.38 (with source and
measurement) are in its `docs/qmi-beyond-libqmi.md`.
