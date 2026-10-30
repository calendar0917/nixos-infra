{
  config,
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  enabled = osConfig != null && (osConfig.my.desktop.sway.enable or false);

  # main is the only host that runs the systemd-managed Sway session below.
  # The mini host keeps its original Sway config, Fuzzel theme and bare `exec`
  # helpers, so its Sway appearance and behaviour are unchanged.
  isMain = osConfig != null && (osConfig.networking.hostName or "") == "main";

  swayConfig =
    if isMain then ../../../config/sway/config-main else ../../../config/sway/config;
  fuzzelConfig =
    if isMain then
      ../../../config/sway/fuzzel/fuzzel-main.ini
    else
      ../../../config/sway/fuzzel/fuzzel.ini;

  wallpaper = ../../../config/wallpapers/background.jpg;

  # The mako package ships a D-Bus activation file for
  # org.freedesktop.Notifications. Without a guard, any notification request in
  # a niri session could start mako even though SwayNC owns notifications there.
  #
  # A plain "is SWAYSOCK set" check is not enough: a stale SWAYSOCK survives
  # into the next session (that is how niri inherited one), so the variable can
  # exist while Sway is gone. Only activate mako when the socket really answers
  # the Sway IPC protocol.
  makoActivate = pkgs.writeShellScript "mako-dbus-activate" ''
    if [ -z "''${SWAYSOCK:-}" ] || [ -z "''${WAYLAND_DISPLAY:-}" ]; then
      exit 1
    fi
    if ! ${lib.getExe' pkgs.sway "swaymsg"} -s "$SWAYSOCK" -t get_version >/dev/null 2>&1; then
      exit 1
    fi
    exec ${lib.getExe pkgs.mako}
  '';

  # NixOS' own Sway integration subscribes to the shutdown event and then stops
  # sway-session.target, but that cleanup has been observed to never finish.
  # This independent watcher re-does the teardown with explicit safety rules:
  # it never stops graphical-session.target while niri owns it, and it retries
  # instead of tearing the session down when Sway is still reachable.
  #
  # Stopping is issued with --no-block because this unit is itself bound to
  # sway-session.target; a blocking stop would deadlock the job queue and the
  # unit's own cgroup would be killed mid-stop.
  swayExitWatch = pkgs.writeShellApplication {
    name = "sway-exit-watch";
    runtimeInputs = with pkgs; [
      coreutils
      sway
      systemd
    ];
    text = ''
      set -euo pipefail

      # Absolute paths by default. The environment overrides exist only so the
      # headless regression tests can substitute stub commands.
      swaymsg_bin="''${SWAY_EXIT_WATCH_SWAYMSG:-${lib.getExe' pkgs.sway "swaymsg"}}"
      systemctl_bin="''${SWAY_EXIT_WATCH_SYSTEMCTL:-${lib.getExe' pkgs.systemd "systemctl"}}"
      sleep_bin="''${SWAY_EXIT_WATCH_SLEEP:-${lib.getExe' pkgs.coreutils "sleep"}}"

      # /etc/sway/config.d/nixos.conf imports SWAYSOCK into the systemd user
      # environment before it starts sway-session.target, so this unit inherits
      # the socket path from the user manager.
      if [ -z "''${SWAYSOCK:-}" ]; then
        echo "sway-exit-watch: SWAYSOCK is not set; no Sway session to watch" >&2
        exit 1
      fi

      sway_reachable() {
        "$swaymsg_bin" -s "$SWAYSOCK" -t get_version >/dev/null 2>&1
      }

      # 1. Wait for the IPC socket to accept commands.
      for _ in $(seq 1 50); do
        if sway_reachable; then
          break
        fi
        "$sleep_bin" 0.2
      done
      if ! sway_reachable; then
        echo "sway-exit-watch: Sway IPC never became reachable; retrying" >&2
        exit 1
      fi

      # 2. Block until Sway publishes shutdown or closes the socket.
      "$swaymsg_bin" -s "$SWAYSOCK" -t subscribe '["shutdown"]' >/dev/null 2>&1 || true

      # 3. A closed subscription alone is not proof of exit. If Sway still
      #    answers, fail so systemd restarts the watcher instead of stopping a
      #    still-running session.
      if sway_reachable; then
        echo "sway-exit-watch: Sway IPC is still reachable; retrying" >&2
        exit 1
      fi

      # 4. Remove the dead socket from the systemd user manager environment so
      #    the next session cannot inherit it.
      if ! "$systemctl_bin" --user unset-environment SWAYSOCK; then
        echo "sway-exit-watch: could not unset SWAYSOCK from the user environment" >&2
      fi

      # 5. Never tear down graphical-session.target while niri is running: it is
      #    niri's own target. Only a residual sway-session.target is stopped.
      if "$systemctl_bin" --user is-active --quiet niri.service; then
        echo "sway-exit-watch: niri is running; stopping only sway-session.target"
        "$systemctl_bin" --user --no-block stop sway-session.target
      else
        "$systemctl_bin" --user --no-block stop sway-session.target graphical-session.target
      fi
    '';
  };

  # Every Sway helper is bound to sway-session.target only. The ConditionEnvironment
  # guard keeps a Home Manager activation performed from a niri session from
  # starting them: SWAYSOCK is absent there, and the target is not active.
  swaySessionUnit = {
    PartOf = [ "sway-session.target" ];
    BindsTo = [ "sway-session.target" ];
    After = [ "sway-session.target" ];
    ConditionEnvironment = [ "SWAYSOCK" ];
  };

  swaySessionInstall = {
    WantedBy = [ "sway-session.target" ];
  };
in
{
  config = lib.mkIf enabled {
    xdg.dataFile."dbus-1/services/fr.emersion.mako.service".text = ''
      [D-BUS Service]
      Name=org.freedesktop.Notifications
      Exec=${makoActivate}
    '';

    xdg.configFile = {
      "sway/config".source = swayConfig;
      "mako/config".source = ../../../config/sway/mako/config;
      "fuzzel/fuzzel.ini".source = fuzzelConfig;
    };

    # Sway session helpers as systemd user units instead of bare `exec waybar`,
    # `exec mako` and `exec swaybg` lines. The unit names are distinct from the
    # niri shell's waybar.service, swaybg.service and swaync.service, so the two
    # sessions can never collide on the same unit.
    systemd.user.services = lib.mkIf isMain {
      sway-waybar = {
        Unit = swaySessionUnit // {
          Description = "Waybar for the Sway session";
        };
        Service = {
          Type = "simple";
          ExecStart = "${lib.getExe pkgs.waybar} -c ${config.xdg.configHome}/waybar/config.jsonc -s ${config.xdg.configHome}/waybar/style.css";
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install = swaySessionInstall;
      };

      sway-mako = {
        Unit = swaySessionUnit // {
          Description = "Mako notification daemon for the Sway session";
        };
        Service = {
          Type = "simple";
          ExecStart = lib.getExe pkgs.mako;
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install = swaySessionInstall;
      };

      sway-bg = {
        Unit = swaySessionUnit // {
          Description = "Wallpaper for the Sway session";
        };
        Service = {
          Type = "simple";
          ExecStart = "${lib.getExe pkgs.swaybg} -i ${wallpaper} -m fill";
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install = swaySessionInstall;
      };

      sway-exit-watch = {
        Unit = swaySessionUnit // {
          Description = "Stop the Sway session targets after Sway exits";
        };
        Service = {
          Type = "simple";
          ExecStart = "${swayExitWatch}/bin/sway-exit-watch";
          # A systemd unit is inherently single-instance: a second start while
          # the watcher runs is merged, not duplicated. Restart only on an
          # unexpected exit ("Sway still reachable" is reported as a failure so
          # the subscription is re-established).
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install = swaySessionInstall;
      };
    };
  };
}
