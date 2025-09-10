#!/usr/bin/env bash

# import.sh — Import translated per-locale CSVs back into catalogs
#
# Usage:
#   ./scripts/localization/import.sh help
#   ./scripts/localization/import.sh localizable <locale> [--file path] [--dry-run]
#   ./scripts/localization/import.sh infoplist  <locale> [--file path] [--dry-run]

set -euo pipefail
cmd=${1:-help}; shift || true

catalog_import() {
  local CAT="$1"; shift
  local LOC="$1"; shift
  local DRY=false FILE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run|--check) DRY=true; shift;;
      --file) FILE="$2"; shift 2;;
      -h|--help) echo "Usage: $0 $CAT <locale> [--file path] [--dry-run]"; return 0;;
      *) echo "Unknown arg: $1"; return 2;;
    esac
  done
  local CATFILE="bitchat/Localizable.xcstrings"
  local DIR="scripts/localization/tmp/localizable"
  if [[ "$CAT" == "infoplist" ]]; then
    CATFILE="bitchat/Infoplist.xcstrings"; DIR="scripts/localization/tmp/infoplist"
  fi
  if [[ -z "$FILE" ]]; then
    FILE="$DIR/${LOC}-translated.csv"
  fi
  [[ -f "$FILE" ]] || { echo "❌ CSV not found: $FILE"; return 2; }
  # Validate placeholders before import
  python3 scripts/localization/tools/helper_check_placeholders.py "$FILE"
  python3 scripts/localization/tools/helper_import_csv.py "$CATFILE" "$LOC" "$FILE" $([[ "$DRY" == true ]] && echo --dry-run || true)
}

case "$cmd" in
  help|-h|--help) sed -n '1,80p' "$0" | sed -n '1,40p';;
  localizable) catalog_import localizable "$@";;
  infoplist)  catalog_import infoplist  "$@";;
  *) echo "Unknown command: $cmd"; exit 2;;
esac
