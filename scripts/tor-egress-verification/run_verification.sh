#!/usr/bin/env bash
# Orchestrates the Tor-egress proxy-honoring verification on macOS.
#
# For each (request-type x key-style) it runs two experiments:
#   A) proxy UP   — did a connection arrive at the SOCKS proxy? (log grows)
#   B) proxy DOWN — pointed at a dead port; does the request still SUCCEED?
#      If it succeeds with no proxy, egress went DIRECT (proxy ignored).
#      If it fails, the proxy setting is being enforced (fail-closed).
#
# Discriminator: PROXIED  = connection observed at proxy AND fails when proxy down
#                DIRECT   = no connection at proxy OR succeeds when proxy down
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=19999
DEADPORT=19998   # nothing listens here
LOG="$(mktemp -t sockslog)"
BIN="$(mktemp -t proxyprobe)"

echo "== building swift probe =="
swiftc -O "$DIR/proxy_probe.swift" -o "$BIN" || { echo "swiftc failed"; exit 1; }

echo "== starting SOCKS proxy on $PORT =="
: > "$LOG"
python3 "$DIR/socks5_probe_proxy.py" "$PORT" "$LOG" >/tmp/socksproxy.out 2>&1 &
PROXY_PID=$!
trap 'kill $PROXY_PID 2>/dev/null' EXIT
# wait for READY
for _ in $(seq 1 50); do
  grep -q READY /tmp/socksproxy.out 2>/dev/null && break
  sleep 0.1
done

run_case() {
  local mode="$1" key="$2"
  # Experiment A: proxy up, watch log
  local before after target
  before=$(wc -l < "$LOG" | tr -d ' ')
  local outA
  outA=$("$BIN" "$mode" "$key" "$PORT" 2>/dev/null | grep '^RESULT' || echo "RESULT $mode $key ERROR no-output")
  sleep 0.3
  after=$(wc -l < "$LOG" | tr -d ' ')
  local proxied="NO"
  if [ "$after" -gt "$before" ]; then proxied="YES"; fi
  local newlines
  newlines=$(tail -n +"$((before+1))" "$LOG" | tr '\t' ' ' | tr '\n' '|')

  # Experiment B: proxy down (dead port), same request
  local outB
  outB=$("$BIN" "$mode" "$key" "$DEADPORT" 2>/dev/null | grep '^RESULT' || echo "RESULT $mode $key ERROR no-output")

  echo "----------------------------------------"
  echo "CASE mode=$mode key=$key"
  echo "  A(proxy up):   $outA   | connection_at_proxy=$proxied  [$newlines]"
  echo "  B(proxy down): $outB"
  # verdict
  local a_ok b_ok
  a_ok=$(echo "$outA" | awk '{print $4}')
  b_ok=$(echo "$outB" | awk '{print $4}')
  local verdict="UNKNOWN"
  if [ "$proxied" = "YES" ] && [ "$b_ok" = "ERROR" ]; then verdict="PROXIED (enforced)"; fi
  if [ "$proxied" = "NO" ] && [ "$b_ok" = "OK" ]; then verdict="DIRECT (proxy ignored)"; fi
  if [ "$proxied" = "YES" ] && [ "$b_ok" = "OK" ]; then verdict="AMBIGUOUS (uses proxy if up, but egresses direct if down)"; fi
  if [ "$proxied" = "NO" ] && [ "$b_ok" = "ERROR" ]; then verdict="BLOCKED both (network/target issue?)"; fi
  echo "  VERDICT: $verdict"
}

for mode in http ws; do
  for key in cf raw; do
    run_case "$mode" "$key"
  done
done
echo "========================================"
echo "raw proxy log:"; cat "$LOG" | tr '\t' ' '
