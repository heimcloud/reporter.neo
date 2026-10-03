# Update-supervision preload: replace the ExecStart of Neo's
# neo-hermes-supervise-{system,docker}-update units so Hermes runs with the
# reporter skill preloaded (`-s <skillName>`). Hermes folds preloaded skill
# bodies into the system prompt, so the procedure cannot be skipped.
# (A future Neo option for extra supervise skills would make the mkForce
# override unnecessary.)
{...}: {
  flake.modules.nixos.reporter-supervise = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.reporter;
      hermes = config.neo.services.hermes;
      skill = cfg.skillName;
      enable =
        cfg.enabled
        && cfg.supervise
        && (hermes.enabled or false)
        && (hermes.superviseUpdates or false);

      hermesPkg = config.services.hermes-agent.package;
      dockerManifest = "${config.neo.services.docker-updater.appdata}/last.json";
      systemManifest = "${config.neo.services.system-updater.appdata}/last.json";
      systemUpdaterOn = config.neo.services.system-updater.enabled or false;
      dockerUpdaterOn = config.neo.services.docker-updater.enabled or false;

      telegramHomeChannel =
        if hermes.telegramAllowedUserId == []
        then null
        else toString (builtins.head hermes.telegramAllowedUserId);

      superviseEnv =
        lib.filterAttrs (_: v: v != null && v != "") {
          HOME = hermes.stateDir;
          HERMES_HOME = "${hermes.stateDir}/.hermes";
          TELEGRAM_BOT_TOKEN = hermes.telegramBotToken;
          HERMES_GATEWAY_TOKEN = hermes.gatewayToken;
          TELEGRAM_ALLOWED_USERS = lib.concatStringsSep "," (map toString hermes.telegramAllowedUserId);
          TELEGRAM_HOME_CHANNEL = telegramHomeChannel;
        }
        // lib.neo.mkHermesLlmEnv {
          inherit (hermes.llm) provider apiKey;
        };

      # Single preloaded skill (classify + notify + mandatory report).
      promptFor = kind: ''
        You are supervising a Neo homeserver ${kind} update.

        Skill **/${skill}** is already preloaded into your system prompt — follow it exactly. Do not skip the incident report when the outcome is broken.

        Latest marker (symlink, retargeted at run start): ${
          if kind == "system"
          then systemManifest
          else dockerManifest
        }
        Run history (JSON + matching .log per run): ${
          if kind == "system"
          then config.neo.services.system-updater.appdata
          else config.neo.services.docker-updater.appdata
        }
        If the marker has in_progress=true, the updater did not finish cleanly — treat as failed.
        Updater unit: ${
          if kind == "system"
          then "neo-auto-update.service"
          else "neo-docker-updater.service"
        }

        Classify as broken, warning, or clean using systemd state and logs.
        - clean: do not send Telegram; do not report
        - warning: notify via `hermes send --to all`; do not report; do not roll back
        - broken: notify via `hermes send --to all`; **must** report the incident per /${skill} (`neo-incident-report`)
          ${
          if kind == "docker"
          then "- for each broken image, run `sudo neo-docker-rollback --image '<repo:tag>'` then confirm the unit is active; mention the rollback in the notification"
          else "- do NOT roll back the NixOS generation; only report what failed"
        }

        Never dump secrets. Keep notifications short.
      '';

      systemPromptFile = pkgs.writeText "neo-reporter-supervise-system-prompt.txt" (promptFor "system");
      dockerPromptFile = pkgs.writeText "neo-reporter-supervise-docker-prompt.txt" (promptFor "docker");

      superviseScript = pkgs.writeShellScriptBin "neo-reporter-supervise" ''
        set -euo pipefail
        kind=''${1:-}
        case "$kind" in
          system)
            marker=${systemManifest}
            unit=neo-auto-update.service
            prompt_file=${systemPromptFile}
            ;;
          docker)
            marker=${dockerManifest}
            unit=neo-docker-updater.service
            prompt_file=${dockerPromptFile}
            ;;
          *)
            echo "usage: neo-reporter-supervise system|docker" >&2
            exit 2
            ;;
        esac

        changed=false
        failed=false
        in_progress=false
        if [ -f "$marker" ]; then
          changed=$(${pkgs.jq}/bin/jq -r '.changed // false' "$marker")
          failed=$(${pkgs.jq}/bin/jq -r '.failed // false' "$marker")
          in_progress=$(${pkgs.jq}/bin/jq -r '.in_progress // false' "$marker")
          echo "marker $marker changed=$changed failed=$failed in_progress=$in_progress"
          ${pkgs.jq}/bin/jq . "$marker" || true
        else
          echo "no marker at $marker"
        fi

        unit_failed=false
        if ${pkgs.systemd}/bin/systemctl is-failed --quiet "$unit" 2>/dev/null; then
          unit_failed=true
          echo "$unit is failed"
        fi

        if [ "$changed" != true ] && [ "$failed" != true ] && [ "$in_progress" != true ] && [ "$unit_failed" != true ]; then
          echo "noop: skip Hermes"
          exit 0
        fi

        echo "Launching Hermes supervise ($kind) with -s ${skill}"
        # Single -s: if the skill is missing, Hermes fails closed (ValueError) instead of silently continuing.
        ${hermesPkg}/bin/hermes --yolo chat -Q --source tool --max-turns 40 \
          -s ${skill} --query-file "$prompt_file"
      '';
    in {
      config = mkIf enable {
        assertions = [
          {
            assertion = cfg.skill.enabled && cfg.skill.conf != null;
            message = "neo.services.reporter.supervise needs the reporter skill (skill.enabled = true).";
          }
        ];

        environment.systemPackages = [superviseScript];

        # Replace Neo's stock supervise ExecStart (which only -s neo-update-supervisor).
        systemd.services.neo-hermes-supervise-system-update = mkIf systemUpdaterOn {
          description = lib.mkForce "Hermes supervision of neo-auto-update (preload ${skill})";
          after = ["network-online.target" "neo-auto-update.service"];
          wants = ["network-online.target"];
          path = [pkgs.jq pkgs.systemd pkgs.sudo hermesPkg "/run/current-system/sw"];
          environment = superviseEnv;
          serviceConfig = {
            Type = "oneshot";
            User = "hermes";
            Group = "hermes";
            WorkingDirectory = "${hermes.stateDir}/workspace";
            TimeoutStartSec = "15min";
            ExecStart = mkForce "${superviseScript}/bin/neo-reporter-supervise system";
          };
        };

        systemd.services.neo-hermes-supervise-docker-update = mkIf dockerUpdaterOn {
          description = lib.mkForce "Hermes supervision of neo-docker-updater (preload ${skill})";
          after = ["network-online.target" "neo-docker-updater.service"];
          wants = ["network-online.target"];
          path = [pkgs.jq pkgs.systemd pkgs.sudo pkgs.docker hermesPkg "/run/current-system/sw"];
          environment = superviseEnv;
          serviceConfig = {
            Type = "oneshot";
            User = "hermes";
            Group = "hermes";
            WorkingDirectory = "${hermes.stateDir}/workspace";
            TimeoutStartSec = "15min";
            ExecStart = mkForce "${superviseScript}/bin/neo-reporter-supervise docker";
          };
        };
      };
    };
}
