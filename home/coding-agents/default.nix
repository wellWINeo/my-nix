{ lib, config, ... }:

let
  cfg = config.codingAgents;
in
{
  options.codingAgents = {
    claude.enable = lib.mkEnableOption "global CLAUDE.md for Claude Code";
    opencode.enable = lib.mkEnableOption "global AGENTS.md for opencode";
  };

  config = {
    home.file.".claude/CLAUDE.md" = lib.mkIf cfg.claude.enable {
      source = ./AGENTS.md;
    };
    home.file.".config/opencode/AGENTS.md" = lib.mkIf cfg.opencode.enable {
      source = ./AGENTS.md;
    };
  };
}
