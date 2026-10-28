{
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  enabled = osConfig != null && (osConfig.my.desktop.sway.enable or false);

  waybar = import ./common.nix { inherit lib pkgs; };

  settings =
    waybar.bar
    // {
      modules-left = [
        "sway/workspaces"
        "sway/mode"
      ];
      modules-center = [ "sway/window" ];
      modules-right = waybar.right;

      "sway/workspaces" = {
        disable-scroll = true;
        all-outputs = false;
        format = "{name}";
        on-click = "activate";
      };

      "sway/mode" = {
        format = "{}";
        max-length = 30;
      };

      "sway/window" = {
        max-length = 60;
        format = "{}";
      };
    }
    // waybar.modules;
in
{
  config = lib.mkIf enabled {
    # Keep the standard path: config/sway/config starts plain `waybar`, which
    # reads ~/.config/waybar/config.jsonc. This is the only Sway panel entry
    # point; there is no systemd unit or XDG autostart.
    xdg.configFile = {
      "waybar/config.jsonc".source = (pkgs.formats.json { }).generate "waybar-sway-config.json" settings;

      # Same file as the niri profile. Both definitions point at the identical
      # path, which Home Manager merges (types.path only accepts equal values).
      "waybar/style.css".source = ../../../../config/waybar/style.css;
    };
  };
}
