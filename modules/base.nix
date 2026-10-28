{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Bootloader, ESP and NVRAM policy live in hosts/<host>/boot.nix. They are
  # host-specific: the Arch dual-boot host shares an ESP and must not inherit
  # the mini host's configurationLimit or canTouchEfiVariables policy.
  boot.supportedFilesystems = [ "ntfs" ];

  # ---------- Nix ----------
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      trusted-users = [
        "root"
        "@wheel"
      ];
      substituters = [
        "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
        "https://cache.nixos.org/"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ];
    };

    # nix-daemon performs store substitutions itself, so a proxy exported only
    # in an interactive shell does not reach cache downloads. Set the local
    # Clash HTTP proxy for the daemon and for Nix clients doing flake fetches.
    # Keep loopback direct; Clash must be running for remote Nix operations.
    envVars = {
      http_proxy = "http://127.0.0.1:7897";
      https_proxy = "http://127.0.0.1:7897";
      HTTP_PROXY = "http://127.0.0.1:7897";
      HTTPS_PROXY = "http://127.0.0.1:7897";
      no_proxy = "localhost,127.0.0.1,::1";
      NO_PROXY = "localhost,127.0.0.1,::1";
    };

    # `--delete-older-than 30d` deletes every profile generation older than
    # 30 days as well as unreachable store paths. It does NOT mean "keep all
    # generations for 30 days": a generation becomes eligible based on its
    # creation time, and deleting it can remove the last known-good rollback
    # target. The current generation is kept.
    #
    # The mini host still forces automatic GC off until a successful reboot
    # and a tested rollback candidate. main enables weekly store-only GC and
    # explicitly overrides `options`; do not rely on this shared value there.
    # See README/RECOVERY.
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

  # KeePassXC-Browser talks to KeePassXC through a native messaging host.
  # Wrapping the system Firefox with the KeePassXC package makes the manifest
  # visible to the browser; the browser profile itself stays user-managed.
  programs.firefox = {
    enable = true;
    nativeMessagingHosts.packages = [ pkgs.keepassxc ];
  };

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
