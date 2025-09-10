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
        if not base:
            continue
        before = len(locs)
        for loc in all_locales:
            if loc not in locs:
                # New locale: English marked translated; others need review
                state = 'translated' if loc == 'en' else 'needs_review'
                locs[loc] = { 'stringUnit': { 'state': state, 'value': base } }
                added += 1
            else:
                su = locs[loc].setdefault('stringUnit', {})
                if not su.get('value'):
                    su['value'] = base
                    su['state'] = 'translated' if loc == 'en' else 'needs_review'
                    added += 1
                else:
                    # If non-English matches base and previously marked translated, mark as needs_review
                    if loc != 'en' and su.get('value') == base and su.get('state') in (None, 'translated'):
                        su['state'] = 'needs_review'
                        retagged += 1
        if len(locs) != before:
            touched_keys += 1

    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"✅ Filled {added} missing entries; marked {retagged} entries as needs_review across {touched_keys} keys.")
    return 0

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('Usage: sync_xcstrings.py <path-to-.xcstrings>', file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
