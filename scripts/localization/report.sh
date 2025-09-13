#!/usr/bin/env bash

# report.sh — Localization coverage report
#
# Usage:
#   ./scripts/localization/report.sh help
#   ./scripts/localization/report.sh locales [--dry-run]
#   ./scripts/localization/report.sh locale <code> [--dry-run]

set -euo pipefail
cmd=${1:-help}; shift || true

report_all() {
python3 - << 'PY'
import json
from collections import defaultdict
d=json.load(open('bitchat/Localizable.xcstrings','r',encoding='utf-8'))
strings=d.get('strings',{})
langs=set()
for v in strings.values():
    langs.update((v.get('localizations') or {}).keys())
langs=sorted(langs)
per_lang_total=defaultdict(int); per_lang_missing=defaultdict(int)
def has_value(loc):
    su=loc.get('stringUnit');
    if isinstance(su,dict) and su.get('value'): return True
    var=(loc.get('variations') or {}).get('plural') or {}
    return any((b.get('stringUnit') or {}).get('value') for b in var.values())
for k,v in strings.items():
    locs=v.get('localizations') or {}
    for lang in langs:
        per_lang_total[lang]+=1
        if lang not in locs or not has_value(locs[lang]): per_lang_missing[lang]+=1
print('🌐 Locale Report — Localizable.xcstrings')
print(f'Total keys: {len(strings)}  |  Languages: {len(langs)}')
print('\nPer-language coverage:')
for lang in langs:
    total=per_lang_total[lang]; missing=per_lang_missing[lang]; filled=total-missing
    pct=0 if total==0 else int(round(filled*100/total))
    status='✅' if missing==0 else ('⚠️ ' if missing<5 else '❌')
    print(f'  {status} {lang:7} {filled:4}/{total:<4}  ({pct:3d}%)  missing: {missing}')
print('\nTip: Filter “Needs Review” in Xcode String Catalog.')
PY
}

report_locale() {
  local code="$1"
python3 - << PY
import json,sys
code=sys.argv[1]
d=json.load(open('bitchat/Localizable.xcstrings','r',encoding='utf-8'))
strings=d.get('strings',{})
missing=[]
def has_value(loc):
    su=loc.get('stringUnit');
    if isinstance(su,dict) and su.get('value'): return True
    var=(loc.get('variations') or {}).get('plural') or {}
    return any((b.get('stringUnit') or {}).get('value') for b in var.values())
for k,v in strings.items():
    loc=v.get('localizations',{}).get(code)
    if not loc or not has_value(loc): missing.append(k)
print(f'📄 Missing in {code}: {len(missing)} keys')
for k in missing[:50]: print('  -',k)
PY
}

case "$cmd" in
  help|-h|--help) sed -n '1,40p' "$0" | sed -n '1,30p';;
  locales) report_all;;
  locale) report_locale "${1:-en}";;
  *) echo "Unknown command: $cmd"; exit 2;;
esac

