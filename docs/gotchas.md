# Gotchas — things that look right and are not

Every entry here cost someone a debugging session, and every one of them looks
correct until it is checked against a source. That is the admission criterion:
this file is not for facts, it is for **beliefs that survive casual inspection
and are wrong**. A plain fact belongs in `reference.md` or `architecture.md`.

Each entry states the plausible belief, what is actually true, and **the evidence
that settles it** — a file and line someone can re-read, not an assertion. If you
find yourself writing "I think" or "presumably", you are not ready to add the
entry yet.

---

## Kernel / datapath

### rmnet flags are assigned when you set them
**Wrong.** `rmnet_changelink()` applies them MASKED:

```c
port->data_format &= ~flags->mask;
port->data_format |= flags->flags & flags->mask;
```

So a mask covering only the bits you want merely ADDS them. Correcting a link
from v5 to v1 with `mask == flags` leaves the v5 checksum bits standing and the
port goes on misparsing. Use a mask covering every format bit wwand owns
(`RMNET_FLAGS_MASK` in `netlink.uc`).

*Evidence:* `drivers/net/ethernet/qualcomm/rmnet/rmnet_config.c`, checked against
6.18.41. Note the create path differs: `rmnet_newlink()` starts from
`RMNET_FLAGS_INGRESS_DEAGGREGATION` and then applies the same masked update, so a
freshly created child and a corrected one are NOT bit-identical for a bit outside
the mask.

### An RTM_NEWLINK changelink only needs the attributes you want to change
**Wrong.** `rmnet_rtnl_validate()` runs on a change as well as on a create and
rejects a message without `IFLA_RMNET_MUX_ID` with `EINVAL` — the flags are never
reached. Send the MAP id the link CURRENTLY has (read it back with
`rmnet_mux_id`), never the config's: on the adopt path the two can disagree, and
a format correction must not remap a live channel.

### The QMAP flags belong to the mux child
**Wrong.** They live on the PARENT: one `port->data_format` per `real_dev`,
shared by every child. This is why a daemon restart that adopts children
inherits the previous run's format, and why correcting one child corrects them
all.

### `DAP_QMAPV5` is 8
**Wrong, and it was wrong in this tree for months.** libqmi 1.38 has
`QMAPV4 = 0x08` and `QMAPV5 = 0x09`; quectel-cm only ever sends `0x05` or `0x09`.
Asking for 8 got declined by every modem here, and the fallback to plain QMAP
looked like a firmware quirk — the note in this repo blamed the RG650E for years.
It was our bug.

*Evidence:* `src/libqmi-glib/qmi-enums-wda.h`; the ladder in
`codec/schema/wda.uc` now spells all of v1..v5 so 5-means-v1 cannot be misread
again.

### A modem that ACKs SET_DATA_FORMAT has changed format
**Wrong while a data session is up.** The modem accepts the request and keeps
the old format; the downlink then goes silent before it even reaches the USB
parent, so it does not look like a demux problem. Every context on that modem
has to go down (`ifdown` is enough; a modem reset is the bigger hammer).

*Evidence:* HW-observed on the RG650E, 2026-08-30 — v5→v1 on a live session gave
`parent rx +0`; after `ifdown`/`ifup` the same configuration passed 4/4.

### An aggregation ratio below 1 means aggregation is off
**Wrong — it means the counters are not comparable.** Every parent frame carries
at least one child packet, so a mean below one is impossible. It happens when the
child is younger than its parent (any recreation) because these are lifetime
counters. Report nothing rather than a "0.00" that reads as a measurement.

### Never send CTL SYNC over the QMI-over-MBIM passthrough
It resets the modem's embedded QMI state and kills the live MBIM data session.
HW-proven on the EG06. Structurally blocked in `qmi_over_mbim.send`.

---

### `/sys/bus/usb/devices/$DEVPATH` addresses a USB interface
**Neither half of that is true, and both were believed at once** in the E182E
hotplug binder.

`/sys/bus/usb/devices/` holds only FLAT kobject names — `3-1`, `3-1:1.1` — as
symlinks into `/sys/devices`. A `$DEVPATH`-shaped path
(`platform/soc@0/.../usb3/3-1`) never appears there, so a guard built from
`${DEVPATH#/devices/}` matches nothing at all and falls through every time.

