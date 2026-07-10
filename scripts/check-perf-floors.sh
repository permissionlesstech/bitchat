#!/usr/bin/env bash
#
# check-perf-floors.sh — order-of-magnitude performance regression gate.
#
# Parses the `PERF[name]: N unit/sec ...` lines that PerformanceBaselineTests
# prints into captured test output and fails if any benchmark's throughput is
# below its floor from bitchatTests/Performance/perf-floors.json.
#
# Floor philosophy (see the floors file): floors sit at ~25% of locally
# measured throughput, so they catch algorithmic regressions (O(n) -> O(n^2)),
# never runner variance. Raise floors deliberately after intentional
# improvements; never tune them to chase noise.
#
# Retry-on-noise: even generous floors can be dipped under by a saturated
# runner (observed: gcs.buildAndDecode at 85% of floor on a loaded GitHub
# macOS runner). When a benchmark lands below its floor, the gate re-runs the
# benchmark suite — appending to the same PERF log — and keeps each
# benchmark's BEST observed value across attempts. Runner noise clears on a
# retry; a real algorithmic regression stays below floor on every attempt and
# still fails. Floors themselves are never lowered by this mechanism.
#
# Usage: scripts/check-perf-floors.sh <test-output-file> [floors-file]
#
# Environment:
#   BITCHAT_PERF_GATE_ATTEMPTS   total measurement attempts (default 3)
#   BITCHAT_PERF_REMEASURE_CMD   command run to re-measure on a below-floor
#                                result (default: swift test --quiet
#                                --filter PerformanceBaselineTests). The
#                                command runs with BITCHAT_PERF_LOG pointed at
#                                the output file so new PERF lines append.
#
# Skips gracefully (exit 0) when:
#   - BITCHAT_SKIP_PERF_BASELINES=1 (perf tests were skipped), or
#   - the output contains no PERF lines (e.g. package-only matrix entries).
#
# Fails when:
#   - any benchmark reports throughput below its floor on every attempt
#     (exit 1), or
#   - PERF lines are present but a floored benchmark is missing — a
#     silently-dropped benchmark must be an explicit floors-file change and
#     is not retried (exit 3).

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <test-output-file> [floors-file]" >&2
    exit 2
fi

OUTPUT_FILE="$1"
FLOORS_FILE="${2:-$(cd "$(dirname "$0")/.." && pwd)/bitchatTests/Performance/perf-floors.json}"
MAX_ATTEMPTS="${BITCHAT_PERF_GATE_ATTEMPTS:-3}"
REMEASURE_CMD="${BITCHAT_PERF_REMEASURE_CMD:-swift test --quiet --filter PerformanceBaselineTests}"

if [[ "${BITCHAT_SKIP_PERF_BASELINES:-}" == "1" ]]; then
    echo "perf-floors: BITCHAT_SKIP_PERF_BASELINES=1 — skipping gate."
    exit 0
fi

if [[ ! -f "$OUTPUT_FILE" ]]; then
    echo "perf-floors: output file '$OUTPUT_FILE' not found — skipping gate." >&2
    exit 0
fi

if [[ ! -f "$FLOORS_FILE" ]]; then
    echo "perf-floors: floors file '$FLOORS_FILE' not found." >&2
    exit 2
fi

if ! grep -q 'PERF\[' "$OUTPUT_FILE"; then
    echo "perf-floors: no PERF lines in '$OUTPUT_FILE' — skipping gate."
    exit 0
fi

# Absolute path so re-measurement appends to the same file regardless of the
# working directory the test process runs in.
case "$OUTPUT_FILE" in
    /*) ;;
    *) OUTPUT_FILE="$(pwd)/$OUTPUT_FILE" ;;
esac

# Exit codes: 0 = all floors met, 1 = below floor (retryable — noise vs
# regression undecided), 3 = floored benchmark missing (not retryable).
check_floors() {
    OUTPUT_FILE="$OUTPUT_FILE" FLOORS_FILE="$FLOORS_FILE" python3 - <<'PYEOF'
import json
import os
import re
import sys

output_file = os.environ["OUTPUT_FILE"]
floors_file = os.environ["FLOORS_FILE"]

with open(floors_file) as f:
    floors = json.load(f)["floors"]

# PERF[delivery.storeUpdate]: 158862 updates/sec (avg 3.147 ms per pass of 500, 10 passes)
pattern = re.compile(r"PERF\[([^\]]+)\]:\s*([0-9]+(?:\.[0-9]+)?)\s*(\S+)/sec")

measured = {}
with open(output_file, errors="replace") as f:
    for line in f:
        m = pattern.search(line)
        if m:
            # Keep the BEST reported value: measurement retries append to the
            # same log, and a healthy benchmark only needs to clear its floor
            # once — a real regression never does.
            name, value, unit = m.group(1), float(m.group(2)), m.group(3)
            if name not in measured or value > measured[name][0]:
                measured[name] = (value, unit)

below_floor = []
missing = []
print(f"perf-floors: checking {len(measured)} benchmark(s) against {len(floors)} floor(s)")
for name in sorted(set(floors) | set(measured)):
    floor = floors.get(name)
    if name not in measured:
        missing.append(
            f"  MISSING  {name}: floored benchmark reported no PERF line "
            f"(removed/renamed? update perf-floors.json in the same change)")
        continue
    value, unit = measured[name]
    if floor is None:
        print(f"  NO-FLOOR {name}: {value:.0f} {unit}/sec (consider adding a floor)")
        continue
    status = "OK" if value >= floor else "BELOW"
    line = f"  {status:8} {name}: {value:.0f} {unit}/sec (floor {floor})"
    print(line)
    if value < floor:
        below_floor.append(
            f"  BELOW    {name}: {value:.0f} {unit}/sec is under floor {floor} "
            f"({value / floor * 100:.0f}% of floor)")

if missing:
    print("\nperf-floors: FAILED — floored benchmark(s) missing from the output:")
    print("\n".join(missing + below_floor))
    sys.exit(3)

if below_floor:
    print("\nperf-floors: below floor — order-of-magnitude-class regression suspected:")
    print("\n".join(below_floor))
    print("\nFloors are ~25% of healthy local throughput; falling below one means an")
    print("algorithmic regression, not runner noise. If the change is intentional,")
    print("update bitchatTests/Performance/perf-floors.json deliberately.")
    sys.exit(1)

print("perf-floors: all benchmarks at or above their floors.")
PYEOF
}

attempt=1
while true; do
    gate_status=0
    check_floors || gate_status=$?

    case "$gate_status" in
        0)
            exit 0
            ;;
        1)
            # Below floor: retry to separate runner noise from regression.
            ;;
        *)
            # Missing benchmark or parse/setup error: re-measuring can't help.
            exit "$gate_status"
            ;;
    esac

    if (( attempt >= MAX_ATTEMPTS )); then
        echo "perf-floors: still below floor after $attempt measurement attempt(s) — treating as a real regression." >&2
        exit 1
    fi

    attempt=$((attempt + 1))
    echo "perf-floors: re-measuring (attempt $attempt of $MAX_ATTEMPTS) to separate runner noise from a real regression."
    # Word splitting of REMEASURE_CMD is deliberate: it is a command line.
    if ! BITCHAT_PERF_LOG="$OUTPUT_FILE" $REMEASURE_CMD; then
        echo "perf-floors: re-measurement command failed: $REMEASURE_CMD" >&2
        exit 1
    fi
done
