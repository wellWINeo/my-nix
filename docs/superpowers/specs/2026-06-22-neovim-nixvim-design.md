# Neovim IDE Configuration via nixvim

## Overview

Turn the minimal `software.neovim` home-manager module into a full,
declarative IDE built on [nixvim](https://github.com/nix-community/nixvim).
Adds LSP, tree-sitter, a sidebar, autocompletion, telescope, the One Dark
colorscheme (matching the existing tmux/alacritty theme), and a curated set of
"must-have" plugins drawn from the gentleman.dots (LazyVim) suite.

Scope guarantees:

- Only the two **darwin home configurations** (`o__ni@Stepans-MacBook-Pro`,
  `o__ni@DodoBook.local`) are affected. The NixOS servers (`nixpi`, `mokosh`,
  `veles`, `buyan`) keep plain `neovim` from `users/o__ni` — untouched.
- The colorscheme follows each machine's `theme.name`, so Stepans stays One
  Dark and DodoBook stays light. Neither machine is forced off its theme.
- LSP servers are provisioned **hybrid**: ambient servers bundled centrally,
  project-coupled servers resolved from each project's devShell `PATH`.

## 1. Flake wiring

### Input

Add to `flake.nix` `inputs`:

```nix
nixvim = {
  url = "github:nix-community/nixvim/nixos-26.05";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

The branch must match the `nixos-26.05` / `home-manager release-26.05` pins
already used. Verify `nixos-26.05` exists at implementation time; if not, pin a
revision compatible with 26.05.

### Module import

Import the nixvim home module in **both** darwin `homeConfigurations`, next to
the existing `agent-skills` module:

```nix
modules = [
  inputs.agent-skills.homeManagerModules.default
  inputs.nixvim.homeModules.nixvim
  ./home
  { ... existing per-machine options ... }
];
```

No change to the NixOS `nixosConfigurations`. This is the "don't affect other
machines" guarantee.

## 2. Theme integration

Extend `home/themes/default.nix`. Add a `neovim` block to each theme, mirroring
the existing `tmux` / `alacritty` blocks:

```nix
"one-dark" = {
  # ... existing alacritty, tmux ...
  neovim = {
    colorscheme = "onedark";
    style = "dark";
  };
};

"one-half-light" = {
  # ... existing alacritty, tmux ...
  neovim = {
    colorscheme = "onedark";
    style = "light";
  };
};
```

The neovim module reads `config.theme.colors.neovim`, exactly like
`home/tmux.nix` reads `config.theme.colors.tmux`. navarasu's `onedark.nvim`
shares the One Dark palette family used by the alacritty/tmux colors, and its
`style` option supports both `dark` and `light`, so a single colorscheme covers
both machines and the editor matches the terminal. `lualine` and `bufferline`
inherit the active colorscheme.

## 3. Neovim module rewrite

Rewrite `home/software/neovim/default.nix`. Keep the existing
`options.software.neovim.enable` gate and the `config = lib.mkIf cfg.enable`
wrapper. Replace the `programs.neovim` block with `programs.nixvim`.

### Base options / keymaps

Preserve current behavior:

```nix
programs.nixvim = {
  enable = true;
  defaultEditor = true;

  globals.mapleader = " ";

  opts = {
    termguicolors = true;
    number = true;
    tabstop = 4;
    expandtab = true;
    shiftwidth = 4;
  };

  # transparent background (replaces the old highlight Normal cmd)
  extraConfigLua = ''
    vim.cmd [[highlight Normal guibg=NONE ctermbg=NONE]]
  '';
};
```

### Colorscheme

```nix
colorschemes.onedark = {
  enable = true;
  settings.style = config.theme.colors.neovim.style;
};
```

### LSP — hybrid provisioning

`plugins.lsp.enable = true` (nvim-lspconfig). Server definitions are always
registered so a server attaches the moment its binary is on `PATH`.

**Ambient — bundled (real nix package):** edited everywhere, no project deps.

- `nixd` — Nix (matches the repo devShell's choice)
- `lua_ls` — Lua / Neovim config
- `html`, `cssls` — standalone, no project dependency graph

**Project-coupled — `package = null` (resolved from devShell `PATH`):** need the
project's toolchain/dependencies to be accurate.

- `ts_ls` — TypeScript / JavaScript
- `pyright` — Python

```nix
plugins.lsp = {
  enable = true;
  servers = {
    nixd.enable = true;
    lua_ls.enable = true;
    html.enable = true;
    cssls.enable = true;

    ts_ls = { enable = true; package = null; };
    pyright = { enable = true; package = null; };
  };
};
```

Add `plugins.direnv.enable = true` (direnv.vim integration) so opening a file in
a project directory loads its `.envrc`, putting the devShell-provided servers on
`PATH` without relaunching nvim.

### Formatting

`plugins.conform-nvim` with format-on-save:

- `nixfmt` (nix), `stylua` (lua), `prettierd` (web), `ruff` (python)

### Tree-sitter

`plugins.treesitter.enable = true` + `plugins.treesitter-textobjects.enable =
true`. Grammars (installed via nix, no runtime download):

`nix`, `lua`, `typescript`, `tsx`, `javascript`, `html`, `css`, `python`,
`markdown`, `markdown_inline`, `bash`, `json`, `yaml`, `toml`.

### Autocompletion

`plugins.blink-cmp` (gentleman.dots' choice; modern). Sources: LSP, buffer,
path. Wires into the LSP capabilities.

### Fuzzy finder (telescope)

`plugins.telescope.enable = true` with the native sorter
`plugins.telescope.extensions.fzf-native.enable = true`. Keymaps:

- `<leader>ff` — find files
- `<leader>fg` — live grep
- `<leader>fb` — buffers

### Sidebar

`plugins.neo-tree.enable = true`. Keymap `<leader>e` — toggle.

## 4. Must-have companion plugins

Curated from gentleman.dots (LazyVim) — the high-value, non-AI essentials.
nixvim has first-class modules for each:

| Plugin | Purpose |
|--------|---------|
| `which-key` | keybinding discovery |
| `lualine` | statusline (inherits onedark) |
| `bufferline` | buffer tabs |
| `gitsigns` | git gutter / hunks |
| `flash` | motions / jump |
| `todo-comments` | highlight TODO/FIXME/etc. |
| `trouble` | diagnostics / quickfix list |
| `nvim-autopairs` | auto-close pairs |
| `web-devicons` | icons (dependency of tree/telescope/lualine) |
| `indent-blankline` | indent guides |
| `tmux-navigator` | seamless tmux ↔ nvim pane navigation |
| `oil` | edit the filesystem as a buffer |
| `render-markdown` | in-buffer markdown rendering |

**Deliberately excluded** (non-essential / gimmicky; easy to add later):
precognition, smear-cursor, twilight, vim-be-good, screenkey, noice, and all AI
plugins (already managed via `codingAgents`).

## 5. Verification

- `make fmt` — `nixfmt` all `.nix` files.
- `make check` — `nix flake check 'path:.' --all-systems`.
- `make apply:home` — applies the current machine
  (`o__ni@Stepans-MacBook-Pro`). Launch `nvim` and confirm:
  - colorscheme is One Dark (dark), transparent background intact;
  - `:checkhealth` is clean;
  - LSP attaches: open a `.nix` file (nixd) and a `.lua` file (lua_ls)
    anywhere; open a `.ts`/`.py` file inside a project devShell and confirm
    `ts_ls`/`pyright` attach (and do **not** attach outside one);
  - telescope (`<leader>ff`, `<leader>fg`), neo-tree (`<leader>e`),
    completion (blink) all work.
- Eval the other Mac without applying:
  `nix build .#homeConfigurations."o__ni@DodoBook.local".activationPackage`
  — builds and selects the light onedark variant.

## 6. Files changed

| File | Action |
|------|--------|
| `flake.nix` | Add `nixvim` input; import `nixvim.homeModules.nixvim` in both darwin home configs |
| `home/themes/default.nix` | Add `neovim` block (`colorscheme`, `style`) to each theme |
| `home/software/neovim/default.nix` | Rewrite: `programs.neovim` → `programs.nixvim` with all plugins above |
| `flake.lock` | Updated by `nix flake lock` to add the nixvim input |

## Notes / decisions

- nixvim adds a sizable closure on first build (tree-sitter grammars + bundled
  LSP servers). Acceptable on a Mac.
- Autocompletion uses `blink-cmp`, not `nvim-cmp`.
- `html`/`cssls` are bundled (ambient) rather than devShell-provisioned because
  they do not consume a project dependency graph; only `ts_ls`/`pyright` are
  left to devShells.
- Exact nixvim option names (e.g. `plugins.direnv`, `ts_ls`, `nixd`) are
  verified against the pinned nixvim branch during implementation.
