# Helper binary + runtime config for the incident reporter, and the token copy
# the reporter reads.
#
# Token: services.reporter.token (settings.toml) or tokenFile (any owner, e.g.
# a homeserver-0600 file) → root oneshot neo-reporter-token →
# /run/neo-reporter/ingest.token, root:hermes 0440. The reporter (supervise
# units, Hermes gateway: user hermes) only ever reads that copy. The token
# value never enters Nix: the oneshot reads settings.toml at run time.
{...}: {
  flake.modules.nixos.reporter = {
    config,
    lib,
    options,
    pkgs,
    ...
  }: let
    cfg = config.neo.services.reporter;
    helper = pkgs.callPackage ../../../pkgs/neo-incident-report.nix {};
    tokenTool = pkgs.callPackage ../../../pkgs/neo-reporter-token.nix {};
    tokenDir = "/run/neo-reporter";
    tokenPath = "${tokenDir}/ingest.token";
    hermesGroup = config.services.hermes-agent.group or "hermes";
    group =
      if config.users.groups ? ${hermesGroup}
      then hermesGroup
      else "root";
    materialize = lib.concatStringsSep " " ([
        "${tokenTool}/bin/neo-reporter-token"
        "--dest ${tokenPath}"
        "--group ${group}"
      ]
      ++ lib.optional (cfg.tokenFile != null) "--source ${lib.escapeShellArg cfg.tokenFile}");
    runtimeConfig = {
      inherit (cfg) endpoint reporterId overridesFile;
      tokenFile = tokenPath;
    };
    hasHermesAgent = options ? services && options.services ? hermes-agent;
  in {
    config = lib.mkIf cfg.enabled (lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.endpoint != null || cfg.overridesFile != null;
            message = "neo.services.reporter: set endpoint (or an overridesFile that provides ingest_url).";
          }
          {
            assertion = cfg.token != null || cfg.tokenFile != null;
            message = "neo.services.reporter: set token (or tokenFile) in [services.reporter].";
          }
        ];
        environment.systemPackages = [helper];
        environment.etc."neo-reporter/config.json".text = builtins.toJSON runtimeConfig;

        systemd.tmpfiles.rules = ["d ${tokenDir} 0750 root ${group} -"];

        # Every switch/boot, so settings.toml / tokenFile edits are picked up.
        system.activationScripts.neo-reporter-token = {
          deps = ["users" "etc"];
          text = "${materialize} || true";
        };

        # Same as a oneshot: the supervise units want it before each run, the
        # path unit below re-runs it when tokenFile changes (e.g. a sync), and
        # operators can `systemctl start neo-reporter-token` after an edit.
        systemd.services.neo-reporter-token = {
          description = "Copy the incident reporter token to ${tokenPath}";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = materialize;
            UMask = "0077";
          };
        };
        systemd.paths.neo-reporter-token = lib.mkIf (cfg.tokenFile != null) {
          description = "Watch the incident reporter token file";
          wantedBy = ["multi-user.target"];
          pathConfig = {
            PathChanged = cfg.tokenFile;
            Unit = "neo-reporter-token.service";
          };
        };
      }
      # Interactive / operator-requested reports from the Hermes gateway: the
      # helper on the gateway PATH and the hermes user profile.
      (lib.optionalAttrs hasHermesAgent {
        services.hermes-agent.extraPackages = [helper];
      })
    ]);
  };
}
