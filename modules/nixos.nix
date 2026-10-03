{config, ...}: {
  systems = ["x86_64-linux"];
  perSystem = {pkgs, ...}: {
    formatter = pkgs.alejandra;
  };
  flake = {lib, ...}: let
    allNixosModules = lib.attrValues (config.flake.modules.nixos or {});
  in {
    # `key` lets the module system dedupe this plugin when it is imported twice
    # (e.g. listed in core.plugins *and* pulled in by another plugin).
    nixosModules.default = {
      key = "reporter.neo";
      imports = allNixosModules;
    };
  };
}
