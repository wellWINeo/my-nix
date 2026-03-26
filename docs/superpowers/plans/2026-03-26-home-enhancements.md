# Home Management Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add alacritty theme support via a `software` options namespace and support multiple home-manager configurations keyed by `user@hostname`.

**Architecture:** Convert hardcoded alacritty config into a NixOS-style options module under `home/software/alacritty/` with `enable` and `theme` options. Themes live in a separate attrset file. The flake outputs multiple `homeConfigurations` keyed by `user@hostname`, each enabling and configuring software modules.

**Tech Stack:** Nix, home-manager, NixOS module system (`mkOption`, `mkEnableOption`, `mkIf`)

**Spec:** `docs/superpowers/specs/2026-03-26-home-enhancements-design.md`

---

### Task 1: Create alacritty themes file

**Files:**
- Create: `home/software/alacritty/themes.nix`

- [ ] **Step 1: Create `home/software/alacritty/themes.nix`**

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

- [ ] **Step 2: Commit**

```bash
git add home/software/alacritty/themes.nix
git commit -m "feat(home): add alacritty theme definitions"
```

---

### Task 2: Create alacritty software module

**Files:**
- Create: `home/software/alacritty/default.nix`

- [ ] **Step 1: Create `home/software/alacritty/default.nix`**

This module defines options and, when enabled, configures alacritty with the selected theme and all non-color settings from the old `home/alacritty.nix`.

```nix
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
```

- [ ] **Step 2: Commit**

```bash
git add home/software/alacritty/default.nix
git commit -m "feat(home): add alacritty software module with theme and enable options"
```

---

### Task 3: Update home/default.nix and delete old alacritty.nix

**Files:**
- Modify: `home/default.nix:11-13` (imports section)
- Delete: `home/alacritty.nix`

- [ ] **Step 1: Update imports in `home/default.nix`**

Replace `./alacritty.nix` with `./software/alacritty` in the imports list:

```nix
  imports = [
    ./software/alacritty
    ./tmux.nix
  ];
```

- [ ] **Step 2: Delete `home/alacritty.nix`**

```bash
git rm home/alacritty.nix
```

- [ ] **Step 3: Commit**

```bash
git add home/default.nix
git commit -m "refactor(home): replace alacritty.nix with software module"
```

---

### Task 4: Update flake.nix with multiple home configurations

**Files:**
- Modify: `flake.nix:75-79` (homeConfigurations section)

- [ ] **Step 1: Replace the single homeConfiguration**

Replace lines 75-79 in `flake.nix`:

```nix
      # standalone home-manager for macOS
      homeConfigurations."o__ni" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgsFor.aarch64-darwin;
        modules = [ ./home ];
      };
```

With:

```nix
      # standalone home-manager for macOS
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

- [ ] **Step 2: Commit**

```bash
git add flake.nix
git commit -m "feat: add multiple home configurations keyed by user@hostname"
```

---

### Task 5: Update Makefile targets

**Files:**
- Modify: `Makefile:48-49` (apply-home target)

- [ ] **Step 1: Replace `apply-home` target**

Replace:

```makefile
apply-home:
	nix run 'path:.#homeConfigurations.o__ni.activationPackage'
```

With:

```makefile
apply\:home:
	nix run "path:.#homeConfigurations.\"$$(whoami)@$$(hostname)\".activationPackage"

apply\:home\:%:
	nix run "path:.#homeConfigurations.\"$*\".activationPackage"
```

- [ ] **Step 2: Commit**

```bash
git add Makefile
git commit -m "feat: replace apply-home with apply:home and apply:home:<name> targets"
```

---

### Task 6: Validate with nix flake check

- [ ] **Step 1: Format all nix files**

```bash
make fmt
```

- [ ] **Step 2: Run flake check**

```bash
nix flake check 'path:.' --all-systems
```

Expected: no errors.

- [ ] **Step 3: Dry-run the home activation for current machine**

```bash
make apply:home
```

Expected: home-manager activates successfully with the alacritty config using the correct theme for the current hostname.

- [ ] **Step 4: Commit any formatting changes**

```bash
git add -A
git commit -m "chore: format nix files"
```
