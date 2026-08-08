# wwand + VRF and DMZ — L3 network isolation

A deep-dive extracted from the [reference](reference.md#deployment-examples):
how to bind a wwand WAN and a DMZ into an L3 **VRF**, the HW-confirmed
l3mdev/DMZ field notes, the NAT66 / nftables SNAT recipe, and the
"router-can't-reach-its-own-cellular-WAN" caveat. For the simpler and
more commonly-right approach, see **Variant 1 — policy routing** in the
[reference](reference.md#deployment-examples).

See also: [README](README.md) · [reference.md](reference.md) ·
[architecture.md](architecture.md) (the VRF invariant).

## VRF setup

Bind the WAN and DMZ into an L3 VRF instead. The VRF is a `config device` of
`type 'vrf'` with its own table; both interfaces' L3 devices are its `ports`:

```
config device
	option type 'vrf'
	option name 'vrf_wan'
	option table '100'
	list ports 'wwand0'              # the WAN l3 device (stable wwandN name,
	                                 #   mux child or renamed raw netdev alike)
	list ports 'dmz0'                # the DMZ l3 device

config interface 'vrf_wan'           # REQUIRED: a `config device` is only brought
	option proto 'none'              #   up when an interface references it — this
	option device 'vrf_wan'          #   instantiates the master + enslaves the ports

config interface 'wan'
	option proto 'wwand'
	option modem 'm0'
	option device 'wwand0'          # l3 device; matches the VRF port
	option apn 'internet'
	option pdp_type 'ipv4v6'
	option ip4table '100'            # REQUIRED: place the default INTO the VRF table
	option ip6table '100'            #   — netifd does NOT auto-place proto routes
	option defaultroute '1'          #   there; without it the default leaks to main

config interface 'dmz'
	option proto 'static'
	option device 'dmz0'
	option ipaddr '192.0.2.1'
	option netmask '255.255.255.0'
	option ip6assign '64'
	option ip4table '100'
	option ip6table '100'
```

Apply with a **full `/etc/init.d/network restart`** (not `reload`): a `reload`
registers the VRF config but does not instantiate the master or enslave the
members. Verify: `ip link show master vrf_wan` lists `wwand0` and `dmz0`.

**VRF specialities — read these:**

- **wwand stays out of it.** The daemon never sets `IFLA_MASTER`; netifd enslaves
  the mux child to the VRF master and places its routes in the VRF table — see the
  [routing/VRF invariant](architecture.md#routing--vrf-compatibility-invariant).
- **l3mdev is a global switch, not per-VRF.** For the router's own *listening*
  sockets (a DHCPv6 client, DNS, …) to work across the VRF, enable it globally:
  ```
  config globals 'globals'
  	option tcp_l3mdev '1'
  	option udp_l3mdev '1'
  ```
  (writes `net.ipv4.{tcp,udp}_l3mdev_accept`; host-wide, all-or-nothing.)
- **fw4 is VRF-agnostic — and you MUST add the VRF master to the WAN zone.** fw4
  derives a zone's `iifname`/`oifname` from each member's `l3_device` (`wwand0`,
  `dmz0`). But a **forwarded, DNAT'd** packet is re-injected by the l3mdev with
  `iif = vrf_wan` (the master, not the member) — so unless `vrf_wan` is in the WAN
  zone it matches no zone and hits the default reject (HW-confirmed via `nft
  monitor trace`: `iif "vrf_wan" oif "br-lan.20" … jump handle_reject`). Add the
  master as a device to the WAN zone:
  ```
  config zone
  	option name 'wan'
  	list network 'wan'
  	list device 'vrf_wan'          # REQUIRED: l3mdev re-injects forwarded
  	...                            #   traffic with iif = the VRF master
  ```
- **l3mdev FIB rule is automatic — do not script it.** When the first VRF device
  is created the kernel installs the `1000: from all lookup [l3mdev]` rule for
  **both** v4 and v6 itself, and the `config device` + `config interface vrf_wan`
  pair re-instantiates the master on every (cold) boot. Cold-boot-verified: no
  `ip rule add l3mdev` and no hotplug helper are needed (an earlier workaround
  adding them by hand was pure redundancy).

**Forwarding to a DMZ host through the VRF (HW-tested).** With the master in the
WAN zone, inbound traffic is correctly DNAT'd and forwarded to the DMZ host — v4
end-to-end confirmed, v6 end-to-end once the two routing fixes below (catch-all
default route + `keep_addr_on_down`) are in place. Announce the DMZ prefix so
the host can address itself, and NAT the forwarded traffic so its reply returns
symmetrically via the router:

```
# /etc/config/dhcp — announce the DMZ /64 (RA) so the host auto-configures
config dhcp 'dmz'
	option interface 'dmz'
	option ra 'server'
	option dhcpv6 'server'
	list ra_flags 'none'

# /etc/config/firewall — DMZ-host DNAT + NAT66 so the host replies via the router
config redirect                     # all inbound v4 -> the DMZ host
	option name 'DMZ-host'
	option src 'wan'
	option dest 'dmz'
	option proto 'all'
	option dest_ip '192.0.2.10'

config zone
	option name 'dmz'
	list network 'dmz'
	option masq6 '1'                # NAT66: forwarded v6 gets an on-link source,
	...                             #   so the host's reply routes back to us
```

**Allow ICMPv6 ND on a REJECT-input DMZ zone (else v6 breaks entirely).** A DMZ
zone with `input 'REJECT'` and no ICMPv6 allow **rejects the host's incoming
neighbour advertisements** — so the router can never resolve the host's L2 address
and every v6 forward silently fails with the neighbour stuck `FAILED`
(HW-confirmed via `nft monitor trace`: the NA hits `input_dmz → reject_from_dmz →
handle_reject`). The stock `wan` zone ships an `Allow-ICMPv6-Input` rule; a custom
DMZ zone needs the same:
```
config rule
	option name 'Allow-DMZ-ICMPv6'
	option src 'dmz'
	option family 'ipv6'
	option proto 'icmp'
	list icmp_type 'neighbour-solicitation'
	list icmp_type 'neighbour-advertisement'
	list icmp_type 'router-solicitation'
	list icmp_type 'router-advertisement'
	list icmp_type 'echo-request'
	list icmp_type 'echo-reply'
	list icmp_type 'destination-unreachable'
	list icmp_type 'packet-too-big'
	list icmp_type 'time-exceeded'
	option limit '1000/sec'
	option target 'ACCEPT'
```
With this, the neighbour resolves (`… lladdr … REACHABLE`) and the host replies
(HW-confirmed SYN → SYN-ACK). The DMZ host must also have an address *in an on-link
prefix the router shares* (SLAAC from the announced RA, or a static address in a
common `fd…::/64` you also put on the DMZ interface as `::1`) so `masq6` can give
the forwarded traffic an on-link source and the reply returns via the router. To
force that on-link source deterministically (RFC-6724 selection otherwise prefers
the GUA over the ULA for a ULA destination), SNAT the forwarded traffic to the
shared `::1` explicitly rather than relying on `masq6` alone — e.g. an
`/etc/nftables.d/` include:
```
# /etc/nftables.d/20-dmz-v6-snat.nft — on-link source for the DMZ host
chain dmz_v6_snat {
	type nat hook postrouting priority 99; policy accept;   # before fw4 srcnat (100)
	oifname "dmz0" ip6 daddr fd00:…::/64 snat ip6 to fd00:…::1
}
```

**The forwarded v6 reply needs a non-source-specific default route in the VRF
table (else it is dropped before `forward`).** Over cellular the WAN's IPv6
default is **source-specific** — `default from <WAN /64> via … dev wwand0`, an
artefact of the delegated/temporary prefix. On the DNAT'd reply the kernel un-NATs
the *destination* at prerouting but the *source* only at postrouting, so at the
**routing decision the source is still the DMZ host's address** — not in the WAN
`/64`, so the source-specific default does not match → `RTNETLINK: Network
unreachable` and the reply is dropped **before** the `forward` hook (HW-confirmed:
`nft monitor trace` stops at `prerouting`, no `forward`/`postrouting`). IPv4 is
immune (its default is not source-scoped). Add a **catch-all** default into the
VRF table — a device route (no gateway) so it survives prefix/gateway rotation:
```
config route6
	option interface 'wan'           # the wwand WAN interface
	option target '::/0'
	option table '100'               # the VRF table
	option metric '2048'             # below the source-specific default (1024)
```
The router's own traffic still prefers the source-specific default (metric 1024);
only the forwarded reply — whose source does not match it — falls through to the
catch-all. With this the v6 3-way handshake completes end-to-end.

**Keep the DMZ's static IPv6 address across VRF enslavement (`keep_addr_on_down`).**
When the DMZ carries a *static* `ip6addr` (the shared `fd…::1/64` the host replies
to on-link), **enslaving the port into the VRF flushes its IPv6 addresses** — the
kernel keeps IPv4 on a master change but drops IPv6, and netifd never notices (it
still lists the address in `ubus … status`; `reload` is a no-op, only a full
`ifup dmz` re-adds it). At boot the enslavement runs *after* the DMZ comes up, so
the static ULA is gone until the next `ifup`. Fix it with one sysctl — retain
IPv6 addresses on a down/master-change:
```
# /etc/sysctl.d/10-keep-addr-on-down.conf
net.ipv6.conf.default.keep_addr_on_down = 1
net.ipv6.conf.all.keep_addr_on_down = 1
```
Cold-boot-verified: the static ULA then survives enslavement with no hotplug/`ifup`
workaround. (A SLAAC address from the announced RA is re-added by netifd anyway;
this only matters for a *static* `ip6addr`.) The root cause is a netifd gap — it
subscribes only to `RTNLGRP_LINK`, never to `RTM_DELADDR`, so an externally-caused
address flush is invisible to it; the sysctl sidesteps it entirely.

**Both members in one VRF collapse fw4's zone distinction (breaks dmz→wan).** The
l3mdev rewrites the ingress `iif` to the master `vrf_wan` for **all** inter-member
forwarding, so fw4 can no longer tell dmz-sourced from wan-sourced transit traffic
— both arrive as `iif = vrf_wan`. The `vrf_wan`-in-WAN-zone entry above (required so
the **inbound** DNAT return matches a zone) therefore also makes the DMZ host's
**outbound** traffic look wan-sourced → it is classified wan→wan and dropped
(`drop wan out: IN=vrf_wan OUT=wwand0`, HW-seen with a DMZ host's outbound IKE).
There is no clean fw4 fix — the zone key (the ingress device) is gone. Either scope
the VRF to the WAN only (leave the DMZ a normal interface that routes into the VRF
table via `ip4table`/`ip6table` + a policy rule, so it keeps its real `br-lan.20`
iif), or — simpler — use **Variant 1 (policy routing)**, where the iif is never
rewritten and dmz↔wan works both ways natively.

> **Hard limit — the WAN uplink itself must NOT be VRF-enslaved if the router
> terminates traffic on its WAN IP.** VRF works for traffic **forwarded through**
> the router (inbound → a DMZ host): those packets carry `iif = the VRF`, so the
> kernel applies the l3mdev redirect and they route out correctly. But traffic
> **terminated on the router's own WAN address** (ping to the WAN IP, or any
> service the router itself runs there) is **broken by design**: the router's
> reply is generated locally, is *not* VRF-associated (no socket bound to the
> VRF), routes to the raw slave **without** the l3mdev redirect, and cannot egress
> the enslaved member. This was HW-confirmed for **both ICMP and TCP** (SYN in, no
> SYN-ACK out — `tcp_l3mdev_accept=1` does not help; it is a routing/l3mdev-egress
> issue *below* the firewall, so no fw4/nftables rule fixes it). Secondary fw4
> symptoms you will also see: the reply is untracked → `ct state invalid` → the
> anti-NAT-leak drop; and the l3mdev double-traversal reclassifies it as
> *forwarded*, hitting the `wan` zone's `forward` policy (IPv6 often survives only
> because of the stock `Allow-ICMPv6-Forward` rule). **If the router must be
> reachable / run services on the cellular WAN IP, use Variant 1 (policy routing)
> — it does exactly that and is the tested model.** Reserve VRF for the
> forward-only case where the router never terminates WAN traffic.
