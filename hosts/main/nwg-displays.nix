{ pkgs, ... }:

# nwg-displays 0.4.4 crashes or returns an empty output list when niri reports
# a disabled output with current_mode/logical set to null. Keep the packaged
# 0.4.4 release and add only the niri parsing fix; do not replace it with a
# development branch or a second nixpkgs.
{
  nixpkgs.overlays = [
    (final: prev: {
      nwg-displays = prev.nwg-displays.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../../patches/nwg-displays-niri-null-outputs.patch ];
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          ${pkgs.python3}/bin/python3 ${../../tests/test_nwg_displays_niri_outputs.py} \
            --source nwg_displays/tools.py
          runHook postCheck
        '';
      });
    })
  ];
}
