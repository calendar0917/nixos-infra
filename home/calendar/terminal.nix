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
      # The full Catppuccin Mocha theme comes from kitty-themes. Do not
      # duplicate its foreground/background/selection colours here: a partial
      # local palette makes the bar and terminal diverge. Only behaviour and
      # geometry settings are added below.
      #
      # 13.5 is main's size. The shared base stays at 11 so the mini host keeps
      # its original terminal appearance.
      font_size = 13.5;

      # Keep the text opaque and make only the background translucent. This
      # preserves text contrast while matching the Catppuccin Mocha Waybar on
      # main; the mini host keeps the original opaque terminal.
      background_opacity = 0.90;
      dynamic_background_opacity = true;
      window_padding_width = 10;
      hide_window_decorations = "yes";
      tab_bar_style = "hidden";
    };
    shellIntegration.mode = "enabled";
  }
  // lib.optionalAttrs catppuccinKitty {
    themeFile = "Catppuccin-Mocha";
  };
}
