#!/bin/bash
set -euo pipefail

# check-translations.sh — report missing/empty translations for required locales
# Usage:
#   ./bitchatTests/UI/Localization/Scripts/check-translations.sh [--file ...] [--required es,fr,zh-Hans,ar,ru,pt-BR]

FILE="bitchat/Localization/Localizable.xcstrings"
REQUIRED="es,fr,zh-Hans,ar,ru,pt-BR"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="$2"; shift 2;;
    --required) REQUIRED="$2"; shift 2;;
    --help) echo "Usage: $0 [--file <xcstrings>] [--required <csv>]"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ ! -f "$FILE" ]]; then
  echo "❌ Cannot find file: $FILE" >&2; exit 2
fi

RESULTS=$( XCSTR_FILE="$FILE" REQ_LOCALES="$REQUIRED" /usr/bin/python3 - << 'PY' || true
import sys, json, os
from pathlib import Path
file = os.environ.get('XCSTR_FILE')
required = [s.strip() for s in os.environ.get('REQ_LOCALES','').split(',') if s.strip()]
data = json.loads(Path(file).read_text())
strings = data.get('strings', {})
missing = {loc: [] for loc in required}
empty = {loc: [] for loc in required}
for key, entry in strings.items():
    locs = entry.get('localizations', {})
    for loc in required:
        if loc not in locs:
            missing[loc].append(key)
        else:
            val = locs[loc].get('stringUnit',{}).get('value','')
            if not val:
                empty[loc].append(key)
had_error = False
for loc in required:
    if missing[loc]:
        print(f"❌ {loc}: missing {len(missing[loc])} keys")
        had_error = True
    if empty[loc]:
        print(f"⚠️  {loc}: {len(empty[loc])} empty values")
if not had_error:
    print("✅ No missing keys for required locales.")
sys.exit(1 if had_error else 0)
PY
)

echo "$RESULTS"
if echo "$RESULTS" | grep -q '^❌'; then exit 1; fi
exit 0
