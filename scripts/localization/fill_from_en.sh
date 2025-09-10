#!/usr/bin/env bash

# fill_from_en.sh — Prefill translated CSVs with English values and needs_review status
#
# Usage:
#   ./scripts/localization/fill_from_en.sh <locale1> [<locale2> ...]

set -euo pipefail

ROOT="scripts/localization/tmp"

fill_one() {
  local LOC="$1"
  for dir in localizable infoplist; do
    local IN="$ROOT/$dir/$LOC.csv"
    local OUT="$ROOT/$dir/${LOC}-translated.csv"
    if [[ ! -f "$IN" ]]; then echo "⚠️  Missing $IN"; continue; fi
    # Create header and copy with localized=en and status=needs_review
    python3 - "$IN" "$OUT" << 'PY'
import csv, sys
inp=sys.argv[1]; out=sys.argv[2]
rows=[]
with open(inp,'r',encoding='utf-8') as f:
  r=csv.DictReader(f)
  for row in r:
    row['localized']=row.get('en','')
    row['status']='needs_review'
    rows.append(row)
with open(out,'w',encoding='utf-8',newline='') as f:
  w=csv.DictWriter(f, fieldnames=['key','en','localized','comment','status'])
  w.writeheader(); w.writerows(rows)
print(f"Wrote {len(rows)} rows -> {out}")
PY
  done
}

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <locale1> [<locale2> ...]"; exit 2
fi

for loc in "$@"; do
  echo "📝 Prefilling $loc from English with needs_review"
  fill_one "$loc"
done

echo "✅ Prefill complete."
