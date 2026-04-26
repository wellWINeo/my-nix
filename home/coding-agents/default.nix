{ lib, config, ... }:

let
  cfg = config.codingAgents;

  toolOpts = parentEnable: {
    enable = lib.mkEnableOption "asset deployment for this coding-agent tool";
    instructions = lib.mkOption {
      type = lib.types.bool;
      default = parentEnable;
      description = "Deploy global instructions (CLAUDE.md / AGENTS.md) for this tool.";
    };
    skills = lib.mkOption {
      type = lib.types.bool;
      default = parentEnable;
      description = "Deploy the skills bundle for this tool.";
    };
    agents = lib.mkOption {
      type = lib.types.bool;
      default = parentEnable;
      description = "Deploy registered agent files for this tool.";
    };
  };
in
{
  imports = [
    ./instructions
    ./agents
    ./skills
  ];

  options.codingAgents = {
    claude = toolOpts cfg.claude.enable;
    opencode = toolOpts cfg.opencode.enable;
  };
}
