#!/usr/bin/env python3
"""Generate src-ucode/atport.uc from ModemManager port-type udev rules.

Usage: gen-atport-table.py <modemmanager-checkout> > ../src-ucode/atport.uc

Parses src/plugins/*/77-mm-*port-types.rules and emits a ucode module
mapping "vid:pid" -> { "<usb interface number>": role }, with roles:
  at    AT primary port
  at2   AT secondary port
  ppp   AT/PPP port
  gps   NMEA/GPS data port
Other tags (QCDM, AUDIO, IGNORE) are dropped to keep the table small.
"""

import re
import subprocess
import sys
from pathlib import Path

ROLE_MAP = {
    'ID_MM_PORT_TYPE_AT_PRIMARY': 'at',
    'ID_MM_PORT_TYPE_AT_SECONDARY': 'at2',
    'ID_MM_PORT_TYPE_AT_PPP': 'ppp',
    'ID_MM_PORT_TYPE_GPS': 'gps',
}

LINE_RE = re.compile(
    r'ATTRS\{idVendor\}=="([0-9a-fA-F]{4})",\s*'
    r'ATTRS\{idProduct\}=="([0-9a-fA-F]{4})",\s*'
    r'ENV\{\.MM_USBIFNUM\}=="([0-9a-fA-F]{2})",\s*'
    r'SUBSYSTEM=="tty",\s*'
    r'ENV\{(ID_MM_PORT_TYPE_[A-Z_]+)\}="1"')


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)

    root = Path(sys.argv[1])
    table = {}
    skipped = 0

    for rules in sorted(root.glob('src/plugins/*/77-mm-*port-types.rules')):
        for line in rules.read_text().splitlines():
            line = line.strip()

            if not line or line.startswith('#'):
                continue

            m = LINE_RE.search(line)

            if not m:
                if 'ID_MM_PORT_TYPE' in line:
                    skipped += 1
                continue

            vid, pid, ifnum, tag = m.groups()
            role = ROLE_MAP.get(tag)

            if role is None:
                continue

            key = f'{vid.lower()}:{pid.lower()}'
            table.setdefault(key, {})[f'{int(ifnum, 16)}'] = role

    try:
        commit = subprocess.check_output(
            ['git', '-C', str(root), 'rev-parse', '--short', 'HEAD'],
            text=True).strip()
    except Exception:
        commit = 'unknown'

    print('// wwand — AT/GPS port roles by USB id and interface number.')
    print('// GENERATED FILE, DO NOT EDIT.')
    print(f'// Source: ModemManager port-type udev rules (commit {commit}),')
    print('// https://gitlab.freedesktop.org/mobile-broadband/ModemManager')
    print('// Regenerate: tools/gen-atport-table.py <mm-checkout> > src-ucode/atport.uc')
    print('// License of the source data: GPL-2.0-or-later.')
    print('// CommonJS-style (return) so it can be require()d lazily.')
    print()
    print("'use strict';")
    print()
    print('return {')

    for key in sorted(table):
        ports = ', '.join(f"'{ifn}': '{role}'"
                          for ifn, role in sorted(table[key].items(), key=lambda kv: int(kv[0])))
        print(f"\t'{key}': {{ {ports} }},")

    print('};')

    devices = len(table)
    print(f'parsed {devices} devices, {skipped} non-matching tagged lines skipped',
          file=sys.stderr)


if __name__ == '__main__':
    main()
