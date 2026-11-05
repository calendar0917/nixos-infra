{
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  enabled = osConfig != null && (osConfig.my.desktop.niri.enable or false);
  hasBattery = osConfig != null && (osConfig.my.desktop.niri.hasBattery or false);
  # The mini host keeps DMS and must not grow the Waybar helper package.
  waybarShell = osConfig != null && (osConfig.my.desktop.niri.shell or "dms") == "waybar";

  waybar = import ./common.nix { inherit lib pkgs hasBattery; };

  # Same plain package definition that shell.nix installs. The absolute store
  # path keeps the Waybar on-click commands independent of the session PATH.
  systemControl = import ../system-control.nix { inherit pkgs; };

  # The helper uses the absolute coreutils path and the session's LC_TIME, so
  # the weekday is localized without a hard-coded English name. The tooltip
  # is intentionally minute-resolution: a 30-second module should not show a
  # ticking seconds field.
  clock = pkgs.writeShellApplication {
    name = "niri-waybar-clock";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      output="$(${pkgs.coreutils}/bin/date '+%m月%d日 %a %H:%M|%Y-%m-%d %H:%M %Z')"
      text="''${output%%|*}"
      tooltip="''${output#*|}"
      printf '{"text":"%s","tooltip":"%s"}\n' "$text" "$tooltip"
    '';
  };

  # Nerd Font Symbols glyphs are written as JSON escapes so this file stays
  # plain ASCII. The font itself is installed by the main host configuration.
  lidMode = pkgs.writeShellApplication {
    name = "niri-lid-mode";
    runtimeInputs = with pkgs; [ systemd ];
    text = ''
      set -euo pipefail
      unit=lid-keep-awake.service

      case "''${1:-status}" in
        toggle)
          if systemctl --user is-active --quiet "$unit"; then
            systemctl --user stop "$unit"
          else
            systemctl --user start "$unit"
          fi
          ;;
        status)
          if systemctl --user is-active --quiet "$unit"; then
            printf '%s\n' '{"text":"☕","tooltip":"合盖保持运行（点击恢复挂起）","class":"awake"}'
          else
            printf '%s\n' '{"text":"☾","tooltip":"合盖自动挂起（点击保持运行）","class":"normal"}'
          fi
          ;;
        *)
          echo "usage: niri-lid-mode [status|toggle]" >&2
          exit 2
          ;;
      esac
    '';
  };

  icon = {
    launcher = builtins.fromJSON ''"\uF0C9"'';
    wifi = builtins.fromJSON ''"\uF1EB"'';
    bell = builtins.fromJSON ''"\uF0F3"'';
    bellOff = builtins.fromJSON ''"\uF1F6"'';
    battery = builtins.fromJSON ''"\uF240"'';
    charging = builtins.fromJSON ''"\uF0E7"'';
    gear = builtins.fromJSON ''"\uF013"'';
    down = builtins.fromJSON ''"\u2193"'';
    up = builtins.fromJSON ''"\u2191"'';
  };

  niriModules = {
    # The launcher is a font glyph so it needs no external icon theme.
    "custom/launcher" = {
      format = icon.launcher;
      tooltip = false;
      on-click = "${lib.getExe pkgs.fuzzel}";
    };

    # The niri workspace-taskbar renders the real application icons of the
    # windows on each workspace. It is available in Waybar's upstream
    # development branch and is the reason main pins a newer Waybar source.
    "niri/workspaces" = {
      format = "{icon}";
      all-outputs = false;
      # Native whole-bar scroll: Waybar listens on the bar window and sends
      # FocusWorkspaceUp/Down. niri stops at the first/last workspace instead
      # of wrapping. No right-side module captures scroll any more.
      enable-bar-scroll = true;
      workspace-taskbar = {
        enable = true;
        icon-size = 18;
      };
    };

    # One native network instance carries both directions. Waybar reads the
    # counters itself, so there is no polling shell script. This ends the left
    # region; keep its reservation compact so it cannot squeeze the real
    # taskbar icons at 1280 logical pixels.
    "network#traffic" = {
      interval = 2;
      format = "${icon.down}{bandwidthDownBytesCompact}/s ${icon.up}{bandwidthUpBytesCompact}/s";
      min-length = 14;
      max-length = 22;
      tooltip-format = "下载 {bandwidthDownBytes}/s\n上传 {bandwidthUpBytes}/s";
    };

    # The icon is constant to avoid a long SSID pushing the clock around.
    # Interface, SSID, address and signal stay in the tooltip.
    "network#status" = {
      interval = 5;
      format-wifi = icon.wifi;
      format-ethernet = icon.wifi;
      format-disconnected = icon.wifi;
      format-linked = icon.wifi;
      format-disabled = icon.wifi;
      # The status label opens NetworkManager's terminal UI directly in the
      # same floating Kitty window; the applet stays available in the tray.
      on-click = "${lib.getExe systemControl} launch network";
      tooltip-format = "{ifname}\n{essid}\n{ipaddr}/{cidr}\n信号 {signalStrength}%";
    };

    "custom/notification" = {
      tooltip = false;
      format = "{icon}";
      format-icons = {
        notification = icon.bell;
        none = icon.bellOff;
        dnd-notification = icon.bellOff;
        dnd-none = icon.bellOff;
        inhibited-notification = icon.bellOff;
        inhibited-none = icon.bellOff;
        dnd-inhibited-notification = icon.bellOff;
        dnd-inhibited-none = icon.bellOff;
      };
      return-type = "json";
      exec = "swaync-client -swb";
      on-click = "swaync-client -t -sw";
      on-click-right = "swaync-client -d -sw";
    };

    "custom/lid-mode" = {
      exec = "${lib.getExe lidMode} status";
      interval = 3;
      return-type = "json";
      on-click = "${lib.getExe lidMode} toggle";
    };

    # One explicit entry point for network, Bluetooth, audio, brightness,
    # power profiles and lid behaviour. Mod+S opens the same menu.
    "custom/system-control" = {
      format = icon.gear;
      tooltip = "系统控制中心 · Mod+S";
      on-click = "${lib.getExe systemControl} launch";
    };

    tray = {
      icon-size = 18;
      spacing = 6;
      show-passive-items = true;
      tooltip = false;
    };

    # The tray is the only right-side group. Its leader stays visible when
    # collapsed so the user has a stable hover target; the real tray items
    # are revealed by Waybar's native drawer and remain clickable.
    "custom/tray-toggle" = {
      format = "⋯";
      tooltip-format = "后台应用";
    };

    "group/tray" = {
      orientation = "inherit";
      modules = [
        "custom/tray-toggle"
        "tray"
      ];
      drawer = {
        transition-duration = 150;
        reveal-delay = 150;
        transition-left-to-right = false;
        click-to-reveal = false;
        start-expanded = false;
      };
    };

    battery = {
      # BAT1 exposes power_now on main, so {power} is a real battery-side
      # reading. Only discharging/charging formats show it; plugged, full and
      # unknown states never print a synthetic 0 W. 10 s is the requested
      # power refresh interval.
      interval = 10;
      states = {
        warning = 20;
        critical = 10;
      };
      format = "${icon.battery} {capacity}%";
      format-charging = "${icon.charging} {capacity}% · 充电";
      format-discharging = "${icon.battery} {capacity}% · {power:.1f} W";
      format-plugged = "${icon.charging} {capacity}% · 已插电";
      format-full = "${icon.battery} {capacity}% · 已充满";
      tooltip-format = "电量 {capacity}%\n健康度 {health}% · {cycles} 次循环";
      tooltip-format-discharging = "剩余 {time}\n电池侧功率 {power:.1f} W\n健康度 {health}% · {cycles} 次循环";
      tooltip-format-charging = "充满还需 {time}\n充电功率 {power:.1f} W\n健康度 {health}% · {cycles} 次循环";
      tooltip-format-plugged = "已插电，未充电\n健康度 {health}% · {cycles} 次循环";
      tooltip-format-full = "已充满\n健康度 {health}% · {cycles} 次循环";
    };

    "custom/clock" = {
      exec = "${clock}/bin/niri-waybar-clock";
      interval = 30;
      return-type = "json";
    };
  };

  # Drop shared definitions this profile no longer places on the bar. The Sway
  # profile still imports common.nix unchanged.
  modules = builtins.removeAttrs (waybar.modules // niriModules) [
    "network"
    "pulseaudio"
  ];

  settings =
    waybar.bar
    // {
      height = 34;
      margin-top = 6;
      margin-left = 8;
      margin-right = 8;
      margin-bottom = 0;
      spacing = 4;

      # CPU, RAM and traffic are always visible. They are compact native
      # modules, not a click-to-reveal drawer, so the left region uses the
      # space it already had.
      modules-left = [
        "custom/launcher"
        "niri/workspaces"
        "cpu"
        "memory"
        "network#traffic"
      ];
      modules-center = [ "custom/clock" ];
      modules-right = [
        "network#status"
      ]
      ++ lib.optional hasBattery "battery"
      ++ lib.optional hasBattery "custom/lid-mode"
      ++ [
        "custom/notification"
        "custom/system-control"
        "group/tray"
      ];
    }
    // modules;
in
{
  # Gate the whole profile on the Waybar shell, not merely on niri being
  # enabled. The mini host keeps DMS and must not receive this config file,
  # its stylesheet or any control-center package reference.
  config = lib.mkIf (enabled && waybarShell) {
    # The clock helper is referenced by absolute store path, so it does not
    # need to be in the session PATH. Only the Waybar host installs it.
    home.packages = [
      clock
      lidMode
    ];

    # Generate the niri profile only. The Sway profile keeps using
    # ~/.config/waybar/config.jsonc, and the niri shell unit starts this file
    # explicitly. Nothing here enables Waybar's packaged user unit.
    xdg.configFile = {
      "waybar/niri.jsonc".source = (pkgs.formats.json { }).generate "waybar-niri-config.json" settings;

      # The niri profile has its own Catppuccin Mocha stylesheet; the Sway
      # fallback keeps the original teal stylesheet and cannot be broken by
      # niri-only selectors.
      "waybar/style-niri.css".source = ../../../../config/waybar/style-niri.css;
    };

    # Waybar is started explicitly by home/calendar/desktop/shell.nix through
    # a niri-bound user service. Do not add it to home.packages here: the
    # shell module owns its package and lifecycle.
  };
}
