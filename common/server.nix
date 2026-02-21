{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

{
  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-curses;
  };

  environment.systemPackages = with pkgs; [
    gnumake
    pinentry-curses
  ];

  # common nginx settings
  services.nginx = mkIf config.services.nginx.enable {
    group = "web";

    recommendedBrotliSettings = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;

    virtualHosts.default = {
      extraConfig = ''
        access_log syslog:server=unix:/dev/log;
      '';
    };
  };

  users.groups.web = {
    members =
      optional config.services.nginx.enable "nginx"
      ++ optional (config.security.acme.certs != { }) "acme";
  };

  services.openssh.enable = true;
}
