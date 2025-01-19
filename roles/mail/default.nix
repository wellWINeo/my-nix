{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.mail;
in {
  options.roles.mail = {
    enable = mkEnableOption "Enable mail server";
    domain = mkOption { type = types.str; };
  };

  
}