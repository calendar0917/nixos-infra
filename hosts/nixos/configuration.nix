{ config, lib, pkgs, inputs, ... }:

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
    configFile = ../../clash.yaml;
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

  # ---------- 桌面 (GNOME) ----------
  services.xserver.enable = true;
  services.xserver.xkb.layout = "cn";

  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  # ---------- 打印机 ----------
  services.printing.enable = true;

  # ---------- 音频 ----------
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

  # ---------- Shell ----------
  programs.fish.enable = true;

  # ---------- Docker ----------
  virtualisation.docker.enable = true;

  # ---------- 用户 ----------
  users.users.calendar = {
    isNormalUser = true;
    description = "calendar";
    shell = pkgs.fish;
    extraGroups = [ "networkmanager" "wheel" "docker" "video" "render" ];
  };

  # ---------- 软件 ----------
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
    kitty
    cmake
    clang
    gdb
    gh
  ] ++ [
    pkgs.unstable.opencode
  ];

  # ---------- Nix ----------
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

  system.stateVersion = "25.05";
}
