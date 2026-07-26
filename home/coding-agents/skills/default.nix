{ lib, config, ... }:

let
  cfg = config.codingAgents;

  claudeEnabled = cfg.claude.enable && cfg.claude.skills;
  sharedEnabled =
    (cfg.opencode.enable && cfg.opencode.skills) || (cfg.codex.enable && cfg.codex.skills);
  anyTargetEnabled = claudeEnabled || sharedEnabled;
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
    # NOTE: no `idPrefix` on any source. Claude Code only discovers personal
    # skills one level deep (~/.claude/skills/<skill>/SKILL.md); an idPrefix
    # nests them as ~/.claude/skills/<prefix>/<skill>/ which is never scanned.
    # Skill names are unique across these sources, so a flat layout is safe.
    codingAgents.skills.sources = {
      own = {
        path = ./own;
      };
      superpowers = {
        input = "superpowers";
        subdir = "skills";
      };
      dotnet = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet/skills";
      };
      dotnet-advanced = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-advanced/skills";
      };
      dotnet-data = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-data/skills";
      };
      dotnet-diag = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-diag/skills";
      };
      dotnet-msbuild = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-msbuild/skills";
      };
      dotnet-nuget = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-nuget/skills";
      };
      dotnet-upgrade = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-upgrade/skills";
      };
      dotnet-ai = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-ai/skills";
      };
      dotnet-test = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-test/skills";
      };
      dotnet-aspnetcore = {
        input = "dotnet-skills";
        subdir = "plugins/dotnet-aspnetcore/skills";
      };
      mattpocock-engineering = {
        input = "mattpocock-skills";
        subdir = "skills/engineering";
        filter.maxDepth = 1;
      };
      mattpocock-productivity = {
        input = "mattpocock-skills";
        subdir = "skills/productivity";
        filter.maxDepth = 1;
      };
    };

    codingAgents.skills.enableAll = [
      "own"
      "superpowers"
      "mattpocock-engineering"
      "mattpocock-productivity"
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
      targets.agents.enable = sharedEnabled;
    };

    home.activation.removeLegacyAgentSkillTrees = lib.mkIf (cfg.opencode.enable || cfg.codex.enable) (
      lib.hm.dag.entryAfter
        ([ "writeBoundary" ] ++ lib.optional (config.home.activation ? "agent-skills") "agent-skills")
        ''
          is_nix_store_skill_tree() {
            local tree="$1"
            local entry target

            [[ -d "$tree" && ! -L "$tree" ]] || return 1

            if ! (
              set -o pipefail
              find "$tree" -mindepth 1 -maxdepth 1 -print0 |
                while IFS= read -r -d "" entry; do
                  [[ "$(basename "$entry")" == ".system" ]] && return 1
                  [[ -L "$entry" ]] || return 1
                  target="$(readlink -f "$entry" || true)"
                  [[ "$target" == /nix/store/* ]] || return 1
                done
            ); then
              return 1
            fi

            return 0
          }

          # TODO: remove this migration action after all supported hosts have
          # activated a generation using the shared ~/.agents skill target.
          for legacy in "$HOME/.config/opencode/skills" "''${CODEX_HOME:-$HOME/.codex}/skills"; do
            if is_nix_store_skill_tree "$legacy"; then
              run rm -rf "$legacy"
            fi
          done
        ''
    );
  };
}
