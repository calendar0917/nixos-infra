{
  config,
  lib,
  pkgs,
  ...
}:

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
        fcitx5-rime
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
  ];
}
