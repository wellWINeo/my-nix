{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.mail.dovecot;
in {
  options.roles.mail.dovecot = {
    enable = mkEnableOption "Enable Dovecot for mail server";
    domain = mkOption { type = types.str; };
  };

  config = mkIf cfg.enable {
    services.dovecot = {
      enable = true;
      settings = {
        protocols = "imap lmtp";
        
      };
    };
  };
}