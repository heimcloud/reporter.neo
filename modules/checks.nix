# nix flake check: helper script tests + NixOS evaluation tests with Neo.
{
  inputs,
  self,
  ...
}: {
  perSystem = {
    pkgs,
    lib,
    system,
    ...
  }: let
    mkHost = neo:
      inputs.nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs.lib = inputs.neo.lib;
        modules = [
          inputs.neo.nixosModules.default
          inputs.neo.nixosModules.base
          self.nixosModules.default
          # imported twice on purpose: `key` must dedupe it
          self.nixosModules.default
          {
            inherit neo;
            fileSystems."/" = {
              device = "none";
              fsType = "tmpfs";
            };
            boot.loader.grub.devices = ["nodev"];
          }
        ];
      };
    base = {
      core.hostname = "test-host";
      services.swag.domain = "example.net";
      services.hermes = {
        enabled = true;
        superviseUpdates = true;
        dashboardPassword = "test-only-not-a-secret";
      };
      services.system-updater.enabled = true;
      services.docker-updater.enabled = true;
    };
    on = mkHost (lib.recursiveUpdate base {
      services.reporter = {
        enabled = true;
        endpoint = "https://autofix.example.net/api/incidents";
        tokenFile = "/var/lib/reporter-test/ingest.token";
        reporterId = "rid-test";
        overridesFile = "/var/lib/reporter-test/meta.json";
        skillName = "legacy-ingest-name";
      };
    });
    tokenOnly = mkHost (lib.recursiveUpdate base {
      services.reporter = {
        enabled = true;
        endpoint = "https://autofix.example.net/api/incidents";
        token = "test-only-not-a-secret";
      };
    });
    tc = tokenOnly.config;
    off = mkHost base;
    noSupervise = mkHost (lib.recursiveUpdate base {
      services.reporter = {
        enabled = true;
        endpoint = "https://autofix.example.net/api/incidents";
        tokenFile = "/var/lib/reporter-test/ingest.token";
        supervise = false;
      };
    });
    c = on.config;
    sys = c.systemd.services;
    sock = c.systemd.sockets.neo-reporter-submit;
    submitUnit = sys."neo-reporter-submit@";
    skill = c.neo.services.reporter.skill.conf;
    rc = builtins.fromJSON c.environment.etc."neo-reporter/config.json".text;
    offSys = off.config.systemd.services;
    nsSys = noSupervise.config.systemd.services;
    failed = n: lib.filter (a: !a.assertion) n.config.assertions;
    expect = [
      ["skill name" (skill.name == "legacy-ingest-name")]
      ["skill uses send-report" (lib.hasInfix "send-report" skill.content && !(lib.hasInfix "ingest.token" skill.content))]
      ["skill has no platforms line" (!(lib.hasInfix "platforms:" skill.content))]
      [
        "runtime config has no secrets or secret paths"
        (rc
          == {
            endpoint = "https://autofix.example.net/api/incidents";
            reporterId = "rid-test";
            socket = "/run/neo-reporter/submit.sock";
          })
      ]
      ["token unit stages creds from tokenFile + overrides" (let x = sys.neo-reporter-token.serviceConfig.ExecStart; in lib.hasInfix "--source /var/lib/reporter-test/ingest.token" x && lib.hasInfix "--dest-dir /run/neo-reporter/creds" x && lib.hasInfix "--overrides /var/lib/reporter-test/meta.json" x)]
      ["run dir 0755, creds dir 0700 root" (lib.elem "d /run/neo-reporter 0755 root root -" c.systemd.tmpfiles.rules && lib.elem "d /run/neo-reporter/creds 0700 root root -" c.systemd.tmpfiles.rules)]
      ["token activation" (c.system.activationScripts ? neo-reporter-token)]
      ["path unit watches tokenFile" (c.systemd.paths.neo-reporter-token.pathConfig.PathChanged == "/var/lib/reporter-test/ingest.token")]
      ["socket: 0666, Accept, bounded" (let
          sc = sock.socketConfig;
        in
          sc.ListenStream == "/run/neo-reporter/submit.sock" && sc.SocketMode == "0666" && sc.Accept == true && sc.MaxConnections == 16 && sc.MaxConnectionsPerSource == 4 && sc.TriggerLimitIntervalSec == 0 && lib.elem "sockets.target" sock.wantedBy && (sock.wants or []) == [] && (sock.after or []) == [])]
      ["submit: dynamic user, token only via LoadCredential" (let
          sc = submitUnit.serviceConfig;
        in
          sc.DynamicUser && sc.User == "neo-reporter" && lib.elem "token:/run/neo-reporter/creds/token" sc.LoadCredential && lib.elem "overrides.json:/run/neo-reporter/creds/overrides.json" sc.LoadCredential && sc.StandardInput == "socket" && sc.StandardOutput == "socket" && lib.hasSuffix "/bin/neo-reporter-submit" sc.ExecStart)]
      ["submit: sandbox" (let
          sc = submitUnit.serviceConfig;
        in
          sc.ProtectSystem == "strict" && sc.ProtectHome && sc.PrivateTmp && sc.PrivateDevices && sc.NoNewPrivileges && sc.RestrictAddressFamilies == ["AF_INET" "AF_INET6" "AF_UNIX"] && sc.CapabilityBoundingSet == "" && sc.RestrictSUIDSGID && sc.MemoryDenyWriteExecute && sc.ProtectKernelTunables && sc.SystemCallArchitectures == "native" && sc.UMask == "0077")]
      ["submit: timeouts + state" (let
          sc = submitUnit.serviceConfig;
        in
          sc.RuntimeMaxSec == 60 && sc.StateDirectory == "neo-reporter" && submitUnit.unitConfig.CollectMode == "inactive-or-failed" && submitUnit.environment.SSL_CERT_FILE == "/etc/ssl/certs/ca-certificates.crt")]
      ["supervise wants the socket, send-report on its PATH" (lib.elem "neo-reporter-submit.socket" sys.neo-hermes-supervise-system-update.wants && lib.elem "neo-reporter-submit.socket" sys.neo-hermes-supervise-docker-update.after && lib.any (p: lib.hasInfix "send-report" (toString p)) sys.neo-hermes-supervise-system-update.path && lib.any (p: lib.hasInfix "send-report" (toString p)) sys.neo-hermes-supervise-docker-update.path)]
      ["send-report + alias on the Hermes gateway PATH" (lib.all (n: lib.any (p: (p.name or "") == n) c.services.hermes-agent.extraPackages) ["send-report" "neo-incident-report"] && lib.any (p: lib.hasInfix "send-report" (toString p)) sys.hermes-agent.path)]
      ["send-report + alias on the system PATH" (lib.all (n: lib.any (p: (p.name or "") == n) c.environment.systemPackages) ["send-report" "neo-incident-report"])]
      ["token only: no failed assertions" (failed tokenOnly == [])]
      ["token only: no source arg, no path unit" (!(lib.hasInfix "--source" tc.systemd.services.neo-reporter-token.serviceConfig.ExecStart) && !(tc.systemd.paths ? neo-reporter-token))]
      ["token only: no overrides arg" (!(lib.hasInfix "--overrides" tc.systemd.services.neo-reporter-token.serviceConfig.ExecStart))]
      ["token never in Nix text" (!(lib.hasInfix "test-only-not-a-secret" (tc.systemd.services.neo-reporter-token.serviceConfig.ExecStart + tc.environment.etc."neo-reporter/config.json".text + tc.neo.services.reporter.skill.conf.content + tc.system.activationScripts.neo-reporter-token.text + builtins.toJSON tc.systemd.services."neo-reporter-submit@".serviceConfig + builtins.toJSON tc.systemd.sockets.neo-reporter-submit.socketConfig)))]
      ["off: no token unit, no socket, no submit service" (!(offSys ? neo-reporter-token) && !(off.config.systemd.sockets ? neo-reporter-submit) && !(offSys ? "neo-reporter-submit@"))]
      ["system supervise preloads skill" (lib.hasInfix "neo-reporter-supervise system" sys.neo-hermes-supervise-system-update.serviceConfig.ExecStart)]
      ["docker supervise preloads skill" (lib.hasInfix "neo-reporter-supervise docker" sys.neo-hermes-supervise-docker-update.serviceConfig.ExecStart)]
      ["off: stock supervise untouched" (!(lib.hasInfix "neo-reporter" offSys.neo-hermes-supervise-system-update.serviceConfig.ExecStart))]
      ["off: no skill" (off.config.neo.services.reporter.skill.conf == null)]
      ["off: no runtime config" (!(off.config.environment.etc ? "neo-reporter/config.json"))]
      ["supervise=false: stock supervise untouched" (!(lib.hasInfix "neo-reporter" nsSys.neo-hermes-supervise-system-update.serviceConfig.ExecStart))]
      ["supervise=false: skill still published" (noSupervise.config.neo.services.reporter.skill.conf.name == "incident-reporter")]
      ["no failed assertions (on)" (failed on == [])]
      ["no failed assertions (off)" (failed off == [])]
      [
        "enabled without endpoint/token fails"
        (let
          bad = mkHost (lib.recursiveUpdate base {services.reporter.enabled = true;});
        in
          builtins.length (failed bad) == 2)
      ]
    ];
    bad = lib.filter (e: !(builtins.elemAt e 1)) expect;
    sendReport = pkgs.callPackage ../pkgs/send-report.nix {};
    submit = pkgs.callPackage ../pkgs/neo-reporter-submit.nix {};
    alias = pkgs.callPackage ../pkgs/neo-incident-report.nix {send-report = sendReport;};
    tokenTool = pkgs.callPackage ../pkgs/neo-reporter-token.nix {};
  in {
    packages = {
      send-report = sendReport;
      neo-reporter-submit = submit;
      neo-incident-report = alias;
      neo-reporter-token = tokenTool;
      default = sendReport;
      # Not in `checks` (needs KVM): nix build .#vm-test
      vm-test = import ../test/vm.nix {inherit pkgs self inputs;};
    };
    checks = {
      report-script =
        pkgs.runCommand "reporter-script-tests" {
          nativeBuildInputs = [pkgs.bash pkgs.python3 pkgs.coreutils];
        } ''
          cp -r ${self}/scripts ${self}/test .
          export HOME=$TMPDIR
          python3 -m unittest discover -s test -p 'test_*.py' -v
          SUBMIT_BIN=${submit}/bin/neo-reporter-submit SEND_BIN=${sendReport}/bin/send-report \
            python3 -m unittest discover -s test -p 'test_*.py'
          bash test/token.test.sh
          TOKEN_BIN=${tokenTool}/bin/neo-reporter-token bash test/token.test.sh
          # alias maps to send-report --json (dry run against no socket → exit 3)
          set +e
          echo '{"logs_excerpt":"x"}' | NEO_REPORTER_SOCKET=$TMPDIR/none.sock ${alias}/bin/neo-incident-report --dry-run --file - 2> alias.err
          rc=$?
          set -e
          [ "$rc" = 3 ] && grep -q "not available" alias.err
          touch $out
        '';
      eval =
        if bad == []
        then
          pkgs.runCommand "reporter-eval-tests" {} ''
            echo ${lib.escapeShellArg (builtins.toJSON (map builtins.head expect))} > $out
            echo ${builtins.unsafeDiscardStringContext on.config.system.build.toplevel.drvPath} >> $out
          ''
        else throw "reporter eval checks failed: ${builtins.toJSON (map builtins.head bad)}";
    };
  };
}
