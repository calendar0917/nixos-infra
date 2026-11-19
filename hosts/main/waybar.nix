{ pkgs, ... }:

# main uses Waybar's native niri `workspace-taskbar` and `enable-bar-scroll`.
# Both are part of the Waybar 0.16.0 release that the pinned nixpkgs ships, so
# main no longer needs to pin an upstream development revision. Keep only the
# feature trimming this host wants:
#
# - no Cava: there is no audio-visualiser module in the profile, and Cava
#   would pull in the sndio stack for nothing;
# - no WWAN: this host uses NetworkManager, not ModemManager.
#
# Do not add an upstream revision pin back unless a needed module is missing
# from the release nixpkgs ships.
{
  nixpkgs.overlays = [
    (final: prev: {
      waybar = prev.waybar.override {
        cavaSupport = false;
        wwanSupport = false;
      };
    })
  ];
}
