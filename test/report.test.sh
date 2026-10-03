#!/usr/bin/env bash
# Tests for scripts/neo-incident-report.sh against a local mock endpoint.
# Needs: bash, jq, curl, python3.  Run: bash test/report.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${REPORT_BIN:-$HERE/../scripts/neo-incident-report.sh}"
T="$(mktemp -d)"; trap 'kill $SRV $SRV2 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "ok - $1"; }
no() { FAIL=$((FAIL+1)); echo "not ok - $1"; }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
P1=$(port); P2=$(port)
python3 "$HERE/mock_server.py" "$P1" "$T/log1" 201 & SRV=$!
python3 "$HERE/mock_server.py" "$P2" "$T/log2" 500 & SRV2=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$P1/" -X POST -d '{}' && break; sleep 0.1; done
rm -f "$T/log1"

TOKEN="tok-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf '%s\n' "$TOKEN" > "$T/token"
cat > "$T/payload.json" <<JSON
{"report_hash":"h1","neo_version":"v1","unit":"neo-auto-update","logs_excerpt":"boom","severity":"error","target_hint":"activate"}
JSON
mkcfg() { # endpoint tokenFile reporterId overridesFile
  jq -n --arg e "$1" --arg t "$2" --arg r "$3" --arg o "$4" \
    '{endpoint: (if $e=="" then null else $e end), tokenFile: (if $t=="" then null else $t end),
      reporterId: (if $r=="" then null else $r end), overridesFile: (if $o=="" then null else $o end)}' > "$T/cfg.json"
}
run() { NEO_REPORTER_CONFIG="$T/cfg.json" bash "$SCRIPT" "$@"; }

# 1. happy path: POST, bearer header, reporter id, machine default
mkcfg "http://127.0.0.1:$P1/api/incidents" "$T/token" "rid-1" ""
out=$(run --file "$T/payload.json" 2>&1); rc=$?
check "posts and exits 0" '[ $rc -eq 0 ] && echo "$out" | grep -q "posted: HTTP 201 report_hash=h1"'
check "bearer from token file" '[ "$(jq -r .auth "$T/log1" | tail -1)" = "Bearer $TOKEN" ]'
check "path + content type" '[ "$(jq -r .path "$T/log1" | tail -1)" = "/api/incidents" ] && [ "$(jq -r .ctype "$T/log1" | tail -1)" = "application/json" ]'
check "reporter_id and legacy customer_repo_slug" '[ "$(jq -r .body.reporter_id "$T/log1" | tail -1)" = "rid-1" ] && [ "$(jq -r .body.customer_repo_slug "$T/log1" | tail -1)" = "rid-1" ]'
check "machine defaults to hostname" '[ "$(jq -r .body.machine "$T/log1" | tail -1)" != "null" ]'
check "token never printed" '! echo "$out" | grep -q "$TOKEN"'

# 2. stdin payload, explicit machine kept
out=$(jq '.machine="m-1"' "$T/payload.json" | run - 2>&1); rc=$?
check "stdin payload" '[ $rc -eq 0 ] && [ "$(jq -r .body.machine "$T/log1" | tail -1)" = "m-1" ]'

# 3. overrides file wins (ingest_url / ops_ingest_url, repo_slug)
echo "{\"ops_ingest_url\":\"http://127.0.0.1:$P1/override\",\"repo_slug\":\"rid-meta\"}" > "$T/meta.json"
mkcfg "http://127.0.0.1:9/never" "$T/token" "rid-1" "$T/meta.json"
out=$(run --file "$T/payload.json" 2>&1); rc=$?
check "overrides: legacy ops_ingest_url + repo_slug" '[ $rc -eq 0 ] && [ "$(jq -r .path "$T/log1" | tail -1)" = "/override" ] && [ "$(jq -r .body.reporter_id "$T/log1" | tail -1)" = "rid-meta" ]'
echo "{\"ingest_url\":\"http://127.0.0.1:$P1/new\",\"reporter_id\":\"rid-new\",\"repo_slug\":\"old\"}" > "$T/meta.json"
out=$(run --file "$T/payload.json" 2>&1); rc=$?
check "overrides: ingest_url + reporter_id preferred" '[ "$(jq -r .path "$T/log1" | tail -1)" = "/new" ] && [ "$(jq -r .body.reporter_id "$T/log1" | tail -1)" = "rid-new" ]'
echo "not json" > "$T/meta.json"
mkcfg "http://127.0.0.1:$P1/api/incidents" "$T/token" "" "$T/meta.json"
out=$(run --file "$T/payload.json" 2>&1); rc=$?
check "bad overrides ignored, reporter id defaults to unknown" '[ $rc -eq 0 ] && [ "$(jq -r .body.reporter_id "$T/log1" | tail -1)" = "unknown" ]'
mkcfg "http://127.0.0.1:$P1/api/incidents" "$T/token" "" "$T/absent.json"
out=$(run --file "$T/payload.json" 2>&1); rc=$?
check "missing overrides file is fine" '[ $rc -eq 0 ]'

