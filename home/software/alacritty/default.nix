{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.software.alacritty;
  alacrittyTheme = config.theme.colors.alacritty;
in
{
  options.software.alacritty = {
    enable = lib.mkEnableOption "alacritty terminal emulator";
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
          decorations_theme_variant = alacrittyTheme.decorations_theme_variant;
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

        colors = alacrittyTheme.colors;

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
