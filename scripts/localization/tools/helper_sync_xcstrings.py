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

def main(path: str, check: bool = False) -> int:
    p = Path(path)
    if not p.exists():
        print(f"❌ File not found: {p}", file=sys.stderr)
        return 2
    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.get('strings', {})

    # Define all 29 supported languages from the comprehensive localization setup
    all_locales = {
        'en',      # English (base)
        'ar',      # Arabic
        'arz',     # Egyptian Arabic
        'bn',      # Bengali
        'de',      # German
        'es',      # Spanish
        'fil',     # Filipino
        'fr',      # French
        'ha',      # Hausa
        'hi',      # Hindi
        'id',      # Indonesian
        'it',      # Italian
        'ja',      # Japanese
        'mr',      # Marathi
        'pcm',     # Nigerian Pidgin
        'pnb',     # Punjabi
        'pt',      # Portuguese
        'pt-BR',   # Brazilian Portuguese
        'ru',      # Russian
        'sw',      # Swahili
        'ta',      # Tamil
        'te',      # Telugu
        'tl',      # Tagalog
        'tr',      # Turkish
        'ur',      # Urdu
        'vi',      # Vietnamese
        'yue',     # Cantonese
        'zh-Hans', # Chinese Simplified
        'zh-Hant', # Chinese Traditional
        'zh-HK'    # Chinese Hong Kong
    }
    
    # Also include any existing locales that might be in the file
    for entry in strings.values():
        all_locales.update((entry.get('localizations') or {}).keys())

    added = 0
    retagged = 0
    touched_keys = 0
    for key, entry in strings.items():
        locs = entry.setdefault('localizations', {})
        base = (locs.get('en') or {}).get('stringUnit', {}).get('value')
        en_variations = ((locs.get('en') or {}).get('variations') or {}).get('plural') or None
        if not base and not en_variations:
            continue
        before = len(locs)
        for loc in all_locales:
            if loc not in locs:
                if base:
                    state = 'translated' if loc == 'en' else 'needs_review'
                    locs[loc] = { 'stringUnit': { 'state': state, 'value': base } }
                    added += 1
                elif en_variations:
                    # Seed plural variations for missing locale by copying English
                    seeded = { 'plural': {} }
                    for cat, branch in en_variations.items():
                        val = ((branch or {}).get('stringUnit') or {}).get('value')
                        if val is None:
                            continue
                        seeded['plural'][cat] = { 'stringUnit': { 'state': 'translated' if loc=='en' else 'needs_review', 'value': val } }
                    if seeded['plural']:
                        locs[loc] = { 'variations': seeded }
                        added += 1
            else:
                su = locs[loc].setdefault('stringUnit', {})
                if base and not su.get('value'):
                    su['value'] = base
                    su['state'] = 'translated' if loc == 'en' else 'needs_review'
                    added += 1
                elif en_variations:
                    # Ensure plural variations exist
                    var = locs[loc].setdefault('variations', {})
                    plural = var.setdefault('plural', {})
                    changed=False
                    for cat, branch in en_variations.items():
                        if cat not in plural:
                            val = ((branch or {}).get('stringUnit') or {}).get('value')
                            if val is None:
                                continue
                            plural[cat] = { 'stringUnit': { 'state': 'translated' if loc=='en' else 'needs_review', 'value': val } }
                            changed=True
                    if changed:
                        added += 1
                else:
                    # If non-English matches base and previously marked translated, mark as needs_review
                    if base and loc != 'en' and su.get('value') == base and su.get('state') in (None, 'translated'):
                        su['state'] = 'needs_review'
                        retagged += 1
        if len(locs) != before:
            touched_keys += 1

    if not check:
        p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"{'[DRY-RUN] ' if check else ''}✅ Filled {added} missing entries; marked {retagged} entries as needs_review across {touched_keys} keys.")
    return 0

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: sync_xcstrings.py <path-to-.xcstrings> [--check]', file=sys.stderr)
        raise SystemExit(2)
    path = None
    check = False
    for arg in sys.argv[1:]:
        if arg == '--check' or arg == '--dry-run':
            check = True
        else:
            path = arg
    if not path:
        print('Usage: sync_xcstrings.py <path-to-.xcstrings> [--check]', file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(path, check))
