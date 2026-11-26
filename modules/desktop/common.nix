{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Fcitx5 candidate-window themes. Catppuccin carries the same Mocha palette
  # the Waybar/niri/kitty configs already use, so the candidate window matches
  # the desktop instead of standing out. The theme packages only install files
  # under share/fcitx5/themes, which Fcitx5 already scans through XDG_DATA_DIRS;
  # that is also what makes every variant selectable in fcitx5-configtool →
  # 外观.
  #
  # The rounded variant uses the theme's SVG panel instead of a flat rectangle.
  # "Glass" is the same panel with a slightly translucent fill and an explicit
  # CJK font: the stock theme asks for plain "Sans", which resolves to whatever
  # fontconfig picks first rather than the Noto Sans CJK SC installed here.
  fcitx5ThemeCatppuccin = pkgs.catppuccin-fcitx5.override {
    withRoundedCorners = true;
  };

  fcitx5ThemeCatppuccinGlass = pkgs.runCommand "fcitx5-theme-catppuccin-mocha-glass" { } ''
    themeDir=$out/share/fcitx5/themes/catppuccin-mocha-glass
    mkdir -p "$themeDir"
    cp -r ${fcitx5ThemeCatppuccin}/share/fcitx5/themes/catppuccin-mocha-blue/. "$themeDir/"
    chmod -R u+w "$themeDir"
    conf="$themeDir/theme.conf"

    # The stock theme is sized for a 1x display: font 12/13 plus 18px text
    # insets and 10px background insets. This host is 1536x864 logical at
    # scale 1.25, so the same numbers come out noticeably larger than the
    # rest of the UI. Shrink one step: font 11, text insets 10/4, background
    # insets 8. The rounded 9-slice slice size is 8px, so keep rx=8 in the SVG.
    sed -i \
      -e 's/^Name=.*/Name=Catppuccin Mocha Glass/' \
      -e 's/^Font=Sans 13$/Font=Noto Sans CJK SC 11/' \
      -e 's/^Font=Sans 10$/Font=Noto Sans CJK SC 10/' \
      -e 's/^Spacing=3$/Spacing=2/' \
      "$conf"

    # Scoped by section so the identically named keys in the Menu sections
    # keep their own values.
    sed -i -E \
      -e '/^\[InputPanel\/TextMargin\]$/,/^\[/ s/^(Left|Right)=.*/\1=10/' \
      -e '/^\[InputPanel\/TextMargin\]$/,/^\[/ s/^(Top|Bottom)=.*/\1=4/' \
      -e '/^\[InputPanel\/Background\/Margin\]$/,/^\[/ s/^(Left|Right|Top|Bottom)=.*/\1=8/' \
      -e '/^\[InputPanel\/Highlight\/Margin\]$/,/^\[/ s/^(Left|Right)=.*/\1=10/' \
      -e '/^\[InputPanel\/Highlight\/Margin\]$/,/^\[/ s/^(Top|Bottom)=.*/\1=4/' \
      "$conf"

    # Mocha surface0 with ~88% alpha, blue accent with ~85% alpha.
    sed -i 's|fill="#313244"|fill="#313244e0"|' "$themeDir/panel.svg"
    sed -i 's|fill="#89b4fa"|fill="#89b4fad9"|' "$themeDir/highlight.svg"
  '';
in
{
  # ---------- Login manager ----------
  # SDDM presents every enabled Wayland session. The list comes from the
  # niri/sway/plasma modules; enabling or disabling a session requires a
  # rebuild, but choosing among enabled sessions at login does not.
  services.xserver.enable = true;
  services.xserver.xkb.layout = "cn";
  services.displayManager.sddm = {
    enable = true;
    # Keep the greeter on the X11 backend. The Wayland greeter on this host
    # had input/pointer problems; using X11 for SDDM only does not change the
    # session type: niri and Sway are still Wayland sessions selected below.
    # This matches the running generation (sddm.conf: DisplayServer=x11).
    wayland.enable = false;
  };

  # Plasma and niri both set a normal-priority default session when enabled.
  # Pick one deterministic default while still exposing every enabled session
  # in SDDM. niri wins when present; Sway is the fallback; Plasma is last.
  services.displayManager.defaultSession = lib.mkForce (
    if config.my.desktop.niri.enable then "niri"
    else if config.my.desktop.sway.enable then "sway"
    else if config.my.desktop.plasma.enable then "plasma"
    else null
  );

  # ---------- Audio ----------
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # ---------- Input method ----------
  # The systemd user unit is shared by all desktops; it starts with the
  # graphical session and never needs a compositor-specific autostart hook.
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5 = {
      waylandFrontend = true;
      addons = with pkgs; [
        qt6Packages.fcitx5-chinese-addons

        # Rime Ice ships its dictionaries as data packages rather than as a
        # fork of fcitx5-rime. Keeping rime-data first lets Ice's upstream
        # `__include: rime_ice_suggestion:/` resolve against the base data
        # while rime-ice adds the ice schemas.
        (fcitx5-rime.override {
          rimeDataPkgs = [
            rime-data
            rime-ice
          ];
        })

        fcitx5-gtk
      ];
    };
  };

  # fcitx5 must stay in the foreground: `-d` daemonizes, which makes systemd
  # see the original process exit and repeatedly restart the unit.
  #
  # This is the only Fcitx5 entry point. It has no XDG autostart entry (masked
  # in home/calendar/default.nix) and no compositor startup hook. Being
  # `partOf` graphical-session.target is what keeps the lifecycle correct: when
  # a Sway session really ends, graphical-session.target stops, this unit stops
  # with it, and Fcitx5 cannot stay attached to a Wayland display that no longer
  # exists. The next niri/Sway login starts graphical-session.target again and
  # therefore starts exactly one Fcitx5.
  systemd.user.services.fcitx5 = {
    description = "Fcitx5 input method";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${config.i18n.inputMethod.package}/bin/fcitx5";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  # ---------- Fonts ----------
  fonts.packages = with pkgs; [
    dejavu_fonts
    jetbrains-mono
    liberation_ttf
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
  ];

  fonts.fontconfig.defaultFonts = {
    sansSerif = [ "Noto Sans CJK SC" "Noto Sans" ];
    serif = [ "Noto Serif CJK SC" "Noto Serif" ];
    monospace = [ "JetBrains Mono" "Noto Sans Mono CJK SC" ];
    emoji = [ "Noto Color Emoji" ];
  };

  # ---------- Portals / graphical base ----------
  # niri and sway add their own portal implementations and desktop-specific
  # configuration. This is only the common fallback plus the GTK backend.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [ "gtk" ];
  };

  programs.dconf.enable = true;
  programs.xwayland.enable = true;
  services.gnome.gnome-keyring.enable = true;
  services.graphical-desktop.enable = true;
  services.xserver.desktopManager.runXdgAutostartIfNone = true;
  security.pam.services.swaylock = { };

  # kitty is the terminal in both niri and sway. Home Manager adds its
  # configuration; installing it system-wide also makes it available from a
  # plain TTY rescue session.
  #
  # Nautilus is the graphical file manager for both desktops. Installing the
  # package does not install the GNOME desktop; gvfs, udisks2, the keyring and
  # the desktop portals are enabled separately below and in base.nix.
  environment.systemPackages = [
    pkgs.kitty
    pkgs.nautilus

    # Candidate-window themes for the Fcitx5 classic UI. Catppuccin ships all
    # four flavours in every accent colour; the extra packages are sober dark
    # themes kept so the user can switch in fcitx5-configtool without a rebuild.
    fcitx5ThemeCatppuccin
    fcitx5ThemeCatppuccinGlass
    pkgs.fcitx5-tokyonight
    pkgs.fcitx5-fluent
    pkgs.fcitx5-nord
  ];

  # The default system path env only links the well-known subtrees, so without
  # this the theme directories above never reach /run/current-system/sw/share
  # and Fcitx5 (which scans XDG_DATA_DIRS) cannot see them.
  environment.pathsToLink = [ "/share/fcitx5" ];
}
