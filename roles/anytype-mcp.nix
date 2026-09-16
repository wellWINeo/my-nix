{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.anytype-mcp;
  hostname = "anytype.${cfg.baseDomain}";
  cliPort = 31012;
  bridgePort = 8118;
  cliDataDir = "/var/lib/anytype";
  bridgeDataDir = "/var/lib/anytype-mcp";
  uploadDir = "${bridgeDataDir}/uploads";
in
{
  options.roles.anytype-mcp = {
    enable = mkEnableOption "public Anytype MCP service";
    baseDomain = mkOption {
      type = types.str;
      description = "Base domain used for the public Anytype MCP hostname";
    };
  };

  config = mkIf cfg.enable {
    users.groups.anytype = { };
    users.users.anytype = {
      isSystemUser = true;
      group = "anytype";
      home = cliDataDir;
      createHome = true;
    };

    systemd.services.anytype-cli = {
      description = "Anytype headless CLI";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        HOME = cliDataDir;
        DATA_PATH = cliDataDir;
      };
      serviceConfig = {
        User = "anytype";
        Group = "anytype";
        StateDirectory = "anytype";
        WorkingDirectory = cliDataDir;
        ExecStart = "${pkgs.anytype-cli}/bin/anytype-cli serve";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };

    environment.systemPackages = [ pkgs.anytype-cli ];

    users.groups.anytype-mcp = { };
    users.users.anytype-mcp = {
      isSystemUser = true;
      group = "anytype-mcp";
      home = bridgeDataDir;
      createHome = true;
    };

    systemd.tmpfiles.rules = [
      "d ${uploadDir} 0700 anytype-mcp anytype-mcp -"
    ];

    systemd.services.anytype-mcp-proxy = {
      description = "Anytype Streamable HTTP MCP bridge";
      after = [ "anytype-cli.service" ];
      requires = [ "anytype-cli.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        ANYTYPE_API_BASE_URL = "http://127.0.0.1:${toString cliPort}";
      };
      serviceConfig = {
        User = "anytype-mcp";
        Group = "anytype-mcp";
        StateDirectory = "anytype-mcp";
        WorkingDirectory = bridgeDataDir;
        EnvironmentFile = "/etc/nixos/secrets/anytype-mcp.env";
        ExecStart = "${pkgs.mcp-proxy}/bin/mcp-proxy --host 127.0.0.1 --port ${toString bridgePort} --pass-environment -- ${pkgs.anytype-mcp}/bin/anytype-mcp";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        InaccessiblePaths = [
          "/etc/nixos/secrets"
          cliDataDir
          "/home"
          "/root"
        ];
        ReadWritePaths = [ uploadDir ];
      };
    };

    roles.backup.paths = [ cliDataDir ];

    services.nginx.virtualHosts.${hostname} = {
      forceSSL = true;
      enableACME = false;
      sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";

      locations."= /mcp" = {
        proxyPass = "http://127.0.0.1:${toString bridgePort}";
        recommendedProxySettings = true;
        extraConfig = ''
          include /etc/nixos/secrets/anytype-mcp-nginx-auth.conf;
          proxy_buffering off;
          proxy_read_timeout 300s;
        '';
      };

      locations."/".extraConfig = ''
        return 404;
      '';
    };
  };
}
