#!/usr/bin/env bash

# sync_comments.sh — Ensure all .xcstrings entries have concise developer comments
#
# Usage:
#   ./scripts/localization/sync_comments.sh [--dry-run]
#
# Behavior:
# - Adds entry-level comments for any keys missing them in both catalogs:
#   Localizable.xcstrings and Infoplist.xcstrings.
# - With --dry-run, prints planned changes without writing files.

set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run|--check) DRY_RUN=true ;;
    -h|--help) echo "Usage: $0 [--dry-run]"; exit 0 ;;
    *) echo "Unknown argument: $arg"; exit 2 ;;
  esac
done

run() {
  echo "$*"
  if [[ "$DRY_RUN" == false ]]; then
    eval "$@"
  fi
}

echo "📝 Syncing developer comments in String Catalogs..."

CATALOGS=(
  "bitchat/Localizable.xcstrings"
  "bitchat/Infoplist.xcstrings"
)

for file in "${CATALOGS[@]}"; do
  if [[ -f "$file" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      python3 scripts/localization/add_missing_comments.py "$file" --dry-run
    else
      python3 scripts/localization/add_missing_comments.py "$file"
    fi
  else
    echo "⚠️  Missing catalog: $file"
  fi
done

echo "✅ Comment sync complete${DRY_RUN:+ (dry-run)}."
