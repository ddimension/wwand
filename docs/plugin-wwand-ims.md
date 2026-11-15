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

Three parts, two of them ordinary wwand plugins:

| Part | Where | What |
|---|---|---|
| `plugins/ims.uc` | daemon plugin, `/usr/share/ucode/wwand/plugins/ims.uc` | the **modem-IMS backend**: IMS registration/service state and call control over QMI (IMSA, IMS, NAS, Voice). ubus `modem_plugin`. |
| `ctl/ims.uc` | wwandctl command, `/usr/share/ucode/wwand/ctl/ims.uc` | `wwandctl ims check\|fix\|setup\|mbn\|call` — prepares the modem and the router. |
| `sipd` | own procd daemon, `/usr/share/wwand-ims/` | SIP registrar + B2BUA for LAN phones / a PBX trunk, and (backend `ue`) **the router's own IMS UE**. |

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

- **Modem** with an IMS PDN and USIM APDU access (QMI UIM, MBIM UICC, or AT).
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
    the persistent way, and the only one where the AT knob is missing. Reading
    the active MBN back from the modem does not work over USB at present, so
    the base MBN has to be extracted from the modem's firmware package, patched
    and uploaded.

  The carrier config follows the SIM: another SIM (or a remote SIM over
  wwand-rsim) can make the modem select another MBN, without the FGIs. Run
  `wwandctl ims check` after every SIM change.
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
wwandctl ims mbn patch --base FILE --upload   # FILE: the MBN from the firmware package

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

### Common failures

| Symptom | Cause / fix |
|---|---|
| `ip xfrm`: *Protocol not supported*; empty kmod-ipsec apks | kernel without `XFRM_USER`/`INET_ESP`/`INET6_ESP` — rebuild the image with kmod-ipsec/4/6 (see Prerequisites). |
| IMS PDN won't come up: *interface in use, config matches an existing call (internal 241)* | the modem's own IMS holds the IMS profile — `wwandctl ims fix` (`QCFG ims` → 2 = off) + reset. |
| `xfrm: spi missing or reserved, sa out spi 0` | the P-CSCF returned a degenerate Security-Server (`spi-c=1; spi-s=0`) after an unclean de-register — a `CFUN 0/1` re-attach clears it; next REGISTER gets real SPIs. Always de-REGISTER cleanly (stop sipd) so SAs/policies do not leak. |
| `no SIP over TCP on port 5064: Address in use` | another UE (a leftover sipd, or `wwandctl ims call`) holds the protected ports — only one UE per IMS PDN. |
| REGISTER times out (`state: unprotected`) on an **IPv4** IMS PDN, though tcpdump shows the 401 on the IMS interface and on the VRF device | netifd's `<addr> dev <iface> scope link` host route displaces the kernel's `local` route for the /32 in the VRF table, so the reply is not delivered locally (no UDP counter moves). The `25-wwand-ims-l3mdev` hotplug re-adds `local <addr>` on every ifup; check `ip route show table <vrf table>` for it. No `ip_nonlocal_bind` / `udp_l3mdev_accept` sysctl is needed. |
| Call ends right after the 183 with `503`, `Reason: … ASR: BEARER_RELEASED` or `ASR: INSUFFICIENT_SERVER_RESOURCES` (which one depends on the P-CSCF site) | the voice bearer (QCI 1) could not be set up. Seen with LTE FGI 3 and 7 missing in the UE capability: no dedicated-bearer request reaches the modem at all. Set the FGIs (Prerequisites); typical after a SIM change that switched the carrier MBN. |
| `IMS UE  down` though sipd runs | the IMS PDN (wwims) is down or re-attaching, so the UE de-registered — check `wwandctl status` for wwims `CONNECTED` and the P-CSCF in `status.contexts.wwims`. |

## How it works

The design, phases and operator-profile mapping are in the plugin repo's
`docs/design.md`; the QMI ids it uses beyond libqmi 1.38 (with source and
measurement) are in its `docs/qmi-beyond-libqmi.md`.
