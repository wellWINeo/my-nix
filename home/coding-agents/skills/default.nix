{ lib, config, ... }:

let
  cfg = config.codingAgents;

  claudeEnabled = cfg.claude.enable && cfg.claude.skills;
  opencodeEnabled = cfg.opencode.enable && cfg.opencode.skills;
  anyTargetEnabled = claudeEnabled || opencodeEnabled;
  hasAllowlist = cfg.skills.enable != [ ];
in
{
  options.codingAgents.skills = {
    sources = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          freeformType = (lib.types.attrsOf lib.types.unspecified);
        }
      );
      default = { };
      description = ''
        Skill catalog sources, forwarded to programs.agent-skills.sources.
        Each entry is either { input = "<flake-input-name>"; subdir = "..."; idPrefix = "..."; }
        or { path = ./relative-path; idPrefix = "..."; }.
      '';
    };
    enable = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Allowlist of skill IDs to bundle and deploy, of the form
        "<idPrefix>/<skill-name>". Skills not on the allowlist are not deployed.
      '';
    };
  };

  config = {
    codingAgents.skills.sources = {
      own = {
        path = ./own;
        idPrefix = "own";
      };
    };

    programs.agent-skills = lib.mkIf (anyTargetEnabled && hasAllowlist) {
      enable = true;
      sources = cfg.skills.sources;
      skills.enable = cfg.skills.enable;
      targets.claude.enable = claudeEnabled;
      targets.opencode = {
        enable = opencodeEnabled;
        dest = "$HOME/.config/opencode/skills";
        structure = "symlink-tree";
      };
    };
  };
}
