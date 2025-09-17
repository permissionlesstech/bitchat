#!/usr/bin/env bash

# add.sh — Add missing localization artifacts (comments, values)
#
# Usage:
#   ./scripts/localization/add.sh help
#   ./scripts/localization/add.sh comments [--dry-run]
#   ./scripts/localization/add.sh values [--dry-run]

set -euo pipefail
cmd=${1:-help}; shift || true
DRY=false

add_comments() {
  local args=""; [[ "$DRY" == true ]] && args="--dry-run"
  python3 scripts/localization/tools/helper_add_missing_comments.py bitchat/Localizable.xcstrings $args
  python3 scripts/localization/tools/helper_add_missing_comments.py bitchat/InfoPlist.xcstrings $args
}

add_values() {
  local args=""; [[ "$DRY" == true ]] && args="--dry-run"
  # Force-fill all locales with English values
  python3 scripts/localization/tools/helper_fill_with_english.py bitchat/Localizable.xcstrings $args
  python3 scripts/localization/tools/helper_fill_with_english.py bitchat/InfoPlist.xcstrings $args
}

case "$cmd" in
  help|-h|--help) sed -n '1,60p' "$0" | sed -n '1,30p';;
  comments) if [[ "${1:-}" == "--dry-run" || "${1:-}" == "--check" ]]; then DRY=true; fi; add_comments;;
  values) if [[ "${1:-}" == "--dry-run" || "${1:-}" == "--check" ]]; then DRY=true; fi; add_values;;
  *) echo "Unknown command: $cmd"; exit 2;;
esac
