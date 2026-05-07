# Global Theme System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace per-app theme selection with a home-level `theme.name` option so all programs (Alacritty, tmux) use consistent colors.

**Architecture:** New `home/themes/default.nix` module defines `theme.name` and exposes `theme.colors` as read-only per-app color maps. Alacritty and tmux modules consume their respective color maps. Flake.nix sets `theme.name` instead of `software.alacritty.theme`.

**Tech Stack:** Nix, home-manager, tmux, Alacritty

---

### Task 1: Create the global theme module

**Files:**
- Create: `home/themes/default.nix`

**Step 1: Create directory**

Run: `mkdir -p home/themes`

**Step 2: Write the theme module**

Create `home/themes/default.nix` with the full theme definitions:

```nix
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
```

**Step 3: Verify syntax**

Run: `nixfmt home/themes/default.nix`

**Step 4: Commit**

```bash
git add home/themes/default.nix
git commit -m "feat: add home-level theme module with one-dark and one-half-light"
```

---

### Task 2: Register the theme module in home imports

**Files:**
- Modify: `home/default.nix:11-16`

**Step 1: Add `./themes` to the imports list**

In `home/default.nix`, add `./themes` to the `imports` list, before the existing entries:

```nix
  imports = [
    ./themes
    ./coding-agents
    ./software/alacritty
    ./software/neovim
    ./tmux.nix
  ];
```

**Step 2: Verify no eval errors yet (won't fully work until Task 3+4)**

No validation command yet — the Alacritty module still references its own theme option which will conflict. This is expected.

**Step 3: Commit**

```bash
git add home/default.nix
git commit -m "feat: register global theme module in home imports"
```

---

### Task 3: Migrate Alacritty to use global theme

**Files:**
- Modify: `home/software/alacritty/default.nix` (full rewrite of option/config sections)
- Delete: `home/software/alacritty/themes.nix`

**Step 1: Rewrite `home/software/alacritty/default.nix`**

Remove the `theme` option, the local `themes` import, and `selectedTheme` let-binding.
Replace with reading from `config.theme.colors.alacritty`:

```nix
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
```

**Step 2: Delete the old themes file**

Run: `rm home/software/alacritty/themes.nix`

**Step 3: Verify formatting**

Run: `nixfmt home/software/alacritty/default.nix`

**Step 4: Commit**

```bash
git add home/software/alacritty/default.nix
git rm home/software/alacritty/themes.nix
git commit -m "feat: migrate alacritty to global theme system"
```

---

### Task 4: Migrate tmux to use global theme

**Files:**
- Modify: `home/tmux.nix` (lines 1, 12-28)

**Step 1: Rewrite `home/tmux.nix`**

Add a `let` binding for `tmuxTheme = config.theme.colors.tmux;` and replace
the hardcoded color values in `extraConfig`:

```nix
{ pkgs, config, ... }:

let
  tmuxTheme = config.theme.colors.tmux;
in
{
  programs.tmux = {
    enable = true;
    prefix = "M-space";
    baseIndex = 1;
    mouse = true;
    keyMode = "vi";
    shell = config.shellPath;

    extraConfig = ''
      # Pane base index
      setw -g pane-base-index 1

      # Status bar styling
      set -g status-style bg=${tmuxTheme.statusBg},fg=${tmuxTheme.statusFg}
      set -g status-left ""
      set -g status-right ""
      set -g status-justify left
      set -g window-status-format ' #I:#W '
      set -g window-status-current-format ' [#I:#W] '
      set -g window-status-current-style bg=${tmuxTheme.currentWindowBg},fg=${tmuxTheme.currentWindowFg}
      set -g status-interval 1

      # Pane focus hooks (dim inactive panes)
      set-hook -g pane-focus-out 'select-pane -P bg=${tmuxTheme.dimPaneBg},fg=${tmuxTheme.dimPaneFg}'
      set-hook -g pane-focus-in 'select-pane -P bg=default,fg=default'

      # Split pane bindings
      bind | split-window -h
      bind - split-window -v
      unbind '"'
      unbind %

      # Vim-style pane navigation
      bind h select-pane -L
      bind j select-pane -D
      bind k select-pane -U
      bind l select-pane -R

      # Pane resizing
      bind H resize-pane -L 5
      bind J resize-pane -D 5
      bind K resize-pane -U 5
      bind L resize-pane -R 5

      # Reload config
      bind r source-file ~/.config/tmux/tmux.conf \; display "Config reloaded!"

      # Copy mode vi bindings
      bind Escape copy-mode
      bind -T copy-mode-vi v send-keys -X begin-selection
      bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel

      # Kill pane/window
      bind x kill-pane
      bind X confirm-before -p "kill window? (y/n)" kill-window

      # Window navigation
      bind -n M-C-Left previous-window
      bind -n M-C-Right next-window
      bind -n M-1 select-window -t 1
      bind -n M-2 select-window -t 2
      bind -n M-3 select-window -t 3
      bind -n M-4 select-window -t 4
    '';
  };
}
```

**Step 2: Verify formatting**

Run: `nixfmt home/tmux.nix`

**Step 3: Commit**

```bash
git add home/tmux.nix
git commit -m "feat: migrate tmux to global theme system"
```

---

### Task 5: Update flake.nix to use `theme.name`

**Files:**
- Modify: `flake.nix:104-105` (Stepans-MacBook-Pro config)
- Modify: `flake.nix:120-121` (DodoBook config)

**Step 1: Replace `software.alacritty.theme` with `theme.name`**

For `o__ni@Stepans-MacBook-Pro` (lines 103-109), change:
```nix
# BEFORE:
software.alacritty.enable = true;
software.alacritty.theme = "one-dark";
```
to:
```nix
# AFTER:
software.alacritty.enable = true;
theme.name = "one-dark";
```

For `o__ni@DodoBook.local` (lines 119-125), change:
```nix
# BEFORE:
software.alacritty.enable = true;
software.alacritty.theme = "one-half-light";
```
to:
```nix
# AFTER:
software.alacritty.enable = true;
theme.name = "one-half-light";
```

**Step 2: Verify formatting**

Run: `nixfmt flake.nix`

**Step 3: Commit**

```bash
git add flake.nix
git commit -m "feat: switch flake.nix from per-app theme to global theme.name"
```

---

### Task 6: Validate the full build

**Step 1: Ensure dummy secrets are set up**

Run: `make setup-dummy-secrets`

**Step 2: Run flake check**

Run: `make check`

Expected: passes without errors.

**Step 3: Build the DodoBook home-manager config (dry run)**

Run: `nix build 'path:.#homeConfigurations."o__ni@DodoBook.local".activationPackage' --no-link`

Expected: succeeds.

**Step 4: Build the Stepans-MacBook-Pro home-manager config (dry run)**

Run: `nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link`

Expected: succeeds.

If any build fails, debug the evaluation error and fix the offending module before proceeding.

---

### Task 7: Final format check

Run: `nixfmt .`

Then commit any formatting changes if needed.
