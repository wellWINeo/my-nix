{ config, pkgs, lib, ... }:
with lib;
with types;

let
  cfg = config.roles.backup-dirs;
in {
  options.servicesbackup-dirs = {
    enable = mkEnableOption "Enable backup to S3";
    dirs = mkOption {
      type = listOf path;
      example = [ "/opt/backup" ];
      description = "List of paths to backup";
    };
    interval = mkOption {
      type = str;
      default = "weekly";
      example = "weekly";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.enable -> (cfg.dirs != []);
        message = "Backup enabled, but no directories to backup";
      }
    ];

    systemd.services = let 
      toService = dir: let
        dir' = utils.escapeSystemdPath dir;
      in nameValuePair "backup-${dir'}" {
        conflicts = [ "shutdown.target" "sleep.target" ];
        before = [ "shutdown.target" "sleep.target" ];
      };
    in listToAttrs (map toService cfg.dirs);
  };
}