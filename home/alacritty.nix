{
  lib,
  pkgs,
  config,
  ...
}:

{
  programs.alacritty = {
    enable = true;

    settings = {
      general.live_config_reload = true;

      terminal.shell.program = config.shellPath;

      selection = {
        save_to_clipboard = false;
        semantic_escape_chars = ",│`|:\"' ()[]{}<>\t";
      };

      window = {
        opacity = 1.0;
        decorations_theme_variant = "Dark";
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

      colors = {
        primary = {
          background = "#1e2127";
          foreground = "#abb2bf";
        };
        normal = {
          black = "#1e2127";
          red = "#e06c75";
          green = "#98c379";
          yellow = "#d19a66";
          blue = "#61afef";
          magenta = "#c678dd";
          cyan = "#56b6c2";
          white = "#abb2bf";
        };
        bright = {
          black = "#5c6370";
          red = "#e06c75";
          green = "#98c379";
          yellow = "#d19a66";
          blue = "#61afef";
          magenta = "#c678dd";
          cyan = "#56b6c2";
          white = "#ffffff";
        };
        dim = {
          black = "#1e2127";
          red = "#e06c75";
          green = "#98c379";
          yellow = "#d19a66";
          blue = "#61afef";
          magenta = "#c678dd";
          cyan = "#56b6c2";
          white = "#828791";
        };
      };

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
}
