{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.roles.rss.summarizer;
in
{
  options.roles.rss.summarizer = {
    enable = mkEnableOption "Miniflux RSS Summarizer";
  };

  config = mkIf cfg.enable {
  };
}
