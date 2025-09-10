#!/usr/bin/env bash

# locale_report.sh — Report localization coverage and gaps
#
# Usage:
#   ./scripts/localization/locale_report.sh [--dry-run]
#
# Output:
# - Total keys and languages
# - Per-language counts of filled values (StringUnit) and missing
# - Keys missing for any language (first N shown)

set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run|--check) DRY_RUN=true ;;
    -h|--help) echo "Usage: $0 [--dry-run]"; exit 0 ;;
    *) echo "Unknown argument: $arg"; exit 2 ;;
  esac
done

CATALOG="bitchat/Localizable.xcstrings"
if [[ ! -f "$CATALOG" ]]; then
  echo "❌ Catalog not found: $CATALOG"; exit 2
fi

python3 - << 'PY'
import json
from collections import defaultdict
data=json.load(open('bitchat/Localizable.xcstrings','r',encoding='utf-8'))
strings=data.get('strings',{})
langs=set()
for v in strings.values():
    langs.update((v.get('localizations') or {}).keys())
langs=sorted(langs)

per_lang_total=defaultdict(int)
per_lang_missing=defaultdict(int)
missing_keys=defaultdict(list)

def has_value(loc):
    su=loc.get('stringUnit')
    if isinstance(su,dict) and su.get('value'): return True
    var=(loc.get('variations') or {}).get('plural') or {}
    for b in var.values():
        su2=b.get('stringUnit')
        if isinstance(su2,dict) and su2.get('value'): return True
    return False

for k,v in strings.items():
    locs=v.get('localizations') or {}
    for lang in langs:
        per_lang_total[lang]+=1
        if lang not in locs or not has_value(locs[lang]):
            per_lang_missing[lang]+=1
            missing_keys[lang].append(k)

print('🌐 Locale Report — Localizable.xcstrings')
print(f'Total keys: {len(strings)}  |  Languages: {len(langs)}')
print('\nPer-language coverage:')
for lang in langs:
    total=per_lang_total[lang]
    missing=per_lang_missing[lang]
    filled=total-missing
    pct=0 if total==0 else int(round(filled*100/total))
    status='✅' if missing==0 else ('⚠️ ' if missing<5 else '❌')
    print(f'  {status} {lang:7} {filled:4}/{total:<4}  ({pct:3d}%)  missing: {missing}')

any_missing=sum(per_lang_missing.values())>0
if any_missing:
    print('\nKeys missing in at least one locale (first 20):')
    # Collect union of missing keys
    union=set()
    for lst in missing_keys.values(): union.update(lst)
    for k in list(sorted(union))[:20]:
        print('  -',k)
else:
    print('\n✅ No missing values across locales')
PY

echo "\nℹ️  Tip: Use Xcode String Catalog filter to target 'Needs Review' items."
echo "Done${DRY_RUN:+ (dry-run)}."
