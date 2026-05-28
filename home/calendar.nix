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

  # ---------- fish ----------
  xdg.configFile."fish".source = ../modules/features/fish;

  # 不在 HM 管理：
  #   nvim → LazyVim 自管理

  home.packages = with pkgs; [
  ];

  home.stateVersion = "25.05";
}
