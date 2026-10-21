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
