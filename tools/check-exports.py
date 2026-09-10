#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 André Valentin <avalentin@marcant.net>
"""Report exported symbols nothing uses, and exports whose only user is a test.

The second category is the interesting one, and it is why this exists. A helper
that only the tests call LOOKS covered — the suite is green, the checks read
sensibly — while production never goes near it, so the tests prove nothing about
the shipped behaviour. That is not hypothetical: `fmt.signalKind()` in
luci-app-wwand was added with nine tests and referenced from production only in a
COMMENT; an external reviewer found it, not the suite. Reverting the helper's
body left every test passing.

That example is JavaScript and this tool reads ucode, so it would NOT have
caught that one — it is cited because the failure mode is the same on both
sides of the fence, and the ucode side has no reviewer reading it line by line.

Two distinctions keep the number honest, and without them it is noise:

  * `codec/schema/**` is protocol VOCABULARY. QMI and MBIM enumerations are
    written out in full so a decoder reads like the specification and the next
    feature does not have to re-derive a constant from a capture. An unused
    `UIM_CARD_STATE_ABSENT` is not debt. Those files are skipped.
  * A symbol exported AND used inside its own module is not dead. It is exported
    because the module's own tests reach for it, which is a legitimate seam.
    Only symbols referenced nowhere at all — not even at home — are reported.

Exit code 1 when something is genuinely unreferenced, 0 otherwise; the
tests-only list is advisory and never fails the run, because "make it reachable
or delete it" is a judgement the author has to make.

Usage:
    tools/check-exports.py
    tools/check-exports.py --tests-only-fails      # stricter, for a release
"""

import argparse
import os
import re
import sys

EXPORT_RE = re.compile(r'^export\s+(?:function|const|let)\s+([A-Za-z_][A-Za-z_0-9]*)', re.M)


def read(path):
    with open(path, encoding='utf-8') as fh:
        return fh.read()


def sources(root):
    out = []
    for base, _dirs, files in os.walk(os.path.join(root, 'src-ucode')):
        for f in sorted(files):
            if f.endswith('.uc'):
                out.append(os.path.join(base, f))
    return sorted(out)


def is_vocabulary(path):
    """protocol enumerations, deliberately complete — see the module docstring"""
    return '/schema/' in path or '/mbim_schema/' in path


def used(name, text):
    return re.search(r'\b%s\b' % re.escape(name), text) is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument('--tests-only-fails', action='store_true',
                    help='also exit 1 when a test is an export\'s only user')
    args = ap.parse_args()

    srcs = sources(args.root)
    if not srcs:
        print('no src-ucode/*.uc found under %s' % args.root, file=sys.stderr)
        return 2

    tests = ''
    tdir = os.path.join(args.root, 'tests')
    if os.path.isdir(tdir):
        tests = '\n'.join(read(os.path.join(tdir, f))
                          for f in sorted(os.listdir(tdir)) if f.endswith('.uc'))

    bodies = {p: read(p) for p in srcs}
    total = 0
    dead, tests_only = [], []

    for p in srcs:
        if is_vocabulary(p):
            continue

        own = bodies[p]
        elsewhere = '\n'.join(b for q, b in bodies.items() if q != p)
        mod = os.path.basename(p)[:-3]

        for m in EXPORT_RE.finditer(own):
            name = m.group(1)
            total += 1

            if used(name, elsewhere):
                continue
            # more than the export line itself -> the module uses its own symbol
            if len(re.findall(r'\b%s\b' % re.escape(name), own)) > 1:
                continue

            (tests_only if used(name, tests) else dead).append((mod, name))

    if dead:
        print('UNREFERENCED — exported and used by nothing, not even its own module:')
        for mod, name in sorted(dead):
            print('  %-20s %s' % (mod, name))

    if tests_only:
        print('%sTESTS ONLY — the suite is the only caller, so it proves nothing '
              'about shipped behaviour:' % ('\n' if dead else ''))
        for mod, name in sorted(tests_only):
            print('  %-20s %s' % (mod, name))
        print('  (either reach it from production or drop it — a green test on an '
              'unreachable helper is worse than no test)')

    if not dead and not tests_only:
        print('ok: every one of the %d non-vocabulary exports is reachable from production'
              % total)
    else:
        print('\nchecked %d non-vocabulary exports: %d unreferenced, %d tests-only'
              % (total, len(dead), len(tests_only)))

    return 1 if (dead or (tests_only and args.tests_only_fails)) else 0


if __name__ == '__main__':
    sys.exit(main())
