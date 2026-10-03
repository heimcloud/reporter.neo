#!/usr/bin/env bash
# neo-reporter-token: source precedence, 0400/0700 modes, overrides copy,
# placeholder/empty handling, never prints the token. Runs unprivileged.
set -euo pipefail
BIN="${TOKEN_BIN:-python3 $(dirname "$0")/../scripts/neo-reporter-token.py}"
T="$(mktemp -d)"
trap 'chmod -R u+rwX "$T"; rm -rf "$T"' EXIT
SECRET_A="tok-from-settings-0123456789"
SECRET_B="tok-from-file-9876543210"
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { $BIN --settings "$T/settings.toml" --dest-dir "$T/run/creds" "$@" > "$T/out" 2>&1; }

# 1. tokenFile only (source unreadable for others, like homeserver 0600)
printf '%s\nsecond line\n' "$SECRET_B" > "$T/src"; chmod 0600 "$T/src"
: > "$T/settings.toml"
mkdir -p "$T/run"; echo old > "$T/run/ingest.token"
run --source "$T/src"
[ "$(cat "$T/run/creds/token")" = "$SECRET_B" ] || fail "tokenFile not copied"
[ "$(stat -c %a "$T/run/creds/token")" = 400 ] || fail "token mode not 0400"
[ "$(stat -c %a "$T/run/creds")" = 700 ] || fail "creds dir mode not 0700"
[ "$(cat "$T/run/creds/overrides.json")" = "{}" ] || fail "overrides not {}"
[ ! -e "$T/run/ingest.token" ] || fail "v0.1.1 group-readable copy not removed"
grep -q "$SECRET_B" "$T/out" && fail "token printed"
echo "tokenFile copy ok"

# 2. settings token wins; overrides copied (relevant keys only)
cat > "$T/settings.toml" <<TOML
[services.reporter]
endpoint = "https://autofix.example.net/api/incidents"
token = "$SECRET_A"
TOML
printf '{"ingest_url":"https://other.example.net/api/incidents","repo_slug":"rid-x","ssh_key":"nope"}' > "$T/meta.json"; chmod 0600 "$T/meta.json"
run --source "$T/src" --overrides "$T/meta.json"
[ "$(cat "$T/run/creds/token")" = "$SECRET_A" ] || fail "settings token does not win"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d=={"ingest_url":"https://other.example.net/api/incidents","repo_slug":"rid-x"}, d' "$T/run/creds/overrides.json" || fail "overrides filter"
[ "$(stat -c %a "$T/run/creds/overrides.json")" = 400 ] || fail "overrides mode not 0400"
grep -q "$SECRET_A" "$T/out" && fail "token printed"
echo "settings token + overrides ok"

# 3. placeholder rewrite over an existing 0400 file
cat > "$T/settings.toml" <<TOML
[services.reporter]
token = "replace-from-private-repo"
TOML
run
[ "$(cat "$T/run/creds/token")" = "replace-from-private-repo" ] || fail "placeholder not written"
grep -q "placeholder" "$T/out" || fail "placeholder not flagged"
echo "rewrite ok"

# 4. nothing configured → empty credential (LoadCredential needs the file), exit 0
: > "$T/settings.toml"
run --source "$T/missing" --overrides "$T/missing.json"
[ -e "$T/run/creds/token" ] && [ ! -s "$T/run/creds/token" ] || fail "stale token kept"
grep -q "no token configured" "$T/out" || fail "no notice"
echo "empty ok"

# 5. broken settings.toml / overrides → tokenFile fallback, no content echoed
printf 'token = "%s\n[[[' "$SECRET_A" > "$T/settings.toml"
printf 'not json %s' "$SECRET_A" > "$T/meta.json"
run --source "$T/src" --overrides "$T/meta.json"
[ "$(cat "$T/run/creds/token")" = "$SECRET_B" ] || fail "no fallback on bad toml"
[ "$(cat "$T/run/creds/overrides.json")" = "{}" ] || fail "bad overrides not {}"
grep -q "$SECRET_A" "$T/out" && fail "settings content printed"
echo "bad input ok"
echo "ALL TOKEN TESTS PASSED"
