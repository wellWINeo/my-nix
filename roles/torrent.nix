# transmission

{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.torrent;
  baseDir = "/mnt/storage/Public/Torrents";
in {
  options.roles.torrent.enable = mkEnableOption "Enable Transmission";

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ transmission ];

    services.transmission = {
      enable = true;
      openFirewall = true;
      openRPCPort = true;
      settings = {
        incomplete-dir = "${baseDir}/Incomplete";
        download-dir = "${baseDir}/Downloads";
        rpc-bind-address = "0.0.0.0";
      };
    };
  };
}