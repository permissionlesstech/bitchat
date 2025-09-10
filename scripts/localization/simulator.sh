#!/usr/bin/env bash

# simulator.sh — Simulator-related localization commands
#
# Usage:
#   ./scripts/localization/simulator.sh help
#   ./scripts/localization/simulator.sh locale --lang <code> [--region <CC>] [--device <udid>] [--boot] [--restart] [--launch <bundle>] [--dry-run]

set -euo pipefail

cmd=${1:-help}; shift || true
DRY=false

run() { echo "$*"; if [[ "$DRY" == false ]]; then eval "$@"; fi }

locale_cmd() {
  local LANG_CODE="" REGION_CODE="" UDID="" BOOT=false RESTART=false LAUNCH=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --lang) LANG_CODE="$2"; shift 2;;
    --region) REGION_CODE="$2"; shift 2;;
    --device) UDID="$2"; shift 2;;
    --boot) BOOT=true; shift;;
    --restart) RESTART=true; shift;;
    --launch) LAUNCH="$2"; shift 2;;
    --dry-run|--check) DRY=true; shift;;
    -h|--help) echo "Usage: $0 locale --lang <code> [--region <CC>] [--device <udid>] [--boot] [--restart] [--launch <bundle>] [--dry-run]"; return 0;;
    *) echo "Unknown arg: $1"; return 2;; esac; done
  [[ -n "$LANG_CODE" ]] || { echo "❌ --lang required"; return 2; }
  if [[ -z "$REGION_CODE" ]]; then
    case "$LANG_CODE" in en) REGION_CODE=US;; es) REGION_CODE=ES;; fr) REGION_CODE=FR;; de) REGION_CODE=DE;; pt) REGION_CODE=PT;; pt-BR) REGION_CODE=BR;; ru) REGION_CODE=RU;; ja) REGION_CODE=JP;; ar|arz) REGION_CODE=SA;; hi) REGION_CODE=IN;; zh-Hans) REGION_CODE=CN;; zh-Hant) REGION_CODE=TW;; zh-HK) REGION_CODE=HK;; tr) REGION_CODE=TR;; vi) REGION_CODE=VN;; id) REGION_CODE=ID;; bn) REGION_CODE=BD;; fil|tl) REGION_CODE=PH;; yue) REGION_CODE=HK;; ur) REGION_CODE=PK;; ta|te|mr) REGION_CODE=IN;; sw) REGION_CODE=KE;; ha|pcm) REGION_CODE=NG;; pnb) REGION_CODE=PK;; *) REGION_CODE=US;; esac
  fi
  local LOCALE="${LANG_CODE%%-*}_${REGION_CODE}"
  if [[ -z "$UDID" ]]; then
    BOOTED=( $(xcrun simctl list devices | awk '/Booted/{print $NF}' | tr -d '()') ) || true
    if [[ ${#BOOTED[@]} -eq 1 ]]; then UDID="${BOOTED[0]}"; else
      if [[ "$BOOT" == true ]]; then
        echo "🛫 Booting an available iPhone..."
        local DEV_LINE=$(xcrun simctl list devices available | awk 'BEGIN{ios=0} /== Devices ==/{next} /iOS/{ios=1;next} ios && /iPhone/ {print; exit}')
        [[ -n "$DEV_LINE" ]] || { echo "❌ No iPhone simulator available"; return 2; }
        UDID=$(echo "$DEV_LINE" | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)).*/\1/p')
        [[ -n "$UDID" ]] || { echo "❌ Could not parse UDID"; return 2; }
        run xcrun simctl boot "$UDID" || true
        run xcrun simctl bootstatus "$UDID" -b
      else
        echo "❌ Specify --device <udid> or pass --boot"; xcrun simctl list devices | sed -n '1,120p'; return 2
      fi
    fi
  fi
  echo "📱 Device: $UDID"; echo "🌐 Language: $LANG_CODE  Locale: $LOCALE"
  run xcrun simctl spawn "$UDID" defaults write -g AppleLanguages -array "$LANG_CODE"
  run xcrun simctl spawn "$UDID" defaults write -g AppleLocale "$LOCALE"
  run xcrun simctl spawn "$UDID" killall -u mobile cfprefsd || true
  if [[ -n "$LAUNCH" ]]; then
    run xcrun simctl launch "$UDID" "$LAUNCH" -AppleLanguages "(\"$LANG_CODE\")" -AppleLocale "$LOCALE" || true
  fi
  if [[ "$RESTART" == true ]]; then
    run xcrun simctl shutdown "$UDID" || true
    run xcrun simctl boot "$UDID"
    run xcrun simctl bootstatus "$UDID" -b
  fi
  echo "✅ Locale ${DRY:+(dry-run) }applied"
}

case "$cmd" in
  help|-h|--help) sed -n '1,40p' "$0" | sed -n '1,20p';;
  locale) locale_cmd "$@";;
  *) echo "Unknown command: $cmd"; exit 2;;
esac

