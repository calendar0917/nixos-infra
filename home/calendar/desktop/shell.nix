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

  powerMenu = pkgs.writeShellApplication {
    name = "niri-power";
    runtimeInputs = with pkgs; [
      fuzzel
      niri
      systemd
      niriLib.niriLock
    ];
    text = ''
      action="''${1:?missing action}"

      confirm() {
        label="$1"
        if ! choice="$(printf 'Cancel\n%s\n' "$label" | fuzzel --dmenu --prompt='Confirm: ')"; then
          return 1
        fi
        [ "$choice" = "$label" ]
      }

      case "$action" in
        lock)
          exec niri-lock
          ;;
        suspend)
          exec systemctl suspend
          ;;
        logout)
          confirm "Log out" || exit 0
          exec niri msg action quit --skip-confirmation
          ;;
        reboot)
          confirm "Reboot" || exit 0
          exec systemctl reboot
          ;;
        shutdown)
          confirm "Shut down" || exit 0
          exec systemctl poweroff
          ;;
        *)
          exit 2
          ;;
      esac
    '';
  };

  wlogoutEntries = [
    {
      label = "lock";
      action = "${powerMenu}/bin/niri-power lock";
      text = "Lock";
      keybind = "l";
    }
    {
      label = "logout";
      action = "${powerMenu}/bin/niri-power logout";
      text = "Logout";
      keybind = "e";
    }
    {
      label = "suspend";
      action = "${powerMenu}/bin/niri-power suspend";
      text = "Suspend";
      keybind = "u";
    }
    {
      label = "reboot";
      action = "${powerMenu}/bin/niri-power reboot";
      text = "Reboot";
      keybind = "r";
    }
    {
      label = "shutdown";
      action = "${powerMenu}/bin/niri-power shutdown";
      text = "Shutdown";
      keybind = "s";
    }
  ];

  wlogoutLayout = lib.concatMapStringsSep "\n" (entry: builtins.toJSON entry) wlogoutEntries;

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
      powerMenu
      swaybg
      swaylock
      swaynotificationcenter
      wlogout
      # The shell unit starts this package directly. It is the only Waybar
      # installation in the main user profile.
      waybar
    ];

    xdg.configFile = {
      "swaync/config.json".source = ../../../config/swaync/config.json;
      "swaync/style.css".source = ../../../config/swaync/style.css;

      "wlogout/layout".text = wlogoutLayout + "\n";
      "wlogout/style.css".text = ''
        * {
          font-family: "JetBrains Mono", "Noto Sans CJK SC", "Symbols Nerd Font", sans-serif;
          font-size: 14px;
        }

        window {
          background-color: rgba(12, 35, 44, 0.94);
        }

        button {
          background-color: #173B43;
          color: #D4E1DF;
          border: 1px solid rgba(99, 138, 140, 0.5);
          border-radius: 10px;
          margin: 8px;
          min-width: 140px;
          min-height: 96px;
        }

        button:hover,
        button:focus {
          background-color: #638A8C;
          color: #0C232C;
          outline: none;
        }
      '';

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
