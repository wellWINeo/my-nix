{ lib, pkgs, ... }:

{
  imports = [
    ./alacritty.nix
    ./tmux.nix
  ];

  home.username = "o__ni";
  home.homeDirectory = if pkgs.stdenv.isDarwin then "/Users/o__ni" else "/home/o__ni";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;
}
