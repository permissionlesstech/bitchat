#!/usr/bin/env bash
set -euo pipefail

# cleanup_localization_artifacts.sh — remove temporary localization exports/artifacts
# Usage:
#   ./scripts/cleanup_localization_artifacts.sh

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

cleanup() {
  local removed=0
  if [[ -d "$ROOT_DIR/localization_exports" ]]; then
    rm -rf "$ROOT_DIR/localization_exports"
    echo "🧹 Removed localization_exports/"
    removed=1
  fi
  # Remove stray CSVs placed next to the catalog (defensive)
  find "$ROOT_DIR/bitchat/Localization" -maxdepth 1 -type f -name '*.csv' -print0 | xargs -0 rm -f 2>/dev/null || true
  # Remove possible temporary files
  find "$ROOT_DIR" -type f \( -name '*.bak' -o -name '*~' \) -print0 | xargs -0 rm -f 2>/dev/null || true
  if [[ $removed -eq 0 ]]; then
    echo "Nothing to clean."
  fi
}

cleanup

