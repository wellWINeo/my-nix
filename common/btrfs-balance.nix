{ pkgs, lib, config, utils, ... }:
with lib;

let
  cfg = config.services.btrfs.balance;
in {
  options.services.btrfs.balance = {
    enable = mkEnableOption "Enable Btrfs balance";
    fileSystems = mkOption {
      type = types.listOf types.path;
      example = [ "/" ];
      description = "List of filesystems to balance";
    };
    interval = mkOption {
      type = types.str;
      default = "monthly";
      example = "weekly";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.enable -> (cfg.fileSystems != []);
        message = "Btrfs's balance enabled, but no filesystems provided";
      }
    ];

    systemd.timers = let
      balanceTimer = fs: let
          fs' = utils.escapeSystemdPath fs;
        in nameValuePair "btrfs-balance-${fs'}" {
          description = "regular btrfs balance timer on ${fs}";

          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.interval;
            AccuracySec = "1d";
            Persistent = true;
          };
      };
    in listToAttrs (map balanceTimer cfg.fileSystems);

    systemd.services = let
      balanceService = fs: let
          fs' = utils.escapeSystemdPath fs;
        in nameValuePair "btrfs-balance-${fs'}" {
          description = "btrfs balance on ${fs}";
          # balance prevents suspend2ram or proper shutdown
          conflicts = [ "shutdown.target" "sleep.target" ];
          before = [ "shutdown.target" "sleep.target" ];

          serviceConfig = {
            Type = "simple";
            Nice = 19;
            IOSchedulingClass = "idle";
            ExecStart = "${pkgs.btrfs-progs}/bin/btrfs balance start --full-balance ${fs}";
          };
        };
    in listToAttrs (map balanceService cfg.fileSystems);
  };
}