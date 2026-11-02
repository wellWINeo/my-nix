{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.software.kaiten-cli;
  skillNames = [
    "kaiten-cli-heavy-data"
    "kaiten-cli-metrics"
    "kaiten-cli-mutations"
  ];
in
{
  options.software.kaiten-cli.enable = lib.mkEnableOption "Kaiten CLI";

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.kaiten-cli ];

    codingAgents.skills.sources.kaiten-cli = {
      input = "kaiten-cli";
      subdir = "skills";
    };

    programs.agent-skills.skills.explicit = lib.genAttrs skillNames (name: {
      from = "kaiten-cli";
      path = name;
      agents = [ "agents" ];
    });
  };
}
