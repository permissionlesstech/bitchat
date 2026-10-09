#!/usr/bin/env bash
# Builds bitchat from source and installs it on an iPhone connected to this Mac.
# Walkthrough for non-developers: docs/INSTALL-ON-IPHONE.md
#
#   bash scripts/install-on-iphone.sh            # from a checkout
#   bash <(curl -fsSL <raw script URL>)          # standalone; clones the repo
set -euo pipefail

readonly DEFAULT_REPO_URL="https://github.com/clustercoder/bitchat.git"
readonly DEFAULT_CHECKOUT_DIR="$HOME/bitchat"
readonly SCHEME="bitchat (iOS)"
# Debug is the configuration that includes Configs/Local.xcconfig (see README).
readonly CONFIGURATION="Debug"
readonly APP_RELATIVE_PATH=".DerivedData/Build/Products/Debug-iphoneos/bitchat.app"
readonly TEAM_ID_PATTERN='^[A-Z0-9]{10}$'
readonly XCODE_APP_STORE_URL="macappstore://apps.apple.com/app/id497799835"
readonly MAX_LAUNCH_ATTEMPTS=3
readonly MAX_INSTALL_ATTEMPTS=3
readonly INSTALL_RETRY_DELAY_SECONDS=3

if [[ -t 2 ]]; then
    readonly BOLD=$'\033[1m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' RESET=$'\033[0m'
else
    readonly BOLD="" GREEN="" YELLOW="" RED="" RESET=""
fi

# --- Output helpers (UI goes to stderr so functions can return values on stdout) ---

say() { printf '%s\n' "$*" >&2; }
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET" >&2; }
ok() { printf '%s✓ %s%s\n' "$GREEN" "$*" "$RESET" >&2; }
warn() { printf '%s! %s%s\n' "$YELLOW" "$*" "$RESET" >&2; }
die() {
    printf '%s✗ %s%s\n' "$RED" "$*" "$RESET" >&2
    exit 1
}

# Prompts read from the terminal, so they work even when the script itself is piped in.
ask_enter() {
    printf '\n%s%s%s [press Enter] ' "$BOLD" "$1" "$RESET" >&2
    read -r _ </dev/tty || die "No terminal available to answer prompts. Run this script in Terminal."
}

ask_line() {
    local reply
    printf '%s ' "$1" >&2
    read -r reply </dev/tty || die "No terminal available to answer prompts. Run this script in Terminal."
    printf '%s' "$reply"
}

usage() {
    cat <<EOF
Usage: install-on-iphone.sh [options]

Builds bitchat from source and installs it on a USB-connected iPhone.
It walks you through the steps that need you (Trust, Developer Mode, etc.).

Options:
  --team TEAM_ID     Apple Developer Team ID to sign with (10 characters).
                     Detected from your Xcode signing certificate if omitted.
  --device ID        Device to install on (name, UDID, or CoreDevice identifier).
                     Asked interactively if several iPhones are connected.
  --source DIR       Existing bitchat checkout to build.
                     Default: this script's checkout, else $DEFAULT_CHECKOUT_DIR.
  -h, --help         Show this help.

Environment:
  BITCHAT_REPO_URL   Repository cloned when no checkout is found
                     (default: $DEFAULT_REPO_URL).

Full guide: docs/INSTALL-ON-IPHONE.md
EOF
}

# --- Pure helpers (covered by scripts/tests/test_install_on_iphone.py) ---

is_valid_team_id() {
    [[ $1 =~ $TEAM_ID_PATTERN ]]
}

