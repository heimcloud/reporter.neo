# reporter.neo

A [Neo](https://github.com/madebydamo/neo) plugin that turns Neo's Hermes update
supervision into an **incident reporter**. When an automatic system or Docker
update (or an activation) breaks, Hermes classifies the outcome, notifies you
and POSTs an incident to an HTTP endpoint you choose, for example an
[autofix.neo](https://github.com/heimcloud/autofix.neo) desk.

It runs no containers and no daemons. It installs:

- a Hermes skill (default name `incident-reporter`) with the classification
  and reporting procedure;
- a small helper, `neo-incident-report`, that validates the payload, reads the
  Bearer token from a file and POSTs it (the token is never printed or put on a
  command line);
- optionally, a preload of that skill into Neo's
  `neo-hermes-supervise-{system,docker}-update` runs, so Hermes cannot skip it.

## Install

Settings → core → plugins → add:

```text
github:heimcloud/reporter.neo
```

Then configure `services.reporter` (web UI or `settings.toml`):

```toml
[services.reporter]
enabled = true
endpoint = "https://autofix.example.net/api/incidents"
tokenFile = "/var/neo/DATA/AppData/reporter/ingest.token"
# reporterId = "my-box"                 # optional, sent as reporter_id
# overridesFile = "/path/to/meta.json"  # optional runtime overrides
# supervise = true                      # preload into update supervision
# skillName = "incident-reporter"
```

Put the token (first line of the file) in place yourself, readable by the
`hermes` user, e.g. `install -m 0440 -o root -g hermes token.txt …`.
Supervision preloading needs `services.hermes.enabled` and
`services.hermes.superviseUpdates`.

## Options

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Turn the reporter on. |
| `endpoint` | `null` | Full ingest URL (POST). Required unless `overridesFile` provides one. |
| `tokenFile` | `null` | Bearer token file. Missing, empty or `replace-…` → notify only, no POST (exit 3). |
| `reporterId` | `null` | Optional id for this box, sent as `reporter_id` (and legacy `customer_repo_slug`). Defaults to `unknown`. |
| `overridesFile` | `null` | JSON read at report time: `ingest_url` / `ops_ingest_url` replace `endpoint`; `reporter_id` / `repo_slug` / `customer_repo_slug` replace `reporterId`. |
| `supervise` | `true` | Preload the skill in Neo's update supervision units. |
| `skillName` | `incident-reporter` | Skill name; change only to keep an existing name stable. |

## Payload

`neo-incident-report --file incident.json` (or `-` for stdin) sends:

```json
{
  "report_hash": "stable id for dedup",
  "neo_version": "…",
  "unit": "neo-auto-update",
  "logs_excerpt": "short, redacted tail",
  "severity": "error",
  "target_hint": "what broke / where to look",
  "machine": "defaults to hostname -s",
  "reporter_id": "from config / overrides",
  "customer_repo_slug": "same value (legacy field)"
}
```

`severity` is one of `info`, `warning`, `error`, `critical`. The endpoint must
accept `Authorization: Bearer <token>` and JSON. `--dry-run` prints the
resolved endpoint, reporter id, token state and body without sending.

Exit codes: `0` posted (2xx), `1` HTTP/transport error, `2` usage/config/payload
error, `3` token missing or placeholder.

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
nix flake check           # helper tests (mock endpoint) + NixOS eval tests
bash test/report.test.sh  # helper tests only (needs bash, jq, curl, python3)
```
