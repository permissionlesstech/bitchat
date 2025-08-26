#!/usr/bin/env python3
"""
sync_xcstrings.py — Ensure all locales in a .xcstrings have values for every key.

Purpose:
  Fills missing or empty locale values with the Base (English) value. Preserves
  existing translations, only filling gaps to keep keysets in sync.

Usage:
  ./bitchatUITests/Localization/Scripts/sync_xcstrings.py <path-to-.xcstrings>

Example:
  python3 sync_xcstrings.py bitchat/Localization/Localizable.xcstrings

Dependencies: Python 3 standard library only (json, pathlib).
"""
import json
import sys
from pathlib import Path

def main(path: str) -> int:
    p = Path(path)
    if not p.exists():
        print(f"❌ File not found: {p}", file=sys.stderr)
        return 2
    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.get('strings', {})

    # Gather the union of locales present anywhere in the catalog
    all_locales = set()
    for entry in strings.values():
        all_locales.update((entry.get('localizations') or {}).keys())
    if 'en' not in all_locales:
        all_locales.add('en')

    added = 0
    touched_keys = 0
    for key, entry in strings.items():
        locs = entry.setdefault('localizations', {})
        base = (locs.get('en') or {}).get('stringUnit', {}).get('value')
        if not base:
            continue
        before = len(locs)
        for loc in all_locales:
            if loc not in locs:
                locs[loc] = { 'stringUnit': { 'state': 'translated', 'value': base } }
                added += 1
            else:
                su = locs[loc].setdefault('stringUnit', {})
                if not su.get('value'):
                    su['value'] = base
                    su['state'] = 'translated'
                    added += 1
        if len(locs) != before:
            touched_keys += 1

    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"✅ Filled {added} missing entries across {touched_keys} keys.")
    return 0

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('Usage: sync_xcstrings.py <path-to-.xcstrings>', file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))

