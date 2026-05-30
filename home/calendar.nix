{ config, pkgs, cc-switch-cli, ... }:

{
  home.username = "calendar";
  home.homeDirectory = "/home/calendar";

  # ---------- niri（唯一由 HM 管理的配置）----------
  xdg.configFile."niri/config.kdl".source = ../modules/features/niri/config.kdl;
  xdg.configFile."niri/dms".source = ../modules/features/niri/dms;

  # 以下由 stow 管理（dotfiles/ 目录，改了立即生效）：
  #   kitty, kanshi, fish, nvim

  home.packages = with pkgs; [
    cc-switch-cli
    hugo
  ];

  home.stateVersion = "25.05";
}
