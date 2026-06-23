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

        telescope = {
          enable = true;
          extensions.fzf-native.enable = true;
        };

        neo-tree.enable = true;

        which-key.enable = true;
        lualine.enable = true;
        bufferline.enable = true;
        gitsigns.enable = true;
        flash.enable = true;
        todo-comments.enable = true;
        trouble.enable = true;
        nvim-autopairs.enable = true;
        web-devicons.enable = true;
        indent-blankline.enable = true;
        tmux-navigator.enable = true;
        oil.enable = true;
        render-markdown.enable = true;

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

      keymaps = [
        {
          mode = "n";
          key = "<leader>ff";
          action = "<cmd>Telescope find_files<CR>";
          options.desc = "Find files";
        }
        {
          mode = "n";
          key = "<leader>fg";
          action = "<cmd>Telescope live_grep<CR>";
          options.desc = "Live grep";
        }
        {
          mode = "n";
          key = "<leader>fb";
          action = "<cmd>Telescope buffers<CR>";
          options.desc = "Buffers";
        }
        {
          mode = "n";
          key = "<leader>e";
          action = "<cmd>Neotree toggle<CR>";
          options.desc = "Toggle file tree";
        }
      ];
    };
  };
}
