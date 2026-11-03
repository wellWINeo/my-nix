{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.software.buildin-cli;

  skillTransform =
    { original, ... }:
    let
      replacements = [
        {
          old = ''
            The CLI source repository may be private. Do not ask the user to clone source
            code before using the CLI. Install or update the released binary from the
            official Buildin CDN only after the user explicitly approves it.

          '';
          new = ''
            The CLI source repository may be private. Do not ask the user to clone source
            code before using the CLI. This installation is managed by Nix: do not use a
            vendor installer or the CLI self-updater. Update the pinned Nix package release
            and checksum instead.

          '';
        }
        {
          old = ''
            If the CLI is missing or outdated, explain that the official installer is
            available at `https://cdn.buildin.ai/buildin-cli/install` (or
            `https://cdn.buildin.ai/buildin-cli/install.ps1` on Windows). Do not download,
            execute, or update it until the user explicitly approves that action.

          '';
          new = ''
            If the CLI is missing or outdated, treat this as a Nix profile or package-pin
            issue. Do not download or run a vendor installer; update the pinned Nix package
            version and checksum through the repository's declarative workflow.

          '';
        }
        {
          old = ''
            After approval, use only the official URL and a user-approved version. Download
            an installer to a temporary file; show its source, version, and SHA-256 hash;
            and compare it with an official checksum or signature before execution. If no
            official integrity data is available, stop and offer manual installation rather
            than executing an unverified installer. Remove temporary installer files after
            the attempt.

          '';
          new = ''
            Do not download or execute a vendor installer for this Nix-managed installation.
            Change the Nix package pin and checksum through the repository's approved
            declarative workflow instead.

          '';
        }
        {
          old = ''
            If a command is missing or help output looks stale, explain that `buildin update`
            can update the CLI and wait for explicit user approval before running it.

          '';
          new = ''
            If a command is missing or help output looks stale, treat it as a Nix package-pin
            issue. Do not use a vendor self-updater; update the pinned Nix package version
            and checksum through the repository's declarative workflow.

          '';
        }
        {
          old = ''
            Useful install overrides:

            - `BUILDIN_INSTALL_DIR` - install directory.
            - `BUILDIN_VERSION` - exact release version, such as `v0.1.10`.
            - `BUILDIN_CLI_RELEASE_BASE_URL` - alternate release base URL for tests.

          '';
          new = ''
            Installer-specific environment overrides do not apply to this Nix-managed
            installation; Nix controls the executable path and pinned release.

          '';
        }
        {
          old = ''
            - Command not found: offer the official installer at `https://cdn.buildin.ai/buildin-cli/install` and wait for explicit approval before using it.
            - Unknown command or option: ask approval before running `buildin update`, then run `buildin <command> --help`.
          '';
          new = ''
            - Command not found or unknown command: inspect `buildin --help`; if the installed CLI is missing or stale, update the pinned Nix package version and checksum through the repository's declarative workflow. Do not use a vendor installer or self-updater.
          '';
        }
      ];
      replace =
        text:
        { old, new }:
        assert lib.hasInfix old text;
        builtins.replaceStrings [ old ] [ new ] text;
      transformed = builtins.foldl' replace original replacements;
      forbidden = [
        "https://cdn.buildin.ai/buildin-cli/install"
        "BUILDIN_INSTALL_DIR"
        "BUILDIN_CLI_RELEASE_BASE_URL"
        "buildin update"
        "offer the official installer"
        "download an installer"
      ];
    in
    assert builtins.all (text: !(lib.hasInfix text transformed)) forbidden;
    assert lib.hasInfix "managed by Nix" transformed;
    assert lib.hasInfix "pinned Nix package version and checksum" transformed;
    transformed;
in
{
  options.software.buildin-cli.enable = lib.mkEnableOption "Buildin CLI";

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.buildin-cli ];

    codingAgents.skills.sources.buildin-skill = {
      input = "buildin-skill";
      subdir = "skills";
    };

    programs.agent-skills.skills.explicit.buildin-cli = {
      from = "buildin-skill";
      path = "buildin-cli";
      agents = [ "agents" ];
      transform = skillTransform;
    };
  };
}
