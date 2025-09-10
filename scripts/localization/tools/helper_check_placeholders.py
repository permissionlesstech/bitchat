#!/usr/bin/env python3
"""
helper_check_placeholders.py — Validate placeholder consistency between EN and localized values.

Usage:
  python3 helper_check_placeholders.py <csv-file>

Checks that the set and count of placeholders (%@, %d, %f, %u, %x, %%, and positional like %1$@)
match between the 'en' and 'localized' columns per row. Reports mismatches and exits non-zero.
"""
import csv
import re
import sys
from pathlib import Path

PH_RE = re.compile(r"%(?:\d+\$)?[@difsux]|%%")

def extract(s: str):
    return sorted(PH_RE.findall(s or ''))

def main(path: str) -> int:
    p = Path(path)
    mismatches = []
    with p.open('r', encoding='utf-8') as f:
        r = csv.DictReader(f)
        for i, row in enumerate(r, start=2):
            en = row.get('en', '')
            loc = row.get('localized', '')
            k = row.get('key','')
            ph_en = extract(en)
            ph_loc = extract(loc)
            if ph_en != ph_loc:
                mismatches.append((i, k, ph_en, ph_loc))
    if mismatches:
        print(f"❌ Placeholder mismatches in {p}:")
        for i,k,a,b in mismatches[:50]:
            print(f"  line {i}: key={k} en={a} loc={b}")
        print(f"Total mismatches: {len(mismatches)}")
        return 1
    print(f"✅ Placeholders OK in {p}")
    return 0

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('Usage: helper_check_placeholders.py <csv-file>')
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
