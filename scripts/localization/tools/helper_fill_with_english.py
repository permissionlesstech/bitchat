#!/usr/bin/env python3
"""
helper_fill_with_english.py — Force-fill all locales with the English value.

Usage:
  python3 helper_fill_with_english.py <path-to-.xcstrings> [--dry-run]

Behavior:
  - For every key, copies English value (or plural variations) to all locales.
  - Sets state to 'translated' for all locales (including English).
  - Preserves keys and comments; preserves placeholders as-is.
  - With --dry-run, prints counts without writing.
"""
import json
import sys
from pathlib import Path

def main(path: str, dry: bool=False) -> int:
    p = Path(path)
    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.get('strings', {})
    # Collect all locales seen
    locales = set()
    for v in strings.values():
        locales.update((v.get('localizations') or {}).keys())
    changed = 0
    keys = 0
    for key, entry in strings.items():
        keys += 1
        locs = entry.setdefault('localizations', {})
        en = locs.get('en') or {}
        en_val = (en.get('stringUnit') or {}).get('value')
        en_plural = ((en.get('variations') or {}).get('plural') or None)
        if not en_val and not en_plural:
            continue
        for loc in locales:
            if en_val:
                su = locs.setdefault(loc, {}).setdefault('stringUnit', {})
                if su.get('value') != en_val or su.get('state') != 'translated':
                    su['value'] = en_val
                    su['state'] = 'translated'
                    changed += 1
            if en_plural:
                var = locs.setdefault(loc, {}).setdefault('variations', {})
                plural = var.setdefault('plural', {})
                for cat, branch in en_plural.items():
                    en_b_val = ((branch or {}).get('stringUnit') or {}).get('value')
                    if en_b_val is None:
                        continue
                    b = plural.setdefault(cat, {}).setdefault('stringUnit', {})
                    if b.get('value') != en_b_val or b.get('state') != 'translated':
                        b['value'] = en_b_val
                        b['state'] = 'translated'
                        changed += 1
    if not dry:
        p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"{'[DRY-RUN] ' if dry else ''}✅ Updated {changed} locale entries across {keys} keys in {p}")
    return 0

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: helper_fill_with_english.py <path-to-.xcstrings> [--dry-run]')
        raise SystemExit(2)
    path=None; dry=False
    for a in sys.argv[1:]:
        if a in ('--dry-run','--check'): dry=True
        else: path=a
    raise SystemExit(main(path, dry))

