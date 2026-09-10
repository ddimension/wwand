#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 André Valentin <avalentin@marcant.net>
"""Verify the `file.ext:LINE` anchors this tree's comments cite.

CLAUDE.md asks for every external claim to be anchored and dated, because an
unanchored claim cannot be re-verified, only believed, and it decays silently
when the dependency moves. The anchors make the claim checkable — but nothing
was checking them, and they rot exactly like any other reference: an
`addrconf.c:3386-3391` written here named the three lines BEFORE the ones it
described, cutting off the two fields the sentence went on to list.

What this can and cannot do:

  * IN-TREE anchors (`context.uc:714`, `view/wwand/status.js:543`, checked 2026-09-10) are resolved against the
    file and the cited line is printed, so a reviewer sees at a glance whether it
    still says what the comment claims. A line number past the end of the file is
    an error — that one is unambiguous.
  * OUT-OF-TREE anchors (`addrconf.c`, `luci.js`, `interface.c`, `form.js`) are
    resolved only when a search root for them is given, because kernel and netifd
    trees live outside this repo and their line numbers are version-specific. A
    comment citing them should also name the version it was checked against;
    this flags the ones that do not.

It deliberately does NOT try to judge whether the cited line supports the claim.
That is reading, not tooling. It answers the cheaper question — does the anchor
still point at a line at all, and is the version recorded.

Usage:
    tools/check-anchors.py
    tools/check-anchors.py --extern /vol/release/.../linux-6.18.41 --extern ~/projects/upstream/netifd
    tools/check-anchors.py --show          # print the cited line for every in-tree anchor
"""

import argparse
import os
import re
import sys

# `name.ext:123` or `name.ext:123-456`, as they appear inside comments
ANCHOR_RE = re.compile(r'\b([A-Za-z_0-9./-]+\.(?:c|h|js|uc|sh|py|json|mk)):(\d+)(?:-(\d+))?\b')
# a version or date recorded near the anchor makes an out-of-tree citation re-checkable
VERSION_RE = re.compile(r'\b(?:[0-9]+\.[0-9]+(?:\.[0-9]+)?|20[0-9]{2}-[0-9]{2}-[0-9]{2})\b')

SCAN_DIRS = ('src-ucode', 'files', 'io/src', 'tools', 'docs')


