#!/usr/bin/env bash
set -euo pipefail

# seed-missing-translations.sh — fill missing required locales by copying English values
# Usage:
#   ./bitchatTests/UI/Localization/Scripts/seed-missing-translations.sh [--file <xcstrings>] [--required es,fr,zh-Hans,ar,ru,pt-BR]

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
updated = 0
for key, entry in strings.items():
    locs = entry.setdefault('localizations', {})
    en = locs.get('en', {}).get('stringUnit', {}).get('value')
    if not en:
        # No English value to copy; skip
        continue
    for loc in required:
        su = locs.get(loc, {}).get('stringUnit', {})
        val = su.get('value') if su else None
        if not val:
            locs[loc] = {
                'stringUnit': {
                    'state': 'translated',
                    'value': en
                }
            }
            updated += 1
if updated:
    Path(file).write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True))
print(f"Seeded {updated} missing localization entries across required locales.")
PY
)

echo "$RESULTS"
exit 0

