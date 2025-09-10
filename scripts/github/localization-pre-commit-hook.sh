#!/bin/bash

# Git Pre-Commit Hook: Localization String Validation
# 
# This script validates that no hardcoded UI strings are being introduced
# and ensures localization keys are properly synchronized.
#
# To enable this hook:
#   cp scripts/github/localization-pre-commit-hook.sh .git/hooks/pre-commit
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

# Enforce developer comments on all keys (context for translators)
check_comments() {
    local file="$1"
    python3 - "$file" << 'PY' || return 1
import json, sys
p = sys.argv[1]
with open(p, 'r', encoding='utf-8') as f:
    data = json.load(f)
strings = data.get('strings', {})
missing = [k for k,v in strings.items() if not (isinstance(v.get('comment'), str) and v.get('comment').strip())]
if missing:
    print(f"❌ Missing comments in {p}: {len(missing)} keys")
    # Print a few examples for guidance
    for k in missing[:5]:
        print("  -", k)
    sys.exit(10)
print(f"✅ All keys in {p} have comments")
PY
}

ensure_comments_or_fail() {
    local file="$1"
    if [[ -f "$file" ]]; then
        if ! check_comments "$file" >/dev/null 2>&1; then
            echo "⚠️  Missing translator comments detected in: $file"
            if [[ -f "scripts/localization/add_missing_comments.py" ]]; then
                echo "🔧 Auto-adding concise comments..."
                python3 scripts/localization/add_missing_comments.py "$file" || true
                # Re-check and surface results
                if ! check_comments "$file"; then
                    VIOLATIONS="$VIOLATIONS\n- Missing translator comments in $file"
                else
                    echo "ℹ️  Comments were added automatically. Review and stage changes."
                    VIOLATIONS="$VIOLATIONS\n- Comments added to $file — review and git add before committing"
                fi
            else
                VIOLATIONS="$VIOLATIONS\n- Missing translator comments in $file"
            fi
        else
            echo "✅ Translator comments present in $file"
        fi
    fi
}

# Check comments for both catalogs
ensure_comments_or_fail "bitchat/Localizable.xcstrings"
ensure_comments_or_fail "bitchat/Infoplist.xcstrings"

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
