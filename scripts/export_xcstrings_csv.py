#!/usr/bin/env python3
"""
export_xcstrings_csv.py — Export .xcstrings to CSV for translation.

Creates one CSV per requested locale with columns:
  key,en,<locale>

Usage:
  python3 scripts/export_xcstrings_csv.py <xcstrings> <out_dir> [--locales es,fr,zh-Hans,ar,ru,pt-BR]
If --locales is omitted, exports all locales present in the file (excluding 'en').
"""
import csv
import json
import os
import sys
from pathlib import Path

def main(path: str, out_dir: str, locales_csv: str | None) -> int:
    p = Path(path)
    if not p.exists():
        print(f"❌ File not found: {p}", file=sys.stderr)
        return 2
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.get('strings', {})

    all_locales = set()
    for e in strings.values():
        all_locales.update(e.get('localizations', {}).keys())
    all_locales.discard('en')

    targets = [s.strip() for s in locales_csv.split(',')] if locales_csv else sorted(all_locales)
    for loc in targets:
        rows = []
        for key, e in strings.items():
            locs = e.get('localizations', {})
            en = locs.get('en', {}).get('stringUnit', {}).get('value', '')
            val = locs.get(loc, {}).get('stringUnit', {}).get('value', '')
            rows.append((key, en, val))
        out_file = out / f"{loc}.csv"
        with out_file.open('w', newline='', encoding='utf-8') as fh:
            w = csv.writer(fh)
            w.writerow(['key','en',loc])
            for r in rows:
                w.writerow(r)
        print(f"📤 Wrote {out_file} ({len(rows)} rows)")
    return 0

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print('Usage: export_xcstrings_csv.py <xcstrings> <out_dir> [--locales a,b,c]', file=sys.stderr)
        sys.exit(2)
    locales = None
    if len(sys.argv) == 5 and sys.argv[3] == '--locales':
        locales = sys.argv[4]
    sys.exit(main(sys.argv[1], sys.argv[2], locales))

