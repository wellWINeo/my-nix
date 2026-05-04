{
  lib,
  pkgs,
  config,
  ...
}:

with lib;

{
  imports = [
    ./themes
    ./coding-agents
    ./software/alacritty
    ./software/neovim
    ./tmux.nix
  ];

  options.shellPath = mkOption {
    type = types.str;
    default = if pkgs.stdenv.isDarwin then "/opt/homebrew/bin/fish" else "${pkgs.fish}/bin/fish";
    description = "Path to the fish shell binary. Override if fish is installed outside of Nix (e.g. Homebrew on Intel Mac: /usr/local/bin/fish).";
  };

  config = {
    home.username = "o__ni";
    home.homeDirectory = if pkgs.stdenv.isDarwin then "/Users/o__ni" else "/home/o__ni";
    home.stateVersion = "25.11";

    programs.home-manager.enable = true;
  };
}
