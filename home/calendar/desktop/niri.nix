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
    # Read-only session configuration. Output layout is deliberately not
    # included from here any more: kanshi applies the wdisplays-written
    # Profiles, and `~/.config/niri/monitor.kdl` stays on disk only as a record
    # of the earlier layout. Home Manager must therefore neither install nor
    # create monitor.kdl.
    xdg.configFile."niri/config.kdl".source = configFile;
  };
}
