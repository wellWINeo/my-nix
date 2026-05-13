{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.backup;
in
{
  options.roles.backup = {
    enable = mkEnableOption "restic backups";

    paths = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    repository = mkOption {
      type = types.str;
      description = "Restic repository URL (e.g. s3:storage.yandexcloud.net/bucket/prefix)";
    };

    passwordFile = mkOption {
      type = types.str;
      description = "Path to restic repository password file";
    };

    environmentFile = mkOption {
      type = types.str;
      description = "Path to environment file (S3 credentials)";
    };

    exclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    pruneOpts = mkOption {
      type = types.listOf types.str;
      default = [
        "--keep-daily 7"
        "--keep-monthly 3"
      ];
    };

    extraBackupArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    frequency = mkOption {
      type = types.nullOr types.str;
      default = "00:00";
    };

    afterServices = mkOption {
      type = types.listOf types.str;
      default = [ ];
      internal = true;
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.paths != [ ];
        message = "roles.backup: at least one path must be set";
      }
    ];

    systemd.targets.backup = { };

    services.restic.backups.local = {
      repository = cfg.repository;
      passwordFile = cfg.passwordFile;
      environmentFile = cfg.environmentFile;
      initialize = true;
      inherit (cfg) paths exclude;
      extraBackupArgs = cfg.extraBackupArgs;
      pruneOpts = cfg.pruneOpts;
      timerConfig = mkIf (cfg.frequency != null) {
        OnCalendar = cfg.frequency;
        Persistent = true;
      };
    };

    systemd.services = {
      restic-backups-local = {
        after = [ "backup.target" ];
        requires = [ "backup.target" ];
      };
    }
    // listToAttrs (
      map (svc: {
        name = svc;
        value = {
          before = [ "backup.target" ];
          wantedBy = [ "backup.target" ];
        };
      }) cfg.afterServices
    );

    systemd.timers = listToAttrs (
      map (svc: {
        name = svc;
        value.enable = false;
      }) cfg.afterServices
    );
  };
}
