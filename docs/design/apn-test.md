<!-- SPDX-License-Identifier: GPL-2.0-only -->
<!-- Design proposal: a scheduled end-to-end APN test package for wwand,
     replacing marcant-apntester. Written for a service provider running
     dedicated test boxes that sweep many APNs across several SIMs and eSIM
     profiles, some of them with an accounting cross-check. Proposal, not
     shipped behaviour — nothing in this file describes code that exists. -->

# `wwand-apntest` — scheduled end-to-end APN tests

> **Design proposal, 2026-09-11.** Nothing here is implemented yet. It is
> written against the existing `marcant-apntester` (Release_2024.10,
> `marcant-extras/packages/vpn2go/marcant-apntester`) and against wwand's ubus
> surface as of v1.6.5. Where the two disagree with reality, reality wins and
> this file is wrong.

## The job

A service provider has to know that its APNs work — not that a modem registers,
but that a subscriber on that APN gets the right IP from the right pool, reaches
the right hosts, and is **billed the right number of bytes**. That is an
end-to-end test, it has to run unattended on a schedule, and its result has to
land in monitoring with enough detail to act on.

The boxes doing this are **dedicated test boxes**: the modem exists to be
dialled and hung up, there is no production traffic to protect. That single fact
removes most of the difficulty — the tester may own the modem outright, one
context at a time, and does not need to hide beside a live session.

What it must do instead is **sweep**: several APNs, across several SIMs, some of
them profiles on an eUICC rather than cards in a slot. Sequentially, because a
modem has one radio.

## What exists today, and what of it survives

`marcant-apntester` is 1109 lines of shell. Roughly 900 of them are a **fork of
the legacy netifd QMI proto handler** — `proto_qmi_get_wds_cid`,
`_start_network`, `_checkpin`, `_waitreg`, `_settechnology`, `_teardown`, a
hand-rolled `udhcpc` invocation and a USB reset. That is the layer wwand
replaced. The test logic proper — ping, check the IP and DNS against a regex,
report to NSCA, source the extra tests from `/etc/apntester-tests/` — is perhaps
200 lines, and all of it is worth keeping.

So the proposal is a package that contains **only the upper 200 lines**, driving
wwand over ubus for everything below.

Three defects in the current tool are worth recording, because each one is a
requirement in disguise.

**The accounting test counts the wrong interface.** It reads
`grep wwan0: /proc/net/dev`, which is the *parent* netdev. With QMAP multiplexing
— wwand's normal case — that aggregates every channel on the modem, so the
comparison against the operator's byte counter is silently wrong whenever
anything else is up. wwand samples the **modem's own WDS packet statistics** per
call and sums them across address families (`context_monitor_qmi.uc:108-155`).
That is not merely the tidier counter: it is the modem's view of the session,
which is the thing the operator bills against.

**Credentials are in the package.** `/etc/apntester-tests/accounting` carries an
OAuth client secret, a user password and a monitoring URL with embedded basic
auth, and ships as a `conffile`. They belong in `/etc/config` at `0600`, or in a
credentials file referenced from there — not in a package anyone can unpack.

**`reboot` is used as error recovery.** `cleanup()` reboots the router once
`maxtries` is reached. wwand already owns an escalation path (retry → opmode
cycle → modem reset → board power-cycle → reboot) with a persisted rung. A
tester should feed that counter, not jump to its last rung.

## Shape

A separate package, `wwand-apntest`, `DEPENDS:=+wwand`. It speaks ubus and knows
nothing about QMI or MBIM, so it works on every backend for free.

```
wwand-apntest
  /usr/sbin/wwand-apntest          CLI: run, list, status, last
  /usr/share/ucode/wwand/apntest/  plan, runner, sinks
  /usr/libexec/wwand-apntest/      test plugins (ping, accounting, …)
  /etc/config/apntest              the plan
```

eSIM steps additionally need `wwand-esim` (which needs lpac). That is a runtime
dependency of a *plan*, not of the package: a plan that never names a profile
runs without it, and a plan that does should fail with "wwand-esim not
installed" rather than silently skipping the step.

## The sweep

A run walks a **plan** — an ordered list of tests, each naming an APN and the
SIM it must be tested on. The interesting part is not the dialling; it is the
cost of getting to the right SIM.

### The two switches, and what they really cost

| step | mechanism | what actually happens |
|---|---|---|
| physical slot | `modem_sim_switch_slot {modem, slot}` | drops the connection; on the NCM/AT backend it **always ends in a modem reset**, which normally re-enumerates the USB device so the bring-up restarts via hotplug (`reference.md`, "Per-SIM settings / dual-SIM") |
| eSIM profile | `modem_esim {modem, op:'enable', iccid}` | eUICC REFRESH → SIM re-init → re-register; no USB re-enumeration |

