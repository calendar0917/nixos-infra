{
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  # Only main has a docking/external-display workflow. The mini host keeps a
  # single always-on output and does not need kanshi or wdisplays.
  enabled = osConfig != null && (osConfig.networking.hostName or "") == "main";

  # Seed file used once, only when the user has no Kanshi config yet. It keeps
  # the internal panel enabled without claiming anything about unknown external
  # displays. It is copied, never symlinked, so the file stays writable.
  initialKanshiConfig = pkgs.writeText "kanshi-config-initial" ''
    profile portable {
        output eDP-1 enable
    }
  '';
in
{
  config = lib.mkIf enabled {
    # wdisplays is the GUI for manual layout changes. Its "Save to kanshi
    # Config" action writes the same file kanshi reads, so one GUI session
    # produces a persistent Profile.
    home.packages = [ pkgs.wdisplays ];

    # `settings = []` is deliberate. It makes Home Manager skip generating
    # ~/.config/kanshi/config, which would otherwise become a read-only
    # /nix/store symlink and break "Save to kanshi Config". The service itself
    # is still managed by Home Manager.
    services.kanshi = {
      enable = true;
      systemdTarget = "graphical-session.target";
      settings = [ ];
    };

    # Create the writable Kanshi config only when it is absent. An existing file
    # (profiles saved from wdisplays) is never overwritten, cleared or replaced.
    home.activation.kanshiConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      kanshiFile="$HOME/.config/kanshi/config"
      if [ ! -e "$kanshiFile" ]; then
        run mkdir -p "$HOME/.config/kanshi"
        run cp ${initialKanshiConfig} "$kanshiFile"
        run chmod 0644 "$kanshiFile"
      fi
    '';
  };
}
