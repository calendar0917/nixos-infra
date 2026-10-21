{
  osConfig,
  lib,
  ...
}:

let
  enabled = osConfig != null && (osConfig.my.desktop.niri.enable or false);
in
{
  config = lib.mkIf enabled {
    xdg.configFile."niri/config.kdl".source = ../../../config/niri/config.kdl;
  };
}
