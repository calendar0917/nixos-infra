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
      # We use Dolphin for the file-manager shortcut. The GTK portal handles
      # file chooser dialogs, so Nautilus is not pulled in just for that.
      useNautilus = false;
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
      kdePackages.dolphin
      grim
      orca
      playerctl
      slurp
      wl-clipboard
      xwayland-satellite
    ];
  };
}
