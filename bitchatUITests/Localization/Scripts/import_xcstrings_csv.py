#!/usr/bin/env python3
"""
import_xcstrings_csv.py — Import a locale CSV back into a .xcstrings catalog.

Purpose:
  Reads a CSV with columns key,en,<locale> and updates the <locale> values in the
  JSON-based .xcstrings file.

Usage:
  ./bitchatUITests/Localization/Scripts/import_xcstrings_csv.py <xcstrings> <csv_file> <locale>

Examples:
  python3 import_xcstrings_csv.py bitchat/Localization/Localizable.xcstrings localization_exports/es.csv es

Dependencies: Python 3 standard library only (json, csv, pathlib).
"""
import csv
import json
import sys
from pathlib import Path

def main(xcstrings: str, csv_file: str, locale: str) -> int:
    xp = Path(xcstrings)
    cp = Path(csv_file)
    if not xp.exists():
        print(f"❌ File not found: {xp}", file=sys.stderr)
        return 2
    if not cp.exists():
        print(f"❌ File not found: {cp}", file=sys.stderr)
        return 2
    data = json.loads(xp.read_text(encoding='utf-8'))
    strings = data.get('strings', {})
    with cp.open(newline='', encoding='utf-8') as fh:
        r = csv.DictReader(fh)
        if 'key' not in r.fieldnames or locale not in r.fieldnames:
            print(f"❌ CSV must contain columns: key and {locale}", file=sys.stderr)
            return 3
        updates = {row['key']: row.get(locale, '') for row in r}

    changed = 0
    for key, entry in strings.items():
        if key not in updates:
            continue
        new_val = updates[key]
        locs = entry.setdefault('localizations', {})
        unit = locs.setdefault(locale, {}).setdefault('stringUnit', {})
        if unit.get('value') != new_val:
            unit['value'] = new_val
            unit['state'] = 'translated' if new_val else unit.get('state', '')
            changed += 1

    xp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"✅ Updated {changed} entries for locale {locale}")
    return 0

if __name__ == '__main__':
    if len(sys.argv) != 4:
        print('Usage: import_xcstrings_csv.py <xcstrings> <csv_file> <locale>', file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2], sys.argv[3]))

