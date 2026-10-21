{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/base.nix
    ../../modules/network.nix
    ../../modules/secrets.nix
    ../../modules/backup.nix
    ../../modules/desktop/common.nix
    ../../modules/desktop/niri.nix
    ../../modules/desktop/sway.nix
    ../../modules/desktop/plasma.nix
  ];

  networking.hostName = "nixos";

  # The desktop switches are deliberately independent. All enabled sessions
  # appear in SDDM and can be selected at login without rebuilding.
  my.desktop = {
    niri.enable = true;
    sway.enable = true;
    plasma.enable = false;
  };

  # Clash Verge Rev is the only proxy implementation. The NixOS module
  # installs the GUI, the service-mode daemon and TUN capabilities; the
  # subscription and profiles are imported through the GUI.
  my.network.clashVerge = {
    enable = true;
    # Confirm with `ip -brief link show type tun` after enabling TUN. The
    # bundled Mihomo 1.19.x core defaults to "Meta".
    tunInterface = "Meta";
  };

  # Restic is manual-only and intentionally disabled until the real backup USB
  # UUID is known. Enable it only after setting usbUuid below; the module
  # refuses to configure the service with a null UUID.
  my.backup = {
    enable = false;
    mountPoint = "/run/media/calendar/NIXOS-BACKUP";
    usbUuid = null;
  };

  users.users.calendar = {
    isNormalUser = true;
    description = "calendar";
    shell = pkgs.fish;
    extraGroups = [
      "networkmanager"
      "wheel"
      "video"
      "render"
    ] ++ lib.optionals config.my.network.clashVerge.enable [ "clash-verge" ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    users.calendar = import ../../home/calendar;
  };

  # First deployment: postpone automatic GC until the installation has
  # rebooted successfully and at least one rollback candidate has been tested.
  # The base policy uses --delete-older-than 30d and deletes old generations;
  # see README/RECOVERY before re-enabling it.
  nix.gc.automatic = lib.mkForce false;

  # First installation version. Do not bump this when upgrading nixpkgs.
  system.stateVersion = "25.05";
}
