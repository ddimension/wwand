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

---

## LuCI

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
