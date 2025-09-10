#!/bin/bash

# Wrapper script to sync localization using the modern .xcstrings format
# Ensures all 29 supported languages have all keys with fallback to English values

set -e

echo "🌐 Syncing Localizable.xcstrings for 29 languages..."
echo "Languages: en, es, zh-Hans, zh-Hant, zh-HK, ar, arz, hi, fr, de, ru, ja, pt, pt-BR, ur, tr, vi, id, bn, fil, tl, yue, ta, te, mr, sw, ha, pcm, pnb"
echo ""

python3 "$(dirname "$0")/localization/sync_xcstrings.py" bitchat/Localizable.xcstrings

echo "✅ Localization sync complete!"
echo ""
echo "📝 Usage tips:"
echo "• This script ensures all 29 languages have the same keys"
echo "• Missing keys are filled with English values for translation"
echo "• Run this after adding new localization keys to the catalog"
echo "• Supports major world languages + regional variants"
echo "• Includes RTL languages (Arabic, Urdu) and CJK languages (Chinese, Japanese)"