#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 André Valentin <avalentin@marcant.net>
"""Check that the packaging of this tree is complete and unambiguous.

Three invariants are stated in prose in several places — CLAUDE.md, the feed
Makefile's own comments, and the openwrt/packages review threads. Prose cannot
fail a build, and all three have been violated at least once in ways nothing
noticed until a reviewer read the release tree by hand:

  1. Every `.uc` file is installed by EXACTLY ONE package. A file owned by none
     ships nowhere — `atcmd_mbim.uc`/`atcmd_mbim_lazy.uc` did exactly that in
     wwand 1.5.1, and because `modem_common.uc` require()s the shim unguarded
     that was a runtime throw, not a missing feature. A file owned by two
     packages makes them non-co-installable.
  2. Every file the Makefile NAMES exists in the source tree. The explicit
     install lists fail closed (a new file ships nowhere) rather than open, but
     only if a rename is noticed — `datapath_qmi.uc` became
     `modem_datapath_qmi.uc` in 1.6.0 and both Makefiles had to follow.
  3. Every `$(PKG_BUILD_DIR)/files/...` path resolves, or the install step dies.

Plus the build-side list the repo's own CMakeLists.txt guards at configure time,
checked here too so a drift is caught before a build is even started.

Usage:
    tools/check-packaging.py                        # CMakeLists vs src-ucode
    tools/check-packaging.py --makefile ../repository/wwand/Makefile
    tools/check-packaging.py --makefile <path> --tarball wwand-1.6.0.tar.gz

`--tarball` checks a RELEASE rather than the working tree, which is what the
packaging actually consumes and the only form that catches "committed but not
tagged". Exit status is non-zero on any violation, so this belongs in CI and in
the release checklist.
"""

import argparse
import os
import re
import sys
import tarfile


def read_sources(root=None, tarball=None):
    """Return (uc_files, files_entries) relative to the package root."""
    if tarball:
        with tarfile.open(tarball) as tf:
            names = [n.split('/', 1)[1] for n in tf.getnames() if '/' in n]
    else:
        names = []
        for base, _dirs, fs in os.walk(root):
            for f in fs:
                names.append(os.path.relpath(os.path.join(base, f), root))

    uc = sorted(n[len('src-ucode/'):] for n in names
                if n.startswith('src-ucode/') and n.endswith('.uc'))
    files = sorted(n for n in names if n.startswith('files/'))

    return uc, files


def makefile_value(mk, var):
    """The value of `var:=...`, following backslash continuations and no further.

    Reading the assignment as a LOGICAL line matters: a pattern that merely runs
    to the next top-level word swallows the comment block that follows, and the
    prose there says things like "ship readable .uc source" — which parsed as a
    module named `.uc` and reported a package as installing a file that does not
    exist. The bug was in the checker both times it fired.
    """
    lines = mk.splitlines()
    for i, line in enumerate(lines):
        if not line.startswith(var + ':='):
            continue
        out = [line.split(':=', 1)[1]]
        while out[-1].rstrip().endswith('\\'):
            i += 1
            if i >= len(lines):
                break
            out.append(lines[i])
        return ' '.join(p.rstrip().rstrip('\\') for p in out)

    return None


def makefile_owners(mk, uc):
    """Map each installed .uc to the packages that install it.

    Understands both shapes this project uses: the `WWAND_*_UC/_CODEC/_SCHEMA`
    variables the base package expands, and per-package `$(INSTALL_DATA)` lines
    (including the one directory glob, which is legitimate because that whole
    directory belongs to a single package).
    """
    owners = {}

    def claim(f, pkg):
        owners.setdefault(f, []).append(pkg)

    # variable-driven lists; the prefix is where that variable installs to
    for var, prefix in (('WWAND_BASE_UC', ''),
                        ('WWAND_BASE_CODEC', 'codec/'),
                        ('WWAND_BASE_SCHEMA', 'codec/schema/')):
        value = makefile_value(mk, var)
        if value is None:
            continue
        for tok in value.split():
            if tok.endswith('.uc'):
                claim(prefix + tok, 'wwand (%s)' % var)

    pkg = None
    for line in mk.splitlines():
        d = re.match(r'define Package/([a-z0-9_-]+)/install', line)
        if d:
            pkg = d.group(1)
            continue
        if line.startswith('endef'):
            pkg = None
            continue
        if not pkg:
            continue

        g = re.search(r'\$\(WWAND_UCODE\)/(\S+)/\*\.uc', line)
        if g:
            # DIRECT children only: a shell glob does not descend, so claiming
            # every descendant would report a nested file as installed when the
            # real install step would silently omit it — a false negative
            # against the one invariant this tool exists for.
            prefix = g.group(1) + '/'
            for f in uc:
                if f.startswith(prefix) and '/' not in f[len(prefix):]:
                    claim(f, pkg)
            continue

        # only real install commands count — INSTALL_DATA for the modules and
        # INSTALL_BIN for main.uc/wwandctl.uc, which install as executables.
        # Matching any mention would let a COMMENT naming a module make an
        # uninstalled file look owned, which is exactly the kind of false clean
        # bill this tool must not give.
        m = re.search(r'\$\(WWAND_UCODE\)/(\S+\.uc)', line)
        if m and ('INSTALL_DATA' in line or 'INSTALL_BIN' in line):
            claim(m.group(1), pkg)

    return owners


