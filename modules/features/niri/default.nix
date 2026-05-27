{ config, lib, pkgs, ... }:

{
  # ---------- KDL 原生配置 ----------
  environment.etc."niri/config.kdl".source = ./config.kdl;

  # ---------- niri 环境变量 ----------
  systemd.user.services.niri.environment = {
    GDK_BACKEND = "wayland";
    XDG_CURRENT_DESKTOP = "niri";
    XDG_SESSION_TYPE = "wayland";
  };

  # ---------- niri 周边工具 ----------
  environment.systemPackages = with pkgs; [
    # 终端 / 文件管理
    thunar
    # 显示器管理
    kanshi
    # 锁屏
    swaylock
    # 壁纸
    swaybg
    waypaper
    # 截图
    grim
    slurp
    # 剪贴板
    wl-clipboard
    cliphist
    clipse
    # 亮度 / 音量
    brightnessctl
    playerctl
    # 网络托盘
    networkmanagerapplet
  ];

  # ---------- polkit 认证代理 ----------
  systemd.user.services.polkit-gnome-authentication-agent-1 = {
    description = "polkit-gnome-authentication-agent-1";
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };

  security.polkit.enable = true;
}
