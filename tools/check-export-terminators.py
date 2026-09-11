#!/usr/bin/env python3
"""Every module-level `export function` must be closed with `};`, not `}`.

This guards a rule the test suite CANNOT check, which is the whole reason it
exists as a separate tool.

OpenWrt's ucode parser refuses a module whose `export function` body ends in a
bare `}` — it reports "Expecting ';'" against the NEXT export, several lines
away, so the error does not even point at the offending line. The host ucode the
suite runs on is newer and lenient: it accepts both, every test passes, and the
module is broken only on the target. `docs/gotchas.md` has carried that warning
for a while; it shipped anyway, in `wwandctl_fmt.uc` in v1.6.4 (r71), where it
made `wwandctl` unusable — reported as ddimension/wwand#17 within hours of the
release, by a user, on hardware. A warning nothing enforces is a warning that
gets forgotten.

    tools/check-export-terminators.py [path ...]      # default: src-ucode

The rule is deliberately dumb, because a dumb rule cannot be fooled: in this
tree every top-level brace sits at column 0, so the line closing an
`export function` is simply the next one that starts with `}`. No brace
counting, and therefore nothing for a brace inside a string, a comment or a
regex to confuse — an earlier attempt that did count braces produced nine false
positives out of twelve hits.

One shape does not fit that rule and is handled separately: a one-line export
(`export function err(...) { log(...); };`, log.uc:98-102) closes on its own
line, where the same `;` is still required.

Exit code 1 when anything is wrong, so it can gate a release.
"""

import pathlib
import re
import sys

EXPORT = re.compile(r'export\s+function\s+\w+')


def check(root):
    bad, total = [], 0

    for path in sorted(pathlib.Path(root).rglob('*.uc')):
        lines = path.read_text().split('\n')

        for i, line in enumerate(lines):
            if not EXPORT.match(line):
                continue

            total += 1

            # a one-liner closes on its own line; it still needs the `;`
            if line.rstrip().endswith('}') or line.rstrip().endswith('};'):
                if not line.rstrip().endswith('};'):
                    bad.append((path, i + 1, i + 1,
                                EXPORT.match(line).group(0), line.rstrip()[-3:]))
                continue

            for j in range(i + 1, len(lines)):
                if not lines[j].startswith('}'):
                    continue

                if lines[j].rstrip() != '};':
                    bad.append((path, i + 1, j + 1,
                                EXPORT.match(line).group(0), lines[j].rstrip()))
                break
            else:
                bad.append((path, i + 1, None,
                            EXPORT.match(line).group(0), '<never closed at column 0>'))

    return total, bad


def main():
    roots = sys.argv[1:] or ['src-ucode']
    total, bad = 0, []

    for r in roots:
        t, b = check(r)
        total += t
        bad += b

    for path, decl_line, end_line, decl, ending in bad:
        where = '%s:%s' % (path, end_line if end_line else '?')
        print('FAIL: %s ends %r — `%s` at %s:%d must close with `};`'
              % (where, ending, decl, path, decl_line))

    print('checked %d export functions in %s: %d not terminated with `};`'
          % (total, ', '.join(roots), len(bad)))

    if bad:
        print('  (the host ucode accepts these; the OpenWrt one does not, and '
              'blames the NEXT export several lines down)')

    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