def cmake_listed(root, tarball=None):
    """The explicit source lists the repo-root CMakeLists.txt builds from.

    Read from the TARBALL when one is given. Reading the working tree's copy
    while checking a release compares two different trees: a stale release
    passes because the tree has since been fixed, and an older good release
    fails against newer lists. Either way the answer would be about the wrong
    thing.
    """
    if tarball:
        with tarfile.open(tarball) as tf:
            member = next((n for n in tf.getnames()
                           if n.split('/', 1)[-1] == 'CMakeLists.txt'), None)
            if not member:
                return None
            raw = tf.extractfile(member).read().decode('utf-8', 'replace')
            return _cmake_lists(raw)

    path = os.path.join(root, 'CMakeLists.txt')
    if not os.path.exists(path):
        return None

    return _cmake_lists(open(path).read())


def _cmake_lists(raw):
    # Strip comments FIRST. These lists carry explanatory comments between the
    # entries, and a `)` inside one (`require()d`, say) ends a non-greedy match
    # early — which reported two perfectly well-listed files as missing the
    # first time this ran. A checker that cries wolf gets switched off.
    txt = re.sub(r'#[^\n]*', '', raw)
    listed = set()
    for var in ('WWAND_UCODE_MODULES', 'WWAND_UCODE_PROGRAMS', 'WWAND_UCODE_PLAIN'):
        m = re.search(r'set\(%s\b(.*?)^\)' % var, txt, re.S | re.M)
        if not m:
            raise SystemExit('CMakeLists.txt: no set(%s ...) block found — '
                             'the checker cannot verify the build lists' % var)
        listed.update(t for t in m.group(1).split() if t.endswith('.uc'))

    return listed


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', default=os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), help='package root (default: this repo)')
    ap.add_argument('--makefile', help='a packaging Makefile to audit')
    ap.add_argument('--tarball', help='check a release tarball instead of the tree')
    args = ap.parse_args()

    bad = 0

    def fail(msg):
        nonlocal bad
        bad += 1
        print('FAIL: %s' % msg)

    uc, files = read_sources(None if args.tarball else args.root, args.tarball)
    where = args.tarball or args.root
    print('source: %s — %d .uc files, %d files/ entries' % (where, len(uc), len(files)))

    # --- build-side list (working tree only; a tarball has the same file) ---
    listed = cmake_listed(args.root, args.tarball)
    if listed is not None:
        for f in uc:
            if f not in listed:
                fail('%s is not in any CMakeLists.txt source list '
                     '(add it to WWAND_UCODE_MODULES/_PROGRAMS/_PLAIN)' % f)
        for f in sorted(listed - set(uc)):
            fail('CMakeLists.txt lists %s, which does not exist' % f)
        if not bad:
            print('ok: CMakeLists.txt covers all %d .uc files exactly' % len(uc))

    if not args.makefile:
        return 1 if bad else 0

    mk = open(args.makefile).read()
    owners = makefile_owners(mk, uc)

    for f in uc:
        if f not in owners:
            fail('%s is installed by NO package (it would ship nowhere)' % f)
    for f, pkgs in sorted(owners.items()):
        if f not in uc:
            fail('%s is installed but does not exist in the source' % f)
        elif len(pkgs) > 1:
            fail('%s is installed by %s — packages must stay co-installable'
                 % (f, ' and '.join(pkgs)))

    refs = set(re.findall(r'\$\(PKG_BUILD_DIR\)/(files/[^\s\\)]+)', mk))
    for r in sorted(refs):
        if r not in files:
            fail('%s is installed but does not exist in the source' % r)

    if not bad:
        print('ok: %s owns every .uc exactly once and all %d files/ paths resolve'
              % (os.path.basename(os.path.dirname(args.makefile)), len(refs)))

    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
