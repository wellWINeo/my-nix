# Home Management Enhancements

## Overview

Enhance the home-manager configuration with two changes:
1. Alacritty theme support via a `software` options namespace
2. Multiple home configurations keyed by `user@hostname`

## 1. Home module structure

```
home/
├── default.nix              # common config, imports software modules
├── software/
│   ├── alacritty/
│   │   ├── default.nix      # options: enable, theme; all non-color settings
│   │   └── themes.nix       # plain attrset of theme definitions
│   └── tmux.nix             # unchanged for now, future software candidate
```

`home/default.nix` imports `./software/alacritty`. It keeps common config (username, homeDirectory, stateVersion, shellPath option). The `./alacritty.nix` import is removed — replaced by `./software/alacritty`.

## 2. Alacritty software module

### `home/software/alacritty/default.nix`

Defines two options under `software.alacritty`:

- **`enable`** — `mkEnableOption "alacritty terminal emulator"`, default false
- **`theme`** — `mkOption { type = types.enum (builtins.attrNames themes); default = "one-dark"; }` where `themes` is imported from `./themes.nix`

When enabled (`config = mkIf cfg.enable { ... }`), sets:
- `programs.alacritty.enable = true`
- `home.packages = [ pkgs.fira-code ]` — installs the Fira Code font via Nix (copied to `~/Library/Fonts/HomeManager/` on macOS)
- `programs.alacritty.settings.colors` = the selected theme's `colors` attrset
- `programs.alacritty.settings.window.decorations_theme_variant` = the selected theme's `decorations_theme_variant`
- All existing non-color, non-decoration settings (font, keybindings, window padding/opacity/dynamic_padding, scrolling, selection, terminal shell, env, general.live_config_reload) remain in this file unchanged
- Darwin-specific settings (`decorations = "Buttonless"`, `option_as_alt = "Both"`) remain via `lib.optionalAttrs`

### `home/software/alacritty/themes.nix`

A plain attrset, no function arguments:

```nix
{
  "one-dark" = {
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

  "one-half-light" = {
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
}
```

Each theme carries only the color sections it needs. `one-dark` includes `dim`; `one-half-light` includes `cursor` and `selection` but no `dim`.

## 3. Flake changes

Replace the single `homeConfigurations."o__ni"` with two entries:

```nix
homeConfigurations."o__ni@Stepans-Macbook-Pro" = inputs.home-manager.lib.homeManagerConfiguration {
  pkgs = nixpkgsFor.aarch64-darwin;
  modules = [
    ./home
    {
      software.alacritty.enable = true;
      software.alacritty.theme = "one-dark";
    }
  ];
};

homeConfigurations."o__ni@DodoBook" = inputs.home-manager.lib.homeManagerConfiguration {
  pkgs = nixpkgsFor.aarch64-darwin;
  modules = [
    ./home
    {
      software.alacritty.enable = true;
      software.alacritty.theme = "one-half-light";
    }
  ];
};
```

Both are `aarch64-darwin`. Each machine enables the software it needs and configures it inline.

## 4. Makefile changes

Remove the `apply-home` target. Add two new targets:

```makefile
apply\:home:
	nix run "path:.#homeConfigurations.\"$$(whoami)@$$(hostname)\".activationPackage"

apply\:home\:%:
	nix run "path:.#homeConfigurations.\"$*\".activationPackage"
```

- `make apply:home` — auto-detects `user@hostname` from the current machine
- `make apply:home:o__ni@DodoBook` — applies a specific named configuration

## 5. Files changed

| File | Action |
|------|--------|
| `home/default.nix` | Remove `./alacritty.nix` import, add `./software/alacritty` import |
| `home/alacritty.nix` | Delete (replaced by software module) |
| `home/software/alacritty/default.nix` | New — options + all non-color settings |
| `home/software/alacritty/themes.nix` | New — theme definitions attrset |
| `flake.nix` | Replace single homeConfiguration with two keyed by user@hostname |
| `Makefile` | Replace `apply-home` with `apply:home` and `apply:home:%` targets |
