#!/bin/bash
# $TARGET is deliberately unquoted throughout: it expands to nothing, or to the
# two words `-s <id>` that adb wants.
# shellcheck disable=SC2086
set -e

# Use the environment variable to target a specific device
if [ "$DEVICE_ID" = "" ]; then
  TARGET=""
else
  TARGET="-s $DEVICE_ID"
fi

# Seconds to wait for a test to report a RESULT before treating it as failed,
# so a hung test can't block the whole run.
TIMEOUT="${NODE_ANDROID_PROXY_TIMEOUT:-120}"

# Kill the test app if it's running, clear the log so we only read this run, and
# drop any verdict files left by previous launches. The per-launch token already
# makes a stale file un-readable (different name), but clearing them keeps the
# sandbox from accumulating files across a 151-test run and removes any doubt.
# None of this is the verdict channel, so a transient adb hiccup here must not
# become a test FAIL via set -e: tolerate failure and let the verdict poll below
# be the only thing that decides.
#
# The force-stop and the cleanup share one round trip. Each adb invocation
# spawns a client and costs ~30 ms, which is pure overhead on every one of
# ~3,300 tests. `logcat -c` is a different adb subcommand, so it stays separate.
adb $TARGET shell "am force-stop nodejsmobile.test.testnode; run-as nodejsmobile.test.testnode sh -c 'rm -f files/result-*.txt'" 2>/dev/null || true
adb $TARGET logcat -c || true

TEST_PATH="$( cd "$( dirname "$0" )" && cd .. && cd .. && cd test && pwd )"

# Quoted: unquoted $* word-splits and glob-expands the test's own arguments
# (a `*` in a --test-name-pattern would be expanded against the cwd).
ARGS="$*"

# Per-launch token: the RESULT marker is tagged with it, so a marker emitted by
# an aborting test or a spawned grandchild can't be mis-attributed to a
# neighbouring test (the contiguous false-FAIL block seen on CI). [a-f0-9] only,
# so it's safe unquoted inside the am extra and in a grep/sed regex.
RUN_TOKEN="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 16)"
[ -n "$RUN_TOKEN" ] || RUN_TOKEN="${RANDOM}${RANDOM}$$"

# Start the test app, passing the test filename, the host dir to substitute, and
# the per-launch token (its own extra so it never enters the test's process.argv).
# -W makes `am start` block until the activity is idle, so the launch can't
# coalesce into the just-force-stopped process still tearing down (which would
# leave node un-started -> a spurious no-verdict timeout).
ADB_START_COMMAND='am start -W -n nodejsmobile.test.testnode/nodejsmobile.test.testnode.MainActivity -e "nodeargs" "'$ARGS'" -e "substitutedir" "'$TEST_PATH'" -e "runtoken" "'$RUN_TOKEN'" '
adb $TARGET shell "$ADB_START_COMMAND" > /dev/null \
  || echo "::warning::node-android-proxy: am start failed for: $ARGS" >&2

# Is the app process still up? Empty `pidof` output = gone. The app never exits
# on its own (MainActivity stays after the node thread returns), so "gone"
# means the process died: a native crash, an abort, or a system kill.
app_alive() {
  [ -n "$(adb $TARGET shell 'pidof nodejsmobile.test.testnode' 2>/dev/null | tr -d '\r\n' || true)" ]
}
# Calibrate once, now, while `am start -W` guarantees the process is up: if
# pidof can't see it here (missing on an older device, or a renamed process),
# the probe is unusable and the poll below must not read its empty output as a
# dead process — that would FAIL every test instantly. Fall back to the plain
# timeout poll instead.
liveness=1
app_alive || liveness=""

# The app writes the test's real exit code to a per-launch file in its sandbox
# (filesDir/result-<token>.txt). Read it via run-as — a durable, private channel
# immune to logcat's rate-limit / ring-buffer eviction / 4KB truncation that made
# a single scraped marker an unrecoverable false FAIL. PASS / FAIL / no-file
# (timeout) are now distinguishable.
RESULT_REL="files/result-${RUN_TOKEN}.txt"
RESULT=1
verdict=""
# Poll for the verdict, but watch the process too. A native crash (SIGSEGV /
# SIGKILL) never reaches the atexit fallback, so no verdict file is ever
# written and there is nothing left to wait for; without the liveness check a
# crash burns the full TIMEOUT and is then indistinguishable from a hang. The
# verdict direction is FAIL either way — this buys wall-clock and a triage
# signal, never a score.
#
# The verdict poll runs at 10 Hz: the median test finishes in ~100 ms, so a
# 1-second tick would dominate the per-test cost across a full-suite run. The
# liveness probe stays at ~1 Hz — it is a second adb round trip and only buys
# triage detail (crash vs hang).
POLL_HZ=10
waited=0
ticks=0
gone=""
while :; do
  verdict=$(adb $TARGET shell "run-as nodejsmobile.test.testnode cat ${RESULT_REL} 2>/dev/null" 2>/dev/null | tr -d '\r\n' || true)
  case "$verdict" in
    PASS) RESULT=0; break ;;
    FAIL) RESULT=1; break ;;
  esac
  # Re-read once after the process died — it may have written the verdict and
  # exited between the two probes — then stop.
  if [ -n "$gone" ]; then break; fi
  if [ -n "$liveness" ] && [ $((ticks % POLL_HZ)) -eq 0 ] && ! app_alive; then
    gone=1
    continue
  fi
  if [ "$waited" -ge "$TIMEOUT" ]; then break; fi
  sleep 0.1
  ticks=$((ticks + 1))
  waited=$((ticks / POLL_HZ))
done
case "$verdict" in
  PASS|FAIL) ;;
  *)
    if [ -n "$gone" ]; then
      echo "::warning::node-android-proxy: crashed (process gone after ${waited}s, no verdict) for: $ARGS" >&2
    else
      echo "::warning::node-android-proxy: hung (no verdict after full ${TIMEOUT}s) for: $ARGS" >&2
    fi
    ;;
esac

# Echo the raw stdout/stderr for test.py's .out comparison. The verdict no longer
# rides this stream, so there is nothing to strip.
adb $TARGET shell 'logcat -d -b main -v raw -s TestNode:E -s TestNode:I -s nodejs' \
  | sed '/^--------- beginning of/d'

exit $RESULT
