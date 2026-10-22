{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.desktop.niri;
in
{
  options.my.desktop.niri.enable = lib.mkEnableOption "niri + DankMaterialShell desktop";

  config = lib.mkIf cfg.enable {
    programs.niri = {
      enable = true;
      # The NixOS niri module uses Nautilus for the GNOME portal's file
      # chooser and exposes its D-Bus service. Nautilus itself is installed
      # by desktop/common.nix for both niri and Sway.
      useNautilus = true;
    };

    # DMS is a shell for niri, not a system-wide graphical service. Binding
    # its unit to niri.service keeps it out of Sway and Plasma sessions.
    programs.dms-shell = {
      enable = true;
      systemd = {
        enable = true;
        target = "niri.service";
      };
    };

    # If niri exits, stop DMS as well. `WantedBy` alone does not guarantee
    # this when the graphical-session target is still alive.
    systemd.user.services.dms.partOf = [ "niri.service" ];

    environment.systemPackages = with pkgs; [
      brightnessctl
      grim
      orca
      playerctl
      slurp
      # The niri Waybar profile is prepared but not started; install the
      # package system-wide so it is available for the manual A/B test and
      # does not shadow the package unit from the user profile.
      waybar
      wl-clipboard
      xwayland-satellite
    ];
  };
}
