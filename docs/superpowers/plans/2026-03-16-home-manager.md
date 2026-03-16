# Home-Manager Integration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add home-manager to the flake with reusable alacritty and tmux modules shared across NixOS machines and standalone macOS.

**Architecture:** New `home/` top-level directory with three modules (default.nix, alacritty.nix, tmux.nix). Flake gets home-manager input, `homeConfigurations` output for macOS, and NixOS module integration for all three machines.

**Tech Stack:** Nix, home-manager (release-25.11), nixpkgs (nixos-25.11)

**Spec:** `docs/superpowers/specs/2026-03-16-home-manager-design.md`

---

## Chunk 1: Flake Input and Home Modules

### Task 1: Add home-manager flake input

**Files:**
- Modify: `flake.nix:4-7` (inputs block)

- [ ] **Step 1: Add home-manager input to flake.nix**

In `flake.nix`, add the home-manager input after nixos-hardware:

```nix
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
```

- [ ] **Step 2: Run flake lock update**

Run: `nix flake lock`
Expected: `flake.lock` updated with home-manager entry (new input is picked up automatically)

- [ ] **Step 3: Verify flake still evaluates**

Run: `nix flake check 'path:.' --all-systems 2>&1 | head -20`
Expected: No errors (warnings OK)

- [ ] **Step 4: Format and commit**

```bash
nixfmt flake.nix
git add flake.nix flake.lock
git commit -m "feat: add home-manager flake input"
```

---

### Task 2: Create home/default.nix

**Files:**
- Create: `home/default.nix`

- [ ] **Step 1: Create home/default.nix**

```nix
{ lib, pkgs, ... }:

{
  imports = [
    ./alacritty.nix
    ./tmux.nix
  ];

  home.username = "o__ni";
  home.homeDirectory =
    if pkgs.stdenv.isDarwin then "/Users/o__ni" else "/home/o__ni";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;
}
```

- [ ] **Step 2: Format**

Run: `nixfmt home/default.nix`

---

### Task 3: Create home/alacritty.nix

**Files:**
- Create: `home/alacritty.nix`

`programs.alacritty.settings` is a freeform attribute set that maps directly to alacritty's TOML structure. macOS-specific settings (`decorations`, `option_as_alt`) are conditionally applied via `lib.optionalAttrs` (not `mkIf`, since this is a plain attrset, not a module option).

- [ ] **Step 1: Create home/alacritty.nix**

```nix
{ lib, pkgs, ... }:

{
  programs.alacritty = {
    enable = true;

    settings = {
      general.live_config_reload = true;

      terminal.shell.program = "${pkgs.fish}/bin/fish";

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
      } // lib.optionalAttrs pkgs.stdenv.isDarwin {
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
```

- [ ] **Step 2: Format**

Run: `nixfmt home/alacritty.nix`

---

### Task 4: Create home/tmux.nix

**Files:**
- Create: `home/tmux.nix`

`programs.tmux` has native options for common settings. Everything else goes in `extraConfig`. The vestigial `bind e` (edit config in vim) is removed per spec. The `bind r` reload is kept pointing at the XDG path since home-manager symlinks the config there.

- [ ] **Step 1: Create home/tmux.nix**

```nix
{ pkgs, ... }:

{
  programs.tmux = {
    enable = true;
    prefix = "M-space";
    baseIndex = 1;
    mouse = true;
    keyMode = "vi";
    shell = "${pkgs.fish}/bin/fish";

    extraConfig = ''
      # Pane base index
      setw -g pane-base-index 1

      # Status bar styling
      set -g status-style bg=black,fg=white
      set -g status-left ""
      set -g status-right ""
      set -g status-justify left
      set -g window-status-format ' #I:#W '
      set -g window-status-current-format ' [#I:#W] '
      set -g window-status-current-style bg=white,fg=black
      set -g status-interval 1

      # Pane focus hooks (dim inactive panes)
      set-hook -g pane-focus-out 'select-pane -P bg=colour233,fg=colour10'
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

- [ ] **Step 2: Format**

Run: `nixfmt home/tmux.nix`

- [ ] **Step 3: Commit all home modules**

```bash
git add home/
git commit -m "feat: add home-manager modules for alacritty and tmux"
```

---

## Chunk 2: Flake Integration and Docs

### Task 5: Add homeConfigurations output to flake.nix

**Files:**
- Modify: `flake.nix:28-75` (outputs block)

- [ ] **Step 1: Add standalone homeConfigurations output**

Add this block inside the `in { ... }` section of flake.nix, after the `nixosConfigurations` and before `devShells`:

```nix
      # standalone home-manager for macOS
      homeConfigurations."o__ni" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgsFor.aarch64-darwin;
        modules = [ ./home ];
      };
```

Note: uses `nixpkgsFor` (not `nixpkgs.legacyPackages`) to include overlays consistently with the rest of the flake.

- [ ] **Step 2: Add home-manager NixOS module to each machine**

For each of the three machine configs in flake.nix (`nixpi`, `mokosh`, `veles`), add two entries to the `modules` list:

```nix
      nixosConfigurations."nixpi" = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = inputs;
        modules = [
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.o__ni = import ./home;
          }
          ./machines/nixpi
          ./users/o__ni
        ];
      };
```

Repeat the same pattern for `mokosh` and `veles`. Note: from `flake.nix` the import path is `./home` (not `../../home` — that's only from within `machines/`).

- [ ] **Step 3: Format and verify**

Run: `nixfmt flake.nix && nix flake check 'path:.' --all-systems 2>&1 | head -20`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add flake.nix
git commit -m "feat: integrate home-manager into flake outputs and NixOS machines"
```

---

### Task 6: Update AGENTS.md

**Files:**
- Modify: `AGENTS.md:125-136` (directory purposes table)

- [ ] **Step 1: Add home/ to directory purposes table**

Add a row to the directory purposes table in `AGENTS.md`:

```markdown
| `home/` | Home-manager modules (user environment config) |
```

- [ ] **Step 2: Add home-manager build command to build/test section**

Add to the build commands section:

```bash
# Build standalone home-manager config (macOS)
nix build 'path:.#homeConfigurations.o__ni.activationPackage'
```

- [ ] **Step 3: Format and commit**

```bash
nixfmt . 2>/dev/null; true
git add AGENTS.md
git commit -m "docs: add home/ directory and home-manager commands to AGENTS.md"
```

---

### Note: Before first activation

On first `home-manager switch` (or `nixos-rebuild switch` on NixOS machines), existing dotfiles at `~/.config/alacritty/alacritty.toml` and `~/.config/tmux/tmux.conf` must be backed up and removed, otherwise activation will fail with "file already exists" errors.

### Task 7: Validate everything

- [ ] **Step 1: Run full flake check**

Run: `nix flake check 'path:.' --all-systems`
Expected: No errors

- [ ] **Step 2: Run formatter**

Run: `nixfmt .`
Expected: No changes (already formatted)

- [ ] **Step 3: Build standalone home-manager config**

Run: `nix build 'path:.#homeConfigurations.o__ni.activationPackage' --dry-run`
Expected: Build plan shown, no errors. (Use `--dry-run` to avoid full build if not on macOS or if packages aren't cached.)

- [ ] **Step 4: Verify git status is clean**

Run: `git status`
Expected: Clean working tree, all changes committed.
