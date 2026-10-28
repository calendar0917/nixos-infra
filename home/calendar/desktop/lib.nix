# Small shared helpers for the niri Waybar shell. This is plain Nix data, not a
# second module framework: clipboard, panel and lock modules all need the same
# niri-bound unit shape and the same transition guard against DMS.
{
  pkgs,
  lib,
}:

let
  niriLib = {
    # Home Manager may start newly added units while the old generation is
    # still logged in with DMS. Refuse to start the Waybar shell helpers while
    # DMS is active; the next graphical login has no DMS unit.
    noDmsGuard = pkgs.writeShellScript "niri-shell-guard-no-dms" ''
      if ${lib.getExe' pkgs.systemd "systemctl"} --user is-active --quiet dms.service; then
        exit 1
      fi
      exit 0
    '';

    niriUnit = {
      PartOf = [ "niri.service" ];
      BindsTo = [ "niri.service" ];
      After = [ "niri.service" ];
    };

    niriInstall = {
      WantedBy = [ "niri.service" ];
    };

    # The unit itself enforces single-instance semantics through systemd: a
    # second start while hyprlock is running is a no-op, not a new process.
    niriLock = pkgs.writeShellApplication {
      name = "niri-lock";
      runtimeInputs = [ pkgs.systemd ];
      text = ''
        exec ${lib.getExe' pkgs.systemd "systemctl"} --user start niri-lock-screen.service
      '';
    };
  };
in
niriLib