The obvious repair is wrong too: an interface is not a SIBLING of its device,
so `/sys$DEVPATH:1.1` does not exist either. It is a CHILD:

```
/sys/bus/usb/devices/3-1:1.1 -> /sys/devices/platform/.../usb3/3-1/3-1:1.1
                                                             ^^^^ inside 3-1
```

So the addressable forms are `/sys$DEVPATH/${DEVPATH##*/}:1.1` or the flat
`/sys/bus/usb/devices/${DEVPATH##*/}:1.1`.

Two more things a USB hotplug script has to know, both of which bit here:

- **`PRODUCT` is exported on interface uevents, not just the device one.**
  `usb_uevent()` handles `is_usb_interface(dev)` explicitly and emits `PRODUCT`
  from the parent device's descriptor. A `case "$PRODUCT"` match with no
  `DEVTYPE=usb_device` gate therefore fires once per interface on top of once
  for the device.
- **`new_id` is not idempotent.** `usb_store_new_id()` kzallocs a `usb_dynid`
  and `list_add_tail()`s it with no duplicate check, so every write appends
  another entry to the driver's list.

*Evidence:* `drivers/usb/core/driver.c` (6.18.41) for both kernel claims; the
sysfs shapes HW-checked on a MikroTik Chateau 5G, 2026-09-05. Guarded by
`tests/test_hotplug_e182e`, which asserts the path shapes separately from the
behaviour so a kernel layout change says which one moved (2026-09-05).

### Every OpenWrt build can install a source-specific IPv6 route
**No — it is a build option, and at least one in-tree target turns it off.**
The IPv6 default route the proto shim asks for carries a source prefix
(`default from <addr>/<plen> via <gw>`), which is what uqmi's `qmi.sh` builds
line for line. The kernel needs `CONFIG_IPV6_SUBTREES` for that, exposed as
`KERNEL_IPV6_SUBTREES` in `config/Config-kernel.in` and itself depending on
`IPV6_MULTIPLE_TABLES`. `target/linux/airoha/*/config-6.18` has
`# CONFIG_IPV6_SUBTREES is not set`.

Where it is off, netifd reports the route in `ubus call network.interface.X
status` and the kernel does not have it. Nothing logs an error, the interface
comes up, addresses are configured, and IPv6 has no default route. `ip -6 route
show table all` shows neither the default nor a `from` entry.

The escape hatch is `option sourcefilter '0'` on the interface (ModemManager's
name and semantics), which installs a plain default instead.