# True if CHOICE is a menu number between 1 and COUNT ("08" is read as 8, not octal).
is_menu_choice() {
    [[ $1 =~ ^[0-9]{1,3}$ ]] && ((10#$1 >= 1 && 10#$1 <= $2))
}

# Extracts the Team ID (the certificate's OU) from an `openssl x509 -subject` line.
team_id_from_subject() {
    local team
    team="$(printf '%s\n' "$1" | grep -oE 'OU ?= ?[A-Z0-9]{10}' | head -n 1 | grep -oE '[A-Z0-9]{10}$')" || return 1
    [[ -n $team ]] || return 1
    printf '%s\n' "$team"
}

json_get() {
    plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

# Prints one tab-separated row per connected, physical iOS device in a
# `devicectl list devices --json-output` file:
# identifier, udid, name, model, pairing state, developer mode, transport.
list_iphones() {
    local json="$1" count i base transport developer_mode
    count="$(json_get "$json" result.devices)"
    [[ $count =~ ^[0-9]+$ ]] || return 0
    for ((i = 0; i < count; i++)); do
        base="result.devices.$i"
        [[ "$(json_get "$json" "$base.hardwareProperties.platform")" == "iOS" ]] || continue
        [[ "$(json_get "$json" "$base.hardwareProperties.reality")" == "physical" ]] || continue
        transport="$(json_get "$json" "$base.connectionProperties.transportType")"
        [[ -n $transport ]] || continue
        developer_mode="$(json_get "$json" "$base.deviceProperties.developerModeStatus")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(json_get "$json" "$base.identifier")" \
            "$(json_get "$json" "$base.hardwareProperties.udid")" \
            "$(json_get "$json" "$base.deviceProperties.name")" \
            "$(json_get "$json" "$base.hardwareProperties.marketingName")" \
            "$(json_get "$json" "$base.connectionProperties.pairingState")" \
            "${developer_mode:-unknown}" \
            "$transport"
    done
}

# Writes Configs/Local.xcconfig for TEAM. Prints created, unchanged, or updated.
# An existing config for a different team is kept as Local.xcconfig.backup-<time>.
write_local_config() {
    local repo="$1" team="$2"
    local config="$repo/Configs/Local.xcconfig" example="$repo/Configs/Local.xcconfig.example"
    local result="created"
    is_valid_team_id "$team" || { say "Invalid Team ID: $team"; return 1; }
    [[ -f $example ]] || { say "Missing $example"; return 1; }
    if [[ -f $config ]]; then
        if grep -Eq "^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*${team}[[:space:]]*$" "$config"; then
            printf 'unchanged\n'
            return 0
        fi
        cp "$config" "$config.backup-$(date +%Y%m%d-%H%M%S)"
        result="updated"
    fi
    sed -E "s/^DEVELOPMENT_TEAM = .*/DEVELOPMENT_TEAM = ${team}/" "$example" >"$config.tmp"
    grep -q "^DEVELOPMENT_TEAM = ${team}$" "$config.tmp" || { rm -f "$config.tmp"; say "Could not set team in $config"; return 1; }
    mv "$config.tmp" "$config"
    printf '%s\n' "$result"
}

# Prints a plain-language hint for known xcodebuild failures to stdout (nothing if unknown).
diagnose_build_log() {
    local log="$1"
    if grep -Eqi "No Accounts|No account for team|not logged in|Sign in with your Apple ID" "$log"; then
        echo "Hint: Xcode is not signed in to your Apple Account. Open Xcode > Settings > Accounts,"
        echo "      click +, add your Apple Account, then run this script again."
    elif grep -Eqi "maximum App ID limit|maximum number of apps|limit .* App IDs" "$log"; then
        echo "Hint: free Apple Accounts may only create a few app IDs per week. Wait up to 7 days,"
        echo "      or delete other apps you sideloaded with Xcode, then try again."
    elif grep -Eqi "Developer Mode" "$log"; then
        echo "Hint: turn on Developer Mode on the iPhone (Settings > Privacy & Security > Developer Mode)."
    elif grep -Eqi "not supported by this version of Xcode|newer than|Unsupported OS|is not installed" "$log"; then
        echo "Hint: your iPhone runs a newer iOS than this Xcode supports. Update Xcode from the App Store,"
        echo "      or install the iOS platform with: xcodebuild -downloadPlatform iOS"
    elif grep -Eqi "No profiles for|requires a provisioning profile|Failed Registering Bundle Identifier" "$log"; then
        echo "Hint: Xcode could not create a signing profile. Open Xcode > Settings > Accounts, select"
        echo "      your account, click 'Download Manual Profiles', then run this script again."
    elif grep -Eqi "Unable to find a destination|Unable to find a device" "$log"; then
        echo "Hint: the iPhone disconnected or is locked. Reconnect it, unlock it, and run again."
    fi
    return 0
}

# --- Mac preparation ---

check_macos() {
    [[ "$(uname -s)" == "Darwin" ]] || die "This script runs on a Mac (macOS). iPhone apps can only be built on a Mac."
}

find_xcode_app() {
    local app
    for app in /Applications/Xcode.app /Applications/Xcode*.app; do
        if [[ -d $app/Contents/Developer ]]; then
            printf '%s\n' "$app"
            return 0
        fi
    done
    return 1
}

ensure_xcode() {
    local xcode_app
    step "Checking Xcode"
    until xcode_app="$(find_xcode_app)"; do
        say "Xcode (free, from the App Store) is required. It is a large download."
        say "Opening the App Store page for Xcode..."
        open "$XCODE_APP_STORE_URL" 2>/dev/null || say "Search for 'Xcode' in the App Store."
        ask_enter "Install Xcode, open it once, then come back here"
    done
    # Fresh Macs point the developer tools at the Command Line Tools, which cannot build iOS apps.
    if [[ "$(xcode-select -p 2>/dev/null)" != *.app/Contents/Developer ]]; then
        say "Pointing the developer tools at $xcode_app (your Mac password is needed)."
        sudo xcode-select --switch "$xcode_app/Contents/Developer"
    fi
    if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || ! xcodebuild -license check >/dev/null 2>&1; then
        say "Xcode needs to finish its first-time setup and license agreement."
        say "Your Mac password is needed for this one-time step."
        sudo xcodebuild -runFirstLaunch
        sudo xcodebuild -license accept
    fi
    xcodebuild -version >/dev/null 2>&1 || die "Xcode is still not ready. Open Xcode once, accept any prompts, and run this script again."
    ok "$(xcodebuild -version | head -n 1)"
}

resolve_source_dir() {
    local requested="$1" script_dir
    if [[ -n $requested ]]; then
        [[ -f $requested/bitchat.xcodeproj/project.pbxproj ]] || die "No bitchat project found in $requested"
        (cd "$requested" && pwd)
        return
    fi
    script_dir="${BASH_SOURCE[0]:-}"
    if [[ -n $script_dir && -f $script_dir ]]; then
        script_dir="$(cd "$(dirname "$script_dir")/.." && pwd)"
        if [[ -f $script_dir/bitchat.xcodeproj/project.pbxproj ]]; then
            printf '%s\n' "$script_dir"
            return
        fi
    fi
    fetch_source "${BITCHAT_REPO_URL:-$DEFAULT_REPO_URL}" "$DEFAULT_CHECKOUT_DIR"
}

fetch_source() {
    local url="$1" dir="$2"
    if [[ -d $dir/.git ]]; then
        say "Updating the bitchat source in $dir"
        git -C "$dir" pull --ff-only >&2 || warn "Could not update $dir; building the copy already there."
    elif [[ -e $dir ]]; then
        die "$dir exists but is not a bitchat checkout. Move it away or pass --source DIR."
    else
        say "Downloading the bitchat source to $dir"
        git clone --depth 1 "$url" "$dir" >&2 || die "Could not download $url. Check your internet connection."
    fi
    [[ -f $dir/bitchat.xcodeproj/project.pbxproj ]] || die "Downloaded source has no bitchat.xcodeproj"
    printf '%s\n' "$dir"
}

# Prints "TEAM_ID<TAB>Name" for every Apple Development signing certificate.
find_signing_teams() {
    local cert subject team org
    security find-identity -v -p codesigning 2>/dev/null |
        sed -nE 's/.*"((Apple Development|iPhone Developer): .*)"$/\1/p' |
        while IFS= read -r cert; do
            subject="$(security find-certificate -c "$cert" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)" || continue
            team="$(team_id_from_subject "$subject")" || continue
            org="$(printf '%s\n' "$subject" | sed -nE 's/.*[ ,/]O ?= ?([^,/]+).*/\1/p')"
            printf '%s\t%s\n' "$team" "${org:-unknown}"
        done | sort -u
}

explain_apple_account_setup() {
    say "Xcode needs your Apple Account and a free 'Apple Development' certificate:"
    say "  1. Open Xcode, then choose Xcode > Settings… (⌘,) > Accounts."
    say "  2. Click +, choose Apple Account, and sign in (a regular free Apple Account works)."
    say "  3. Select your account, click 'Manage Certificates…', click + and choose 'Apple Development'."
}

choose_team() {
    local requested="$1" teams count choice
    if [[ -n $requested ]]; then
        is_valid_team_id "$requested" || die "--team must be a 10-character Team ID like 6GZP5XRVZH"
        printf '%s\n' "$requested"
        return
    fi
    while true; do
        teams="$(find_signing_teams)"
        count="$(printf '%s' "$teams" | awk 'NF { n++ } END { print n + 0 }')"
        if [[ $count -eq 1 ]]; then
            printf '%s\n' "$teams" | cut -f 1
            return
        elif [[ $count -gt 1 ]]; then
            say "You have more than one signing team:"
            printf '%s\n' "$teams" | awk -F'\t' '{ printf "  %d) %s  (%s)\n", NR, $2, $1 }' >&2
            choice="$(ask_line "Type the number of the team to use:")"
            if is_menu_choice "$choice" "$count"; then
                printf '%s\n' "$teams" | sed -n "$((10#$choice))p" | cut -f 1
                return
            fi
            warn "Please type a number between 1 and $count."
        else
            warn "No Apple Development certificate found on this Mac."
            explain_apple_account_setup
            ask_enter "Do the steps above in Xcode, then come back here"
        fi
    done
}

warn_if_no_xcode_account() {
    local accounts
    accounts="$(defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null || true)"
    [[ $accounts == *identifier* ]] && return
    warn "Xcode does not seem to be signed in to an Apple Account. The build needs it to create a profile."
    explain_apple_account_setup
    ask_enter "Sign in to Xcode, then continue"
}

# --- iPhone preparation ---

device_rows() {
    local json rows
    json="$(mktemp -t bitchat-devices)"
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
    rows="$(list_iphones "$json")"
    rm -f "$json"
    printf '%s' "$rows"
}

device_row() {
    device_rows | WANT="$1" awk -F'\t' '$1 == ENVIRON["WANT"]'
}

field() {
    printf '%s\n' "$1" | cut -f "$2"
}

explain_connect() {
    say "Connect your iPhone to this Mac with a USB cable and unlock it."
    say "If the iPhone asks 'Trust This Computer?', tap Trust and enter your passcode."
}

# Prints the CoreDevice identifier of the iPhone to install on.
select_device() {
    local requested="$1" rows count choice
    step "Finding your iPhone"
    while true; do
        rows="$(device_rows)"
        [[ -n $requested ]] && rows="$(printf '%s\n' "$rows" | WANT="$requested" awk -F'\t' '$1 == ENVIRON["WANT"] || $2 == ENVIRON["WANT"] || $3 == ENVIRON["WANT"]')"
        count="$(printf '%s' "$rows" | awk 'NF { n++ } END { print n + 0 }')"
        if [[ $count -eq 1 ]]; then
            ok "Found $(field "$rows" 3) ($(field "$rows" 4))"
            field "$rows" 1
            return
        elif [[ $count -gt 1 ]]; then
            say "More than one iPhone is connected:"
            printf '%s\n' "$rows" | awk -F'\t' '{ printf "  %d) %s (%s)\n", NR, $3, $4 }' >&2
            choice="$(ask_line "Type the number of the iPhone to install on:")"
            if is_menu_choice "$choice" "$count"; then
                printf '%s\n' "$rows" | sed -n "$((10#$choice))p" | cut -f 1
                return
            fi
            warn "Please type a number between 1 and $count."
        else
            warn "No iPhone found${requested:+ matching \"$requested\"}."
            explain_connect
            ask_enter "Once the iPhone is connected and unlocked"
        fi
    done
}

wait_for_device() {
    local id="$1" row
    row="$(device_row "$id")"
    while [[ -z $row ]]; do
        warn "The iPhone is not connected (it may be restarting)."
        explain_connect
        ask_enter "Once the iPhone is connected and unlocked"
        row="$(device_row "$id")"
    done
    printf '%s\n' "$row"
}

ensure_paired() {
    local id="$1" row log
    step "Pairing the iPhone with this Mac"
    log="$(mktemp -t bitchat-pair)"
    while true; do
        row="$(wait_for_device "$id")"
        if [[ "$(field "$row" 5)" == "paired" ]]; then
            ok "iPhone is paired"
            rm -f "$log"
            return
        fi
        say "Unlock your iPhone now. When it asks 'Trust This Computer?', tap Trust and enter your passcode."
        if xcrun devicectl manage pair --device "$id" >"$log" 2>&1 &&
            [[ "$(field "$(wait_for_device "$id")" 5)" == "paired" ]]; then
            continue
        fi
        warn "Pairing did not complete:"
        tail -n 5 "$log" >&2
        ask_enter "Unlock the iPhone and get ready to tap Trust, then try again"
    done
}

explain_developer_mode() {
    say "Turn on Developer Mode on the iPhone (needed for any app not from the App Store):"
    say "  1. Open Settings > Privacy & Security, scroll to the bottom, tap Developer Mode."
    say "  2. Switch it on and tap Restart."
    say "  3. After the restart, unlock the iPhone and tap Turn On, then enter your passcode."
    say "If you don't see Developer Mode: unplug and replug the cable, press Enter here, and"
    say "check again. (It stays hidden until a Mac has tried to use the iPhone for development.)"
}

ensure_developer_mode() {
    local id="$1" row status
    step "Checking Developer Mode"
    while true; do
        row="$(wait_for_device "$id")"
        status="$(field "$row" 6)"
        case "$status" in
            enabled)
                ok "Developer Mode is on"
                return
                ;;
            unknown)
                warn "Could not read the Developer Mode setting; continuing (the install will tell us)."
                return
                ;;
        esac
        # Asking for developer services makes iOS reveal the Developer Mode switch.
        xcrun devicectl device info ddiServices --device "$id" >/dev/null 2>&1 || true
        explain_developer_mode
        ask_enter "Once Developer Mode is on and the iPhone is unlocked"
    done
}

# --- Build, install, launch ---

run_with_progress() {
    local log="$1" pid started elapsed
    shift
    "$@" >"$log" 2>&1 </dev/null &
    pid=$!
    # Background jobs ignore Ctrl-C in scripts, so stop the build ourselves.
    trap 'kill "$pid" 2>/dev/null; exit 130' INT TERM
    started=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$((SECONDS - started))
        printf '\r  Working… %dm %02ds ' $((elapsed / 60)) $((elapsed % 60)) >&2
        sleep 2
    done
    printf '\r%40s\r' "" >&2
    trap - INT TERM
    wait "$pid"
}

build_app() {
    local source="$1" udid="$2" log="$3"
    step "Building bitchat (the first build takes 5–15 minutes)"
    say "Full build log: $log"
    if ! run_with_progress "$log" xcodebuild \
        -project "$source/bitchat.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "id=$udid" \
        -derivedDataPath "$source/.DerivedData" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        build; then
        warn "The build failed. Last errors:"
        grep -E "error:" "$log" | sort -u | tail -n 10 >&2 || tail -n 20 "$log" >&2
        diagnose_build_log "$log" >&2
        die "Build failed. Fix the issue above and run the script again."
    fi
    ok "Build succeeded"
}

verify_profile_includes_device() {
    local app="$1" udid="$2" profile
    profile="$(security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null || true)"
    if [[ $profile != *"$udid"* ]]; then
        die "The signing profile does not include this iPhone. Run the script again so Xcode can register it."
    fi
}

install_app() {
    local id="$1" app="$2" log attempt=1
    step "Installing bitchat on the iPhone"
    log="$(mktemp -t bitchat-install)"
    while ! xcrun devicectl device install app --device "$id" "$app" >"$log" 2>&1; do
        if grep -qi "Developer Mode is disabled" "$log"; then
            explain_developer_mode
            ask_enter "Once Developer Mode is on and the iPhone is unlocked"
            continue
        fi
        # Replacing an app that is open on the iPhone often fails once, then succeeds.
        if [[ $attempt -lt $MAX_INSTALL_ATTEMPTS ]]; then
            attempt=$((attempt + 1))
            say "Install did not go through; retrying ($attempt of $MAX_INSTALL_ATTEMPTS)…"
            sleep "$INSTALL_RETRY_DELAY_SECONDS"
            continue
        fi
        warn "Install failed:"
        grep -E "ERROR|Suggestion|Reason" "$log" | head -n 6 >&2 || tail -n 10 "$log" >&2
        rm -f "$log"
        die "Install failed. Close bitchat on the iPhone, unlock it, and run the script again."
    done
    rm -f "$log"
    ok "bitchat is installed"
}

explain_trust_certificate() {
    say "iOS blocks apps signed by a new developer until you trust them (one time only):"
    say "  1. Open Settings > General > VPN & Device Management."
    say "  2. Under 'Developer App', tap your Apple Development profile."
    say "  3. Tap Trust, then Trust again."
}

launch_app() {
    local id="$1" bundle_id="$2" attempt log
    step "Opening bitchat"
    log="$(mktemp -t bitchat-launch)"
    for ((attempt = 1; attempt <= MAX_LAUNCH_ATTEMPTS; attempt++)); do
        if xcrun devicectl device process launch --device "$id" "$bundle_id" >"$log" 2>&1; then
            rm -f "$log"
            ok "bitchat is open on your iPhone"
            return
        fi
        if grep -Eqi "locked" "$log"; then
            ask_enter "Unlock your iPhone"
        else
            explain_trust_certificate
            ask_enter "Once you've tapped Trust"
        fi
    done
    rm -f "$log"
    warn "Could not open bitchat automatically. Tap its icon on the Home Screen."
}

print_summary() {
    step "Done"
    say "bitchat is installed. When it first opens, allow Bluetooth (needed for the offline mesh)."
    say "Location is optional and only used for location-based channels."
    say ""
    say "With a free Apple Account the app stops opening after 7 days. To renew it, connect the"
    say "iPhone and run this script again; your chats and settings are kept."
}

parse_args() {
    TEAM_ARG="" DEVICE_ARG="" SOURCE_ARG=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --team) TEAM_ARG="${2:?--team needs a value}"; shift 2 ;;
            --device) DEVICE_ARG="${2:?--device needs a value}"; shift 2 ;;
            --source) SOURCE_ARG="${2:?--source needs a value}"; shift 2 ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; die "Unknown option: $1" ;;
        esac
    done
}

main() {
    parse_args "$@"
    check_macos
    ensure_xcode

    local source team config_status device_id udid app bundle_id build_log
    step "Getting the bitchat source"
    source="$(resolve_source_dir "$SOURCE_ARG")"
    ok "Using $source"

    step "Setting up app signing"
    team="$(choose_team "$TEAM_ARG")"
    warn_if_no_xcode_account
    config_status="$(write_local_config "$source" "$team")" || die "Could not write $source/Configs/Local.xcconfig"
    say "Signing config: $config_status (team $team)"

    device_id="$(select_device "$DEVICE_ARG")"
    ensure_paired "$device_id"
    ensure_developer_mode "$device_id"
    udid="$(field "$(wait_for_device "$device_id")" 2)"
    [[ -n $udid ]] || die "Could not read the iPhone's hardware ID. Unplug it, plug it back in, and run again."

    build_log="$(mktemp -t bitchat-build)"
    build_app "$source" "$udid" "$build_log"
    app="$source/$APP_RELATIVE_PATH"
    verify_profile_includes_device "$app" "$udid"
    install_app "$device_id" "$app"

    bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")"
    launch_app "$device_id" "$bundle_id"
    print_summary
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
