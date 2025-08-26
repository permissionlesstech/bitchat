#!/usr/bin/env python3
"""
export_xcstrings_csv.py — Export .xcstrings to per-locale CSV files.

Purpose:
  Writes one CSV per target locale with columns: key,en,<locale>.

Usage:
  ./bitchatUITests/Localization/Scripts/export_xcstrings_csv.py <xcstrings> <out_dir> [--locales es,fr,...]

Examples:
  - All locales present:
      python3 export_xcstrings_csv.py bitchat/Localization/Localizable.xcstrings localization_exports
  - Specific locales only:
      python3 export_xcstrings_csv.py bitchat/Localization/Localizable.xcstrings localization_exports --locales es,fr

Dependencies: Python 3 standard library only (json, csv, pathlib).
"""
import csv
import json
import sys
from pathlib import Path

def main(xcstrings: str, out_dir: str, locales_csv: str | None) -> int:
    p = Path(xcstrings)
    if not p.exists():
        print(f"❌ File not found: {p}", file=sys.stderr)
        return 2
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.get('strings', {})

    all_locales = set()
    for e in strings.values():
        all_locales.update((e.get('localizations') or {}).keys())
    all_locales.discard('en')
    targets = [s.strip() for s in (locales_csv or '').split(',') if s.strip()] or sorted(all_locales)

    for loc in targets:
        rows = []
        for key, e in strings.items():
            locs = e.get('localizations', {})
            en = (locs.get('en') or {}).get('stringUnit', {}).get('value', '')
            val = (locs.get(loc) or {}).get('stringUnit', {}).get('value', '')
            rows.append((key, en, val))
        out_file = out / f"{loc}.csv"
        with out_file.open('w', newline='', encoding='utf-8') as fh:
            w = csv.writer(fh)
            w.writerow(['key', 'en', loc])
            w.writerows(rows)
        print(f"📤 Wrote {out_file} ({len(rows)} rows)")
    return 0

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print('Usage: export_xcstrings_csv.py <xcstrings> <out_dir> [--locales a,b,c]', file=sys.stderr)
        raise SystemExit(2)
    locales = None
    if len(sys.argv) == 5 and sys.argv[3] == '--locales':
        locales = sys.argv[4]
    raise SystemExit(main(sys.argv[1], sys.argv[2], locales))

