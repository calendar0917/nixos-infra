{
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  enabled = osConfig != null && (osConfig.my.desktop.niri.enable or false);
  hasBattery = osConfig != null && (osConfig.my.desktop.niri.hasBattery or false);
  hasBluetooth = osConfig != null && (osConfig.hardware.bluetooth.enable or false);
  # The mini host keeps DMS and must not grow the Waybar helper package.
  waybarShell = osConfig != null && (osConfig.my.desktop.niri.shell or "dms") == "waybar";

  waybar = import ./common.nix { inherit lib pkgs hasBattery; };

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
  icon = {
    launcher = builtins.fromJSON ''"\uF0C9"'';
    volume = builtins.fromJSON ''"\uF028"'';
    wifi = builtins.fromJSON ''"\uF1EB"'';
    bell = builtins.fromJSON ''"\uF0F3"'';
    bellOff = builtins.fromJSON ''"\uF1F6"'';
    battery = builtins.fromJSON ''"\uF240"'';
    charging = builtins.fromJSON ''"\uF0E7"'';
    bluetooth = builtins.fromJSON ''"\uF293"'';
    bluetoothConnected = builtins.fromJSON ''"\uF294"'';
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
      workspace-taskbar = {
        enable = true;
        icon-size = 18;
      };
    };

    # One native network instance carries both directions. Waybar reads the
    # counters itself, so there is no polling shell script.
    "network#traffic" = {
      interval = 2;
      format = "${icon.down} {bandwidthDownBytesCompact}/s  ${icon.up} {bandwidthUpBytesCompact}/s";
      min-length = 18;
      tooltip = false;
    };

    pulseaudio = {
      format = "${icon.volume} {volume}%";
      format-muted = "${icon.volume} muted";
      on-click = "${lib.getExe pkgs.pavucontrol}";
      on-scroll-up = "${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+";
      on-scroll-down = "${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";
      tooltip = false;
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
      on-click = "${lib.getExe' pkgs.networkmanagerapplet "nm-connection-editor"}";
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

    tray = {
      icon-size = 18;
      spacing = 6;
      show-passive-items = true;
      tooltip = false;
    };

    battery = {
      interval = 30;
      states = {
        warning = 20;
        critical = 10;
      };
      format = "${icon.battery} {capacity}%";
      format-charging = "${icon.charging} {capacity}%";
      format-plugged = "${icon.charging} {capacity}%";
      format-full = "${icon.battery} {capacity}%";
      tooltip-format = "{timeTo}";
    };

    "custom/clock" = {
      exec = "${clock}/bin/niri-waybar-clock";
      interval = 30;
      return-type = "json";
    };
  };

  bluetoothModule = {
    format = "{icon}";
    format-icons = {
      disabled = icon.bluetooth;
      off = icon.bluetooth;
      on = icon.bluetooth;
      connected = icon.bluetoothConnected;
      "no-controller" = icon.bluetooth;
    };
    format-disabled = "{icon}";
    format-off = "{icon}";
    format-on = "{icon}";
    format-connected = "{icon}";
    format-no-controller = "{icon}";
    on-click = "${lib.getExe' pkgs.blueman "blueman-manager"}";
    tooltip-format = "{controller_alias}\n{status}";
    tooltip-format-disabled = "蓝牙已禁用";
    tooltip-format-off = "蓝牙已关闭";
    tooltip-format-on = "{controller_alias}\n蓝牙已开启，未连接设备";
    tooltip-format-connected = "{controller_alias}\n{device_enumerate}";
    tooltip-format-enumerate-connected = "已连接 {device_alias}\n{device_address}";
    tooltip-format-no-controller = "没有蓝牙适配器";
  };

  modules =
    waybar.modules
    // niriModules
    // lib.optionalAttrs hasBluetooth {
      bluetooth = bluetoothModule;
    };

  settings =
    waybar.bar
    // {
      height = 34;
      margin-top = 8;
      margin-left = 10;
      margin-right = 10;
      margin-bottom = 0;
      spacing = 4;

      modules-left = [
        "custom/launcher"
        "niri/workspaces"
      ];
      modules-center = [ "custom/clock" ];
      modules-right = [
        "cpu"
        "memory"
        "network#traffic"
        "pulseaudio"
        "network#status"
      ]
      ++ lib.optional hasBluetooth "bluetooth"
      ++ lib.optional hasBattery "battery"
      ++ [
        "custom/notification"
        "tray"
      ];
    }
    // modules;
in
{
  config = lib.mkIf enabled {
    # The clock helper is referenced by absolute store path, so it does not
    # need to be in the session PATH. Only the Waybar host installs it.
    home.packages = lib.optional waybarShell clock;

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
