#!/usr/bin/env bash
set -euo pipefail

# test-sim-locale.sh — helper for simulator locale + localization tests
# Usage examples:
#   ./bitchatTests/UI/Localization/Scripts/test-sim-locale.sh --help
#   ./bitchatTests/UI/Localization/Scripts/test-sim-locale.sh --get
#   ./bitchatTests/UI/Localization/Scripts/test-sim-locale.sh --set --locale es_ES
#   ./bitchatTests/UI/Localization/Scripts/test-sim-locale.sh --test

# Resolve repo root robustly: prefer git, fallback by walking up to find the .xcodeproj
ROOT_DIR="$(
  git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || \
  (cd "$(dirname "$0")"; while [ ! -e bitchat.xcodeproj ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)
)"
PROJECT="$ROOT_DIR/bitchat.xcodeproj"
SCHEME_DEFAULT="bitchat (iOS)"
DEST_DEFAULT="platform=iOS Simulator,name=iPhone 15"

usage() {
  cat <<EOF
Usage:
  $0 --help
  $0 --get | --set --locale <BCP47> | --test [--scheme S] [--dest D] [--id UDID]
EOF
}

find_booted_udid() {
  BOOTED_LINE="$(xcrun simctl list devices | grep -m1 'Booted' || true)"
  if [[ -n "$BOOTED_LINE" ]]; then
    sed -n 's/.*(\([A-F0-9-]\{36\}\)).*/\1/p' <<< "$BOOTED_LINE"
    return 0
  fi
  return 1
}

get_locale() {
  local udid=$1
  local lang locale
  locale=$(xcrun simctl spawn "$udid" defaults read -g AppleLocale || true)
  lang=$(xcrun simctl spawn "$udid" defaults read -g AppleLanguages | sed -e 's/[()\n]//g' -e 's/\s\+//g' || true)
  echo "📍 Simulator: $udid"
  echo "  • AppleLocale     : ${locale:-<unknown>}"
  echo "  • AppleLanguages  : ${lang:-<unknown>}"
}

set_locale() {
  local udid=$1
  local tag=$2
  local lang=${tag%%_*}
  echo "🛠 Setting locale on $udid to $tag (language=$lang)"
  xcrun simctl spawn "$udid" defaults write -g AppleLocale "$tag"
  xcrun simctl spawn "$udid" defaults write -g AppleLanguages "(\"$lang\")"
  echo "🔄 Restarting SpringBoard to apply settings"
  if ! xcrun simctl spawn "$udid" launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null; then
    if ! xcrun simctl spawn "$udid" killall -9 SpringBoard 2>/dev/null; then
      echo "ℹ️  Cycling simulator (shutdown/boot) to apply settings" >&2
      xcrun simctl shutdown "$udid" || true
      xcrun simctl boot "$udid" || true
      xcrun simctl bootstatus "$udid" -b || true
    fi
  fi
}

run_tests() {
  local scheme=${1:-$SCHEME_DEFAULT}
  local dest=${2:-$DEST_DEFAULT}
  # If a specific simulator UDID was provided, prefer that over the default destination
  if [[ -n "${UDID:-}" ]]; then dest="id=$UDID"; fi
  echo "🧪 Running UITests — scheme: $scheme; destination: $dest"
  if command -v xcpretty >/dev/null 2>&1; then
    xcodebuild -scheme "$scheme" -project "$PROJECT" -destination "$dest" -derivedDataPath "$ROOT_DIR/DerivedData" test | xcpretty -c
  else
    xcodebuild -scheme "$scheme" -project "$PROJECT" -destination "$dest" -derivedDataPath "$ROOT_DIR/DerivedData" test
  fi
}

UDID=""; DO_GET=false; DO_SET=false; DO_TEST=false; LOCALE_TAG=""; SCHEME="$SCHEME_DEFAULT"; DEST="$DEST_DEFAULT"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage; exit 0;;
    --id) UDID="$2"; shift 2;;
    --get) DO_GET=true; shift;;
    --set) DO_SET=true; shift;;
    --locale) LOCALE_TAG="$2"; shift 2;;
    --scheme) SCHEME="$2"; shift 2;;
    --dest) DEST="$2"; shift 2;;
    --test) DO_TEST=true; shift;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ $DO_TEST == true ]]; then
  run_tests "$SCHEME" "$DEST"; exit 0
fi

if [[ -z "$UDID" ]]; then
  UDID=$(find_booted_udid || true)
fi
if [[ -z "$UDID" ]]; then
  echo "❌ No booted simulator found; specify --id <UDID> or boot a simulator." >&2
  echo "ℹ️  Tip: xcrun simctl list devices | grep -m1 Booted || echo 'No booted device yet'" >&2
  exit 1
fi

if [[ $DO_GET == true ]]; then
  get_locale "$UDID"
  exit 0
fi

if [[ $DO_SET == true ]]; then
  if [[ -z "$LOCALE_TAG" ]]; then
    echo "❌ --set requires --locale <BCP47> (e.g., es_ES, fr_FR)" >&2
    exit 1
  fi
  set_locale "$UDID" "$LOCALE_TAG"
  echo "✅ Done."
  exit 0
fi

usage; exit 1
