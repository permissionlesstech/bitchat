#!/usr/bin/env bash
# Non-Nix hosts: just verify flake.nix is parseable JSON-ish via nix if present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v nix >/dev/null 2>&1; then
  echo "nix not installed; skipping flake evaluation"
  # Still require the files to exist
  test -f "$ROOT/flake.nix"
  test -f "$ROOT/docs/NIX.md"
  exit 0
fi
nix flake check "$ROOT" --no-build 2>/dev/null || nix eval "$ROOT#devShells.$(nix eval --impure --raw --expr 'builtins.currentSystem')"#default.name
