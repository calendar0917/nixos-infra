{
  osConfig,
  lib,
  ...
}:

let
  enabled = osConfig != null && (osConfig.my.desktop.niri.enable or false);
  shell = if osConfig != null then (osConfig.my.desktop.niri.shell or "dms") else "dms";
  waybarShell = shell == "waybar";

  # config.kdl is the main host's modular Waybar profile. The mini host keeps
  # its original DMS bindings verbatim; both files are read-only Home Manager
  # links, so the DMS profile cannot drift into the Waybar session.
  configFile =
    if waybarShell then ../../../config/niri/config.kdl else ../../../config/niri/config-dms.kdl;
in
{
  config = lib.mkIf enabled {
    xdg.configFile."niri/config.kdl".source = configFile;

    # nwg-displays writes the GUI-managed output layout here. This must stay a
    # normal writable file: never put monitor.kdl in xdg.configFile, which
    # would replace it with a read-only Nix store symlink on every activation.
    # config/niri/config.kdl contains `include "monitor.kdl"`; niri resolves
    # that relative include next to the symlink at ~/.config/niri/config.kdl.
    home.activation = lib.mkIf waybarShell {
      niriMonitorKdl = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        monitorFile="$HOME/.config/niri/monitor.kdl"
        if [ ! -e "$monitorFile" ]; then
          run mkdir -p "$HOME/.config/niri"
          run touch "$monitorFile"
          run chmod 0644 "$monitorFile"
        fi
      '';
    };
  };
}