def comment_lines(path):
    """(lineno, text, block) for comment/prose lines.

    `block` is the whole contiguous comment paragraph the line belongs to. The
    version or date that makes an out-of-tree citation re-checkable belongs to
    the CLAIM, not to the line the anchor happens to land on, and comments wrap:
    "libqmi 1.38" ends a line and "qmi-errors.h:240" opens the next. Checking a
    single line reported both halves of one correct citation as undated.
    """
    ext = os.path.splitext(path)[1]
    with open(path, encoding='utf-8', errors='replace') as fh:
        raw = fh.readlines()

    keep = []
    for i, line in enumerate(raw, 1):
        s = line.strip()
        keep.append(ext == '.md' or s.startswith(('//', '*', '/*', '#')))

    out = []
    i = 0
    while i < len(raw):
        if not keep[i]:
            i += 1
            continue
        j = i
        while j < len(raw) and keep[j]:
            j += 1
        block = ''.join(raw[i:j])
        for k in range(i, j):
            out.append((k + 1, raw[k], block))
        i = j
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument('--extern', action='append', default=[],
                    help='a tree to resolve out-of-tree anchors in (repeatable)')
    ap.add_argument('--show', action='store_true', help='print the cited line for in-tree anchors')
    args = ap.parse_args()

    # ALL candidates per basename, never just the first. Resolving `status.js`
    # to whichever copy the walk happened to reach first produced a confident
    # "BROKEN — status.js has only 467 lines" against a 467-line status.js from
    # an unrelated LuCI app, while the 808-line one the comment meant sat two
    # directories away. A tool that is wrong with conviction is worse than no
    # tool, so an ambiguous name is reported as ambiguous.
    intree = {}
    for base, _dirs, files in os.walk(args.root):
        if '/.git' in base:
            continue
        for f in files:
            intree.setdefault(f, []).append(os.path.join(base, f))

    extern = {}
    for tree in args.extern:
        for base, _dirs, files in os.walk(tree):
            for f in files:
                extern.setdefault(f, []).append(os.path.join(base, f))

    bad, unresolved, undated, ambiguous, checked = [], [], [], [], 0

    for d in SCAN_DIRS:
        top = os.path.join(args.root, d)
        if not os.path.isdir(top):
            continue
        for base, _dirs, files in os.walk(top):
            for f in sorted(files):
                path = os.path.join(base, f)
                rel = os.path.relpath(path, args.root)
                for lineno, text, block in comment_lines(path):
                    for m in ANCHOR_RE.finditer(text):
                        name, start, end = m.group(1), int(m.group(2)), m.group(3)
                        target = os.path.basename(name)
                        checked += 1

                        cands = intree.get(target) or []
                        where = 'in-tree'
                        if not cands:
                            cands = extern.get(target) or []
                            where = 'extern'

                        if not cands:
                            unresolved.append((rel, lineno, m.group(0)))
                            continue

                        # an anchor written with directories ("view/wwand/status.js")
                        # disambiguates itself
                        if '/' in name:
                            narrowed = [c for c in cands if c.endswith(name)]
                            if narrowed:
                                cands = narrowed

                        last = int(end) if end else start
                        lengths = []
                        for c in cands:
                            with open(c, encoding='utf-8', errors='replace') as fh:
                                lengths.append((c, fh.readlines()))

                        fits = [(c, b) for c, b in lengths if last <= len(b)]

                        # Ambiguity only matters when it changes the answer. Two
                        # checkouts of the same file (a reference clone beside the
                        # working one) both have the line, so which was meant is
                        # moot; report only when the candidates DISAGREE.
                        if len(cands) > 1 and 0 < len(fits) < len(cands):
                            ambiguous.append((rel, lineno, m.group(0), len(cands)))
                            continue

                        if not fits:
                            src, body = lengths[0]
                            bad.append((rel, lineno, m.group(0),
                                        '%s has only %d lines' % (target, len(body))))
                            continue

                        src, body = fits[0]

                        if where == 'extern' and not VERSION_RE.search(block):
                            undated.append((rel, lineno, m.group(0)))

                        if args.show and where == 'in-tree':
                            print('  %s:%d -> %s:%d  %s'
                                  % (rel, lineno, target, start, body[start - 1].rstrip()[:70]))

    for rel, lineno, anchor, why in bad:
        print('BROKEN  %s:%d cites %s — %s' % (rel, lineno, anchor, why))

    if undated:
        print('%sUNDATED — an out-of-tree anchor with no version or date beside it '
              'cannot be re-checked once that tree moves:' % ('\n' if bad else ''))
        for rel, lineno, anchor in undated:
            print('  %s:%d  %s' % (rel, lineno, anchor))

    if ambiguous:
        print('%sAMBIGUOUS — several files carry this name, so the anchor cannot be '
              'resolved; write enough of the path to pick one:' % ('\n' if bad or undated else ''))
        for rel, lineno, anchor, n in ambiguous:
            print('  %s:%d  %s  (%d candidates)' % (rel, lineno, anchor, n))

    if unresolved:
        print('%sUNRESOLVED — no such file in this tree or any --extern tree '
              '(pass the tree, or the anchor names something that moved):'
              % ('\n' if bad or undated else ''))
        for rel, lineno, anchor in unresolved:
            print('  %s:%d  %s' % (rel, lineno, anchor))

    print('\nchecked %d anchors: %d broken, %d ambiguous, %d undated, %d unresolved'
          % (checked, len(bad), len(ambiguous), len(undated), len(unresolved)))

    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
