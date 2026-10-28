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

  wallpaper = ../../../config/wallpapers/background.jpg;

  # All cliphist clients use the same session database. Do not fall back to
  # ~/.cache/cliphist: that is the old persistent database and is deliberately
  # left untouched.
  cliphistSession = pkgs.writeShellApplication {
    name = "niri-cliphist-session";
    runtimeInputs = with pkgs; [
      cliphist
      coreutils
      wl-clipboard
      cliphistStore
    ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
      session_dir="$runtime_dir/niri-cliphist"
      db="$session_dir/db"

      # shellcheck disable=SC2329 # invoked from the EXIT trap
      cleanup() {
        rm -rf -- "$session_dir"
      }

      # A previous compositor may have died without running its stop job.
      # Starting from an empty directory is the only reliable way to avoid
      # carrying clipboard data into the next graphical session.
      rm -rf -- "$session_dir"
      mkdir -m 700 -- "$session_dir"

      export CLIPHIST_DB_PATH="$db"
      # cliphist 0.7.0 only accepts these as CLI flags. They are exported too
      # so the per-item store helper enforces the same limits; the exported
      # names are not read by cliphist itself.
      export CLIPHIST_MAX_ITEMS=100
      export CLIPHIST_MAX_STORE_SIZE=2097152
      umask 077

      trap 'cleanup' EXIT
      trap 'exit 0' HUP INT TERM

      wl-paste --type text --watch niri-cliphist-store &
      text_pid=$!
      wl-paste --type image --watch niri-cliphist-store &
      image_pid=$!

      # A watcher exiting while the session is still up is a failure and
      # should restart the pair. A normal systemd stop exits through the TERM
      # trap above instead.
      set +e
      wait -n "$text_pid" "$image_pid"
      kill "$text_pid" "$image_pid" 2>/dev/null
      wait "$text_pid" "$image_pid" 2>/dev/null
      exit 1
    '';
  };

  # One capped store helper for both clipboard watch types. cliphist detects
  # images from their magic bytes, so the helper does not need to know which
  # watcher invoked it.
  cliphistStore = pkgs.writeShellApplication {
    name = "niri-cliphist-store";
    runtimeInputs = with pkgs; [
      cliphist
      coreutils
    ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
      db="''${CLIPHIST_DB_PATH:?CLIPHIST_DB_PATH is not set}"
      max_items="''${CLIPHIST_MAX_ITEMS:-100}"
      max_size="''${CLIPHIST_MAX_STORE_SIZE:-2097152}"
      tmp="$(mktemp "$runtime_dir/niri-cliphist/item.XXXXXX")"
      trap 'rm -f -- "$tmp"' EXIT

      # Read one byte past the limit so oversized data is rejected without
      # buffering an arbitrary amount of clipboard content on tmpfs.
      head -c "$((max_size + 1))" > "$tmp"
      size="$(stat -c %s -- "$tmp")"
      if [ "$size" -le "$max_size" ]; then
        cliphist -db-path "$db" -max-items "$max_items" store < "$tmp"
      fi
    '';
  };

  clipboardMenu = pkgs.writeShellApplication {
    name = "niri-clipboard-menu";
    runtimeInputs = with pkgs; [
      cliphist
      fuzzel
      coreutils
      wl-clipboard
    ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
      db="$runtime_dir/niri-cliphist/db"

      # No live session database: exit quietly. Never fall back to the old
      # ~/.cache/cliphist database.
      if [ ! -s "$db" ]; then
        exit 0
      fi

      export CLIPHIST_DB_PATH="$db"

      if ! selection="$(cliphist -db-path "$db" list | fuzzel --dmenu --prompt='Clipboard: ')"; then
        exit 0
      fi
      if [ -z "$selection" ]; then
        exit 0
      fi

      mime=""
      case "$selection" in
        *"image/png"*) mime="image/png" ;;
        *"image/jpeg"*) mime="image/jpeg" ;;
        *"image/gif"*) mime="image/gif" ;;
        *"image/webp"*) mime="image/webp" ;;
        *"image/bmp"*) mime="image/bmp" ;;
      esac

      if [ -n "$mime" ]; then
        printf '%s\n' "$selection" | cliphist -db-path "$db" decode | wl-copy --type "$mime"
      else
        printf '%s\n' "$selection" | cliphist -db-path "$db" decode | wl-copy
      fi
    '';
  };

  powerMenu = pkgs.writeShellApplication {
    name = "niri-power";
    runtimeInputs = with pkgs; [
      fuzzel
      niri
      swaylock
      systemd
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
          exec swaylock -f -c 0C232C
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

  # Home Manager may start newly added units while the old generation is still
  # logged in (the current niri.service is active, and with it DMS). Refuse to
  # start the Waybar shell while DMS is still running; the next graphical login
  # has no DMS unit and starts normally. This also prevents two panels or two
  # notification daemons during a switch-then-logout transition.
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
in
{
  config = lib.mkIf enabled {
    home.packages = with pkgs; [
      btop
      cliphist
      clipboardMenu
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
      niri-cliphist = {
        Unit = niriUnit // {
          Description = "Session-local cliphist watchers";
        };
        Service = {
          Type = "simple";
          ExecCondition = noDmsGuard;
          ExecStart = "${cliphistSession}/bin/niri-cliphist-session";
          Restart = "on-failure";
          RestartSec = 1;
          UMask = "0077";
        };
        Install = niriInstall;
      };

      waybar = {
        Unit = niriUnit // {
          Description = "Waybar for the niri session";
        };
        Service = {
          Type = "simple";
          ExecCondition = noDmsGuard;
          ExecStart = "${lib.getExe pkgs.waybar} -c ${config.xdg.configHome}/waybar/niri.jsonc -s ${config.xdg.configHome}/waybar/style.css";
          Restart = "on-failure";
          RestartSec = 2;
          Environment = [
            "LANG=${osConfig.i18n.defaultLocale}"
            "LC_TIME=${osConfig.i18n.defaultLocale}"
            "LOCALE_ARCHIVE=${osConfig.i18n.glibcLocales}/lib/locale/locale-archive"
          ];
        };
        Install = niriInstall;
      };

      swaybg = {
        Unit = niriUnit // {
          Description = "Wallpaper for the niri session";
        };
        Service = {
          Type = "simple";
          ExecCondition = noDmsGuard;
          ExecStart = "${lib.getExe pkgs.swaybg} -i ${wallpaper} -m fill";
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install = niriInstall;
      };

      swaync = {
        Unit = niriUnit // {
          Description = "SwayNotificationCenter for the niri session";
          ConditionEnvironment = [
            "WAYLAND_DISPLAY"
            "NIRI_SOCKET"
          ];
        };
        Service = {
          Type = "dbus";
          ExecCondition = noDmsGuard;
          BusName = "org.freedesktop.Notifications";
          ExecStart = lib.getExe pkgs.swaynotificationcenter;
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install = niriInstall;
      };

      nm-applet = {
        Unit = niriUnit // {
          Description = "NetworkManager applet for the niri session";
        };
        Service = {
          Type = "simple";
          ExecCondition = noDmsGuard;
          ExecStart = "${lib.getExe pkgs.networkmanagerapplet} --indicator";
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install = niriInstall;
      };
    };
  };
}
