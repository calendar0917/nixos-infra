# hosts/main/hardware-configuration.nix is generated from the NixOS Minimal
# ISO after mounting @nixos, @nixos-home, @nixos-nix and the existing ESP.
# It is intentionally absent until generated; flake.nix only exposes
# nixosConfigurations.main when that file exists. Do not add placeholder disk
# UUIDs, subvolumes, swap devices or CPU declarations to make evaluation pass.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./docker.nix
    ./clash.nix
    ./waybar.nix
    ../../modules/base.nix
    ../../modules/network.nix
    ../../modules/secrets.nix
    ../../modules/desktop/common.nix
    ../../modules/desktop/niri.nix
    ../../modules/desktop/sway.nix
    ../../modules/desktop/plasma.nix
  ];

  networking.hostName = "main";

  # Use the same desktop/Home Manager baseline as the mini host, but keep the
  # NixOS home on its own @nixos-home subvolume. Arch's ~/.config and ~/.local
  # are never copied or used as Home Manager targets.
  my.desktop = {
    niri = {
      enable = true;
      # main uses the modular Waybar shell. The mini host keeps the default
      # DMS shell from modules/desktop/niri.nix.
      shell = "waybar";
      hasBattery = true;
    };
    sway.enable = true;
    plasma.enable = false;
  };

  # Fallback glyphs for the Waybar modules that use Nerd Font Symbols. Keep
  # this on main only; the mini host's DMS/font setup is unchanged.
  fonts.packages = [ pkgs.nerd-fonts.symbols-only ];

  # Do not copy the mini host's Clash Verge/TUN settings: the main machine's
  # proxy profiles, subscription and interface names are not part of this
  # migration. NetworkManager, resolved and Tailscale (without an auth key)
  # are enough for the first installation.
  my.network = {
    tailscale.enable = true;
    clashVerge.enable = true;
  };

  # Arch's user is UID/GID 1000:1000 with primary group "calendar" (gid 1000).
  # NixOS must use UID 1000 to read Arch's mode-0700 home through the read-only
  # mount below. The mini host uses group "users" (gid 100); do not copy that.
  users.groups.calendar.gid = 1000;
  users.users.calendar = {
    isNormalUser = true;
    uid = 1000;
    group = "calendar";
    description = "calendar";
    shell = pkgs.fish;
    extraGroups = [
      "networkmanager"
      "wheel"
      "video"
      "render"
    ] ++ lib.optionals config.my.network.clashVerge.enable [ "clash-verge" ];
  };

  # The workstation owner explicitly requested passwordless sudo. This is
  # root-equivalent for every process running as this wheel user; do not add
  # other interactive users to wheel.
  security.sudo.wheelNeedsPassword = false;

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    users.calendar = import ../../home/calendar;
  };

  # Read-only view of Arch's @home. Reuse the generated NixOS root device
  # string instead of duplicating a UUID. This is never mounted read-write,
  # never used as /home, and never managed by Home Manager.
  fileSystems."/mnt/arch-home" = {
    device = config.fileSystems."/".device;
    fsType = "btrfs";
    options = [
      "ro"
      "relatime"
      "subvol=@home"
      "nofail"
    ];
  };

  # Keep every generation until the first NixOS boot and a rollback test have
  # passed. Do not enable automatic GC during the installation phase.
  nix.gc.automatic = lib.mkForce false;

  # First-install release, taken from the actual installation medium. The
  # Ventoy stick holds the Graphical 26.05.12297 image (preferred) and the
  # Minimal 26.05.12400 image (fallback); nixos-generate-config for either
  # writes 26.05, so this must be 26.05 even though flake.lock pins a 26.11
  # pre-release nixpkgs. The nixpkgs pin and stateVersion are independent; do
  # not bump this to 26.11 just because the flake is newer. If a different ISO
  # is used, set this to that ISO's VERSION_ID before nixos-install and never
  # change it afterwards.
  system.stateVersion = "26.05";
}
