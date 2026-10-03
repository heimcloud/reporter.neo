# send-report + the reporter socket service.
#
#   any local user ── send-report ──▶ /run/neo-reporter/submit.sock (0666)
#        ──▶ neo-reporter-submit@.service (DynamicUser, sandboxed, one per
#            connection) ──Bearer──▶ endpoint
#
# Token: services.reporter.token (settings.toml) or tokenFile (any owner, e.g.
# a homeserver-0600 file) → root oneshot neo-reporter-token →
# /run/neo-reporter/creds/token (0400 root, directory 0700 root) →
# LoadCredential= of the submit service. Nobody else (hermes included) can read
# it; the token value never enters Nix (the oneshot reads settings.toml at
# run time). The service identifies the caller with SO_PEERCRED and stamps it
# as submitted_by (root, hermes or uid-<n>), bounds the request (64 KiB),
# rate-limits per uid and answers with the incident id.
{...}: {
  flake.modules.nixos.reporter = {
    config,
    lib,
    options,
    pkgs,
    ...
  }: let
    cfg = config.neo.services.reporter;
    sendReport = pkgs.callPackage ../../../pkgs/send-report.nix {};
    submit = pkgs.callPackage ../../../pkgs/neo-reporter-submit.nix {};
    alias = pkgs.callPackage ../../../pkgs/neo-incident-report.nix {send-report = sendReport;};
    tokenTool = pkgs.callPackage ../../../pkgs/neo-reporter-token.nix {};
    runDir = "/run/neo-reporter";
    credsDir = "${runDir}/creds";
    socketPath = "${runDir}/submit.sock";
    hermesUser = config.services.hermes-agent.user or "hermes";
    materialize = lib.concatStringsSep " " ([
        "${tokenTool}/bin/neo-reporter-token"
        "--dest-dir ${credsDir}"
      ]
      ++ lib.optional (cfg.tokenFile != null) "--source ${lib.escapeShellArg cfg.tokenFile}"
      ++ lib.optional (cfg.overridesFile != null) "--overrides ${lib.escapeShellArg cfg.overridesFile}");
    # No secrets in here (world-readable): endpoint and id only.
    runtimeConfig = {
      inherit (cfg) endpoint reporterId;
      socket = socketPath;
    };
    hasHermesAgent = options ? services && options.services ? hermes-agent;
    tools = [sendReport alias];
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
        environment.systemPackages = tools;
        environment.etc."neo-reporter/config.json".text = builtins.toJSON runtimeConfig;

        # 0755 so every user reaches the socket; creds/ stays root-only.
        systemd.tmpfiles.rules = [
          "d ${runDir} 0755 root root -"
          "d ${credsDir} 0700 root root -"
        ];

        # Every switch/boot, so settings.toml / tokenFile edits are picked up.
        system.activationScripts.neo-reporter-token = {
          deps = ["users" "etc"];
          text = "${materialize} || true";
        };

        # Same as a oneshot; the path
        # unit re-runs it when tokenFile changes, and operators can
        # `systemctl start neo-reporter-token` after an edit.
        systemd.services.neo-reporter-token = {
          description = "Stage the incident reporter token as a root-only credential";
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

        systemd.sockets.neo-reporter-submit = {
          description = "Incident reporter submit socket (send-report)";
          # No ordering on neo-reporter-token.service: a socket is started
          # before basic.target, so that would be a cycle. The activation
          # script stages the credentials on every boot/switch, and they are
          # only loaded when a connection starts an instance.
          wantedBy = ["sockets.target"];
          socketConfig = {
            ListenStream = socketPath;
            SocketMode = "0666";
            Accept = true;
            MaxConnections = 16;
            MaxConnectionsPerSource = 4;
            # A flood must not put the socket into a failed state (that would
            # let any user switch reporting off); MaxConnections* and the
            # per-uid bucket in the service do the limiting.
            TriggerLimitIntervalSec = 0;
            RemoveOnStop = true;
          };
        };

        systemd.services."neo-reporter-submit@" = {
          description = "Incident reporter submission (one connection)";
          environment = {
            NEO_REPORTER_CONFIG = "/etc/neo-reporter/config.json";
            SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
            NEO_REPORTER_HERMES_USER = hermesUser;
          };
          unitConfig.CollectMode = "inactive-or-failed";
          serviceConfig = {
            ExecStart = "${submit}/bin/neo-reporter-submit";
            StandardInput = "socket";
            StandardOutput = "socket";
            StandardError = "journal";
            DynamicUser = true;
            User = "neo-reporter";
            StateDirectory = "neo-reporter";
            StateDirectoryMode = "0700";
            LoadCredential = [
              "token:${credsDir}/token"
              "overrides.json:${credsDir}/overrides.json"
            ];
            RuntimeMaxSec = 60;
            # sandbox
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
            RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
            SystemCallFilter = ["@system-service" "~@privileged"];
            CapabilityBoundingSet = "";
            AmbientCapabilities = "";
            UMask = "0077";
            MemoryMax = "128M";
            TasksMax = 8;
          };
        };
      }
      # Interactive / operator-requested reports from the Hermes gateway.
      (lib.optionalAttrs hasHermesAgent {
        services.hermes-agent.extraPackages = tools;
      })
    ]);
  };
}
