#!/bin/bash
# Native-addon gate (iOS simulator): stage the prebuilt crc-native .node + the
# test into the installed testnode app's Documents, run the test, and decide
# PASS/FAIL from the per-launch verdict file (same channel the smoke uses).
# NodeRunner.mm sets NODE_MOBILE_ADDON to <Documents>/crcnative.node, which the
# test dlopens. Proves the shipped libnode loads + runs a real N-API addon.
#
# Retries only the simulator-flake signature (a '<none>' verdict = the app
# launched but wrote nothing); a 'FAIL' verdict (the addon ran and an assertion
# failed) is a real failure and is never retried. Mirrors run-ios-smoke.sh.
#
# Usage: run-ios-addon.sh <testnode.app> <simulator-udid> <crcnative.node>
set -uo pipefail

APP="$1"; UDID="$2"; ADDON="$3"
BUNDLE_ID=nodejsmobile.test
HERE="$(cd "$(dirname "$0")/crc-native" && pwd)"
MAX_ATTEMPTS="${ADDON_MAX_ATTEMPTS:-3}"
POLL_SECONDS="${ADDON_POLL_SECONDS:-60}"

xcrun simctl install "$UDID" "$APP"
DOCS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Documents"
mkdir -p "$DOCS"
cp "$ADDON" "$DOCS/crcnative.node"
cp "$HERE/test-napi-addon.js" "$DOCS/test-napi-addon.js"

# Launch once; echo app output to stderr, print the verdict (PASS|FAIL|"") to stdout.
run_once() {
  local token result lp verdict="" i log
  log="$(mktemp)"
  token="$(/usr/bin/uuidgen | tr 'A-F' 'a-f' | tr -d '-')"
  result="$DOCS/result-${token}.txt"
  rm -f "$result"
  # On-device script path passed as a plain arg (no --substitute-dir, no ./test/
  # substring, so main.m's rewriter leaves it untouched).
  xcrun simctl launch --console --terminate-running-process "$UDID" "$BUNDLE_ID" \
    --run-token "$token" "$DOCS/test-napi-addon.js" >| "$log" 2>&1 &
  lp=$!
  for ((i=0; i<POLL_SECONDS; i++)); do
    if [ -f "$result" ]; then
      verdict=$(tr -d '\r\n' < "$result")
      [ -n "$verdict" ] && break
    fi
    kill -0 "$lp" 2>/dev/null || { [ -f "$result" ] && verdict=$(tr -d '\r\n' < "$result"); break; }
    sleep 1
  done
  kill "$lp" 2>/dev/null || true
  wait "$lp" 2>/dev/null || true
  echo "----- app output -----" >&2; cat "$log" >&2; echo "----------------------" >&2
  rm -f "$result" "$log"
  printf '%s' "$verdict"
}

attempt=1
while :; do
  echo "iOS NAPI-addon attempt ${attempt}/${MAX_ATTEMPTS}..."
  verdict="$(run_once)"
  case "$verdict" in
    PASS)
      echo "iOS NAPI-addon: PASS (attempt ${attempt})"
      exit 0
      ;;
    FAIL)
      echo "::error::iOS NAPI-addon verdict 'FAIL' (addon ran, assertion failed) — not retrying"
      exit 1
      ;;
    *)
      echo "::warning::iOS NAPI-addon verdict '<none>' on attempt ${attempt} (simulator-flake signature)"
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "::error::iOS NAPI-addon verdict '<none>' after ${MAX_ATTEMPTS} attempts (expected PASS)"
        exit 1
      fi
      xcrun simctl shutdown "$UDID" 2>/dev/null || true
      xcrun simctl boot "$UDID" 2>/dev/null || true
      xcrun simctl bootstatus "$UDID" -b 2>/dev/null || true
      attempt=$((attempt + 1))
      ;;
  esac
done
