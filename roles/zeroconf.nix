{ pkgs, lib, config, ... }:
with lib;

let
  cfg = config.roles.zeroconf;
in {
  options.roles.zeroconf = {
    enable = mkEnableOption "Enable Zeroconf";
  };

  config = mkIf cfg.enable {
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      ipv4 = true;
      publish = {
        enable = true;
        addresses = true;
        domain = true;
        hinfo = true;
        userServices = true;
      };
    };
  };
}