*Evidence:* HW-measured by a reporter on ImmortalWrt 25.12-SNAPSHOT,
mediatek/filogic (ddimension/wwand#8, 2026-09-06). Adding the default by hand
**with the gateway wwand reports** worked and pinged; the same route with a
`from` prefix was never installed; `option sourcefilter '0'` made netifd install
`default via … proto static` and IPv6 worked. So the gateway was fine and the
source filter was the whole problem. Note this hits **stock uqmi identically**
on such a build.

### An "UNTRUSTED signature" from the feed means the key is wrong
**Not on openwrt-25.12, where it usually means there is no signature to check.**
That branch signs the package INDEX and nothing else: `SIGN_EACH_PACKAGE` does
not exist in its `config/Config-build.in`, and its `include/package-pack.mk`
carries no `--sign` at all. Per-package signing arrived after 25.12 and lives
only on snapshot/master.

The practical consequence is only visible when you bypass the index:

- `apk add <name>=<version>` over a configured feed works on both branches —
  the index is signed on both, and a package listed in a trusted index is
  trusted by its hash.
- `apk add ./file.apk` works on snapshot and **always** fails on 25.12, for any
  feed including OpenWrt's own. `--allow-untrusted` is the normal answer there,
  not a symptom of a broken key.

*Evidence:* `apk verify` on one router, same keys, same apk 3.0.5 — the
snapshot build of a package says `OK`, the 25.12 build of the same package and
version says `UNTRUSTED signature` (2026-09-06). That looks exactly like a key
mismatch and is not one; the CI passes the same `PRIVATE_KEY` to every matrix
entry, and the difference is upstream capability. Diagnosed wrongly here first,
as "the 25.12 branch of the feed is unusable" — it is not.

## ucode

### `require()` shares module instances with the importer
**Wrong.** A plain script pulled in with `require()` gets its OWN copies of
everything it imports, so module-level mutable state — a registry, a cache — is
invisible across that boundary, and silently so. This is why the datapath
plug-ins RETURN their implementation instead of registering it.

### A module-level `export function f() {…}` can end with `}`
**Wrong on the OpenWrt parser.** It must end with `};` — the newer host-built
ucode is lenient, so `run_tests.sh` does NOT catch this. Sanity-import changed
modules on the target after deploying.

### Self-referencing arrow functions work like in JS
**Wrong.** No hoisting: a `let` arrow that references itself (recursion,
reschedule) throws "Can't access lexical declaration before initialization" at
RUNTIME. Forward-declare: `let f; f = () => {…}`.

### A string decoder that passes every test you have is a correct decoder
**Only for the inputs you tried, and ASCII is the trap.** `codec/mbim.uc`'s
`utf16le_decode` did `chr(c & 0xff)`, discarding the high byte of every UTF-16
code unit. ASCII survives that untouched, so every operator name, device name
and APN anyone had looked at came through perfectly — for months, across a full
wire-buffer test suite built from captures that were all ASCII.

It took a China Broadcasting SIM to show it (ddimension/wwand#8):

    中国广电  ->  U+4E2D U+56FD U+5E7F U+7535
              ->  chr(0x2D) chr(0xFD) chr(0x7F) chr(0x35)
              ->  "-ý\x7f5"   which reaches a terminal or a JSON reader as  -5

And it cost the reporter an extra round, because the reply told him the junk
name came from his modem: the mangling is indistinguishable from a modem
answering badly, and "the modem is lying" is the cheaper explanation to reach
for. Note `chr()` is byte-oriented in ucode — `chr(0x4E2D)` gives `0xff`, not a
character — so encoding needs the same care in reverse.

**Any codec test whose fixtures are all ASCII has not tested the codec.** Put
one multi-byte string in each direction.

---

## LuCI

### A `null` in an `E()` children array is skipped
**Not on openwrt-25.12, where it paints the word "null" into the page.** That
branch's `dom.append` tests the wrong thing:

    // openwrt-25.12, luci.js:1382
    else if (children !== null && children !== undefined)   // the ARRAY
        node.appendChild(document.createTextNode(`${children[i]}`));

    // master, after 7b02b9add
    else if (children[i] !== null && children[i] !== undefined)   // the MEMBER

`children` is the array and is always truthy, so every null MEMBER falls through
to `createTextNode(String(null))`. Fixed upstream on 2026-05-11 by `7b02b9add`
("luci-base: fix \"null\" text appearing in modal") and **not backported** — the
branches have diverged, so 25.12 still has it.

The consequence is that a conditional child written the obvious way —
`(function(){ if (!x) return null; return E(...); })()` inside a children array
— is invisible on master and prints `null` on the release users actually run.
Return `''` instead: an empty text node, invisible on both.

Found the expensive way (ddimension/luci-app-wwand#6): reported as "displays
null", answered once with an unrelated PLMN fix that was also real, retested,
still there — and only settled when the reporter sent a DOM-inspector shot
pinning the stray `#text` node inside the Cell lock section. Grepping our own
source for the visible string would never have found it; the string is LuCI's.


### Wrapping a widget from `renderWidget()` is harmless
**It is not, and the code comment that said so was wrong for weeks.** Returning
the super's node inside a container —

```js
return E('div', {}, [ node, hint ]);   // WRONG
```

— breaks `getUIElement()` for that option. It resolves with
`map.findElement('id', cbid)` and then `dom.findClassInstance(node)`, and
**findClassInstance walks UPWARDS** through `parentNode` until it finds a bound
class. An extra parent changes what that walk reaches, so the option resolves to
an instance that is not its widget. For a `form.Flag` the next thing that
happens is `Flag.formvalue()` calling `isChecked()` on it, which throws and
takes the whole modal save with it.

Append into the node instead:

```js
node.appendChild(hint);
return node;                            // RIGHT
```

*Evidence:* measured in the browser on OpenWrt 25.12-SNAPSHOT with
`luci-base 26.246.70755` — for the one wrapped option both
`cbid.network.wan.at2_external` and `widget.cbid.network.wan.at2_external`
resolved to an instance without `isChecked`, while every unwrapped flag on the
same form (`lowpower`, `location`, `defaultroute`, `peerdns`, …) resolved to a
`Checkbox` (ddimension/luci-app-wwand#3, 2026-09-06). A careful reading of
`getUIElement` had concluded the opposite, twice — it looks only at the id, and
the id does not move. The walk does.

### `E('td', {}, someString)` escapes the string
**Wrong — it renders it as MARKUP.** In `dom.append` a bare string child is
assigned through `innerHTML` (luci.js:1394-1396); only an ARRAY child becomes a
`createTextNode` (:1382-1383). So `E('td', {}, [ str ])` escapes and
`E('td', {}, str)` does not.

Anything the modem, the network, the SIM or a carrier profile supplied must go in
as an array. Wrapping an unsafe `E('span', {}, str)` inside a safe table helper
does not help: the string was assigned through that span's `innerHTML` before the
helper ever saw it.

---

## Release / packaging / tooling

### `git rev-parse v1.5.2` gives you the commit
**Wrong for an annotated tag** — it gives the tag OBJECT's sha. Pinning that as
`PKG_SOURCE_VERSION` produces a different tarball than the commit does and the
hash check fails, even though git peels the tag on checkout and the source tree
is identical. Use `git rev-parse v1.5.2^{commit}`.

### `scripts/update-hashes.sh` succeeded because it printed no error
**Check the Makefile actually changed.** It has an all-or-nothing gate: if ANY
package fails to fetch, it writes no Makefile at all and exits non-zero — so
unrelated packages failing means your hash was computed and discarded. And if you
pipe it (`| tail`), the exit status you see is the pipe's, not the script's.

### `apk upgrade <pkg>` upgrades that package
**Not reliably.** On two of the four test routers it reported success and
upgraded nothing, leaving a base package at r49 with its backends at r28 — a mix
that is not supportable. `apk add "<pkg>=<version>"` with the explicit version
works. Always read the installed versions back afterwards.

### A test router that cannot fetch packages means the build is not published
**Check the default route first.** A box whose WAN is the modem has no route at
all when that interface is administratively down, and apk then fails for EVERY
repository — including `downloads.openwrt.org`. That symptom was misread as "CI
has not built this architecture yet" on 2026-08-30; the build had been ready for
an hour.

### `tar cf - -C $STAGING . | ssh box 'tar xf - -C /'` only writes the files
**It writes the DIRECTORY it was told to archive, too — including `/`.** `tar`
stores an entry for `.` itself, carrying that directory's mode and ownership, and
extracting into `/` applies both to the root directory. A staging tree built with
`mktemp -d` is mode 0700 and owned by the developer's uid, so `/` becomes
`drwx------ 1000:1000`.

Root keeps working — it bypasses the permission check — so ssh, ping and the
running daemon all look healthy. Everything NOT running as root loses the ability
to traverse `/`: ubus clients cannot reach the socket, rpcd and the web interface
die, and `ubus list` answers "Failed to connect to ubus" while `pgrep ubusd`
shows it alive and sleeping with 30 open fds. Done on the Chateau, 2026-08-31.

Name the subtrees instead of `.` (`tar cf - -C $ST ./usr ./etc ./www`), or pass
`--owner=root --group=root`, or extract somewhere that is not `/`. Afterwards,
`find / -xdev \( -uid <yours> -o -gid <yours> \)` finds what was mis-owned; the
same trap applies to every earlier `-C <dir>` deploy in this repo's instructions,
which is why `/usr/share/ucode/wwand` had been owned by a foreign uid for weeks
without anyone noticing (mode 0775 there, so nothing broke).

### NSS offload is on once rmnet_nss is loaded and the children are adopted
**Two more things have to be true, and neither is visible from wwand.**

The vendor driver decides whether a child gets an NSS context ONCE, when it
creates it: `qmi_wwan_q` calls `nss_cb->nss_create(qmap_net)` in its USB probe.
Load `rmnet_nss` afterwards and the children exist, traffic flows, and every
packet goes through the CPU — nothing fails, the offload is simply absent.
wwand logs it at probe time because it cannot fix it: the answer was captured
before wwand saw the device. That is a property of the STOCK driver; turning the
single attempt into a bounded delayed-work retry removes the ordering
requirement entirely (kuncy7/aw1000-nss-builder carries such a patch for
quectel-qmi-wwan), but it is a kernel-module change and no wwand package can
apply it.

Second, on an NSS build the ECM has to accelerate raw-IP flows at all: the ECM
in the Julius EDMA tree no longer enables `ECM_INTERFACE_RAWIP_ENABLE`, so rmnet
flows are not accelerated unless it is turned back on. Reported from an
Arcadyan AW1000 (IPQ807x, RG500Q-EA), 2026-09-03.

So "rmnet_nss is loaded, the children are adopted, the link is up" is not the
same as "the datapath is offloaded", and the difference costs throughput
silently. Check the NSS side before concluding wwand is the problem.

### Upgrading luci-app-wwand makes browsers fetch the new JS
**No. The cache-busting token is luci-base's version, not the app's.** `luci.js`
appends `?v=${env.resource_version}` to every resource it loads — app views
included — and `resource_version` is the *luci-base* version
(`?v=26.239.42882~e60322b`). Upgrade only `luci-app-wwand` and that token does
not move, so a browser holding the old `view/wwand/modems.js` keeps serving it
under heuristic freshness and never asks the server, even though uhttpd has a new
ETag and Last-Modified for it.

The symptom is a page built from a MIX: old JS against a new daemon, new ACL and
new ubus surface. It presents as the app misbehaving — up to "cannot save any
change" — with nothing wrong on the box. Verified on the sponsor's WH3000 Pro
(2026-09-01) after an app-only r23 → r24 upgrade; the served file matched the
package byte for byte and every ubus method the page calls was granted.

Clearing `/tmp/luci-indexcache*` and `/tmp/luci-modulecache` does NOT help: those
are the server's own caches. The browser needs a hard reload (Ctrl-Shift-R) or a
site-data clear. So when someone reports odd LuCI behaviour right after a package
update, ask for that FIRST — before reading the JS for a bug that is not there.

### A test suite that prints "0 failures" ran all its checks
**Not if the chain died.** The scenario-driven suites run one scenario at a
time, each starting the next from its own completion. mockhub `die()`s on a
message no handler covers; that exception leaves the uloop callback, uloop.run()
returns early — and the summary still reads 0 failures, because no check ever
FAILED, they simply never ran. `test_modem` reported 83 of its 213 checks that
way, and the only visible symptom was a number nobody was comparing against
anything. The `die()` message itself never reached the output.

Every chained suite now asserts `current == length(scenarios)` after the loop
(test_context asserts its pump finished rather than running out of iterations).
When a suite's count drops, that is the first thing to check — and a new
scenario against a minimal-service mock is the usual cause, since base_handlers
carries only what most scenarios need.

### A basename `grep` proves a file is listed in a build or packaging list
**Wrong.** It also matches comments and prose. Use `tools/check-packaging.py`,
which parses the lists — and note that its first two versions had false positives
of their own, for the same reason in reverse (a `)` inside a comment, and a
pattern that ran past the end of a variable into the prose after it).

### A load-bearing test proves the guard is right
**No — it proves the guard and the test agree.** The cancellation guard in the
settings-refresh walk checked `err.error == 'cancelled'`, and its unit test
injected exactly that. The test passed, and it failed when the guard was removed,
so it looked like proof. But `context.uc`'s `fetch_settings` WRAPS the client
error as `{ stage: 'settings', err }`, so the guard never matched in production
and the test was describing an interface that does not exist (2026-08-31).

Reverting the fix to see the test go red is necessary and not sufficient. The
fixture also has to be the shape the real caller passes. When a callback is
reached through a wrapper, read the wrapper — do not infer the shape from the
guard you just wrote.

### `client.destroy()` is a quiet operation
**It is not: it fails every pending request SYNCHRONOUSLY, with the hub still
live.** So a callback that treats "error" as "carry on" issues its next request
on a client mid-destruction, and arms timers after teardown's cancellation pass
has already run. That is one bug class with many instances — a slot switch, an
NV profile write and a data-session START were all reachable this way. The
convention that works is a captured generation plus one `torn_down(err, client)`
helper, applied at once; fixing instances one at a time is how each fix came to
introduce the next hole (2026-08-30/31).

**The AT engine is different**, and worth knowing so it is not "fixed" too:
`atcmd.close()` cancels the timer, nulls the active command and clears the queue
WITHOUT invoking pending callbacks, so the AT chains cannot resume this way.

### INVALID_PROFILE means the profile index does not exist
**Not necessarily — on an old stack it means "I do not do profile WRITES".**
The Huawei E182E (Qualcomm 8200A, firmware 2009-11-13) answers every
`WDS MODIFY_PROFILE` with QMI protocol error 10, and then answers
`GET_PROFILE_SETTINGS` on that very index without complaint, one request later.
The index is real, readable and dial-able; only writing it is unimplemented.

wwand used to take the write's verdict as final and drop `3gpp-profile` from
START_NETWORK. The modem then failed the dial with call end reason 11 (internal
error) after ~36 s, every time. So the read now revokes the flag
(`context.uc` `check_pdp_type`): a profile that can be read exists
(HW-observed, sponsor box 2026-09-09).

### START_NETWORK's inline APN TLV is enough, so the profile write is optional
**It is not enough on such a modem — the APN has to actually be IN the context.**
This is the other half of the same bug, and the half that really kept the E182E
offline. With the correct APN passed inline and the correct profile index sent,
the dial still failed with reason 11; the modem's `AT+CGDCONT?` showed the index
still carrying the vendor preset (`internet`, for a SIM that needs
`internet.globe.com.ph`). Writing the APN over `AT+CGDCONT` into **the same index
the dial asks for** connected it immediately.

Hence the AT fallback in `context.uc` (`at_define_context`), which fires only
when QMI refused the write. Two things about it are load-bearing:
- **The cid must equal `profile.index`**, the number that goes to START_NETWORK
  as `profile_3gpp`. Defining cid 1 and dialling profile 2 looks correct in the
  log and never connects.
- **The AT reply is not the verdict.** This hardware answers so late that wwand
  books the answer as an unsolicited line and the send reports a timeout, while
  the write has landed — visible as `urc[at]: +CGDCONT: 1,...` carrying the new
  APN right after `AT+CGDCONT? -> error: timeout`. Gating the dial on that reply
  would throw away a write that worked.

### A stricter field pattern is the safe choice for a parser
**Not when the row is all-or-nothing.** `parse_gtccinfo` matched the whole
GTCCINFO row with one regex and skipped any line that did not match. The sinr
slot accepted `[0-9A-Fa-f]*`, so a row reading `-6` failed the match and was
dropped **entirely** — mcc, mnc, tac, cid, earfcn, pci, rsrp and rsrq went with
it, the serving cell stayed empty, and `fill_signal_from_serving` therefore left
`signal.lte` empty too. `registration.rat` was null for the same reason.

The failure mode is the inversion that makes it worth remembering: **sinr is
negative exactly when the cell is weak**, so the serving-cell block went blank
precisely in the situation its numbers are wanted for. On a healthy cell
everything parsed, which is why it survived so long. Field-observed on an
FM350-GL at RSRP -115 dBm (sponsor box, 2026-09-10):

    1,4,515,3,BF7E,0022F5D68,2460,251,,,-6,25,25,0

`numtok` had always accepted `/^-?[0-9]+$/` — only the row pattern refused, so
the value layer was never the problem. When one pattern gates a whole record,
every field it describes has to admit the full range that field can actually
carry; a slot that is too strict does not degrade that field, it deletes the
record.

### An empty signal panel means the modem is not registered
**It means we have no RSRP — a different claim, and often a false one.** The
status page drew signal only from `lte.rsrp` / `nr5g.rsrp` and otherwise printed
"no signal (modem not registered)", while the Serving cell panel beside it read
`registered` from the registration block for the same modem. Both were on screen
at once (sponsor box, 2026-09-10).

The generic `rssi` is the common floor and for some modems it is all there is:
the FM350-GL on NCM, the EG06 on native MBIM (`telemetry_mbim.uc:42`) and any
QMI modem camped on 2G/3G report it alone. Two of the three modems on that one
box hit the dead end, on two different backends. Registration is what the
registration block says (`fmt.regShort`); the absence of a measurement is not
evidence about it.
