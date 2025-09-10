#!/usr/bin/env bash

# translate.sh — Translate per-locale CSVs in batches, validate, and (optionally) apply
#
# Usage:
#   ./scripts/localization/translate.sh help
#   ./scripts/localization/translate.sh batch --provider deepl --locales es,fr,de,pt-BR,ja [--apply]

set -euo pipefail

cmd=${1:-help}; shift || true
PROVIDER="deepl"
LOCALES=""
APPLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2;;
    --locales) LOCALES="$2"; shift 2;;
    --apply) APPLY=true; shift;;
    -h|--help) cmd=help; shift;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done

ROOT="scripts/localization/tmp"

declare -a BATCH

translate_locale() {
  local loc="$1"
  echo "🌍 Translating $loc..."
  # Localizable
  python3 scripts/localization/tools/helper_translate_csv.py --provider "$PROVIDER" --target "$loc" \
    --in "$ROOT/localizable/$loc.csv" --out "$ROOT/localizable/$loc-translated.csv"
  python3 scripts/localization/tools/helper_check_placeholders.py "$ROOT/localizable/$loc-translated.csv"
  # InfoPlist
  python3 scripts/localization/tools/helper_translate_csv.py --provider "$PROVIDER" --target "$loc" \
    --in "$ROOT/infoplist/$loc.csv" --out "$ROOT/infoplist/$loc-translated.csv"
  python3 scripts/localization/tools/helper_check_placeholders.py "$ROOT/infoplist/$loc-translated.csv"
}

dry_import_and_validate() {
  local loc="$1"
  echo "🧪 Dry-import + validate for $loc"
  ./scripts/localization/import.sh localizable "$loc" --file "$ROOT/localizable/$loc-translated.csv" --dry-run
  ./scripts/localization/import.sh infoplist  "$loc" --file "$ROOT/infoplist/$loc-translated.csv" --dry-run
  ./scripts/localization/validate.sh build
}

apply_import() {
  local loc="$1"
  echo "✅ Applying import for $loc"
  # Force needs_review status
  python3 scripts/localization/tools/helper_import_csv.py bitchat/Localizable.xcstrings "$loc" "$ROOT/localizable/$loc-translated.csv" --force-status needs_review
  python3 scripts/localization/tools/helper_import_csv.py bitchat/Infoplist.xcstrings  "$loc" "$ROOT/infoplist/$loc-translated.csv" --force-status needs_review
  ./scripts/localization/validate.sh build
}

case "$cmd" in
  help|-h|--help)
    sed -n '1,80p' "$0" | sed -n '1,40p';;
  batch)
    IFS=',' read -ra LCS <<< "$LOCALES"
    if [[ ${#LCS[@]} -eq 0 ]]; then echo "❌ No locales specified"; exit 2; fi
    for loc in "${LCS[@]}"; do
      translate_locale "$loc"
      dry_import_and_validate "$loc"
      if [[ "$APPLY" == true ]]; then
        apply_import "$loc"
      fi
    done
    ;;
  *) echo "Unknown command: $cmd"; exit 2;;
esac
