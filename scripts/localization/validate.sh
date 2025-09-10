#!/usr/bin/env bash

# validate.sh — Validate localization build and catalog integrity
#
# Usage:
#   ./scripts/localization/validate.sh help
#   ./scripts/localization/validate.sh build [--dry-run]

set -euo pipefail

cmd=${1:-help}; shift || true
DRY=false

build() {
  echo "🔍 Validating localization compliance...${DRY:+ (dry-run)}"
  # Hardcoded strings scan limited to Views and ViewModels
  local violations=0
  local patterns=(
    'Text\s*\(\s*"[A-Za-z][^"]*"'
    'Button\s*\(\s*"[A-Za-z][^"]*"'
    'TextField\s*\(\s*"[A-Za-z][^"]*"'
    'Alert\s*\(\s*"[A-Za-z][^"]*"'
    'Label\s*\(\s*"[A-Za-z][^"]*"'
    '\\.accessibility(Label|Hint)\s*\(\s*"[A-Za-z][^"]*"'
  )
  for pat in "${patterns[@]}"; do
    if rg -n -e "$pat" bitchat/Views bitchat/ViewModels | rg -v 'String\(localized:|LocalizedStringKey' >/tmp/loc_hardcoded.txt 2>/dev/null; then
      echo "❌ Hardcoded strings found:"; cat /tmp/loc_hardcoded.txt; violations=1
    fi
  done
  if [[ $violations -eq 0 ]]; then echo "✅ No localization violations found"; fi
  # Validate catalogs
  python3 - << 'PY'
import json,sys
for p in ('bitchat/Localizable.xcstrings','bitchat/Infoplist.xcstrings'):
  try:
    d=json.load(open(p,'r',encoding='utf-8'))
    strings=d.get('strings',{})
    langs=set()
    for v in strings.values():
      langs.update((v.get('localizations') or {}).keys())
    if not strings: print(f'❌ {p}: no strings'); sys.exit(1)
    if len(langs)<29 and p.endswith('Localizable.xcstrings'):
      print(f'❌ {p}: expected 29 languages, found {len(langs)}'); sys.exit(1)
    # Comments check
    missing=[k for k,v in strings.items() if not isinstance(v.get('comment'),str) or not v['comment'].strip()]
    if missing:
      print(f'❌ {p}: {len(missing)} keys missing comments'); sys.exit(1)
    print(f'✅ {p}: {len(strings)} keys, {len(langs)} langs OK')
  except Exception as e:
    print(f'❌ {p}: {e}'); sys.exit(1)
print('✅ Catalog validation passed')
PY
}

case "$cmd" in
  help|-h|--help) sed -n '1,40p' "$0" | sed -n '1,20p';;
  build) if [[ "${1:-}" == "--dry-run" || "${1:-}" == "--check" ]]; then DRY=true; fi; build;;
  *) echo "Unknown command: $cmd"; exit 2;;
esac

