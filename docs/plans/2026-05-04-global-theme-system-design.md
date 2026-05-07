# Global Theme System

## Problem

DodoBook uses Alacritty with the `one-half-light` theme (light background), but tmux
colors are hardcoded for a dark theme (`bg=black, fg=white`, dim panes with
`colour233`/`colour10`). This causes a jarring mismatch: dark tmux status bar on a
light terminal, and light-gray/green characters that are hard to read.

## Root Cause

Theme selection is per-app (`software.alacritty.theme`) with no mechanism for other
programs to react. Tmux in `home/tmux.nix` has no theme awareness at all.

## Design

Introduce a home-level `theme.name` option as the single source of truth. Each
software module reads application-specific color maps from `theme.colors.<app>`.

### Theme Module (`home/themes/default.nix`)

Defines `theme.name` (enum) and exposes `theme.colors` (read-only attrs) containing
per-app color maps for each theme:

```
themes."one-dark".alacritty   = { decorations_theme_variant, colors }
themes."one-dark".tmux        = { statusBg, statusFg, currentWindowBg, currentWindowFg, dimPaneBg, dimPaneFg }
themes."one-half-light".alacritty = { ... }
themes."one-half-light".tmux      = { ... }
```

Alacritty color values are preserved exactly as-is from the existing `themes.nix`.

### Consumer Changes

- **Alacritty**: remove `software.alacritty.theme` option; read from
  `config.theme.colors.alacritty`.
- **Tmux**: replace hardcoded colors in `extraConfig` with values from
  `config.theme.colors.tmux`.
- **Flake.nix**: replace `software.alacritty.theme` with `theme.name` in both
  `homeConfigurations`.

### Light Theme Tmux Colors

| Element | Value | Rationale |
|---------|-------|-----------|
| statusBg | `#fafafa` | matches Alacritty background |
| statusFg | `#383a42` | matches Alacritty foreground |
| currentWindowBg | `#383a42` | inverted for emphasis |
| currentWindowFg | `#fafafa` | inverted for emphasis |
| dimPaneBg | `#e5e5e5` | light gray for inactive panes |
| dimPaneFg | `#a0a1a7` | muted text for inactive panes |

### File Changes

| File | Action |
|------|--------|
| `home/themes/default.nix` | Create |
| `home/default.nix` | Add `./themes` to imports |
| `home/software/alacritty/default.nix` | Remove theme option, read from global theme |
| `home/software/alacritty/themes.nix` | Delete (absorbed into global theme) |
| `home/tmux.nix` | Replace hardcoded colors with theme values |
| `flake.nix` | Replace `software.alacritty.theme` with `theme.name` |

### Extensibility

Adding a new app (e.g. neovim theming) means adding a color map key under each
theme entry. Adding a new theme means adding a new entry to the `themes` attrset.
