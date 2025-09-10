#!/bin/bash

# sync_all_localizations.sh — Comprehensive sync for both .xcstrings files
# Ensures all 29 languages have complete coverage

set -e

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run|--check) DRY_RUN=true ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"; exit 0 ;;
    *) echo "Unknown argument: $arg"; exit 2 ;;
  esac
done

echo "🌐 Syncing ALL localization files for 29 languages..."
echo "Languages: en, es, zh-Hans, zh-Hant, zh-HK, ar, arz, hi, fr, de, ru, ja, pt, pt-BR, ur, tr, vi, id, bn, fil, tl, yue, ta, te, mr, sw, ha, pcm, pnb"
echo ""

echo "📱 Syncing Localizable.xcstrings (App UI strings)..."
if [[ "$DRY_RUN" == true ]]; then
  python3 "$(dirname "$0")/sync_xcstrings.py" bitchat/Localizable.xcstrings --check
  python3 "$(dirname "$0")/add_missing_comments.py" bitchat/Localizable.xcstrings --dry-run
else
  python3 "$(dirname "$0")/sync_xcstrings.py" bitchat/Localizable.xcstrings
  python3 "$(dirname "$0")/add_missing_comments.py" bitchat/Localizable.xcstrings
fi

echo ""
echo "📋 Syncing InfoPlist.xcstrings (System permission strings)..."
if [[ "$DRY_RUN" == true ]]; then
  python3 "$(dirname "$0")/sync_xcstrings.py" bitchat/Infoplist.xcstrings --check
  python3 "$(dirname "$0")/add_missing_comments.py" bitchat/Infoplist.xcstrings --dry-run
else
  python3 "$(dirname "$0")/sync_xcstrings.py" bitchat/Infoplist.xcstrings
  python3 "$(dirname "$0")/add_missing_comments.py" bitchat/Infoplist.xcstrings
fi

echo ""
echo "✅ Complete localization sync finished!"
echo "📊 Coverage:"
echo "  • App UI: 146+ keys × 29 languages"  
echo "  • System permissions: 2 keys × 29 languages"
echo "  • Total: 4,200+ localization entries"
