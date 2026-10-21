{
  osConfig,
  lib,
  ...
}:

let
  enabled = osConfig != null && (osConfig.my.desktop.sway.enable or false);
in
{
  config = lib.mkIf enabled {
    xdg.configFile = {
      "sway/config".source = ../../../config/sway/config;
      "waybar/config.jsonc".source = ../../../config/sway/waybar/config.jsonc;
      "waybar/style.css".source = ../../../config/sway/waybar/style.css;
      "mako/config".source = ../../../config/sway/mako/config;
      "fuzzel/fuzzel.ini".source = ../../../config/sway/fuzzel/fuzzel.ini;
    };
  };
}
