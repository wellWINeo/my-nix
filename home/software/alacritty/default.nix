{
  lib,
  pkgs,
  config,
  ...
}:

let
  themes = import ./themes.nix;
  cfg = config.software.alacritty;
  selectedTheme = themes.${cfg.theme};
in
{
  options.software.alacritty = {
    enable = lib.mkEnableOption "alacritty terminal emulator";

    theme = lib.mkOption {
      type = lib.types.enum (builtins.attrNames themes);
      default = "one-dark";
      description = "Alacritty color theme to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.fira-code ];

    programs.alacritty = {
      enable = true;

      settings = {
        general.live_config_reload = true;

        terminal.shell.program = config.shellPath;

        selection = {
          save_to_clipboard = false;
          semantic_escape_chars = '',│`|:"' ()[]{}<>\t'';
        };

        window = {
          opacity = 1.0;
          decorations_theme_variant = selectedTheme.decorations_theme_variant;
          dynamic_padding = true;
          padding = {
            x = 6;
            y = 6;
          };
        }
        // lib.optionalAttrs pkgs.stdenv.isDarwin {
          decorations = "Buttonless";
          option_as_alt = "Both";
        };

        font = {
          size = 14.0;
          normal.family = "Fira Code";
          bold.family = "Fira Code";
          italic.family = "Fira Code";
          bold_italic.family = "Fira Code";
        };

        colors = selectedTheme.colors;

        scrolling = {
          history = 10000;
          multiplier = 3;
        };

        keyboard.bindings = [
          {
            key = "V";
            mods = "Control|Shift";
            action = "Paste";
          }
          {
            key = "C";
            mods = "Control|Shift";
            action = "Copy";
          }
          {
            key = "N";
            mods = "Control|Shift";
            action = "SpawnNewInstance";
          }
        ];

        env.TERM = "xterm-256color";
      };
    };
  };
}
