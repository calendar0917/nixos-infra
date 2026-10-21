{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.desktop.sway;
in
{
  options.my.desktop.sway.enable = lib.mkEnableOption "Sway fallback desktop";

  config = lib.mkIf cfg.enable {
    # Sway is launched directly by SDDM rather than through a desktop
    # manager. Pull the XDG autostart target into the session so Clash Verge
    # starts here as well as under niri; fcitx5's package autostart entry is
    # masked by Home Manager to avoid a second input-method process.
    systemd.user.targets.sway-session.wants = [ "xdg-desktop-autostart.target" ];

    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true;
      xwayland.enable = true;

      # These are exactly the session-local helpers used by config/sway.
      # waybar and mako are started by the Sway config, never by a shared
      # systemd target, so a niri session cannot accidentally run them.
      extraPackages = with pkgs; [
        brightnessctl
        fuzzel
        grim
        kitty
        mako
        playerctl
        slurp
        swaybg
        swaylock
        waybar
        wl-clipboard
      ];
    };
  };
}
