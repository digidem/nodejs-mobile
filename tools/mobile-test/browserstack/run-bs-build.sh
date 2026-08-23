#!/usr/bin/env bash
# Upload an app + test suite to BrowserStack App Automate, trigger a build on
# one or more real devices, and poll it to a verdict. Framework-agnostic
# driver for the real-device smoke — used with framework=espresso (Android) and
# framework=xcuitest (iOS).
#
# Usage:
#   run-bs-build.sh <framework> <app_file> <test_suite_file> <devices_csv> <project> <build_tag>
#
# Env: BROWSERSTACK_USER, BROWSERSTACK_PW (basic-auth credentials).
#
# API (https://www.browserstack.com/docs/app-automate/api-reference):
#   POST /app-automate/<fw>/v2/app         (multipart file=)  -> {app_url}
#   POST /app-automate/<fw>/v2/test-suite  (multipart file=)  -> {test_suite_url}
#   POST /app-automate/<fw>/v2/build       (JSON)             -> {build_id}
#   GET  /app-automate/<fw>/v2/builds/<id>                    -> {status, devices...}
set -euo pipefail

FW=$1; APP_FILE=$2; SUITE_FILE=$3; DEVICES_CSV=$4; PROJECT=$5; BUILD_TAG=$6

: "${BROWSERSTACK_USER:?BROWSERSTACK_USER is required}"
: "${BROWSERSTACK_PW:?BROWSERSTACK_PW is required}"
AUTH="${BROWSERSTACK_USER}:${BROWSERSTACK_PW}"
API="https://api-cloud.browserstack.com/app-automate/${FW}/v2"

req() { # method url [curl args...] -> body on stdout, fails on HTTP >= 400
  local method=$1 url=$2; shift 2
  local out http
  out=$(curl -sS --show-error -w '\n%{http_code}' -u "$AUTH" -X "$method" "$url" "$@")
  http=$(printf '%s' "$out" | tail -n1)
  printf '%s' "$out" | sed '$d'
  if [ "$http" -ge 400 ]; then
    echo "::error::BrowserStack $method $url failed (HTTP $http)" >&2
    return 1
  fi
}

echo "Uploading app: $APP_FILE ($(du -h "$APP_FILE" | cut -f1))"
APP_URL=$(req POST "$API/app" -F "file=@${APP_FILE}" | jq -r '.app_url // empty')
[ -n "$APP_URL" ] || { echo "::error::app upload returned no app_url"; exit 1; }
echo "  app_url: $APP_URL"

echo "Uploading test suite: $SUITE_FILE ($(du -h "$SUITE_FILE" | cut -f1))"
SUITE_URL=$(req POST "$API/test-suite" -F "file=@${SUITE_FILE}" | jq -r '.test_suite_url // .test_url // empty')
[ -n "$SUITE_URL" ] || { echo "::error::test-suite upload returned no test_suite_url"; exit 1; }
echo "  test_suite_url: $SUITE_URL"

DEVICES_JSON=$(printf '%s' "$DEVICES_CSV" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')
BODY=$(jq -n \
  --arg app "$APP_URL" --arg suite "$SUITE_URL" \
  --arg project "$PROJECT" --arg tag "$BUILD_TAG" \
  --argjson devices "$DEVICES_JSON" \
  '{app: $app, testSuite: $suite, devices: $devices, project: $project,
    buildTag: $tag, deviceLogs: true, networkLogs: false}')

echo "Triggering $FW build on: $DEVICES_CSV"
BUILD_ID=$(req POST "$API/build" -H 'Content-Type: application/json' -d "$BODY" | jq -r '.build_id // empty')
[ -n "$BUILD_ID" ] || { echo "::error::build trigger returned no build_id"; exit 1; }
echo "  build_id: $BUILD_ID"
echo "  dashboard: https://app-automate.browserstack.com/dashboard/v2/builds/$BUILD_ID"

# Poll to a terminal status. A device smoke is minutes; cap at ~30 min.
STATUS=""
for _ in $(seq 1 60); do
  sleep 30
  STATUS=$(req GET "$API/builds/$BUILD_ID" | jq -r '.status // empty') || continue
  echo "  status: $STATUS"
  case "$STATUS" in
    queued|running|'') ;;
    *) break ;;
  esac
done

echo "--- final build report ---"
REPORT=$(req GET "$API/builds/$BUILD_ID")
printf '%s\n' "$REPORT" | jq .

if [ "$STATUS" != "passed" ]; then
  # Pull per-testcase diagnostics so the failure reason lands in the CI log.
  # The session detail embeds authoritative per-testcase log URLs
  # (instrumentation_log / device_log / crash_logs) — follow those verbatim
  # rather than guessing endpoint shapes.
  for SID in $(printf '%s' "$REPORT" | jq -r '.devices[]?.sessions[]?.id // empty'); do
    echo "=== session $SID detail ==="
    DETAIL=$(req GET "$API/builds/$BUILD_ID/sessions/$SID") || continue
    printf '%s\n' "$DETAIL" | jq . || true
    printf '%s' "$DETAIL" | jq -r '
        (.testcases.data[]?.testcases[]?) // empty
        | .name as $n
        | (.instrumentation_log // empty), (.device_log // empty), (.crash_logs // empty)
      ' | while IFS= read -r url; do
      [ -n "$url" ] || continue
      echo "=== $url (tail) ==="
      curl -sS -u "$AUTH" "$url" | tail -n 250 || true
      echo
    done
  done
  echo "::error::BrowserStack $FW build finished with status '$STATUS' (want 'passed'). See the dashboard link above; deviceLogs are enabled."
  exit 1
fi
echo "PASS: BrowserStack $FW smoke passed on: $DEVICES_CSV"
