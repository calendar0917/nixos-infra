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

      # Session-local helpers. On main they are started by sway-session-bound
      # systemd user units (home/calendar/desktop/sway.nix), on the mini host by
      # the bare `exec` lines in config/sway/config. Either way they stay inside
      # a Sway session and can never start from a shared graphical target.
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
