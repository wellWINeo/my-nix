{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.software.neovim;
in
{
  options.software.neovim = {
    enable = lib.mkEnableOption "neovim editor";
  };

  config = lib.mkIf cfg.enable {
    programs.neovim = {
      enable = true;
      defaultEditor = true;

      extraLuaConfig = ''
        vim.opt.termguicolors = true
        vim.opt.number = true

        vim.opt.tabstop = 4
        vim.opt.expandtab = true
        vim.opt.shiftwidth = 4

        vim.cmd [[highlight Normal guibg=NONE ctermbg=NONE]]
      '';
    };
  };
}
