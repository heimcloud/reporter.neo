# Hermes skill: classify Neo update/activate failures and report broken ones.
# skill.conf + skill.enabled → Neo getSkillServices → Hermes skills tree.
#
# Frontmatter hardening (Hermes parse_frontmatter): keep the description
# colon-free and drop `platforms` so a YAML slip cannot fail the skill closed.
{...}: {
  flake.modules.nixos.reporter-skill = {
    config,
    lib,
    ...
  }: let
    cfg = config.neo.services.reporter;
    domain = config.neo.services.swag.domain or null;
    endpointText =
      if cfg.endpoint != null
      then "`${cfg.endpoint}`"
      else "(none in Nix; taken from the overrides file)";
  in {
    config.neo.services.reporter.skill.conf = lib.mkIf cfg.enabled (let
      skill = lib.neo.mkServiceSkill {
        service = "reporter";
        inherit cfg domain;
        name = cfg.skillName;
        description = "Classify Neo update failures and report broken ones to the incident endpoint";
        tags = ["neo" "incidents" "reporter" "updates"];
        title = "Incident reporter";
        includeCredentialsFooter = false;
        body = ''
          ## When to Use
          This skill is the failure-reporting procedure for this machine. Neo's
          update supervision preloads it (`-s ${cfg.skillName}`) on every
          non-noop supervise run, so its body is part of the system prompt.

          Also use it when an operator asks you to file a Neo update/activate
          failure as an incident.

          ## Required procedure
          1. Classify the outcome from the updater marker, systemd state and
             journals: **broken**, **warning** or **clean**.
          2. **broken:** notify with `hermes send --to all` (short summary),
             **then** file the incident with `neo-incident-report` (below).
             Skipping the report on a broken outcome is a procedure failure.
          3. **warning:** notify only; do **not** report.
          4. **clean:** do nothing.
          5. Never invent tokens. If `neo-incident-report` exits 3 (token
             missing or placeholder), say so in the notification and stop.

          ## Report (no secrets on the command line)
          Write the payload to a temp file and pipe it to the helper. The helper
          reads the endpoint, token file, reporter id and runtime overrides from
          `/etc/neo-reporter/config.json`, adds `reporter_id` and `machine`, and
          sends the Bearer token from a 0600 header file.

          ```bash
          jq -n \
            --arg report_hash "$REPORT_HASH" \
            --arg neo_version "$NEO_VERSION" \
            --arg unit "$UNIT" \
            --arg logs_excerpt "$LOGS_EXCERPT" \
            --arg severity "$SEVERITY" \
            --arg target_hint "$TARGET_HINT" \
            '{report_hash: $report_hash, neo_version: $neo_version, unit: $unit,
              logs_excerpt: $logs_excerpt, severity: $severity, target_hint: $target_hint}' \
            > /tmp/neo-incident.json
          neo-incident-report --file /tmp/neo-incident.json
          rm -f /tmp/neo-incident.json
          ```

          `neo-incident-report --dry-run --file …` prints the resolved endpoint,
          the reporter id, the token state (present/placeholder/missing) and the
          body, without sending.

          ## Payload fields
          | Field | Required | Notes |
          |-------|----------|-------|
          | `report_hash` | yes | Stable id for this incident (e.g. sha256 of unit + neo_version + head of the log excerpt, or the updater run id). Used for dedup. |
          | `neo_version` | yes | Neo / generation hint (`neo --version`, generation path). |
          | `unit` | yes | Failed unit or workflow (`neo-auto-update`, `neo activate`, flake input name, …). |
          | `logs_excerpt` | yes | Short tail of the relevant journal / updater `.log`. Truncate; strip secrets. |
          | `severity` | yes | `info`, `warning`, `error` or `critical`. A hard update/activate failure is `error` or `critical`. |
          | `target_hint` | yes | What broke / where to look (unit, flake input, component). |
          | `machine` | no | Defaults to `hostname -s`. |

          ## This machine
          - Endpoint: ${endpointText}${lib.optionalString (cfg.overridesFile != null) " (an `ingest_url` in `${cfg.overridesFile}` wins)"}
          - Token file: ${
            if cfg.tokenFile != null
            then "`${cfg.tokenFile}`"
            else "(not set)"
          }
          - Never print, paste or store the token (chat, notifications, MEMORY, skill notes).

          ## Pitfalls
          - Truncate logs; redact API keys, SSH keys and `.env` contents before reporting.
          - One report per incident; reuse the same `report_hash` for the same failure.
          - Tell the operator only that an incident was filed (HTTP status and `report_hash`).

          ## Verification
          - `neo-incident-report --dry-run --file <payload>` shows `token: present` and the expected endpoint.
          - A real report is only for confirmed failures; expect HTTP 2xx.
        '';
      };
    in
      skill
      // {
        content = builtins.replaceStrings ["platforms: [linux]\n"] [""] skill.content;
      });
  };
}
