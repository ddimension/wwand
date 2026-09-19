#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# wwand — refuse regex syntax ucode cannot compile.
#
# ucode's regexes are POSIX ERE. Constructs every other language spells the same
# way are not merely unsupported there, they are a COMPILE ERROR raised when the
# literal is first evaluated — and a regex literal inside a callback is evaluated
# when that callback runs, which is typically inside uloop. The throw kills the
# daemon; procd respawns it into the identical crash.
#
# This is not hypothetical. `(?:...)` in the AT+QPINC parser shipped in 495afc8
# (2026-07-24) and was reachable only when a PIN was set AND the modem answered
# QPINC with a payload line, so no test and no test router ever walked it. On the
# target it raises "Repetition not preceded by valid expression", on the host
# build "Invalid preceding regular expression". Found by review, 2026-09-19.
#
# Run from the repo root:  tools/check-regex-portability.py

import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# ONE generic rule, not a list of spellings. `(?` opens every construct POSIX
# ERE lacks — non-capturing groups, lookaround, atomic and branch-reset groups,
# inline flags, comments, recursion, conditionals — and enumerating them invites
# missing the next one. It has no collision in ucode source: `(?` is not valid
# outside a regex.
#
# A lazy-quantifier rule (`*?`, `+?`, `??`) deliberately does NOT exist here.
# `??` is ucode's null-coalescing operator and appears on hundreds of lines; the
# first version of this checker produced 53 false positives and not one true
# one. A checker that cries wolf is worse than no checker.
BANNED = re.compile(r'\(\?')

# STRINGS ARE SCANNED, comments are not. Four call sites build a regex from a
# TABLE ENTRY at runtime — netlink.uc:621, atcmd.uc:89, protocol_switch.uc:71,
# modeswitch.uc:71 all do `regexp(<entry>.pattern)` over vendor-matching tables
# whose patterns are string literals in the source. A banned construct there
# compiles at first use and throws exactly like a literal would, so skipping
# string contents would blind this checker to the likeliest place for the next
# one to be added. Comments, by contrast, must be skipped: this tree DESCRIBES
# the construct in prose on purpose (atcmd_parse.uc:642, :787).
def scannable(line, in_block):
    """Return (text to search, new in_block) — the parts of `line` a banned
    construct could really live in.

    STRING CONTENTS ARE SEARCHED, comments are not. Four call sites build a
    regex from a table entry at runtime (netlink.uc:621, atcmd.uc:89,
    protocol_switch.uc:71, modeswitch.uc:71 all do `regexp(<entry>.pattern)`
    over vendor-matching tables whose patterns are string literals), so a banned
    construct in a string compiles at first use and throws exactly like a
    literal. Comments must be skipped because this tree describes the construct
    in prose on purpose (atcmd_parse.uc:642, :787).

    THE LEXER KNOWS STRINGS, and it has to. A first version did not, so the
    `/*` in `fx.glob('/sys/class/net/*')` (netlink.uc:713) opened a block
    comment that never closed and hid the remaining 1000 lines of that file.
    The version after it dropped block comments altogether on the false premise
    that this tree has none — it has three (test_daemon.uc:1127,
    test_client.uc:157, test_recovery.uc:18), and their prose would then have
    been scanned as code. Both mistakes were caught in review, 2026-09-19.
    """
    out, i, n = [], 0, len(line)

    while i < n:
        if in_block:
            j = line.find('*/', i)
            if j < 0:
                return ''.join(out), True
            i, in_block = j + 2, False
            continue

        c = line[i]

        if c == '"' or c == "'":
            i += 1
            start = i
            while i < n and line[i] != c:
                i += 2 if line[i] == '\\' else 1
            out.append(line[start:i])       # the CONTENT, not the quotes
            i += 1
            continue

        if line[i:i+2] == '//':
            break

        if line[i:i+2] == '/*':
            in_block = True
            i += 2
            continue

        out.append(c)
        i += 1

    return ''.join(out), in_block


def main():
    bad = 0
    files = sorted(ROOT.glob('src-ucode/**/*.uc')) + sorted(ROOT.glob('tests/**/*.uc'))

    for f in files:
        in_block = False
        for n, line in enumerate(f.read_text().splitlines(), 1):
            code, in_block = scannable(line, in_block)

            if not BANNED.search(code):
                continue

            print(f'{f.relative_to(ROOT)}:{n}: `(?` — ucode uses POSIX ERE, which has no')
            print( '    non-capturing group, lookaround, atomic group or inline flags.')
            print( '    The literal THROWS when it is evaluated; inside a callback that')
            print( '    means inside uloop, which kills the daemon. Use a plain group and')
            print( '    shift the capture indices, or restructure the match.')
            print(f'    {line.strip()}')
            bad += 1

    print(f'checked {len(files)} .uc files: {bad} non-POSIX regex construct(s)')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
