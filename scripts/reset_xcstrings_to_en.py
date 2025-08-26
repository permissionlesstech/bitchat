#!/usr/bin/env python3
"""
reset_xcstrings_to_en.py — Force all locale values to match English for every key.

This is useful if you want a clean slate before retranslation to avoid
wrong-locale residue. Existing keys are preserved; only values are overwritten.

Usage:
  python3 scripts/reset_xcstrings_to_en.py <path-to-.xcstrings> [--locales es,fr,...]

If --locales is omitted, resets all locales except 'en'.
"""
import json
import sys
from pathlib import Path

def main(file: str, only_locales: list[str] | None) -> int:
    p = Path(file)
    if not p.exists():
        print(f"❌ File not found: {p}", file=sys.stderr)
        return 2
    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.get('strings', {})

    # Collect all locales
    all_locales = set()
    for e in strings.values():
        all_locales.update(e.get('localizations', {}).keys())
    all_locales.discard('en')
    targets = set(only_locales) if only_locales else all_locales

    changed = 0
    for key, entry in strings.items():
        locs = entry.get('localizations', {})
        en_val = locs.get('en', {}).get('stringUnit', {}).get('value', '')
        if en_val is None:
            en_val = ''
        for loc in targets:
            unit = locs.setdefault(loc, {}).setdefault('stringUnit', {})
            if unit.get('value') != en_val:
                unit['value'] = en_val
                unit['state'] = 'translated'
                changed += 1

    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"✅ Reset {changed} entries across {len(targets)} locales to English")
    return 0

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: reset_xcstrings_to_en.py <file> [--locales a,b,c]', file=sys.stderr)
        sys.exit(2)
    file = sys.argv[1]
    locales = None
    if len(sys.argv) == 4 and sys.argv[2] == '--locales':
        locales = [s.strip() for s in sys.argv[3].split(',') if s.strip()]
    sys.exit(main(file, locales))

