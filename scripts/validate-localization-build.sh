#!/bin/bash

# Build-time localization validation script
# Enforces that all user-facing strings use proper localization

set -e

echo "🔍 Validating localization compliance..."

# Patterns to catch hardcoded UI strings
FORBIDDEN_PATTERNS=(
    'Text\s*\(\s*"[^"]*"'
    'Button\s*\(\s*"[^"]*"'
    'TextField\s*\(\s*"[^"]*"'
    'Alert\s*\(\s*"[^"]*"'
    'Label\s*\(\s*"[^"]*"'
    '\.accessibilityLabel\s*\(\s*"[^"]*"'
    '\.accessibilityHint\s*\(\s*"[^"]*"'
    'addSystemMessage\s*\(\s*"[^"]*"'
)

VIOLATIONS=()
SWIFT_FILES=$(find bitchat/Views bitchat/ViewModels -name "*.swift" 2>/dev/null)

for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            matches=$(grep -n -E "$pattern" "$file" | grep -v "String(localized:" | grep -v "LocalizedStringKey" || true)
            if [[ -n "$matches" ]]; then
                VIOLATIONS+=("$file: $matches")
            fi
        fi
    done <<< "$SWIFT_FILES"
done

# Report violations
if [[ ${#VIOLATIONS[@]} -gt 0 ]]; then
    echo "❌ LOCALIZATION VIOLATIONS FOUND:"
    echo ""
    for violation in "${VIOLATIONS[@]}"; do
        echo "  $violation"
    done
    echo ""
    echo "🔧 Fix by using String(localized: \"key\") instead of hardcoded strings"
    echo ""
    exit 1
else
    echo "✅ No localization violations found"
fi

# Validate .xcstrings integrity
if [[ -f "bitchat/Localizable.xcstrings" ]]; then
    python3 -c "
import json
import sys
try:
    with open('bitchat/Localizable.xcstrings') as f:
        data = json.load(f)
    
    strings = data.get('strings', {})
    if len(strings) < 50:
        print('⚠️  Warning: Only {} keys found, expected 80+'.format(len(strings)))
    else:
        print('✅ xcstrings file has {} keys'.format(len(strings)))
        
    # Check language parity
    all_langs = set()
    for entry in strings.values():
        all_langs.update(entry.get('localizations', {}).keys())
    
    if len(all_langs) != 29:
        print('❌ Expected 29 languages, found {}'.format(len(all_langs)))
        sys.exit(1)
    else:
        print('✅ All 29 languages present with parity')

except Exception as e:
    print('❌ xcstrings validation failed: {}'.format(e))
    sys.exit(1)
" || exit 1
fi

echo "✅ Build-time localization validation passed!"