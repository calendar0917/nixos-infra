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

  # Mihomo needs a real subscription in the SOPS-managed secret. Keep it off
  # until that secret and the age key have been installed on the machine.
  my.network.mihomo.enable = false;

  # Restic is manual-only. The path is checked again by the wrapper script and
  # by a systemd mount-point condition before anything is written.
  my.backup = {
    enable = true;
    mountPoint = "/run/media/calendar/NIXOS-BACKUP";
    # Set this to the filesystem UUID of the backup USB once it is known.
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
    ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    users.calendar = import ../../home/calendar;
  };

  # First installation version. Do not bump this when upgrading nixpkgs.
  system.stateVersion = "25.05";
}
