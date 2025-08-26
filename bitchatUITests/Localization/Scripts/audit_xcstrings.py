#!/usr/bin/env python3
"""
audit_xcstrings.py — Heuristic audit of a .xcstrings catalog to flag likely wrong-locale strings.

Purpose:
  Scans the JSON-based .xcstrings file and prints suspicious entries, such as
  script mismatches for non‑Latin locales and cross-language tokens inside
  Latin locales (e.g., French words in Spanish entries).

Usage:
  ./bitchatUITests/Localization/Scripts/audit_xcstrings.py bitchat/Localization/Localizable.xcstrings

Examples:
  - Basic audit:
      python3 audit_xcstrings.py path/to/Localizable.xcstrings

Dependencies: Python 3 standard library only (json, re, pathlib).
"""
import sys, json, re
from pathlib import Path

def main(path: str) -> int:
    p = Path(path)
    if not p.exists():
        print(f"❌ File not found: {p}", file=sys.stderr)
        return 2
    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.get('strings', {})

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
        'ar': ARABIC, 'ar-EG': ARABIC, 'arz': ARABIC, 'ur': ARABIC, 'pnb': ARABIC,
        'ru': CYRILLIC,
        'hi': DEVANAGARI, 'mr': DEVANAGARI,
        'bn': BENGALI,
        'ta': TAMIL,
        'te': TELUGU,
    }

    token_lang = {
        'fr': { 'ajouter', 'retirer', 'utilisation', 'favoris', 'réseau', 'sécurisé' },
        'es': { 'añadir', 'agregar', 'quitar', 'uso', 'favoritos', 'cercanos', 'red', 'segura' },
        'pt': { 'adicionar', 'remover', 'uso', 'favoritos', 'próximos', 'rede', 'segura' },
        'de': { 'hinzufügen', 'entfernen', 'nutzen', 'favoriten', 'sicheres', 'netzwerk' },
        'en': { 'add', 'remove', 'usage', 'favorites', 'nearby', 'secure', 'network' },
    }

    issues = []
    latin_locales = {'en','es','fr','pt','pt-BR','de','id','fil','tl','sw','tr','vi','ha','pcm'}

    def likely_japanese(s: str) -> bool:
        return bool(HAN.search(s) or HIRAGANA.search(s) or KATAKANA.search(s))

    for key, entry in strings.items():
        locs = entry.get('localizations', {})
        for loc, obj in locs.items():
            val = (obj.get('stringUnit', {}) or {}).get('value', '') or ''
            v = val.strip()
            if not v:
                continue
            # script mismatch
            if loc in expected_scripts:
                if not expected_scripts[loc].search(v):
                    issues.append((key, loc, 'script-mismatch', v))
            if loc == 'ja' and v and not likely_japanese(v):
                issues.append((key, loc, 'script-mismatch', v))
            # cross-language token hints for Latin locales
            if loc in latin_locales:
                words = re.findall(r"[A-Za-zÀ-ÿ]+", v.lower())
                if words:
                    tokens = set(words)
                    for lang, toks in token_lang.items():
                        if (lang == 'pt' and loc in {'pt','pt-BR'}) or (lang == loc):
                            continue
                        if tokens & toks:
                            issues.append((key, loc, f"contains-{lang}-tokens", v))

    if issues:
        print("Suspicious entries (first 200):")
        for i,(k,loc,kind,v) in enumerate(issues[:200],1):
            print(f"{i:3d}. [{loc}] {kind} | {k} = {v}")
        print(f"… total issues: {len(issues)}")
    else:
        print("✅ No issues found by heuristics.")
    return 0

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: audit_xcstrings.py <path-to-.xcstrings>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))

