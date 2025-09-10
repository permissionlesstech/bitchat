#!/bin/bash

# Git Pre-Commit Hook: Localization String Validation
# 
# This script validates that no hardcoded UI strings are being introduced
# and ensures localization keys are properly synchronized.
#
# To enable this hook:
#   cp scripts/Localization/localization-pre-commit-hook.sh .git/hooks/pre-commit
#   chmod +x .git/hooks/pre-commit
#
# To disable temporarily: 
#   git commit --no-verify

set -e

echo "🔍 Running localization validation..."

# Check for hardcoded strings in Swift files
HARDCODED_PATTERNS=(
    'Button\s*\(\s*"[^"]*"'
    'Text\s*\(\s*"[^"]*"'
    'TextField\s*\(\s*"[^"]*"'
    'Alert\s*\(\s*"[^"]*"'
    '\.accessibilityLabel\s*\(\s*"[^"]*"'
)

VIOLATIONS=""
for pattern in "${HARDCODED_PATTERNS[@]}"; do
    # Check staged Swift files for hardcoded strings
    MATCHES=$(git diff --cached --name-only | grep '\.swift$' | xargs grep -l "$pattern" 2>/dev/null || true)
    if [[ -n "$MATCHES" ]]; then
        echo "⚠️  Found potential hardcoded strings:"
        for file in $MATCHES; do
            echo "   $file"
            git diff --cached "$file" | grep -E "^\+" | grep -E "$pattern" || true
        done
        VIOLATIONS="$VIOLATIONS\n- Hardcoded strings in: $MATCHES"
    fi
done

# Verify xcstrings file integrity
if [[ -f "bitchat/Localizable.xcstrings" ]]; then
    python3 -c "
import json
import sys
try:
    with open('bitchat/Localizable.xcstrings') as f:
        data = json.load(f)
    print('✅ Localizable.xcstrings is valid JSON')
    
    strings = data.get('strings', {})
    if not strings:
        print('❌ No strings found in xcstrings file')
        sys.exit(1)
        
    # Check language parity
    all_langs = set()
    for entry in strings.values():
        all_langs.update(entry.get('localizations', {}).keys())
    
    expected_count = 29
    if len(all_langs) < expected_count:
        print(f'⚠️  Only {len(all_langs)} languages found, expected {expected_count}')
    else:
        print(f'✅ All {len(all_langs)} languages present')
        
except Exception as e:
    print(f'❌ xcstrings validation failed: {e}')
    sys.exit(1)
" || {
        VIOLATIONS="$VIOLATIONS\n- Invalid Localizable.xcstrings format"
    }
else
    echo "⚠️  Localizable.xcstrings not found"
    VIOLATIONS="$VIOLATIONS\n- Missing Localizable.xcstrings file"
fi

# Check if localization keys need sync
if command -v python3 >/dev/null 2>&1 && [[ -f "scripts/localization/sync_xcstrings.py" ]]; then
    SYNC_OUTPUT=$(python3 scripts/localization/sync_xcstrings.py bitchat/Localizable.xcstrings 2>&1)
    if echo "$SYNC_OUTPUT" | grep -q "Filled [1-9]"; then
        echo "⚠️  Localization keys are out of sync:"
        echo "$SYNC_OUTPUT"
        VIOLATIONS="$VIOLATIONS\n- Localization keys need syncing"
    fi
fi

# Summary
if [[ -n "$VIOLATIONS" ]]; then
    echo ""
    echo "❌ Pre-commit hook FAILED:"
    echo -e "$VIOLATIONS"
    echo ""
    echo "To fix:"
    echo "1. Replace hardcoded strings with String(localized: \"key\")"
    echo "2. Run: ./scripts/Localization/sync-localization.sh"
    echo "3. Add new keys to Localizable.xcstrings if needed"
    echo ""
    echo "To bypass (not recommended): git commit --no-verify"
    exit 1
else
    echo "✅ Localization validation passed!"
    exit 0
fi
