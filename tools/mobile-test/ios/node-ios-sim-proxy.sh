#!/bin/bash
# Per-test proxy for the iOS *simulator*, used via `test.py --shell`. Launches the
# installed testnode app with simctl, reads the test's real exit code from a
# verdict file the app writes to its Documents dir (durable; not scraped from the
# lossy `simctl --console` stream), echoes node's stdout/stderr for test.py to
# compare, and maps PASS->0 / FAIL or no-verdict->1.
#
# The physical-device proxy is node-ios-proxy.sh (devicectl), which reads the
# same verdict file; `simctl launch` does not return the app's exit code, hence
# the file.
set -uo pipefail

: "${DEVICE_ID:?set DEVICE_ID to the target simulator UDID}"
UDID="$DEVICE_ID"
BUNDLE=nodejsmobile.test
TIMEOUT="${NODE_IOS_PROXY_TIMEOUT:-120}"
# `simctl launch --console` occasionally fails to establish its stdout FIFO on a
# rapid relaunch ("Unable to establish FIFO ... Error 17" / NSPOSIXErrorDomain),
# which launches nothing -> no verdict -> a spurious FAIL. Retry the launch a few
# times; a real PASS/FAIL verdict ends the loop immediately, so only infra
# failures pay the retry.
LAUNCH_ATTEMPTS="${NODE_IOS_PROXY_LAUNCH_ATTEMPTS:-3}"

SCRIPT_DIR="$( cd "$( dirname "$0" )" && pwd )"
TEST_BASE="$( cd "$SCRIPT_DIR/../../.." && cd test && pwd )"
# Resolve the app's data container. Under `set -uo pipefail` (no -e) a command
# substitution that exits 0 with empty stdout would silently yield DOCS=/Documents
# and an unwritable verdict path; assert non-empty so a degraded simctl fails
# loudly instead of turning every test into a no-verdict FAIL.
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null || true)"
[ -n "$CONTAINER" ] || { echo "::error::node-ios-sim-proxy: could not resolve app container for $BUNDLE on $UDID" >&2; exit 1; }
DOCS="$CONTAINER/Documents"
LOG="$(mktemp)"

RESULT=1
verdict=""
for attempt in $(seq 1 "$LAUNCH_ATTEMPTS"); do
  # Per-launch token names the verdict file (Documents/result-<token>.txt) so a
  # stale file or a spawned child (never gets --run-token) can't be confused for
  # this launch. Lowercased uuid -> [0-9a-f], uniform with the Android token.
  # Fresh per attempt: a prior attempt's app instance (launch mis-classified as
  # failed, torn down by --terminate-running-process) may still write a FAIL
  # verdict for ITS token as it dies; reusing one token would let that stale
  # write race this attempt's poll.
  RUN_TOKEN="$(/usr/bin/uuidgen | tr 'A-F' 'a-f' | tr -d '-')"
  RESULT_FILE="$DOCS/result-${RUN_TOKEN}.txt"
  STDOUT_FILE="$DOCS/stdout-${RUN_TOKEN}.txt"
  rm -f "$RESULT_FILE" "$STDOUT_FILE"
  : >| "$LOG"
  # main.m consumes --run-token into the env (NodeRunner builds the verdict path)
  # and applies --substitute-dir to rewrite host test paths to the Documents copy.
  #
  # No --console: the app redirects its own stdout/stderr into the sandbox (see
  # NodeRunner.mm) and we read that file below. --console pipes the output over a
  # FIFO that simctl intermittently fails to establish on a rapid relaunch, which
  # is what the retry loop below exists for; without it the launch just returns.
  # Synchronous, not backgrounded: without --console this returns as soon as the
  # app is launched rather than when it exits, and it prints "<bundle>: <pid>".
  # A simulator app is an ordinary macOS process, so that pid is one this shell
  # can signal — which is what replaces the old "did simctl exit yet" liveness
  # check. Watching the launcher instead would end the poll immediately here.
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" \
    --run-token "$RUN_TOKEN" --substitute-dir "$TEST_BASE" "$@" >| "$LOG" 2>&1
  APP_PID="$(sed -nE 's/^.*: ([0-9]+)$/\1/p' "$LOG" | tail -1)"

  # Poll at 10 Hz: the verdict file is on this filesystem, so a probe is a
  # cheap stat, and the median test is far shorter than a 1-second tick.
  # TIMEOUT stays in seconds.
  verdict=""
  gone=""
  for _ in $(seq 1 $((TIMEOUT * 10))); do
    if [ -f "$RESULT_FILE" ]; then
      verdict=$(tr -d '\r\n' < "$RESULT_FILE")
      [ -n "$verdict" ] && break
    fi
    # Re-read once after the process died: it may have written the verdict and
    # exited between the two probes. Without a pid, fall back to the timeout.
    if [ -n "$gone" ]; then break; fi
    if [ -n "$APP_PID" ] && ! kill -0 "$APP_PID" 2>/dev/null; then gone=1; continue; fi
    sleep 0.1
  done

  # A real PASS/FAIL verdict is authoritative -> stop (never retry a genuine
  # FAIL). Retry only when there is no verdict AND simctl reported a launch
  # failure (the --console FIFO race); a no-verdict with no launch error is a
  # genuine hang -> let it stand as FAIL rather than burn retries.
  case "$verdict" in PASS|FAIL) break ;; esac
  if grep -qiE "error was encountered|NSPOSIXErrorDomain|Could not (launch|find)" "$LOG"; then
    echo "::warning::node-ios-sim-proxy: simctl launch failed (attempt ${attempt}/${LAUNCH_ATTEMPTS}), retrying: $*" >&2
    sleep 2
    continue
  fi
  break
done
case "$verdict" in
  PASS) RESULT=0 ;;
  FAIL) RESULT=1 ;;
  *) RESULT=1; echo "::warning::node-ios-sim-proxy: no verdict file after ${LAUNCH_ATTEMPTS} attempt(s) (timeout/crash/launch-failure) for: $*" >&2 ;;
esac

# Echo node's output for test.py's .out comparison. It comes from the app's own
# redirect, so it is complete rather than best-effort: nothing here depends on
# simctl having managed to hold a pipe open for the life of the process.
[ -f "$STDOUT_FILE" ] && cat "$STDOUT_FILE"
rm -f "$LOG" "$RESULT_FILE" "$STDOUT_FILE"
exit "$RESULT"
