#!/usr/bin/env bash

# sync.sh — Sync String Catalogs and comments
#
# Usage:
#   ./scripts/localization/sync.sh help
#   ./scripts/localization/sync.sh all [--dry-run]

set -euo pipefail

cmd=${1:-help}; shift || true
DRY=false

sync_all() {
  local args=""; [[ "$DRY" == true ]] && args="--check"
  echo "📱 Syncing Localizable.xcstrings...${DRY:+ (dry-run)}"
  python3 scripts/localization/tools/helper_sync_xcstrings.py bitchat/Localizable.xcstrings $args
  echo "📋 Syncing InfoPlist.xcstrings...${DRY:+ (dry-run)}"
  python3 scripts/localization/tools/helper_sync_xcstrings.py bitchat/InfoPlist.xcstrings $args
  echo "📝 Ensuring developer comments...${DRY:+ (dry-run)}"
  local addargs=""; [[ "$DRY" == true ]] && addargs="--dry-run"
  python3 scripts/localization/tools/helper_add_missing_comments.py bitchat/Localizable.xcstrings $addargs
  python3 scripts/localization/tools/helper_add_missing_comments.py bitchat/InfoPlist.xcstrings $addargs
  echo "✅ Sync complete${DRY:+ (dry-run)}."
}

case "$cmd" in
  help|-h|--help) sed -n '1,40p' "$0" | sed -n '1,20p';;
  all) if [[ "${1:-}" == "--dry-run" || "${1:-}" == "--check" ]]; then DRY=true; fi; sync_all;;
  *) echo "Unknown command: $cmd"; exit 2;;
esac
