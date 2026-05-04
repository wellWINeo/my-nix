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
