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

  * IN-TREE anchors (`context.uc:712`, `view/wwand/status.js:543`, checked 2026-09-10) are resolved against the
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
    tools/check-anchors.py --since HEAD    # also catch anchors a local edit has MOVED
    tools/check-anchors.py --since HEAD --fix

--since REV closes the gap the plain check leaves open. An anchor pointing at
a line that still exists passes it, even when an edit above that line has
moved its target somewhere else. Removing comment lines is the usual cause: a
mechanical pass over the QMI modules on 2026-09-24 would have left 21 anchors
across the tree pointing next to their target, and only a content comparison
by hand caught it. So: for every in-tree anchor that already existed at REV,
the target file at REV is diffed against the working tree. If the line the
anchor named then now sits at another number, it is reported as SHIFTED (and
rewritten with --fix). If that line was itself changed or deleted, the anchor
is reported as STALE, because no tool can tell what it should point at now.
An anchor that did not exist at REV was written against the current file and
is left alone.
"""

import argparse
import difflib
import os
import re
import subprocess
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


def git_show(root, rev, rel):
    """File content at REV, or None when it did not exist there / no git."""
    try:
        r = subprocess.run(['git', '-C', root, 'show', '%s:%s' % (rev, rel)],
                           capture_output=True, text=True, errors='replace')
    except OSError:
        return None
    return r.stdout if r.returncode == 0 else None


def line_map(old, new):
    """old 1-based line number -> new line number, or None for a changed/deleted
    line. Only EQUAL blocks map: a line inside a replaced block has no successor
    anyone can name with confidence, and guessing one is how an anchor rots."""
    m = {}
    sm = difflib.SequenceMatcher(a=old, b=new, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            for k in range(i2 - i1):
                m[i1 + k + 1] = j1 + k + 1
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument('--extern', action='append', default=[],
                    help='a tree to resolve out-of-tree anchors in (repeatable)')
    ap.add_argument('--show', action='store_true', help='print the cited line for in-tree anchors')
    ap.add_argument('--since', metavar='REV',
                    help='also report anchors whose target line moved since REV (git)')
    ap.add_argument('--fix', action='store_true',
                    help='with --since: rewrite SHIFTED anchors to the new line number')
    args = ap.parse_args()

    maps, olds = {}, {}      # per target / citing file, computed once

    def target_map(path):
        rel = os.path.relpath(path, args.root)
        if rel not in maps:
            old = git_show(args.root, args.since, rel)
            if old is None:
                maps[rel] = None
            else:
                with open(path, encoding='utf-8', errors='replace') as fh:
                    maps[rel] = line_map(old.split('\n'), fh.read().split('\n'))
        return maps[rel]

    def existed_at_rev(rel, anchor):
        if rel not in olds:
            olds[rel] = git_show(args.root, args.since, rel) or ''
        return anchor in olds[rel]

    shifted, stale, fixes = [], [], {}

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

                        if args.since and where == 'in-tree' and existed_at_rev(rel, m.group(0)):
                            mp = target_map(src)
                            if mp is not None:
                                ns = mp.get(start)
                                if ns is None:
                                    stale.append((rel, lineno, m.group(0)))
                                elif ns != start:
                                    ne = (mp.get(int(end)) or int(end) + ns - start) if end else None
                                    new = '%s:%d%s' % (name, ns, ('-%d' % ne) if ne else '')
                                    shifted.append((rel, lineno, m.group(0), new))
                                    fixes.setdefault(path, []).append((m.group(0), new))

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

    if shifted:
        print('\nSHIFTED since %s — the target line moved; the anchor still names its old number%s:'
              % (args.since, ' (rewritten)' if args.fix else ''))
        for rel, lineno, anchor, new in shifted:
            print('  %s:%d  %s -> %s' % (rel, lineno, anchor, new))

    if stale:
        print('\nSTALE since %s — the cited line itself was changed or removed; re-read '
              'the comment and point it at what it means:' % args.since)
        for rel, lineno, anchor in stale:
            print('  %s:%d  %s' % (rel, lineno, anchor))

    if args.fix:
        for path, subs in fixes.items():
            with open(path, encoding='utf-8') as fh:
                text = fh.read()
            for old, new in subs:
                text = re.sub(re.escape(old) + r'(?![0-9-])', new, text, count=1)
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write(text)

    print('\nchecked %d anchors: %d broken, %d ambiguous, %d undated, %d unresolved%s'
          % (checked, len(bad), len(ambiguous), len(undated), len(unresolved),
             (', %d shifted, %d stale since %s' % (len(shifted), len(stale), args.since))
             if args.since else ''))

    return 1 if (bad or stale or (shifted and not args.fix)) else 0


if __name__ == '__main__':
    sys.exit(main())
