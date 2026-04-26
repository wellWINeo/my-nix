{ lib, config, ... }:

let
  cfg = config.codingAgents;
  enableClaude = cfg.claude.enable && cfg.claude.instructions;
  enableOpencode = cfg.opencode.enable && cfg.opencode.instructions;
in
{
  config = {
    home.file.".claude/CLAUDE.md" = lib.mkIf enableClaude {
      source = ./AGENTS.md;
    };
    home.file.".config/opencode/AGENTS.md" = lib.mkIf enableOpencode {
      source = ./AGENTS.md;
    };
  };
}