Both are **asynchronous in a way the ubus reply does not capture**: the call
returns long before the modem is usable again. The runner must therefore wait on
*state*, not on the reply — modem back to `READY` and registered, with a budget
— and must tolerate the device disappearing and coming back under it.

Two consequences for the plan:

- **Order by SIM, not by APN.** Tests are grouped so that each slot switch and
  each profile enable happens once per run. A plan listing five APNs on SIM A
  and two on SIM B costs two switches, not seven.
- **A switch failure fails a group, not a run.** If the modem will not come back
  on slot 2, every test bound to slot 2 is reported as such, and the sweep
  continues with the next SIM.

### The run, step by step

```
lock(modem)                       one run per modem, ever
remember(active slot, active profile)
for each sim-group in plan:
    select(sim)                   slot switch and/or profile enable, then wait
                                  for READY + registered, with a budget
    for each test in group:
        context_up(test context)  wwand dials; settings come back on ubus
        wait CONNECTED or fail    budget per test
        snapshot counters         from the modem, before the checks
        run checks                plugins, in order, each with its own budget
        snapshot counters again
        context_down
        report(verdict)           one verdict per test, immediately
    optional: detach              operating mode low-power between groups
restore(slot, profile)            also on abort, also on a crash
unlock(modem)
```

Three properties this shape is chosen for:

- **Every test reports on its own.** A sweep that dies in the middle must still
  have delivered verdicts for everything it already did. Monitoring that only
  hears from a completed run cannot distinguish "APN broken" from "test box
  wedged".
- **The state is restored.** A test box left on the wrong slot after a failed run
  is a test box whose next run tests the wrong SIM and reports a false failure.
  Restoration belongs in the same place as the lock: released on every exit path.
- **Budgets everywhere.** A slot switch that never completes must end the group,
  not the night. A full sweep needs a deadline of its own, because the sum of
  the parts is what the schedule has to fit into.

### Detach between groups

`imsi_detach` in the current tool sets the modem to low-power after a test so the
SIM stops being attached to the network. It matters to an SP for a reason worth
stating: an idle attached SIM keeps a subscriber context in the operator's core,
and on some tariffs that is billable, and in some tests it is exactly what is
being measured. It stays, per plan rather than global, and it is a *step in the
sweep* — it belongs between groups, not inside the teardown of a single test.

## Configuration

Close enough to the current `/etc/config/apntester` that a migration is
mechanical, but with the SIM named explicitly rather than implied by whatever the
box happened to boot with.

```
config apntest 'globals'
    option modem        'wwmodem0'
    option schedule     '*/30 * * * *'
    option run_budget   '1800'          # seconds for the whole sweep
    option restore_sim  '1'             # put the box back as it was

config apntest_sim 'cda'
    option slot         '1'             # physical slot …
    # option profile    '8949…'         # … or an eUICC profile ICCID

config apntest 'vodafone_cda'
    option sim          'cda'
    option apn          'cda.vodafone.de'
    option auth         'pap'
    option username     'mccp@vpn2go.com'
    option password     '…'
    option ip_regex     '^172\.'
    option dns_regex    '217\.14\.1'
    option detach_after '1'
    list  check         'ping:172.30.0.1'
    list  check         'ping:172.30.0.2'
    list  check         'accounting'
    option service      'apn-cda.vodafone.de'
```

`config apntest_sim` is the piece the current model lacks. Today a test inherits
whichever SIM is active; with a sweep the SIM has to be part of the test's
identity, or a run's results cannot be attributed.

## Interfaces

**ubus**, so LuCI and monitoring see the same thing the CLI does:

| method | args | Description |
|---|---|---|
| `apntest.list` | — | the plan, grouped as it will be executed |
| `apntest.run` | `test?`, `sim?` | run the sweep, one group, or one test |
| `apntest.status` | — | what is running now, and how far in |
| `apntest.last` | `test?` | the last verdict per test, with its timestamp |

**Test plugins** get a contract instead of the current `. $i` source-into-scope.
Today a plugin inherits `$ifname`, `$HOST`, `$SERVICE` and calls
`proto_qmi_log`; it is coupled to the internals of a script that is about to be
replaced. The tree already has a precedent for the better shape
(`docs/datapath-interface.md`): a plugin is an executable that reads a JSON
context on stdin and writes a JSON verdict on stdout.

```json
{ "test": "vodafone_cda", "apn": "cda.vodafone.de", "sim": "cda",
  "netdev": "wwand3", "ipv4": { "address": "…", "gateway": "…", "dns": [ … ] },
  "counters_before": { "rx_bytes": 0, "tx_bytes": 0 },
  "deadline": 240 }
```

```json
{ "state": "ok|warning|critical", "message": "…",
  "perfdata": { "rta": 23.4, "loss": 0 } }
```

