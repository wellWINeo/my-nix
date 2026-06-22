{
  lib,
  config,
  ...
}:

let
  cfg = config.software.neovim;
  nvimTheme = config.theme.colors.neovim;
in
{
  options.software.neovim = {
    enable = lib.mkEnableOption "neovim editor";
  };

  config = lib.mkIf cfg.enable {
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

      extraConfigLua = ''
        vim.cmd [[highlight Normal guibg=NONE ctermbg=NONE]]
      '';

      colorschemes.onedark = {
        enable = true;
        settings.style = nvimTheme.style;
      };

      plugins = {
        lsp = {
          enable = true;
          servers = {
            # Ambient — bundled, no project deps
            nixd.enable = true;
            lua_ls.enable = true;
            html.enable = true;
            cssls.enable = true;

            # Project-coupled — resolved from the project's devShell PATH
            ts_ls = {
              enable = true;
              package = null;
            };
            pyright = {
              enable = true;
              package = null;
            };
          };
        };

        treesitter = {
          enable = true;
          settings.ensure_installed = [
            "nix"
            "lua"
            "typescript"
            "tsx"
            "javascript"
            "html"
            "css"
            "python"
            "markdown"
            "markdown_inline"
            "bash"
            "json"
            "yaml"
            "toml"
          ];
        };
        treesitter-textobjects.enable = true;

        blink-cmp = {
          enable = true;
          settings.sources.default = [
            "lsp"
            "path"
            "buffer"
          ];
        };

        # Load a project's .envrc inside nvim so devShell servers land on PATH
        direnv.enable = true;

        # Format on save
        conform-nvim = {
          enable = true;
          autoInstall.enable = true;
          settings = {
            format_on_save = {
              timeout_ms = 500;
              lsp_format = "fallback";
            };
            formatters_by_ft = {
              nix = [ "nixfmt" ];
              lua = [ "stylua" ];
              javascript = [ "prettierd" ];
              typescript = [ "prettierd" ];
              typescriptreact = [ "prettierd" ];
              html = [ "prettierd" ];
              css = [ "prettierd" ];
              python = [ "ruff_format" ];
            };
          };
        };
      };
    };
  };
}
