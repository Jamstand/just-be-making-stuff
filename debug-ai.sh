#!/usr/bin/env bash
# Diagnose whether /ai/detect is reachable. Run on the Pi.
# Usage: bash debug-ai.sh

set -u

PORT="${PORT:-3000}"
LOCAL="http://127.0.0.1:${PORT}"

# Construct tailnet URL programmatically so we never have to paste/type
# the full URL (and trip iOS's URL auto-bracketing on phone keyboards).
HOST="$(hostname)"
SUFFIX="$(tailscale status --json 2>/dev/null \
  | grep -o '"MagicDNSSuffix":"[^"]*"' \
  | sed 's/.*:"//; s/"$//')"

if [ -z "$SUFFIX" ]; then
  echo "Could not auto-detect MagicDNS suffix from tailscale status."
  echo "Set TAILNET manually, e.g. TAILNET=tail9b1d83.ts.net bash debug-ai.sh"
  TAILNET="${TAILNET:-}"
else
  TAILNET="${TAILNET:-$SUFFIX}"
fi

TS_URL=""
if [ -n "$TAILNET" ]; then
  TS_URL="https://${HOST}.${TAILNET}"
fi

PAYLOAD='{"transactions":[{"date":"2026-01-01","desc":"NETFLIX.COM","amount":-9.99}],"heuristicNames":[]}'

run() {
  local label="$1" url="$2"
  echo "── $label  ($url/ai/detect)"
  local out
  out=$(curl -sk -o /tmp/debug-ai.body \
    -w 'http=%{http_code} time_total=%{time_total}s size_download=%{size_download}\n' \
    -X POST -H 'Content-Type: application/json' \
    --data "$PAYLOAD" \
    "$url/ai/detect" 2>&1)
  echo "$out"
  echo "── body (first 200 bytes):"
  head -c 200 /tmp/debug-ai.body
  echo
  echo
}

echo "================================================================"
echo "  AI backend reachability check"
echo "  hostname=$HOST  tailnet=$TAILNET"
echo "================================================================"
echo

echo "(1) Local loopback — proves the Express handler itself works."
run "loopback" "$LOCAL"

if [ -n "$TS_URL" ]; then
  echo "(2) Tailnet HTTPS via tailscale serve — proves the proxy forwards POSTs."
  run "tailnet"  "$TS_URL"
else
  echo "(2) Skipped tailnet test (no MagicDNS suffix detected)."
fi

echo "── /ai/status (loopback):"
curl -sf "$LOCAL/ai/status"; echo
if [ -n "$TS_URL" ]; then
  echo "── /ai/status (tailnet):"
  curl -skf "$TS_URL/ai/status"; echo
fi

echo
echo "Now: in another terminal run \`journalctl -u subs -f\` and confirm"
echo "the requests above appear as log lines (POST /ai/detect -> ...)."
