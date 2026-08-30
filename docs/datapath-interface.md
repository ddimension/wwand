# wwand datapaths

**The control backend talks to the modem; the datapath builds the kernel side of
the data link.** They are separate axes: a QMI modem may carry its sessions over
mainline rmnet, over qmi_wwan's own `add_mux`, over a vendor driver's QMAP
children, or over nothing at all. wwand ships four answers and takes a fifth from
any add-on package, all through **one interface** — the built-ins are entries in
it, not special cases beside it.

| name | serves | what it does |
|---|---|---|
| `rmnet` | qmi | QMAP through the kernel rmnet driver (qmi_wwan `pass_through`) |
| `qmimux` | qmi | QMAP through qmi_wwan's own `add_mux` |
| `vlan` | mbim | cdc_mbim sessions as 802.1q sub-devices |
| `raw_ip` | all | no multiplexing — the plain raw-IP parent (not an implementation) |
| `ethernet` | qmi | no multiplexing — the parent keeps the kernel's 802.3 framing (raw_ip off), NOARP point-to-point hop; for QMI stacks without a WDA service (not an implementation) |
| *add-on* | declared | `rmnet_nss` (vendor `qmi_wwan_q`, USB) and `rmnet_nss_mhi` (vendor `pcie_mhi`, PCIe/MHI) keep Qualcomm NSS offload by adopting the children those drivers register |

`raw_ip` was spelled `none` before 1.6 and both spellings — plus `raw-ip` — still
select it. Underscore is canonical: a datapath name doubles as the ucode module
name of its add-on package, and a module path cannot carry a hyphen.

