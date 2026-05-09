{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.rss;
  backupDir = "/var/backup/miniflux";
in
{
  config = mkIf cfg.enable {
    systemd.services.backup-miniflux = {
      description = "Backup Miniflux PostgreSQL database";
      path = [ pkgs.postgresql_16 ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "backup-miniflux" ''
          set -euo pipefail
          mkdir -p ${backupDir}
          pg_dump miniflux | gzip > ${backupDir}/miniflux.sql.gz.tmp
          mv ${backupDir}/miniflux.sql.gz.tmp ${backupDir}/miniflux.sql.gz
        '';
        User = "postgres";
        Group = "postgres";
      };
    };

    systemd.timers.backup-miniflux = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "23:00";
        Persistent = true;
      };
    };

    roles.backup.paths = [ backupDir ];
    roles.backup.afterServices = [ "backup-miniflux.service" ];
  };
}
