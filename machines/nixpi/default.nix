{ config, pkgs, lib, ... }:

let 
  hostname = "nixpi";
in {
  imports = [ 
    ../../roles/share.nix
    ../../hardware/rpi4.nix
  ];

  environment.systemPackages = with pkgs; [
    gnumake
    pinentry-curses
  ];

  programs.gnupg.agent = {
		enable = true;
		pinentryPackage = pkgs.pinentry-curses;
	};

  networking = {
    hostName = hostname;
    wireless.enable = false;    
    firewall = {
      enable = true;
      allowPing = true;
    };
  };

  roles.share = {
    hostname = hostname;
    enable = true;
    enableTimeMachine = true;
  };

  services.openssh.enable = true;

  system.stateVersion = "23.11";
}