#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tracked_justfiles="$(git ls-files | awk 'tolower($0) == "justfile"')"
tracked_justfile_count="$(printf '%s\n' "$tracked_justfiles" | awk 'NF { count++ } END { print count + 0 }')"
if [[ $tracked_justfile_count -ne 1 || $tracked_justfiles != "Justfile" ]]; then
    echo "Expected exactly one tracked canonical Justfile; found: ${tracked_justfiles:-none}" >&2
    exit 1
fi

if ! grep -Fxq 'clean:' Justfile; then
    echo "Clean recipe must not depend on another recipe" >&2
    exit 1
fi

clean_recipe="$({
    awk '
        /^clean:/ { in_clean = 1; next }
        in_clean && /^[^[:space:]]/ { exit }
        in_clean { print }
    ' Justfile
})"

if [[ -z ${clean_recipe//[[:space:]]/} ]]; then
    echo "Justfile clean recipe is missing or empty" >&2
    exit 1
fi

if ! grep -Fxq 'derived_data := ".DerivedData"' Justfile; then
    echo "Derived data path must remain the ignored repo-local .DerivedData directory" >&2
    exit 1
fi

clean_forbidden='git[[:space:]]+(checkout|restore|reset|clean)|(^|[[:space:]])(cp|mv)([[:space:]]|$)|bitchat\.xcodeproj|project\.pbxproj|Info\.plist|LaunchScreen|project\.yml|Configs/'
if grep -Eiq "$clean_forbidden" <<<"$clean_recipe"; then
    echo "Unsafe source/configuration mutation found in the clean recipe:" >&2
    grep -Ein "$clean_forbidden" <<<"$clean_recipe" >&2
    exit 1
fi

if ! grep -Fq 'rm -rf -- "{{derived_data}}" ".build"' <<<"$clean_recipe"; then
    echo "Clean recipe must remain limited to the declared repo-local artifact paths" >&2
    exit 1
fi

clean_rm_count="$(grep -Ec '^[[:space:]]*@?rm[[:space:]]+-rf([[:space:]]|$)' <<<"$clean_recipe" || true)"
if [[ $clean_rm_count -ne 1 ]]; then
    echo "Clean recipe must contain exactly one recursive removal command" >&2
    exit 1
fi

expected_clean_recipe='    @echo "Cleaning repo-local build artifacts..."
    @rm -rf -- "{{derived_data}}" ".build"
    @echo "✅ Cleaned {{derived_data}} and .build; tracked files were untouched"'
if [[ $clean_recipe != "$expected_clean_recipe" ]]; then
    echo "Clean recipe contains commands outside the reviewed artifact-only implementation" >&2
    exit 1
fi

file_forbidden='git[[:space:]]+(checkout|restore|reset|clean)|rm[[:space:]]+-rf[^#]*(bitchat\.xcodeproj|bitchat/|Configs/)|LaunchScreen\.storyboard\.ios|project\.pbxproj\.backup|Info\.plist\.backup'
if grep -Ein "$file_forbidden" Justfile; then
    echo "Unsafe tracked-file recovery/deletion logic found in Justfile" >&2
    exit 1
fi

echo "Justfile clean safety check passed"
