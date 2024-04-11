# miniDLNA

{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.media;
in {
  options.roles.media.enable =  mkEnableOption "Enable miniDLNA";

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ minidlna ];

    services.minidlna = {
      enable = true;
      openFirewall = true;
      settings = {
        inotify = "yes";
        media_dir = [
          "V,/mnt/storage/Public/Media"
        ];
      };
    };
  };
}