{
  config,
  lib,
  ...
}:

let
  cfg = config.my.desktop.plasma;
in
{
  options.my.desktop.plasma.enable = lib.mkEnableOption "KDE Plasma 6 desktop (optional fallback)";

  config = lib.mkIf cfg.enable {
    # Keep this close to the official NixOS module. Plasma users can create
    # their personal settings through the normal Plasma UI.
    services.desktopManager.plasma6.enable = true;
  };
}
