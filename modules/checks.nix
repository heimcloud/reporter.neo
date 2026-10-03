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
    skill = c.neo.services.reporter.skill.conf;
    rc = builtins.fromJSON c.environment.etc."neo-reporter/config.json".text;
    offSys = off.config.systemd.services;
    nsSys = noSupervise.config.systemd.services;
    failed = n: lib.filter (a: !a.assertion) n.config.assertions;
    expect = [
      ["skill name" (skill.name == "legacy-ingest-name")]
      ["skill mentions helper" (lib.hasInfix "neo-incident-report" skill.content)]
      ["skill has no platforms line" (!(lib.hasInfix "platforms:" skill.content))]
      [
        "runtime config"
        (rc
          == {
            endpoint = "https://autofix.example.net/api/incidents";
            tokenFile = "/run/neo-reporter/ingest.token";
            reporterId = "rid-test";
            overridesFile = "/var/lib/reporter-test/meta.json";
          })
      ]
      ["token unit copies tokenFile" (lib.hasInfix "--source /var/lib/reporter-test/ingest.token" sys.neo-reporter-token.serviceConfig.ExecStart && lib.hasInfix "--group hermes" sys.neo-reporter-token.serviceConfig.ExecStart)]
      ["token dir root:hermes 0750" (lib.elem "d /run/neo-reporter 0750 root hermes -" c.systemd.tmpfiles.rules)]
      ["token activation" (c.system.activationScripts ? neo-reporter-token)]
      ["path unit watches tokenFile" (c.systemd.paths.neo-reporter-token.pathConfig.PathChanged == "/var/lib/reporter-test/ingest.token")]
      ["supervise wants token unit" (lib.elem "neo-reporter-token.service" sys.neo-hermes-supervise-system-update.wants && lib.elem "neo-reporter-token.service" sys.neo-hermes-supervise-docker-update.after)]
      ["helper on the Hermes gateway PATH" (lib.any (p: (p.name or "") == "neo-incident-report") c.services.hermes-agent.extraPackages && lib.any (p: lib.hasInfix "neo-incident-report" (toString p)) sys.hermes-agent.path)]
      ["token only: no failed assertions" (failed tokenOnly == [])]
      ["token only: no source arg, no path unit" (!(lib.hasInfix "--source" tc.systemd.services.neo-reporter-token.serviceConfig.ExecStart) && !(tc.systemd.paths ? neo-reporter-token))]
      ["token never in Nix text" (!(lib.hasInfix "test-only-not-a-secret" (tc.systemd.services.neo-reporter-token.serviceConfig.ExecStart + tc.environment.etc."neo-reporter/config.json".text + tc.neo.services.reporter.skill.conf.content + tc.system.activationScripts.neo-reporter-token.text)))]
      ["off: no token unit" (!(offSys ? neo-reporter-token))]
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
    helper = pkgs.callPackage ../pkgs/neo-incident-report.nix {};
    tokenTool = pkgs.callPackage ../pkgs/neo-reporter-token.nix {};
  in {
    packages.neo-incident-report = helper;
    packages.neo-reporter-token = tokenTool;
    packages.default = helper;
    checks = {
      report-script =
        pkgs.runCommand "reporter-script-tests" {
          nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.curl pkgs.python3 pkgs.hostname pkgs.coreutils pkgs.shellcheck];
        } ''
          cp -r ${self}/scripts ${self}/test .
          shellcheck -S warning scripts/neo-incident-report.sh
          bash test/report.test.sh
          REPORT_BIN=${helper}/bin/neo-incident-report bash test/report.test.sh
          TOKEN_BIN=${tokenTool}/bin/neo-reporter-token bash test/token.test.sh
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
