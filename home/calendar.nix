{ config, pkgs, ... }:

{
  home.username = "calendar";
  home.homeDirectory = "/home/calendar";

  # ---------- niri ----------
  xdg.configFile."niri/config.kdl".source = ../modules/features/niri/config.kdl;
  xdg.configFile."niri/dms".source = ../modules/features/niri/dms;

  # ---------- kitty ----------
  xdg.configFile."kitty".source = ../modules/features/kitty;

  # ---------- kanshi ----------
  xdg.configFile."kanshi/config".source = ../modules/features/kanshi/config;

  # 不在 HM 管理（手动维护，随时可改）：
  #   fish  → ~/.config/fish/    改得频繁，rebuild 太慢
  #   nvim  → LazyVim 自管理插件  和 HM 冲突

  home.packages = with pkgs; [
  ];

  home.stateVersion = "25.05";
}
