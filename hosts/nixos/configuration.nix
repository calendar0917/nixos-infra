{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/features/niri
    ../../modules/fonts
  ];

  # ---------- 二进制缓存 ----------
  nix.settings = {
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };

  # ---------- 引导 ----------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Windows 双启动：把 Windows 的 EFI 文件复制到 NixOS ESP
  boot.loader.systemd-boot.extraInstallCommands = ''
    ${pkgs.coreutils}/bin/mkdir -p /boot/EFI
    ${pkgs.util-linux}/bin/mount /dev/nvme0n1p1 /mnt
    ${pkgs.coreutils}/bin/cp -r /mnt/EFI/Microsoft /boot/EFI/
    ${pkgs.util-linux}/bin/umount /mnt
  '';

  boot.loader.systemd-boot.extraEntries = {
    "windows.conf" = ''
      title   Windows
      efi     /EFI/Microsoft/Boot/bootmgfw.efi
    '';
  };

  # ---------- 网络 ----------
  networking.hostName = "nixos";
  networking.networkmanager.enable = true;
  networking.firewall.enable = false;

  # ---------- sops-nix ----------
  sops.age.keyFile = "/home/calendar/.config/sops/age/keys.txt";

  sops.secrets."mihomo-config" = {
    sopsFile = ../../secrets/secrets.yaml;
  };

  # ---------- 代理 ----------
  # mihomo 系统服务 + TUN 模式
  services.mihomo = {
    enable = true;
    tunMode = true;
    configFile = config.sops.secrets."mihomo-config".path;
    webui = pkgs.metacubexd;  # Web UI: http://127.0.0.1:9090/ui
  };

  # ---------- Tailscale ----------
  services.tailscale.enable = true;
  systemd.services.tailscaled.environment = {
  HTTP_PROXY = "http://127.0.0.1:7890";
  HTTPS_PROXY = "http://127.0.0.1:7890";
};

  # ---------- 时区 / 区域 ----------
  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "zh_CN.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "zh_CN.UTF-8";
    LC_COLLATE = "zh_CN.UTF-8";
    LC_CTYPE = "zh_CN.UTF-8";
    LC_IDENTIFICATION = "zh_CN.UTF-8";
    LC_MEASUREMENT = "zh_CN.UTF-8";
    LC_MESSAGES = "zh_CN.UTF-8";
    LC_MONETARY = "zh_CN.UTF-8";
    LC_NAME = "zh_CN.UTF-8";
    LC_NUMERIC = "zh_CN.UTF-8";
    LC_PAPER = "zh_CN.UTF-8";
    LC_TELEPHONE = "zh_CN.UTF-8";
    LC_TIME = "zh_CN.UTF-8";
  };

  # ---------- XWayland ----------
  programs.xwayland.enable = true;

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

  # U 盘 / 移动硬盘自动挂载
  services.udisks2.enable = true;
  services.gvfs.enable = true;

  # gvfs 默认不自动启动，手动加依赖让它在 session 启动时拉起
  systemd.user.services.gvfs-daemon.wantedBy = [ "graphical-session.target" ];
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

  # ---------- 电源管理 ----------
  # 笔记本合盖无动作
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  # ---------- 蓝牙 ----------
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  # ---------- Home Manager ----------
  home-manager.backupFileExtension = "hm-backup";  # 冲突时自动备份旧文件
  home-manager.extraSpecialArgs = { inherit (pkgs) cc-switch-cli; };
  home-manager.users.calendar = ../../home/calendar.nix;

  # ---------- Shell ----------
  programs.fish.enable = true;
  programs.zoxide.enable = true;
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc.lib
      zlib
      xz
      bzip2
      libffi
      openssl
    ];
  };
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

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
    extraGroups = [ "networkmanager" "wheel" "docker" "video" "render" "vboxusers" "wireshark"];
  };

  # ---------- 软件 ----------
  programs.firefox.enable = true;
  programs.wireshark = {
      enable = true;
      package = pkgs.wireshark;
    };

  nixpkgs.config.allowUnfree = true;

  # Flatpak（QQ/腾讯会议等在 nixpkgs 里没有的软件走这里）
  services.flatpak.enable = true;

  environment.systemPackages = with pkgs; [
    # 系统工具
    git vim wget lsof curl htop btop ncdu
    tree ripgrep fd jq gnupg p7zip fastfetch
    appimage-run stow tree-sitter
    # 开发
    cmake clang gdb gh go nodejs python3 uv pandoc
    # 终端
    kitty yazi
    # 通信（微信走 Flatpak：com.tencent.WeChat）
    telegram-desktop
    # 办公 / 笔记
    libreoffice
    obsidian zotero
    # 娱乐
    steam
    obs-studio
    wl-screenrec
    qbittorrent
    # 浏览器
    google-chrome
    # AI (from llm-agents.nix)
    pkgs.llm-agents.claude-code
    pkgs.llm-agents.opencode
    pkgs.llm-agents.codex
    pkgs.llm-agents.pi
    pkgs.llm-agents.cc-switch-cli
    # 代理 GUI（可选）
    clash-verge-rev
    # XWayland（niri 需要 xwayland-satellite 来运行 X11 应用如 OnlyOffice）
    xwayland-satellite
    # LaTeX
    (texlive.combine {
      inherit (texlive)
        scheme-small
        collection-latexextra
        collection-langchinese
        collection-fontsrecommended;
    })
    # winapps
    inputs.winapps.packages.${pkgs.system}.winapps
    inputs.winapps.packages.${pkgs.system}.winapps-launcher
    freerdp3
  ];

  # ---------- Windows 分区挂载 ----------
  boot.supportedFilesystems = [ "ntfs" ];

  fileSystems."/mnt/c" = {
    device = "/dev/disk/by-uuid/7A0C392C0C38E533";
    fsType = "ntfs3";
    options = [ "rw" "uid=1000" "gid=100" "umask=022" ];
  };

  fileSystems."/mnt/d" = {
    device = "/dev/disk/by-uuid/4A0EEC030EEBE5C3";
    fsType = "ntfs3";
    options = [ "rw" "uid=1000" "gid=100" "umask=022" ];
  };

  # ---------- Nix ----------
  nix = {
    settings = {
      trusted-users = [ "root" "@wheel" ];
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;   # 文件级去重，省 30-50% 空间
      substituters = [
        "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
        "https://cache.nixos.org/"
        "https://winapps.cachix.org/"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "winapps.cachix.org-1:HI82jWrXZsQRar/PChgIx1unmuEsiQMQq+zt05CD36g="
      ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  system.stateVersion = "25.05";
}
