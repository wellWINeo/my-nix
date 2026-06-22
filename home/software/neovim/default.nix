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
    };
  };
}
