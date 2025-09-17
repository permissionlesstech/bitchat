#!/bin/bash

# reset.sh — Reset all localization values to English and mark as needs translation
# 
# This script resets all non-English localizations to English values and marks them
# as 'needs_review' to indicate they need proper translation. Useful for:
# - Starting fresh translation workflow
# - Resetting after major content changes
# - Preparing for professional translation services
#
# Usage:
#   ./scripts/localization/reset.sh [--dry-run] [--localizable-only] [--infoPlist-only]
#
# Options:
#   --dry-run        Show what would be changed without making changes
#   --localizable-only   Reset only Localizable.xcstrings (app UI)
#   --infoPlist-only     Reset only InfoPlist.xcstrings (system permissions)
#   --help               Show this help message

set -e

DRY_RUN=false
LOCALIZABLE_ONLY=false
INFOPLIST_ONLY=false

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --dry-run|--check)
      DRY_RUN=true ;;
    --localizable-only)
      LOCALIZABLE_ONLY=true ;;
    --infoPlist-only)  
      INFOPLIST_ONLY=true ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--localizable-only] [--infoPlist-only]"
      echo ""
      echo "Reset all localization values to English and mark as needs translation"
      echo ""
      echo "Options:"
      echo "  --dry-run           Show changes without applying them"
      echo "  --localizable-only  Reset only app UI strings"
      echo "  --infoPlist-only    Reset only system permission strings"
      echo "  --help              Show this help"
      exit 0 ;;
    *)
      echo "Unknown argument: $arg"
      echo "Use --help for usage information"
      exit 2 ;;
  esac
done

echo "🔄 LOCALIZATION RESET UTILITY"
echo "=============================="
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo "🔍 DRY RUN MODE - No changes will be made"
    echo ""
fi

# Determine which files to process
FILES_TO_RESET=()

if [[ "$LOCALIZABLE_ONLY" == true ]]; then
    FILES_TO_RESET=("bitchat/Localizable.xcstrings")
    echo "📱 Resetting: App UI strings only"
elif [[ "$INFOPLIST_ONLY" == true ]]; then
    FILES_TO_RESET=("bitchat/InfoPlist.xcstrings") 
    echo "📋 Resetting: System permission strings only"
else
    FILES_TO_RESET=("bitchat/Localizable.xcstrings" "bitchat/InfoPlist.xcstrings")
    echo "🔄 Resetting: Both app UI and system permission strings"
fi

echo "Languages: en, es, zh-Hans, zh-Hant, zh-HK, ar, arz, hi, fr, de, ru, ja, pt, pt-BR, ur, tr, vi, id, bn, fil, tl, yue, ta, te, mr, sw, ha, pcm, pnb"
echo ""

# Process each file
for FILE_PATH in "${FILES_TO_RESET[@]}"; do
    if [[ ! -f "$FILE_PATH" ]]; then
        echo "⚠️  File not found: $FILE_PATH"
        continue
    fi
    
    echo "Processing: $FILE_PATH"
    
    # Use Python to reset all non-English entries
    python3 - "$FILE_PATH" "$DRY_RUN" << 'EOF'
import json
import sys

file_path = sys.argv[1] 
dry_run = sys.argv[2] == 'True'

# Load the xcstrings file
with open(file_path, 'r') as f:
    data = json.load(f)

strings = data.get('strings', {})
total_keys = len(strings)
total_reset = 0
total_entries = 0

print(f"  📊 Processing {total_keys} keys...")

for key, entry in strings.items():
    localizations = entry.get('localizations', {})
    
    # Get English baseline value(s)
    en_data = localizations.get('en', {})
    en_string_unit = en_data.get('stringUnit', {})
    en_value = en_string_unit.get('value')
    en_variations = en_data.get('variations', {})
    
    reset_count = 0
    
    # Reset all non-English languages
    for locale, loc_data in localizations.items():
        if locale == 'en':
            continue  # Skip English - it stays as is
            
        total_entries += 1
        
        # Handle regular string units
        if en_value:
            loc_data['stringUnit'] = {
                'state': 'needs_review',
                'value': en_value
            }
            reset_count += 1
        
        # Handle plural variations if they exist
        elif en_variations:
            if 'plural' in en_variations:
                loc_data['variations'] = {
                    'plural': {}
                }
                for category, en_plural_data in en_variations['plural'].items():
                    en_plural_value = en_plural_data.get('stringUnit', {}).get('value')
                    if en_plural_value:
                        loc_data['variations']['plural'][category] = {
                            'stringUnit': {
                                'state': 'needs_review', 
                                'value': en_plural_value
                            }
                        }
                reset_count += 1
    
    if reset_count > 0:
        total_reset += reset_count

print(f"  📊 Reset {total_reset} localizations across {total_keys} keys")
print(f"  📊 Total entries processed: {total_entries}")

if not dry_run:
    # Save the updated file
    with open(file_path, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
    print(f"  ✅ Saved changes to {file_path}")
else:
    print(f"  🔍 DRY RUN - No changes saved")

EOF
    
    echo ""
done

echo "📋 RESET SUMMARY:"
echo "=================="

if [[ "$DRY_RUN" == true ]]; then
    echo "🔍 DRY RUN completed - no changes made"
else
    echo "✅ Reset completed successfully"
fi

echo ""
echo "📝 Next Steps:"
echo "1. Review the reset in Xcode String Catalog editor"
echo "2. Send .xcstrings files to translators"
echo "3. Import completed translations"
echo "4. Run: just sync-all to ensure consistency"
echo ""
echo "💡 Translation Workflow Tips:"
echo "• Translators should look for 'needs_review' state in Xcode"
echo "• All entries now have English values as reference"
echo "• Comments provide context for proper translation"
echo "• Reserved terms (#mesh, BitChat, Nostr) should stay unchanged"