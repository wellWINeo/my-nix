{ pkgs, ... }:

{
  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-curses;
  };

  environment.systemPackages = with pkgs; [
    gnumake
    pinentry-curses
  ];

  services.openssh.enable = true;
}
