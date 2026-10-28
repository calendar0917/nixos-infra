{
  osConfig,
  lib,
  ...
}:

let
  niriEnabled = osConfig != null && (osConfig.my.desktop.niri.enable or false);
  shell = if osConfig != null then (osConfig.my.desktop.niri.shell or "dms") else "dms";
  catppuccinKitty = niriEnabled && shell == "waybar";
in
{
  programs.kitty = {
    enable = true;
    settings = {
      font_family = "JetBrains Mono";
      font_size = 11;
      cursor_shape = "beam";
      scrollback_lines = 10000;
      enable_audio_bell = false;
      confirm_os_window_close = 0;
      copy_on_select = true;
    }
    // lib.optionalAttrs catppuccinKitty {
      # Keep the window itself opaque and make only the background
      # translucent. This preserves text contrast while matching the
      # Catppuccin Mocha Waybar on main; the mini host keeps the original
      # opaque terminal.
      background_opacity = 0.90;
      dynamic_background_opacity = true;
      window_padding_width = 8;
      background = "#1e1e2e";
      foreground = "#cdd6f4";
      selection_background = "#89b4fa";
      selection_foreground = "#1e1e2e";
    };
    shellIntegration.mode = "enabled";
  };
}