# 4. token missing / empty / placeholder → exit 3, nothing posted
n=$(wc -l < "$T/log1")
mkcfg "http://127.0.0.1:$P1/api/incidents" "$T/nope" "" ""
run --file "$T/payload.json" >/dev/null 2>&1; rc=$?
check "missing token → 3" '[ $rc -eq 3 ]'
: > "$T/empty"; mkcfg "http://127.0.0.1:$P1/api/incidents" "$T/empty" "" ""
run --file "$T/payload.json" >/dev/null 2>&1; rc=$?
check "empty token → 3" '[ $rc -eq 3 ]'
echo "replace-from-private-repo" > "$T/ph"; mkcfg "http://127.0.0.1:$P1/api/incidents" "$T/ph" "" ""
out=$(run --file "$T/payload.json" 2>&1); rc=$?
check "placeholder token → 3" '[ $rc -eq 3 ] && echo "$out" | grep -q placeholder'
check "nothing posted without a token" '[ "$(wc -l < "$T/log1")" = "$n" ]'

# 5. validation
mkcfg "http://127.0.0.1:$P1/api/incidents" "$T/token" "" ""
jq 'del(.unit)' "$T/payload.json" > "$T/bad.json"
out=$(run --file "$T/bad.json" 2>&1); rc=$?
check "missing field → 2" '[ $rc -eq 2 ] && echo "$out" | grep -q "missing fields: unit"'
jq '.severity="bad"' "$T/payload.json" > "$T/bad.json"
run --file "$T/bad.json" >/dev/null 2>&1; rc=$?
check "bad severity → 2" '[ $rc -eq 2 ]'
echo '[1]' | run - >/dev/null 2>&1; rc=$?
check "non-object payload → 2" '[ $rc -eq 2 ]'
mkcfg "" "$T/token" "" ""
run --file "$T/payload.json" >/dev/null 2>&1; rc=$?
check "no endpoint → 2" '[ $rc -eq 2 ]'

# 6. HTTP error → 1
mkcfg "http://127.0.0.1:$P2/api/incidents" "$T/token" "" ""
out=$(run --file "$T/payload.json" 2>&1); rc=$?
check "HTTP 500 → 1" '[ $rc -eq 1 ] && echo "$out" | grep -q "HTTP 500"'
mkcfg "http://127.0.0.1:9/api/incidents" "$T/token" "" ""
run --file "$T/payload.json" >/dev/null 2>&1; rc=$?
check "connection refused → 1" '[ $rc -eq 1 ]'

# 7. dry run: no POST, no token
n=$(wc -l < "$T/log1")
mkcfg "http://127.0.0.1:$P1/api/incidents" "$T/token" "rid-1" ""
out=$(run --dry-run --file "$T/payload.json" 2>&1); rc=$?
check "dry-run shows endpoint/token state, no POST" '[ $rc -eq 0 ] && [ "$(echo "$out" | jq -r .token)" = present ] && [ "$(echo "$out" | jq -r .endpoint)" = "http://127.0.0.1:$P1/api/incidents" ] && [ "$(wc -l < "$T/log1")" = "$n" ] && ! echo "$out" | grep -q "$TOKEN"'

# 8. token not in argv (curl reads the header from a file)
check "script never puts the token on a command line" '! grep -nE "Bearer \\\$\\(cat|-H \"Authorization: Bearer \\\$" "$SCRIPT"'

echo "# pass $PASS fail $FAIL"
[ "$FAIL" -eq 0 ]
