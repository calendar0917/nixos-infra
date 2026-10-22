{
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  enabled = osConfig != null && (osConfig.my.desktop.niri.enable or false);

  waybar = import ./common.nix { inherit lib; };

  # niri-specific modules only. Do not reuse sway/workspaces or sway/window:
  # niri has its own IPC and exposes niri/workspaces and niri/window.
  settings = waybar.bar // {
    modules-left = [ "niri/workspaces" ];
    modules-center = [ "niri/window" ];
    modules-right = waybar.right;

    "niri/workspaces" = {
      format = "{value}";
      all-outputs = false;
    };

    "niri/window" = {
      format = "{title}";
      separate-outputs = false;
    };
  } // waybar.modules;
in
{
  config = lib.mkIf enabled {
    # The niri profile is prepared but deliberately NOT started. The niri
    # session keeps DMS as its panel; this is a complete standalone profile:
    #
    #   waybar -c ~/.config/waybar/niri.jsonc -s ~/.config/waybar/style.css
    #
    # No systemd unit, no XDG autostart and no spawn line in config/niri are
    # added, so DMS and Waybar cannot both start a panel by accident. See
    # README "Waybar" for the A/B procedure.
    xdg.configFile = {
      "waybar/niri.jsonc".source =
        (pkgs.formats.json { }).generate "waybar-niri-config.json" settings;

      # Same file as the Sway profile; identical path definitions merge.
      "waybar/style.css".source = ../../../../config/waybar/style.css;
    };

    # waybar itself is installed system-wide by modules/desktop/niri.nix.
    # Do not add it to home.packages: a user-profile copy shadows the system
    # unit and makes `systemctl --user is-enabled waybar` report it as enabled.
    # fuzzel is only needed by this prepared profile, so it stays here.
    home.packages = [ pkgs.fuzzel ];
  };
}
