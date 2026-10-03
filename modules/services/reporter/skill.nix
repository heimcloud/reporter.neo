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
             **then** file the incident with `send-report` (below).
             Skipping the report on a broken outcome is a procedure failure.
          3. **warning:** notify only; do **not** report.
          4. **clean:** do nothing.
          5. Never look for or invent tokens: `send-report` has none and needs
             none. If it exits 3 (not configured) or 4 (rate limited), say so
             in the notification and stop.

          ## Report
          `send-report` hands the report to the local reporter service over
          `/run/neo-reporter/submit.sock`; the service adds the reporter id,
          the machine name and who sent it, and POSTs it with the ingest
          token, which only that service can read. Text comes from the
          arguments or stdin (max 64 KiB).

          ```bash
          journalctl -u "$UNIT" -n 80 --no-pager | tail -c 20000 \
            | send-report --severity error --unit "$UNIT" \
                --title "$UNIT failed after the update" --kind update
          ```

          Prints `incident #<id> filed (status open)`, or `already on the
          board` for a repeat of the same report (deduplicated by
          `report_hash`). For full control send an incident JSON object:

          ```bash
          jq -n --arg unit "$UNIT" --arg logs "$LOGS_EXCERPT" --arg hint "$TARGET_HINT" \
            '{unit: $unit, logs_excerpt: $logs, severity: "error", target_hint: $hint}' \
            | send-report --json
          ```

          Optional JSON fields: `report_hash` (stable id, default: hash of
          machine + unit + title + text), `neo_version` (default: the running
          generation), `kind`. `--dry-run` shows the body the service would
          send and the token state (present/placeholder/missing) without
          posting.

          Exit codes: 0 filed or duplicate, 1 endpoint/transport error,
          2 invalid or too large, 3 not configured, 4 rate limited.

          ## This machine
          - Endpoint: ${endpointText}${lib.optionalString (cfg.overridesFile != null) " (an `ingest_url` in `${cfg.overridesFile}` wins)"}
          - Token: held by `neo-reporter-submit` (systemd credential, root only). You never need it.
          - `neo-incident-report` is a deprecated alias for `send-report --json --file …`.

          ## Pitfalls
          - Truncate logs; redact API keys, SSH keys and `.env` contents before reporting.
          - One report per incident; the same text and unit reuse the same `report_hash`.
          - Tell the operator only that an incident was filed (incident id or `report_hash`).

          ## Verification
          - `echo test | send-report --dry-run` shows `"token": "present"` and the expected endpoint.
          - A real report is only for confirmed failures (or an operator-requested test).
        '';
      };
    in
      skill
      // {
        content = builtins.replaceStrings ["platforms: [linux]\n"] [""] skill.content;
      });
  };
}
