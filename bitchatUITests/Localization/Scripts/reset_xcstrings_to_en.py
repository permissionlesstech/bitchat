#!/usr/bin/env python3
"""
reset_xcstrings_to_en.py — Copy English values to other locales in a .xcstrings file.

Purpose:
  For each key, sets the specified locales' values to the English value. Useful to
  seed or reset missing locales while keeping the keyset aligned.

Usage:
  ./bitchatUITests/Localization/Scripts/reset_xcstrings_to_en.py <xcstrings> [--locales es,fr,...]

Examples:
  - Reset specific locales:
      python3 reset_xcstrings_to_en.py bitchat/Localization/Localizable.xcstrings --locales es,fr
  - Reset all locales (except en):
      python3 reset_xcstrings_to_en.py bitchat/Localization/Localizable.xcstrings

Dependencies: Python 3 standard library only (json, pathlib).
"""
import json
import sys
from pathlib import Path

def main(xcstrings: str, locales_csv: str | None) -> int:
    p = Path(xcstrings)
    if not p.exists():
        print(f"❌ File not found: {p}", file=sys.stderr)
        return 2
    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.get('strings', {})
    targets = [s.strip() for s in (locales_csv or '').split(',') if s.strip()]

    all_locales = set()
    for e in strings.values():
        all_locales.update((e.get('localizations') or {}).keys())
    all_locales.discard('en')
    if not targets:
        targets = sorted(all_locales)

    changed = 0
    for key, entry in strings.items():
        en = (entry.get('localizations', {}).get('en') or {}).get('stringUnit', {}).get('value', '')
        for loc in targets:
            unit = entry.setdefault('localizations', {}).setdefault(loc, {}).setdefault('stringUnit', {})
            if unit.get('value') != en:
                unit['value'] = en
                unit['state'] = 'translated'
                changed += 1
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"✅ Reset {changed} entries across {len(targets)} locales to English")
    return 0

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: reset_xcstrings_to_en.py <xcstrings> [--locales a,b,c]', file=sys.stderr)
        raise SystemExit(2)
    locales = None
    if len(sys.argv) == 4 and sys.argv[2] == '--locales':
        locales = sys.argv[3]
    raise SystemExit(main(sys.argv[1], locales))

