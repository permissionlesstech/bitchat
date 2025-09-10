#!/usr/bin/env bash

# prepare_translations.sh — Create per-locale "-translated.csv" copies for editing
#
# Usage:
#   ./scripts/localization/prepare_translations.sh
#
# Copies:
#   tmp/localizable/<loc>.csv    -> tmp/localizable/<loc>-translated.csv
#   tmp/infoplist/<loc>.csv     -> tmp/infoplist/<loc>-translated.csv

set -euo pipefail

ROOT="scripts/localization/tmp"
mkdir -p "$ROOT/localizable" "$ROOT/infoplist"

count=0
for f in "$ROOT/localizable"/*.csv "$ROOT/infoplist"/*.csv; do
  [[ -f "$f" ]] || continue
  dir=$(dirname "$f")
  base=$(basename "$f")
  loc="${base%.csv}"
  out="$dir/${loc}-translated.csv"
  cp "$f" "$out"
  echo "📝 Prepared $out"
  count=$((count+1))
done

echo "✅ Prepared $count translated CSV files."

