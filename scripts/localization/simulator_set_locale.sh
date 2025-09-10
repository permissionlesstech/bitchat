#!/usr/bin/env bash

# simulator_set_locale.sh — Quickly set Simulator language/locale
#
# Usage:
#   ./scripts/simulator/set-locale.sh --lang fr --region FR [--device <udid>] [--restart]
#   ./scripts/simulator/set-locale.sh --lang es --launch com.example.app [--device <udid>]
#
# Behavior:
# - If --device is omitted and exactly one Simulator is Booted, that UDID is used.
# - Sets device-wide AppleLanguages and AppleLocale via simctl spawn defaults.
# - Optional: reboot the Simulator device to apply system-wide.
# - Optional: launch an app with per-launch overrides instead of rebooting.

set -euo pipefail

LANG_CODE=""
REGION_CODE=""
UDID=""
RESTART=false
BOOT_ON_DEMAND=false
LAUNCH_BUNDLE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang)
      LANG_CODE="$2"; shift 2;;
    --region)
      REGION_CODE="$2"; shift 2;;
    --device)
      UDID="$2"; shift 2;;
    --restart)
      RESTART=true; shift;;
    --boot)
      BOOT_ON_DEMAND=true; shift;;
    --launch)
      LAUNCH_BUNDLE="$2"; shift 2;;
    --dry-run|--check)
      DRY_RUN=true; shift;;
    -h|--help)
      echo "Usage: $0 --lang <code> [--region <CC>] [--device <udid>] [--restart] [--launch <bundle>]"; exit 0;;
    *)
      echo "Unknown argument: $1"; exit 2;;
  esac
done

if [[ -z "$LANG_CODE" ]]; then
  echo "❌ --lang is required (e.g., fr, es, zh-Hans)"; exit 2
fi

# Derive locale if region omitted (basic defaults)
if [[ -z "$REGION_CODE" ]]; then
  case "$LANG_CODE" in
    en) REGION_CODE="US";; es) REGION_CODE="ES";; fr) REGION_CODE="FR";; de) REGION_CODE="DE";;
    pt) REGION_CODE="PT";; "pt-BR") REGION_CODE="BR";; ru) REGION_CODE="RU";; ja) REGION_CODE="JP";;
    ar|arz) REGION_CODE="SA";; hi) REGION_CODE="IN";; zh-Hans) REGION_CODE="CN";; zh-Hant) REGION_CODE="TW";;
    zh-HK) REGION_CODE="HK";; tr) REGION_CODE="TR";; vi) REGION_CODE="VN";; id) REGION_CODE="ID";;
    bn) REGION_CODE="BD";; fil|tl) REGION_CODE="PH";; yue) REGION_CODE="HK";; ur) REGION_CODE="PK";;
    ta) REGION_CODE="IN";; te) REGION_CODE="IN";; mr) REGION_CODE="IN";; sw) REGION_CODE="KE";;
    ha) REGION_CODE="NG";; pcm) REGION_CODE="NG";; pnb) REGION_CODE="PK";;
    *) REGION_CODE="US";;
  esac
fi

LOCALE="${LANG_CODE%%-*}_${REGION_CODE}"

if [[ -z "$UDID" ]]; then
  # Try use the only Booted simulator UDID
  BOOTED=( $(xcrun simctl list devices | awk '/Booted/{print $NF}' | tr -d '()') ) || true
  if [[ ${#BOOTED[@]} -eq 1 ]]; then
    UDID="${BOOTED[0]}"
  else
    if [[ "$BOOT_ON_DEMAND" == true ]]; then
      echo "🛫 No single booted device. Booting an available iPhone..."
      # Pick the first available iPhone device from the iOS section
      DEV_LINE=$(xcrun simctl list devices available | awk 'BEGIN{ios=0} /== Devices ==/{next} /iOS/{ios=1;next} ios && /iPhone/ {print; exit}')
      if [[ -z "$DEV_LINE" ]]; then
        echo "❌ Could not find an available iPhone simulator to boot."; exit 2
      fi
      UDID=$(echo "$DEV_LINE" | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)).*/\1/p')
      if [[ -z "$UDID" ]]; then
        echo "❌ Failed to parse UDID from: $DEV_LINE"; exit 2
      fi
      echo "🔧 Booting $UDID"
      run xcrun simctl boot "$UDID" || true
      run xcrun simctl bootstatus "$UDID" -b
    else
      echo "❌ Specify --device <udid> (found ${#BOOTED[@]} booted devices). Or pass --boot to auto-boot one."
      xcrun simctl list devices | sed -n '1,160p'
      exit 2
    fi
  fi
fi

echo "📱 Target device: $UDID"
echo "🌐 Setting language: $LANG_CODE, locale: $LOCALE"

# Device-wide settings via defaults
run xcrun simctl spawn "$UDID" defaults write -g AppleLanguages -array "$LANG_CODE"
run xcrun simctl spawn "$UDID" defaults write -g AppleLocale "$LOCALE"

# Nudge cfprefsd so changes pick up faster
run xcrun simctl spawn "$UDID" killall -u mobile cfprefsd || true

if [[ -n "$LAUNCH_BUNDLE" ]]; then
  echo "🚀 Launching $LAUNCH_BUNDLE with overrides"
  # Per-app launch overrides: no reboot required
  run xcrun simctl launch "$UDID" "$LAUNCH_BUNDLE" -AppleLanguages "(\"$LANG_CODE\")" -AppleLocale "$LOCALE" || true
fi

if [[ "$RESTART" == true ]]; then
  echo "🔁 Restarting Simulator device to apply system-wide settings"
  run xcrun simctl shutdown "$UDID" || true
  run xcrun simctl boot "$UDID"
  run xcrun simctl bootstatus "$UDID" -b
fi

echo "✅ Locale ${DRY_RUN:+(dry-run) }applied. Language=$LANG_CODE, Locale=$LOCALE"
run() {
  echo "$*"
  if [[ "$DRY_RUN" == false ]]; then
    eval "$@"
  fi
}
