{
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  enabled = osConfig != null && (osConfig.my.desktop.sway.enable or false);

  # The mako package ships a D-Bus activation file for
  # org.freedesktop.Notifications. Without a guard, any notification request in
  # a niri session could start mako even though DMS owns notifications there.
  # Keep D-Bus activation working for Sway, but make it a no-op elsewhere.
  makoActivate = pkgs.writeShellScript "mako-dbus-activate" ''
    if [ -n "''${SWAYSOCK:-}" ] && [ -n "''${WAYLAND_DISPLAY:-}" ]; then
      exec ${lib.getExe pkgs.mako}
    fi
    exit 1
  '';
in
{
  config = lib.mkIf enabled {
    xdg.dataFile."dbus-1/services/fr.emersion.mako.service".text = ''
      [D-BUS Service]
      Name=org.freedesktop.Notifications
      Exec=${makoActivate}
    '';

    xdg.configFile = {
      "sway/config".source = ../../../config/sway/config;
      "waybar/config.jsonc".source = ../../../config/sway/waybar/config.jsonc;
      "waybar/style.css".source = ../../../config/sway/waybar/style.css;
      "mako/config".source = ../../../config/sway/mako/config;
      "fuzzel/fuzzel.ini".source = ../../../config/sway/fuzzel/fuzzel.ini;
    };
  };
}
