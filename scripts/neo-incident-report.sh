#!/usr/bin/env bash
# neo-incident-report: POST one incident to the configured endpoint.
#
#   neo-incident-report [--dry-run] [--config FILE] [--file PAYLOAD.json | -]
#
# Payload (JSON object): report_hash, neo_version, unit, logs_excerpt,
# severity (info|warning|error|critical), target_hint; machine optional.
# reporter_id / customer_repo_slug are added from config (+ overridesFile).
#
# Config (JSON, default /etc/neo-reporter/config.json, or NEO_REPORTER_CONFIG):
#   { "endpoint": "...", "tokenFile": "...", "reporterId": "...", "overridesFile": "..." }
#
# The token is never printed and never passed on the command line (curl reads
# the Authorization header from a 0600 temp file).
#
# Exit codes: 0 posted (2xx) or dry-run ok; 1 HTTP/transport error;
# 2 usage/config/payload error; 3 token missing or placeholder (not posted).
set -euo pipefail

CONFIG="${NEO_REPORTER_CONFIG:-/etc/neo-reporter/config.json}"
DRY_RUN=0
PAYLOAD_FILE=""

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --config) shift; CONFIG="${1:?}" ;;
    --file) shift; PAYLOAD_FILE="${1:?}" ;;
    -h|--help) usage ;;
    -) PAYLOAD_FILE="-" ;;
    *) echo "neo-incident-report: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -r "$CONFIG" ] || { echo "neo-incident-report: config not readable: $CONFIG" >&2; exit 2; }
cfg() { jq -r --arg k "$1" '.[$k] // empty' "$CONFIG"; }

ENDPOINT="$(cfg endpoint)"
TOKEN_FILE="$(cfg tokenFile)"
REPORTER_ID="$(cfg reporterId)"
OVERRIDES="$(cfg overridesFile)"

if [ -n "$OVERRIDES" ] && [ -r "$OVERRIDES" ]; then
  if jq -e 'type == "object"' "$OVERRIDES" >/dev/null 2>&1; then
    u="$(jq -r '.ingest_url // .ops_ingest_url // empty' "$OVERRIDES")"
    [ -n "$u" ] && ENDPOINT="$u"
    r="$(jq -r '.reporter_id // .repo_slug // .customer_repo_slug // empty' "$OVERRIDES")"
    [ -n "$r" ] && REPORTER_ID="$r"
  else
    echo "neo-incident-report: overrides file is not a JSON object, ignored" >&2
  fi
fi
[ -n "$REPORTER_ID" ] || REPORTER_ID="unknown"

if [ -z "$PAYLOAD_FILE" ] || [ "$PAYLOAD_FILE" = "-" ]; then
  RAW="$(cat)"
else
  [ -r "$PAYLOAD_FILE" ] || { echo "neo-incident-report: payload not readable: $PAYLOAD_FILE" >&2; exit 2; }
  RAW="$(cat "$PAYLOAD_FILE")"
fi

MACHINE_DEFAULT="$(hostname -s 2>/dev/null || true)"
BODY="$(printf '%s' "$RAW" | jq -c \
  --arg rid "$REPORTER_ID" --arg machine "$MACHINE_DEFAULT" '
  if type != "object" then error("payload must be a JSON object") else . end
  | . as $p
  | ["report_hash","neo_version","unit","logs_excerpt","severity","target_hint"]
  | map(select(($p[.] // "") | tostring | length == 0)) as $missing
  | if ($missing | length) > 0 then error("missing fields: " + ($missing | join(", "))) else $p end
  | if (.severity | IN("info","warning","error","critical")) then . else error("severity must be info|warning|error|critical") end
  | .reporter_id = $rid
  | .customer_repo_slug = $rid
  | .machine = (if (.machine // "") != "" then .machine elif $machine != "" then $machine else null end)
  ' 2>&1)" || { echo "neo-incident-report: invalid payload: ${BODY#jq: error (at <stdin>:*): }" >&2; exit 2; }

TOKEN_STATE="missing"
if [ -n "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
  first="$(head -n1 "$TOKEN_FILE" | tr -d '\r')"
  case "$first" in
    "") TOKEN_STATE="missing" ;;
    replace-*) TOKEN_STATE="placeholder" ;;
    *) TOKEN_STATE="present" ;;
  esac
fi

if [ "$DRY_RUN" = 1 ]; then
  jq -n --arg endpoint "$ENDPOINT" --arg rid "$REPORTER_ID" --arg token "$TOKEN_STATE" --argjson body "$BODY" \
    '{dry_run: true, endpoint: (if $endpoint == "" then null else $endpoint end), reporter_id: $rid, token: $token, body: $body}'
  [ -n "$ENDPOINT" ] || exit 2
  exit 0
fi

[ -n "$ENDPOINT" ] || { echo "neo-incident-report: no endpoint configured" >&2; exit 2; }
if [ "$TOKEN_STATE" != "present" ]; then
  echo "neo-incident-report: ingest token $TOKEN_STATE; not posting (report locally only)" >&2
  exit 3
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"
( umask 077; printf 'Authorization: Bearer %s\n' "$first" > "$TMP/h" )
printf '%s' "$BODY" > "$TMP/body.json"

set +e
CODE="$(curl -sS -o "$TMP/resp" -w '%{http_code}' --max-time "${NEO_REPORTER_TIMEOUT:-30}" \
  -X POST "$ENDPOINT" -H 'Content-Type: application/json' -H @"$TMP/h" \
  --data-binary @"$TMP/body.json")"
RC=$?
set -e
HASH="$(printf '%s' "$BODY" | jq -r '.report_hash')"
if [ $RC -ne 0 ]; then
  echo "neo-incident-report: transport error (curl exit $RC) report_hash=$HASH" >&2
  exit 1
fi
case "$CODE" in
  2??) echo "posted: HTTP $CODE report_hash=$HASH"; exit 0 ;;
  *) echo "neo-incident-report: HTTP $CODE report_hash=$HASH" >&2; head -c 300 "$TMP/resp" >&2 || true; echo >&2; exit 1 ;;
esac
