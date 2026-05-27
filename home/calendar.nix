{ config, pkgs, ... }:

{
  home.username = "calendar";
  home.homeDirectory = "/home/calendar";

  # ---------- niri（主配置 + dms 子配置）----------
  xdg.configFile."niri/config.kdl".source = ../modules/features/niri/config.kdl;
  xdg.configFile."niri/dms".source = ../modules/features/niri/dms;

  # ---------- kitty ----------
  xdg.configFile."kitty".source = ../modules/features/kitty;

  # ---------- kanshi ----------
  xdg.configFile."kanshi/config".source = ../modules/features/kanshi/config;

  # ---------- fish ----------
  programs.fish.enable = true;

  # 以下不在 HM 管理范围，直接留 ~/.config/ 下：
  #   nvim  → LazyVim 自管理插件，不适合声明式
  #   fish  → config.fish 已手动维护，Arch/NixOS 共用

  home.packages = with pkgs; [
  ];

  home.stateVersion = "25.05";
}
