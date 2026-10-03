# Options for the Hermes incident reporter (neo.services.reporter).
{...}: {
  flake.modules.nixos.reporter-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.reporter = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Hermes incident reporter" {rank = 0;};

              endpoint = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "https://autofix.example.net/api/incidents";
                description = "Incident ingest URL (full URL, POST). Required when enabled. A runtime overridesFile may replace it.";
                rank = 10;
              };

              tokenFile = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "/var/neo/DATA/AppData/reporter/ingest.token";
                description = "File with the Bearer token for the endpoint (first line). Missing, empty or a value starting with 'replace-' means: notify locally, do not POST.";
                rank = 20;
              };

              reporterId = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Optional id of this machine/installation, sent as reporter_id (and the legacy customer_repo_slug). A runtime overridesFile may replace it.";
                rank = 30;
              };

              overridesFile = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Optional JSON file read at report time. Keys ingest_url/ops_ingest_url replace endpoint; reporter_id/repo_slug/customer_repo_slug replace reporterId.";
                rank = 40;
              };

              supervise = mkOption {
                type = types.bool;
                default = true;
                description = "Preload the reporter skill into Neo's Hermes update supervision (needs services.hermes.superviseUpdates).";
                rank = 50;
              };

              skillName = mkOption {
                type = types.strMatching "[a-z0-9][a-z0-9-]*";
                default = "incident-reporter";
                description = "Hermes skill name (directory and -s name). Change only to keep an existing name stable.";
                rank = 90;
              };
            }
            // lib.neo.mkSkillOptions {enabled = true;}
            // lib.neo.mkServiceMeta {
              category = "AI";
              description = ''
                Hermes incident reporter. Neo's update supervision classifies
                failed updates/activations and POSTs broken ones to an incident
                endpoint (for example an autofix.neo desk), with a Bearer token
                read from a file. No containers; installs a Hermes skill and a
                small helper (neo-incident-report).
              '';
              projectUrl = "https://github.com/heimcloud/reporter.neo";
              githubUrl = "https://github.com/heimcloud/reporter.neo";
            };
        };
        default = {};
        description = "Hermes incident reporter";
      };
    };
}
