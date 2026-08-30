# Extending wwand

wwand is built to be **extended by data, not by branching code**. Adding a modem
usually means adding a row to a table; adding a feature means adding one
declarative schema entry or one small module behind an existing contract. This
guide is the map: what to touch, where, and how to test it.

Every change is host-testable — see [§9 Testing](#9-testing). Run the suites
before every commit; reproduce a field problem as a mock scenario first.

**Contents**

1. [Adding a modem / firmware quirk](#1-adding-a-modem--firmware-quirk)
2. [Adding a config option](#2-adding-a-config-option)
3. [Adding a control backend](#3-adding-a-control-backend)
4. [Adding a datapath backend](#4-adding-a-datapath-backend)
5. [Adding telemetry](#5-adding-telemetry)
6. [Adding a ubus method](#6-adding-a-ubus-method)
7. [Extending the LuCI UI](#7-extending-the-luci-ui)
8. [Adding a board profile](#8-adding-a-board-profile)
9. [Testing](#9-testing)

---

## 1. Adding a modem / firmware quirk

Quirks are **pattern-gated data tables**. You match the modem model (a regex)
and declare what it needs — no `if (model == …)` in the flow logic. Pick the
table that matches the kind of quirk:

| Quirk kind | Where | Shape |
|---|---|---|
| **AT command at init** (carrier-config, mode, vendor tweak) | `src-ucode/atcmd.uc` → `MODEL_QUIRKS` | `{ match: /regex/, commands: [ 'AT+…' ] }` |
| **Expectation / validation + operator warning** | `src-ucode/modem_quirks.uc` → `QUIRKS` | `{ match, expect:{…}, warn:[…], init_commands:[…] }` |
| **QMAP aggregation datagram size** | `src-ucode/netlink.uc` (model/board table) | model → bytes; `option dl_datagram_max_size` overrides |
| **Protocol-switch recipe** (QMI⇄MBIM `AT+QCFG="usbnet"`) | `src-ucode/protocol_switch.uc` | per-vendor set/reset/query commands |
| **usbnet mode-switch** (PPP-only → rich mode) | `src-ucode/modeswitch.uc` | per-vendor `{ set, reset, query }` |
| **AT port mapping** (which ttyUSB is AT/at2/gps) | `src-ucode/atport.uc` (generated) + `atcmd.uc` `LOCAL_PORTS` | `usbid → { ifnum: role }` |
| **NCM dial + telemetry recipe** | `src-ucode/ncm_vendors.uc` → `VENDORS` | per-vendor `dials` + `telemetry` blocks |

### Worked example — "my modem needs an AT command at startup"

Say a new Quectel needs `AT+QMBNCFG="AutoSel",1` before registration. Add one row
to `MODEL_QUIRKS` in `src-ucode/atcmd.uc`:

```
const MODEL_QUIRKS = [
    { match: /^EG06|^EM06|^RG50[0-9]|^RG65[0-9]/,
      commands: [ 'AT+QMBNCFG="AutoSel",1' ] },
    // your modem:
    { match: /^RG255/, commands: [ 'AT+MYCMD=1' ] },
];
```

`model_init_commands(model)` collects every matching row; the AT engine runs them
once after the modem is detected, before registration. That's it — no other code
changes. Add a `test_atcmd` assertion (`model_init_commands('RG255…')` returns
your command) and you're done.

### Worked example — "validate the live modem against a spec + warn"

`src-ucode/modem_quirks.uc` `for_model(model)` merges every matching `QUIRKS`
entry into `{ expect, warn, init_commands }`. `modem.validate_config` compares
the live modem to `expect` and surfaces mismatches as `config_warnings` (shown in
`status()` and LuCI); `warn` entries are static heads-ups. Example:

```
{ match: /^RG502Q/,
  expect: { attach_pdp_type: 'ipv4v6' },
  warn:   [ 'firmware self-activates PDP profile 2 on boot; wwand reclaims it' ] },
```

### Capability probing instead of a model gate

When a feature exists on *some* firmwares of a model (e.g. a QMI service that one
build answers with `INFO_UNAVAILABLE`), don't gate on the model — **probe** it
once and cache the winning transport with `backend.choose` (`src-ucode/backend.uc`):

```
backend.choose(self, '_ca_be', [
    { name: 'qmi', probe: (ok) => self.nas ? qmi_backend.get_ca(self.nas, ca => ok(ca != null)) : ok(false) },
    { name: 'at',  probe: (ok) => ok(!!self.at) },
], (be) => { /* use the chosen backend */ });
```

The choice is cached per modem and reset on SIM/protocol change (`backend.reset`).
This is how CA info falls back QMI → AT+QCAINFO transparently.

### AT port mapping for a new USB id

The table in `src-ucode/atport.uc` is **generated** from ModemManager's udev
rules — regenerate it rather than editing by hand:

```
tools/gen-atport-table.py <modemmanager-checkout> > src-ucode/atport.uc
```

For a modem MM doesn't cover, add it to `LOCAL_PORTS` in `atcmd.uc`
(`'2c7c:0122': { '2': 'at', '3': 'at2' }`). `find_at_channels` resolves the
primary AT + optional dedicated telemetry (`at2`) channel from it.

---

## 2. Adding a config option

Config is parsed by `src-ucode/config.uc` into a normalized model. To add an
option (say a modem option `foo`):

1. **Default** — add `foo` to `modem_defaults()` (or `context_defaults()`).
2. **Parse** — read it in `modem_from_section(s)` (the `config wwand_modem`
   parser) with the right coercion (`+(s.foo ?? 0)`, `bool_opt(s.foo, false)`,
   list handling). Context options go in the `context` case + the `option modem`
   interface branch in `compat_translate`.
3. **netifd** — if it's an *interface* (connection) option, declare it in
   `files/wwand-proto.sh` with `proto_config_add_string foo` so netifd tracks it
   (the daemon reads uci directly, but this keeps change-detection clean).
4. **Consume** — read `self.config.foo` in `modem.uc`/`context.uc`.
5. **Migrate** — if old configs carried it inline, add it to `MIGRATE_MODEM_OPTS`
   in `config.uc migrate_plan` so it moves to the right section on conversion.
6. **LuCI + docs** — a form field (see §6) and a row in `docs/reference.md`.
7. **Test** — a `test_config` case asserting it parses.

> **Trap:** the parser copies fields **explicitly** — an option that exists in
> `modem_defaults()` but is not read in step 2 parses to its default and
> silently never reaches the runtime. The `test_config` pass-through assertion
> in step 7 is what catches this.

The config model itself (`wwand_modem` / `wwand_sim` / `interface option modem` /
`wwand_globals`, all in `/etc/config/network`) is described in
[reference.md → Configuration](reference.md#configuration).

---

## 3. Adding a control backend

wwand has three control backends — **QMI**, **MBIM**, **NCM** — behind one
**daemon-neutral contract** (`docs/backend-interface.md`). A modem object exposes
the same methods (`start`/`stop`/`state`/`with_nas`/`attach_context`/
`note_connect_*`/`switch_protocol` + events) and its contexts produce an
**identical `settings` shape** (`{ipv4{addr,prefix,gateway,dns[]}, ipv6{…}, mtu}`),
so `daemon.uc`, the netifd shim and the ubus API stay protocol-neutral.

To add a backend `xyz`:

1. **State machines** — `src-ucode/modem_xyz.uc` + `context_xyz.uc`. Reuse the
   shared core in `src-ucode/modem_common.uc` (`scaffolding`, `make_fail`,
   `note_connect_failure_light`, `watch_driver`, `open_at`/`close_at`/
   `telemetry_at`) and `context_common.uc` (`rx_stall_watch`, `zero_rx_limit_ms`)
   — do NOT re-implement them. **Import other modules by namespace**
   (`import * as foo from 'wwand.foo'`), never relative (`'./foo.uc'`), and use
   `_` not `-` in file/dir names — the bytecode precompile resolves modules only
   via the search path and cannot map hyphens (see `docs/architecture.md`).
2. **Lazy shim** — `src-ucode/xyz_lazy.uc` (an exportless plain script that
   `import`s the modules and returns `{ modem, context }`), because ucode's
   `require()` cannot load ES modules directly.
3. **Loader** — a `load_xyz()` in `daemon.uc` with the same try/catch (returns
   null when the package is absent) and a branch in `backend_for(proto)`.
4. **Discovery** — teach `src-ucode/discovery.uc` `resolve_control(cfg)` to map
   the modem's driver/device to `xyz`.
5. **Package** — a `wwand-xyz` package in the feed Makefile (`DEPENDS +wwand`)
   with an **explicit per-file install list** (no glob-then-`rm` — every module
   is owned by exactly one package). Add each new `.uc` to the source lists in
   the repo-root **`CMakeLists.txt`** (`WWAND_UCODE_MODULES` for `export`
   modules, `_PLAIN` for `require()`d CommonJS shims) or the bytecode build's
   configure-time completeness check fails. Do **not** `CONFLICTS` the stock
   handler — wwand coexists with it and only manages `proto wwand` interfaces.
6. **Migration** — if the modem is normally driven by a stock netifd proto, add
   that proto to `migrate_plan` so a `proto xyz` interface converts to `proto
   wwand` + `wwand_modem` (user-triggered from the LuCI modem list / migrate CLI).

MBIM is the reference example of reuse: it has no native NAS, so it brings up a
**QMI-over-MBIM passthrough** (`qmi_over_mbim.uc`) and runs the whole QMI stack
(`qmi_backend`, schemas) over the open MBIM channel — which is why `wwand-mbim`
depends on `wwand-qmi`.

---

## 4. Adding a datapath backend

The control backend talks to the modem; the **datapath** builds the kernel side
of the data link. wwand ships `rmnet` and `qmimux` for QMI, `vlan` for MBIM
sessions, and `raw_ip` for no multiplexing at all. A vendor driver with its own
mux mechanism is added as an **add-on package, without patching wwand**.

> The contract itself — every field, the selection rules, what `setup()` returns
> and what `status` exposes — is **[datapath-interface.md](datapath-interface.md)**.
> Read that first; this section is the implementation checklist.

**1. Write it.** Ship `wwand/datapath_<name>.uc`: a `require()`-able **plain
script** (top-level `return`, like the `*_lazy.uc` shims) that RETURNS its
implementation object. `links(fx, ctx)` is the only required member — everything
around it (pruning, the parent rename, urb/MTU handling, link up, child MTUs,
the vendor `link_state` gate, uplink aggregation) stays shared.

> **Do not import wwand modules for shared state.** ucode hands a `require()`d
> plain script its **own copies** of the modules it imports, so a plugin that
> called a `register_backend()` in `netlink.uc` would populate a *different*
> instance than the daemon's and vanish without a trace. That is why the
> implementation is returned and threaded through instead. Pure helpers are
> fine; anything stateful is not.

**2. Name it so it can be found.** The name must match `^[a-z][a-z0-9_]*$` — it
becomes a module path, and `config.uc` rejects anything else (after
canonicalising, so a typed `raw-ip` is not rejected as path-shaped). It is also
the value of `option mux` and the package name, so all three read alike.

**3. Make the probe narrow.** `option mux '<name>'` names it outright and always
wins; under the default `auto` it is your `probe()` that decides, and it runs on
every box whether or not the config has channels. On hardware it does not fit,
your plugin must change **nothing**. A plugin without a probe is explicit-only.

**4. Package it** like the backend packages: `wwand-datapath-<name>`,
`DEPENDS +wwand` plus the backend package of whatever `proto` you declare, with
an explicit per-file install list. In tree, add the file to `WWAND_UCODE_PLAIN`
in the root `CMakeLists.txt` — the configure step fails on a `.uc` that is not
listed.

**5. Test it** without hardware: `tests/test_datapath.uc` drives a plugin object
through `netlink.select_backend()` / `netlink.setup()` against the fake `fx` and
asserts the action trace; `tests/test_wan6.uc` covers the daemon side, including
the missing-package `control_note`.

```
# nothing configured -> a plugin whose probe recognises this box takes over
config wwand_modem 'm0'
	option device '/dev/cdc-wdm0'

# ... or pin it, either way
	option mux 'rmnet_nss'      # this one or nothing
	option mux 'rmnet'          # a built-in: plugins are not consulted at all
```

**A worked example ships in tree.** `src-ucode/datapath_rmnet_nss.uc` is the
Qualcomm NSS datapath for the vendor `qmi_wwan_q` driver, packaged as
`wwand-datapath-rmnet_nss`. It uses nearly every optional field, because it has
to: the children already exist (the driver registers them in its USB probe), so
it adopts instead of creating and renames them onto the context's stable name;
its `prune()` is a no-op; and the QMAP id on the wire is `0x80 + channel`, not
the config's channel number. Its head comments cite the driver lines each
decision comes from, and `tests/test_datapath_nss.uc` pins them.

## 5. Adding telemetry

Telemetry decoders live in the per-transport backends and are chosen per
capability:

- **QMI** — add a decoder to `src-ucode/qmi_backend.uc` returning a **normalized
  shape** (the same shape the daemon renders, regardless of transport). Verify
  the QMI message id + every TLV id against libqmi's `data/qmi-service-*.json`
  (a wrong tag silently decodes garbage) and add a hand-built-wire-buffer test to
  `test_qmi_backend` (or `test_mbim_backend` for MBIM).
- **MBIM** — `src-ucode/mbim_backend.uc` (native MS Basic Connect Extensions) or
  the passthrough (reusing the QMI decoder).
- **Selection** — wire it into the modem's per-capability resolver via
  `backend.choose` (native → passthrough → AT), and into the adaptive
  `watch_driver` refresh loop so it only polls while a consumer watches
  (`modem_signal`/`modem_cells`).
- **Surface** — the daemon exposes it via `status()` / `modem_signal` /
  `modem_cells`; keep the shape identical across backends so the UI stays neutral.
- **Radio type / IoT variant** — the canonical vocabulary lives in one place,
  `src-ucode/codec/schema/rat.uc` (GSM…5G plus NB-IoT / LTE-M / EC-GSM-IoT /
  RedCap / NTN). Add a source mapper there (`from_*`), give it a `test_rat.uc`
  case, and — since the IoT variants are only visible over AT — feed it through
  `modem_common.probe_iot_rat` (AT+QNWINFO) / `collect_caps`. It surfaces as
  `status.rat` (current fine access tech) + `status.caps` `{rats,iot_modes,ntn}`.
- **A SIM EF wwand should re-apply** (like the forbidden-PLMN list `EF_FPLMN`):
  read/write via QMI UIM READ/WRITE_TRANSPARENT with an `AT+CRSM` fallback for
  modems whose UIM rejects EF access (see `sim.uc` `read_fplmn`/`write_fplmn`),
  and register it as a `wwand_plmnlist` type so the daemon restores it before
  every radio-on.

---

## 6. Adding a ubus method

1. **Daemon method** — implement `self.my_method(args…, cb)` in `src-ucode/daemon.uc`.
2. **ubus binding** — in `src-ucode/ubus.uc`, add the method. For a deferred
   (async) reply, route through the shared `defer(req, run, watchdog_ms?)` helper
   so the request completes exactly once and a dropped callback can't leak it:

   ```
   my_method: {
       args: { modem: '', ubus_rpc_session: '' },
       call: (req) => defer(req, (reply) =>
           daemon.my_method(req.args.modem, (err, res) =>
               reply(err ? { ok: false, ...err } : { ok: true, ...res }))),
   },
   ```

   Every method callable from LuCI must accept `ubus_rpc_session: ''` (rpcd
   injects it).
3. **ACL** — grant read/write in the LuCI ACL JSON (`luci-app-wwand` /
   `luci-proto-wwand` `root/usr/share/rpcd/acl.d/*.json`).
4. **Test** — assert it end-to-end in `test_daemon` (real ubusd) or against the
   daemon directly in `test_netsel`.

---

## 7. Extending the LuCI UI

Two packages, both editing `/etc/config/network` and calling the `wwand` ubus
object:

- **`luci-proto-wwand`** (`…/protocol/qmi.js`) — the interface/connection form
  under *Network → Interfaces*. Radio/SIM options are stored on the interface's
  `wwand_modem` section via the `bindModem()` redirect (so saving converts to the
  network-native model); connection options stay on the interface.
- **`luci-app-wwand`** (`…/view/wwand/*.js`) — the *Mobile Data* status/settings
  page: live signal/cells, band/mode/roaming (pushed to the daemon at runtime,
  not UCI), network selection, SIM slots, **per-SIM overrides** (`wwand_sim`
  sections), PIN enable/disable, and eSIM.

`node --check` every JS file. LuCI cannot be host-tested — validate in a browser
on the router. For a visual tour of the existing panels (what each view looks
like and where a new field lands), see [luci.md](luci.md).

---

## 8. Adding a board profile

Board-specific modem power/reset GPIOs and status LEDs live in one table in
`src-ucode/board.uc`, keyed by the `/etc/board.json` model id. To support a new
router, add an entry:

```
'vendor,my-router': {
    power_gpio: 'modem-power',      // named GPIO gating modem USB power (optional)
    reset_gpio: 'modem-reset',      // named GPIO on the modem RESET line (optional)
    option_ids: [ '2c7c 0800' ],    // usb-serial `option` new_id binds (optional)
    // render the panel from { present, registered, radio, roaming, bars }:
    leds: (fx, s) => render_bars(fx, [ 'green:sig-1', 'green:sig-2', 'green:sig-3' ],
                                 s.registered ? s.bars : 0),
},
```

The GPIO / LED names are the kernel's line/LED names (`ls /sys/class/gpio`,
`ls /sys/class/leds`). `leds(fx, s)` may use the helpers `render_bars` (an
N-LED signal graph) or `render_mobile` (red/green(+orange) mobile + a tech LED);
`bars` is derived by `bars_from_signal`. Everything goes through the injectable
`fx` (read/write/list), so add a case to `test_board.uc` with a recording fx and
assert the GPIO/LED writes — **no hardware needed**. An unknown board keeps the
null profile (all ops no-op), so nothing else changes. The recovery ladder and
the `modem_repower` ubus method pick this up automatically; the config
`reset_gpio` option overrides the board default per modem.

---

## 9. Testing

```
cd wwand/tests && sh run_tests.sh      # host-side, no hardware
```

The suites drive the **real codec** through a mock hub (`tests/lib/mockhub.uc`
for QMI, `mbim_mockhub.uc` for MBIM) and a private `ubusd` for the daemon
integration test. Everything is wired through **effect injection** (`fx`,
`transport_open`, `deps`), so a field bug becomes a scenario:

- **Codec / decoder** — hand-build the wire buffer with the libqmi-correct tags
  (mockhub `__raw` path) so a wrong schema tag fails the test, not passes silently.
- **Modem/context flow** — a `scenario()` in `test_modem` / `test_context` with
  scripted handler responses + injected indications.
- **Config** — feed `config.parse` / `config.migrate_plan` raw section objects and
  assert the model.
- **Pure logic** — unit-test the extracted helper (`modem_common`, `recovery`,
  `context_common`) directly.

Needs a host `ucode` with `fs`/`struct`/`uloop` (+ `ubus`/`uci` and a `ubusd`
binary for `test_daemon`, skipped otherwise). See
[reference.md → Development](reference.md#development).
