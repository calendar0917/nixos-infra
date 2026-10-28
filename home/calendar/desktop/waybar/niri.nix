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
    brightness = builtins.fromJSON ''"\uF185"'';
    profilePerformance = builtins.fromJSON ''"\uF0E7"'';
    profileBalanced = builtins.fromJSON ''"\uF24E"'';
    profileSaver = builtins.fromJSON ''"\uF06C"'';
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
      # Native whole-bar scroll: Waybar listens on the bar window and sends
      # FocusWorkspaceUp/Down. niri stops at the first/last workspace instead
      # of wrapping. Modules with their own scroll handlers are remapped to the
      # same actions below so one scroll cannot both change volume/brightness
      # and switch workspaces.
      enable-bar-scroll = true;
      workspace-taskbar = {
        enable = true;
        icon-size = 18;
      };
    };

    # One native network instance carries both directions. Waybar reads the
    # counters itself, so there is no polling shell script. This sits to the
    # right of the workspaces; keep its reservation compact so it cannot
    # squeeze the real taskbar icons at 1280 logical pixels.
    "network#traffic" = {
      interval = 2;
      format = "${icon.down}{bandwidthDownBytesCompact}/s ${icon.up}{bandwidthUpBytesCompact}/s";
      min-length = 14;
      max-length = 22;
      tooltip-format = "下载 {bandwidthDownBytes}/s\n上传 {bandwidthUpBytes}/s";
    };

    pulseaudio = {
      format = "${icon.volume} {volume}%";
      format-muted = "${icon.volume} muted";
      on-click = "${lib.getExe pkgs.pavucontrol}";
      # The pulseaudio module always installs its own scroll handler. Point it
      # at the same niri actions instead of wpctl so scrolling over the volume
      # label switches workspaces exactly like the rest of the bar and never
      # changes volume at the same time. Volume stays on the media keys and the
      # pavucontrol click action.
      on-scroll-up = "${lib.getExe pkgs.niri} msg action focus-workspace-up";
      on-scroll-down = "${lib.getExe pkgs.niri} msg action focus-workspace-down";
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

    # Native PPD module. Left click cycles only the profiles the daemon
    # actually exposes; no wrapper or forced profile on login/AC changes. The
    # daemon itself starts at balanced and persists later manual selections.
    "power-profiles-daemon" = {
      format = "{icon}";
      tooltip-format = "电源档位 {profile}\nCPU 驱动 {cpu_driver}\n平台驱动 {platform_driver}";
      format-icons = {
        default = icon.profileBalanced;
        performance = icon.profilePerformance;
        balanced = icon.profileBalanced;
        "power-saver" = icon.profileSaver;
      };
    };

    # The slider is the only brightness control besides the media keys. The
    # bar-level scroll belongs to workspaces, so the label's native scroll is
    # remapped instead of changing brightness a second time.
    backlight = {
      interval = 2;
      # Probed on main: amdgpu_bl1 is the only screen backlight. If a kernel
      # update renames it, remove `device` and let Waybar select the screen
      # backlight automatically.
      device = "amdgpu_bl1";
      format = "${icon.brightness} {percent}%";
      max-length = 7;
      min-brightness = 5;
      tooltip-format = "内屏亮度 {percent}%";
      on-scroll-up = "${lib.getExe pkgs.niri} msg action focus-workspace-up";
      on-scroll-down = "${lib.getExe pkgs.niri} msg action focus-workspace-down";
    };

    "backlight/slider" = {
      device = "amdgpu_bl1";
      min = 5;
      max = 100;
      interval = 1000;
    };

    # Click the brightness label to reveal the short native slider; the drawer
    # expands to the left so the clock and right-side status modules stay put.
    "group/backlight" = {
      orientation = "inherit";
      modules = [
        "backlight"
        "backlight/slider"
      ];
      drawer = {
        transition-duration = 150;
        click-to-reveal = true;
        transition-left-to-right = false;
      };
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
      margin-top = 6;
      margin-left = 8;
      margin-right = 8;
      margin-bottom = 0;
      spacing = 4;

      modules-left = [
        "custom/launcher"
        "niri/workspaces"
        "network#traffic"
      ];
      modules-center = [ "custom/clock" ];
      modules-right = [
        "cpu"
        "memory"
        "pulseaudio"
        "network#status"
      ]
      ++ lib.optional hasBluetooth "bluetooth"
      ++ lib.optional hasBattery "power-profiles-daemon"
      ++ lib.optional hasBattery "group/backlight"
      ++ lib.optional hasBattery "battery"
      ++ [
        "custom/notification"
        "group/tray"
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
