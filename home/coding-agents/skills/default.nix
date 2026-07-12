{ lib, config, ... }:

let
  cfg = config.codingAgents;

  claudeEnabled = cfg.claude.enable && cfg.claude.skills;
  opencodeEnabled = cfg.opencode.enable && cfg.opencode.skills;
  codexEnabled = cfg.codex.enable && cfg.codex.skills;
  anyTargetEnabled = claudeEnabled || opencodeEnabled || codexEnabled;
  hasSelection = cfg.skills.enableAll != [ ] || cfg.skills.enable != [ ];
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
    enableAll = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Enable every discovered skill from the named sources. An empty list
        disables source-wide selection.
      '';
    };
  };

  config = {
    codingAgents.skills.sources = {
      own = {
        path = ./own;
        idPrefix = "own";
      };
      superpowers = {
        input = "superpowers";
        subdir = "skills";
        idPrefix = "superpowers";
      };
      dotnet = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet/skills";
        idPrefix = "dotnet";
      };
      dotnet-advanced = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-advanced/skills";
        idPrefix = "dotnet-advanced";
      };
      dotnet-data = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-data/skills";
        idPrefix = "dotnet-data";
      };
      dotnet-diag = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-diag/skills";
        idPrefix = "dotnet-diag";
      };
      dotnet-msbuild = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-msbuild/skills";
        idPrefix = "dotnet-msbuild";
      };
      dotnet-nuget = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-nuget/skills";
        idPrefix = "dotnet-nuget";
      };
      dotnet-upgrade = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-upgrade/skills";
        idPrefix = "dotnet-upgrade";
      };
      dotnet-ai = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-ai/skills";
        idPrefix = "dotnet-ai";
      };
      dotnet-test = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-test/skills";
        idPrefix = "dotnet-test";
      };
      dotnet-aspnetcore = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-aspnetcore/skills";
        idPrefix = "dotnet-aspnetcore";
      };
    };

    codingAgents.skills.enableAll = [
      "superpowers"
      "dotnet"
      "dotnet-advanced"
      "dotnet-data"
      "dotnet-diag"
      "dotnet-msbuild"
      "dotnet-nuget"
      "dotnet-upgrade"
      "dotnet-ai"
      "dotnet-test"
      "dotnet-aspnetcore"
    ];

    programs.agent-skills = lib.mkIf (anyTargetEnabled && hasSelection) {
      enable = true;
      sources = cfg.skills.sources;
      skills.enable = cfg.skills.enable;
      skills.enableAll = cfg.skills.enableAll;
      targets.claude.enable = claudeEnabled;
      targets.opencode = {
        enable = opencodeEnabled;
        dest = "$HOME/.config/opencode/skills";
        structure = "symlink-tree";
      };
      targets.codex.enable = codexEnabled;
    };
  };
}
