{ config, lib, pkgs, inputs, ... }:

let
  dms = pkgs.unstable.dms-shell;
  quickshell = pkgs.unstable.quickshell;
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  # ---------- 引导 ----------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ---------- 网络 ----------
  networking.hostName = "nixos";
  networking.networkmanager.enable = true;
  networking.firewall.enable = false;

  # ---------- 代理 ----------
  services.mihomo = {
    enable = true;
    configFile = ./clash.yaml;
  };

  # ---------- 时区 / 区域 ----------
  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "zh_CN.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "zh_CN.UTF-8";
    LC_IDENTIFICATION = "zh_CN.UTF-8";
    LC_MEASUREMENT = "zh_CN.UTF-8";
    LC_MONETARY = "zh_CN.UTF-8";
    LC_NAME = "zh_CN.UTF-8";
    LC_NUMERIC = "zh_CN.UTF-8";
    LC_PAPER = "zh_CN.UTF-8";
    LC_TELEPHONE = "zh_CN.UTF-8";
    LC_TIME = "zh_CN.UTF-8";
  };

  # ---------- 中文输入法 ----------
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.addons = with pkgs; [ fcitx5-rime ];
  };

  # ---------- 桌面环境 ----------
  security.polkit.enable = true;
  services.xserver.enable = true;

  services.xserver.xkb = {
    layout = "cn";
    variant = "";
  };

  # GDM + GNOME（来自 stable，保证 PAM 稳定）
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  # niri Wayland compositor（来自 unstable，版本够新）
  # 参考：https://wiki.nixos.org/wiki/Niri
  programs.niri = {
    enable = true;
    package = pkgs.unstable.niri;
  };

  # niri 官方 wiki：NixOS 会注入精简 PATH 覆盖 user-manager 的完整 PATH，
  # 导致 niri-session 找不到用户安装的程序。必须关闭。
  systemd.user.services.niri.enableDefaultPath = false;

  # niri + GNOME 共存时，文件选择器需要额外配置
  xdg.portal.config.niri = {
    "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
  };

  # niri 的 secret service（保存 WiFi 密码、SSH key 密码等）
  services.gnome.gnome-keyring.enable = true;

  # DankMaterialShell（来自 unstable，手动配置）
  systemd.packages = [ dms ];
  systemd.user.services.dms = {
    wantedBy = [ "graphical-session.target" ];
    path = [ quickshell ];
    restartIfChanged = false;
  };
  hardware.graphics.enable = true;

  # ---------- 打印机 ----------
  services.printing.enable = true;

  # ---------- 音频 (PipeWire) ----------
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # ---------- 蓝牙 ----------
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  # ---------- 字体 (CJK) ----------
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-emoji
  ];

  # ---------- Shell ----------
  programs.fish.enable = true;

  # ---------- Docker ----------
  virtualisation.docker.enable = true;

  # ---------- 用户 ----------
  users.users.calendar = {
    isNormalUser = true;
    description = "calendar";
    shell = pkgs.fish;
    extraGroups = [ "networkmanager" "wheel" "docker" ];
    packages = with pkgs; [
      #   thunderbird
    ];
  };

  # ---------- 基础软件 ----------
  programs.firefox.enable = true;
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    git
    vim
    wget
    lsof
    curl
    htop
    btop
    ripgrep
    fd
    jq
    gnupg
    p7zip
    fastfetch
    # 开发
    cmake
    clang
    gdb
    gh
    # niri 周边工具
    xwayland-satellite  # XWayland 兼容层，niri wiki 强烈推荐
    kitty         # GPU 终端
    kanshi        # 显示器输出管理
    wayland-utils # wayland-info
    wl-clipboard  # Wayland 剪贴板
    grim          # 截图
    slurp         # 区域选择
    swaybg        # 壁纸
  ] ++ [
    dms
    quickshell
    pkgs.unstable.opencode
  ];

  # ---------- Nix 配置 ----------
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    substituters = [
      "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
      "https://cache.nixos.org/"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

  # ---------- 版本锁定 ----------
  system.stateVersion = "25.05";
}
