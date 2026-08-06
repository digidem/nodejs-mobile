#!/bin/bash
# Turn a tools/test.py run log into a short, reviewable summary: the counts and
# the names that failed, as a GitHub job summary when there is one and on stdout
# either way.
#
# Pulls the totals and `=== release <name> ===` failure banners out of a shard
# log that's otherwise thousands of progress lines.
#
# Never fails: this reports on a run, it does not judge it. The caller decides
# whether a failure count is allowed to fail the build.
set -uo pipefail

LOG="${1:?usage: summarize-suite-run.sh <log> [label]}"
LABEL="${2:-suite run}"

if [ ! -r "$LOG" ]; then
  echo "::warning::summarize-suite-run: no log at $LOG (the run may have died before writing one)"
  exit 0
fi

# test.py writes progress with \r; split those so grep sees whole lines.
NORM="$(mktemp)"
SUMMARY="$(mktemp)"
trap 'rm -f "$NORM" "$SUMMARY"' EXIT
tr '\r' '\n' < "$LOG" > "$NORM"

# Last progress line carries the totals: [mm:ss|%NNN|+ pass|- fail]
LAST="$(grep -aE '^\[[0-9]+:[0-9]+\|' "$NORM" | tail -1)"
PASS="$(printf '%s' "$LAST" | sed -nE 's/.*\+[[:space:]]*([0-9]+).*/\1/p')"
FAIL="$(printf '%s' "$LAST" | sed -nE 's/.*-[[:space:]]*([0-9]+)\].*/\1/p')"
PASS="${PASS:-0}"; FAIL="${FAIL:-0}"

FAILED="$(grep -aoE '^=== release [a-z0-9._-]+ ===$' "$NORM" \
          | sed 's/^=== release //; s/ ===$//' | sort -u)"
NFAILED="$(printf '%s' "$FAILED" | grep -c . || true)"

# Android proxy distinguishes hang vs crash; the iOS proxy can't tell them
# apart, so its failures land in NOVERD instead of NHANG/NCRASH.
NHANG="$(grep -ac 'hung (no verdict' "$NORM" || true)"
NCRASH="$(grep -ac 'crashed (process gone' "$NORM" || true)"
NOVERD="$(grep -ac 'no verdict file after' "$NORM" || true)"

{
  echo "### Full device suite — ${LABEL}"
  echo
  echo "| passed | failed | no verdict: hung | no verdict: crashed | no verdict: other |"
  echo "|---:|---:|---:|---:|---:|"
  echo "| ${PASS} | ${FAIL} | ${NHANG} | ${NCRASH} | ${NOVERD} |"
  if [ "${NFAILED}" -gt 0 ]; then
    echo
    echo "<details><summary>${NFAILED} failing test(s)</summary>"
    echo
    printf '%s\n' "$FAILED" | sed 's/^/- `/; s/$/`/'
    echo
    echo '</details>'
  fi
} > "$SUMMARY"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$SUMMARY" >> "$GITHUB_STEP_SUMMARY"
else
  cat "$SUMMARY"
fi

echo "${LABEL}: ${PASS} passed, ${FAIL} failed (${NHANG} hung, ${NCRASH} crashed, ${NOVERD} no-verdict)"
[ "${NFAILED}" -gt 0 ] && printf '%s\n' "$FAILED" | sed 's/^/  FAIL /'
exit 0
