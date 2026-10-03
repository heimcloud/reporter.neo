#!/usr/bin/env bash
# neo-reporter-token: source precedence, mode, removal, never prints the token.
# Runs unprivileged (no chown); the group is the caller's own.
set -euo pipefail
BIN="${TOKEN_BIN:-python3 $(dirname "$0")/../scripts/neo-reporter-token.py}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
G="$(id -gn)"
SECRET_A="tok-from-settings-0123456789"
SECRET_B="tok-from-file-9876543210"
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { $BIN --settings "$T/settings.toml" --dest "$T/run/ingest.token" --group "$G" "$@" > "$T/out" 2>&1; }

# 1. tokenFile only (source unreadable for others, like homeserver 0600)
printf '%s\nsecond line\n' "$SECRET_B" > "$T/src"; chmod 0600 "$T/src"
: > "$T/settings.toml"
run --source "$T/src"
[ "$(cat "$T/run/ingest.token")" = "$SECRET_B" ] || fail "tokenFile not copied"
[ "$(stat -c %a "$T/run/ingest.token")" = 440 ] || fail "mode not 0440"
[ "$(stat -c %a "$T/run")" = 750 ] || fail "dir mode not 0750"
grep -q "$SECRET_B" "$T/out" && fail "token printed"
echo "tokenFile copy ok"

# 2. settings token wins
cat > "$T/settings.toml" <<TOML
[services.reporter]
endpoint = "https://autofix.example.net/api/incidents"
token = "$SECRET_A"
TOML
run --source "$T/src"
[ "$(cat "$T/run/ingest.token")" = "$SECRET_A" ] || fail "settings token does not win"
grep -q "$SECRET_A" "$T/out" && fail "token printed"
echo "settings token ok"

# 3. replace an existing 0440 file (atomic rename in a writable dir)
cat > "$T/settings.toml" <<TOML
[services.reporter]
token = "replace-from-private-repo"
TOML
run
[ "$(cat "$T/run/ingest.token")" = "replace-from-private-repo" ] || fail "placeholder not written"
grep -q "placeholder" "$T/out" || fail "placeholder not flagged"
echo "rewrite ok"

# 4. nothing configured → file removed, exit 0
: > "$T/settings.toml"
run --source "$T/missing"
[ ! -e "$T/run/ingest.token" ] || fail "stale token kept"
grep -q "notify-only" "$T/out" || fail "no notice"
echo "removal ok"

# 5. broken settings.toml → falls back to tokenFile, no content echoed
printf 'token = "%s\n[[[' "$SECRET_A" > "$T/settings.toml"
run --source "$T/src"
[ "$(cat "$T/run/ingest.token")" = "$SECRET_B" ] || fail "no fallback on bad toml"
grep -q "$SECRET_A" "$T/out" && fail "settings content printed"
echo "bad toml ok"
echo "ALL TOKEN TESTS PASSED"
