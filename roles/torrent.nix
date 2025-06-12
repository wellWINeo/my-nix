# transmission

{
  config,
  pkgs,
  lib,
  ...
}:
with lib;

let
  defineMediaUser = import ../common/define-media-user.nix;

  torrentUser = "torrent";
  mediaGroup = "media";
  cfg = config.roles.torrent;
  baseDir = "/mnt/storage/Public/Torrents";
in
{
  options.roles.torrent.enable = mkEnableOption "Enable Transmission";

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ transmission_4 ];

    users.groups.${mediaGroup} = { };
    users.users.${torrentUser} = {
      isNormalUser = false;
      isSystemUser = true;

      group = mediaGroup;
    };

    # services.transmission = {
    #   enable = true;
    #   package = pkgs.transmission_4;
    #   openFirewall = true;
    #   openRPCPort = true;
    #   downloadDirPermissions = "777";
    #   user = torrentUser;
    #   group = "media";
    #   settings = {
    #     incomplete-dir = "${baseDir}/Incomplete";
    #     download-dir = "${baseDir}/Downloads";
    #     rpc-bind-address = "0.0.0.0";
    #     rpc-whitelist = "127.0.0.1,192.168.0.*,10.20.0.*";
    #   };
    # };
  };
}
