Subject: [RFC] wwand — an event-driven ucode WWAN connection manager: improve the existing stack, or a separate proto?

To: openwrt-devel@lists.openwrt.org
Cc: (WWAN/netifd maintainers — e.g. dangowrt, blocktrron, Matti Laakso / uqmi;
     ModemManager maintainers feckert et al.)

Hi all,

I'd like to get the architecture question settled before pushing further on the
packages PR (openwrt/packages#30185), because it's really a project-direction
question for the WWAN/netifd area, not a packaging one.

## What wwand is

wwand is an event-driven cellular connection manager written in ucode, built
around uloop/ubus/UCI/netifd. It replaces a bash QMI dialer I've run
since ~2014 and encodes a lot of field-earned modem-quirk handling. It speaks
QMI, MBIM and NCM/AT itself (native qmux/tlv codec + MBIM, no uqmi/mbimcli
spawning), owns the connection lifecycle, and drives netifd over ubus
(`no_proto_task=1`: after setup the interface stays up with no monitor process;
the daemon renews in place on transient loss, preserving IPv6-PD and VRF).

It is now a **good citizen**: no `CONFLICTS`, manages only `proto wwand`, and
coexists with uqmi/umbim/comgt-ncm. Adopting the stock stack is opt-in
(`option takeover`, default off) or per-interface user-triggered migration.

One-line positioning: *a lightweight WWAN control daemon providing a unified
control plane for **QMI and MBIM** modems, with Qualcomm-specific datapaths
(QMAP/RmNet) and modern PCIe/MHI transports modelled as separate capabilities* —
deliberately not "a QMI daemon".

## Architecture: control protocol ≠ datapath ≠ transport

The design choice I'd most like feedback on is the separation of three concerns
that the stock tools tend to conflate:

```
  control protocol :  QMI | MBIM | AT | (QRTR)
  datapath         :  QMAP/RmNet | MBIM | NCM/ECM | raw-ip
  physical transport: USB | PCIe/MHI | UART
```

QMI and MBIM are **both first-class control backends** behind one daemon-neutral
contract (not QMI-with-MBIM-bolted-on) — that matches where the market actually
is: Quectel/SIMCom/MeiG lean QMI/QMAP, while Sierra-Semtech/Telit/Fibocom/u-blox
lean MBIM as the generic host interface. Crucially, **QMAP is modelled as a
datapath capability, not a synonym for QMI**, and the physical transport is not
baked in — so `control=QMI datapath=QMAP transport=PCIe/MHI` is representable
without a redesign, which matters as high-end 5G modules move to PCIe/MHI (and
QRTR) instead of USB. That transport-independence is not just aspirational: modem
discovery already enumerates control devices from the kernel `wwan` framework
(`/dev/wwanXqmi0|mbim0`, the MHI/PCIe path) alongside USB cdc-wdm, and binds them
by sysfs path — the remaining PCIe/MHI work is HW validation on an M.2 module, not
a redesign. This transport-independent, control/datapath-separated model is the
part I think is genuinely worth having in-tree regardless of the QMI-vs-MBIM
balance. (A fuller vendor/interface survey is in `docs/interface-landscape.md`.)

## The question

BKPepe's review of #30185 raised the right high-level point: since wwand is
OpenWrt-specific and overlaps the existing WWAN stack, should the missing
capabilities be added to the *existing* components instead of introducing another
QMI/MBIM/NCM implementation?

I genuinely want the maintainers' read on this, because both answers are
defensible and I'll follow the consensus.

## Precedent

`net/modemmanager` already sits in the packages feed: a large, external WWAN
daemon, additive, with its own `proto modemmanager` netifd handler, co-maintained
by core people. After the coexistence rework wwand is structurally in the same
position — an optional `proto wwand` the user selects, next to the stock
handlers. So "a separate WWAN manager as an optional proto" is not without
precedent in the feed; ModemManager is exactly that.

There's also the fw4 precedent for a from-scratch ucode reimplementation of an
existing subsystem (iptables→nftables) living in-tree because the new design was
worth it. I'm not claiming wwand is fw4 — only that "ucode rewrite of an existing
capability" is not automatically disqualifying if the design earns it.

## What wwand does that the existing stack doesn't (the concrete delta)

These are the field problems that made me build it rather than script uqmi:

1. **Recovery ladder** — a fired-once, threshold-crossing escalation over a
   persisted counter: opmode-cycle → modem-reset → board power-cycle / reset-GPIO
   → reboot. Robust to counter jumps and restarts. (uqmi has no recovery model;
   scripts around it re-invent this poorly.)
2. **Non-destructive reload / in-place renew** — transient loss holds the
   interface up and renews over ubus without teardown, so IPv6-PD leases and VRF/
   policy-routing survive. netifd otherwise tears down and rebuilds.
3. **Native netlink datapath — QMAP mux + UL/DL aggregation** — wwand sets up the
   rmnet mux channels *and* the QMAP uplink/downlink datagram aggregation
   (datagram max size + aggregation count, both directions) **directly over
   netlink** (RTM_NEWLINK / rmnet), with no qmicli/ip subprocess in the path.
   It's strictly link-layer (mux/MTU/carrier); all addressing and routing stay in
   netifd, so ip4table/ip6table/VRF/policy-routing apply unchanged. Several
   `proto wwand` interfaces share one modem over mux channels with per-context
   lifecycle. This aggregation path is the main throughput win over a
   uqmi+scripts setup and is not something the CLI tools expose cleanly.
4. **Backend-neutral SIM/PLMN layer** — PIN safety (never burn the last retry),
   per-ICCID overrides, and named PLMN selector lists (preferred + forbidden/
   FPLMN) the daemon re-applies before every radio-on. The forbidden-list control
   is a real operator need (steering-of-roaming for M2M/GDSP SIMs) that nothing in
   the current stack offers.
5. **eSIM handling** — lpac-based profile management (list/enable/disable/
   download/switch) with the APDU channel carried over whichever transport the
   modem offers: QMI-UIM logical channel, native MBIM UICC low-level access, or
   AT CCHO/CGLA. Profile switch applies via a SIM hot-reset (no full modem
   reboot). Shipped as an optional `wwand-esim` package (pulls lpac). Nothing in
   the stock stack does eSIM.
6. **Board integration** — /etc/board.json-keyed power/reset GPIOs + status LEDs,
   absorbing the per-vendor helper scripts.
7. **netifd-ecosystem integration depth** — dependent tunnels (WireGuard, xfrm/
   IPsec, gre/vti/ipip) that bind the WAN as `tunlink`/parent follow it correctly
   through netifd's host-dependency graph on up/down. wwand also handles the one
   subtle edge the in-place-renew design creates: netifd drops an in-place
   base-address update for resolved host dependencies, so a tunnel/xfrm would keep
   a stale local address across a cellular IP change — an opt-in
   `hard_reconnect_on_ip_change` makes wwand emit a netifd link down→up (without
   re-dialling the session) so dependents re-follow. This is the kind of
   whole-netifd-ecosystem behaviour a from-scratch, netifd-native manager can get
   right by construction.

## The two ways forward

**(a) Improve the existing stack.** Some of the above could land as uqmi/netifd
improvements — better renew semantics, a recovery helper, QMAP ergonomics.
Others (the async state machine, the unified QMI/MBIM/NCM contract, the PLMN
lifecycle) are hard to retrofit onto uqmi's one-shot CLI model without
effectively rewriting it.

**(b) A separate opt-in proto** (the ModemManager shape). Lower risk to existing
users (additive, opt-in), at the cost of a second WWAN codebase in the feed to
review/maintain.

I lean toward (b) — it's what the coexistence rework already implements and it
mirrors ModemManager — but I want the WWAN/netifd maintainers to weigh in,
because if there's appetite for folding specific pieces into the existing stack
I'm happy to contribute them there too (the recovery model and in-place renew are
the most portable).

## Maturity / maintenance

It runs on production hardware here across QMI/MBIM/NCM and aarch64+mipsel (Quectel
RG650E/EG06/RG502Q, Huawei E392, MeiG SLM770A, Fibocom-class), with a 40-suite /
~2000-check host test suite in CI (wire-buffer tests pinning every QMI/MBIM
message against libqmi/libmbim 1.38/1.32). I'm committed to maintaining it and my
company (M2M-focused) stands behind it; I'm actively looking for a co-maintainer
and collecting field reports.

Grateful for direction on (a) vs (b), and for any WWAN/netifd-specific concerns.

Thanks,
André Valentin (ddimension)
