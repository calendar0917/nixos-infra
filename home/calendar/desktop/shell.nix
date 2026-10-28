{
  config,
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  niriEnabled = osConfig != null && (osConfig.my.desktop.niri.enable or false);
  shell = if osConfig != null then (osConfig.my.desktop.niri.shell or "dms") else "dms";
  enabled = niriEnabled && shell == "waybar";
  niriLib = import ./lib.nix { inherit pkgs lib; };

  wallpaper = ../../../config/wallpapers/background.jpg;

  # D-Bus can activate the notification daemon independently of systemd. Make
  # both activation paths refuse to start SwayNC outside niri; the systemd
  # unit has the same ConditionEnvironment guard.
  swayncActivate = pkgs.writeShellScript "swaync-dbus-activate" ''
    if [ -z "''${NIRI_SOCKET:-}" ] || [ -z "''${WAYLAND_DISPLAY:-}" ]; then
      exit 1
    fi
    exec ${lib.getExe' pkgs.systemd "systemctl"} --user start swaync.service
  '';
in
{
  config = lib.mkIf enabled {
    home.packages = with pkgs; [
      btop
      fuzzel
      networkmanagerapplet
      nwg-displays
      pavucontrol
      swaybg
      swaylock
      swaynotificationcenter
      # The shell unit starts this package directly. It is the only Waybar
      # installation in the main user profile.
      waybar
    ];

    xdg.configFile = {
      "swaync/config.json".source = ../../../config/swaync/config.json;
      "swaync/style.css".source = ../../../config/swaync/style.css;

      # nm-applet is started by the niri-bound unit below. Mask its XDG
      # autostart entry so a session cannot start a second applet.
      "autostart/nm-applet.desktop".text = ''
        [Desktop Entry]
        Type=Application
        Name=nm-applet (managed by systemd)
        Exec=true
        Hidden=true
      '';
    };

    xdg.dataFile = {
      "wallpapers/background.jpg".source = wallpaper;

      "dbus-1/services/org.erikreider.swaync.service".text = ''
        [D-BUS Service]
        Name=org.freedesktop.Notifications
        Exec=${swayncActivate}
        SystemdService=swaync.service
      '';

      "dbus-1/services/org.erikreider.swaync.cc.service".text = ''
        [D-BUS Service]
        Name=org.erikreider.swaync.cc
        Exec=${swayncActivate}
        SystemdService=swaync.service
      '';
    };

    systemd.user.services = {
      waybar = {
        Unit = niriLib.niriUnit // {
          Description = "Waybar for the niri session";
        };
        Service = {
          Type = "simple";
          ExecCondition = niriLib.noDmsGuard;
          ExecStart = "${lib.getExe pkgs.waybar} -c ${config.xdg.configHome}/waybar/niri.jsonc -s ${config.xdg.configHome}/waybar/style-niri.css";
          Restart = "on-failure";
          RestartSec = 2;
          Environment = [
            "LANG=${osConfig.i18n.defaultLocale}"
            "LC_TIME=${osConfig.i18n.defaultLocale}"
            "LOCALE_ARCHIVE=${osConfig.i18n.glibcLocales}/lib/locale/locale-archive"
          ];
        };
        Install = niriLib.niriInstall;
      };

      swaybg = {
        Unit = niriLib.niriUnit // {
          Description = "Wallpaper for the niri session";
        };
        Service = {
          Type = "simple";
          ExecCondition = niriLib.noDmsGuard;
          ExecStart = "${lib.getExe pkgs.swaybg} -i ${wallpaper} -m fill";
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install = niriLib.niriInstall;
      };

      swaync = {
        Unit = niriLib.niriUnit // {
          Description = "SwayNotificationCenter for the niri session";
          ConditionEnvironment = [
            "WAYLAND_DISPLAY"
            "NIRI_SOCKET"
          ];
        };
        Service = {
          Type = "dbus";
          ExecCondition = niriLib.noDmsGuard;
          BusName = "org.freedesktop.Notifications";
          ExecStart = lib.getExe pkgs.swaynotificationcenter;
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install = niriLib.niriInstall;
      };

      nm-applet = {
        Unit = niriLib.niriUnit // {
          Description = "NetworkManager applet for the niri session";
        };
        Service = {
          Type = "simple";
          ExecCondition = niriLib.noDmsGuard;
          ExecStart = "${lib.getExe pkgs.networkmanagerapplet} --indicator";
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install = niriLib.niriInstall;
      };
    };
  };
}
