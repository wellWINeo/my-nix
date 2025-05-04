{ config, pkgs, lib, ... }:
with builtins;
with lib;

let
  cfg = config.roles.hardened;
in {
  options.roles.hardened = {
    enable = mkEnableOption "Enable server hardenings";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.fail2ban ];

    services.fail2ban = {
      enable = true;
      maxretry = 5;

      jails = let
        mkJail = filterName: {
          settings = {
            port = "http,https";
            filter = filterName;
          };
        };
        filterNames = [
          "nginx-http-auth"
          "nginx-bad-request"
          "nginx-error-common"
          "nginx-forbidden"
        ];
        nginxJails = listToAttrs (map (f: {
          name = f;
          value = mkJail f;
        }) filterNames);
      in 
        nginxJails 
        // 
        { 
          sshd = {
            settings = {
              port = "ssh";
              filter = "sshd";
              logpath = "/var/log/auth.log";
            };
          };  
        }
        //
        {
          nginx-botsearch = {
            settings = {
              port = "http,https";
              failregex = ''
                \[error\] \d+#\d+: \*\d+ (\S+ )?\"\S+\" (failed|is not found) \(2\: No such file or directory\), client\: <HOST>\, server\: \S*\, request: \"(GET|POST|HEAD) \/<block> \S+\"\, .*?$
              '';
              datepattern = ''
                {^LN-BEG}%%ExY(?P<_sep>[-/.])%%m(?P=_sep)%%d[T ]%%H:%%M:%%S(?:[.,]%%f)?(?:\s*%%z)?
                ^[^\[]*\[({DATE})
                {^LN-BEG} 
              '';
              journalmatch = "_SYSTEMD_UNIT=nginx.service + _COMM=nginx";
            };
          };
        };
    };
  };
}