# Home-Manager Integration Design

## Summary

Add home-manager support to the flake with reusable home modules for alacritty and tmux. Shared modules live in `home/`, used by both NixOS machines (via NixOS module) and macOS (via standalone `homeConfigurations` output).

## Goals

- Declaratively manage alacritty and tmux configs via home-manager native Nix options
- Reuse the same home modules across NixOS servers and standalone macOS
- Follow existing project conventions (nixfmt-rfc-style, camelCase options)

## Non-Goals

- nix-darwin integration (future work)
- Fish shell configuration via home-manager
- Per-program enable/disable toggles
- Any other programs beyond alacritty and tmux

## Architecture

### New flake input

```nix
home-manager.url = "github:nix-community/home-manager/release-25.11";
home-manager.inputs.nixpkgs.follows = "nixpkgs";
```

Follows nixpkgs to avoid duplicate nixpkgs evaluations.

### New directory: `home/`

```
home/
├── default.nix      # Root module — imports alacritty and tmux, sets home basics
├── alacritty.nix    # programs.alacritty native options
└── tmux.nix         # programs.tmux native options + extraConfig
```

### Flake outputs

**Standalone macOS** — new `homeConfigurations` output:

```nix
homeConfigurations."o__ni" = home-manager.lib.homeManagerConfiguration {
  pkgs = nixpkgs.legacyPackages.aarch64-darwin;
  modules = [ ./home ];
};
```

**NixOS machines** — add to each machine's imports:

```nix
home-manager.nixosModules.home-manager
{
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.o__ni = import ../../home;
}
```

This ensures `home/default.nix` is the single source of truth for both contexts.

## Module Details

### home/default.nix

Root module that:
- Imports `./alacritty.nix` and `./tmux.nix`
- Sets `home.username = "o__ni"`
- Sets `home.homeDirectory` conditionally: `/Users/o__ni` on Darwin, `/home/o__ni` on Linux (using `pkgs.stdenv.isDarwin`)
- Sets `home.stateVersion = "25.11"`
- Sets `programs.home-manager.enable = true`

### home/alacritty.nix

Translates the existing `~/.config/alacritty/alacritty.toml` into `programs.alacritty` native options.

**Configuration mapped:**

| Setting | Value |
|---------|-------|
| `programs.alacritty.enable` | `true` |
| Shell program | Fish (platform-dependent path) |
| Font family | Fira Code |
| Font size | 14.0 |
| Window decorations | Buttonless (macOS only) |
| Window theme variant | Dark |
| Window option_as_alt | Both (macOS only) |
| Window padding | x=6, y=6 |
| Window opacity | 1.0 |
| Window dynamic_padding | true |
| Colors | One Dark scheme (primary, normal, bright, dim — all 24 values) |
| Scrolling history | 10000 |
| Scrolling multiplier | 3 |
| Selection save_to_clipboard | false |
| Selection semantic_escape_chars | `,│\`\|:\"' ()[]{}<>\t` |
| Keyboard bindings | Ctrl+Shift+V (Paste), Ctrl+Shift+C (Copy), Ctrl+Shift+N (SpawnNewInstance) |
| Env TERM | xterm-256color |
| live_config_reload | true |

**Platform handling:** `decorations = "Buttonless"` and `option_as_alt = "Both"` are macOS-specific. Use `lib.mkIf pkgs.stdenv.isDarwin` to conditionally set these, with sensible Linux defaults (or omit them).

**Shell path:** On macOS standalone, fish is at `/opt/homebrew/bin/fish`. On NixOS, fish would come from nixpkgs. Use `pkgs.stdenv.isDarwin` to select the right path.

### home/tmux.nix

Translates the existing `~/.config/tmux/tmux.conf` using a mix of native `programs.tmux` options and `extraConfig`.

**Native options:**

| Option | Value |
|--------|-------|
| `programs.tmux.enable` | `true` |
| `programs.tmux.prefix` | `M-space` |
| `programs.tmux.baseIndex` | `1` |
| `programs.tmux.mouse` | `true` |
| `programs.tmux.keyMode` | `vi` |
| `programs.tmux.shell` | Fish path (platform-dependent) |

**extraConfig** (settings without native HM options):

```
# Pane base index
setw -g pane-base-index 1

# Status bar styling
set -g status-style bg=black,fg=white
set -g status-left ''
set -g status-right ''
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

# Config editing
bind e new-window -n "tmux-config" "vim ~/.tmux.conf"
```

**Shell path:** Same platform-dependent logic as alacritty — `/opt/homebrew/bin/fish` on macOS, fish from nixpkgs on NixOS.

## Files Changed

| File | Change |
|------|--------|
| `flake.nix` | Add home-manager input, add `homeConfigurations` output, add HM NixOS module to each machine |
| `home/default.nix` | New — root home module |
| `home/alacritty.nix` | New — alacritty config |
| `home/tmux.nix` | New — tmux config |

## Testing

- `nix flake check --all-systems` must pass
- `nixfmt .` must produce no changes
- Verify standalone build: `nix build .#homeConfigurations.o__ni.activationPackage` (on macOS)
- Verify NixOS eval doesn't fail (via flake check)
