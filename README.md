# reporter.neo

A [Neo](https://github.com/madebydamo/neo) plugin that turns Neo's Hermes update
supervision into an **incident reporter**. When an automatic system or Docker
update (or an activation) breaks, Hermes classifies the outcome, notifies you
and POSTs an incident to an HTTP endpoint you choose, for example an
[autofix.neo](https://github.com/heimcloud/autofix.neo) desk.

It runs no containers and no long-running daemons. It installs:

- `send-report`, a small CLI that **any local user** can call to file an
  incident (`send-report "text…"` or via stdin). It holds no secret;
- a socket-activated, sandboxed service (`neo-reporter-submit`) that owns the
  ingest token, checks and rate-limits each report and POSTs it;
- a Hermes skill (default name `incident-reporter`) with the classification
  and reporting procedure;
- optionally, a preload of that skill into Neo's
  `neo-hermes-supervise-{system,docker}-update` runs, so Hermes cannot skip it.

## Install

Settings → core → plugins → add:

```text
github:heimcloud/reporter.neo
```

Then configure `services.reporter` in `settings.toml`:

```toml
[services.reporter]
enabled = true
endpoint = "https://autofix.example.net/api/incidents"
token = "…"                             # or: tokenFile = "/path/to/file"
# reporterId = "my-box"                 # optional, sent as reporter_id
# overridesFile = "/path/to/meta.json"  # optional runtime overrides
# supervise = true                      # preload into update supervision
# skillName = "incident-reporter"
```

## How it works

```text
any local user ── send-report ──▶ /run/neo-reporter/submit.sock (0666)
     ──▶ neo-reporter-submit@.service  (one per connection; DynamicUser, sandboxed)
     ──Authorization: Bearer <token>──▶ endpoint
```

- **Token.** A root oneshot (`neo-reporter-token`; it runs on every activation,
  before the socket starts and, for `tokenFile`, whenever that file changes)
  stages the token at `/run/neo-reporter/creds/token`, mode `0400 root`, in a
  `0700 root` directory. Only `neo-reporter-submit@.service` gets it, through
  `LoadCredential=`. No user, `hermes` included, can read it, and
  `send-report` never sees it. `token` is read from `/etc/neo/settings.toml`
  at run time, so it is never part of a Nix derivation or unit. `tokenFile` may
  have any owner and mode (e.g. a homeserver-only `0600` file). `token` wins
  when both are set. Neo keeps `settings.toml` on the host
  (`/etc/neo/settings.toml`), so use `tokenFile` if the token must not be in
  that file.
- **Caller.** The service identifies the caller with `SO_PEERCRED`. It records
  them as `submitted_by` (`root`, `hermes` or `uid-<n>`, never a personal user
  name), together with the machine name and `reporter_id`.
- **Limits.** One request per connection, at most 64 KiB, read within 10 s.
  The HTTP POST has a 20 s timeout and the instance 60 s overall. Each uid
  gets a token bucket of 5 reports, plus one more every 2 minutes. The socket
  allows 16 connections (4 per uid) and has no trigger limit, so a flood
  cannot put it into a failed state.
- **Sandbox.** `DynamicUser`, `ProtectSystem=strict`, `ProtectHome`,
  `PrivateTmp`, `PrivateDevices`, `NoNewPrivileges`, an empty capability set,
  `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`,
  `SystemCallFilter=@system-service`, `MemoryDenyWriteExecute`, and the
  `Protect*` kernel options.

`send-report` is on the system PATH, the PATH of the update supervision units
and the Hermes gateway PATH. `neo-incident-report` remains for one release as a
deprecated alias for `send-report --json --file …`.

Supervision preloading needs `services.hermes.enabled` and
`services.hermes.superviseUpdates`.

## Options

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Turn the reporter on. |
| `endpoint` | `null` | Full ingest URL (POST). Required unless `overridesFile` provides one. |
| `token` | `null` | Bearer token (settings.toml). Staged as a root-only credential for the socket service. Missing, empty or `replace-…` → no POST (`send-report` exits 3). |
| `tokenFile` | `null` | Alternative: file with the token on its first line, any owner (root copies it). Keeps the token out of `/etc/neo/settings.toml`. |
| `reporterId` | `null` | Optional id for this box, sent as `reporter_id` (and legacy `customer_repo_slug`). Defaults to `unknown`. |
| `overridesFile` | `null` | JSON (any owner; root copies the relevant keys at activation): `ingest_url` / `ops_ingest_url` replace `endpoint`; `reporter_id` / `repo_slug` / `customer_repo_slug` replace `reporterId`. |
| `supervise` | `true` | Preload the skill in Neo's update supervision units. |
| `skillName` | `incident-reporter` | Skill name; change only to keep an existing name stable. |

## send-report

```bash
send-report "backup job failed twice"                 # text as arguments
journalctl -u foo -n 80 | send-report --unit foo.service --severity critical \
  --title "foo crash-loops" --kind manual             # stdin + flags
send-report --json --file incident.json               # full incident object
echo test | send-report --dry-run                     # show body + token state, no POST
```

Prints `incident #<id> filed (status open)`, or `… already on the board` for a
repeat. A report's `report_hash` defaults to a hash of machine, unit, title and
text, so identical reports are deduplicated by the endpoint.

The service sends:

```json
{
  "report_hash": "sr-… (or yours)",
  "neo_version": "running generation (or yours)",
  "unit": "--unit, default send-report",
  "logs_excerpt": "[send-report kind=… submitted_by=… machine=…]\n<text>",
  "severity": "--severity, default error",
  "target_hint": "--title, default the first line",
  "kind": "--kind, default manual",
  "machine": "short hostname",
  "submitted_by": "root | hermes | uid-<n>",
  "reporter_id": "from config / overrides",
  "customer_repo_slug": "same value (legacy field)"
}
```

`severity` is one of `info`, `warning`, `error`, `critical`. The endpoint must
accept `Authorization: Bearer <token>` and JSON. If it answers with
`{created, incident: {id, status}}` (as autofix.neo does), the id and status
are shown.

Exit codes: `0` filed or duplicate (or dry run), `1` endpoint/transport error,
`2` usage, invalid or too large, `3` not configured (no endpoint, token missing
or placeholder, socket not running), `4` rate limited.

## Use from another plugin

A plugin can import this one and set defaults, so its users do not have to add
a second plugin URL:

```nix
imports = [inputs.reporter.nixosModules.default];
neo.services.reporter = {
  enabled = lib.mkDefault true;
  endpoint = lib.mkDefault "https://autofix.example.net/api/incidents";
  tokenFile = lib.mkDefault "/path/to/token";
};
```

The module has `key = "reporter.neo"`, so importing it twice (directly and via
another plugin) is deduplicated.

## Development

```bash
nix flake check                                   # unit/e2e tests + NixOS eval tests
python3 -m unittest discover -s test -p 'test_*.py'  # sender/service tests only
bash test/token.test.sh                           # token staging tests
nix build .#vm-test -L                            # NixOS VM test (needs KVM)
```
