{
  config,
  lib,
  ...
}:

let
  cfg = config.my.desktop.xfce;
in
{
  # X11 session for hosts that should not run a Wayland compositor. The mini
  # host is the only user today: it is headless, and every tool that has to
  # attach to a live X display from outside the machine (xdotool, x11vnc,
  # AT-SPI) works against X11 without a Wayland-side helper.
  options.my.desktop.xfce.enable = lib.mkEnableOption "XFCE X11 desktop session";

  config = lib.mkIf cfg.enable {
    # XFCE ships xfwm4, xfce4-session, thunar and the panel through this one
    # switch. It is a much smaller install than Plasma 6 and has no Wayland
    # session of its own, so enabling it cannot reintroduce a Wayland default.
    services.xserver.desktopManager.xfce.enable = true;
  };
}