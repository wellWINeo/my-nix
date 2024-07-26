{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.doh;
in {
  options.roles.doh.enable = mkEnableOption "Enable DNS over HTTPS";

  config = mkIf cfg.enable {
    services.https-dns-proxy = {
      enable = true;
      provider.kind = "cloudflare";
      preferIPv4 = true;
      port = 8053;
      extraArgs = [ "-v info" "-i 3600" ];
    };
  };
}