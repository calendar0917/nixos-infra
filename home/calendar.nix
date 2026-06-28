{ config, lib, pkgs, ... }:
let
  out = config.lib.file.mkOutOfStoreSymlink;
in {
  home.username = "calendar";
  home.homeDirectory = "/home/calendar";

  # 改了即时生效，不用 rebuild
  xdg.configFile = {
    "niri/config.kdl".source = out "${config.home.homeDirectory}/nixos/modules/features/niri/config.kdl";
    "niri/dms".source       = out "${config.home.homeDirectory}/nixos/modules/features/niri/dms";
    fish.source              = out "${config.home.homeDirectory}/nixos/dotfiles/fish/.config/fish";
    kitty.source             = out "${config.home.homeDirectory}/nixos/dotfiles/kitty/.config/kitty";
    kanshi.source            = out "${config.home.homeDirectory}/nixos/dotfiles/kanshi/.config/kanshi";
    nvim.source              = out "${config.home.homeDirectory}/nixos/dotfiles/nvim/.config/nvim";
  };

  programs.tmux = {
    enable = true;
    mouse = true;
    keyMode = "vi";
    terminal = "screen-256color";
    baseIndex = 1;

    extraConfig = ''
      # 分屏键改成更直觉的 | 和 -
      bind | split-window -h
      bind - split-window -v
      # 关闭窗口后自动重排编号
      set -g renumber-windows on
      # esc 延迟问题（vim 用户必加）
      set -sg escape-time 0
    '';
  };

  home.packages = with pkgs; [
    hugo
    taskwarrior3
    taskwarrior-tui
  ];

  home.stateVersion = "25.05";
}
