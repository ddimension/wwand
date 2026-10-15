#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Fail on ucode constructs that parse, run, and silently do the wrong thing.

One so far: CALLING A PARENTHESIZED `??`,

    let c = (o.cursor_isolated ?? o.cursor)();     # c is null
    (o.timer ?? uloop.timer)(wait, fn);            # overwrites a neighbouring local

When the left operand is set and the right one is a member expression, the
interpreter's stack ends up one slot off: assigned, the value is null; as a
bare statement, a neighbouring local is overwritten. No error either way, and
the fallback path works, so a test that only exercises it passes. Only the
`return (a ?? b)()` form (and an arrow body, which is one) is safe. Verified on
the host ucode and on ucode-2026.07.09~b885dd0f (RG650E, 2026-10-10; the table
is in docs/gotchas.md). Write it as two statements:

    let mk = o.cursor_isolated ?? o.cursor;
    let c = mk();

Flagged here regardless of what the right operand is: whether it is a member
expression is easy to misjudge, and two statements are never wrong.

Usage: check-ucode-pitfalls.py [root]   (default: src-ucode)
"""

import os
import re
import sys

# directly after `return` or an arrow `=>`: the one safe form
SAFE = re.compile(r'(?:\breturn|=>)\s*$')


def mask_noncode(src):
    """The source with comments and string literals blanked out, offsets and
    newlines kept — so a `(` or `??` inside either cannot count."""
    out = list(src)
    i, state = 0, None

    while i < len(src):
        c = src[i]

        if state in ("'", '"', '`'):
            if c == '\\':
                out[i] = ' '
                if i + 1 < len(src) and src[i + 1] != '\n':
                    out[i + 1] = ' '
                i += 2
                continue
            if c == state:
                state = None
            if c != '\n':
                out[i] = ' '
        elif state == 'block':
            if src.startswith('*/', i):
                out[i:i + 2] = '  '
                state = None
                i += 2
                continue
            if c != '\n':
                out[i] = ' '
        elif src.startswith('//', i):
            end = src.find('\n', i)
            end = len(src) if end < 0 else end
            out[i:end] = ' ' * (end - i)
            i = end
            continue
        elif src.startswith('/*', i):
            out[i:i + 2] = '  '
            state = 'block'
            i += 2
            continue
        elif c in ("'", '"', '`'):
            state = c
            out[i] = ' '

        i += 1

    return ''.join(out)


def bad_calls(src):
    """Line numbers of every called parenthesized `??` outside a return —
    balanced over the whole file, so a call split over lines or one with
    parentheses inside the `??` is found as well."""
    code = mask_noncode(src)
    stack = []

    for i, ch in enumerate(code):
        if ch == '(':
            stack.append(i)
        elif ch == ')' and stack:
            start = stack.pop()
            inner = code[start + 1:i]

            # the `??` must be at THIS level, not inside a nested call
            depth, top = 0, False
            for k, x in enumerate(inner):
                if x == '(':
                    depth += 1
                elif x == ')':
                    depth -= 1
                elif depth == 0 and inner.startswith('??', k):
                    top = True
                    break

            if not top:
                continue

            # an argument list — `foo(a ?? b)(…)` — is not a parenthesized
            # `??`: its `(` follows a name, a `)` or a `]`
            k = start - 1
            while k >= 0 and code[k].isspace():
                k -= 1

            if k >= 0 and (code[k].isalnum() or code[k] in '_$)]'):
                continue

            j = i + 1
            while j < len(code) and code[j].isspace():
                j += 1

            if j < len(code) and code[j] == '(' and not SAFE.search(code[:start]):
                yield src.count('\n', 0, start) + 1


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else 'src-ucode'
    hits = []
    files = 0

    for dirpath, _, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith('.uc'):
                continue

            path = os.path.join(dirpath, name)
            files += 1

            with open(path, encoding='utf-8') as f:
                src = f.read()

            lines = src.splitlines()

            for n in bad_calls(src):
                hits.append((path, n, lines[n - 1].strip()))

    for path, n, text in hits:
        print(f'{path}:{n}: call of a parenthesized `??` — misplaces the stack when the left side is set; split it into two statements')
        print(f'    {text}')

    print(f'checked {files} .uc files under {root}: {len(hits)} called `(a ?? b)()` outside a return')
    return 1 if hits else 0


if __name__ == '__main__':
    sys.exit(main())
