#!/usr/bin/env python3
"""
update_xcstrings_value.py — Update a single locale value for a key in a .xcstrings file.

Usage:
  python3 scripts/update_xcstrings_value.py <file> <key> <locale> <value>
"""
import json
import sys
from pathlib import Path

def main(file, key, locale, value):
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
        print("Usage: update_xcstrings_value.py <file> <key> <locale> <value>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3], ' '.join(sys.argv[4:])))

