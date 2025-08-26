#!/usr/bin/env python3
"""
audit_xcstrings.py — Heuristic audit of a .xcstrings catalog to flag likely wrong-locale strings.

Checks performed:
  1) Script mismatch: locale expects non-Latin script (e.g., Arabic, Cyrillic, Han), but value is Latin-only.
  2) Cross-language tokens: e.g., Spanish entries containing French-only tokens ("ajouter", "utilisation").
  3) Suspicious duplicates: exact same non-empty value across multiple Latin locales (e.g., es==fr).

Usage:
  python3 scripts/audit_xcstrings.py bitchat/Localization/Localizable.xcstrings
"""
import json
import sys
import re
from collections import defaultdict
from pathlib import Path

LATIN = re.compile(r"^[\s\d\W\w]*$", re.UNICODE)
ARABIC = re.compile(r"[\u0600-\u06FF]")
CYRILLIC = re.compile(r"[\u0400-\u04FF]")
DEVANAGARI = re.compile(r"[\u0900-\u097F]")
BENGALI = re.compile(r"[\u0980-\u09FF]")
TAMIL = re.compile(r"[\u0B80-\u0BFF]")
TELUGU = re.compile(r"[\u0C00-\u0C7F]")
HAN = re.compile(r"[\u4E00-\u9FFF]")
HIRAGANA = re.compile(r"[\u3040-\u309F]")
KATAKANA = re.compile(r"[\u30A0-\u30FF]")

expected_scripts = {
    # Non-Latin scripts we can reliably check
    'ar': ARABIC, 'ar-EG': ARABIC, 'arz': ARABIC, 'ur': ARABIC, 'pnb': ARABIC,
    'ru': CYRILLIC,
    'hi': DEVANAGARI, 'mr': DEVANAGARI,
    'bn': BENGALI,
    'ta': TAMIL,
    'te': TELUGU,
    'zh': HAN, 'zh-Hans': HAN, 'zh-Hant': HAN, 'zh-HK': HAN, 'yue': HAN, 'yue-Hant': HAN,
    'ja': None,  # special handling: Hiragana/Katakana or Han
}

token_lang = {
    'fr': { 'ajouter', 'retirer', 'utilisation', 'favoris', 'proche', 'réseau', 'sécurisé' },
    'es': { 'añadir', 'agregar', 'quitar', 'uso', 'favoritos', 'cercanos', 'red', 'segura' },
    'pt': { 'adicionar', 'remover', 'uso', 'favoritos', 'próximos', 'rede', 'segura' },
    'de': { 'hinzufügen', 'entfernen', 'nutzen', 'favoriten', 'sicheres', 'netzwerk' },
    'en': { 'add', 'remove', 'usage', 'favorites', 'nearby', 'secure', 'network' },
}

latin_locales = {
    'en','es','fr','pt','pt-BR','de','id','fil','tl','sw','tr','vi','ha','pcm'
}

def likely_japanese(s: str) -> bool:
    return bool(HAN.search(s) or HIRAGANA.search(s) or KATAKANA.search(s))

def is_latin_only(s: str) -> bool:
    # latin-only if it has no characters from known non-latin blocks
    return not (ARABIC.search(s) or CYRILLIC.search(s) or DEVANAGARI.search(s) or BENGALI.search(s)
                or TAMIL.search(s) or TELUGU.search(s) or HAN.search(s) or HIRAGANA.search(s) or KATAKANA.search(s))

def main(path: str) -> int:
    p = Path(path)
    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.get('strings', {})

    issues = []
    # Track duplicates by value across latin locales per key
    dupes = []

    for key, entry in strings.items():
        locs = entry.get('localizations', {})

        # 1) Script mismatch checks
        for loc, obj in locs.items():
            val = obj.get('stringUnit', {}).get('value', '') or ''
            v = val.strip()
            if not v:
                continue
            if loc in expected_scripts and expected_scripts[loc] is not None:
                pattern = expected_scripts[loc]
                if not pattern.search(v):
                    issues.append((key, loc, 'script-mismatch', v))
            if loc == 'ja' and not likely_japanese(v):
                issues.append((key, loc, 'script-mismatch', v))

        # 2) Cross-language token checks (only for latin locales)
        for loc, obj in locs.items():
            if loc not in latin_locales:
                continue
            val = obj.get('stringUnit', {}).get('value', '') or ''
            w = re.findall(r"[A-Za-zÀ-ÿ]+", val.lower())
            if not w:
                continue
            tokens = set(w)
            for other_lang, toks in token_lang.items():
                if other_lang == 'en' and loc == 'en':
                    continue
                if other_lang == 'fr' and loc == 'fr':
                    continue
                if other_lang == 'es' and loc == 'es':
                    continue
                if other_lang == 'pt' and loc in {'pt','pt-BR'}:
                    continue
                if other_lang == 'de' and loc == 'de':
                    continue
                if tokens & toks:
                    issues.append((key, loc, f"contains-{other_lang}-tokens", val))

        # 3) Suspicious duplicates among latin locales
        latin_values = {loc: entry.get('localizations', {}).get(loc, {}).get('stringUnit', {}).get('value', '').strip()
                        for loc in latin_locales if loc in locs}
        non_empty = {loc: v for loc, v in latin_values.items() if v}
        if non_empty:
            # group by value
            reverse = defaultdict(list)
            for loc, v in non_empty.items():
                reverse[v].append(loc)
            for v, lst in reverse.items():
                if len(lst) >= 3:
                    dupes.append((key, v, sorted(lst)))

    # Print concise report
    if issues:
        print("Suspicious entries (first 200):")
        for i, (k, loc, kind, v) in enumerate(issues[:200], 1):
            print(f"{i:3d}. [{loc}] {kind} | {k} = {v}")
        print(f"… total issues: {len(issues)}")
    else:
        print("No issues found by heuristics.")

    if dupes:
        print("\nHigh-duplicate Latin entries (value reused by 3+ locales):")
        for k, v, lst in dupes[:100]:
            print(f"- {k}: {v} -> {', '.join(lst)}")

    return 0

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('Usage: audit_xcstrings.py <path-to-.xcstrings>', file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))

