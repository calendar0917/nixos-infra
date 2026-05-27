{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/features/niri
    ../../modules/fonts
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

  # ---------- Tailscale ----------
  services.tailscale.enable = true;

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

  # ---------- 桌面 ----------
  services.xserver.enable = true;
  services.xserver.xkb.layout = "cn";

  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # niri + dms
  programs.niri.enable = true;
  programs.dms-shell = {
    enable = true;
    systemd.enable = true;
  };

  # ---------- 键盘映射: Caps → Esc(单击)/Ctrl(长按) ----------
  services.keyd = {
    enable = true;
    keyboards = {
      default = {
        ids = [ "*" ];
        settings = {
          main = {
            capslock = "overload(control, esc)";
          };
        };
      };
    };
  };

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

  # ---------- Home Manager ----------
  home-manager.users.calendar = import ../../home/calendar.nix;

  # ---------- Shell ----------
  programs.fish.enable = true;
  programs.zoxide.enable = true;

  # ---------- Docker ----------
  virtualisation.docker.enable = true;

  # ---------- VirtualBox ----------
  virtualisation.virtualbox.host.enable = true;

  # ---------- Neovim ----------
  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };

  # ---------- 用户 ----------
  users.users.calendar = {
    isNormalUser = true;
    description = "calendar";
    shell = pkgs.fish;
    extraGroups = [ "networkmanager" "wheel" "docker" "video" "render" "vboxusers" ];
  };

  # ---------- 软件 ----------
  programs.firefox.enable = true;
  nixpkgs.config.allowUnfree = true;

  # Flatpak（QQ/腾讯会议等在 nixpkgs 里没有的软件走这里）
  services.flatpak.enable = true;

  environment.systemPackages = with pkgs; [
    # 系统工具
    git vim wget lsof curl htop btop ncdu
    tree ripgrep fd jq gnupg p7zip fastfetch
    appimage-run
    # 开发
    cmake clang gdb gh go nodejs python3 uv pandoc
    # 终端
    kitty yazi
    # 通信
    telegram-desktop
    wechat-uos
    # 办公 / 笔记
    onlyoffice-desktopeditors
    obsidian zotero
    # 娱乐
    steam
    obs-studio
    wl-screenrec
    qbittorrent
    # 浏览器
    google-chrome
    # AI
    claude-code
    opencode
    # 代理 GUI（可选）
    clash-verge-rev
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
