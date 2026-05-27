{ config, pkgs, ... }:

{
  home.username = "calendar";
  home.homeDirectory = "/home/calendar";

  # ---------- niri KDL 配置（放在 ~/.config/niri/ 而非 /etc/niri/）----------
  xdg.configFile."niri/config.kdl".source = ../modules/features/niri/config.kdl;

  # ---------- fish shell 配置 ----------
  programs.fish.enable = true;

  # ---------- kitty 终端 ----------
  programs.kitty = {
    enable = true;
    settings = {
      font_family = "Maple Mono NF CN";
      font_size = 13;
      shell = "fish";
    };
  };

  # ---------- 用户级包（不影响系统）----------
  home.packages = with pkgs; [
    # 可以在这里加只有你需要的东西
  ];

  # ---------- 版本 ----------
  home.stateVersion = "25.05";
}
