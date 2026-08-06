#!/bin/bash
# Install the testnode app on a booted iOS simulator, run a one-line console.log
# via `node -e`, and assert it booted and exited cleanly. Boot smoke
# (docs/TESTING.md on the recipe branch).
#
# Usage: run-ios-smoke.sh <testnode.app> <simulator-udid>
#
# Retries only the simulator-flake signature: a '<none>' verdict means the
# launch never completed inside the poll window (a degraded CI runner). A
# 'FAIL' verdict means node ran and the test failed — that is a real
# regression and is never retried, so the retry can't mask a real bug.
set -uo pipefail

APP="$1"; UDID="$2"
BUNDLE_ID=nodejsmobile.test
MARKER=NODEJS_MOBILE_SMOKE_OK
MAX_ATTEMPTS="${SMOKE_MAX_ATTEMPTS:-3}"
# 180, not 60: a healthy CI attempt takes ~55s (cold first launch of the large
# NodeMobile dylib), and a degraded runner (multi-minute simulator boots)
# stretches that past 60 — every observed flake was `simctl launch` still
# alive at poll expiry with no output. A verdict ends the poll early, so
# green runs don't pay for the headroom.
POLL_SECONDS="${SMOKE_POLL_SECONDS:-180}"
# Single shell-quoted -e expression so simctl passes it as one argv (main.m
# forwards argv after the executable straight to node). Deliberately NO
# process.exit(0): nodejs-mobile's process.exit() routes through node::Exit ->
# libc exit(), which never returns from node_start, so NodeRunner's post-run
# PASS write is skipped and only the atexit FAIL fallback fires. Letting the
# event loop drain returns 0 from node_start -> a clean PASS verdict.
EXPR="console.log('${MARKER} ' + process.version + ' ' + process.platform + ' ' + process.arch);"

# Launch once; echo the app output to stderr (for log visibility) and print the
# verdict (PASS | FAIL | "") to stdout for the caller to capture.
run_once() {
  local log token docs result lp verdict="" i
  log="$(mktemp)"
  token="$(/usr/bin/uuidgen | tr 'A-F' 'a-f' | tr -d '-')"
  xcrun simctl install "$UDID" "$APP" >/dev/null 2>&1

  # Decide pass/fail from the durable verdict file NodeRunner writes
  # (Documents/result-<token>.txt), not from scraping `simctl --console`: that
  # stream races a fast-exiting process and intermittently drops the marker on
  # loaded CI runners.
  # Empty container (wedged CoreSimulator / failed install) would have us poll
  # /Documents forever; return no verdict so the caller reboots and retries.
  docs="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)"
  if [ -z "$docs" ]; then
    echo "::warning::could not resolve app container for ${BUNDLE_ID} on ${UDID}" >&2
    rm -f "$log"
    return 0
  fi
  result="$docs/Documents/result-${token}.txt"
  rm -f "$result"

  xcrun simctl launch --console --terminate-running-process "$UDID" "$BUNDLE_ID" \
    --run-token "$token" -e "$EXPR" >| "$log" 2>&1 &
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

  echo "----- app output -----" >&2
  cat "$log" >&2
  echo "----------------------" >&2
  rm -f "$result" "$log"
  printf '%s' "$verdict"
}

attempt=1
while :; do
  echo "iOS smoke attempt ${attempt}/${MAX_ATTEMPTS}..."
  verdict="$(run_once)"
  case "$verdict" in
    PASS)
      echo "iOS smoke: PASS (attempt ${attempt})"
      exit 0
      ;;
    FAIL)
      echo "::error::iOS smoke verdict was 'FAIL' (node ran, test failed) — real failure, not retrying"
      exit 1
      ;;
    *)
      echo "::warning::iOS smoke verdict was '<none>' on attempt ${attempt} (simulator-flake signature)"
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "::error::iOS smoke verdict was '<none>' after ${MAX_ATTEMPTS} attempts (expected PASS)"
        exit 1
      fi
      echo "Rebooting simulator ${UDID} before retry..."
      xcrun simctl shutdown "$UDID" 2>/dev/null || true
      xcrun simctl boot "$UDID" 2>/dev/null || true
      xcrun simctl bootstatus "$UDID" -b 2>/dev/null || true
      attempt=$((attempt + 1))
      ;;
  esac
done
