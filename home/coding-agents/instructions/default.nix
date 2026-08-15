{ lib, config, ... }:

let
  cfg = config.codingAgents;
  enableClaude = cfg.claude.enable && cfg.claude.instructions;
  enableShared =
    (cfg.opencode.enable && cfg.opencode.instructions) || (cfg.codex.enable && cfg.codex.instructions);
in
{
  config = {
    home.file.".claude/CLAUDE.md" = lib.mkIf enableClaude {
      source = ./AGENTS.md;
    };
    home.file.".agents/AGENTS.md" = lib.mkIf enableShared {
      source = ./AGENTS.md;
    };
  };
}
