{
  lib,
  config,
  ...
}:

let
  themes = {
    "one-dark" = {
      alacritty = {
        decorations_theme_variant = "Dark";
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
      };
      tmux = {
        statusBg = "black";
        statusFg = "white";
        currentWindowBg = "white";
        currentWindowFg = "black";
        dimPaneBg = "colour233";
        dimPaneFg = "colour10";
      };
    };

    "one-half-light" = {
      alacritty = {
        decorations_theme_variant = "Light";
        colors = {
          primary = {
            foreground = "#383a42";
            background = "#fafafa";
          };
          cursor = {
            text = "#383a42";
            cursor = "#bfceff";
          };
          selection = {
            text = "#383a42";
            background = "#bfceff";
          };
          normal = {
            black = "#383a42";
            red = "#e45649";
            green = "#50a14f";
            yellow = "#c18401";
            blue = "#0184bc";
            magenta = "#a626a4";
            cyan = "#0997b3";
            white = "#fafafa";
          };
          bright = {
            black = "#4f525e";
            red = "#e06c75";
            green = "#98c379";
            yellow = "#e5c07b";
            blue = "#61afef";
            magenta = "#c678dd";
            cyan = "#56b6c2";
            white = "#ffffff";
          };
        };
      };
      tmux = {
        statusBg = "#fafafa";
        statusFg = "#383a42";
        currentWindowBg = "#383a42";
        currentWindowFg = "#fafafa";
        dimPaneBg = "#e5e5e5";
        dimPaneFg = "#a0a1a7";
      };
    };
  };
in
{
  options.theme = {
    name = lib.mkOption {
      type = lib.types.enum (builtins.attrNames themes);
      default = "one-dark";
      description = "Global color theme name. All themed applications derive their colors from this.";
    };

    colors = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = themes.${config.theme.name};
      description = "Resolved per-app color maps for the selected theme.";
    };
  };
}