That makes the accounting plugin backend-independent — the same file runs
against QMI, MBIM and NCM — and makes it testable without a modem.

**Sinks** are configuration, not code paths. NSCA stays (Icinga is what is
deployed); a Prometheus textfile and syslog are the obvious companions. A
verdict is a structure; where it goes is a list.

## Accounting: accounts, not endpoints

The field settled this before the design asked it. Four distinct endpoints are
in use across the twelve reachable boxes:

| endpoint | protocol | boxes |
|---|---|---|
| `api-ng.m-ccp.de` | basic auth in the URL, `/<simtype>/<simid>/status`, sum `.statusList[1].currentTraffic.counter[].bytesTotal` | 9 |
| `m-ccp-be1.ioteasyconnect.de` | same protocol, different operator host | 2 |
| `api.ioteasyconnect.de` | OAuth2 password grant, `/api/v1/simcard/<id>/status` -> `traffic_used`, then logout | 2 |
| a `.cz` instance | same as the line above, own credentials | not on these boxes (operator-confirmed) |

So there are **two protocols and N accounts**, not two providers. That is
already visible on `.27`, where the shipped test has been refactored by hand
into `iec_api_baseurl=` and `mccp_api_url=` variables — with the m-ccp path
commented out, so that box counts through IEC only. The account model
formalises what that edit was reaching for, and moves the credentials into
`/etc/config` at 0600 instead of a packaged conffile.

```
config apntest_account 'iec_de'
    option type     'iec'            # oauth2 + /api/v1/simcard/<id>/status
    option base_url 'https://api.ioteasyconnect.de'
    option client_id '…'
    option client_secret '…'
    option username '…'
    option password '…'

config apntest_account 'iec_cz'      # same protocol, own credentials
    option type     'iec'
    option base_url 'https://api.ioteasyconnect.cz'

config apntest_account 'mccp'
    option type     'mccp'           # basic auth, statusList
    option base_url 'https://api-ng.m-ccp.de'

config apntest 'vf_m2m'
    option account  'iec_de'
    option sim_id   '262021608171418'
    option sim_type 'globalsim'      # simcard | globalsim
    list  check     'accounting'
```

Two details worth carrying over rather than rediscovering:

- **`.statusList[1]` is a hard-coded index into a list.** It is the second
  entry, not a lookup, and nothing in the old code checks that the entry it
  lands on describes the SIM being tested. Before the plugin copies that, the
  shape of a real answer has to be looked at once.
- **A check that cannot run must say so.** The old test returns 0 — success —
  when `mccp_simid` or `mccp_simtype` is unset. Three boxes have no id set, so
  their accounting has never run and has never said anything about it. Here
  that is UNKNOWN with a reason.

## What this deliberately does not do

No second dialler, no `udhcpc`, no PIN, registration, technology-preference or
PLMN logic. All of that is in the daemon, is tested there, and has had its
hardware bugs found already. A tester that reimplements it will reimplement the
bugs too — which is, precisely, the history of the tool being replaced.

No `reboot`. Failures feed the recovery counter; the ladder decides.

No parallel contexts. On a dedicated test box there is nothing to run beside, so
the runner takes the modem, uses one context, and gives it back. The plugin
contract carries a netdev rather than assuming one, so the same plugins would
still work if a future version needed to test beside a live session on a
production box — but nothing is built for that case now.

## Open questions

- **Does a group need its own registration check before dialling?** Registering
  on the wrong PLMN after a slot switch is a distinct failure from an APN that
  will not dial, and an SP probably wants to see the difference. Cheap to add;
  needs a decision on whether it is a separate verdict or part of the APN one.
- **How long is the accounting settle time, really?** The current test sleeps
  180 s before and after the transfer, twice, which puts a floor of six minutes
  on every accounting test and therefore on the sweep. If the operator API's
  update interval is known, that number should come from configuration; if it
  is not, it should be measured once rather than guessed forever.
- **Should a failing APN be retried inside the run?** The current tool retries
  with `retries`/`retrysleep` and counts tries across runs towards a reboot. With
  a sweep there is a cheaper option: finish the pass, then retry only the
  failures, which keeps one slow APN from delaying everything behind it.

## Phases

1. **Sweep skeleton.** Package, config model, the group-by-SIM plan, slot
   switching, `context_up`/`down` per test, the ping check, the NSCA sink. This
   already replaces the current tool for the non-accounting cases.
2. **eSIM groups.** Profile enable as a selection step, with the `wwand-esim`
   dependency surfaced as a plan error rather than a silent skip.
3. **Accounting.** The plugin contract, modem-side counters, credentials out of
   the package and into configuration.
4. **LuCI.** Last verdicts, a manual run button. Only once 1-3 are stable —
   a test box that reports correctly matters more than one that looks good.
