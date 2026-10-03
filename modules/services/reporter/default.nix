# Helper binary + runtime config for the incident reporter.
{...}: {
  flake.modules.nixos.reporter = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.neo.services.reporter;
    helper = pkgs.callPackage ../../../pkgs/neo-incident-report.nix {};
    runtimeConfig = {
      inherit (cfg) endpoint tokenFile reporterId overridesFile;
    };
  in {
    config = lib.mkIf cfg.enabled {
      assertions = [
        {
          assertion = cfg.endpoint != null || cfg.overridesFile != null;
          message = "neo.services.reporter: set endpoint (or an overridesFile that provides ingest_url).";
        }
        {
          assertion = cfg.tokenFile != null;
          message = "neo.services.reporter: set tokenFile (Bearer token file for the endpoint).";
        }
      ];
      environment.systemPackages = [helper];
      environment.etc."neo-reporter/config.json".text = builtins.toJSON runtimeConfig;
    };
  };
}
