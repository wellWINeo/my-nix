{ lib, config, ... }:

let
  cfg = config.codingAgents;

  targetPaths = {
    claude = name: ".claude/agents/${name}.md";
    opencode = name: ".config/opencode/agents/${name}.md";
  };

  isTargetEnabled = target: cfg.${target}.enable && cfg.${target}.agents;

  expandDefinition =
    name: def:
    let
      activeTargets = lib.filter (t: builtins.elem t def.targets && isTargetEnabled t) (
        lib.attrNames targetPaths
      );
    in
    lib.listToAttrs (
      map (t: {
        name = targetPaths.${t} name;
        value = {
          source = def.source;
        };
      }) activeTargets
    );

  expandedFiles = lib.foldl' (
    acc: name: acc // expandDefinition name cfg.agents.definitions.${name}
  ) { } (lib.attrNames cfg.agents.definitions);
in
{
  options.codingAgents.agents.definitions = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.path;
            description = "Path to the agent's .md source file.";
          };
          targets = lib.mkOption {
            type = lib.types.listOf (
              lib.types.enum [
                "claude"
                "opencode"
              ]
            );
            default = [
              "claude"
              "opencode"
            ];
            description = "Coding-agent tools that should receive this agent.";
          };
        };
      }
    );
    default = { };
    description = "Registered agent files. Each entry is deployed to its declared targets.";
  };

  config.home.file = expandedFiles;

}