`ethernet` is the QMI counterpart of `raw_ip` for modems whose link-layer format
was never negotiable: `auto` selects it when the modem has no WDA service (the
kernel link — qmi_wwan's 802.3 default — is what stays), and `option mux
'ethernet'` names it outright. The WDA `SET_DATA_FORMAT` then carries
`llp = 802-3` when a WDA service exists after all; the IPv4/IPv6 configuration
still comes over the QMI channel (WDS).

Everything here lives in **`src-ucode/netlink.uc`**. How to *write* an add-on and
package it is [extending.md §4](extending.md#4-adding-a-datapath-backend); this
document is the contract it implements.

## Why an interface and not a registry

A plugin ships as `wwand/datapath_<name>.uc`, a `require()`-able plain script
that **RETURNS** its implementation. The daemon `require()`s it and threads the
object down to `netlink.setup()`.

That indirection is not taste. ucode hands a `require()`d plain script its **own
copies** of the modules it imports, so a plugin calling a `register_backend()` in
`netlink.uc` would populate a *different* netlink instance than the daemon's and
vanish without a trace — verified on the interpreter, and silent, which is the
dangerous part. Hence: no module-level registry anywhere, and a plugin imports
wwand modules for pure helpers only. Everything it needs is handed to it.

The built-ins go through the same table (`BUILTIN`) for a second reason: the path
an add-on takes is then the path every install exercises, instead of a seam only
third parties ever touch. That is not hypothetical — the MBIM session mux was a
`setup_mbim()` of its own until 1.6 and the copy drifted: a stale-child prune fix
landed in the shared `setup()` and was missed there, leaving MBIM with exactly
the defect it had been fixed for.

## The contract

```js
// wwand/datapath_vendorx.uc
'use strict';

return {
    proto:           [ 'qmi' ],          // control protocols served (default qmi)
    description:     '…',                // one line, reaches the LuCI dropdown
    probe:           (fx, netdev, info) => …,   // is this box mine?
    links:           (fx, ctx) => [ … ], // create/adopt children, return names
    pre:             (fx, ctx) => true,  // own driver-format switch (optional)
    prune:           (fx, netdev, wanted) => …, // own child removal (optional)
    child_name:      (netdev, entry) => …,      // own naming (optional)
    map_id:          (entry, netdev, fx) => entry.id,  // wire id (optional)
    status:          (fx, netdev) => ({ … }),   // extra status rows (optional)
    qmap:            true,               // QMAP rides the parent (default: aggregate)
    qmap_v5:         false,              // may negotiate MAPv5 checksum offload
    aggregate:       true,               // QMAP arithmetic on the parent
    programs_parent: true,               // reprograms the parent's link format
    tx_aggr:         false,              // rmnet-style uplink coalesce
};
```

`links()` is the only required part. Everything around it stays shared and is
never reimplemented: pruning stale children, moving a parent off a child's name,
the urb-size write, the parent MTU, link up, child MTUs, the vendor `link_state`
gate and uplink aggregation.

### `links(fx, ctx)`

`ctx` carries `netdev` (the parent — **possibly already renamed, use this one**),
`sys` (`/sys/class/net/<netdev>/qmi`), `mux` (`[{ id, name?, mtu? }]`),
`urb_size`, `v5` (MAPv5 checksum offload negotiated over WDA), `mux_mtus` (fill
it: child → configured MTU) and the full `opts`, plus four helpers so the common
case needs **no imports at all**:

| helper | does |
|---|---|
| `ctx.link(what, dev, opts)` | one rtnl link operation, logged |
| `ctx.write_attr(path, value, what)` | one sysfs write, existence-gated |
| `ctx.child_mtu(mtu, what)` | the configured MTU or 1500, invalid values logged |
| `ctx.child_name(entry)` | **the** naming rule — the same one prune and the rename check use |

### The three flags, and why they are behavioural

Defaults are what the QMI mux backends do, so an add-on that says nothing gets
the historical behaviour.

- **`aggregate`** (default true) — this datapath aggregates QMAP frames on the
  parent, so the shared code adds the 4-byte QMAP header to the datagram size,
  writes `rx_urb_size` and puts that size on the parent MTU. `vlan` sets false
  and sizes the trunk itself inside `links()` (largest child + 4 for the tag).
- **`programs_parent`** (default true) — this datapath reprograms the parent
  driver's link-layer format (qmi_wwan's `raw_ip`, whatever `pre` writes), which
  the driver accepts only while the parent is **down**, so the shared code
  bounces it first. False means "I touch no driver format" and therefore "do not
  bounce it" — not cosmetic: on a restart that adopts a live session the bounce
  drops the very traffic being adopted. Adoption has one obligation the built-in
  rmnet path discharges for you: the QMAP flags are **not** a property of the
  child but of its parent (`port->data_format`, one per real_dev), so a child
  surviving a restart carries the format the PREVIOUS run negotiated. The
  adopt path therefore re-asserts them with a netlink changelink
  (`fx.rmnet_flags_set(child, kernel_map_id, flags, RMNET_FLAGS_MASK)`); without
  it a box moving from plain QMAP to v5 comes back decoding the wrong header —
  tx climbs, rx stays at zero, and nothing is logged. Two details that are easy
  to get wrong, both enforced by the kernel rather than by us:
  `rmnet_rtnl_validate()` rejects a change message carrying no
  `IFLA_RMNET_MUX_ID`, so the id goes along (the kernel's, never the config's);
  and `rmnet_changelink()` applies the flags MASKED
  (`data_format &= ~mask; data_format |= flags & mask`) rather than assigning
  them, so the mask has to cover every format bit wwand owns — a mask of just
  the wanted bits leaves the previous version's standing and a downgrade fixes
  nothing. If the correction cannot be made at all, the link is deleted and
  recreated rather than reported as a working mux.

  Note what this does *not* solve: the modem latches the aggregation format
  while a data session is up. Changing the version on a running modem is
  accepted but not acted on — HW-observed on the RG650E — until every context
  on that modem has been taken down. The bounce additionally requires
  something to program (a `qmi` sysfs group, or a `pre`), so a parent with
  neither is left alone.
- **`tx_aggr`** (default false) — opt into the mainline-rmnet ethtool egress
  coalesce call. Also decides whether the negotiated uplink maxima are reported
  as `ul_agg`.
- **`qmap`** (default: `aggregate`) — QMAP frames ride the parent. A different
  question from `aggregate`, which is about who sizes the buffers: a datapath
  adopting a driver's channels answers `aggregate: false, qmap: true`. It
  decides whether the WDA data format applies and whether the parent-vs-children
  packet ratio measures anything.
- **`qmap_v5`** (default false) — this datapath carries MAPv5 checksum offload,
  so the WDA format is negotiated as QMAPv5 first, with the plain-QMAP fallback.

`netlink.datapath_caps(backend, plugins)` answers all four by name. Three
callers used to test the name itself (`backend == 'rmnet'` for v5 and uplink
coalescing, `!= 'rmnet' && != 'qmimux'` for the aggregation ratio), which every
datapath added later fell outside of, silently.

### Naming and the id on the wire

`child_name(netdev, entry)` is the one naming rule, used by the shared prune, by
the parent-rename collision check and by `links()` itself. Returning **null**
means "this entry gets no child at all" — MBIM session 0 rides the parent
untagged. Default: `entry.name`, else `<parent>m<id>`.

Whatever a child is called while it is being built, it must END as
`child_name()` says: netifd binds `option device` to the context's stable
`wwandN`, and a child left under a driver's own name leaves the interface
unclaimed. `qmimux` renames its `qmimuxN`, and an adopting datapath renames the
driver's child the same way.

`map_id(entry, netdev, fx)` is the id the **modem** must tag the channel with,
when it differs from the config's channel number. It gets the netdev and the
effects object because the answer can be a property of the device that has to be
READ: the Quectel MHI driver offsets MBIM session ids by 112 on an SDX7x
(PCI 17cb:0309) and by nothing elsewhere, and those PCI ids are not under the
netdev's own `device` — they sit on an ancestor. Only a datapath that adopts a driver's
own children knows this: the vendor `qmi_wwan_q` numbers its children `0x81`
upwards, so config channel 1 is `0x81` on the wire, and binding WDS to 1 makes
the driver drop every downlink frame as an unknown mux id. `setup()` returns the
mapping as `map_ids` (keyed by the config channel), `context.uc` binds `BIND_MUX_DATA_PORT` to that, and on MBIM it is the **session
id** — used for CONNECT, DEACTIVATE, IP_CONFIGURATION and, easy to forget,
for matching the unsolicited CONNECT indication back to its context. Default:
`entry.id`, which is right for every datapath that creates its own children.

The chain is `netlink.setup()` → `r.map_ids` → `modem.datapath.map_ids` →
`context.wire_session()` → the wire. Every link has to be present; the mapping
was inert once because the MBIM modem dropped `map_ids` when it stored the
datapath, and nothing noticed because no test drove a remap through it.

## Selection

`select_backend(fx, netdev, cfg_mux, want_mux, plugins, info)` decides, with
`info.proto` the modem's control protocol.

1. **`option mux 'raw_ip'`** — no mux, done.
2. **Named outright** (`option mux 'vendorx'`) — that one or nothing, never a
   quiet substitution. Missing package → `null`, reported as a `control_note`.
3. **`auto`** — every installed add-on that **serves this protocol** and whose
   `probe()` recognises the box, first by name if several match (a second
   claimant is a packaging mistake and is warned about); then the built-ins in
   their own preference order, filtered the same way.
4. **Nothing claimed it** — `null` when a mux was required (the caller reports
   `mux_backend_unavailable`), `raw_ip` otherwise.

Two rules are worth stating explicitly because they pull in opposite directions:

- **The probe is advisory.** Naming a datapath whose probe says no is refused,
  but the probe is the datapath's own judgement about hardware and an operator
  who names one on odd hardware is making an explicit choice.
- **The declared protocol is enforced**, named or not. A protocol a datapath does
  not serve is not a risky choice but an impossible one — rmnet's QMAP framing on
  a cdc_mbim session cannot carry traffic however firmly it was named. Refused
  with an error naming both protocols.

**The probes run on every box**, whatever the channel count. They used to be
skipped when a config had no channels, which is precisely where an accelerated
add-on has to introduce itself — nobody writes `option mux` on an autosetup box.
What the probe does not do is conjure channels: a datapath selected with no
children to build is dropped to `raw_ip` by `setup()` and logged, because
applying its framing anyway (rmnet's `pass_through` with no rmnet child behind
it) is a link that is up and carries nothing. That drop happens **after** the
datapath's own `prune()`, so one whose children the kernel owns keeps them.

## What the rest of wwand sees

- **`setup()` returns** `{ ok, backend, urb_size, mux_devs, map_ids, parent }`.
  `backend` is what actually ran (not what was selected), and `parent` follows a
  possibly-renamed parent.
- **`modem_datapath`** carries the link-layer detail the status page renders:
  backend, parent, negotiated WDA aggregation, NTB parameters, the live mux
  channels and counters — plus `extra`, whatever the datapath's own optional
  `status(fx, netdev)` returned. That hook exists because the generic block
  knows QMAP and NTB and nothing about a vendor datapath's view of the link; the
  NSS one reports the driver's channel count, its RX buffer and whether the shim
  was loaded. Keys are rendered as given.
- **`status`** reports the datapath that came up per modem
  (`modems.<name>.datapath`) and the catalog of what is selectable on this box in
  `globals.datapaths` — `{ name, kind: mode|builtin|plugin, proto, description }`,
  built from the datapaths themselves plus the installed add-ons. The LuCI
  dropdown is that list, filtered per row by the modem's protocol.
- **Autosetup** asks `mux_available(fx, netdev, proto, plugins)` before writing a
  `mux_id` — per modem, against that modem's own netdev, since `qmimux` reads
  that device's `add_mux` node and an add-on probes that device.

## Invariant

The datapath layer touches only the **link layer**: mux children, MTU, carrier,
rename, up/down, and sysfs. It never adds an address or a route and never sets
`IFLA_MASTER` — all addressing and routing goes through netifd, so `ip4table` /
`ip6table` / VRF apply. Guarded by `test_datapath` ("vrf: …").

## Tests

`tests/test_datapath.uc` exercises the whole interface against a fake `fx` with
no hardware: selection, the shared sequence, both built-in QMI backends, the vlan
backend, plugins (including the flags above) and the catalog.
`tests/test_datapath_nss.uc` pins the vendor datapath against the driver sources
it was written from.
