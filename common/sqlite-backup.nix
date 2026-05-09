{
  lib,
  pkgs,
  name,
  databases,
  backupDir,
  user,
  group,
  extraPaths ? [ ],
}:
let
  backupCmds = lib.concatMapStringsSep "\n" (
    db:
    let
      dbName = baseNameOf db;
    in
    ''
      sqlite3 "${db}" ".backup '${backupDir}/${dbName}'"
    ''
  ) databases;
  extraPathsCmd = lib.optionalString (extraPaths != [ ]) ''
    ${pkgs.rsync}/bin/rsync -a ${lib.concatStringsSep " " extraPaths} ${backupDir}/
  '';
in
{
  systemd.tmpfiles.rules = [
    "d ${backupDir} 0750 ${user} ${group} -"
  ];

  systemd.services."backup-${name}" = {
    description = "Backup ${name}";
    path = [ pkgs.sqlite ];

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = group;
      ExecStart = pkgs.writeShellScript "backup-${name}" ''
        set -euo pipefail
        ${extraPathsCmd}
        ${backupCmds}
      '';
    };
  };

  systemd.timers."backup-${name}" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "23:00";
      Persistent = true;
    };
  };
}
