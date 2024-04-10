{ config, pkgs, lib, ... }:

let 
  hostname = "nixpi";
in {
  imports = [ 
    ../../roles/share.nix
    ../../hardware/rpi4.nix
  ];

  networking = {
    hostName = hostname;
    wireless.enable = false;    
  };

  roles.share = {
    hostname = hostname;
    enable = true;
    enableTimeMachine = true;
  };

  services.openssh.enable = true;

  system.stateVersion = "23.11";
}