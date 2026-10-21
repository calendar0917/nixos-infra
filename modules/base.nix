{
  config,
  lib,
  pkgs,
  ...
}:

{
  # ---------- Boot ----------
  # /boot is the NixOS ESP from hardware-configuration.nix. Windows keeps its
  # own ESP; nothing in this repository copies or deletes Windows EFI files.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 20;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 3;

  # If Windows and NixOS use different ESPs, systemd-boot cannot auto-detect
  # Windows. After checking the device handle from the EDK2 UEFI shell, add:
  # boot.loader.systemd-boot.windows."11".efiDeviceHandle = "HD0c1";
  # The firmware boot menu remains a safe fallback until that is verified.

  boot.supportedFilesystems = [ "ntfs" ];

  # ---------- Nix ----------
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "@wheel" ];
      substituters = [
        "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
        "https://cache.nixos.org/"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ];
    };

    # Keep 20 boot generations and 30 days of store paths. This is deliberately
    # not aggressive: rollback is more valuable than a few gigabytes.
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  nixpkgs.config.allowUnfree = true;

  # ---------- Locale / time ----------
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
  console.keyMap = "us";

  # ---------- Hardware / basic services ----------
  hardware.enableRedistributableFirmware = true;
  hardware.graphics.enable = true;
  services.fstrim.enable = true;
  services.udisks2.enable = true;
  services.gvfs.enable = true;
  security.polkit.enable = true;

  # Caps Lock: tap = Escape, hold = Ctrl. This is independent of the desktop
  # and applies to all sessions.
  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings.main.capslock = "overload(control, esc)";
    };
  };

  # ---------- User-facing base packages ----------
  programs.fish.enable = true;
  programs.firefox.enable = true;
  programs.gnupg.agent.enable = true;

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

  services.flatpak.enable = true;

  environment.systemPackages = with pkgs; [
    # Recovery and inspection tools available without a graphical session.
    age
    btrfs-progs
    btop
    curl
    dosfstools
    e2fsprogs
    exfatprogs
    fd
    git
    gptfdisk
    htop
    jq
    lm_sensors
    ncdu
    ntfs3g
    openssh
    p7zip
    parted
    pciutils
    restic
    ripgrep
    smartmontools
    sops
    tree
    unzip
    usbutils
    util-linux
    vim
    wget
  ];
}
