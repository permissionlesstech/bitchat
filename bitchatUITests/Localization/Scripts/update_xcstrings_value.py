#!/usr/bin/env python3
"""
update_xcstrings_value.py — Update a single locale value for a key in a .xcstrings file.

Purpose:
  Sets the value for a given key and locale, marking the unit as translated.

Usage:
  ./bitchatUITests/Localization/Scripts/update_xcstrings_value.py <file> <key> <locale> <value>

Example:
  python3 update_xcstrings_value.py bitchat/Localization/Localizable.xcstrings accessibility.add_favorite es "Añadir a favoritos"

Dependencies: Python 3 standard library only (json, pathlib).
"""
import json
import sys
from pathlib import Path

def main(file: str, key: str, locale: str, value: str) -> int:
    p = Path(file)
    if not p.exists():
        print(f"❌ File not found: {p}", file=sys.stderr)
        return 2
    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.get('strings', {})
    if key not in strings:
        print(f"❌ Key not found: {key}", file=sys.stderr)
        return 3
    locs = strings[key].setdefault('localizations', {})
    unit = locs.setdefault(locale, {}).setdefault('stringUnit', {})
    unit['state'] = 'translated'
    unit['value'] = value
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"✅ Updated {key} [{locale}] = {value}")
    return 0

if __name__ == '__main__':
    if len(sys.argv) < 5:
        print('Usage: update_xcstrings_value.py <file> <key> <locale> <value>', file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2], sys.argv[3], ' '.join(sys.argv[4:])))

