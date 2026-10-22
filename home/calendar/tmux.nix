{
  ...
}:

{
  # Small, plugin-free tmux configuration for SSH sessions. The terminal stays
  # usable across an SSH disconnect; it does not survive a reboot, and it is
  # not started automatically. `secureSocket` (the Home Manager default) puts
  # the socket under $XDG_RUNTIME_DIR, so it is not world-accessible.
  programs.tmux = {
    enable = true;
    terminal = "tmux-256color";
    historyLimit = 10000;
    baseIndex = 1;
    escapeTime = 10;
    keyMode = "vi";
    customPaneNavigationAndResize = true;
    mouse = true;
    focusEvents = true;
    aggressiveResize = true;
    clock24 = true;
    newSession = false;
    sensibleOnTop = false;

    extraConfig = ''
      # OSC 52: copy from a remote tmux pane to the local terminal's clipboard
      # when the outer terminal supports it. `allow-passthrough` also lets
      # applications such as image previews write through tmux.
      set -g set-clipboard on
      set -g allow-passthrough on
      set -g renumber-windows on

      # Keep new panes/windows in the current working directory.
      bind | split-window -h -c "#{pane_current_path}"
      bind - split-window -v -c "#{pane_current_path}"
      bind c new-window -c "#{pane_current_path}"
    '';
  };
}
