#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_ENV="${NDR_DEVICE_E2E_ENV:-$ROOT_DIR/.local/ndr-device-e2e.env}"
RUN_ROOT="${NDR_DEVICE_E2E_RUN_ROOT:-$ROOT_DIR/.local/ndr-device-e2e}"
COMMAND="${1:-run}"
if [[ $# -gt 0 ]]; then
    shift
fi

usage() {
    cat <<'EOF'
Usage:
  scripts/ndr-device-e2e.sh run [--duration seconds]
  scripts/ndr-device-e2e.sh preflight
  scripts/ndr-device-e2e.sh checklist

Optional local config:
  cp scripts/ndr-device-e2e.env.example .local/ndr-device-e2e.env
  $EDITOR .local/ndr-device-e2e.env

What this does:
  - Builds and launches the macOS app unless RUN_MAC=0.
  - Builds, installs, and launches the iOS app when IOS_DEVICE_ID is set.
  - Builds, installs, and launches the Android app when ANDROID_SERIAL is set.
  - Captures macOS, iOS, and Android logs into .local/ndr-device-e2e/.
  - Prints a manual checklist for cross-device NDR/private-message smoke.

The script intentionally does not contain local device names or IDs. Keep those
in .local/ndr-device-e2e.env, which is ignored by git.
EOF
}

log() {
    printf '[ndr-device-e2e] %s\n' "$*"
}

die() {
    printf '[ndr-device-e2e] error: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

load_env() {
    if [[ -f "$LOCAL_ENV" ]]; then
        # shellcheck disable=SC1090
        source "$LOCAL_ENV"
    fi

    ANDROID_REPO="${ANDROID_REPO:-$ROOT_DIR/../bitchat-android}"
    if [[ "$ANDROID_REPO" != /* ]]; then
        ANDROID_REPO="$ROOT_DIR/$ANDROID_REPO"
    fi
    IOS_BUNDLE_ID="${IOS_BUNDLE_ID:-chat.bitchat}"
    ANDROID_PACKAGE="${ANDROID_PACKAGE:-com.bitchat.droid}"
    ANDROID_ACTIVITY="${ANDROID_ACTIVITY:-com.bitchat.android.MainActivity}"
    DURATION_SECONDS="${DURATION_SECONDS:-240}"

    RUN_MAC="${RUN_MAC:-1}"
    if [[ -n "${IOS_DEVICE_ID:-}" ]]; then
        RUN_IOS="${RUN_IOS:-1}"
    else
        RUN_IOS="${RUN_IOS:-0}"
    fi
    if [[ -n "${ANDROID_SERIAL:-}" ]]; then
        RUN_ANDROID="${RUN_ANDROID:-1}"
    else
        RUN_ANDROID="${RUN_ANDROID:-0}"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --duration)
                [[ $# -ge 2 ]] || die "--duration requires seconds"
                DURATION_SECONDS="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

preflight() {
    need_cmd xcodebuild
    need_cmd xcrun

    if [[ "$RUN_ANDROID" == "1" ]]; then
        need_cmd adb
        [[ -d "$ANDROID_REPO" ]] || die "ANDROID_REPO does not exist: $ANDROID_REPO"
        [[ -x "$ANDROID_REPO/gradlew" ]] || die "gradlew not executable in ANDROID_REPO: $ANDROID_REPO"
        [[ -n "${ANDROID_SERIAL:-}" ]] || die "ANDROID_SERIAL must be set when RUN_ANDROID=1"
        adb -s "$ANDROID_SERIAL" get-state >/dev/null
    fi

    if [[ "$RUN_IOS" == "1" ]]; then
        [[ -n "${IOS_DEVICE_ID:-}" ]] || die "IOS_DEVICE_ID must be set when RUN_IOS=1"
    fi
}

make_run_dir() {
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
    RUN_DIR="$RUN_ROOT/$RUN_ID"
    DERIVED_DATA="$RUN_DIR/DerivedData"
    mkdir -p "$RUN_DIR"
    log "writing logs to $RUN_DIR"
}

build_and_launch_mac() {
    [[ "$RUN_MAC" == "1" ]] || return 0

    log "building macOS app"
    xcodebuild \
        -project "$ROOT_DIR/bitchat.xcodeproj" \
        -scheme "bitchat (macOS)" \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "$DERIVED_DATA/macos" \
        CODE_SIGNING_ALLOWED=NO \
        build \
        -quiet

    local app_path
    app_path="$(find "$DERIVED_DATA/macos/Build/Products/Debug" -name 'bitchat.app' -type d -print -quit)"
    [[ -n "$app_path" ]] || die "macOS app build did not produce bitchat.app"

    log "launching macOS app"
    open "$app_path"
}

build_install_launch_ios() {
    [[ "$RUN_IOS" == "1" ]] || return 0

    log "building iOS app for configured device"
    xcodebuild \
        -project "$ROOT_DIR/bitchat.xcodeproj" \
        -scheme "bitchat (iOS)" \
        -configuration Debug \
        -destination "id=$IOS_DEVICE_ID" \
        -derivedDataPath "$DERIVED_DATA/ios" \
        build \
        -quiet

    local app_path
    app_path="$(find "$DERIVED_DATA/ios/Build/Products/Debug-iphoneos" -name 'bitchat.app' -type d -print -quit)"
    [[ -n "$app_path" ]] || die "iOS device build did not produce bitchat.app"

    log "installing iOS app"
    xcrun devicectl device install app --device "$IOS_DEVICE_ID" "$app_path" >/dev/null

    log "launching iOS app"
    xcrun devicectl device process launch --device "$IOS_DEVICE_ID" "$IOS_BUNDLE_ID" >/dev/null || true
}

build_install_launch_android() {
    [[ "$RUN_ANDROID" == "1" ]] || return 0

    log "building and installing Android app"
    (
        cd "$ANDROID_REPO"
        ./gradlew installDebug -Pandroid.injected.adb.device.serial="$ANDROID_SERIAL"
    )

    log "granting Android runtime permissions when possible"
    for perm in \
        android.permission.BLUETOOTH_SCAN \
        android.permission.BLUETOOTH_CONNECT \
        android.permission.BLUETOOTH_ADVERTISE \
        android.permission.ACCESS_FINE_LOCATION \
        android.permission.ACCESS_COARSE_LOCATION \
        android.permission.POST_NOTIFICATIONS; do
        adb -s "$ANDROID_SERIAL" shell pm grant "$ANDROID_PACKAGE" "$perm" >/dev/null 2>&1 || true
    done

    log "launching Android app"
    adb -s "$ANDROID_SERIAL" shell am start -n "$ANDROID_PACKAGE/$ANDROID_ACTIVITY" >/dev/null
}

LOG_PIDS=()

start_logs() {
    if [[ "$RUN_MAC" == "1" ]]; then
        log "capturing macOS logs"
        (log stream --style compact --predicate 'process == "bitchat"' >"$RUN_DIR/macos.log" 2>&1) &
        LOG_PIDS+=("$!")
    fi

    if [[ "$RUN_IOS" == "1" ]]; then
        log "capturing iOS logs"
        (xcrun devicectl device log stream --device "$IOS_DEVICE_ID" --predicate 'process == "bitchat"' >"$RUN_DIR/ios.log" 2>&1) &
        LOG_PIDS+=("$!")
    fi

    if [[ "$RUN_ANDROID" == "1" ]]; then
        log "capturing Android logs"
        adb -s "$ANDROID_SERIAL" logcat -c || true
        (adb -s "$ANDROID_SERIAL" logcat -v time \
            MainActivity:D \
            NostrRelayManager:V \
            NostrTransport:V \
            NdrNostrService:V \
            NostrDirectMessageHandler:V \
            BluetoothMeshService:D \
            MeshForegroundService:D \
            '*:S' >"$RUN_DIR/android.log" 2>&1) &
        LOG_PIDS+=("$!")
    fi
}

stop_logs() {
    local pid
    for pid in "${LOG_PIDS[@]:-}"; do
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    done
}

print_checklist() {
    cat <<'EOF'

Manual cross-device NDR smoke:

1. Bring the configured clients online: macOS, iOS device, and Android device.
2. Confirm each client has network permission and can connect to Nostr relays.
3. Establish/refresh mutual favorites over the app UI so NDR out-of-band invite
   exchange can happen over the mesh path.
4. Send private messages in both directions for each pair:
   - macOS <-> iOS
   - macOS <-> Android
   - iOS <-> Android
5. Force one client to quit, relaunch it, then send again to verify stored relay
   events are processed after late subscription.
6. Watch for:
   - successful NDR session creation
   - kind 1060 publishes
   - decrypted private messages
   - repeated subscription churn or excessive relay reconnects
   - failed/rejected relay publishes

EOF
}

summarize_one_log() {
    local label="$1"
    local path="$2"
    [[ -f "$path" ]] || return 0

    local ndr_count
    local relay_count
    local error_count
    ndr_count="$(grep -Eci 'Ndr|double.?ratchet|kind[ =:]1060|decrypted' "$path" || true)"
    relay_count="$(grep -Eci 'REQ|subscribe|subscription|relay|WebSocket|kind[ =:]1060' "$path" || true)"
    error_count="$(grep -Eci 'error|failed|reject|panic|fatal|exception' "$path" || true)"

    printf '%s: ndr=%s relay=%s errors=%s log=%s\n' \
        "$label" "$ndr_count" "$relay_count" "$error_count" "$path"
}

summarize_logs() {
    log "log summary"
    summarize_one_log "macOS" "$RUN_DIR/macos.log"
    summarize_one_log "iOS" "$RUN_DIR/ios.log"
    summarize_one_log "Android" "$RUN_DIR/android.log"
}

run_all() {
    preflight
    make_run_dir
    trap stop_logs EXIT

    build_and_launch_mac
    build_install_launch_ios
    build_install_launch_android
    start_logs
    print_checklist

    log "collecting logs for ${DURATION_SECONDS}s"
    sleep "$DURATION_SECONDS"
    stop_logs
    summarize_logs
}

load_env
parse_args "$@"

case "$COMMAND" in
    run)
        run_all
        ;;
    preflight)
        preflight
        log "preflight ok"
        ;;
    checklist)
        print_checklist
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
