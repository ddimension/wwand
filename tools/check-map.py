#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Verify every `file.uc symbol` pair cited by docs/map.md still resolves.

map.md is a REVERSE index: keyed by the question a person debugging actually
has, not by subsystem. It exists because this tree's 8700 lines of docs answer
"what is the datapath" very well and "which module prints this log line" not at
all — and that second question is the one that costs the time.

Anchored by SYMBOL, not by line. `check-anchors.py` already resolves
`file.ext:123` anchors, but a line number in a lookup table rots on every edit
above it and would make the map a maintenance tax rather than a help. A symbol
survives refactoring inside a file and fails loudly when the thing is renamed or
moved, which is exactly when the map is wrong.

Accepts the definition forms this tree actually uses — a module-level function,
an arrow bound to a `let`, an object member, and a method hung on `self`:

    export function conn_cfg(          function nr_convention(
    let retry_activate = ...           retire_wan6: (parent) => {
    self.usb_repower = function(       const RUNGS = [

(The const form was missing from the first version of this list, and the map's
own first draft is what found that — two citations the tree does define came
back BROKEN. A checker whose pattern list is short fails safe: it complains
about something real rather than passing something wrong.)

Usage: tools/check-map.py
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
mapfile = root / 'docs' / 'map.md'

# `file.uc symbol` / `file.sh symbol` as the table writes them, in backticks
CITE = re.compile(r'`([A-Za-z_0-9./-]+\.(?:uc|sh|js|py))\s+([A-Za-z_][A-Za-z_0-9]*)`')

SEARCH = ('src-ucode', 'files', 'tools', '.')

# A definition inside a comment or a string is not a definition. Blanked
# offset-preserving, so line reporting stays honest. Raised by Codex review,
# 2026-09-24: without this, a symbol named only in a block comment — and this
# tree comments heavily, often quoting the very symbol it discusses — would
# satisfy a citation that nothing implements.
def strip_noise(s):
    out, i, n = list(s), 0, len(s)
    while i < n:
        c = s[i]
        if c in "'\"`":
            j = i + 1
            while j < n:
                if s[j] == '\\':
                    j += 2
                    continue
                if s[j] == c:
                    break
                j += 1
            for k in range(i, min(j + 1, n)):
                out[k] = ' '
            i = j + 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            j = s.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '*':
            j = s.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                out[k] = ' '
            i = j
            continue
        if c == '#' and (i == 0 or s[i - 1] == '\n'):     # shell / python
            j = s.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
            continue
        i += 1
    return ''.join(out)

def defines(path, sym):
    try:
        s = strip_noise(path.read_text())
    except OSError:
        return None                      # file itself missing — reported separately
    pats = [
        rf'^\s*(?:export\s+)?function\s+{re.escape(sym)}\s*\(',
        rf'^\s*let\s+{re.escape(sym)}\s*=',
        rf'^\s*(?:export\s+)?const\s+{re.escape(sym)}\s*=',
        rf'^\s*{re.escape(sym)}\s*:\s*(?:function|\()',
        rf'^\s*self\.{re.escape(sym)}\s*=',
        rf'^\s*{re.escape(sym)}\s*\(\s*\)\s*\{{',        # shell function
        rf'^\s*{re.escape(sym)}\s*=\s*',
    ]
    return any(re.search(p, s, re.M) for p in pats)

if not mapfile.exists():
    print('docs/map.md is missing')
    sys.exit(1)

bad, ok = [], 0
for m in CITE.finditer(mapfile.read_text()):
    name, sym = m.group(1), m.group(2)
    # EVERY match, not the first. Two files with the same basename in different
    # search roots would otherwise be silently collapsed into whichever root
    # comes first in SEARCH, and a citation could then be validated against a
    # file the reader will never open. Codex review, 2026-09-24.
    hits = [root / d / name for d in SEARCH if (root / d / name).exists()]

    if not hits:
        bad.append((name, sym, 'no such file'))
        continue
    if len({h.resolve() for h in hits}) > 1:
        bad.append((name, sym, 'ambiguous: %s' % ', '.join(
            str(h.relative_to(root)) for h in hits)))
        continue
    hit = hits[0]
    if not defines(hit, sym):
        bad.append((name, sym, 'file has no such symbol'))
        continue
    ok += 1

for name, sym, why in bad:
    print('  BROKEN  %s %s — %s' % (name, sym, why))

print('checked %d map citations: %d resolve, %d broken' % (ok + len(bad), ok, len(bad)))
sys.exit(1 if bad else 0)
