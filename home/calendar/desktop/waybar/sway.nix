{
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  enabled = osConfig != null && (osConfig.my.desktop.sway.enable or false);

  # main's Sway session mirrors the niri panel (Catppuccin Mocha, same bar
  # geometry). The mini host keeps its original teal stylesheet and has no
  # floating margins.
  isMain = osConfig != null && (osConfig.networking.hostName or "") == "main";

  waybar = import ./common.nix { inherit lib pkgs; };

  swayStyle =
    if isMain then
      ../../../../config/waybar/style-sway-main.css
    else
      ../../../../config/waybar/style.css;

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
    // lib.optionalAttrs isMain {
      margin-top = 6;
      margin-bottom = 0;
      margin-left = 8;
      margin-right = 8;
    }
    // waybar.modules;
in
{
  config = lib.mkIf enabled {
    # Keep the standard path: main's sway-waybar.service and the mini host's
    # `exec waybar` both read ~/.config/waybar/config.jsonc. This is the only
    # Sway panel entry point; there is no XDG autostart.
    xdg.configFile = {
      "waybar/config.jsonc".source = (pkgs.formats.json { }).generate "waybar-sway-config.json" settings;

      # main gets its own Catppuccin stylesheet; the mini host keeps the
      # original style.css. Sway always uses `sway/workspaces` here, never the
      # niri module.
      "waybar/style.css".source = swayStyle;
    };
  };
}
