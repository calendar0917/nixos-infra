{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.desktop.niri;
  useDms = cfg.shell == "dms";
in
{
  options.my.desktop.niri = {
    enable = lib.mkEnableOption "niri desktop";

    # The shell is a host-level choice. The mini host keeps the original
    # DankMaterialShell setup; main runs the modular Waybar shell from
    # home/calendar/desktop/shell.nix. This option exists only to keep the
    # shared niri module from forcing DMS onto every host.
    shell = lib.mkOption {
      type = lib.types.enum [
        "dms"
        "waybar"
      ];
      default = "dms";
      description = ''
        Desktop shell used by niri. "dms" enables DankMaterialShell as before;
        "waybar" leaves DMS disabled and lets the Home Manager niri shell own
        the panel and session helpers.
      '';
    };

    # Battery presence is a property of the machine, not of the shell. The
    # laptop sets this to true; the mini PC keeps the default.
    hasBattery = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether the Waybar niri profile should display a battery module.";
    };
  };

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
    #
    # main selects shell = "waybar", which disables this block entirely. Do
    # not delete the DMS configuration: the mini host still uses it. Current
    # nixpkgs renamed the module to programs.dux-shell, but the installed CLI,
    # dms.service and config-dms.kdl names remain unchanged.
    programs.dux-shell = lib.mkIf useDms {
      enable = true;
      systemd = {
        enable = true;
        target = "niri.service";
      };
    };

    # If niri exits, stop DMS as well. `WantedBy` alone does not guarantee
    # this when the graphical-session target is still alive.
    systemd.user.services.dms = lib.mkIf useDms {
      partOf = [ "niri.service" ];
    };

    environment.systemPackages = with pkgs; [
      brightnessctl
      grim
      orca
      playerctl
      slurp
      wl-clipboard
      xwayland-satellite
    ];
  };
}
