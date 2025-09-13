#!/usr/bin/env bash

# export.sh — Export .xcstrings to per-locale CSVs
#
# Usage:
#   ./scripts/localization/export.sh help
#   ./scripts/localization/export.sh all [--locales all|en,es,...] [--dry-run]
#
# Outputs to: scripts/localization/tmp/localizable/<locale>.csv and tmp/infoPlist/<locale>.csv

set -euo pipefail
cmd=${1:-help}; shift || true
DRY=false
LOCALES="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|--check) DRY=true; shift;;
    --locales) LOCALES="$2"; shift 2;;
    -h|--help) cmd=help; shift;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done

export_all() {
  # Determine locales
  python3 - << 'PY' > /tmp/_locs.txt
import json
d=json.load(open('bitchat/Localizable.xcstrings','r',encoding='utf-8'))
langs=set()
for v in d.get('strings',{}).values():
    langs.update((v.get('localizations') or {}).keys())
print(','.join(sorted(langs)))
PY
  ALL_LOCS=$(cat /tmp/_locs.txt)
  IFS=',' read -ra ALL <<< "$ALL_LOCS"
  if [[ "$LOCALES" == "all" ]]; then
    TARGETS=("${ALL[@]}")
  else
    IFS=',' read -ra TARGETS <<< "$LOCALES"
  fi
  mkdir -p scripts/localization/tmp/localizable scripts/localization/tmp/infoPlist
  for loc in "${TARGETS[@]}"; do
    echo "📤 Exporting $loc (localizable)"
    python3 scripts/localization/tools/helper_export_csv.py bitchat/Localizable.xcstrings "$loc"
    echo "📤 Exporting $loc (infoPlist)"
    python3 scripts/localization/tools/helper_export_csv.py bitchat/InfoPlist.xcstrings "$loc"
  done
  echo "✅ Export complete. CSVs in scripts/localization/tmp/{localizable,infoPlist}/<locale>.csv"
}

case "$cmd" in
  help|-h|--help) sed -n '1,60p' "$0" | sed -n '1,30p';;
  all) export_all;;
  *) echo "Unknown command: $cmd"; exit 2;;
esac

